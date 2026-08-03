#!/bin/sh
set -eu

fail() {
    printf 'release-assets: %s\n' "$1" >&2
    exit 1
}

[ "$#" -eq 1 ] || fail "usage: scripts/prepare-release-assets.sh <version-or-v-tag>"

repository_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd -P)
version=$("$repository_root/scripts/verify-release-version.sh" "$1")
CODEX_COVE_REQUIRE_RECORDED_STRICT_VERIFY=1 \
    "$repository_root/scripts/verify-release-readiness.sh" "$1" >/dev/null
build_root="$repository_root/build"
app_path="$build_root/Codex Cove.app"
extension_path="$repository_root/extension/dist/cove-extension.vsix"
remote_path="$app_path/Contents/Resources/remote"
release_parent="$build_root/release"
release_root="$release_parent/$version"

[ -d "$build_root" ] && [ ! -L "$build_root" ] ||
    fail "build must be a real directory inside the repository"
[ -d "$app_path" ] && [ ! -L "$app_path" ] || fail "packaged app bundle is missing"
[ -f "$app_path/Contents/Info.plist" ] && [ ! -L "$app_path/Contents/Info.plist" ] ||
    fail "packaged app Info.plist is missing or unsafe"
[ -x "$app_path/Contents/MacOS/CodexCove" ] &&
    [ -f "$app_path/Contents/MacOS/CodexCove" ] &&
    [ ! -L "$app_path/Contents/MacOS/CodexCove" ] ||
    fail "packaged app executable is missing or unsafe"
[ -x "$app_path/Contents/Resources/bin/codex-cove" ] &&
    [ -f "$app_path/Contents/Resources/bin/codex-cove" ] &&
    [ ! -L "$app_path/Contents/Resources/bin/codex-cove" ] ||
    fail "embedded helper is missing or unsafe"
[ -f "$extension_path" ] && [ ! -L "$extension_path" ] ||
    fail "packaged editor extension is missing"
[ -f "$remote_path/SHA256SUMS" ] && [ ! -L "$remote_path/SHA256SUMS" ] ||
    fail "remote helper checksum manifest is missing"
[ -f "$repository_root/SOURCE_CANDIDATE.manifest" ] ||
    fail "source-candidate manifest is missing"
[ -f "$repository_root/SOURCE_CANDIDATE.sha256" ] ||
    fail "source-candidate digest is missing"
[ -f "$repository_root/SOURCE_CANDIDATE.receipt" ] ||
    fail "source-candidate receipt is missing"

packaged_version=$(
    /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
        "$app_path/Contents/Info.plist"
) || fail "could not read the packaged app version"
[ "$packaged_version" = "$version" ] ||
    fail "packaged app version $packaged_version does not match $version"
packaged_build=$(
    /usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \
        "$app_path/Contents/Info.plist"
) || fail "could not read the packaged app build number"
source_build=$(
    /usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \
        "$repository_root/Packaging/Info.plist"
) || fail "could not read the source app build number"
[ "$packaged_build" = "$source_build" ] ||
    fail "packaged app build number does not match the source"
packaged_identifier=$(
    /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
        "$app_path/Contents/Info.plist"
) || fail "could not read the packaged app identifier"
[ "$packaged_identifier" = local.chris.codexcove ] ||
    fail "packaged app identifier is not local.chris.codexcove"
packaged_executable=$(
    /usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' \
        "$app_path/Contents/Info.plist"
) || fail "could not read the packaged app executable name"
[ "$packaged_executable" = CodexCove ] ||
    fail "packaged app executable name is not CodexCove"

native_helper_version=$("$app_path/Contents/Resources/bin/codex-cove" --version) ||
    fail "could not read the embedded helper version"
[ "$native_helper_version" = "codex-cove $version" ] ||
    fail "embedded helper version does not match $version"

extension_archive_version=$(
    unzip -p "$extension_path" extension/package.json |
        node -e 'const fs=require("node:fs"); const p=JSON.parse(fs.readFileSync(0,"utf8")); process.stdout.write(String(p.version || ""));'
) || fail "could not read the packaged editor extension version"
[ "$extension_archive_version" = "$version" ] ||
    fail "packaged editor extension version does not match $version"
cmp -s "$extension_path" \
    "$app_path/Contents/Resources/extension/codex-cove.vsix" ||
    fail "embedded editor extension does not match the published VSIX"

expected_remote_files='./SHA256SUMS
./aarch64-apple-darwin/codex-cove
./aarch64-unknown-linux-musl/codex-cove
./x86_64-apple-darwin/codex-cove
./x86_64-unknown-linux-musl/codex-cove'
actual_remote_files=$(
    cd "$remote_path"
    find -P . -type f -print | LC_ALL=C sort
) || fail "could not inspect the remote helper layout"
[ "$actual_remote_files" = "$expected_remote_files" ] ||
    fail "remote bundle must contain exactly the four supported helpers"
[ -z "$(find -P "$remote_path" ! -type d ! -type f -print -quit)" ] ||
    fail "remote bundle contains a symbolic link or special entry"

codesign --verify --deep --strict --verbose=2 "$app_path"
codesign_details=$(codesign -dv --verbose=4 "$app_path" 2>&1) ||
    fail "could not inspect the app signature"
printf '%s\n' "$codesign_details" | grep '^Authority=Developer ID Application: ' >/dev/null ||
    fail "app is not signed with Developer ID Application"
team_identifier=$(printf '%s\n' "$codesign_details" | sed -n 's/^TeamIdentifier=//p')
[ -n "$team_identifier" ] && [ "$team_identifier" != "not set" ] ||
    fail "app signature has no TeamIdentifier"
printf '%s\n' "$codesign_details" | grep '^Authority=Developer ID Application: ' >/dev/null ||
    fail "app signature is not a Developer ID Application signature"
