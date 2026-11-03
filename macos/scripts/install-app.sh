#!/usr/bin/env bash
# Installs macos/build/Bookshelf.app in ~/Applications (docs/MACOS_APP.md §18): quits the
# running copy the way ⌘Q does (its SIGTERM handler stops the services first), copies the
# new one with ditto, registers it with Launch Services and opens it.
#
#   macos/scripts/install-app.sh [--no-open]
#
# BOOKSHELF_INSTALL_DIR overrides ~/Applications.
set -euo pipefail

MACOS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$MACOS/build/Bookshelf.app"
DEST_DIR="${BOOKSHELF_INSTALL_DIR:-$HOME/Applications}"
DEST="$DEST_DIR/Bookshelf.app"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

[[ -d "$APP" ]] || { echo "No build at $APP; run macos/scripts/build-app.sh first." >&2; exit 1; }

# Any running copy (this one, or macos/build's): only one may run, and a second launch
# would exit at once. The app only: its guards run the same binary with --guard.
running_apps() {
  pgrep -f "Bookshelf\.app/Contents/MacOS/Bookshelf" | while read -r pid; do
    ps -o command= -p "$pid" | grep -q -- "--guard" || echo "$pid"
  done
}
running="$(running_apps)"
if [[ -n "$running" ]]; then
  echo "→ quitting the running Bookshelf ($(echo $running))"
  kill -TERM $running  # the app's handler quits as ⌘Q does: services first
  for _ in $(seq 1 150); do
    [[ -z "$(running_apps)" ]] && break
    sleep 0.1
  done
  if [[ -n "$(running_apps)" ]]; then
    echo "Bookshelf did not quit within 15 s (a dialog may be waiting); quit it and run this again." >&2
    exit 1
  fi
fi

echo "→ $DEST"
mkdir -p "$DEST_DIR"
rm -rf "$DEST"
ditto "$APP" "$DEST"
"$LSREGISTER" -f "$DEST"

if [[ "${1:-}" != "--no-open" ]]; then
  open "$DEST"
fi
