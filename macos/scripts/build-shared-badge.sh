#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUTPUT_DIR="$1"
BUILD_DIR="$ROOT/macos/build"
GENERATOR="$BUILD_DIR/SharedBadge"
MODULE_CACHE="$BUILD_DIR/ModuleCache"
if [[ -n "$(printenv FP_MODULE_CACHE_PATH 2>/dev/null || true)" ]]; then
    MODULE_CACHE="$(printenv FP_MODULE_CACHE_PATH)"
fi

if [[ -n "$(printenv FP_SDK_PATH 2>/dev/null || true)" ]]; then
    SDK="$(printenv FP_SDK_PATH)"
elif [[ -d "/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk" ]]; then
    SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk"
else
    SDK="$(xcrun --sdk macosx --show-sdk-path)"
fi

mkdir -p "$BUILD_DIR" "$MODULE_CACHE" "$OUTPUT_DIR"
export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE"
if [[ ! -x "$GENERATOR" || "$ROOT/macos/scripts/SharedBadge.swift" -nt "$GENERATOR" ]]; then
    swiftc -swift-version 5 \
        -target arm64-apple-macos13.0 \
        -sdk "$SDK" \
        -framework CoreGraphics \
        -framework ImageIO \
        -o "$GENERATOR" \
        "$ROOT/macos/scripts/SharedBadge.swift"
fi

"$GENERATOR" "$OUTPUT_DIR/Shared.icns"