printf '%s\n' "$codesign_details" | grep '^Timestamp=' >/dev/null ||
    fail "app signature has no trusted timestamp"
printf '%s\n' "$codesign_details" | grep '^CodeDirectory .*flags=.*runtime' >/dev/null ||
    fail "app signature does not enable the hardened runtime"
xcrun stapler validate "$app_path" >/dev/null || fail "app has no valid notarization ticket"
spctl --assess --type execute --verbose=4 "$app_path" ||
    fail "Gatekeeper rejected the packaged app"

app_architectures=$(lipo -archs "$app_path/Contents/MacOS/CodexCove") ||
    fail "could not inspect the app architecture"
[ "$app_architectures" = arm64 ] || fail "release app must be arm64"
helper_architectures=$(lipo -archs "$app_path/Contents/Resources/bin/codex-cove") ||
    fail "could not inspect the embedded helper architecture"
[ "$helper_architectures" = arm64 ] || fail "embedded helper must be arm64"

verify_developer_id_binary() {
    binary_path=$1
    binary_label=$2
    codesign --verify --strict --verbose=2 "$binary_path" ||
        fail "$binary_label has an invalid code signature"
    binary_details=$(codesign -dv --verbose=4 "$binary_path" 2>&1) ||
        fail "could not inspect the $binary_label signature"
    printf '%s\n' "$binary_details" | grep '^Authority=Developer ID Application: ' >/dev/null ||
        fail "$binary_label is not signed with Developer ID Application"
    binary_team=$(printf '%s\n' "$binary_details" | sed -n 's/^TeamIdentifier=//p')
    [ "$binary_team" = "$team_identifier" ] ||
        fail "$binary_label TeamIdentifier does not match the app"
    printf '%s\n' "$binary_details" | grep '^Timestamp=' >/dev/null ||
        fail "$binary_label signature has no trusted timestamp"
    printf '%s\n' "$binary_details" | grep '^CodeDirectory .*flags=.*runtime' >/dev/null ||
        fail "$binary_label signature does not enable the hardened runtime"
}

verify_developer_id_binary "$app_path/Contents/Resources/bin/codex-cove" \
    "embedded native helper"

remote_arm64_macos="$remote_path/aarch64-apple-darwin/codex-cove"
remote_x86_64_macos="$remote_path/x86_64-apple-darwin/codex-cove"
[ "$(lipo -archs "$remote_arm64_macos")" = arm64 ] ||
    fail "remote Apple Silicon helper must be arm64"
[ "$(lipo -archs "$remote_x86_64_macos")" = x86_64 ] ||
    fail "remote Intel helper must be x86_64"
verify_developer_id_binary "$remote_arm64_macos" "remote Apple Silicon helper"
verify_developer_id_binary "$remote_x86_64_macos" "remote Intel helper"

linux_arm64_details=$(file -b "$remote_path/aarch64-unknown-linux-musl/codex-cove") ||
    fail "could not inspect the remote Linux arm64 helper"
case "$linux_arm64_details" in
    *'ELF 64-bit'*'ARM aarch64'*'statically linked'*) ;;
    *) fail "remote Linux arm64 helper has the wrong format or architecture" ;;
esac
linux_x86_64_details=$(file -b "$remote_path/x86_64-unknown-linux-musl/codex-cove") ||
    fail "could not inspect the remote Linux x86_64 helper"
case "$linux_x86_64_details" in
    *'ELF 64-bit'*'x86-64'*'statically linked'*) ;;
    *) fail "remote Linux x86_64 helper has the wrong format or architecture" ;;
esac
for remote_helper in "$remote_path"/*/codex-cove; do
    strings "$remote_helper" | grep -F "codex-cove $version" >/dev/null ||
        fail "remote helper version does not match $version"
done
(
    cd "$remote_path"
    shasum -a 256 -c SHA256SUMS
)

if [ -e "$release_parent" ] || [ -L "$release_parent" ]; then
    [ -d "$release_parent" ] && [ ! -L "$release_parent" ] ||
        fail "release output parent must be a real directory"
else
    mkdir "$release_parent"
fi
if [ -e "$release_root" ] || [ -L "$release_root" ]; then
    [ -d "$release_root" ] && [ ! -L "$release_root" ] ||
        fail "release output must be a real directory"
fi
rm -rf -- "$release_root"
mkdir "$release_root"

app_archive="$release_root/Codex-Cove-$version-macos-arm64.zip"
extension_archive="$release_root/Codex-Cove-$version.vsix"
remote_archive="$release_root/Codex-Cove-$version-remote-helpers.tar.gz"

ditto -c -k --sequesterRsrc --keepParent "$app_path" "$app_archive"
cp -f "$extension_path" "$extension_archive"
tar -C "$app_path/Contents/Resources" -czf "$remote_archive" remote
cp -f "$repository_root/SOURCE_CANDIDATE.manifest" \
    "$release_root/Codex-Cove-$version-source-candidate.manifest"
cp -f "$repository_root/SOURCE_CANDIDATE.sha256" \
    "$release_root/Codex-Cove-$version-source-candidate.sha256"
cp -f "$repository_root/SOURCE_CANDIDATE.receipt" \
    "$release_root/Codex-Cove-$version-release.receipt"

"$repository_root/scripts/render-homebrew-cask.sh" \
    "$version" \
    "$app_archive" \
    "$release_root/codex-cove.rb" >/dev/null

(
    cd "$release_root"
    find . -type f ! -name SHA256SUMS -print | LC_ALL=C sort | while IFS= read -r artifact; do
        shasum -a 256 "$artifact"
    done
) >"$release_root/SHA256SUMS"

printf '%s\n' "$release_root"
