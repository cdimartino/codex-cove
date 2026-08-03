#!/bin/sh
set -eu

COVE_CARGO_BIN_DIR="${CARGO_HOME:-$HOME/.cargo}/bin"
if [ -d "$COVE_CARGO_BIN_DIR" ]; then
    PATH="$COVE_CARGO_BIN_DIR:$PATH"
    export PATH
fi

repository_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd -P)
build_root="$repository_root/build"
artifact_root="$build_root/remote"
manifest_path="$artifact_root/SHA256SUMS"

if [ -e "$build_root" ] || [ -L "$build_root" ]; then
    [ -d "$build_root" ] && [ ! -L "$build_root" ] || {
        printf 'Build output parent must be a real repository directory.\n' >&2
        exit 1
    }
fi
if [ -e "$artifact_root" ] || [ -L "$artifact_root" ]; then
    [ -d "$artifact_root" ] && [ ! -L "$artifact_root" ] || {
        printf 'Remote artifact output must be a real directory.\n' >&2
        exit 1
    }
fi

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        printf 'Missing required command: %s\n' "$1" >&2
        printf '%s\n' "$2" >&2
        exit 1
    fi
}

require_command rustup "Install rustup before building remote helpers."
require_command cargo "Install Rust before building remote helpers."
require_command cargo-zigbuild "Run: cargo install cargo-zigbuild --locked"
require_command zig "Run: brew install zig"

COVE_RUSTUP_TOOLCHAIN=${COVE_RUSTUP_TOOLCHAIN:-stable}
COVE_RUSTC=$(rustup which --toolchain "$COVE_RUSTUP_TOOLCHAIN" rustc)
COVE_CARGO=$(rustup which --toolchain "$COVE_RUSTUP_TOOLCHAIN" cargo)

# Homebrew can install native `cargo`/`rustc` alongside rustup without
# installing rustup's proxy binaries in ~/.cargo/bin. Cross-target standard
# libraries belong to the rustup toolchain, so invoke that cargo and compiler
# explicitly instead of relying on whichever pair happens to win PATH.
rustup target add --toolchain "$COVE_RUSTUP_TOOLCHAIN" \
    aarch64-apple-darwin \
    x86_64-apple-darwin \
    aarch64-unknown-linux-musl \
    x86_64-unknown-linux-musl

rm -rf "$artifact_root"
mkdir -p "$artifact_root"

build_target() {
    target=$1
    builder=$2
    destination="$artifact_root/$target"
    mkdir -p "$destination"

    if [ "$builder" = "cargo" ]; then
        RUSTC="$COVE_RUSTC" "$COVE_CARGO" build \
            --manifest-path "$repository_root/helper/Cargo.toml" \
            --locked \
            --release \
            --target "$target"
    else
        RUSTC="$COVE_RUSTC" "$COVE_CARGO" zigbuild \
            --manifest-path "$repository_root/helper/Cargo.toml" \
            --locked \
            --release \
            --target "$target"
    fi

    cp -f \
        "$repository_root/helper/target/$target/release/codex-cove" \
        "$destination/codex-cove"
    chmod 0755 "$destination/codex-cove"
}

build_target aarch64-apple-darwin cargo
build_target x86_64-apple-darwin cargo
build_target aarch64-unknown-linux-musl cargo-zigbuild
build_target x86_64-unknown-linux-musl cargo-zigbuild

(
    cd "$artifact_root"
    find . -type f -name codex-cove -print | LC_ALL=C sort | while IFS= read -r artifact; do
        shasum -a 256 "$artifact"
    done
) >"$manifest_path"

printf '%s\n' "$artifact_root"
