#!/bin/sh
set -eu

# `cargo install` uses Cargo's bin directory even when Homebrew supplies the
# active `cargo` executable. Include that conventional location so freshly
# installed Cargo subcommands are discoverable in non-login shells.
COVE_CARGO_BIN_DIR="${CARGO_HOME:-$HOME/.cargo}/bin"
if [ -d "$COVE_CARGO_BIN_DIR" ]; then
    PATH="$COVE_CARGO_BIN_DIR:$PATH"
    export PATH
fi

missing=0

version_at_least() {
    current_version=$1
    minimum_version=$2
    awk -v current="$current_version" -v minimum="$minimum_version" 'BEGIN {
        split(current, current_parts, ".")
        split(minimum, minimum_parts, ".")
        for (part_index = 1; part_index <= 3; part_index++) {
            current_value = (current_parts[part_index] == "" ? 0 : current_parts[part_index]) + 0
            minimum_value = (minimum_parts[part_index] == "" ? 0 : minimum_parts[part_index]) + 0
            if (current_value > minimum_value) exit 0
            if (current_value < minimum_value) exit 1
        }
        exit 0
    }'
}

require_version() {
    label=$1
    current_version=$2
    minimum_version=$3
    install_hint=$4
    if [ -n "$current_version" ] && version_at_least "$current_version" "$minimum_version"; then
        printf '%-18s %s\n' "$label" "$current_version (ok; >= $minimum_version)"
    else
        printf '%-18s %s\n' "$label" "${current_version:-unknown} (need >= $minimum_version; $install_hint)"
        missing=1
    fi
}

require_command() {
    command_name=$1
    install_hint=$2
    if command -v "$command_name" >/dev/null 2>&1; then
        printf '%-18s %s\n' "$command_name" "ok"
    else
        printf '%-18s missing (%s)\n' "$command_name" "$install_hint"
        missing=1
    fi
}

require_command swift "install Apple Command Line Tools"
require_command cargo "install Rust with rustup"
require_command rustc "install Rust with rustup"
require_command node "install Node.js 22+"
require_command npm "install Node.js 22+"
require_command codex "install Codex CLI 0.147.0+"
require_command make "install GNU Make"
require_command codesign "provided by macOS"
require_command plutil "provided by macOS"
require_command xcodebuild "install and select full Xcode 26.6+"

if command -v swift >/dev/null 2>&1; then
    swift_version=$(swift --version 2>/dev/null | sed -nE 's/.*Apple Swift version ([0-9]+(\.[0-9]+){1,2}).*/\1/p' | head -n 1)
    require_version swift-version "$swift_version" 6.0.0 "select a compatible Xcode toolchain"
fi
if command -v rustc >/dev/null 2>&1; then
    rust_version=$(rustc --version 2>/dev/null | awk 'NR == 1 { print $2 }')
    require_version rust-version "$rust_version" 1.85.0 "install a newer stable Rust"
fi
if command -v node >/dev/null 2>&1; then
    node_version=$(node --version 2>/dev/null | sed 's/^v//')
    require_version node-version "$node_version" 22.0.0 "install Node.js 22+"
fi
if command -v codex >/dev/null 2>&1; then
    codex_version=$(codex --version 2>/dev/null | awk 'NR == 1 { print $2 }')
    require_version codex-version "$codex_version" 0.147.0 "install Codex CLI 0.147.0+"
fi
if command -v xcodebuild >/dev/null 2>&1; then
    xcode_version=$(xcodebuild -version 2>/dev/null | awk 'NR == 1 { print $2 }')
    require_version xcode-version "$xcode_version" 26.6.0 "install and select Xcode 26.6+"
    printf '%-18s %s\n' "developer-dir" "$(xcode-select -p 2>/dev/null || printf unknown)"
fi

if [ -f "$(dirname "$0")/../extension/package-lock.json" ]; then
    extension_root=$(CDPATH= cd -- "$(dirname "$0")/../extension" && pwd)
    if npm --prefix "$extension_root" ls --depth=0 --silent >/dev/null 2>&1; then
        printf '%-18s %s\n' "extension-deps" "ok"
    else
        printf '%-18s %s\n' "extension-deps" "missing or inconsistent (run make deps)"
        missing=1
    fi
fi

if command -v zig >/dev/null 2>&1; then
    printf '%-18s %s\n' "zig" "ok (remote cross-build enabled)"
else
    printf '%-18s %s\n' "zig" "optional; required for Linux remote helpers"
fi

if command -v cargo-zigbuild >/dev/null 2>&1; then
    printf '%-18s %s\n' "cargo-zigbuild" "ok (remote cross-build enabled)"
else
    printf '%-18s %s\n' "cargo-zigbuild" "optional; install with cargo install cargo-zigbuild --locked"
fi

if command -v xcodegen >/dev/null 2>&1; then
    printf '%-18s %s\n' "xcodegen" "$(xcodegen --version 2>/dev/null | head -n 1) (optional project regeneration)"
else
    printf '%-18s %s\n' "xcodegen" "optional; required only to regenerate the UI-test project"
fi

if [ "$missing" -ne 0 ]; then
    exit 1
fi
