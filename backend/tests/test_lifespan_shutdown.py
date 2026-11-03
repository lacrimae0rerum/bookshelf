"""The lifespan's shutdown (`app.main`): the runners stop on the first signal, a forced
exit kills the requests' runs too, and the lifespan's end kills whatever is left. The
signal handling itself is in `tests/test_lifecycle.py`."""

import asyncio
import contextlib
import signal
import subprocess
import threading
from collections.abc import Iterator

import pytest
from fastapi import FastAPI

from app import main
from app.core.config import get_settings
from app.jobs.background import JOIN_SECONDS, BackgroundWorker
from app.jobs.runners import Runners
from app.jobs.worker import Worker
from tests.conftest import TrackedRuns

WATCHDOG_SECONDS = 0.5
_SIGNALS = (signal.SIGINT, signal.SIGTERM)


class _FakeWorker:
    """Stands in for a runner's `BackgroundWorker` (and the `claude` run inside it):
    records each time `stop_all` stops it, and on which thread."""

    def __init__(self) -> None:
        self.stopped = threading.Event()
        self.stops: list[str] = []

    def release(self) -> None:
        """Nothing held to hand back."""

    def stop(self, timeout: float = 0.0, *, abandon: bool = False) -> bool:
        self.stops.append(threading.current_thread().name)
        self.stopped.set()
        return True


def test_a_shutdown_signal_stops_the_runners_without_waiting_for_the_lifespan_shutdown(
    monkeypatch: pytest.MonkeyPatch,
):
    """A second Ctrl-C makes uvicorn skip the lifespan shutdown, and under `fastapi dev`
    the server then dies of the SIGTERM its reloader sent: the first signal alone must
    stop the runners (jobs back to the queue, `claude` killed). Once: the lifespan's own
    `runners.shutdown()` afterwards finds nothing left to stop."""
    worker = _FakeWorker()

    class _RunnersWithAJob(Runners):
        def start(self) -> None:
            self.jobs = worker  # duck-typed: all `stop_all` needs of a BackgroundWorker

    monkeypatch.setattr(main, "Runners", _RunnersWithAJob)
    app = FastAPI()
    app.state.settings = get_settings()

    async def serve_until_signalled() -> bool:
        async with main.lifespan(app):
            signal.raise_signal(signal.SIGTERM)
            return worker.stopped.wait(timeout=WATCHDOG_SECONDS)

    received: list[int] = []
    previous = signal.signal(signal.SIGTERM, lambda sig, frame: received.append(sig))  # uvicorn
    try:
        stopped_inside_the_lifespan = asyncio.run(serve_until_signalled())
    finally:
        signal.signal(signal.SIGTERM, previous)

    assert stopped_inside_the_lifespan, "the runners waited for the lifespan shutdown"
    assert len(worker.stops) == 1, "the runners must stop once in all"
    assert worker.stops[0] != threading.main_thread().name, "the signal's thread stops them"
    assert received == [signal.SIGTERM]


class _ObservedJobWorker(BackgroundWorker):
    """A real pipeline worker, never started: stopping it runs the real `abandon()`. Tells
    when that stop is over."""

    def __init__(self) -> None:
        worker = Worker(
            handlers={}, session_factory=contextlib.nullcontext, on_done=lambda db, job: None
        )  # nothing held, so handing jobs back never opens the session
        super().__init__(worker, name="job-worker")
        self.stopped = threading.Event()

    def stop(self, timeout: float = JOIN_SECONDS, *, abandon: bool = False) -> bool:
        try:
            return super().stop(timeout, abandon=abandon)
        finally:
            self.stopped.set()


@contextlib.contextmanager
def _uvicorn_handlers() -> Iterator[list[int]]:
    """Recording handlers for SIGINT and SIGTERM, standing in for uvicorn's (never the
    default ones, which would end the test run). Yields the signals they got."""
    received: list[int] = []
    previous = {sig: signal.signal(sig, lambda s, f: received.append(s)) for sig in _SIGNALS}
    try:
        yield received
    finally:
        for sig, handler in previous.items():
            signal.signal(sig, handler)


def test_a_request_run_outlives_the_first_signal_and_dies_when_the_exit_is_forced(
    monkeypatch: pytest.MonkeyPatch, tracked_runs: TrackedRuns
):
    """One Ctrl-C (or a reload) hands the jobs back and kills their runs at once, but
    uvicorn still waits for open requests, so a `/search/answer` run finishes as before.
    A second Ctrl-C forces the exit and drops that request: its run is killed too, or it
    would outlive the server (`fastapi dev` then exits without the lifespan shutdown)."""
    worker = _ObservedJobWorker()

    class _RunnersWithAWorker(Runners):
        def start(self) -> None:
            self.jobs = worker

    monkeypatch.setattr(main, "Runners", _RunnersWithAWorker)
    app = FastAPI()
    app.state.settings = get_settings()
    outcome: dict[str, object] = {}

    async def serve() -> None:
        async with main.lifespan(app):
            job_run = tracked_runs.start(for_a_job=True)
            request_run = tracked_runs.start(for_a_job=False)
            signal.raise_signal(signal.SIGTERM)  # one Ctrl-C, or a reload
            outcome["jobs stopped"] = worker.stopped.wait(timeout=WATCHDOG_SECONDS)
            outcome["job run"] = tracked_runs.exit_code(job_run)
            outcome["request run, one signal"] = tracked_runs.exit_code(request_run, within=0.2)
            signal.raise_signal(signal.SIGINT)  # a second Ctrl-C: uvicorn forces the exit
            outcome["request run, forced"] = tracked_runs.exit_code(request_run)

    with _uvicorn_handlers() as received:
        asyncio.run(serve())

    assert outcome == {
        "jobs stopped": True,
        "job run": TrackedRuns.KILLED,
        "request run, one signal": None,  # still running
        "request run, forced": TrackedRuns.KILLED,
    }
    assert received == [signal.SIGTERM, signal.SIGINT]


def test_the_lifespan_end_kills_every_run_still_going(tracked_runs: TrackedRuns):
    """Whatever outlived the shutdown (a request's run whose response was cut) dies with
    the lifespan, as it always did, signal or not."""
    app = FastAPI()
    app.state.settings = get_settings()

    async def serve() -> subprocess.Popen[str]:
        async with main.lifespan(app):
            return tracked_runs.start(for_a_job=False)

    request_run = asyncio.run(serve())

    assert tracked_runs.exit_code(request_run) == TrackedRuns.KILLED
