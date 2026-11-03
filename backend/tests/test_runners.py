"""The API's runners (`app.jobs.runners`): Settings → Database stops and starts them
again; a shutdown stops them for good, and refuses every job run after it."""

import subprocess

import pytest

from app.core.config import get_settings
from app.jobs import runners as runners_module
from app.jobs.runners import Runners
from app.pipeline import processes
from tests.conftest import TrackedRuns

STILL_RUNNING_FOR = 0.2


class _FakeJobWorker:
    """Stands in for the API's pipeline worker (`runners._job_worker`): no thread, no DB."""

    def __init__(self) -> None:
        self.stopped = False
        self.events: list[str] = []

    def start(self) -> None:
        """Nothing to run."""

    def release(self) -> None:
        self.events.append("release")

    def stop(self, timeout: float = 0.0, *, abandon: bool = False) -> bool:
        self.stopped = True
        self.events.append("stop")
        return True


@pytest.fixture
def runners(monkeypatch: pytest.MonkeyPatch) -> Runners:
    monkeypatch.setattr(runners_module, "_job_worker", lambda settings: _FakeJobWorker())
    only_the_job_worker = get_settings().model_copy(
        update={
            "api_worker": True,
            "api_embed_runner": False,
            "api_narrate_runner": False,
            "api_build_runner": False,
        }
    )
    return Runners(only_the_job_worker)


def test_a_stop_then_a_start_restarts_the_runners(runners: Runners):
    """What a database switch, sync or snapshot restore does around its work."""
    runners.start()
    first = runners.jobs

    runners.stop()
    runners.start()

    assert runners.jobs is not None and runners.jobs is not first


def test_nothing_starts_the_runners_again_after_the_shutdown_stop(runners: Runners):
    runners.start()
    started = runners.jobs

    runners.shutdown()
    runners.start()  # the `finally: runners.start()` of a switch the shutdown caught

    assert runners.jobs is None
    assert isinstance(started, _FakeJobWorker) and started.stopped


def _started_worker(runners: Runners) -> _FakeJobWorker:
    runners.start()
    assert isinstance(runners.jobs, _FakeJobWorker)
    return runners.jobs


def test_the_shutdown_kills_the_jobs_runs_once_the_jobs_are_handed_back(
    runners: Runners, tracked_runs: TrackedRuns, monkeypatch: pytest.MonkeyPatch
):
    """Killed before its job went back, a run would count as a failed attempt."""
    worker = _started_worker(runners)
    real_kill = processes.kill_group

    def kill_group(proc: subprocess.Popen[str]) -> None:
        worker.events.append("kill")
        real_kill(proc)

    monkeypatch.setattr(processes, "kill_group", kill_group)
    job_run = tracked_runs.start(for_a_job=True)

    runners.shutdown()

    assert tracked_runs.exit_code(job_run) == TrackedRuns.KILLED
    assert worker.events.index("release") < worker.events.index("kill")


def test_a_job_run_that_starts_after_the_shutdown_dies_at_once(
    runners: Runners, tracked_runs: TrackedRuns
):
    """A job that was waiting for a CLI slot when the jobs went back starts its run late:
    nothing may wait on it, and the process (or the app's SIGKILL) may end any moment."""
    _started_worker(runners)
    runners.shutdown()

    late_run = tracked_runs.start(for_a_job=True)

    assert tracked_runs.exit_code(late_run) == TrackedRuns.KILLED


def test_a_request_run_still_starts_after_the_shutdown(runners: Runners, tracked_runs: TrackedRuns):
    _started_worker(runners)
    runners.shutdown()

    request_run = tracked_runs.start(for_a_job=False)

    assert tracked_runs.exit_code(request_run, within=STILL_RUNNING_FOR) is None


def test_after_a_plain_stop_and_start_job_runs_start_again(
    runners: Runners, tracked_runs: TrackedRuns
):
    """A database switch (or an `abandon` without a shutdown) refuses nothing."""
    _started_worker(runners)
    runners.stop()
    runners.start()

    job_run = tracked_runs.start(for_a_job=True)

    assert tracked_runs.exit_code(job_run, within=STILL_RUNNING_FOR) is None
