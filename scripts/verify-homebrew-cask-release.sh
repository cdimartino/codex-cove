#!/bin/sh
set -eu

fail() {
    printf 'homebrew-cask-release: %s\n' "$1" >&2
    exit 1
}

[ "$#" -eq 2 ] ||
    fail "usage: scripts/verify-homebrew-cask-release.sh <committed-cask> <release-directory>"

repository_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd -P)
committed_cask=$1
release_directory=$2
[ -d "$release_directory" ] && [ ! -L "$release_directory" ] ||
    fail "release directory must be a real directory"

version=$("$repository_root/scripts/read-homebrew-cask-version.sh" "$committed_cask")
archive_name="Codex-Cove-$version-macos-arm64.zip"
expected_url='https://github.com/cdimartino/codex-cove/releases/download/v#{version}/Codex-Cove-#{version}-macos-arm64.zip'
release_cask="$release_directory/codex-cove.rb"
release_archive="$release_directory/$archive_name"
release_checksums="$release_directory/SHA256SUMS"

for release_file in "$release_cask" "$release_archive" "$release_checksums"; do
    [ -f "$release_file" ] && [ ! -L "$release_file" ] ||
        fail "required release asset is missing or unsafe: ${release_file##*/}"
done

cmp -s "$committed_cask" "$release_cask" ||
    fail "committed cask is not byte-identical to the release cask asset"

cask_url_values=$(sed -nE 's/^[[:space:]]*url "([^"]+)",[[:space:]]*$/\1/p' "$committed_cask") ||
    fail "could not read the cask release URL"
cask_url_count=$(printf '%s\n' "$cask_url_values" | awk 'NF { count++ } END { print count + 0 }')
[ "$cask_url_count" -eq 1 ] || fail "cask must contain exactly one release URL stanza"
cask_url=$(printf '%s\n' "$cask_url_values" | awk 'NF { print; exit }')
[ "$cask_url" = "$expected_url" ] ||
    fail "cask URL is not the exact immutable version-tagged GitHub release URL"

cask_sha_values=$(sed -nE 's/^[[:space:]]*sha256 "([0-9a-f]+)"[[:space:]]*$/\1/p' "$committed_cask") ||
    fail "could not read the cask SHA-256"
cask_sha_count=$(printf '%s\n' "$cask_sha_values" | awk 'NF { count++ } END { print count + 0 }')
[ "$cask_sha_count" -eq 1 ] || fail "cask must contain exactly one SHA-256 stanza"
cask_sha=$(printf '%s\n' "$cask_sha_values" | awk 'NF { print; exit }')
case "$cask_sha" in
    *[!0-9a-f]* | '') fail "cask SHA-256 is invalid" ;;
esac
[ "${#cask_sha}" -eq 64 ] || fail "cask SHA-256 is invalid"

manifest_checksum() {
    manifest_name=$1
    awk -v expected="./$manifest_name" '
        $2 == expected {
            count++
            checksum = $1
            if (NF != 2 || length($1) != 64 || $1 ~ /[^0-9a-f]/) {
                invalid = 1
            }
        }
        END {
            if (count != 1 || invalid) {
                exit 1
            }
            print checksum
        }
    ' "$release_checksums"
}

manifest_archive_sha=$(manifest_checksum "$archive_name") ||
    fail "release checksum manifest has no unique valid entry for $archive_name"
manifest_cask_sha=$(manifest_checksum codex-cove.rb) ||
    fail "release checksum manifest has no unique valid entry for codex-cove.rb"
actual_archive_sha=$(shasum -a 256 "$release_archive" | awk '{ print $1 }') ||
    fail "could not hash the release app archive"
actual_cask_sha=$(shasum -a 256 "$release_cask" | awk '{ print $1 }') ||
    fail "could not hash the release cask"

[ "$cask_sha" = "$actual_archive_sha" ] ||
    fail "cask SHA-256 does not match the release app archive"
[ "$manifest_archive_sha" = "$actual_archive_sha" ] ||
    fail "release checksum for the app archive does not match the asset"
[ "$manifest_cask_sha" = "$actual_cask_sha" ] ||
    fail "release checksum for the cask does not match the asset"

printf 'Homebrew cask %s matches the immutable release assets and checksums.\n' "$version"
