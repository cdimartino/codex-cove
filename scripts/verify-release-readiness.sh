#!/bin/sh
set -eu

fail() {
    printf 'release-readiness: %s\n' "$1" >&2
    exit 1
}

[ "$#" -eq 1 ] || fail "usage: scripts/verify-release-readiness.sh <version-or-v-tag>"

repository_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd -P)
receipt_path="$repository_root/SOURCE_CANDIDATE.receipt"
digest_path="$repository_root/SOURCE_CANDIDATE.sha256"
manifest_path="$repository_root/SOURCE_CANDIDATE.manifest"
schema_keys_path="$repository_root/schemas/release-receipt-v1.keys"

[ -f "$receipt_path" ] || fail "SOURCE_CANDIDATE.receipt is missing"
[ ! -L "$receipt_path" ] || fail "SOURCE_CANDIDATE.receipt must not be a symbolic link"
[ -f "$schema_keys_path" ] && [ ! -L "$schema_keys_path" ] ||
    fail "release receipt key schema is missing or unsafe"

"$repository_root/scripts/verify-release-version.sh" "$1" >/dev/null
"$repository_root/scripts/source-candidate.sh" verify >/dev/null

awk '
    NR == 1 { next }
    $0 !~ /^[A-Za-z0-9_]+=/ { exit 2 }
    {
        key = $0
        sub(/=.*/, "", key)
        if (++seen[key] != 1) { exit 3 }
    }
' "$receipt_path" || fail "candidate receipt contains a malformed or duplicate key"

awk '
    /^[A-Za-z0-9_]+$/ {
        if (++seen[$0] != 1) { exit 2 }
        next
    }
    { exit 3 }
' "$schema_keys_path" || fail "release receipt key schema is malformed"

awk '
    FNR == NR { allowed[$0] = 1; next }
    FNR == 1 { next }
    {
        key = $0
        sub(/=.*/, "", key)
        if (!allowed[key]) { exit 2 }

        value = $0
        sub(/^[^=]*=/, "", value)
        if (length(value) == 0 || length(value) > 160) { exit 3 }
        if (value ~ /[[:space:][:cntrl:]\\\/@]/ ||
            value ~ /[^A-Za-z0-9._:+-]/) { exit 4 }

        if (length(value) == 36 &&
            substr(value, 9, 1) == "-" &&
            substr(value, 14, 1) == "-" &&
            substr(value, 19, 1) == "-" &&
            substr(value, 24, 1) == "-") { exit 5 }

        if (length(value) == 64 && value !~ /[^0-9a-f]/ &&
            key !~ /(_digest|_sha256)$/ && key != "source_candidate_digest") {
            exit 6
        }
    }
' "$schema_keys_path" "$receipt_path" ||
    fail "candidate receipt violates the privacy-safe key/value schema"

receipt_value() {
    receipt_key=$1
    awk -v wanted="$receipt_key" '
        index($0, wanted "=") == 1 {
            sub(/^[^=]*=/, "")
            print
            exit
        }
    ' "$receipt_path"
}

require_value() {
    required_key=$1
    required_value=$2
    actual_value=$(receipt_value "$required_key")
    [ "$actual_value" = "$required_value" ] ||
        fail "$required_key must be $required_value"
}

require_recorded() {
    recorded_key=$1
    recorded_value=$(receipt_value "$recorded_key")
    [ -n "$recorded_value" ] && [ "$recorded_value" != not-run ] ||
        fail "$recorded_key must contain current-candidate evidence"
}

require_positive_integer() {
    integer_key=$1
    integer_value=$(receipt_value "$integer_key")
    case "$integer_value" in
        '' | 0 | *[!0-9]*) fail "$integer_key must be a positive integer" ;;
    esac
}

require_nonnegative_integer() {
    integer_key=$1
    integer_value=$(receipt_value "$integer_key")
    case "$integer_value" in
        '' | *[!0-9]*) fail "$integer_key must be a nonnegative integer" ;;
    esac
}

require_decimal_below() {
    decimal_key=$1
    decimal_limit=$2
    decimal_value=$(receipt_value "$decimal_key")
    printf '%s\n' "$decimal_value" |
        grep -E '^[0-9]+([.][0-9]+)?$' >/dev/null ||
        fail "$decimal_key must be a nonnegative decimal"
    awk -v value="$decimal_value" -v limit="$decimal_limit" \
        'BEGIN { exit !(value >= 0 && value < limit) }' ||
        fail "$decimal_key must be below $decimal_limit seconds"
}

require_local_timestamp() {
    timestamp_key=$1
    timestamp_value=$(receipt_value "$timestamp_key")
    printf '%s\n' "$timestamp_value" |
        grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}([+-][0-9]{4}|[+-][0-9]{2}:[0-9]{2})$' >/dev/null ||
        fail "$timestamp_key must be a local ISO-8601 timestamp"
}

candidate_digest=$(sed -n '1p' "$digest_path")
case "$candidate_digest" in
    '' | *[!0-9a-f]*) fail "candidate digest is invalid" ;;
