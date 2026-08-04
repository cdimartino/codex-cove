#!/bin/sh
set -eu

fail() {
    printf 'homebrew-cask-version: %s\n' "$1" >&2
    exit 1
}

[ "$#" -eq 1 ] ||
    fail "usage: scripts/read-homebrew-cask-version.sh <cask-path>"

cask_path=$1
[ -f "$cask_path" ] && [ ! -L "$cask_path" ] ||
    fail "cask must be a real file"

versions=$(sed -nE 's/^[[:space:]]*version "([^"]+)"[[:space:]]*$/\1/p' "$cask_path") ||
    fail "could not read the cask version"
version_count=$(printf '%s\n' "$versions" | awk 'NF { count++ } END { print count + 0 }')
[ "$version_count" -eq 1 ] || fail "cask must contain exactly one version stanza"
version=$(printf '%s\n' "$versions" | awk 'NF { print; exit }')
printf '%s\n' "$version" |
    grep -Eq '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$' ||
    fail "cask version must be semantic major.minor.patch without leading zeroes"

printf '%s\n' "$version"
