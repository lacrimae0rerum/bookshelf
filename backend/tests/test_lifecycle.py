"""Shutdown ends long-lived responses: SSE streams stop at once instead of holding a
`fastapi dev` reload (or Ctrl-C) until their own timers run out."""

import json
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


def _inside_stopping_set(frame: FrameType | None) -> bool:
    set_code = type(lifecycle.stopping).set.__code__
    while frame is not None:
        if frame.f_code is set_code:
            return True
        frame = frame.f_back
    return False


@contextmanager
def _signal_again_inside_stopping_set(signum: int) -> Iterator[list[int]]:
    """Deliver `signum` once more before every line that runs inside `stopping.set()` (its
    own and those of anything it calls), so a second handler runs while the first one is
    there. That is what `kill -TERM -- -<pgid>` does to `uv run fastapi run`: python gets
    the group's SIGTERM and `uv` forwards another. Yields the lines where one landed. The
    nested handlers run inside the trace function, where tracing is off, so only the
    first handler's `set()` is traced."""
    landed: list[int] = []

    def before_each_line(frame: FrameType, event: str, arg: object) -> TraceFunction:
        if event == "line":
            landed.append(frame.f_lineno)
            signal.raise_signal(signum)  # its handler runs right here, before returning
        return before_each_line

    def on_call(frame: FrameType, event: str, arg: object) -> TraceFunction | None:
        return before_each_line if _inside_stopping_set(frame) else None

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


# `uv` forwards SIGINT (Ctrl-C reaches the whole foreground group) the same way as SIGTERM.
@pytest.mark.parametrize("signum", [signal.SIGINT, signal.SIGTERM], ids=lambda s: s.name)
def test_a_signal_arriving_while_the_flag_is_being_set_still_reaches_the_server(
    signum: signal.Signals,
):
    received: list[int] = []
    previous = signal.signal(signum, lambda sig, frame: received.append(sig))
    restore = lifecycle.install()
    try:
        with (
            _watchdog(WATCHDOG_SECONDS),
            _signal_again_inside_stopping_set(signum) as landed,
        ):
            signal.raise_signal(signum)
    except _Hung:
        pytest.fail(f"a {signum.name} landing inside stopping.set() blocked the shutdown handler")
    finally:
        restore()
        signal.signal(signum, previous)
    stopped = lifecycle.stopping.is_set()

    assert landed, "no second signal reached the handler while it was setting the flag"
    assert stopped and received == [signum] * (1 + len(landed))


def test_every_route_tag_is_documented(client: TestClient):
    paths = client.get("/openapi.json").json()["paths"]
    used = {tag for path in paths.values() for op in path.values() for tag in op.get("tags", [])}

    assert used <= {str(t["name"]) for t in TAGS_METADATA}


def test_openapi_lists_resume_and_confirm(client: TestClient):
    paths = json.dumps(client.get("/openapi.json").json()["paths"])

    assert "/outline/confirm" in paths and "/resume" in paths
