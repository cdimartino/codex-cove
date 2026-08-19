#!/bin/sh
set -eu

developer_dir=${XCODE_DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
products=DerivedData/Build/Products
source_run=
expected_xcode_version='Xcode 26.6
Build version 17F113'

xcode_version=$("$developer_dir/usr/bin/xcodebuild" -version 2>/dev/null) || {
    echo "Unable to verify the Xcode version; legacy Accessibility UI tests were not started." >&2
    exit 2
}
if [ "$xcode_version" != "$expected_xcode_version" ]; then
    echo "The private legacy Accessibility fallback is validated only on Xcode 26.6 build 17F113; UI tests were not started." >&2
    exit 2
fi

for candidate in "$products"/CodexCoveUITests_*.xctestrun; do
    case "$candidate" in
        *legacy-ax*) continue ;;
    esac
    if [ -f "$candidate" ]; then
        source_run=$candidate
        break
    fi
done

if [ -z "$source_run" ]; then
    echo "No built CodexCoveUITests .xctestrun was found; run make ui-test-build first." >&2
    exit 2
fi

locked=$(/usr/sbin/ioreg -n Root -d1 -a 2>/dev/null \
    | /usr/bin/plutil -extract IOConsoleLocked raw -o - - 2>/dev/null) || {
    echo "Unable to verify that the macOS console is unlocked; UI tests were not started." >&2
    exit 2
}
if [ "$locked" = "true" ]; then
    echo "UI tests require an unlocked macOS console; unlock the Mac and retry." >&2
    exit 2
fi

temporary_run="$products/CodexCoveUITests_legacy-ax-$$.xctestrun"
if [ -e "$temporary_run" ]; then
    echo "Refusing to replace existing temporary test configuration: $temporary_run" >&2
    exit 2
fi
trap 'rm -f "$temporary_run"' EXIT HUP INT TERM

/bin/cp "$source_run" "$temporary_run"
/usr/bin/plutil -replace CodexCoveUITests.CommandLineArguments \
    -json '["-XCTDisableAutomationSession","YES"]' "$temporary_run"

echo "Using Xcode's private runner-wide legacy Accessibility fallback; this is not a per-app exclusion."
DEVELOPER_DIR="$developer_dir" /usr/bin/caffeinate -dimsu \
    "$developer_dir/usr/bin/xcodebuild" \
    -xctestrun "$temporary_run" \
    -destination 'platform=macOS' \
    test-without-building "$@"
