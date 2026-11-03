"""Shutdown ends long-lived responses: SSE streams stop at once instead of holding a
`fastapi dev` reload (or Ctrl-C) until their own timers run out."""

import json
import os
import signal
import sys
import threading
from collections.abc import Callable, Iterator
from contextlib import contextmanager
from types import FrameType

import pytest
from fastapi.testclient import TestClient

from app.core import lifecycle
from app.core.docs import TAGS_METADATA

WATCHDOG_SECONDS = 0.5
_SIGNALS = (signal.SIGINT, signal.SIGTERM)

type TraceFunction = Callable[[FrameType, str, object], TraceFunction | None]


class _Hung(Exception):
    """Raised in the main thread by `_watchdog` when the block under test stays blocked."""


@contextmanager
def _watchdog(seconds: float) -> Iterator[None]:
    """Interrupt the main thread (SIGALRM raising `_Hung`) if the block takes longer than
    `seconds`: a signal handler blocked on a lock would otherwise hang the whole suite.
    A blocked `Lock.acquire()` in the main thread returns early to run signal handlers."""

    finished = threading.Event()

    def interrupt(signum: int, frame: FrameType | None) -> None:
        if not finished.is_set():  # an alarm that lands just as the block ends is moot
            raise _Hung

    previous = signal.signal(signal.SIGALRM, interrupt)
    main_thread = threading.main_thread().ident
    assert main_thread is not None

    def watch() -> None:
        if not finished.wait(timeout=seconds):
            signal.pthread_kill(main_thread, signal.SIGALRM)

    watcher = threading.Thread(target=watch, daemon=True)
    watcher.start()
    try:
        yield
    finally:
        try:  # an alarm landing in here must not skip putting the old handler back
            finished.set()
            watcher.join(timeout=seconds)
        finally:
            signal.signal(signal.SIGALRM, previous)


def _inside_a_lifecycle_call(frame: FrameType | None) -> bool:
    """True inside what the shutdown handler calls in `app.core.lifecycle` (setting the
    flag, waking the runner stopper), but not on the handler's own lines."""
    while frame is not None:
        code = frame.f_code
        if code.co_filename == lifecycle.__file__ and code.co_name != "chained":
            return True
        frame = frame.f_back
    return False


@contextmanager
def _signal_again_inside_lifecycle_calls(signum: int) -> Iterator[list[int]]:
    """Deliver `signum` once more before every line that runs inside what the handler calls
    in `app.core.lifecycle` (`stopping.set()`, the stopper's wake-up, and anything they
    call), so a second handler runs while the first one is there. That is what
    `kill -TERM -- -<pgid>` does to `uv run fastapi run` without a terminal: python gets
    the group's signal and `uv` forwards another. Yields the lines where one landed. The
    nested handlers run inside the trace function, where tracing is off, so only the
    first handler's calls are traced."""
    landed: list[int] = []

    def before_each_line(frame: FrameType, event: str, arg: object) -> TraceFunction:
        if event == "line":
            landed.append(frame.f_lineno)
            signal.raise_signal(signum)  # its handler runs right here, before returning
        return before_each_line

    def on_call(frame: FrameType, event: str, arg: object) -> TraceFunction | None:
        return before_each_line if _inside_a_lifecycle_call(frame) else None

    previous = sys.gettrace()  # e.g. coverage's tracer
    sys.settrace(on_call)
    try:
        yield landed
    finally:
        sys.settrace(previous)


@pytest.fixture(autouse=True)
def _flag_cleared() -> Iterator[None]:
    """A failing test must not leave the shutdown flag set for the tests after it."""
    yield
    lifecycle.stopping.clear()


@pytest.fixture
def shutting_down() -> Iterator[None]:
    lifecycle.stopping.set()
    yield
    lifecycle.stopping.clear()


def test_the_job_stream_ends_as_soon_as_shutdown_begins(client: TestClient, shutting_down):
    with client.stream("GET", "/api/v1/jobs/stream", params={"max_seconds": 3600}) as response:
        text = "".join(response.iter_text())

    last = text.strip().split("\n\n")[-1].splitlines()
    assert last[0] == "event: end"
    assert json.loads(last[1].removeprefix("data: ")) == {"reason": "shutdown"}


def test_shutdown_signals_set_the_flag_and_still_reach_the_server():
    received: list[int] = []
    previous = signal.signal(signal.SIGTERM, lambda signum, frame: received.append(signum))
    restore = lifecycle.install()
    try:
        signal.raise_signal(signal.SIGTERM)
    finally:
        restore()
        signal.signal(signal.SIGTERM, previous)
    stopped = lifecycle.stopping.is_set()

    assert stopped and received == [signal.SIGTERM]


