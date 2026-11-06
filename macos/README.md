# Bookshelf.app

A native macOS launcher for this repo: it starts Postgres, the API and the compiled web,
shows the web in its own window, and stops the services when you quit. Design and
decisions: [docs/MACOS_APP.md](../docs/MACOS_APP.md) and
[ADR-001](../docs/adr/ADR-001-native-macos-launcher-for-bookshelf.md). This is phase P1,
plus adding files (§13) and the menu bar icon (§10), both brought forward from P2.

## Build, install, test

```bash
macos/scripts/make-signing-identity.sh   # once: the self-signed "Bookshelf Local" identity in the login keychain
macos/scripts/build-app.sh     # swift build → bundle → placeholder icon → codesign → macos/build/Bookshelf.app
macos/scripts/install-app.sh   # quit the running copy (⌘Q path), ditto to ~/Applications, lsregister, open
macos/scripts/smoke.sh         # build, then launch with env -i … open -n and check start, ⌘Q, Force Quit, SIGINT
cd macos && swift test         # unit tests (Swift Testing), under a second
```

- Signing: the "Bookshelf Local" identity when the login keychain has it, else ad-hoc
  (the build says so). With it, the designated requirement is the certificate, not the
  binary's hash, so macOS keeps the app's permissions across rebuilds (M11).
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
  then the API, within 7 s; the API always keeps 6.2 s of it for its SIGINT step. The app
  also quits this way on SIGTERM. A one-shot step still running (`pg-local.sh start`,
  `astro build`) is not stopped at quit.
- **Web build**: P1 runs `astro build` only when `frontend/dist/server/entry.mjs` is missing,
  or on *Server → Rebuild Web*. Rebuilds on change come with the fingerprints in P2.

## Adding files

All entry points take the same path (docs/MACOS_APP.md §13):

- Drop PDF, EPUB, HTML or Markdown files on the Dock icon, or use *Open With → Bookshelf* in Finder.
- *File → Add to Library…* (⌘O) for one or more files, or drop them onto the window.
- *File → Add Web Article…* (⇧⌘O) for an `http`/`https` address; the API fetches the page.

The app copies each file (it never moves it, and off the main thread) to
`library/inbox/<yyyy-mm>/`, with ` (2)`, ` (3)`… before the extension on a name clash, then
sends `POST /api/documents {"path": "inbox/…"}` through the web's proxy. One new document
opens its page; several open the library. Content already on the shelf (`409`): the app says
so, offers to open it and deletes the copy; any other error also deletes it. With no answer
at all (or the proxy's `502 upstream_unavailable`), the copy is kept (the API may have taken
it) and the alert says where; *Add a book* lists it if it is not on the shelf. Other file
types get a short alert and are not copied. Files that arrive while the services are not
ready wait, uncopied, and go in once they are. Web addresses must be `http`/`https`, without
credentials. Each file gets a line in `app.log` (`[intake]`) with its name and its copy's
path in `library/`; a web article, with its scheme and host only.

Every file dragged onto the window from another app goes to intake, so dropping a snapshot
on the web's restore field no longer works: use that field's button, which opens the panel.
Drags that start in the page stay the page's.

## Menu bar icon

The icon shows the state by its shape (§10): an hourglass while the services start or stop,
empty books when ready, filled books while jobs run, a pause sign when the job queue is
paused, a warning triangle when a service failed. Its tooltip says the same in words. Click
it for the status lines (Database, API, Web, Jobs), *Open Bookshelf*, *Add to Library…*,
*Pause / Resume Job Queue*, *Restart Services* and *Quit Bookshelf*. ⌘-drag moves it, and
macOS keeps its place; there is no setting to hide it until Settings (P2). While the services
are ready, the app reads the job queue every 5 s while jobs run or wait, and every 30 s when
the queue is idle or paused; each read adds a line to `api.log`. A status line longer than 80
characters (a paused queue's reason, say) is cut with "…", here and in the Server menu; the
web shows it whole.

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

`Sources/Bookshelf/`: `App/` (entry point, delegate, menus, intake's panels and alerts, smoke
mode), `Window/` (window, web view and its file drop, loading and error views, navigation
policy), `Supervisor/` (supervisor, guard, spawn, kqueue, stop sequence, ports, readiness),
`Integration/` (intake: file types, inbox copy, API calls, what to show; the menu bar icon
and its job-queue poll), `Environment/` (login PATH, allowlist, tools), `Build/` (state file),
`Support/` (paths, preferences, logs, one-shot commands).
