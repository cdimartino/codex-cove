#!/bin/sh
set -eu

fail() {
    printf 'homebrew-cask-test: %s\n' "$1" >&2
    exit 1
}

repository_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd -P)
version=$(
    /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
        "$repository_root/Packaging/Info.plist"
)
version=$("$repository_root/scripts/verify-release-version.sh" "$version")
temporary_root=$(mktemp -d "${TMPDIR:-/tmp}/codex-cove-homebrew-test.XXXXXX")
cleanup() {
    rm -rf -- "$temporary_root"
}
trap cleanup EXIT HUP INT TERM

archive_path="$temporary_root/Codex-Cove-$version-macos-arm64.zip"
cask_directory="$temporary_root/Casks"
cask_path="$cask_directory/codex-cove.rb"
mkdir "$cask_directory"
printf 'deterministic fake Codex Cove archive for cask rendering tests\n' >"$archive_path"
expected_sha256=$(shasum -a 256 "$archive_path" | awk '{ print $1 }')

"$repository_root/scripts/render-homebrew-cask.sh" \
    "v$version" \
    "$archive_path" \
    "$cask_path" >/dev/null

grep -F 'cask "codex-cove" do' "$cask_path" >/dev/null ||
    fail "rendered cask token is missing"
grep -F "version \"$version\"" "$cask_path" >/dev/null ||
    fail "rendered cask version is missing"
grep -F "sha256 \"$expected_sha256\"" "$cask_path" >/dev/null ||
    fail "rendered cask checksum does not match the archive"
grep -F 'releases/download/v#{version}/Codex-Cove-#{version}-macos-arm64.zip' \
    "$cask_path" >/dev/null || fail "rendered cask URL is not version-pinned"
grep -F 'app "Codex Cove.app", target: "~/Applications/Codex Cove.app"' \
    "$cask_path" >/dev/null || fail "cask does not force the canonical app path"
grep -F 'args: ["install", "--app-path", app_path]' "$cask_path" >/dev/null ||
    fail "postflight helper installation is missing"
grep -F 'env:  { "PATH" => ENV.fetch("HOMEBREW_PATH", ENV.fetch("PATH")) }' \
    "$cask_path" >/dev/null || fail "postflight does not restore Homebrew's caller PATH"
grep -F '["--sync-login-item-and-quit"]' "$cask_path" >/dev/null ||
    fail "postflight login-item synchronization is missing"
grep -F 'timeout: 10' "$cask_path" >/dev/null ||
    fail "postflight login-item synchronization is not bounded"
grep -F '["--unregister-login-item-and-quit"]' "$cask_path" >/dev/null ||
    fail "postflight failure compensation is missing"
grep -F 'ENV["PATH"] = ENV.fetch("HOMEBREW_PATH", ENV.fetch("PATH"))' \
    "$cask_path" >/dev/null || fail "uninstall does not restore Homebrew's caller PATH"
grep -F 'args:       ["uninstall", "--keep-settings", "--keep-app"]' \
    "$cask_path" >/dev/null || fail "package-manager-safe uninstall is missing"
grep -F '"~/Library/Application Support/Codex Cove"' "$cask_path" >/dev/null ||
    fail "zap does not remove application support"
grep -F '"~/Library/Preferences/local.chris.codexcove.plist"' "$cask_path" >/dev/null ||
    fail "zap does not remove preferences"
grep -F '"~/Library/Saved Application State/local.chris.codexcove.savedState"' \
    "$cask_path" >/dev/null || fail "zap does not remove saved application state"

quit_line=$(grep -n 'uninstall quit:' "$cask_path" | cut -d: -f1)
script_line=$(grep -n 'script: {' "$cask_path" | cut -d: -f1)
[ -n "$quit_line" ] && [ -n "$script_line" ] && [ "$quit_line" -lt "$script_line" ] ||
    fail "uninstall must quit the app before invoking the embedded helper"

