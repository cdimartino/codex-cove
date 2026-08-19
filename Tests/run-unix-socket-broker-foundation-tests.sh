#!/bin/zsh
set -euo pipefail
setopt null_glob

COVE_REPOSITORY_ROOT="${0:A:h:h}"
cd "$COVE_REPOSITORY_ROOT"

swift build --disable-sandbox --target CoveCore
COVE_BUILD_BIN_PATH="$(swift build --disable-sandbox --show-bin-path)"
COVE_TEST_TEMP_DIR="$(mktemp -d /tmp/cove-socket-broker-tests.XXXXXX)"
trap '/bin/rm -rf -- "$COVE_TEST_TEMP_DIR"' EXIT

COVE_CORE_OBJECTS=("$COVE_BUILD_BIN_PATH"/CoveCore.build/*.swift.o)
if (( ${#COVE_CORE_OBJECTS} == 0 )); then
    print -u2 "CoveCore build produced no object files"
    exit 1
fi

xcrun --sdk macosx swiftc \
    -parse-as-library \
    -swift-version 6 \
    -I "$COVE_BUILD_BIN_PATH/Modules" \
    Sources/CodexCoveApp/CoveUnixSocketBroker.swift \
    Tests/CoveUnixSocketBrokerFoundationTests/main.swift \
    "$COVE_CORE_OBJECTS[@]" \
    -lsqlite3 \
    -o "$COVE_TEST_TEMP_DIR/CoveUnixSocketBrokerFoundationTests"

"$COVE_TEST_TEMP_DIR/CoveUnixSocketBrokerFoundationTests"
