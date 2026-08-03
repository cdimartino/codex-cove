#!/bin/zsh
set -euo pipefail

COVE_REPOSITORY_ROOT="${0:A:h:h}"
cd "$COVE_REPOSITORY_ROOT"

swift build --disable-sandbox --target CoveCore
COVE_BUILD_BIN_PATH="$(swift build --disable-sandbox --show-bin-path)"
COVE_TEST_TEMP_DIR="$(mktemp -d "$COVE_REPOSITORY_ROOT/.build/codex-cove-m13-tests.XXXXXX")"
trap '/bin/rm -rf -- "$COVE_TEST_TEMP_DIR"' EXIT

COVE_CORE_OBJECTS=("$COVE_BUILD_BIN_PATH"/CoveCore.build/*.swift.o)
swiftc \
    -swift-version 6 \
    -Xfrontend -interface-compiler-version \
    -Xfrontend 6.3.2 \
    -I "$COVE_BUILD_BIN_PATH/Modules" \
    Sources/CodexCoveApp/CoveOverlayPresentation.swift \
    Sources/CodexCoveApp/CoveActionState.swift \
    Sources/CodexCoveApp/CoveImportedSoundStore.swift \
    Tests/CoveMilestone13FoundationTests/main.swift \
    "$COVE_CORE_OBJECTS[@]" \
    -o "$COVE_TEST_TEMP_DIR/CoveMilestone13FoundationTests"

COVE_IMPORTED_SOUND_TEST_ROOT="$COVE_TEST_TEMP_DIR" \
    "$COVE_TEST_TEMP_DIR/CoveMilestone13FoundationTests"
