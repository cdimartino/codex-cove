#!/bin/zsh
set -euo pipefail

COVE_REPOSITORY_ROOT="${0:A:h:h}"
cd "$COVE_REPOSITORY_ROOT"

COVE_TEST_TEMP_DIR="$(
    mktemp -d "${TMPDIR:-/tmp}/codex-cove-launch-at-login-tests.XXXXXX"
)"
trap '/bin/rm -rf -- "$COVE_TEST_TEMP_DIR"' EXIT

xcrun --sdk macosx swiftc \
    -parse-as-library \
    -swift-version 6 \
    -module-cache-path "$COVE_TEST_TEMP_DIR/module-cache" \
    Sources/CodexCoveApp/CoveLaunchAtLoginService.swift \
    Tests/CoveLaunchAtLoginFoundationTests/main.swift \
    -framework ServiceManagement \
    -o "$COVE_TEST_TEMP_DIR/CoveLaunchAtLoginFoundationTests"

"$COVE_TEST_TEMP_DIR/CoveLaunchAtLoginFoundationTests"
