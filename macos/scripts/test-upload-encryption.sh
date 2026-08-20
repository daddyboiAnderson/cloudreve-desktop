#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TEST_BINARY="${TMPDIR:-/tmp}/cloudreve-upload-encryption-tests"
SDK="${FP_SDK_PATH:-$(xcrun --sdk macosx --show-sdk-path)}"

xcrun swiftc -swift-version 5 \
    -target arm64-apple-macos13.0 \
    -sdk "$SDK" \
    -framework Foundation \
    -o "$TEST_BINARY" \
    "$ROOT/macos/fileprovider/Sources/UploadEncryption.swift" \
    "$ROOT/macos/fileprovider/Tests/UploadEncryptionTests.swift"

"$TEST_BINARY"
