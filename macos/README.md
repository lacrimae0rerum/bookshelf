# Bookshelf.app

A native macOS launcher for this repo: it starts Postgres, the API and the compiled web,
shows the web in its own window, and stops the services when you quit. Design and
decisions: [docs/MACOS_APP.md](../docs/MACOS_APP.md) and
[ADR-001](../docs/adr/ADR-001-native-macos-launcher-for-bookshelf.md). This is phase P1.

## Build, install, test

```bash
macos/scripts/build-app.sh     # swift build → bundle → placeholder icon → codesign → macos/build/Bookshelf.app
macos/scripts/install-app.sh   # quit the running copy (⌘Q path), ditto to ~/Applications, lsregister, open
macos/scripts/smoke.sh         # build, then launch with env -i … open -n and check start, ⌘Q, Force Quit, SIGINT
cd macos && swift test         # unit tests (Swift Testing), under a second
```

- Signing: the "Bookshelf Local" identity when the login keychain has it, else ad-hoc
  (the build says so). No script creates the identity.
- The smoke test uses a fake `claude` that never answers; it never runs the real one, and
  it never stops Postgres. It refuses to run while Bookshelf runs or 8000/4321 are taken.
- The app reads the repo path that `build-app.sh` writes into Info.plist
  (`BookshelfRepositoryPath`), so build from the checkout you want it to run.

## How it runs

```
Bookshelf (app)
├── scripts/pg-local.sh start                     Postgres, a daemon: it stays after quit
├── Bookshelf --guard <app-pid> -- uv run fastapi run app/main.py --host 127.0.0.1 --port 8000
└── Bookshelf --guard <app-pid> -- node --env-file=.env dist/server/entry.mjs   (HOST, PORT, API_INTERNAL_URL set)
```

- **Guard**: the same binary in a second mode. It leads a process group, runs the command
  and watches the app with kqueue. When the app quits, crashes or is force-quit, or when the
  app sends it SIGTERM, it sends SIGTERM to the command, SIGINT after 5 s, then SIGKILL to
  the group after 1 s more (M8, M9).
- **Environment**: `PATH` from `/bin/zsh -l`, plus an allowlist (`HOME USER LOGNAME SHELL
  TMPDIR LANG LC_*`) and the app's own variables. `BOOKSHELF_CLAUDE_BIN` is the resolved
  `claude`. Nothing else is inherited (M10).
- **Quit**: ⌘Q returns `.terminateLater`, asks before quitting while jobs run, stops the web,
  then the API, within 7 s. The app also quits this way on SIGTERM.
- **Web build**: P1 runs `astro build` only when `frontend/dist/server/entry.mjs` is missing,
  or on *Server → Rebuild Web*. Rebuilds on change come with the fingerprints in P2.

## Files

| Path | Holds |
|---|---|
| `~/Library/Logs/Bookshelf/` | `app.log`, `api.log`, `web.log` (each with its guard's lines), `web-build.log`, `setup.log` |
| `~/Library/Application Support/Bookshelf/` | `state.json` (last PATH capture), `pids/` (one guard pid per service) |

Settings have no window until P2. Keys in the `io.github.lacrimae0rerum.bookshelf` domain:
`RepositoryPath`, `ClaudeBinary`, `KeepDatabaseRunning` (default on), `ConfirmQuitWhileJobsRun`
(on), `ReopenLastPage` (on), `WebInspectorEnabled` (off). Set one for a single launch with
`open -n Bookshelf.app --args -ClaudeBinary /path/to/claude`.

## Code

`Sources/Bookshelf/`: `App/` (entry point, delegate, menus, smoke mode), `Window/` (window,
web view, loading and error views, navigation policy), `Supervisor/` (supervisor, guard,
spawn, kqueue, stop sequence, ports, readiness), `Environment/` (login PATH, allowlist,
tools), `Build/` (state file), `Support/` (paths, preferences, logs, one-shot commands).
