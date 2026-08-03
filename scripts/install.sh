#!/bin/sh
set -eu

repository_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
source_app="$repository_root/build/Codex Cove.app"
destination_root="$HOME/Applications"
destination_app="$destination_root/Codex Cove.app"
expected_bundle_identifier="local.chris.codexcove"
expected_executable_name="CodexCove"

bundle_identifier_at_path() {
    bundle_path=$1
    /usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" \
        "$bundle_path/Contents/Info.plist" 2>/dev/null
}

validate_existing_destination() {
    if [ ! -e "$destination_app" ]; then
        return 0
    fi

    destination_bundle_identifier=$(bundle_identifier_at_path "$destination_app" || true)
    if [ "$destination_bundle_identifier" != "$expected_bundle_identifier" ]; then
        printf 'Refusing to replace app with unexpected bundle identifier at %s: %s\n' \
            "$destination_app" "${destination_bundle_identifier:-unreadable}" >&2
        return 1
    fi
}

running_cove_applications() {
    /usr/bin/lsappinfo find bundleID="$expected_bundle_identifier"
}

application_info_value() {
    information=$1
    key=$2
    if [ "$key" = "pid" ]; then
        # macOS 26 emits the PID as an unquoted integer while path and bundle
        # values remain quoted. Keep the numeric grammar strict before the
        # existing ownership/path validation consumes it.
        printf '%s\n' "$information" | /usr/bin/sed -n \
            's/^"pid"=\([0-9][0-9]*\)$/\1/p'
    else
        printf '%s\n' "$information" | /usr/bin/sed -n \
            "s/^\"$key\"=\"\(.*\)\"$/\1/p"
    fi
}

validate_running_cove_application() {
    application_specifier=$1
    application_information=$(
        /usr/bin/lsappinfo info \
            -only pid \
            -only bundleID \
            -only bundlepath \
            -only executablepath \
            "$application_specifier"
    )
    application_pid=$(application_info_value "$application_information" pid)
    application_bundle_identifier=$(application_info_value "$application_information" CFBundleIdentifier)
    application_bundle_path=$(application_info_value "$application_information" LSBundlePath)
    application_executable_path=$(application_info_value "$application_information" CFBundleExecutablePath)

    case "$application_pid" in
        ''|*[!0-9]*)
            printf 'Refusing to stop Cove application with unreadable pid: %s\n' \
                "$application_specifier" >&2
            return 1
            ;;
    esac

    application_user_id=$(
        /bin/ps -p "$application_pid" -o uid= 2>/dev/null |
            /usr/bin/tr -d '[:space:]'
    )
    current_user_id=$(/usr/bin/id -u)
    if [ "$application_user_id" != "$current_user_id" ]; then
        printf 'Refusing to stop Cove application not owned by the current user (pid %s).\n' \
            "$application_pid" >&2
        return 1
    fi

    if [ "$application_bundle_identifier" != "$expected_bundle_identifier" ]; then
        printf 'Refusing to stop application with unexpected bundle identifier: %s\n' \
            "${application_bundle_identifier:-unreadable}" >&2
        return 1
    fi

    expected_executable_path="$application_bundle_path/Contents/MacOS/$expected_executable_name"
    if [ -z "$application_bundle_path" ] || \
        [ "$application_executable_path" != "$expected_executable_path" ]; then
        printf 'Refusing to stop Cove application with unexpected executable path: %s\n' \
            "${application_executable_path:-unreadable}" >&2
        return 1
    fi

    on_disk_bundle_identifier=$(bundle_identifier_at_path "$application_bundle_path" || true)
    if [ "$on_disk_bundle_identifier" != "$expected_bundle_identifier" ]; then
        printf 'Refusing to stop Cove application whose bundle identity cannot be verified: %s\n' \
            "$application_bundle_path" >&2
        return 1
    fi
}

stop_running_cove_applications() {
    stop_timeout_seconds=${CODEX_COVE_INSTALL_STOP_TIMEOUT_SECONDS:-10}
    case "$stop_timeout_seconds" in
        ''|*[!0-9]*)
            printf 'Invalid CODEX_COVE_INSTALL_STOP_TIMEOUT_SECONDS: %s\n' \
                "$stop_timeout_seconds" >&2
            return 1
            ;;
    esac

    application_specifiers=$(running_cove_applications)
    if [ -z "$application_specifiers" ]; then
        return 0
    fi

    # Validate every target before terminating any process. This prevents a
    # partial shutdown if LaunchServices returns an unexpected registration.
    for application_specifier in $application_specifiers; do
        validate_running_cove_application "$application_specifier"
    done

    printf 'Stopping running Codex Cove application before install...\n'
    for application_specifier in $application_specifiers; do
        # `lsappinfo kill` sends SIGTERM to this exact LaunchServices ASN. It
        # avoids PID-reuse races while retaining a graceful, bounded shutdown.
        /usr/bin/lsappinfo kill "$application_specifier" >/dev/null 2>&1 || true
    done

    elapsed_seconds=0
    while [ "$elapsed_seconds" -lt "$stop_timeout_seconds" ]; do
        remaining_application_specifiers=$(running_cove_applications)
        if [ -z "$remaining_application_specifiers" ]; then
            return 0
        fi
        /bin/sleep 1
        elapsed_seconds=$((elapsed_seconds + 1))
    done

    remaining_application_specifiers=$(running_cove_applications)
    if [ -n "$remaining_application_specifiers" ]; then
        printf 'Codex Cove did not stop within %s seconds; installation aborted without replacing the app.\n' \
            "$stop_timeout_seconds" >&2
        return 1
    fi
}

validate_existing_destination
# Packaging replaces the repository build bundle, which may itself be the
# running Cove instance during development.
stop_running_cove_applications

"$repository_root/scripts/package-app.sh"
mkdir -p "$destination_root"

staging_app="$destination_root/.Codex Cove.app.installing"
rm -rf "$staging_app"
cp -R "$source_app" "$staging_app"
codesign --verify --deep --strict "$staging_app"
bundle_identifier=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$staging_app/Contents/Info.plist")
if [ "$bundle_identifier" != "$expected_bundle_identifier" ]; then
    printf 'Refusing to install unexpected bundle identifier: %s\n' "$bundle_identifier" >&2
    exit 1
fi

# Close the small race where Cove could be relaunched while the package was
# being built. Never move the installed bundle while an old binary is alive.
stop_running_cove_applications

if [ -e "$destination_app" ]; then
    backup_suffix=$(date -u '+%Y%m%dT%H%M%SZ')
    backup_app="$destination_root/Codex Cove.app.backup.$backup_suffix"
    mv "$destination_app" "$backup_app"
fi

mv "$staging_app" "$destination_app"
if ! "$destination_app/Contents/Resources/bin/codex-cove" install --app-path "$destination_app"; then
    failed_app="$destination_root/Codex Cove.app.failed.$(date -u '+%Y%m%dT%H%M%SZ')"
    mv "$destination_app" "$failed_app"
    if [ -n "${backup_app:-}" ] && [ -e "$backup_app" ]; then
        mv "$backup_app" "$destination_app"
    fi
    printf 'Integration install failed; app rollback completed.\n' >&2
    printf 'Failed package retained at %s\n' "$failed_app" >&2
    exit 1
fi

printf 'Installed %s\n' "$destination_app"
printf 'Run %s\n' "$HOME/bin/codex-cove doctor"
