#!/bin/bash
# Builds the CloudreveFileProvider.appex from Swift sources using swiftc
# (no Xcode project needed), assembles the bundle and signs it.
#
# Env overrides:
#   FP_SIGN_IDENTITY  codesign identity ("-" = ad-hoc, default)
#   FP_CONFIGURATION  Debug (default) | Release
#   FP_BUILD_NUMBER   numeric CFBundleVersion (default: 4)
#   FP_SHORT_VERSION  release version (default: 0.2.0)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC_DIR="$ROOT/macos/fileprovider/Sources"
SUPPORT_DIR="$ROOT/macos/fileprovider/Support"
BUILD_DIR="$ROOT/macos/build"
APPEX="$BUILD_DIR/CloudreveFileProvider.appex"
MODULE_CACHE="${FP_MODULE_CACHE_PATH:-$BUILD_DIR/ModuleCache}"

IDENTITY="${FP_SIGN_IDENTITY:--}"
CONFIG="${FP_CONFIGURATION:-Debug}"
BUILD_NUMBER="${FP_BUILD_NUMBER:-4}"
SHORT_VERSION="${FP_SHORT_VERSION:-0.2.0}"
if [[ -n "${FP_SDK_PATH:-}" ]]; then
    SDK="$FP_SDK_PATH"
elif [[ -d "/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk" ]]; then
    SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk"
else
    SDK="$(xcrun --sdk macosx --show-sdk-path)"
fi
mkdir -p "$MODULE_CACHE"
export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE"

echo "==> Compiling extension ($CONFIG, sdk: $SDK)"
rm -rf "$APPEX"
mkdir -p "$APPEX/Contents/MacOS"
mkdir -p "$APPEX/Contents/Resources"

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
    -framework Foundation -framework AppKit -framework FileProvider -framework UniformTypeIdentifiers \
    -Xlinker -e -Xlinker _NSExtensionMain \
    -o "$APPEX/Contents/MacOS/CloudreveFileProvider" \
    "$SRC_DIR"/*.swift

echo "==> Assembling bundle"
cp "$SUPPORT_DIR/Info.plist" "$APPEX/Contents/Info.plist"
cp "$ROOT/src-tauri/icons/icon.icns" "$APPEX/Contents/Resources/Cloudreve.icns"
bash "$ROOT/macos/scripts/build-keep-downloaded-badge.sh" \
    "$APPEX/Contents/Resources"
bash "$ROOT/macos/scripts/build-shared-badge.sh" \
    "$APPEX/Contents/Resources"
bash "$ROOT/macos/scripts/build-lock-badge.sh" \
    "$APPEX/Contents/Resources"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APPEX/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $SHORT_VERSION" "$APPEX/Contents/Info.plist"

echo "==> Signing (identity: $IDENTITY)"
codesign --force --sign "$IDENTITY" \
    --entitlements "$SUPPORT_DIR/FileProvider.entitlements" \
    --timestamp=none \
    "$APPEX"

echo "==> Done: $APPEX"
codesign -dv "$APPEX" 2>&1 | grep -E "Identifier|Signature" || true
