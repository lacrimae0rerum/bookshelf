"""The background runners one API process owns, started and stopped together.

The lifespan starts them; switching databases (Settings → Database) stops them, so every
running job goes back to the queue of the database it came from, and starts fresh ones
that claim from the new database. Shutdown stops them for good (`shutdown`): a switch,
sync or restore caught by it must not start them again on its way out.
"""

import logging
import threading

from app.core.config import Settings
from app.jobs.background import BackgroundWorker, stop_all
from app.jobs.build_runner import BuildRunner
from app.jobs.embedded import EmbedRunner
from app.jobs.narration import NarrateRunner
from app.jobs.steering import own_slot_kinds
from app.jobs.worker import Worker, autodiscover

logger = logging.getLogger(__name__)


def _job_worker(settings: Settings) -> BackgroundWorker | None:
    """The API's own pipeline worker (`app.jobs.background`): every kind with a handler,
    except `embed` while embedded Qdrant's runner owns it, and `narrate` and `build_run`,
    which run on slots of their own (`app.jobs.narration`, `app.jobs.build_runner`)."""
    if not settings.api_worker:
        return None
    autodiscover()
    worker = Worker(exclude=own_slot_kinds(settings), label="api")
    return BackgroundWorker(worker, name="job-worker")


class Runners:
    def __init__(self, settings: Settings) -> None:
        self._settings = settings
        self._lock = threading.Lock()
        self.embed: EmbedRunner | None = None
        self.narrate: NarrateRunner | None = None
        self.build: BuildRunner | None = None
        self.jobs: BackgroundWorker | None = None
        self._shut_down = False

    def start(self) -> None:
        """Start the configured runners; nothing after `shutdown`."""
        settings = self._settings
        with self._lock:
            if self._shut_down:
                return
            if settings.qdrant_url is None and settings.api_embed_runner:
                self.embed = EmbedRunner()
                self.embed.start()
            if settings.api_narrate_runner:
                self.narrate = NarrateRunner()
                self.narrate.start()
            if settings.api_build_runner:
                self.build = BuildRunner()
                self.build.start()
            self.jobs = _job_worker(settings)
            if self.jobs is not None:
                self.jobs.start()

    def stop(self) -> None:
        """Hand running jobs back to their queue; their `claude` runs are killed (not a
        request's: `app.pipeline.processes`). A build's agent is not: it runs detached,
        and the next claim of its job attaches. Idempotent and safe from any thread."""
        with self._lock:
            self._stop_locked()

    def shutdown(self) -> None:
        """`stop` for good: the process is going away, so `start` does nothing after it."""
        with self._lock:
            self._shut_down = True
            self._stop_locked()

    def _stop_locked(self) -> None:
        stop_all([self.jobs, self.narrate, self.build])
        if self.embed is not None:
            self.embed.stop()
        self.embed = self.narrate = self.build = self.jobs = None