esac
[ "${#candidate_digest}" -eq 64 ] || fail "candidate digest is invalid"

require_value source_candidate_digest "$candidate_digest"
require_value receipt_schema codex-cove-release-evidence-v1
require_value source_candidate_manifest SOURCE_CANDIDATE.manifest
require_value source_candidate_digest_verified yes
require_value source_manifest_header codex-cove-source-candidate-v2
require_value source_manifest_sha256 "$candidate_digest"
require_value receipt_manifest_membership excluded
require_value receipt_privacy_schema pass

manifest_entry_count=$(awk 'END { print NR - 1 }' "$manifest_path") ||
    fail "could not count source-candidate manifest entries"
require_value source_manifest_entry_count "$manifest_entry_count"
digest_file_output=$(shasum -a 256 <"$digest_path") ||
    fail "could not hash the source-candidate digest file"
digest_file_sha256=${digest_file_output%% *}
require_value source_digest_file_sha256 "$digest_file_sha256"

for digest_key in \
    candidate_verify_before_digest \
    candidate_verify_after_dependencies_digest \
    candidate_verify_after_bootstrap_digest \
    candidate_verify_after_build_digest \
    candidate_verify_after_components_digest \
    candidate_verify_after_ui_digest \
    candidate_verify_after_install_digest \
    candidate_verify_after_runtime_digest \
    candidate_verify_after_local_prompt_batch_digest \
    candidate_verify_final_digest
do
    require_value "$digest_key" "$candidate_digest"
done

for pass_key in \
    candidate_verify_before \
    candidate_verify_after_dependencies \
    candidate_verify_after_bootstrap \
    candidate_verify_after_build \
    candidate_verify_after_components \
    candidate_verify_after_ui \
    candidate_verify_after_install \
    candidate_verify_after_runtime \
    candidate_verify_after_local_prompt_batch \
    candidate_verify_final \
    receipt_binding_verify \
    dependency_gate \
    bootstrap_gate \
    component_gate \
    product_build_gate \
    shell_syntax_gate \
    rust_format_gate \
    rust_native_clippy_warnings_denied \
    linux_musl_aarch64_all_targets \
    linux_musl_x86_64_all_targets \
    ui_test_bundle_compile \
    ui_gate \
    package_gate \
    install_gate \
    editor_extension_gate \
    remote_artifact_gate \
    runtime_process_socket_gate \
    app_server_smoke \
    desktop_app_server_smoke \
    authorization_L_A_placement_result \
    owner_scripted_pass \
    single_question \
    multi_question \
    allow_once \
    allow_for_task \
    failure_retry \
    failure_open_control \
    settings_controls \
    production_settings_persistence \
    audible_sound \
    interactive_shim \
    terminal_app_exact_origin \
    vscode_terminal_exact_origin \
    vscode_two_window_focus \
    vscode_sequential_same_terminal \
    vscode_persisted_state_privacy \
    cursor_terminal_exact_origin \
    cursor_two_window_focus \
    cursor_sequential_same_terminal \
    cursor_persisted_state_privacy \
    two_task_acceptance \
    two_task_distinct_attribution \
    two_task_native_fallback \
    desktop_interactive \
    desktop_native_fallback \
    scroll_mouse_wheel \
    scroll_trackpad \
    scroll_keyboard \
    scroll_voiceover \
    reduce_motion \
    reduce_transparency \
    increased_contrast \
    voiceover \
    full_keyboard_access \
    switch_control \
    system_larger_text \
    light_appearance \
    dark_appearance \
    built_in_notch \
    external_display \
    no_notch \
    spaces \
    fullscreen \
    stage_manager \
    sleep_wake \
    remote_alias \
    remote_version_checksum \
    remote_decision_route \
    remote_disconnect_reconnect \
    rollback_uninstall_reinstall \
    rollback_owned_artifacts_removed \
    rollback_settings_retained \
    rollback_session_metadata_retained \
    rollback_unrelated_hooks_preserved \
    rollback_codex_threads_untouched \
    rollback_ssh_state_unchanged \
    rollback_reinstall_bundle_match \
    rollback_reinstall_signature \
    rollback_editor_targets_restored \
    rollback_remote_checksums \
    rollback_socket_private \
    rollback_nonprompting_smokes \
    rollback_full_verification \
    final_socket_private \
    p0_p1_signoff
do
    require_value "$pass_key" pass
done

for yes_key in \
    installed_signature_valid \
    doctor_healthy \
    hook_trusted \
    representative_background_restored \
    rollback_doctor_healthy \
    system_baseline_restored \
    cove_settings_baseline_restored \
    remote_baseline_restored \
    final_doctor_healthy \
    p0_p1_retest_receipts_complete
do
    require_value "$yes_key" yes
done

