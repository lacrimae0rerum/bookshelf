"""The `claude` CLI runs the API waits on, tracked so a stopping API can end them instead
of waiting minutes for runs nobody will record. (The speech model runs detached, never
tracked: `app.audio.detached`.) Each runs in its own process group, so a kill takes its
whole tree; and so no Ctrl-C reaches it.

Each run belongs to a job or to a request, by where it starts: inside `job_scope()` (the
worker opens one around every job it runs, `app.jobs.worker`) it belongs to that job;
anywhere else (`/search/answer` and its router) it belongs to a request. Unmarked is the
safe default: such a run is killed later (`terminate_all`), never earlier.

Shutdown kills them in two steps (`app.main` lifespan, `app.core.lifecycle`):
- `terminate_jobs`, as soon as shutdown begins: the jobs go back to the queue, so their
  runs are wasted. A request's run is left alone: uvicorn waits for its response.
- `terminate_all`, when the exit is forced (a second Ctrl-C drops the open requests) and
  at the end of the lifespan: whatever is left.
"""

import contextlib
import contextvars
import os
import signal
import subprocess
import threading
from collections.abc import Iterator

_IN_JOB: contextvars.ContextVar[bool] = contextvars.ContextVar("in_job", default=False)

_LIVE: dict[subprocess.Popen[str], bool] = {}  # each run: does it belong to a job?
_LIVE_LOCK = threading.Lock()


@contextlib.contextmanager
def job_scope() -> Iterator[None]:
    """Runs tracked while the block runs (in this thread or task) belong to a job."""
    token = _IN_JOB.set(True)
    try:
        yield
    finally:
        _IN_JOB.reset(token)


@contextlib.contextmanager
def tracked(proc: subprocess.Popen[str]) -> Iterator[subprocess.Popen[str]]:
    """`proc` is known to `terminate_jobs` / `terminate_all` while the block runs."""
    with _LIVE_LOCK:
        _LIVE[proc] = _IN_JOB.get()
    try:
        yield proc
    finally:
        with _LIVE_LOCK:
            _LIVE.pop(proc, None)


def communicate_tracked(
    proc: subprocess.Popen[str], stdin: str, *, timeout: float
) -> tuple[str, str]:
    """`proc.communicate`, tracked. On a timeout the whole process group is killed before
    `TimeoutExpired` propagates."""
    with tracked(proc):
        try:
            return proc.communicate(stdin, timeout=timeout)
        except subprocess.TimeoutExpired:
            kill_group(proc)
            proc.communicate()
            raise


def terminate_jobs() -> int:
    """Kill the process tree of every tracked run that belongs to a job; their `run` calls
    fail. Returns how many were killed."""
    return _terminate(only_jobs=True)


def terminate_all() -> int:
    """Kill every tracked process tree this process started, jobs' and requests' alike.
    Returns how many were killed."""
    return _terminate(only_jobs=False)


def _terminate(*, only_jobs: bool) -> int:
    with _LIVE_LOCK:
        procs = [proc for proc, in_job in _LIVE.items() if in_job or not only_jobs]
    for proc in procs:
        kill_group(proc)
    return len(procs)


def kill_group(proc: subprocess.Popen[str]) -> None:
    with contextlib.suppress(ProcessLookupError):  # already gone
        os.killpg(proc.pid, signal.SIGKILL)
