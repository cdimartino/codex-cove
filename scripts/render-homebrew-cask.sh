#!/bin/sh
set -eu

fail() {
    printf 'homebrew-cask: %s\n' "$1" >&2
    exit 1
}

historical_release=0
historical_release_cask=
if [ "${1-}" = "--historical-release" ]; then
    [ "$#" -eq 4 ] ||
        fail "usage: scripts/render-homebrew-cask.sh --historical-release <verified-release-cask> <app-archive> <output-cask>"
    historical_release=1
    historical_release_cask=$2
    archive_path=$3
    output_path=$4
else
    [ "$#" -eq 3 ] ||
        fail "usage: scripts/render-homebrew-cask.sh <version-or-v-tag> <app-archive> <output-cask>"
    requested_version=$1
    archive_path=$2
    output_path=$3
fi

repository_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd -P)
template_path="$repository_root/Packaging/Homebrew/codex-cove.rb.template"

if [ "$historical_release" -eq 1 ]; then
    # The tap verifier uses this mode only after independently verifying the
    # immutable release Cask, archive, and checksum manifest. Source version
    # synchronization would make it impossible to re-render an older Cask
    # after the repository advances to the next release.
    version=$(
        "$repository_root/scripts/read-homebrew-cask-version.sh" \
            "$historical_release_cask"
    )
else
    version=$("$repository_root/scripts/verify-release-version.sh" "$requested_version")
fi

[ -f "$template_path" ] && [ ! -L "$template_path" ] ||
    fail "cask template is missing or unsafe"
[ -f "$archive_path" ] && [ ! -L "$archive_path" ] ||
    fail "app archive is missing or unsafe"

archive_name=${archive_path##*/}
expected_archive_name="Codex-Cove-$version-macos-arm64.zip"
[ "$archive_name" = "$expected_archive_name" ] ||
    fail "app archive must be named $expected_archive_name"

archive_sha256=$(shasum -a 256 "$archive_path" | awk '{ print $1 }') ||
    fail "could not hash the app archive"
case "$archive_sha256" in
    *[!0-9a-f]* | '') fail "app archive SHA-256 is invalid" ;;
esac
[ "${#archive_sha256}" -eq 64 ] || fail "app archive SHA-256 is invalid"

output_parent=$(dirname "$output_path")
[ -d "$output_parent" ] && [ ! -L "$output_parent" ] ||
    fail "output parent must be a real directory"
[ ! -L "$output_path" ] || fail "output cask must not be a symbolic link"

temporary=$(mktemp "$output_parent/.codex-cove-cask.XXXXXX") ||
    fail "could not create a temporary cask"
cleanup() {
    rm -f -- "$temporary"
}
trap cleanup EXIT HUP INT TERM

sed \
    -e "s/@VERSION@/$version/g" \
    -e "s/@SHA256@/$archive_sha256/g" \
    "$template_path" >"$temporary"

if grep -E '@(VERSION|SHA256)@|sha256[[:space:]]+:no_check' "$temporary" >/dev/null; then
    fail "rendered cask contains an unresolved or unsafe checksum token"
fi

chmod 0644 "$temporary"
mv -f -- "$temporary" "$output_path"
trap - EXIT HUP INT TERM

printf '%s\n' "$output_path"
