#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUTPUT_DIR="$1"
BUILD_DIR="$ROOT/macos/build"
GENERATOR="$BUILD_DIR/LockBadge"
MODULE_CACHE="${FP_MODULE_CACHE_PATH:-$BUILD_DIR/ModuleCache}"

if [[ -n "${FP_SDK_PATH:-}" ]]; then
    SDK="$FP_SDK_PATH"
elif [[ -d "/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk" ]]; then
    SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk"
else
    SDK="$(xcrun --sdk macosx --show-sdk-path)"
fi

mkdir -p "$BUILD_DIR" "$MODULE_CACHE" "$OUTPUT_DIR"
export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE"
if [[ ! -x "$GENERATOR" || "$ROOT/macos/scripts/LockBadge.swift" -nt "$GENERATOR" ]]; then
    swiftc -swift-version 5 \
        -target arm64-apple-macos13.0 \
        -sdk "$SDK" \
        -framework CoreGraphics \
        -framework ImageIO \
        -o "$GENERATOR" \
        "$ROOT/macos/scripts/LockBadge.swift"
fi

"$GENERATOR" "$OUTPUT_DIR/UploadConflict.icns"
