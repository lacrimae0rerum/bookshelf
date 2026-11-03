# ADR-001: Native macOS launcher for Bookshelf

<!-- alfred-doc:filled -->

**Fecha:** 2026-11-03
**Estado:** aceptado (Fer, 2026-11-03)
**Autor:** architect
**Detalle:** [docs/MACOS_APP.md](../MACOS_APP.md)

## Contexto

Bookshelf runs as three local services: Postgres (`scripts/pg-local.sh`, port 54329), the
FastAPI API (8000) and the Astro server (4321). Today they are started by hand in terminals.
When they are not running, the browser shows `ERR_CONNECTION_REFUSED`, with no hint of what
to start. Fer is the only user, on one Mac (macOS 27, Apple silicon). He wants a Mac app:
an icon, a window, a menu bar icon and settings, with the services started and stopped
for him.

Constraints: no new dependencies without approval; the repo's runtimes (uv, Node, pnpm,
Homebrew Postgres, the `claude` CLI) are already installed; no paid Apple Developer account.

## Opciones evaluadas

### Opción 1: web app in the Dock + LaunchAgents

Safari's *Add to Dock* gives a window and an icon; LaunchAgents keep the services always on.
Little code. But: no control over the window or menus, no file drops on the icon, no single
place for errors, services running when unused, and LaunchAgents are critical unversioned
configuration that must be maintained by hand.

### Opción 2: native launcher (AppKit + WKWebView) that supervises the repo's services

A small Swift app, built with SwiftPM and a bundle script, signed locally. It starts the
services with the captured login PATH, shows the web in a `WKWebView`, and stops the services
at quit; guards kill the services if the app dies. Full control over the window, menus, Dock,
menu bar icon, notifications and errors. Costs: about 2–3k lines of Swift over three phases,
and tests in Swift.

### Opción 3: packaged app (Tauri or Electron) with bundled runtimes

A self-contained app with Python, Node and Postgres inside. Needed only to give the app to
other people. Weeks of work, a large bundle (runtimes plus ~160 MB of embedding models), a new
framework dependency, and two copies of every runtime to keep in step with the repo.

### Variants rejected inside option 2

- **SwiftUI lifecycle and SwiftUI `WebView`**: in SDK 27.2 `WebView`/`WebPage` lacks
  downloads, a `window.open` hook, `pageZoom`, printing and media playback control on macOS;
  close-is-not-quit, reopen and frame autosave need the `NSWindow` anyway.
- **`.xcodeproj` + `xcodebuild`**: only needed for App Intents; the project file is noisy to
  review. A URL scheme and AppleScript cover automation.
- **`pnpm dev` / `fastapi dev`**: `astro dev` daemonizes itself under `CLAUDECODE=1` and then
  escapes group signals (measured); the compiled web server starts in 0.12 s.
- **Ad-hoc signing only**: every rebuild changes the designated requirement (TN3127), so
  permissions are asked again.

## Decisión

Option 2. Bookshelf gets a native AppKit launcher with a `WKWebView` window, built from
`macos/` with SwiftPM and a bundle script, signed with a free self-signed identity, and
installed in `~/Applications`. The app supervises the repo's own services, each in its own
process group under a guard that kills it if the app dies. The environment is built from the
login shell's PATH and an allowlist, never inherited. The web is served compiled
(`astro build` + `node dist/server/entry.mjs`) and rebuilt when a frontend fingerprint
changes. Everything binds and loads on `127.0.0.1`.

Settled with the decision: a self-signed "Bookshelf Local" certificate (ad-hoc only as the
fallback); Swift Testing for `macos/`; Postgres keeps running after quit by default; the
backend fix (P0) comes before the first build phase.

## Consecuencias

- The app is tied to this Mac and this repo; it is not distributable as is.
- The API's shutdown had to be made safe for a supervisor first (P0, done 2026-11-03): a
  SIGTERM to its process group no longer hangs it, and its `claude` runs, which live in
  sessions of their own, are ended by the API itself (`b28ae80`, `d782745`, `d39b8cc`).
  The app stops it with SIGTERM, then SIGINT, then SIGKILL (`docs/MACOS_APP.md`, M9).
- The app's tests are Swift Testing (`swift test`); CLAUDE.md now carries that exception
  for `macos/`.
- A self-signed certificate must be created once in the login keychain.
- No new third-party dependencies: Swift, AppKit, WebKit, UserNotifications and
  ServiceManagement ship with macOS and Xcode.
- Open items that the spike could not verify are listed in `docs/MACOS_APP.md` §22.