if grep -E '@(VERSION|SHA256)@|sha256[[:space:]]+:no_check' "$cask_path" >/dev/null; then
    fail "rendered cask contains an unresolved or unsafe checksum token"
fi

wrong_archive="$temporary_root/not-the-release-asset.zip"
cp "$archive_path" "$wrong_archive"
if "$repository_root/scripts/render-homebrew-cask.sh" \
    "$version" "$wrong_archive" "$temporary_root/rejected.rb" >/dev/null 2>&1; then
    fail "renderer accepted an archive with a noncanonical filename"
fi

write_cask_version() {
    replacement_version=$1
    replacement_path=$2
    sed -E \
        "s/^  version \"[0-9]+\\.[0-9]+\\.[0-9]+\"$/  version \"$replacement_version\"/" \
        "$cask_path" >"$replacement_path"
}

old_cask="$temporary_root/old-cask.rb"
new_cask="$temporary_root/new-cask.rb"
equal_cask="$temporary_root/equal-cask.rb"
large_old_cask="$temporary_root/large-old-cask.rb"
large_new_cask="$temporary_root/large-new-cask.rb"
leading_zero_cask="$temporary_root/leading-zero-cask.rb"
trailing_dot_cask="$temporary_root/trailing-dot-cask.rb"
write_cask_version 0.1.9 "$old_cask"
write_cask_version 0.2.0 "$new_cask"
write_cask_version 0.2.0 "$equal_cask"
write_cask_version 9.99.99 "$large_old_cask"
write_cask_version 10.0.0 "$large_new_cask"
write_cask_version 00.2.1 "$leading_zero_cask"
write_cask_version 1.2.3. "$trailing_dot_cask"

"$repository_root/scripts/verify-homebrew-cask-update.sh" \
    "$temporary_root/not-yet-committed.rb" "$new_cask" >/dev/null
"$repository_root/scripts/verify-homebrew-cask-update.sh" \
    "$old_cask" "$new_cask" >/dev/null
"$repository_root/scripts/verify-homebrew-cask-update.sh" \
    "$large_old_cask" "$large_new_cask" >/dev/null
if "$repository_root/scripts/verify-homebrew-cask-update.sh" \
    "$new_cask" "$equal_cask" >/dev/null 2>&1; then
    fail "cask update guard accepted an equal version"
fi
if "$repository_root/scripts/verify-homebrew-cask-update.sh" \
    "$new_cask" "$old_cask" >/dev/null 2>&1; then
    fail "cask update guard accepted an older version"
fi
if "$repository_root/scripts/read-homebrew-cask-version.sh" \
    "$leading_zero_cask" >/dev/null 2>&1; then
    fail "cask version reader accepted a leading-zero component"
fi
if "$repository_root/scripts/read-homebrew-cask-version.sh" \
    "$trailing_dot_cask" >/dev/null 2>&1; then
    fail "cask version reader accepted a non-semantic trailing dot"
fi

release_directory="$temporary_root/release"
mkdir "$release_directory"
cp "$cask_path" "$release_directory/codex-cove.rb"
cp "$archive_path" "$release_directory/Codex-Cove-$version-macos-arm64.zip"

write_release_checksums() {
    release_archive_sha=$(shasum -a 256 \
        "$release_directory/Codex-Cove-$version-macos-arm64.zip" | awk '{ print $1 }')
    release_cask_sha=$(shasum -a 256 \
        "$release_directory/codex-cove.rb" | awk '{ print $1 }')
    printf '%s  ./%s\n%s  ./%s\n' \
        "$release_archive_sha" "Codex-Cove-$version-macos-arm64.zip" \
        "$release_cask_sha" codex-cove.rb >"$release_directory/SHA256SUMS"
}

write_release_checksums
"$repository_root/scripts/verify-homebrew-cask-release.sh" \
    "$cask_path" "$release_directory" >/dev/null

