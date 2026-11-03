"""The API's runners (`app.jobs.runners`): Settings → Database stops and starts them
again; a shutdown stops them for good."""

import pytest

from app.core.config import get_settings
from app.jobs import runners as runners_module
from app.jobs.runners import Runners


class _FakeJobWorker:
    """Stands in for the API's pipeline worker (`runners._job_worker`): no thread, no DB."""

    def __init__(self) -> None:
        self.stopped = False

    def start(self) -> None:
        """Nothing to run."""

    def release(self) -> None:
        """Nothing held to hand back."""

    def stop(self, timeout: float = 0.0, *, abandon: bool = False) -> bool:
        self.stopped = True
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
