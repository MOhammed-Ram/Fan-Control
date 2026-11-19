#!/usr/bin/env bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
cd "$DIR"

CACHE_DIR="$DIR/build/cache"
TEST_BIN="$DIR/build/unit-tests"
mkdir -p "$DIR/build" "$CACHE_DIR"

echo "🔨 Compiling unit test suite..."
swiftc -O \
    -module-cache-path "$CACHE_DIR" \
    Sources/Common/Models.swift \
    Sources/Common/CurveEngine.swift \
    Sources/Common/ShellEscaping.swift \
    Tests/UnitTests.swift \
    -framework Foundation \
    -o "$TEST_BIN"

echo "🚀 Running unit tests..."
"$TEST_BIN"
rm -f "$TEST_BIN"
