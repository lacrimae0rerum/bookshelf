#!/usr/bin/env bash
# Builds macos/build/Bookshelf.app (docs/MACOS_APP.md §18):
# swift build → bundle → placeholder icon → Info.plist values → codesign.
#
#   macos/scripts/build-app.sh
#
# Signs with the "Bookshelf Local" code-signing identity when the login keychain has it,
# else ad-hoc. An ad-hoc signature changes with every build, so macOS may ask for
# permissions again after a rebuild. make-signing-identity.sh creates the identity, once.
set -euo pipefail

MACOS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="$(cd "$MACOS/.." && pwd)"
OUT="$MACOS/build"
APP="$OUT/Bookshelf.app"
PLIST="$APP/Contents/Info.plist"

echo "→ swift build (release)"
swift build -c release --package-path "$MACOS"
BIN="$(swift build -c release --package-path "$MACOS" --show-bin-path)/Bookshelf"

echo "→ bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Bookshelf"
cp "$MACOS/Resources/Info.plist" "$PLIST"

ICON_SCRIPT="$MACOS/scripts/make-icon.swift"
if [[ ! -f "$OUT/AppIcon.icns" || "$ICON_SCRIPT" -nt "$OUT/AppIcon.icns" ]]; then
  echo "→ placeholder icon"
  swift "$ICON_SCRIPT" "$OUT/AppIcon.iconset"
  iconutil -c icns "$OUT/AppIcon.iconset" -o "$OUT/AppIcon.icns"
  rm -rf "$OUT/AppIcon.iconset"
fi
cp "$OUT/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

git_() { git -C "$ROOT" --no-optional-locks "$@"; }
VERSION="$(sed -n 's/^version = "\(.*\)"/\1/p' "$ROOT/backend/pyproject.toml" | head -1)"
COMMIT="$(git_ rev-parse --short HEAD)$([[ -z "$(git_ status --porcelain -- macos)" ]] || echo "+dirty")"
plutil -replace CFBundleShortVersionString -string "${VERSION:-0.0.0}" "$PLIST"
plutil -replace CFBundleVersion -string "$(git_ rev-list --count HEAD)" "$PLIST"
plutil -replace BookshelfCommit -string "$COMMIT" "$PLIST"
plutil -replace BookshelfRepositoryPath -string "$ROOT" "$PLIST"

IDENTITY="-"
# No -v: that lists only trusted identities, and a self-signed one may not be marked trusted.
if security find-identity -p codesigning 2>/dev/null | grep -q '"Bookshelf Local"'; then
  IDENTITY="Bookshelf Local"
else
  echo "warning: no \"Bookshelf Local\" identity in the keychain; signing ad-hoc." >&2
  echo "         macOS may ask for permissions again after each rebuild." >&2
  echo "         Create the identity once with macos/scripts/make-signing-identity.sh." >&2
fi
echo "→ codesign ($IDENTITY)"
codesign --force --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP"

echo "$APP"
