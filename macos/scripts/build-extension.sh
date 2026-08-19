#!/bin/bash
# Builds the CloudreveFileProvider.appex from Swift sources using swiftc
# (no Xcode project needed), assembles the bundle and signs it.
#
# Env overrides:
#   FP_SIGN_IDENTITY  codesign identity ("-" = ad-hoc, default)
#   FP_CONFIGURATION  Debug (default) | Release
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC_DIR="$ROOT/macos/fileprovider/Sources"
SUPPORT_DIR="$ROOT/macos/fileprovider/Support"
BUILD_DIR="$ROOT/macos/build"
APPEX="$BUILD_DIR/CloudreveFileProvider.appex"

IDENTITY="${FP_SIGN_IDENTITY:--}"
CONFIG="${FP_CONFIGURATION:-Debug}"
SDK="$(xcrun --sdk macosx --show-sdk-path)"

echo "==> Compiling extension ($CONFIG, sdk: $SDK)"
rm -rf "$APPEX"
mkdir -p "$APPEX/Contents/MacOS"

OPT_FLAGS=(-Onone)
if [[ "$CONFIG" == "Release" ]]; then
    OPT_FLAGS=(-O)
fi

# shellcheck disable=SC2086
swiftc -swift-version 5 \
    -module-name CloudreveFileProvider \
    -target arm64-apple-macos13.0 \
    -sdk "$SDK" \
    -application-extension \
    "${OPT_FLAGS[@]}" \
    -framework Foundation -framework FileProvider -framework UniformTypeIdentifiers \
    -Xlinker -e -Xlinker _NSExtensionMain \
    -o "$APPEX/Contents/MacOS/CloudreveFileProvider" \
    "$SRC_DIR"/*.swift

echo "==> Assembling bundle"
cp "$SUPPORT_DIR/Info.plist" "$APPEX/Contents/Info.plist"

echo "==> Signing (identity: $IDENTITY)"
codesign --force --sign "$IDENTITY" \
    --entitlements "$SUPPORT_DIR/FileProvider.entitlements" \
    --timestamp=none \
    "$APPEX"

echo "==> Done: $APPEX"
codesign -dv "$APPEX" 2>&1 | grep -E "Identifier|Signature" || true
