#!/bin/zsh
set -euo pipefail

COVE_REPOSITORY_ROOT="${0:A:h:h}"
cd "$COVE_REPOSITORY_ROOT"

swift build --target CoveCore
COVE_BUILD_BIN_PATH="$(swift build --show-bin-path)"
COVE_TEST_TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/codex-cove-m2-tests.XXXXXX")"
trap '/bin/rm -rf -- "$COVE_TEST_TEMP_DIR"' EXIT

COVE_CORE_OBJECTS=("$COVE_BUILD_BIN_PATH"/CoveCore.build/*.swift.o)
swiftc \
    -swift-version 6 \
    -Xfrontend -interface-compiler-version \
    -Xfrontend 6.3.2 \
    -I "$COVE_BUILD_BIN_PATH/Modules" \
    Sources/CodexCoveApp/CoveOverlayPresentation.swift \
    Tests/CoveMilestone2FoundationTests/main.swift \
    "$COVE_CORE_OBJECTS[@]" \
    -o "$COVE_TEST_TEMP_DIR/CoveMilestone2FoundationTests"

"$COVE_TEST_TEMP_DIR/CoveMilestone2FoundationTests"
