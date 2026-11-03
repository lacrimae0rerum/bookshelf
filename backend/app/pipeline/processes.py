"""The `claude` CLI runs the API waits on, tracked so a stopping API can end them instead
of waiting minutes for runs nobody will record. (The speech model runs detached, never
tracked: `app.audio.detached`.) Each runs in its own process group, so a kill takes its
whole tree; and so no Ctrl-C reaches it.

Each run belongs to a job or to a request, by where it starts: inside `job_scope()` (the
worker opens one around every job it runs, `app.jobs.worker`) it belongs to that job;
anywhere else (`/search/answer` and its router) it belongs to a request. Unmarked is the
safe default: such a run is killed later (`terminate_all`), never earlier.

Shutdown kills them in two steps (`app.main` lifespan, `app.core.lifecycle`):
- `refuse_jobs`, as soon as shutdown begins (`Runners.shutdown`, once the jobs are back
  in the queue, so their runs are wasted): it kills the jobs' runs, and from then until
  the process ends every job run is killed as it registers. A job that was waiting for a
  CLI slot (`runner.cli_slots`) starts its run after the others died; nothing may wait on
  it, since the process (or the macOS app's SIGKILL, which never reaches a run in its own
  session) can end any moment. A request's run is left alone: uvicorn waits for it.
- `terminate_all`, when the exit is forced (a second Ctrl-C drops the open requests) and
  at the end of the lifespan: whatever is left.
`terminate_jobs` (a worker's `abandon`, e.g. on a database switch) kills the jobs' runs
without refusing later ones: the runners start again.
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
_LIVE_LOCK = threading.Lock()  # also guards `_JOBS_REFUSED`
_JOBS_REFUSED = False  # set for good by `refuse_jobs`


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
    """`proc` is known to `terminate_jobs` / `terminate_all` while the block runs. A job's
    run registered after `refuse_jobs` is killed at once, so its `run` call fails."""
    in_job = _IN_JOB.get()
    with _LIVE_LOCK:  # one step with `refuse_jobs`: a run is either listed or refused
        _LIVE[proc] = in_job
        refused = in_job and _JOBS_REFUSED
    if refused:
        kill_group(proc)
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


def jobs_refused() -> bool:
    """True inside a job once `refuse_jobs` ran: a run about to start would die at once."""
    return _IN_JOB.get() and _JOBS_REFUSED


def refuse_jobs() -> int:
    """Kill the jobs' runs, and every job run registered after this, until the process
    ends (the shutdown: the jobs are back in the queue). Returns how many were killed."""
    global _JOBS_REFUSED
    with _LIVE_LOCK:
        _JOBS_REFUSED = True
        procs = [proc for proc, in_job in _LIVE.items() if in_job]
    for proc in procs:
        kill_group(proc)
    return len(procs)


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
