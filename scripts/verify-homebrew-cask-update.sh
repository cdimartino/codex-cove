#!/bin/sh
set -eu

fail() {
    printf 'homebrew-cask-update: %s\n' "$1" >&2
    exit 1
}

[ "$#" -eq 2 ] ||
    fail "usage: scripts/verify-homebrew-cask-update.sh <committed-cask> <candidate-cask>"

repository_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd -P)
committed_cask=$1
candidate_cask=$2
candidate_version=$("$repository_root/scripts/read-homebrew-cask-version.sh" "$candidate_cask")

if [ ! -e "$committed_cask" ] && [ ! -L "$committed_cask" ]; then
    printf 'Homebrew cask %s is the first committed version.\n' "$candidate_version"
    exit 0
fi

committed_version=$("$repository_root/scripts/read-homebrew-cask-version.sh" "$committed_cask")

split_version() {
    old_ifs=$IFS
    IFS=.
    set -- $1
    IFS=$old_ifs
    printf '%s\n%s\n%s\n' "$1" "$2" "$3"
}

component_compare() {
    awk -v candidate="$1" -v committed="$2" 'BEGIN {
        if (length(candidate) < length(committed)) {
            print -1
        } else if (length(candidate) > length(committed)) {
            print 1
        } else if (candidate == committed) {
            print 0
        } else if (("x" candidate) < ("x" committed)) {
            print -1
        } else {
            print 1
        }
    }'
}

committed_components=$(split_version "$committed_version")
candidate_components=$(split_version "$candidate_version")
for position in 1 2 3; do
    committed_component=$(printf '%s\n' "$committed_components" | sed -n "${position}p")
    candidate_component=$(printf '%s\n' "$candidate_components" | sed -n "${position}p")
    comparison=$(component_compare "$candidate_component" "$committed_component")
    case "$comparison" in
        1)
            printf 'Homebrew cask version advances from %s to %s.\n' \
                "$committed_version" "$candidate_version"
            exit 0
            ;;
        -1)
            fail "candidate version $candidate_version is older than committed version $committed_version"
            ;;
        0) ;;
        *) fail "could not compare cask versions" ;;
    esac
done

fail "candidate version $candidate_version must be newer than committed version $committed_version"
