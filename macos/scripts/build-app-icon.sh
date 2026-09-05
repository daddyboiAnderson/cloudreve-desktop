#!/bin/bash
# Compile the Icon Composer document, including its light and dark appearances.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUTPUT="$ROOT/macos/build/AppIcon"
DEVELOPER="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
ACTOOL="${ICON_ACTOOL:-$DEVELOPER/usr/bin/actool}"

if [[ ! -x "$ACTOOL" ]]; then
    echo "error: Xcode 26 or later is required to compile the macOS app icon. Set DEVELOPER_DIR to its Developer directory." >&2
    exit 1
fi

mkdir -p "$OUTPUT"
"$ACTOOL" "$ROOT/macos/icons/Cloudreve.icon" \
    --compile "$OUTPUT" \
    --output-format human-readable-text --notices --warnings \
    --output-partial-info-plist "$OUTPUT/Info.plist" \
    --app-icon Cloudreve --include-all-app-icons \
    --enable-on-demand-resources NO --development-region en \
    --target-device mac --minimum-deployment-target 26.0 --platform macosx

test -s "$OUTPUT/Assets.car"
test -s "$OUTPUT/Cloudreve.icns"
