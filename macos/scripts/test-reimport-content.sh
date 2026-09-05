#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TEST_BINARY="${TMPDIR:-/tmp}/cloudreve-reimport-content-tests"
SDK="${FP_SDK_PATH:-/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk}"
MODULE_CACHE="${FP_MODULE_CACHE_PATH:-$ROOT/macos/build/TestModuleCache}"
mkdir -p "$MODULE_CACHE"

swiftc -swift-version 5 -target arm64-apple-macos13.0 \
    -sdk "$SDK" -module-cache-path "$MODULE_CACHE" \
    -o "$TEST_BINARY" \
    "$ROOT/macos/fileprovider/Sources/ReimportContent.swift" \
    "$ROOT/macos/fileprovider/Tests/ReimportContentTests.swift"

"$TEST_BINARY"
