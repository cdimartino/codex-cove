#!/bin/sh
set -eu
set -f

fail() {
    printf 'release-workflow-test: %s\n' "$1" >&2
    exit 1
}

repository_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd -P)
workflow="$repository_root/.github/workflows/release.yml"
temporary_root=$(mktemp -d "${TMPDIR:-/tmp}/codex-cove-release-workflow-test.XXXXXX")
cleanup() {
    rm -rf -- "$temporary_root"
}
trap cleanup EXIT HUP INT TERM

[ -f "$workflow" ] && [ ! -L "$workflow" ] ||
    fail "release workflow is missing or unsafe"

extract_job() {
    job_name=$1
    output_path=$2
    awk -v heading="  $job_name:" '
        $0 == heading { active = 1 }
        active && $0 ~ /^  [A-Za-z0-9_-]+:$/ && $0 != heading { exit }
        active { print }
    ' "$workflow" >"$output_path"
    [ -s "$output_path" ] || fail "missing workflow job: $job_name"
}

require_text() {
    file_path=$1
    expected=$2
    description=$3
    grep -F -- "$expected" "$file_path" >/dev/null || fail "$description"
}

reject_text() {
    file_path=$1
    rejected=$2
    description=$3
    if grep -F -- "$rejected" "$file_path" >/dev/null; then
        fail "$description"
    fi
}

preflight="$temporary_root/preflight.yml"
build_release="$temporary_root/build-release.yml"
publish="$temporary_root/publish.yml"
verify_cask="$temporary_root/verify-cask.yml"
update_cask="$temporary_root/update-cask.yml"
extract_job preflight "$preflight"
extract_job build-release "$build_release"
extract_job publish "$publish"
extract_job verify-homebrew-cask "$verify_cask"
extract_job update-homebrew-cask "$update_cask"

require_text "$preflight" 'contents: read' \
    "preflight must remain read-only"
require_text "$preflight" 'persist-credentials: false' \
    "preflight checkout must not persist credentials"
require_text "$preflight" 'if [[ "$source_sha" != "$GITHUB_SHA" ]]; then' \
    "preflight must require the tag to name the exact dispatched commit"
require_text "$preflight" 'make verify-release-readiness' \
    "preflight must strictly verify the complete release candidate"
require_text "$preflight" './scripts/render-release-notes.sh "$RELEASE_TAG"' \
    "preflight must render candidate-bound release notes"

require_text "$build_release" 'environment: release' \
    "signing job must use the protected release environment"
require_text "$build_release" 'contents: read' \
    "signing job must remain repository-read-only"
require_text "$build_release" 'persist-credentials: false' \
    "signing checkout must not persist credentials"

require_text "$publish" 'environment: release' \
    "publisher must use the protected release environment"
require_text "$publish" 'contents: write' \
    "publisher must scope write permission to release publication"
require_text "$publish" 'persist-credentials: false' \
    "publisher checkout must not persist credentials"
require_text "$publish" '--notes-file "$rendered_release_notes"' \
    "publisher must use the rendered candidate-bound notes"
require_text "$publish" 'verify_release_notes' \
    "publisher must compare the stored release body"
require_text "$publish" 'isImmutable' \
    "publisher must verify immutable release state"
reject_text "$publish" '--generate-notes' \
    "publisher must not generate post-approval release notes"

require_text "$verify_cask" 'contents: read' \
    "Homebrew verification must remain read-only"
require_text "$verify_cask" 'persist-credentials: false' \
    "Homebrew verification checkout must not persist credentials"
require_text "$verify_cask" 'brew style --cask' \
    "read-only Homebrew job must run style"
require_text "$verify_cask" 'brew audit --cask' \
    "read-only Homebrew job must run audit"
require_text "$verify_cask" 'HOMEBREW_GITHUB_API_TOKEN: ${{ github.token }}' \
    "Homebrew audit must authenticate GitHub API requests"
require_text "$verify_cask" 'name: validated-homebrew-cask' \
    "read-only Homebrew job must upload the validated Cask handoff"
require_text "$verify_cask" \
    'for source_file in SOURCE_CANDIDATE.manifest SOURCE_CANDIDATE.sha256 "$RELEASE_NOTES_PATH"; do' \
    "read-only Homebrew verification must extract the manifest used by the notes renderer"

require_text "$update_cask" 'contents: write' \
    "Cask staging job must be the minimal write job"
require_text "$update_cask" 'persist-credentials: true' \
    "only Cask staging may persist the push credential"
require_text "$update_cask" 'name: validated-homebrew-cask' \
    "Cask staging must consume the validated artifact"
require_text "$update_cask" 'isImmutable' \
    "Cask staging must reverify immutable release state"
require_text "$update_cask" 'resolve-github-tag.sh' \
    "Cask staging must re-resolve the immutable tag"
require_text "$update_cask" 'release-notes.md' \
    "Cask staging must reverify rendered release notes"
require_text "$update_cask" \
    'for source_file in SOURCE_CANDIDATE.manifest SOURCE_CANDIDATE.sha256 "$RELEASE_NOTES_PATH"; do' \
    "Cask staging must extract the manifest used by the notes renderer"
require_text "$update_cask" 'shasum -a 256 -c SHA256SUMS' \
    "Cask staging must reverify release checksums"
require_text "$update_cask" 'cmp -s validated-homebrew-cask/codex-cove.rb published-release/codex-cove.rb' \
    "Cask staging must compare the validated and published Cask bytes"
reject_text "$update_cask" 'brew style' \
    "credentialed Cask staging must not evaluate Homebrew content"
reject_text "$update_cask" 'brew audit' \
    "credentialed Cask staging must not audit Homebrew content"
reject_text "$update_cask" 'HOMEBREW_' \
    "credentialed Cask staging must not execute Homebrew"

persisted_checkout_count=$(grep -Fc 'persist-credentials: true' "$workflow" || true)
[ "$persisted_checkout_count" -eq 1 ] ||
    fail "exactly one workflow checkout may persist credentials"

printf 'Release-workflow invariants passed.\n'
