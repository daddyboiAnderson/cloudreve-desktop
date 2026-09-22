#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cloudreve-state-tests.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
export CLOUDREVE_FP_TEST_FIXTURE="$TEST_DIR/fixture"
SDK="${FP_SDK_PATH:-$(xcrun --sdk macosx --show-sdk-path)}"
cd "$ROOT"
cargo test -p cloudreve-sync --lib fileprovider_db::tests
swiftc -swift-version 5 -sdk "$SDK" \
    -module-cache-path "$ROOT/macos/build/TestModuleCache" \
    "$ROOT/macos/fileprovider/Sources/FileProviderStateDatabase.swift" \
    "$ROOT/macos/fileprovider/Tests/FileProviderStateDatabaseTests.swift" \
    -o "$TEST_DIR/state-tests"
"$TEST_DIR/state-tests"
# Both language implementations must expose the same schema and values.
test "$(sqlite3 "$CLOUDREVE_FP_TEST_FIXTURE/fileprovider.db" "SELECT payload FROM fp_records WHERE namespace='interop' AND key='swift'")" = "Swift wrote this"
SCHEMA_QUERY='SELECT m.name,p.name,p.type,p."notnull",p.pk FROM sqlite_master m JOIN pragma_table_info(m.name) p WHERE m.type="table" ORDER BY m.name,p.cid'
test "$(sqlite3 "$CLOUDREVE_FP_TEST_FIXTURE/fileprovider.db" "$SCHEMA_QUERY")" = "$(sqlite3 "$CLOUDREVE_FP_TEST_FIXTURE/swift-created/fileprovider.db" "$SCHEMA_QUERY")"
