#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TEST_BINARY="${TMPDIR:-/tmp}/cloudreve-pin-request-tests"
export CLANG_MODULE_CACHE_PATH="$ROOT/macos/build/TestModuleCache"
swiftc -swift-version 5 -target arm64-apple-macos13.0 \
    -sdk "${FP_SDK_PATH:-/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk}" \
    -framework Foundation -framework AppKit -framework FileProvider -framework UniformTypeIdentifiers \
    -o "$TEST_BINARY" "$ROOT/macos/fileprovider/Sources/"*.swift \
    "$ROOT/macos/fileprovider/Tests/PinRequestTests.swift"
"$TEST_BINARY"
