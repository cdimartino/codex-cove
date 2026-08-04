#!/bin/sh
set -eu
set -f

fail() {
    printf 'release-notes-test: %s\n' "$1" >&2
    exit 1
}

repository_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd -P)
renderer="$repository_root/scripts/render-release-notes.sh"
temporary_root=$(mktemp -d "${TMPDIR:-/tmp}/codex-cove-release-notes-test.XXXXXX")
cleanup() {
    rm -rf -- "$temporary_root"
}
trap cleanup EXIT HUP INT TERM

release_tag=v1.2.3
release_version=1.2.3
digest_token='{{SOURCE_CANDIDATE_DIGEST}}'
fixture_root="$temporary_root/source"
template_directory="$fixture_root/docs/releases"
template_path="$template_directory/$release_tag.md"
manifest_path="$fixture_root/SOURCE_CANDIDATE.manifest"
digest_path="$fixture_root/SOURCE_CANDIDATE.sha256"
rendered_path="$temporary_root/rendered.md"
expected_path="$temporary_root/expected.md"

mkdir -p "$template_directory"
[ -x "$renderer" ] || fail "renderer is missing or not executable"

sha256_file() {
    shasum -a 256 <"$1" | awk '{ print $1 }'
}

write_valid_template() {
    {
        printf '%s\n' "# Codex Cove $release_version"
        printf '%s\n' "<!-- release-tag: $release_tag -->"
        printf '\n'
        printf 'Source tag: `%s`\n' "$release_tag"
        printf '\n'
        printf '%s\n' 'Frozen source-candidate manifest SHA-256:'
        printf '`%s`\n' "$digest_token"
    } >"$template_path"
}

refresh_manifest() {
    template_digest=$(sha256_file "$template_path")
    {
        printf '%s\n' codex-cove-source-candidate-v2
        printf '0644\t%s\tdocs/releases/%s.md\n' \
            "$template_digest" "$release_tag"
    } >"$manifest_path"
    candidate_digest=$(sha256_file "$manifest_path")
    printf '%s\n' "$candidate_digest" >"$digest_path"
}

write_valid_fixture() {
    write_valid_template
    refresh_manifest
}

expect_rejected() {
    case_name=$1
    shift
    if "$@" \
        >"$temporary_root/$case_name.stdout" \
        2>"$temporary_root/$case_name.stderr"; then
        fail "renderer accepted $case_name"
    fi
}

replace_template() {
    sed_expression=$1
    sed "$sed_expression" "$template_path" >"$temporary_root/template.next"
    mv "$temporary_root/template.next" "$template_path"
    refresh_manifest
}

write_valid_fixture
sed "s/$digest_token/$candidate_digest/" "$template_path" >"$expected_path"
"$renderer" "$release_tag" "$fixture_root" >"$rendered_path"
cmp -s "$expected_path" "$rendered_path" ||
    fail "valid rendering did not preserve the template and substitute the digest"

if grep -F "$digest_token" "$rendered_path" >/dev/null; then
    fail "rendered notes leaked the template token"
fi
expected_digest_line=$(printf '`%s`' "$candidate_digest")
rendered_digest_count=$(grep -Fxc "$expected_digest_line" "$rendered_path" || true)
[ "$rendered_digest_count" -eq 1 ] ||
    fail "rendered notes do not contain exactly one candidate digest"

write_valid_fixture
replace_template 's/{{SOURCE_CANDIDATE_DIGEST}}/digest intentionally omitted/'
expect_rejected missing-token "$renderer" "$release_tag" "$fixture_root"

write_valid_fixture
printf '\nDuplicate token: %s\n' "$digest_token" >>"$template_path"
refresh_manifest
expect_rejected duplicate-token "$renderer" "$release_tag" "$fixture_root"

write_valid_fixture
replace_template '1s/^# Codex Cove 1\.2\.3$/# Codex Cove 9.9.9/'
expect_rejected wrong-heading "$renderer" "$release_tag" "$fixture_root"

write_valid_fixture
replace_template '/^<!-- release-tag:/d'
expect_rejected missing-binding "$renderer" "$release_tag" "$fixture_root"

write_valid_fixture
printf '%s\n' "<!-- release-tag: $release_tag -->" >>"$template_path"
refresh_manifest
expect_rejected duplicate-binding "$renderer" "$release_tag" "$fixture_root"

write_valid_fixture
replace_template 's/^Source tag: `v1\.2\.3`$/Source tag: `v9.9.9`/'
expect_rejected wrong-visible-tag "$renderer" "$release_tag" "$fixture_root"

write_valid_fixture
printf 'Source tag: `%s`\n' "$release_tag" >>"$template_path"
refresh_manifest
expect_rejected duplicate-visible-tag "$renderer" "$release_tag" "$fixture_root"

write_valid_fixture
invalid_digest="${candidate_digest%?}g"
printf '%s\n' "$invalid_digest" >"$digest_path"
expect_rejected invalid-digest "$renderer" "$release_tag" "$fixture_root"

write_valid_fixture
printf '%s\n%s\n' "$candidate_digest" "$candidate_digest" >"$digest_path"
expect_rejected multiline-digest "$renderer" "$release_tag" "$fixture_root"

write_valid_fixture
printf '%s\n' '0644  malformed manifest record' >>"$manifest_path"
expect_rejected manifest-digest-mismatch "$renderer" "$release_tag" "$fixture_root"

write_valid_fixture
printf '\nTemplate changed after freeze.\n' >>"$template_path"
expect_rejected template-manifest-mismatch "$renderer" "$release_tag" "$fixture_root"

write_valid_fixture
sed '1s/.*/wrong-manifest-header/' "$manifest_path" >"$temporary_root/manifest.next"
mv "$temporary_root/manifest.next" "$manifest_path"
printf '%s\n' "$(sha256_file "$manifest_path")" >"$digest_path"
expect_rejected wrong-manifest-header "$renderer" "$release_tag" "$fixture_root"

write_valid_fixture
tail -n 1 "$manifest_path" >>"$manifest_path"
printf '%s\n' "$(sha256_file "$manifest_path")" >"$digest_path"
expect_rejected duplicate-manifest-record "$renderer" "$release_tag" "$fixture_root"

write_valid_fixture
sed 's/^0644/0755/' "$manifest_path" >"$temporary_root/manifest.next"
mv "$temporary_root/manifest.next" "$manifest_path"
printf '%s\n' "$(sha256_file "$manifest_path")" >"$digest_path"
expect_rejected wrong-manifest-mode "$renderer" "$release_tag" "$fixture_root"

write_valid_fixture
expect_rejected invalid-release-tag "$renderer" v01.2.3 "$fixture_root"

ln -s "$fixture_root" "$temporary_root/source-link"
expect_rejected symlink-source-root \
    "$renderer" "$release_tag" "$temporary_root/source-link"

printf 'Release-notes renderer tests passed.\n'
