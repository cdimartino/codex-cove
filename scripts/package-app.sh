#!/bin/sh
set -eu

fail() {
    printf 'package-app: %s\n' "$1" >&2
    exit 1
}

repository_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd -P)
build_root="$repository_root/build"
app_path="$build_root/Codex Cove.app"
contents_path="$app_path/Contents"
macos_path="$contents_path/MacOS"
resources_path="$contents_path/Resources"
identity_name=${CODEX_COVE_SIGNING_IDENTITY:-"Codex Cove Local Code Signing"}
signing_identity=$identity_name
signing_timestamp=--timestamp=none

if [ -e "$build_root" ] || [ -L "$build_root" ]; then
    [ -d "$build_root" ] && [ ! -L "$build_root" ] ||
        fail "build must be a real directory inside the repository"
fi

if ! security find-identity -v -p codesigning | grep -F "\"$identity_name\"" >/dev/null; then
    if [ "${CODEX_COVE_DISTRIBUTION_BUILD:-0}" = "1" ]; then
        printf 'Distribution build requires the configured Developer ID Application identity.\n' >&2
        exit 1
    fi
    signing_identity=-
    printf 'Named signing identity unavailable; using safe ad-hoc signing for this local build.\n' >&2
elif [ "${CODEX_COVE_DISTRIBUTION_BUILD:-0}" = "1" ]; then
    case "$identity_name" in
        'Developer ID Application: '*) ;;
        *)
            printf 'Distribution build requires a Developer ID Application identity.\n' >&2
            exit 1
            ;;
    esac
    signing_timestamp=--timestamp
fi

cd "$repository_root"

swift build -c release --product CodexCove
cargo build --locked --release --manifest-path helper/Cargo.toml

if [ -f extension/package.json ]; then
    npm --prefix extension run build
    npm --prefix extension run package
fi

if [ -e "$app_path" ] || [ -L "$app_path" ]; then
    [ -d "$app_path" ] && [ ! -L "$app_path" ] ||
        fail "existing app package must be a real directory"
fi
rm -rf "$app_path"
mkdir -p \
    "$macos_path" \
    "$resources_path/bin" \
    "$resources_path/schemas" \
    "$resources_path/extension" \
    "$resources_path/remote"

cp -f Packaging/Info.plist "$contents_path/Info.plist"
cp -f ".build/release/CodexCove" "$macos_path/CodexCove"
cp -f "helper/target/release/codex-cove" "$resources_path/bin/codex-cove"
cp -rf schemas/. "$resources_path/schemas/"
cp -f LICENSE README.md "$resources_path/"

if [ -d Resources/Sounds ]; then
    cp -rf Resources/Sounds "$resources_path/Sounds"
fi

if [ -d Resources/Themes ]; then
    cp -rf Resources/Themes "$resources_path/Themes"
fi

icon_resource=Resources/AppIcon.icns
[ -f "$icon_resource" ] && [ ! -L "$icon_resource" ] ||
    fail "expected committed app icon is missing or unsafe"
cp -f "$icon_resource" "$resources_path/AppIcon.icns"
/usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$contents_path/Info.plist" 2>/dev/null ||
    /usr/libexec/PlistBuddy -c "Set :CFBundleIconFile AppIcon" "$contents_path/Info.plist"

extension_package=extension/dist/cove-extension.vsix
[ -f "$extension_package" ] && [ ! -L "$extension_package" ] ||
    fail "expected packaged editor extension is missing or unsafe"
cp -f "$extension_package" "$resources_path/extension/codex-cove.vsix"

if [ "${CODEX_COVE_INCLUDE_REMOTE:-0}" = "1" ]; then
    remote_source=build/remote
    if [ ! -f "$remote_source/SHA256SUMS" ] || [ -L "$remote_source/SHA256SUMS" ]; then
        printf 'Remote artifacts requested, but build/remote/SHA256SUMS is missing.\n' >&2
        exit 1
    fi

    expected_remote_files='./SHA256SUMS
./aarch64-apple-darwin/codex-cove
./aarch64-unknown-linux-musl/codex-cove
./x86_64-apple-darwin/codex-cove
./x86_64-unknown-linux-musl/codex-cove'
    actual_remote_files=$(
        cd "$remote_source"
        find -P . -type f -print | LC_ALL=C sort
    )
    if [ "$actual_remote_files" != "$expected_remote_files" ]; then
        printf 'Remote artifact layout does not contain exactly the four supported helpers.\n' >&2
        exit 1
    fi
    if [ -n "$(find -P "$remote_source" ! -type d ! -type f -print -quit)" ]; then
        printf 'Remote artifact layout contains a symbolic link or special entry.\n' >&2
        exit 1
    fi

    expected_remote_manifest_paths='./aarch64-apple-darwin/codex-cove
./aarch64-unknown-linux-musl/codex-cove
./x86_64-apple-darwin/codex-cove
./x86_64-unknown-linux-musl/codex-cove'
    actual_remote_manifest_paths=$(
        awk 'NF == 2 { print $2 }' "$remote_source/SHA256SUMS" | LC_ALL=C sort
    )
    if [ "$actual_remote_manifest_paths" != "$expected_remote_manifest_paths" ]; then
        printf 'Remote checksum manifest does not name exactly the four supported helpers.\n' >&2
        exit 1
    fi
    (
        cd "$remote_source"
        shasum -a 256 -c SHA256SUMS
    ) || {
        printf 'Remote artifact checksum verification failed before packaging.\n' >&2
        exit 1
    }

    cp -rf "$remote_source"/. "$resources_path/remote/"
fi

plutil -lint "$contents_path/Info.plist" >/dev/null
plutil -lint Packaging/CodexCove.entitlements >/dev/null

codesign --force --options runtime "$signing_timestamp" --sign "$signing_identity" "$resources_path/bin/codex-cove"
for target in aarch64-apple-darwin x86_64-apple-darwin; do
    remote_helper="$resources_path/remote/$target/codex-cove"
    if [ -f "$remote_helper" ]; then
        codesign --force --options runtime "$signing_timestamp" --sign "$signing_identity" "$remote_helper"
    fi
done
if [ -f "$resources_path/remote/SHA256SUMS" ]; then
    (
        cd "$resources_path/remote"
        find . -type f -name codex-cove -print | LC_ALL=C sort | while IFS= read -r artifact; do
            shasum -a 256 "$artifact"
        done
    ) >"$resources_path/remote/SHA256SUMS.installing"
    mv "$resources_path/remote/SHA256SUMS.installing" "$resources_path/remote/SHA256SUMS"
    (
        cd "$resources_path/remote"
        shasum -a 256 -c SHA256SUMS
    )
fi
codesign --force --options runtime "$signing_timestamp" \
    --entitlements Packaging/CodexCove.entitlements \
    --sign "$signing_identity" "$app_path"

codesign --verify --deep --strict --verbose=2 "$app_path"
printf '%s\n' "$app_path"