require_value iterm2_appearance_seconds not-required
require_value iterm2_exact_origin not-required
require_value candidate_verify_after_build_blocker none
require_value ui_blocker none
require_value two_task_duplicate_count 0
require_value desktop_duplicate_count 0
require_value remote_duplicate_count 0
require_value wrong_scope_send_count 0
require_value dependency_npm_vulnerability_count 0
require_value ui_started yes
require_value ui_pass_count 23
require_value ui_fail_count 0
require_value ui_skip_count 0
require_value p0_open_count 0
require_value p1_open_count 0
require_value rollback_process_count 1
require_value final_process_count 1
require_value hook_group_count 11
require_value terminal_adapters 4
require_value owner_candidate_attempt 1
require_value desktop_task_count 1
require_value remote_task_count 2

permission_authorization=$(receipt_value authorization_P_A)
case "$permission_authorization" in
    not-requested)
        require_value authorization_P_A_approved_tasks 0
        require_value authorization_P_A_launched_tasks 0
        permission_task_count=0
        ;;
    approved)
        require_value authorization_P_A_approved_tasks 1
        require_value authorization_P_A_launched_tasks 1
        permission_task_count=1
        ;;
    *) fail "authorization_P_A must be not-requested or approved for a completed release" ;;
esac

require_value authorization_L_A approved
require_value authorization_L_A_approved_tasks 7
require_value authorization_L_A_launched_tasks 7
require_value authorization_L_A_terminal_app_launch_count 1
require_value authorization_L_A_iterm2_launch_count 0
require_value authorization_L_A_vscode_terminal_launch_count 3
require_value authorization_L_A_cursor_terminal_launch_count 3
require_value authorization_L_A_routed_completed_tasks 7
require_value authorization_L_A_failed_startup_tasks 0
require_value authorization_L_A_exact_reply_count 7

for authorization_prefix in L_B D_B R_A R_B; do
    require_value "authorization_$authorization_prefix" approved
    require_value "authorization_${authorization_prefix}_approved_tasks" 1
    require_value "authorization_${authorization_prefix}_launched_tasks" 1
done

expected_prompted_task_count=$((11 + permission_task_count))
require_value prompted_task_count "$expected_prompted_task_count"

for count_key in \
    ssh_connection_count \
    manual_settings_mutation_count \
    trust_approval_count \
    uninstall_action_count \
    rollback_action_count
do
    require_nonnegative_integer "$count_key"
done
require_positive_integer ssh_connection_count
require_positive_integer uninstall_action_count
require_positive_integer rollback_action_count

require_decimal_below waiting_task_seconds 5
require_decimal_below terminal_app_appearance_seconds 2
require_decimal_below vscode_terminal_appearance_seconds 2
require_decimal_below cursor_terminal_appearance_seconds 2
require_decimal_below exact_origin_seconds 8
require_decimal_below desktop_exact_open_seconds 8

remote_platform=$(receipt_value remote_platform)
case "$remote_platform" in
    aarch64-apple-darwin | x86_64-apple-darwin | \
        aarch64-unknown-linux-musl | x86_64-unknown-linux-musl) ;;
    *) fail "remote_platform must be one supported target category" ;;
esac

require_value defect_register_schema privacy_safe_v1
require_value defect_register_entry_count 2
require_value supersedes_source_candidate_digest 00bfe5bbc2d54e1e8ad02cbd1b9748ec3d6e43da0272ceb79490a4e9626a8010
require_value superseded_candidate_receipt_sha256 904990f7849f04cc382c619e379934e626bf886d09fb678a1a61470ccc555de0
require_value superseded_candidate_failure_row_count 2
require_value superseded_candidate_owner_attempt not-run
require_value superseded_candidate_owner_scripted_pass not-run
require_value defect_001_ref P1-001
require_value defect_001_severity P1
require_value defect_001_release_row vscode_two_window_focus
require_value defect_001_status closed
require_value defect_001_current_candidate_retest_receipt vscode_two_window_focus
require_value defect_001_symptom_category exact_editor_window_not_activated
require_value defect_002_ref P1-002
require_value defect_002_severity P1
require_value defect_002_release_row cursor_two_window_focus
require_value defect_002_status closed
require_value defect_002_current_candidate_retest_receipt cursor_two_window_focus
require_value defect_002_symptom_category exact_editor_window_not_activated

for timestamp_key in \
    started_at \
    finished_at \
    candidate_verify_before_at \
    dependency_gate_at \
    bootstrap_gate_at \
    product_build_gate_at \
    defect_001_first_observed_at \
    defect_002_first_observed_at \
    defect_register_reviewed_at \
    receipt_binding_verify_at \
    candidate_verify_final_at
do
    require_local_timestamp "$timestamp_key"
done

require_recorded defect_register_reviewed_at
require_value source_change_reason homebrew_release_validation_trust_hardening
require_value notes release_candidate_complete

if [ "${CODEX_COVE_REQUIRE_RECORDED_STRICT_VERIFY:-0}" = "1" ]; then
    require_value receipt_strict_release_verify pass
fi

require_value release_gate pass
require_value receipt_state complete

finished_at=$(receipt_value finished_at)
[ -n "$finished_at" ] && [ "$finished_at" != not-run ] ||
    fail "finished_at must contain the completed release timestamp"

printf '%s\n' "$candidate_digest"
