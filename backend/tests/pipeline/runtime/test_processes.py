"""What a stopping API kills (`app.pipeline.processes`): the runs of jobs as soon as
shutdown begins, the runs of requests (`/search/answer`) only when everything goes."""

import subprocess
import threading

import pytest
from sqlmodel import Session

from app.jobs import queue
from app.jobs.registry import HandlerResult, JobContext
from app.jobs.worker import Worker
from app.models.enums import JobKind
from app.pipeline import processes
from tests.conftest import TrackedRuns

STILL_RUNNING_FOR = 0.2


def test_terminating_the_jobs_runs_leaves_the_requests_runs_alone(tracked_runs: TrackedRuns):
    job_run = tracked_runs.start(for_a_job=True)
    request_run = tracked_runs.start(for_a_job=False)

    processes.terminate_jobs()

    assert tracked_runs.exit_code(job_run) == TrackedRuns.KILLED
    assert tracked_runs.exit_code(request_run, within=STILL_RUNNING_FOR) is None


def test_terminating_everything_takes_the_requests_runs_too(tracked_runs: TrackedRuns):
    request_run = tracked_runs.start(for_a_job=False)
    job_run = tracked_runs.start(for_a_job=True)

    processes.terminate_all()

    assert tracked_runs.exit_code(request_run) == TrackedRuns.KILLED
    assert tracked_runs.exit_code(job_run) == TrackedRuns.KILLED


def test_abandon_kills_the_jobs_runs_even_when_handing_the_jobs_back_fails(
    tracked_runs: TrackedRuns,
):
    def database_gone() -> None:
        raise RuntimeError("database gone")

    worker = Worker(handlers={}, session_factory=database_gone, on_done=lambda db, job: None)
    job_run = tracked_runs.start(for_a_job=True)

    with pytest.raises(RuntimeError, match="database gone"):
        worker.abandon()

    assert tracked_runs.exit_code(job_run) == TrackedRuns.KILLED


def test_a_run_a_jobs_handler_starts_belongs_to_the_job(session: Session):
    """The worker marks each job's runs (`processes.job_scope`), so the first shutdown
    signal kills them; unmarked, they would wait for the end of the lifespan."""
    queue.enqueue(session, queue.JobSpec(kind=JobKind.EXPORT, anchor="scoped"))
    registered = threading.Event()
    exit_codes: list[int | None] = []

    def handler(ctx: JobContext) -> HandlerResult:
        proc = subprocess.Popen(["/bin/sleep", "30"], start_new_session=True, text=True)
        try:
            with processes.tracked(proc):
                registered.set()
                exit_codes.append(TrackedRuns.exit_code(proc, within=2.0))
        finally:
            if proc.poll() is None:
                proc.kill()
                proc.wait()
        return HandlerResult()

    worker = Worker(poll_seconds=0.01, handlers={JobKind.EXPORT: handler},
                    on_done=lambda db, job: None, concurrency=1)  # fmt: skip
    thread = threading.Thread(target=worker.run, kwargs={"once": True})
    thread.start()
    try:
        assert registered.wait(timeout=5)
        processes.terminate_jobs()
    finally:
        thread.join(timeout=5)

    assert exit_codes == [TrackedRuns.KILLED]