printf '\n' >>"$release_directory/codex-cove.rb"
write_release_checksums
if "$repository_root/scripts/verify-homebrew-cask-release.sh" \
    "$cask_path" "$release_directory" >/dev/null 2>&1; then
    fail "release verifier accepted a cask asset with different bytes"
fi
cp "$cask_path" "$release_directory/codex-cove.rb"

printf 'tampered archive\n' >>"$release_directory/Codex-Cove-$version-macos-arm64.zip"
write_release_checksums
if "$repository_root/scripts/verify-homebrew-cask-release.sh" \
    "$cask_path" "$release_directory" >/dev/null 2>&1; then
    fail "release verifier accepted a cask SHA that does not match the app archive"
fi
cp "$archive_path" "$release_directory/Codex-Cove-$version-macos-arm64.zip"
write_release_checksums

printf '%064d  ./%s\n' 0 "Codex-Cove-$version-macos-arm64.zip" \
    >"$release_directory/SHA256SUMS"
if "$repository_root/scripts/verify-homebrew-cask-release.sh" \
    "$cask_path" "$release_directory" >/dev/null 2>&1; then
    fail "release verifier accepted an incomplete or incorrect checksum manifest"
fi

release_workflow="$repository_root/.github/workflows/release.yml"
audit_copy_line=$(grep -nF \
    'cp published-release/codex-cove.rb "$audit_repository/Casks/codex-cove.rb"' \
    "$release_workflow" | cut -d: -f1)
audit_commit_line=$(grep -nF "commit -qm 'audit exact released cask'" \
    "$release_workflow" | cut -d: -f1)
audit_tap_line=$(grep -nF 'brew tap "$audit_tap" "$audit_repository"' \
    "$release_workflow" | cut -d: -f1)
[ -n "$audit_copy_line" ] && [ -n "$audit_commit_line" ] && [ -n "$audit_tap_line" ] &&
    [ "$audit_copy_line" -lt "$audit_commit_line" ] &&
    [ "$audit_commit_line" -lt "$audit_tap_line" ] ||
    fail "release workflow does not commit the exact candidate before tapping it"
grep -F 'cmp -s published-release/codex-cove.rb "$tapped_cask"' \
    "$release_workflow" >/dev/null ||
    fail "release workflow does not byte-verify the disposable tapped cask"
grep -F 'brew audit --cask --new "$audit_tap/codex-cove"' \
    "$release_workflow" >/dev/null ||
    fail "first-release workflow does not audit the disposable candidate as a new cask"

ci_workflow="$repository_root/.github/workflows/ci.yml"
no_cask_guard_line=$(grep -nF \
    'if [[ ! -e "$cask_path" && ! -L "$cask_path" ]]; then' \
    "$ci_workflow" | cut -d: -f1)
first_release_query_line=$(grep -nF \
    'gh repo view "$GITHUB_REPOSITORY"' \
    "$ci_workflow" | cut -d: -f1)
[ -n "$no_cask_guard_line" ] && [ -n "$first_release_query_line" ] &&
    [ "$no_cask_guard_line" -lt "$first_release_query_line" ] ||
    fail "CI does not skip network release verification before the first committed cask"

if command -v brew >/dev/null 2>&1; then
    brew ruby \
        "$repository_root/Tests/HomebrewCaskPostflightTests/main.rb" \
        "$cask_path"
    brew ruby -e '
      require "cask/cask_loader"
      require "cask/auditor"
      cask = Cask::CaskLoader.load(File.read(ARGV.fetch(0)))
      errors = Cask::Auditor.audit(
        cask,
        audit_download: false,
        audit_online: false,
        audit_signing: false,
        audit_strict: true,
        any_named_args: true,
      )
      errors.each { |error| warn error.to_s }
      exit(errors.empty? ? 0 : 1)
    ' "$cask_path"
    HOMEBREW_CACHE="$temporary_root/homebrew-cache" \
        HOMEBREW_DEVELOPER=1 \
        brew style --cask "$cask_path"
fi

printf 'Homebrew cask rendering tests passed.\n'
