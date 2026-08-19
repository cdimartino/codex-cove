#!/bin/bash
set -euo pipefail

REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPOSITORY_ROOT"

swift build --target CoveCore
BUILD_DIRECTORY="$(swift build --show-bin-path)"
MODULE_DIRECTORY="$BUILD_DIRECTORY/Modules"
CORE_OBJECT_DIRECTORY="$BUILD_DIRECTORY/CoveCore.build"
TEST_OUTPUT_DIRECTORY="$(mktemp -d /tmp/cove-store-foundation.XXXXXX)"
trap 'rm -rf "$TEST_OUTPUT_DIRECTORY"' EXIT

shopt -s nullglob
CORE_OBJECTS=("$CORE_OBJECT_DIRECTORY"/*.o)
if [[ ${#CORE_OBJECTS[@]} -eq 0 ]]; then
    echo "CoveCore build produced no object files" >&2
    exit 1
fi

APP_SOURCES=(
    Sources/CodexCoveApp/CoveOverlayPresentation.swift
    Sources/CodexCoveApp/CoveActionState.swift
    Sources/CodexCoveApp/CoveImportedSoundStore.swift
    Sources/CodexCoveApp/CoveEditorWindowFocusing.swift
    Sources/CodexCoveApp/CoveMetadataBridge.swift
    Sources/CodexCoveApp/CoveFaviconLoader.swift
    Sources/CodexCoveApp/CoveTerminalJumping.swift
    Sources/CodexCoveApp/CoveUITestSupport.swift
    Sources/CodexCoveApp/CoveSoundService.swift
    Sources/CodexCoveApp/CoveStore.swift
    Sources/CodexCoveApp/CoveWorkspaceStore.swift
)

swiftc \
    -parse-as-library \
    -I "$MODULE_DIRECTORY" \
    "${APP_SOURCES[@]}" \
    Tests/CoveStoreFoundationTests/main.swift \
    "${CORE_OBJECTS[@]}" \
    -framework AppKit \
    -framework ApplicationServices \
    -framework AVFoundation \
    -framework ImageIO \
    -framework SwiftUI \
    -lsqlite3 \
    -o "$TEST_OUTPUT_DIRECTORY/CoveStoreFoundationTests"

"$TEST_OUTPUT_DIRECTORY/CoveStoreFoundationTests"
