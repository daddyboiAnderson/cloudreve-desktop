#!/bin/bash
# Package ONLY the finished production bundle. The updater archive must contain
# the same embedded extension and signature as the DMG, never a pre-embed app.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP="$ROOT/target/release/bundle/macos/Cloudreve.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
EXT="$APP/Contents/PlugIns/CloudreveFileProvider.appex"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")" = cloudreve.desktop
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$EXT/Contents/Info.plist")" = cloudreve.desktop.fileprovider
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$EXT/Contents/Info.plist")" = "$BUILD"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$EXT/Contents/Info.plist")" = "$VERSION"
codesign --verify --deep --strict "$APP"
ARCH="$(uname -m)"
[[ "$ARCH" == arm64 ]] && ARCH=aarch64
[[ "$ARCH" == aarch64 || "$ARCH" == x86_64 ]]
OUT="$ROOT/release/$VERSION"
mkdir -p "$OUT"
STAGING="$(mktemp -d "${TMPDIR:-/tmp}/cloudreve-dmg.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
ditto "$APP" "$STAGING/Cloudreve.app"
ln -s /Applications "$STAGING/Applications"
DMG="$OUT/Cloudreve_${VERSION}_${ARCH}.dmg"
test ! -e "$DMG" || { echo "Refusing to overwrite $DMG" >&2; exit 1; }
hdiutil create -volname Cloudreve -srcfolder "$STAGING" -ov -format UDZO "$DMG"
ARCHIVE="$OUT/Cloudreve_${VERSION}_${ARCH}.app.tar.gz"
COPYFILE_DISABLE=1 tar -czf "$ARCHIVE" -C "$(dirname "$APP")" Cloudreve.app
# Signing key must be provided by the release operator/CI; never commit it.
: "${TAURI_SIGNING_PRIVATE_KEY_PATH:?Set TAURI_SIGNING_PRIVATE_KEY_PATH to your release key file}"
cargo tauri signer sign "$ARCHIVE"
node "$ROOT/macos/scripts/write-update-manifest.mjs" "$OUT" "$VERSION" "$ARCH"
shasum -a 256 "$DMG" "$ARCHIVE"