# Without a terminal `uv` forwards SIGINT the same way as SIGTERM.
@pytest.mark.parametrize("signum", [signal.SIGINT, signal.SIGTERM], ids=lambda s: s.name)
@pytest.mark.parametrize("with_stopper", [False, True], ids=["flag-only", "with-stopper"])
def test_a_signal_arriving_while_the_handler_runs_still_reaches_the_server(
    signum: signal.Signals, with_stopper: bool
):
    received: list[int] = []
    stops: list[str] = []
    forces: list[str] = []
    previous = signal.signal(signum, lambda sig, frame: received.append(sig))

    def record_stop() -> None:
        stops.append(threading.current_thread().name)

    def record_force() -> None:
        forces.append(threading.current_thread().name)

    if with_stopper:
        restore = lifecycle.install(on_shutdown=record_stop, on_force=record_force)
    else:
        restore = lifecycle.install()
    try:
        with (
            _watchdog(WATCHDOG_SECONDS),
            _signal_again_inside_lifecycle_calls(signum) as landed,
        ):
            signal.raise_signal(signum)
    except _Hung:
        pytest.fail(f"a {signum.name} landing inside the shutdown handler blocked it")
    finally:
        restore()  # waits for the stopper, so `stops` is final
        signal.signal(signum, previous)
    stopped = lifecycle.stopping.is_set()

    assert landed, "no second signal reached the handler while it was running"
    assert stopped and received == [signum] * (1 + len(landed))
    assert len(stops) == (1 if with_stopper else 0), "the stopper must run once, however many land"
    # A SIGINT after any signal is a forced exit for uvicorn too; a SIGTERM never is.
    forced = with_stopper and signum == signal.SIGINT
    assert len(forces) == (1 if forced else 0), "the forced stop must run once, on a SIGINT"


class _FakeUvicornServer:
    """The exit state and `handle_exit` rule of `uvicorn.Server` (0.53): a SIGINT after
    any signal forces the exit. Its first `handle_exit` delivers one more signal, before
    or after applying the rule, as a nested signal lands while the handler runs."""

    def __init__(self, nested: signal.Signals, *, before_the_rule: bool) -> None:
        self.should_exit = False
        self.force_exit = False
        self._nested: signal.Signals | None = nested
        self._before_the_rule = before_the_rule

    def handle_exit(self, sig: int, frame: FrameType | None) -> None:
        nested, self._nested = self._nested, None
        if nested is not None and self._before_the_rule:
            signal.raise_signal(nested)
        if self.should_exit and sig == signal.SIGINT:
            self.force_exit = True
        else:
            self.should_exit = True
        if nested is not None and not self._before_the_rule:
            signal.raise_signal(nested)


@pytest.mark.parametrize(
    ("outer", "nested", "before_the_rule", "uvicorn_forces"),
    [
        (signal.SIGINT, signal.SIGTERM, True, True),  # the reloader's SIGTERM lands first
        (signal.SIGTERM, signal.SIGINT, True, False),  # the SIGINT reaches uvicorn first
        (signal.SIGTERM, signal.SIGINT, False, True),  # just after uvicorn took the outer
        (signal.SIGINT, signal.SIGTERM, False, False),
    ],
    ids=["INT>TERM-first", "TERM>INT-first", "TERM>INT-after", "INT>TERM-after"],
)
def test_the_forced_stop_runs_exactly_when_uvicorn_forces_the_exit(
    outer: signal.Signals, nested: signal.Signals, before_the_rule: bool, uvicorn_forces: bool
):
    """However the signals nest, `on_force` follows uvicorn's own `force_exit`: a request's
    run must die when uvicorn drops its connection, and only then."""
    server = _FakeUvicornServer(nested, before_the_rule=before_the_rule)
    forces: list[str] = []
    previous = {sig: signal.signal(sig, server.handle_exit) for sig in _SIGNALS}
    restore = lifecycle.install(on_shutdown=lambda: None, on_force=lambda: forces.append("x"))
    try:
        with _watchdog(WATCHDOG_SECONDS):
            signal.raise_signal(outer)
    finally:
        restore()  # waits for the forced stop, so `forces` is final
        for sig, handler in previous.items():
            signal.signal(sig, handler)

    assert server.force_exit is uvicorn_forces
    assert len(forces) == (1 if uvicorn_forces else 0)


def _open_descriptors() -> set[int]:
    return {int(fd) for fd in os.listdir("/dev/fd")}


def test_install_and_restore_leave_no_thread_descriptor_or_handler_behind():
    handlers = {sig: signal.getsignal(sig) for sig in _SIGNALS}
    threads, descriptors = set(threading.enumerate()), _open_descriptors()

    for _ in range(3):  # a process (or a pytest session) may install more than once
        lifecycle.install(on_shutdown=lambda: None, on_force=lambda: None)()

    assert {sig: signal.getsignal(sig) for sig in handlers} == handlers
    assert set(threading.enumerate()) == threads
    assert _open_descriptors() == descriptors


def test_every_route_tag_is_documented(client: TestClient):
    paths = client.get("/openapi.json").json()["paths"]
    used = {tag for path in paths.values() for op in path.values() for tag in op.get("tags", [])}

    assert used <= {str(t["name"]) for t in TAGS_METADATA}


def test_openapi_lists_resume_and_confirm(client: TestClient):
    paths = json.dumps(client.get("/openapi.json").json()["paths"])

    assert "/outline/confirm" in paths and "/resume" in paths
