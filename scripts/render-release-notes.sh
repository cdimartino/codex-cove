#!/bin/sh
set -eu
set -f

fail() {
    printf 'release-notes: %s\n' "$1" >&2
    exit 1
}

sha256_file() {
    sha256_output=$(shasum -a 256 <"$1") ||
        fail "could not hash candidate input"
    sha256_value=${sha256_output%% *}
    case "$sha256_value" in
        '' | *[!0-9a-f]*) fail "SHA-256 tool returned an invalid digest" ;;
    esac
    [ "${#sha256_value}" -eq 64 ] ||
        fail "SHA-256 tool returned an invalid digest"
    printf '%s' "$sha256_value"
}

[ "$#" -ge 1 ] && [ "$#" -le 2 ] ||
    fail "usage: scripts/render-release-notes.sh <vMAJOR.MINOR.PATCH> [source-root]"

release_tag=$1
printf '%s\n' "$release_tag" |
    grep -Eq '^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$' ||
    fail "release tag must match vMAJOR.MINOR.PATCH without leading zeroes"

if [ "$#" -eq 2 ]; then
    source_root_input=$2
else
    source_root_input=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd -P)
fi
[ -d "$source_root_input" ] && [ ! -L "$source_root_input" ] ||
    fail "source root must be a real directory"
source_root=$(CDPATH= cd -- "$source_root_input" && pwd -P)

release_version=${release_tag#v}
template_path="$source_root/docs/releases/$release_tag.md"
manifest_path="$source_root/SOURCE_CANDIDATE.manifest"
digest_path="$source_root/SOURCE_CANDIDATE.sha256"
digest_token='{{SOURCE_CANDIDATE_DIGEST}}'

[ -f "$template_path" ] && [ ! -L "$template_path" ] ||
    fail "candidate-bound release notes are missing or unsafe: docs/releases/$release_tag.md"
[ -f "$manifest_path" ] && [ ! -L "$manifest_path" ] ||
    fail "source-candidate manifest is missing or unsafe"
[ -f "$digest_path" ] && [ ! -L "$digest_path" ] ||
    fail "source-candidate digest is missing or unsafe"

[ "$(sed -n '1p' "$template_path")" = "# Codex Cove $release_version" ] ||
    fail "release notes have the wrong version heading"
binding_count=$(grep -Fxc "<!-- release-tag: $release_tag -->" "$template_path" || true)
[ "$binding_count" -eq 1 ] || fail "release notes must contain one exact tag binding"
visible_tag_line=$(printf 'Source tag: `%s`' "$release_tag")
visible_tag_count=$(grep -Fxc "$visible_tag_line" "$template_path" || true)
[ "$visible_tag_count" -eq 1 ] ||
    fail "release notes must contain one exact visible source tag"

candidate_digest=$(sed -n '1p' "$digest_path")
case "$candidate_digest" in
    '' | *[!0-9a-f]*) fail "source-candidate digest is invalid" ;;
esac
[ "${#candidate_digest}" -eq 64 ] || fail "source-candidate digest is invalid"
[ "$(awk 'END { print NR }' "$digest_path")" -eq 1 ] ||
    fail "source-candidate digest file must contain exactly one line"

[ "$(sed -n '1p' "$manifest_path")" = "codex-cove-source-candidate-v2" ] ||
    fail "source-candidate manifest header is invalid"
manifest_digest=$(sha256_file "$manifest_path")
[ "$manifest_digest" = "$candidate_digest" ] ||
    fail "source-candidate digest does not hash the manifest"

template_digest=$(sha256_file "$template_path")
template_relative_path="docs/releases/$release_tag.md"
template_record_count=$(
    awk -F '\t' -v path="$template_relative_path" '
        NR > 1 && $3 == path { count++ }
        END { print count + 0 }
    ' "$manifest_path"
)
[ "$template_record_count" -eq 1 ] ||
    fail "source-candidate manifest must contain exactly one release-notes record"
expected_template_record=$(printf '0644\t%s\t%s' "$template_digest" "$template_relative_path")
matching_template_record_count=$(grep -Fxc "$expected_template_record" "$manifest_path" || true)
[ "$matching_template_record_count" -eq 1 ] ||
    fail "release-notes template does not match the source-candidate manifest"

token_count=$(
    awk -v token="$digest_token" '
        {
            remaining = $0
            while ((position = index(remaining, token)) != 0) {
                count++
                remaining = substr(remaining, position + length(token))
            }
        }
        END { print count + 0 }
    ' "$template_path"
)
[ "$token_count" -eq 1 ] ||
    fail "release notes must contain exactly one $digest_token token"

awk -v token="$digest_token" -v digest="$candidate_digest" '
    {
        position = index($0, token)
        if (position == 0) {
            print
            next
        }
        print substr($0, 1, position - 1) digest \
            substr($0, position + length(token))
    }
' "$template_path"
