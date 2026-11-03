# Bookshelf for macOS — a native launcher

**Status**: accepted; P0 and P1 done, P2 next · **Date**: 2026-11-03 · **Extends**: [ARCHITECTURE.md](ARCHITECTURE.md) · **Decision**: [ADR-001](adr/ADR-001-native-macos-launcher-for-bookshelf.md)

`Bookshelf.app` is a small native app for one Mac. Opening it starts the three local services
(Postgres, the FastAPI API, the Astro server), shows the web UI in its own window, and stops
the services when you quit. It adds what a browser tab cannot: a Dock icon you can drop files
on, a menu bar icon with the service state, native menus and shortcuts, notifications when
jobs finish, and one place that says what failed and why.

It is a **launcher, not a bundle**. The runtimes stay where they are (uv, Node, pnpm,
Homebrew Postgres, the `claude` CLI); the app supervises the repository you already run.

**Not in scope**: distribution, the App Store, notarization, other users or Macs, bundling
Python/Node/Postgres, and any change to the web UI's features.

Facts marked **(measured)** come from disposable prototypes run on this Mac (macOS 27.0.1,
Apple M5 Max, Swift 6.4.2, SDK 27.2). Facts marked **(unverified)** are open; see §22.

---

## 1. Decisions

| # | Decision | Rationale | Consequence |
|---|---|---|---|
| M1 | **A launcher that supervises the repo's services** | Nothing to bundle or keep in sync; the app runs exactly the code in the repo | The app needs the repo path and the dev tools installed. It cannot be given to someone else as is |
| M2 | **AppKit lifecycle; SwiftUI only inside the Settings window** | Close ≠ quit, reopen from the Dock, frame autosave and the title bar all need the `NSWindow`; AppKit gives them directly | `main.swift` + `NSApplicationDelegate`, menus built in code, `NSHostingController` for Settings |
| M3 | **`WKWebView`, not SwiftUI `WebView`** | In SDK 27.2 the SwiftUI `WebView`/`WebPage` has no download API, no `window.open` hook, no `pageZoom`, no printing, and its media playback behaviour is unavailable on macOS | One `WKWebView` in a view controller, with its navigation and UI delegates |
| M4 | **SwiftPM executable + a bundle script; no `.xcodeproj`** | Plain text, reviewable, `swift build` from a terminal | No App Intents (they need Xcode's metadata extraction). Automation uses a URL scheme and AppleScript (§15) |
| M5 | **Compiled web, not `pnpm dev`** | `node dist/server/entry.mjs` answers in 0.12 s **(measured)**; `astro dev` daemonizes itself when `CLAUDECODE=1` is in the environment and then escapes group signals **(measured)** | Rebuild with `astro build` (2.3 s **(measured)**) when the frontend changed (§6). A development mode is a later option |
| M6 | **Loopback by IP: `127.0.0.1` everywhere** | `localhost` can resolve to `::1` first while the API binds `127.0.0.1`; one address removes the ambiguity | The app sets `HOST`, `PORT` and `API_INTERNAL_URL` for the web server and loads `http://127.0.0.1:4321` |
| M7 | **The API and the web run only while the app runs; Postgres stays up** | No background load from the app's services when you are not using it; no LaunchAgents to maintain. Postgres is a small daemon and keeping it saves a step at launch | *Keep the database running after quit* is on by default (§12); switch it off to stop Postgres too |
| M8 | **Each service in its own process group, watched by a guard** | Force Quit (SIGKILL) skips every cleanup; without a guard the API and its children keep running **(measured)** | The app re-runs itself as `Bookshelf --guard <app-pid> -- <command>`: a kqueue `NOTE_EXIT` watcher that kills the group when the app dies (cleanup in ~280 ms **(measured)**) |
| M9 | **Stop a service with SIGTERM to its command, then SIGINT, then SIGKILL the group** | SIGTERM to the whole group used to hang the API (fixed in P0). The API's `claude` runs live in sessions of their own, so a SIGKILL to the group never reaches them: the API must end them itself. Its first SIGTERM stops the jobs' runs at once; a SIGINT after it is uvicorn's forced exit, on which the API also kills the requests' runs (P0) | The app signals the guard; the guard sends SIGTERM to its direct child (`uv`, `node`) only; after 5 s, SIGINT (forced exit); after 1 s more, SIGKILL to the group |
| M10 | **The environment is built, never inherited** | GUI apps get launchd's `PATH=/usr/bin:/bin:/usr/sbin:/sbin` **(measured)**; an app opened from a terminal inherits that shell's variables, `CLAUDECODE` included **(measured)** | Capture `PATH` from `/bin/zsh -l -c` (29–34 ms **(measured)**), then pass an allowlist of variables (§5) |
| M11 | **A stable signing identity, not ad-hoc** | An ad-hoc signature's designated requirement is the binary's hash (TN3127), so every rebuild looks like a new app to TCC, notifications and login items | A free self-signed "Bookshelf Local" code-signing certificate in the login keychain. Ad-hoc stays the fallback |
| M12 | **No sandbox, no hardened runtime, no entitlements** | The app must spawn tools in `~/.local`, `/opt/homebrew` and the repo; the sandbox would pass to the children | Nothing to configure. Only notarization would need the hardened runtime |
| M13 | **One origin in the window; everything else opens in the browser** | The window is the app, not a browser; a link to the open web should not replace it | Navigation policy allows `http://127.0.0.1:4321` only. `target=_blank` and `window.open` to other origins go to the default browser |
| M14 | **Dropped files are copied into `library/` by the app** | The ingest API takes paths inside `library/` only; the app's own process holds the user's intent to read from Downloads or Documents, so no child triggers a privacy prompt | Copy to `library/inbox/<yyyy-mm>/`, then `POST /documents {path}` (§13) |
| M15 | **No JavaScript bridge in v1** | A bridge gives any script in the page native powers; everything the app needs is in the HTTP API | Status, badges and notifications read the API (`/jobs/queue`, `/jobs/stream`) |
| M16 | **The menu bar icon is optional; the Dock menu has the same actions** | macOS can hide status items when the menu bar is full | A setting, on by default |
| M17 | **Automation by URL scheme first, AppleScript second** | `bookshelf://` works from `open`, Shortcuts ("Open URL") and scripts with no extra machinery | Actions that cost tokens (adding a URL) ask for confirmation, since any web page can open the scheme |
| M18 | **Bundle id `io.github.lacrimae0rerum.bookshelf`, never changed** | The WebKit data store, preferences, notification permission and TCC grants are keyed to it | Chosen once; recorded in Info.plist |

---

## 2. Shape

```
Bookshelf.app (AppKit)
├── Supervisor ──┬── scripts/pg-local.sh start ─► postgres (daemon, .pgdata/, 127.0.0.1:54329)
│                ├── guard ─► uv run fastapi run app/main.py   (127.0.0.1:8000)
│                │               └── job worker thread ─► claude -p … (own group, killed on stop)
│                │               └── builds, narrations: detached by design, survive the API
│                └── guard ─► node dist/server/entry.mjs        (127.0.0.1:4321)
├── Main window ── WKWebView ─► http://127.0.0.1:4321 ─► /api proxy ─► API ─► Postgres
├── Status item, Dock menu, notifications ─► API: /health/ready, /jobs/queue, /jobs/stream
└── Intake (Dock, Finder, ⌘O, drop) ─► copy into library/inbox/ ─► POST /api/v1/documents
```

State lives in three places, all outside the repo:

| Path | Holds |
|---|---|
| `~/Library/Application Support/Bookshelf/` | `state.json` (fingerprints, last PATH capture), `pids/` (one file per service) |
| `~/Library/Logs/Bookshelf/` | `app.log`, `api.log`, `web.log`, `web-build.log`, `setup.log` |
| `UserDefaults` (bundle id) | Settings (§12), window frame, last page, zoom |

---

## 3. Start and stop

### Start

```
launch ─► resolve repo ─► capture PATH ─► check tools ─► reconcile stale pids ─► check ports
      ─► Postgres start ─┬─► [uv.lock changed] uv sync ─► [migrations changed] migrate ─► API ─► /health/ready
                         └─► [lockfile changed] pnpm install ─► [frontend changed] astro build ─► web ─► GET /
      ─► both ready ─► load last page ─► first paint ─► show the page
```

- The window opens at once with a **native loading view** in the app's paper colour: the
  Bookshelf mark and one line per step ("Database", "API", "Web") with a spinner, a check or
  a cross. The web view stays hidden until its first `didFinish`, so there is no white flash.
- The two branches run in parallel. Steps in brackets run only when their fingerprint
  changed (§6), so a warm start is Postgres + API + web: about 1.5–2.5 s (API 0.9–1.2 s and
  web 0.12 s **(measured)**; Postgres start **(unverified)**).
- A step that fails stops the start and turns the loading view into the error view (§17).

### Stop (⌘Q, Quit in any menu, logout)

1. `applicationShouldTerminate` returns `.terminateLater`.
2. Ask `GET /jobs/queue` (1 s timeout). If jobs are running and *Confirm quit while jobs run*
   is on, show a sheet: "2 jobs are running. Quit anyway? They go back to the queue and run
   again next time." Buttons **Quit** / **Cancel**, with *Don't ask again*. Builds and
   narrations are not counted: they run detached by design and continue after quit.
3. Stop the web server, then the API (M9): the app sends SIGTERM to the guard; the guard
   sends SIGTERM to its command only. The API hands the jobs back and kills their runs at
   once; uvicorn then waits for open requests (a `/search/answer` can take up to 180 s).
   After 5 s the guard sends SIGINT: uvicorn forces the exit and the API kills every run
   left, the requests' too. After 1 s more, SIGKILL to the group. With no request open, the
   stop takes 0.2–0.3 s and leaves no `claude` behind **(measured)**. With a
   `/search/answer` open, uvicorn waits, the SIGINT at 5 s ends the answer's `claude`,
   and the app quits after 5.3–5.4 s with nothing left **(measured, P1 smoke)**.
4. Postgres keeps running (the default). With *Keep the database running after quit* off:
   `scripts/pg-local.sh stop` (`pg_ctl -w stop`, fast mode).
5. `reply(toApplicationShouldTerminate: true)`. Total budget 7 s; after that, kill and quit.

On logout or shutdown (`NSWorkspace.willPowerOffNotification`) the app skips the dialog.
The Info.plist must **not** set `NSSupportsSuddenTermination` or
`NSSupportsAutomaticTermination`: either lets macOS kill the app without asking the delegate.

### Crash or Force Quit

The guards see the app's pid exit and kill their groups. Postgres is a daemon
(`pg_ctl start`), so it stays; the next launch reuses it. At start, the app reads `pids/`:
a recorded pid that is alive, listens on our port and whose executable lives under the repo
or the known tool paths is ours and is stopped. Anything else on the port is foreign (§17).

---

## 4. Services

| Service | Command (cwd) | Ready when | Stop |
|---|---|---|---|
| Postgres | `scripts/pg-local.sh start` (repo) | the script exits 0 and port 54329 accepts | `scripts/pg-local.sh stop` |
| Backend deps | `uv sync` (`backend/`) | exit 0 | — |
| Migrations | `uv run python -m app.db.migrate` (`backend/`) | exit 0 | — |
| API | `uv run fastapi run app/main.py --host 127.0.0.1 --port 8000` (`backend/`) | `GET /health/ready` is 200 | guard: SIGTERM to the command → 5 s → SIGINT → 1 s → SIGKILL group |
| Frontend deps | `pnpm install --frozen-lockfile` (`frontend/`) | exit 0 | — |
| Web build | `pnpm exec astro build` (`frontend/`) | exit 0 | — |
| Web | `node --env-file=.env dist/server/entry.mjs` (`frontend/`), with `HOST=127.0.0.1 PORT=4321 API_INTERNAL_URL=http://127.0.0.1:8000/api/v1` | `GET /` is 200 | guard: SIGTERM to the command → 5 s → SIGINT → 1 s → SIGKILL group |

- `astro build` skips the 19 s `astro check` that `pnpm build` runs **(measured)**; type
  checking stays in the developer workflow, not in a launch.
- Health monitor: every 5 s, `GET /health` and `GET /`. A dead service restarts after 1 s,
  3 s, then 10 s; after 3 failures in 5 minutes it stays down and the app shows the error
  state. After sleep (`NSWorkspace.didWakeNotification`), the monitor checks at once.
- While services run, the app holds `ProcessInfo.beginActivity(.userInitiatedAllowingIdleSystemSleep)`
  so App Nap does not slow the API when the window is hidden. Children get
  `qualityOfService = .userInitiated`.

---

## 5. Environment

1. **PATH**: run `/bin/zsh -l -c 'print -rn -- "$PATH"'` with stdin from `/dev/null`, a
   minimal environment (`HOME USER LOGNAME SHELL TMPDIR LANG`) and a 5 s timeout. On this
   Mac `~/.zprofile` puts `~/.local/bin` on the path, so a login shell is enough; `-i` is
   twice as slow and not needed **(measured)**. Cache the result in `state.json`; Settings
   has a *Refresh* button and an override field.
2. **Allowlist** passed to every child: `PATH HOME USER LOGNAME SHELL TMPDIR LANG LC_*`,
   plus the variables the app sets itself (`HOST`, `PORT`, `API_INTERNAL_URL`,
   `BOOKSHELF_CLAUDE_BIN`). Nothing else is inherited: not `CLAUDECODE`, not `AI_AGENT`, not
   a terminal's variables.
3. **Tools**: resolve `uv`, `node`, `pnpm`, `claude` and the Postgres binaries on that PATH
   and record their absolute paths and versions (Settings → Advanced). `pnpm` is a Node
   script (`#!/usr/bin/env node`), so `node` must be on the PATH even when `pnpm` is called by
   absolute path **(measured)**. `BOOKSHELF_CLAUDE_BIN` is set to the absolute `claude` path.
4. Backend and frontend settings still come from `backend/.env` and `frontend/.env`. The app
   overrides only what §4 lists.

---

## 6. Rebuilds

The app keeps one fingerprint per derived artifact in `state.json` and redoes the step only
when the fingerprint changed:

| Step | Fingerprint |
|---|---|
| `uv sync` | sha256 of `backend/uv.lock` and `backend/pyproject.toml` |
| migrate | sha256 of the sorted file names and contents under `supabase/migrations/` |
| `pnpm install` | sha256 of `frontend/pnpm-lock.yaml` and `frontend/package.json` |
| `astro build` | tree id of `frontend` at `HEAD` + sha of `git diff --binary HEAD -- frontend` + untracked, non-ignored files + `frontend/.env` + `node_modules/.modules.yaml` + `node --version` |

- The web fingerprint takes 74 ms **(measured)**. All git calls use `--no-optional-locks`
  so they never write `.git/index`.
- It changes on every edit, even a second edit of an already modified file (a hash of
  `git status` does not), and it ignores commits that touch only the backend **(measured)**.
- *Server → Rebuild Web* forces a build. A failed build shows its log and keeps the
  previous `dist/` untouched only if the build writes elsewhere first **(unverified)**; until
  that is checked, a failed build means the web cannot start.

---

## 7. The window

- **One main window**, `NSWindowController` + `WKWebView`. Native tabs off:
  `NSWindow.allowsAutomaticWindowTabbing = false` before any window exists, and
  `tabbingMode = .disallowed`.
- **Size**: default 1280 × 860, centred on first launch; minimum 900 × 600;
  `setFrameAutosaveName("BookshelfMain")` keeps size and position per screen setup. Full
  screen works as usual (green button, ⌃⌘F).
- **Title bar**: the standard one, with the page title (`webView.title`, for example
  "Today — Bookshelf") and no toolbar, since the web UI has its own navigation. Back and
  forward use the trackpad swipe (`allowsBackForwardNavigationGestures`) and ⌘[ / ⌘].
  A full-bleed variant (`.fullSizeContentView`, transparent title bar,
  `webView.obscuredContentInsets` for the traffic lights) is a later polish.
- **Close is not quit**: the red button and ⌘W hide the window (`orderOut`); the web view,
  its scroll position and any narration that is playing stay alive. A Dock click, the menu
  bar icon or `bookshelf://open` shows it again (`applicationShouldHandleReopen`).
  `applicationShouldTerminateAfterLastWindowClosed` returns `false`.
- **Last page**: saved on every same-origin navigation and restored at launch. At quit the
  app also saves `webView.interactionState` (history and scroll) and restores it next time.
  System window restoration is off (`isRestorable = false`) so there is one mechanism.
- **Appearance**: follows the system. The web already uses `prefers-color-scheme`. The
  window and the loading view use the paper colour (`#f3f4f0` light, `#14171c` dark), also
  set as `underPageBackgroundColor`.
- **Zoom**: ⌘+, ⌘-, ⌘0 set `pageZoom` (persisted). Pinch zoom is on (`allowsMagnification`).
- **Find**: ⌘F, ⌘G, ⇧⌘G, ⌘E through `NSTextFinder` (`WKWebView` is a text-finder client).
  If the find bar does not appear **(unverified)**, fall back to `find(_:configuration:)`
  with a small native bar.
- **Print**: ⌘P through `printOperation(with:)` (blank-page risk **(unverified)**).
- **Media**: `mediaTypesRequiringUserActionForPlayback = []` so narrations play without an
  extra click.
- **Downloads** (exports, snapshots): when the response is an attachment or a type WebKit
  cannot show, the navigation becomes a `WKDownload`; the app asks where to save with an
  `NSSavePanel`, defaulting to `~/Downloads`.
- **File inputs** (`<input type=file>`, used by snapshot restore): `runOpenPanelWith`
  shows an `NSOpenPanel`. Without it, WebKit cancels the input.
- **Web content crash** (`webViewWebContentProcessDidTerminate`): reload once at once; a
  second crash within a minute shows a banner with *Reload*.
- **Web Inspector**: `isInspectable` behind a Settings switch; it opens from Safari's
  Develop menu.

---

## 8. Menus and shortcuts

Shortcuts the web already uses stay with the web: **⌘K** (search) and **⌘↩** (submit).

| Menu | Items |
|---|---|
| **Bookshelf** | About Bookshelf · Settings… ⌘, · Services ▸ · Hide ⌘H · Hide Others ⌥⌘H · Show All · Quit ⌘Q |
| **File** | Add to Library… ⌘O · Add Web Article… ⇧⌘O · Close Window ⌘W · Print… ⌘P |
| **Edit** | Undo ⌘Z · Redo ⇧⌘Z · Cut ⌘X · Copy ⌘C · Paste ⌘V · Select All ⌘A · Find ▸ (⌘F, ⌘G, ⇧⌘G, ⌘E) |
| **View** | Reload ⌘R · Actual Size ⌘0 · Zoom In ⌘+ · Zoom Out ⌘- · Enter Full Screen ⌃⌘F · Web Inspector ⌥⌘I (when enabled) |
| **Go** | Back ⌘[ · Forward ⌘] · Today ⌘1 · Library ⌘2 · Papers ⌘3 · Pills ⌘4 · Review ⌘5 · Pipeline ⌘6 · Shelf Settings (the web's `/settings`) |
| **Server** | Status lines (Database, API, Web, Jobs) · Restart Services ⌥⌘R · Restart API · Rebuild Web · Pause / Resume Job Queue · Reveal Library in Finder · Open API Docs (browser) · Show Logs |
| **Window** | Minimize ⌘M · Zoom · Bring All to Front |
| **Help** | Bookshelf README · Show Logs |

- The **Edit** menu is required: without it, ⌘C and ⌘V do nothing in a `WKWebView`.
- The menu is called **Server**, not "Services", which is the system submenu.
- *Pause / Resume Job Queue* calls `PATCH /jobs/queue`.

---

## 9. Dock

- **Icon**: the app icon (§11).
- **Menu** (`applicationDockMenu`): a status line ("Ready · 2 jobs running") · Open Bookshelf
  · Add to Library… · Pause / Resume Job Queue · Restart Services.
- **Drop files on the icon**: `CFBundleDocumentTypes` for PDF (`com.adobe.pdf`), EPUB
  (`org.idpf.epub-container`), HTML (`public.html`) and Markdown
  (`net.daringfireball.markdown`), role *Viewer*, rank *Alternate*, so Bookshelf appears in
  *Open With* without becoming the default app. Files arrive in `application(_:open:)` and
  go to intake (§13).
- **Badge**: off, or the number of running jobs (setting). `dockTile.badgeLabel`; whether it
  needs notification permission is **(unverified)**.
- **Attention**: a failure while the app is in the background bounces the icon once
  (`requestUserAttention(.informationalRequest)`).

---

## 10. Menu bar icon (the mini icon)

- `NSStatusItem` with an SF Symbol as a **template image**, so macOS tints it for light,
  dark and tinted menu bars. State is shown by **shape, never colour**:

| State | Symbol |
|---|---|
| Starting / restarting | `hourglass` |
| Ready, nothing running | `books.vertical` |
| Ready, jobs running | `books.vertical.fill` |
| Queue paused | `pause.circle` |
| Error | `exclamationmark.triangle.fill` |

  (`books.vertical`, `hourglass` and `exclamationmark.triangle.fill` checked in the SDK as
  template images **(measured)**; the other two to check.)
- **Tooltip** and `accessibilityDescription` say the state in words: "Bookshelf — ready, 2
  jobs running".
- **Click** opens a menu, not a popover: status lines (Database ✓, API ✓, Web ✓, Jobs: 2
  running · 5 queued) · Open Bookshelf · Add to Library… · Pause / Resume Job Queue ·
  Restart Services · Settings… · Quit Bookshelf.
- A custom glyph (a book spine, black on transparent, 18 × 18 pt canvas, template) can
  replace the symbol later.
- **Optional menu-bar-only mode** (setting, off): when the window closes, the app switches
  to `.accessory` (no Dock icon); reopening switches back to `.regular`.

---

## 11. App icon

- **Format**: an Icon Composer document, `macos/Resources/AppIcon.icon` (Icon Composer
  ships inside Xcode). Layered artwork on a 1024 × 1024 px square canvas without a mask, at
  most four groups; macOS renders the Liquid Glass, dark, tinted and clear variants.
- **Artwork**: three book spines leaning against each other, in paper white (`#f3f4f0`) on
  the accent indigo (`#22348c`), with the spines as separate layers so the glass gives them
  depth. Dark appearance: indigo `#a9b8ff` spines on `#14171c`.
- **Compile without the Xcode UI** **(measured)**:
  `xcrun actool AppIcon.icon --compile <Resources> --app-icon AppIcon --platform macosx --target-device mac --minimum-deployment-target 26.0 --output-partial-info-plist icon.plist`.
  It writes `Assets.car` (light, dark and tintable) and an `AppIcon.icns` fallback; the
  partial plist adds `CFBundleIconName` and `CFBundleIconFile`.
- A plain `.icns` alone is rejected: macOS 26+ would put it in a generic rounded square.
- After a rebuild the Dock may keep the old icon **(unverified)**; `install-app.sh`
  re-registers the app with `lsregister -f`.

---

## 12. Settings (⌘,)

A native window with four panes (toolbar tabs). These are settings for the app shell; the
web's own settings (look, reading) stay in the web, under *Go → Shelf Settings*.

| Pane | Setting | Default |
|---|---|---|
| **General** | Repository folder (validated: `backend/`, `frontend/`, `scripts/pg-local.sh`) | the repo that built the app |
| | Open at login (`SMAppService.mainApp`) | off |
| | Show in menu bar | on |
| | Hide the Dock icon when the window is closed | off |
| | Reopen the last page | on |
| | Dock badge: Off / Running jobs | Off |
| **Services** | Keep the database running after quit | on |
| | Confirm quit while jobs run | on |
| | Restart services that stop | on |
| | Rebuild the web when the frontend changes · *Rebuild Now* | on |
| | Ports (read-only in v1): Postgres 54329, API 8000, Web 4321 | — |
| **Notifications** | A job failed · The queue paused itself (usage limit) · A build finished · Every job finished | on · on · on · off |
| | Permission state and *Open System Settings* | — |
| **Advanced** | Captured PATH (read-only) · *Refresh* · override | — |
| | Detected tools with path and version (uv, node, pnpm, claude, Postgres) | — |
| | Enable Web Inspector | off |
| | *Reveal Logs* · *Copy Diagnostics* | — |

- *Open at login* registers on demand; if macOS answers `.requiresApproval`, the app opens
  *System Settings → Login Items*.
- Settings live in `UserDefaults`; Settings changes that touch services ask to restart them.

---

## 13. Adding files

Entry points: drop on the Dock icon, *Open With → Bookshelf* in Finder, *File → Add to
Library…* (⌘O), drop onto the window, and `bookshelf://add`.

1. Accept `.pdf .epub .html .htm .md`; anything else gets a short alert.
2. Copy (never move) into `library/inbox/<yyyy-mm>/<name>`; on a name clash add ` (2)`.
3. `POST /api/v1/documents` with `{"path": "inbox/<yyyy-mm>/<name>"}` (relative to
   `library/`, as the API requires).
4. `202`: open the new document's page if the window is in front, otherwise notify. `409`
   (same content already on the shelf): say so and offer to open the existing document;
   delete the copy.
5. *Add Web Article…* (⇧⌘O) asks for a URL and sends `{"url": …}`.

Drops onto the window: WebKit would navigate to `file://` when the page does not handle
the drop. A `WKWebView` subclass takes file drags in `performDragOperation` and sends them to
intake; the navigation policy also cancels any `file://` navigation **(unverified)**.

---

## 14. Notifications

- Source: `GET /api/v1/jobs/stream?max_seconds=3600` (SSE), reopened when it ends or drops.
- Events: a job failed; the queue paused itself (with the reason, for example the usage
  limit and when it resets); a build finished; optionally every finished job.
- Shown only when the window is not in front, except failures. Clicking one opens the
  window at the related document or job.
- Permission is asked the first time a notification setting is switched on, not at launch.
  That a self-signed app can request it on macOS 27 is **(unverified)**.

---

## 15. Automation

**URL scheme** (`CFBundleURLTypes`, `bookshelf`):

| URL | Does |
|---|---|
| `bookshelf://open` | shows the window |
| `bookshelf://open?path=/library` | shows the window at that path (must start with `/`; same origin only) |
| `bookshelf://reload` | reloads the page |
| `bookshelf://add?url=https://…` | asks for confirmation, then ingests the article |
| `bookshelf://restart` | asks for confirmation, then restarts the services |

Commands are idempotent; anything that costs tokens or stops work asks first, because any
web page can open a `bookshelf://` URL.

**Terminal and Shortcuts**, with no extra code:

```bash
open -a Bookshelf paper.pdf              # add a file (document types, §9)
open 'bookshelf://open?path=/review'     # jump to a page
```

Shortcuts uses its *Open URL* action with the same URLs.

**AppleScript** (phase 3): a small `Bookshelf.sdef` (`NSAppleScriptEnabled`,
`OSAScriptingDefinition`) with `add file`, `add url`, `restart services` and a read-only
`status` property:

```bash
osascript -e 'tell application "Bookshelf" to get status'      # "ready, 2 jobs running"
osascript -e 'tell application "Bookshelf" to add file POSIX file "/Users/me/x.pdf"'
```

The first `osascript` call from a terminal makes macOS ask for Automation permission for
that terminal.

---

## 16. Logs and diagnostics

- `~/Library/Logs/Bookshelf/`: `app.log` (supervisor, intake, errors), `api.log` (the API's
  JSON lines), `web.log`, `web-build.log`, `setup.log` (uv sync, migrate, pnpm install).
  Postgres keeps its own `.pgdata/server.log`. Files rotate at launch above 10 MB, three kept.
- The app also logs through `os.Logger` (subsystem = bundle id; categories `supervisor`,
  `window`, `intake`), visible in Console.app.
- *Copy Diagnostics* puts on the clipboard: app version and commit, macOS version, repo
  path, captured PATH, tool versions, ports and their owners, service states, and the last
  20 lines of each log.

---

## 17. Failures

| Failure | Detected by | Shown as | Way out |
|---|---|---|---|
| Repo folder missing or moved | validation at launch | first-run sheet | choose the folder |
| A tool is missing (uv, node, pnpm, Postgres) | tool resolution | error view with the missing tool | the install command, for example `brew install postgresql@17`; *Retry* |
| `claude` missing or not logged in | tool resolution | warning in the status menu; services still start | model jobs fail until fixed |
| A port is held by another program | `lsof`-style owner check | error view naming the program and pid | quit it, *Retry* |
| A port is held by our stale process | pid file + executable path | nothing (logged) | the app stops it and goes on |
| Postgres does not start | script exit code | error view + tail of `server.log` | *Show Log*, *Retry* |
| `uv sync`, migrate, `pnpm install` or the web build fails | exit code | error view + log tail | *Show Log*, *Retry* |
| A service dies while running | health monitor | status icon ⚠ + banner in the window | automatic restart (1 s, 3 s, 10 s), then manual |
| The web content process crashes | WebKit delegate | reload, then banner | *Reload* |

The error view replaces the loading view: what failed, in one sentence; the last lines of
the relevant log; buttons *Retry*, *Show Log*, *Settings*, *Quit*.

---

## 18. Build, sign, install

```bash
macos/scripts/make-signing-identity.sh   # once: self-signed "Bookshelf Local" code-signing cert
macos/scripts/build-app.sh               # swift build → bundle → actool → codesign → build/Bookshelf.app
macos/scripts/install-app.sh             # quit the running app, ditto to ~/Applications, lsregister, open
```

- `build-app.sh`: `swift build -c release`, then assemble `Contents/MacOS/Bookshelf`,
  `Contents/Info.plist`, `Contents/Resources/` (compiled icon, sdef). SwiftPM's
  `Bundle.module` puts resources in a separate bundle, so the script copies them to
  `Contents/Resources` itself. Sign the finished bundle: `codesign --force --sign "Bookshelf
  Local" build/Bookshelf.app`; check with `codesign -d -r-`.
- The certificate is made once in *Keychain Access → Certificate Assistant → Create a
  Certificate…* (type *Code Signing*) or by the script. Without it, the script signs ad-hoc
  (`--sign -`) and warns that permissions may be asked again after each rebuild.
- Locally built apps carry no quarantine attribute, so Gatekeeper does not intervene.
- Install in `~/Applications` (no admin rights).

**Info.plist**: `CFBundleIdentifier`, `CFBundleName`/`CFBundleDisplayName` "Bookshelf",
`CFBundleExecutable`, `CFBundlePackageType` `APPL`, `CFBundleShortVersionString` (the
backend version), `CFBundleVersion` (commit count), `LSMinimumSystemVersion` `26.0`,
`CFBundleIconName`/`CFBundleIconFile` `AppIcon`, `NSPrincipalClass` `NSApplication`,
`NSAppTransportSecurity` → `NSAllowsLocalNetworking` `true` (loopback loads even without it
**(measured)**; the key states the intent and covers `URLSession` health checks),
`CFBundleDocumentTypes`, `CFBundleURLTypes`, `LSApplicationCategoryType`
`public.app-category.education`, `BookshelfRepositoryPath` (written by the build script),
and in phase 3 `NSAppleScriptEnabled` + `OSAScriptingDefinition`.

---

## 19. Code layout

```
macos/
├── Package.swift                 executable target "Bookshelf", macOS 26+
├── Sources/Bookshelf/
│   ├── App/                      main.swift, AppDelegate, MainMenu, DockMenu
│   ├── Window/                   MainWindowController, WebViewController, LoadingView, ErrorView
│   ├── Supervisor/               Supervisor, Service, ProcessGroup, Guard, Ports, HealthMonitor
│   ├── Environment/              ShellPath, ToolResolver, ChildEnvironment
│   ├── Build/                    Fingerprints, StateStore
│   ├── Integration/              StatusItem, Intake, URLRouter, Notifications, JobStream, Scripting
│   ├── Settings/                 SettingsWindowController, panes (SwiftUI), Preferences
│   └── Support/                  Log, Paths, Diagnostics
├── Resources/                    Info.plist, AppIcon.icon/, Bookshelf.sdef
├── Tests/BookshelfTests/         Swift Testing
└── scripts/                      build-app.sh, install-app.sh, make-signing-identity.sh, smoke.sh
```

- One binary, two modes: `Bookshelf` (the app) and `Bookshelf --guard <pid> -- <command…>`
  (the guard: becomes the group leader, runs the command, watches the app's pid with kqueue
  `EVFILT_PROC`/`NOTE_EXIT`, checks `kill(pid, 0)` after registering to close the race, and
  kills its group when the app is gone).
- Every file stays under 400 lines (CLAUDE.md).

---

## 20. Tests

- **Unit** (Swift Testing, `swift test` in `macos/`, in the toolchain, no new dependency):
  fingerprints, PATH capture parsing, the child-environment allowlist, the URL router and
  its origin checks, port-owner parsing, intake naming and the `409` path. Fast and
  deterministic: no real services.
- **Smoke** (`macos/scripts/smoke.sh`): build, launch with a launchd-like environment
  (`env -i … open -n`) and `--smoke`, which starts the services, waits for ready, quits, and
  exits non-zero if anything still listens on 8000 or 4321. A second run sends SIGKILL to the
  app and checks that the guards clean up.
- **Manual UAT**: the checklist in §21, phase by phase.

---

## 21. Phases

| Phase | Delivers | Done when |
|---|---|---|
| **P0** prerequisites — **done** (2026-11-03) | The API's shutdown, made safe for a supervisor: the signal handler never blocks (`b28ae80`); the first signal stops the jobs' runs and a forced exit the requests' too (`d782745`); job runs that start after that are refused (`d39b8cc`). Also the `scripts/pg-local.sh` comment (`224f831`) and a flaky catalogue test (`e9af837`) | Met: 0 of 32 group SIGTERMs hang (6 of 16 before); one SIGTERM stops the API in 0.2 s with no `claude` left (5 s, SIGKILL and 2 orphans before) |
| **P1** core — **done** (2026-11-03) | Supervisor, guards, environment, loading and error views, window, menus, quit flow, logs, build/sign/install scripts, a placeholder icon. Ad-hoc signed until the "Bookshelf Local" identity exists. The web is built only when `dist/` is missing or on *Rebuild Web* (fingerprints: P2) | Met (`macos/scripts/smoke.sh`, `env -i … open -n`, fake `claude`): page shown 1.5–1.7 s after `open` warm; ⌘Q leaves nothing on 8000/4321; SIGKILL to the app frees them in 0.09–0.17 s and, with an answer open, its `claude` ends at the SIGINT step (5.3 s), no orphans. Known gap: a `pg-local.sh start` or `astro build` still running at quit is not stopped |
| **P2** integration | Menu bar icon, Dock menu and badge, intake (Dock, Finder, ⌘O, window drop), notifications, Settings, fingerprints and rebuilds, restarts, sleep/wake | A PDF dropped on the Dock icon appears on the shelf; a failed job notifies; a frontend edit triggers a rebuild at the next launch |
| **P3** polish | Icon Composer icon, URL scheme, AppleScript, open at login, find/print checks, full-bleed title bar, optional development mode | `osascript … get status` answers; the icon renders in light, dark and tinted |

---

## 22. Open questions (unverified)

- Notification permission and `SMAppService` login items with a self-signed identity on
  macOS 27; whether the Dock badge needs notification permission.
- Whether the native find bar appears through `NSTextFinder`; blank pages from
  `printOperation`.
- Taking file drops in a `WKWebView` subclass before WebKit navigates to `file://`.
- Whether App Nap slows the children while the app is hidden, with the activity held.
- Postgres cold start time; `pnpm install` and `astro build` without network.
- Whether `astro build` can write to a temporary folder so a failed build keeps the last
  good `dist/`.
- How long logout waits for `.terminateLater`.
- The Dock icon cache after replacing the app in `~/Applications`.
- `books.vertical.fill` and `pause.circle` as template images.
- ~~The stop's SIGINT step (§3) with a `/search/answer` open~~: checked in P1; the
  answer's `claude` is gone at the SIGINT step, before the SIGKILL.
- Known, accepted gaps from P0: a job run can escape for a few milliseconds if the API
  dies between its slot check and its registration; build agents and narrations run
  detached by design and survive the API.

---

## 23. Decided (2026-11-03, Fer)

1. **The plan**: accepted (ADR-001).
2. **Signing**: a self-signed "Bookshelf Local" certificate; ad-hoc only as the fallback.
3. **Swift tests**: Swift Testing in `macos/`, as an exception to the Vitest rule (CLAUDE.md).
4. **Database at quit**: it keeps running by default.
5. **Order**: the P0 backend fixes come before P1 (done). The API hang on a group SIGTERM
   also mattered outside the app, for any supervisor that signals the whole group.
