"""Process shutdown: the signal for long-lived responses (SSE streams), and the runner stop.

Uvicorn's graceful shutdown (Ctrl-C, SIGTERM, a `fastapi dev` reload) waits for open
responses before it runs the lifespan shutdown, so a stream that only ends on its own
timer holds the reload for minutes. `install()` (called from the lifespan startup, i.e.
after uvicorn has installed its own handlers) chains SIGINT/SIGTERM so `stopping` is set
the moment shutdown begins; streams check it on every poll and end cleanly. (`fastapi
dev` reloads by sending the server process SIGTERM, so this covers reloads too.)

The signals also wake two callbacks, each on a thread of its own, instead of leaving the
work to the lifespan shutdown:
- `on_shutdown`, on the first signal (the lifespan passes the runners' `shutdown`: jobs
  back to the queue, their `claude` runs killed). Requests keep their runs: uvicorn still
  waits for them, so a `/search/answer` in flight finishes.
- `on_force`, when uvicorn forces the exit (a SIGINT after any earlier signal; the
  SIGTERM a `fastapi dev` reloader sends after a Ctrl-C never counts). Uvicorn then
  drops the open requests, so the lifespan passes `processes.terminate_all`: their runs
  die with them. The handler reads uvicorn's own verdict after calling it: the chained
  handler is `uvicorn.Server.handle_exit` (a bound method), and `Server.force_exit` is
  its flag (uvicorn 0.53; an implementation detail, so `_forced_by` checks it is there).
  Read after every call, the verdict holds however signals nest: a counter of our own
  can see them in another order than uvicorn does. A previous handler without that flag
  (anything but uvicorn) falls back to the rule itself.
The lifespan shutdown may never run: a forced exit skips it, and under `fastapi dev` the
server then re-raises the SIGTERM its reloader sent with the default handler, which kills
the process on the spot. `claude` runs in a session of its own, so no Ctrl-C reaches it:
without these callbacks it would be orphaned and its job left `running` until the lock
went stale.

The race left: the stop needs a few milliseconds (one database round trip to hand the
jobs back, then the kills). Two Ctrl-C less than ~50 ms apart can kill a `fastapi dev`
server before that, with the old outcome.

Nothing the handler runs takes a lock, because the handler can run inside itself:
stopping the process group of `uv run fastapi run` without a terminal (`kill -TERM --
-<pgid>`) gives python the group's signal and `uv` forwards a second one, which can
interrupt the first handler anywhere. A `threading.Event` would block that nested handler
forever on the lock the outer call holds, so uvicorn would never hear of the shutdown.
Hence `ShutdownFlag`, a pipe per callback for the wake-up (one non-blocking `os.write`),
plain attribute reads for uvicorn's verdict, and `itertools.count` for the fallback rule
(`next` is one C call, so a nested handler cannot split it).
"""

import contextlib
import itertools
import logging
import os
import signal
import threading
from collections.abc import Callable
from types import FrameType

logger = logging.getLogger(__name__)


class ShutdownFlag:
    """The `set`/`clear`/`is_set` of `threading.Event` without its lock (and so without
    `wait`): a plain attribute store never blocks, so a signal handler interrupted by
    another signal can set it again safely."""

    def __init__(self) -> None:
        self._is_set = False

    def set(self) -> None:
        self._is_set = True

    def clear(self) -> None:
        self._is_set = False

    def is_set(self) -> bool:
        return self._is_set


stopping = ShutdownFlag()

_SIGNALS = (signal.SIGINT, signal.SIGTERM)


class _OnSignal:
    """Runs `action` once, on a daemon thread, after the first `wake()`.

    The thread blocks reading a pipe; `wake()` (from the signal handler) writes one byte
    to it without blocking and without a lock, however often it is called. `close()`
    waits for an action already started, then frees the thread and both descriptors.
    """

    def __init__(self, action: Callable[[], object], *, name: str) -> None:
        self._read_fd, self._write_fd = os.pipe()
        os.set_blocking(self._write_fd, False)
        self._closed = False
        self._thread = threading.Thread(target=self._run, args=(action,), name=name, daemon=True)
        self._thread.start()

    def wake(self) -> None:
        if self._closed:  # set before the descriptor closes: never write to a reused one
            return
        with contextlib.suppress(OSError):  # a full pipe: a wake-up is already waiting
            os.write(self._write_fd, b"\0")

    def _run(self, action: Callable[[], object]) -> None:
        if not os.read(self._read_fd, 1):  # end of file: closed without a signal
            return
        try:
            action()
        except Exception:  # the lifespan's own cleanup runs it again
            logger.exception("Shutdown cleanup failed", extra={"thread": self._thread.name})

    def close(self) -> None:
        self._closed = True
        os.close(self._write_fd)  # a waiting wake-up byte is still read before end of file
        self._thread.join()
        os.close(self._read_fd)


def _forced_by(handler: object) -> bool | None:
    """Uvicorn's verdict: the `force_exit` of the `Server` whose bound `handle_exit` is
    `handler`, or None when `handler` carries no such flag (not uvicorn)."""
    force_exit = getattr(getattr(handler, "__self__", None), "force_exit", None)
    return force_exit if isinstance(force_exit, bool) else None


def install(
    on_shutdown: Callable[[], object] | None = None, on_force: Callable[[], object] | None = None
) -> Callable[[], None]:
    """Start a fresh run and chain the shutdown signals: the first one also runs
    `on_shutdown`, a forced exit `on_force`, each on a thread of its own. Returns a
    function that restores the previous handlers and waits for a callback in progress.
    Signal handlers can only be set from the main thread (uvicorn); elsewhere (e.g. a test
    client) only the flag is managed, and the callbacks are left to the caller."""
    stopping.clear()
    if threading.current_thread() is not threading.main_thread():
        return lambda: None
    previous = {sig: signal.getsignal(sig) for sig in _SIGNALS}
    signals_seen = itertools.count()
    callbacks = {"shutdown": on_shutdown, "forced": on_force}
    stoppers = {
        when: _OnSignal(action, name=f"{when}-stopper")
        for when, action in callbacks.items()
        if action is not None
    }

    def chained(signum: int, frame: FrameType | None) -> None:
        stopping.set()
        after_another = next(signals_seen) > 0
        if (shutdown := stoppers.get("shutdown")) is not None:
            shutdown.wake()
        handler = previous.get(signal.Signals(signum))
        if callable(handler):
            handler(signum, frame)
        elif handler == signal.SIG_DFL:  # nobody else handles it: behave as before
            signal.signal(signum, signal.SIG_DFL)
            signal.raise_signal(signum)
        verdict = _forced_by(handler)  # after the call: what this very signal decided
        if verdict is None:
            verdict = signum == signal.SIGINT and after_another
        if verdict and (forced := stoppers.get("forced")) is not None:
            forced.wake()

    for sig in _SIGNALS:
        signal.signal(sig, chained)

    def restore() -> None:
        for sig, handler in previous.items():
            signal.signal(sig, handler)
        for stopper in stoppers.values():
            stopper.close()

    return restore
