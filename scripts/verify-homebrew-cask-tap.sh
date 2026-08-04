#!/bin/sh
set -eu

fail() {
    printf 'homebrew-cask-tap: %s\n' "$1" >&2
    exit 1
}

[ "$#" -eq 2 ] ||
    fail "usage: scripts/verify-homebrew-cask-tap.sh <committed-cask> <release-directory>"

repository_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd -P)
committed_cask=$1
release_directory=$2
release_cask="$release_directory/codex-cove.rb"

# Preserve the immutable release evidence independently from the live tap.
"$repository_root/scripts/verify-homebrew-cask-release.sh" \
    "$release_cask" "$release_directory" >/dev/null

committed_version=$(
    "$repository_root/scripts/read-homebrew-cask-version.sh" "$committed_cask"
)
release_version=$(
    "$repository_root/scripts/read-homebrew-cask-version.sh" "$release_cask"
)
[ "$committed_version" = "$release_version" ] ||
    fail "committed cask version does not match the immutable release"

archive_path="$release_directory/Codex-Cove-$release_version-macos-arm64.zip"
temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/codex-cove-tap-cask.XXXXXX") ||
    fail "could not create a temporary rendering directory"
cleanup() {
    rm -rf -- "$temporary_directory"
}
trap cleanup EXIT HUP INT TERM

rendered_cask="$temporary_directory/codex-cove.rb"
"$repository_root/scripts/render-homebrew-cask.sh" \
    "v$release_version" "$archive_path" "$rendered_cask" >/dev/null
cmp -s "$committed_cask" "$rendered_cask" ||
    fail "committed cask is not the deterministic output of the current template"

printf 'Homebrew tap cask %s deterministically targets the immutable release archive.\n' \
    "$committed_version"
