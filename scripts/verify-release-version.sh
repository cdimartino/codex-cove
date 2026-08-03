#!/bin/sh
set -eu

fail() {
    printf 'release-version: %s\n' "$1" >&2
    exit 1
}

[ "$#" -eq 1 ] || fail "usage: scripts/verify-release-version.sh <version-or-v-tag>"

repository_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd -P)
requested=$1
version=${requested#v}
[ "$requested" = "$version" ] || [ "$requested" = "v$version" ] ||
    fail "tag must contain one leading v"

old_ifs=$IFS
IFS=.
set -- $version
IFS=$old_ifs
[ "$#" -eq 3 ] || fail "version must be numeric major.minor.patch"
for component in "$@"; do
    case "$component" in
        '' | *[!0-9]*) fail "version must be numeric major.minor.patch" ;;
    esac
done

plist_version=$(
    /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
        "$repository_root/Packaging/Info.plist"
) || fail "could not read the app version"

extension_version=$(
    node -e 'const p=require(process.argv[1]); process.stdout.write(String(p.version || ""));' \
        "$repository_root/extension/package.json"
) || fail "could not read the extension version"

extension_lock_versions=$(
    node -e '
        const p = require(process.argv[1]);
        process.stdout.write(`${p.version || ""}\n${p.packages?.[""]?.version || ""}`);
    ' "$repository_root/extension/package-lock.json"
) || fail "could not read the extension lock versions"

helper_version=$(
    awk '
        /^\[package\]$/ { in_package = 1; next }
        in_package && /^\[/ { exit }
        in_package && /^version = "[^"]+"$/ {
            value = $0
            sub(/^version = "/, "", value)
            sub(/"$/, "", value)
            print value
            exit
        }
    ' "$repository_root/helper/Cargo.toml"
) || fail "could not read the helper version"

helper_lock_version=$(
    awk '
        previous == "name = \"codex-cove\"" && /^version = "[^"]+"$/ {
            value = $0
            sub(/^version = "/, "", value)
            sub(/"$/, "", value)
            print value
            exit
        }
        { previous = $0 }
    ' "$repository_root/helper/Cargo.lock"
) || fail "could not read the helper lock version"

xcodegen_version=$(
    awk '$1 == "MARKETING_VERSION:" { print $2 }' "$repository_root/XcodeProject.yml"
) || fail "could not read the XcodeGen marketing version"

xcodegen_build=$(
    awk '$1 == "CURRENT_PROJECT_VERSION:" { print $2 }' "$repository_root/XcodeProject.yml"
) || fail "could not read the XcodeGen build number"

project_versions=$(
    sed -n 's/.*MARKETING_VERSION = \([^;]*\);.*/\1/p' \
        "$repository_root/CodexCoveUITests.xcodeproj/project.pbxproj" | LC_ALL=C sort -u
) || fail "could not read the generated project marketing version"
project_version_count=$(
    sed -n 's/.*MARKETING_VERSION = \([^;]*\);.*/\1/p' \
        "$repository_root/CodexCoveUITests.xcodeproj/project.pbxproj" |
        awk 'END { print NR }'
) || fail "could not count generated project marketing versions"

plist_build=$(
    /usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \
        "$repository_root/Packaging/Info.plist"
) || fail "could not read the app build number"

xcode_build_numbers=$(
    sed -n 's/.*CURRENT_PROJECT_VERSION = \([^;]*\);.*/\1/p' \
        "$repository_root/CodexCoveUITests.xcodeproj/project.pbxproj" | LC_ALL=C sort -u
) || fail "could not read the generated project build number"
xcode_build_number_count=$(
    sed -n 's/.*CURRENT_PROJECT_VERSION = \([^;]*\);.*/\1/p' \
        "$repository_root/CodexCoveUITests.xcodeproj/project.pbxproj" |
        awk 'END { print NR }'
) || fail "could not count generated project build numbers"

[ -n "$helper_version" ] || fail "helper package version is missing"
[ "$plist_version" = "$version" ] ||
    fail "app version $plist_version does not match $version"
[ "$extension_version" = "$version" ] ||
    fail "extension version $extension_version does not match $version"
[ "$helper_version" = "$version" ] ||
    fail "helper version $helper_version does not match $version"
[ "$helper_lock_version" = "$version" ] ||
    fail "helper lock version $helper_lock_version does not match $version"
[ "$extension_lock_versions" = "$version
$version" ] || fail "extension lock versions do not both match $version"
[ "$xcodegen_version" = "$version" ] ||
    fail "XcodeGen marketing version $xcodegen_version does not match $version"
[ "$project_versions" = "$version" ] ||
    fail "generated project marketing versions do not all match $version"
[ "$project_version_count" -eq 2 ] ||
    fail "generated project must contain exactly two marketing version assignments"

case "$plist_build" in
    '' | 0 | *[!0-9]*) fail "CFBundleVersion must be a positive integer" ;;
esac
case "$xcode_build_numbers" in
    '' | 0 | *[!0-9]*) fail "CURRENT_PROJECT_VERSION must be a positive integer" ;;
esac
[ "$xcodegen_build" = "$plist_build" ] ||
    fail "XcodeGen build number $xcodegen_build does not match CFBundleVersion $plist_build"
[ "$xcode_build_numbers" = "$plist_build" ] ||
    fail "generated project build number $xcode_build_numbers does not match CFBundleVersion $plist_build"
[ "$xcode_build_number_count" -eq 2 ] ||
    fail "generated project must contain exactly two build number assignments"

app_swift_versions=$(
    sed -n 's/.*as? String ?? "\([0-9][0-9.]*\)".*/\1/p' \
        "$repository_root/Sources/CodexCoveApp/AppDelegate.swift"
) || fail "could not read app fallback versions"
account_swift_versions=$(
    sed -n 's/.*clientVersion: String = "\([0-9][0-9.]*\)".*/\1/p' \
        "$repository_root/Sources/CoveCore/CoveAccountUsageHydration.swift"
) || fail "could not read account client versions"
desktop_swift_versions=$(
    sed -n 's/.*clientVersion: String = "\([0-9][0-9.]*\)".*/\1/p' \
        "$repository_root/Sources/CoveCore/CoveDesktopThreadHydration.swift"
) || fail "could not read Desktop client versions"

verify_swift_versions() {
    swift_label=$1
    expected_count=$2
    swift_values=$3
    actual_count=$(printf '%s\n' "$swift_values" | awk 'NF { count++ } END { print count + 0 }')
    [ "$actual_count" -eq "$expected_count" ] ||
        fail "$swift_label version occurrences are missing or duplicated"
    while IFS= read -r swift_value; do
        [ "$swift_value" = "$version" ] ||
            fail "$swift_label version $swift_value does not match $version"
    done <<EOF
$swift_values
EOF
}

verify_swift_versions "app fallback" 2 "$app_swift_versions"
verify_swift_versions "account client" 3 "$account_swift_versions"
verify_swift_versions "Desktop client" 2 "$desktop_swift_versions"

receipt_path="$repository_root/SOURCE_CANDIDATE.receipt"
if [ -f "$receipt_path" ]; then
    receipt_version=$(sed -n 's/^release_version=//p' "$receipt_path")
    [ "$receipt_version" = "$version" ] ||
        fail "candidate receipt version does not match $version"
fi

printf '%s\n' "$version"
