#!/bin/sh
set -eu

fail() {
    printf 'resolve-github-tag: %s\n' "$*" >&2
    exit 1
}

[ "$#" -eq 2 ] || fail "usage: $0 <owner/repository> <vMAJOR.MINOR.PATCH>"

repository=$1
release_tag=$2

case $repository in
    */*) ;;
    *) fail "repository must be owner/name" ;;
esac

printf '%s\n' "$release_tag" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$' ||
    fail "tag must match vMAJOR.MINOR.PATCH"

read_object() {
    api_path=$1
    object_record=$(gh api "$api_path" --jq '.object | "\(.type) \(.sha)"') ||
        fail "GitHub did not return $api_path"
    set -- $object_record
    [ "$#" -eq 2 ] || fail "GitHub returned malformed tag metadata"
    object_type=$1
    object_sha=$2
    case $object_sha in
        '' | *[!0-9a-f]*) fail "GitHub returned an invalid object SHA" ;;
    esac
    [ "${#object_sha}" -eq 40 ] || fail "GitHub returned an invalid object SHA"
}

read_object "repos/$repository/git/ref/tags/$release_tag"
peel_depth=0
while [ "$object_type" = tag ]; do
    peel_depth=$((peel_depth + 1))
    [ "$peel_depth" -le 8 ] || fail "annotated tag chain is too deep"
    read_object "repos/$repository/git/tags/$object_sha"
done

[ "$object_type" = commit ] ||
    fail "tag resolves to unsupported object type: $object_type"

printf '%s\n' "$object_sha"
