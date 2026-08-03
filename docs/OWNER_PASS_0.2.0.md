# Codex Cove 0.2.0 owner and manual release pass

Last updated: 2026-08-01, America/New_York.
Repository-state update: 2026-08-03, America/New_York.

Candidate-freeze rule: this runbook and its receipt template are
source-candidate inputs. Once `SOURCE_CANDIDATE.manifest` is written, do not edit
this file to record release results. Write them only to the repository-root
`SOURCE_CANDIDATE.receipt`, the sole release-current evidence record, which is
deliberately excluded from the source manifest.

## Status and purpose

This is the canonical procedure for the 0.2.0 release gates that cannot be
claimed from unit tests or XCUITest alone. It is intentionally not marked as
completed. Run it with the macOS console unlocked and record only observed
results.

Use Sections 2-4 as procedures, not as an early claim of owner success. The
release order is: preflight; complete the accessibility, display, sleep, and
selected-host matrices in Sections 5-7; restore the baseline; then perform the
Section 8 owner script once, first attempt, using the procedures in Sections
2-4. Missing hardware or authorization leaves the corresponding prerequisite
blocked.

The deterministic UI-test host is appropriate for rehearsing Cove-owned
questions, approvals, failure/retry, and Settings controls. It disables real
external jumps, notification delivery, sound playback, persistence, brokers,
relays, and other external effects. Production checks are therefore separate
and mandatory for real `Open in Codex`, audible sound, persistence, terminal
attribution, hook trust, and reconnect behavior.

## Safety and evidence rules

- Obtain explicit user approval before changing any macOS accessibility,
  appearance, display arrangement, Space, fullscreen state, Stage Manager, or
  sleep state. VoiceOver and Switch Control can be disruptive; let the user
  operate or supervise those rows. Restore the prior state after each check.
- Change one system setting at a time through System Settings. Do not use
  unsupported `defaults write` mutations. Restore that setting before moving
  to the next row unless the row explicitly tests a combination.
- Obtain separate explicit authorization before sending any new Codex prompt.
  State the exact prompt, working directory, number of tasks, and exact
  per-application placement distribution first. A placement not named in that
  authorization is not authorized.
- Never crawl SSH configuration or contact a host. A remote pass begins only
  after the user supplies one exact SSH alias and approves that connection.
- Do not save prompts, responses, task/thread identifiers, commands, diffs,
  terminal pane identifiers, SSH aliases, or user preference contents in this
  repository. Record only timestamps, elapsed seconds, counts, booleans,
  adapter/display categories, and pass/fail notes without task content.
- Do not stage, commit, tag, or delete retained app backups as part of this
  pass.
- A row is `Pass` only from direct observation. Use `Fail` for a directly
  observed requirement failure, `Blocked` when a required prerequisite such
  as hardware, authorization, trust, or an uninterrupted environment is
  unavailable, and `Not run` only when the row has not been attempted.
- `Blocked` is never equivalent to `Pass`, never closes a release row, and
  never waives a requirement. It may allow independent rows to proceed, but
  the release stays open until a later directly observed `Pass` replaces it.
- A task launch consumes one task from the exact authorization batch even if
  launch, routing, or the task itself fails. Never retry, replace, or add a
  task under the old count; obtain a new authorization first.

## Pre-freeze host restore baseline

A read-only preflight refresh at `2026-08-01T14:55:55-0400` found the following
starting state. Refresh it again immediately before the first approved system
or application-setting mutation because system state can drift.

| Item | Audited state | Restore target if unchanged at preflight |
|---|---|---|
| Appearance | Aqua/light | Aqua/light |
| Reduce Motion | Off | Off |
| Reduce Transparency | Off | Off |
| Increased Contrast | Off | Off |
| Differentiate Without Color | Off | Off |
| Invert Colors | Off | Off |
| VoiceOver | Off | Off |
| Switch Control | Off | Off |
| Full Keyboard Access | Off | Off |
| System text-size category | `XL` (`UICTContentSizeCategoryXL`; prior inventory was `L`) | `XL` |
| Stage Manager | Off | Off |
| Displays | One main built-in Retina, 1728 x 1117 points, scale 2, 3456 x 2234 backing pixels, 32-point safe top, notch present | Same attachment state |
| Spaces | Persistent inventory suggests two on the built-in display; Mission Control confirmation required | Preserve every user-confirmed Space and the starting active Space |
| Remote Cove hosts | Zero | Zero |
| Persisted terminal adapters | Zero | Do not fabricate records |

At that refresh the user session was on-console and unlocked. Exactly one
installed Cove process owned the current-user mode-0600 event socket, and
Doctor was healthy with fourteen passes plus the four documented warnings.
There was no attached external or no-notch display. The latest recorded system
sleep/wake occurred before the current Cove process started, so it supplies no
recovery evidence. These observations close only the corresponding read-only
preflight checks at that timestamp: they do not pass any alternate-state,
visual/interaction, hardware, or sleep/wake row. The production Cove Settings
snapshot in Preflight step 5 also remains to be observed in the UI before the
scored owner sequence.

## Prompt authorization batches and minimum task count

This table is a counting plan, **not authorization**. Every row needs a new,
explicit user approval that states its exact prompt, working directory, and
new-task count before any task in that row is launched. Approval for one row
does not carry to another row. `Task A` and `Task B` mean the two exact prompts
printed verbatim in Section 3; substitutions require a new documented plan and
new approval.

| Batch | Exact new tasks | Placement and evidence reuse | Minimum count |
|---|---|---|---:|
| `P-A` permission bootstrap, conditional | Task A in Terminal.app | Use only if preflight shows the first real exact-origin jump would trigger an OS permission prompt. Resolve it under user supervision, close the task, and restore the clean baseline. It supplies no scored evidence and cannot be reused by `L-A`. | 1 when needed; otherwise 0 |
| `L-A` local reply | Task A in Terminal.app once; VS Code three times; Cursor three times | Keep the Terminal.app task available as Task A for `L-B`. In each editor, run one task in window 1/terminal 1 and one concurrently in window 2/terminal 2 for two-window focus, then a second sequential task in window 1/terminal 1. Those same tasks close that editor's appearance and exact-origin rows; do not add separate matrix tasks. iTerm2 remains supported but is not a required 0.2.0 placement. | 7 |
| `L-B` local approval | Task B in a new, distinct visible local terminal pane | Pair it with the still-visible Terminal.app Task A for the two-task acceptance. Reuse this same waiting Task B for the Cove-quit/native-fallback observation; do not launch another Task B. If Task A is no longer reusable, a replacement Task A requires its own new authorization and is not included in this count. | 1 |
| `D-B` Desktop approval | Task B in Codex Desktop | Desktop never inherits a CLI authorization. This one task supplies hook/app-server appearance, native permission fallback, and exact Desktop Open evidence. | 1 |
| `R-A` remote reply | Task A on the one user-selected host | Requires the separately approved SSH connection/deployment and an exact user-approved remote working directory. It supplies remote appearance and basic routing only. | 1 |
| `R-B` remote approval | Task B on that same selected host | Separately authorize the approval prompt. Reuse the one waiting request for decision routing and the approved bounded disconnect/reconnect check; do not create a replacement after disconnect without new approval. | 1 |

The clean-start minimum is therefore 11 new tasks when no permission bootstrap
is needed: eight local CLI tasks, one Desktop task, and two remote tasks. If
`P-A` is required, the exact total is 12. Those totals are descriptive only and
grant no permission. A partial batch authorizes only its stated count; any
expired, closed, or unusable task that cannot satisfy its listed reuse makes
the remaining observation `Blocked` or requires a newly approved replacement.

## Result receipt

Use the repository-root `SOURCE_CANDIDATE.receipt` for the release session and
keep it privacy-safe. The matrix
rows may be completed in separately approved segments; the owner fields must
describe one uninterrupted first-attempt owner run.

The complete machine-readable key allowlist is
[`schemas/release-receipt-v1.keys`](../schemas/release-receipt-v1.keys), and
`scripts/verify-release-readiness.sh` is the canonical value and consistency
validator for 0.2.0. The block below documents the operator-facing subset; it
must not be copied as a standalone complete receipt. A rollover starts from the
prior receipt, resets every new-candidate evidence field, adds any newly required
schema keys, and then follows the procedure below. Unknown keys, free-form
values, paths, identifiers, and incomplete automated checkpoints are rejected.

```text
codex-cove-source-candidate-receipt-v1
source_candidate_digest=<exact 64-character lowercase SHA-256>
receipt_schema=codex-cove-release-evidence-v1
release_version=0.2.0
started_at=<local ISO-8601 timestamp>
finished_at=<local ISO-8601 timestamp>
source_candidate_manifest=SOURCE_CANDIDATE.manifest
source_candidate_digest_verified=yes|no|not-run
authorization_P_A=approved|declined|not-requested
authorization_P_A_approved_tasks=<count only>
authorization_P_A_launched_tasks=<count only>
authorization_L_A=approved|declined|not-requested
authorization_L_A_approved_tasks=<count only>
authorization_L_A_launched_tasks=<count only>
authorization_L_A_terminal_app_launch_count=<count only>
authorization_L_A_iterm2_launch_count=<count only>
authorization_L_A_vscode_terminal_launch_count=<count only>
authorization_L_A_cursor_terminal_launch_count=<count only>
authorization_L_A_routed_completed_tasks=<count only>
authorization_L_A_failed_startup_tasks=<count only>
authorization_L_A_exact_reply_count=<count only>
authorization_L_A_placement_result=pass|fail|blocked|not-run
authorization_L_B=approved|declined|not-requested
authorization_L_B_approved_tasks=<count only>
authorization_L_B_launched_tasks=<count only>
authorization_D_B=approved|declined|not-requested
authorization_D_B_approved_tasks=<count only>
authorization_D_B_launched_tasks=<count only>
authorization_R_A=approved|declined|not-requested
authorization_R_A_approved_tasks=<count only>
authorization_R_A_launched_tasks=<count only>
authorization_R_B=approved|declined|not-requested
authorization_R_B_approved_tasks=<count only>
authorization_R_B_launched_tasks=<count only>
installed_signature_valid=yes|no
doctor_healthy=yes|no
owner_candidate_attempt=<positive integer or not-run>
owner_scripted_pass=pass|fail|blocked|not-run
waiting_task_seconds=<number or not-run>
exact_origin_seconds=<number or not-run>
single_question=pass|fail|not-run
multi_question=pass|fail|not-run
allow_once=pass|fail|not-run
allow_for_task=pass|fail|not-run
failure_retry=pass|fail|not-run
failure_open_control=pass|fail|not-run
settings_controls=pass|fail|not-run
production_settings_persistence=pass|fail|not-run
audible_sound=pass|fail|not-run
interactive_shim=pass|fail|not-run
hook_trusted=yes|no|blocked|not-run
hook_group_count=<count only>
terminal_adapters=<count only>
terminal_app_appearance_seconds=<number or not-run>
terminal_app_exact_origin=pass|fail|blocked|not-run
iterm2_appearance_seconds=not-required|<number or not-run>
iterm2_exact_origin=not-required|pass|fail|blocked|not-run
vscode_terminal_appearance_seconds=<number or not-run>
vscode_terminal_exact_origin=pass|fail|blocked|not-run
vscode_two_window_focus=pass|fail|blocked|not-run
vscode_sequential_same_terminal=pass|fail|blocked|not-run
vscode_persisted_state_privacy=pass|fail|blocked|not-run
cursor_terminal_appearance_seconds=<number or not-run>
cursor_terminal_exact_origin=pass|fail|blocked|not-run
cursor_two_window_focus=pass|fail|blocked|not-run
cursor_sequential_same_terminal=pass|fail|blocked|not-run
cursor_persisted_state_privacy=pass|fail|blocked|not-run
two_task_acceptance=pass|fail|blocked|not-run
two_task_distinct_attribution=pass|fail|blocked|not-run
two_task_native_fallback=pass|fail|blocked|not-run
two_task_duplicate_count=<count only or not-run>
desktop_interactive=pass|fail|blocked|not-run
desktop_native_fallback=pass|fail|blocked|not-run
desktop_exact_open_seconds=<number or not-run>
desktop_task_count=<count only>
desktop_duplicate_count=<count only>
scroll_mouse_wheel=pass|fail|blocked|not-run
scroll_trackpad=pass|fail|blocked|not-run
scroll_keyboard=pass|fail|blocked|not-run
scroll_voiceover=pass|fail|blocked|not-run
reduce_motion=pass|fail|blocked|not-run
reduce_transparency=pass|fail|blocked|not-run
increased_contrast=pass|fail|blocked|not-run
voiceover=pass|fail|blocked|not-run
full_keyboard_access=pass|fail|blocked|not-run
switch_control=pass|fail|blocked|not-run
system_larger_text=pass|fail|blocked|not-run
light_appearance=pass|fail|blocked|not-run
dark_appearance=pass|fail|blocked|not-run
representative_background_restored=yes|no|not-run
built_in_notch=pass|fail|blocked|not-run
external_display=pass|fail|blocked|not-run
no_notch=pass|fail|blocked|not-run
spaces=pass|fail|blocked|not-run
fullscreen=pass|fail|blocked|not-run
stage_manager=pass|fail|blocked|not-run
sleep_wake=pass|fail|blocked|not-run
remote_alias=pass|fail|blocked|not-run
remote_platform=<os-architecture category or not-run>
remote_version_checksum=pass|fail|blocked|not-run
remote_task_count=<count only>
remote_duplicate_count=<count only>
remote_decision_route=pass|fail|blocked|not-run
remote_disconnect_reconnect=pass|fail|blocked|not-run
rollback_uninstall_reinstall=pass|fail|blocked|not-run
rollback_owned_artifacts_removed=pass|fail|blocked|not-run
rollback_settings_retained=pass|fail|blocked|not-run
rollback_session_metadata_retained=pass|fail|blocked|not-run
rollback_unrelated_hooks_preserved=pass|fail|blocked|not-run
rollback_codex_threads_untouched=pass|fail|blocked|not-run
rollback_ssh_state_unchanged=pass|fail|blocked|not-run
rollback_reinstall_bundle_match=pass|fail|blocked|not-run
rollback_reinstall_signature=pass|fail|blocked|not-run
rollback_editor_targets_restored=pass|fail|blocked|not-run
rollback_remote_checksums=pass|fail|blocked|not-run
rollback_process_count=<count only or not-run>
rollback_socket_private=pass|fail|blocked|not-run
rollback_doctor_healthy=yes|no|not-run
rollback_nonprompting_smokes=pass|fail|blocked|not-run
rollback_full_verification=pass|fail|blocked|not-run
system_baseline_restored=yes|no|not-run
cove_settings_baseline_restored=yes|no|not-run
remote_baseline_restored=yes|no|not-run
final_process_count=<count only or not-run>
final_socket_private=pass|fail|not-run
final_doctor_healthy=yes|no|not-run
defect_register_reviewed_at=<local ISO-8601 timestamp or not-run>
p0_open_count=<count only or not-run>
p1_open_count=<count only or not-run>
p0_p1_retest_receipts_complete=yes|no|not-run
wrong_scope_send_count=<count only or not-run>
p0_p1_signoff=pass|fail|blocked|not-run
notes=release_candidate_complete
```

For a completed 0.2.0 receipt, the validator additionally enforces every
automated gate and digest checkpoint, 23 passing UI tests with zero failures or
skips, the exact authorized 7-task `L-A` placement (Terminal 1, iTerm2 0,
VS Code 3, Cursor 3), one task each for `L-B`, `D-B`, `R-A`, and `R-B`, one
Desktop task, two remote tasks, timing thresholds, candidate lineage, and closed
current-candidate retests for the two carried editor-window P1 defects. The
schema allowlist is exhaustive; a missing key is not implicitly `pass`.
The final 0.2.0 validator accepts only
`source_change_reason=homebrew_release_validation_trust_hardening` and
`notes=release_candidate_complete`; use `not-run` while those fields remain
open rather than recording free-form text.

The source-candidate fields reserve a reference for the deterministic source
manifest and digest. No source-manifest path or digest is claimed by this
pre-freeze runbook. Before any observed test/package/install evidence is called
current for a frozen release candidate, generate that manifest, bind the root
receipt to it, verify its digest before and after the applicable gates, and set
`source_candidate_digest_verified=yes` in that receipt. A
placeholder, `not-created`, `not-run`, or an unverified digest leaves the
candidate-to-evidence release row open.

### New-candidate rollover after a failed receipt

`candidate-write` deliberately rejects a repository-root receipt bound to a
different digest. After a product fix, use this sequence rather than erasing
or relabeling the failed attempt:

1. Preserve the old manifest, digest, and receipt together in a new private
   directory outside the repository. Record the old digest and the SHA-256 of
   the final, factually corrected old receipt. Never overwrite that preserved
   set.
2. Move the old root receipt into that preserved directory; do not delete it.
   Leave the old manifest and digest in place until the replacement write.
3. Run `make candidate-write` only after the replacement source is final. It
   atomically replaces the root manifest and digest.
4. Create the new root receipt with the exact required header and new digest
   as lines 1-2. Record `supersedes_source_candidate_digest` and
   `superseded_candidate_receipt_sha256`, carry every old P0/P1 failure as
   historical or `fixed-awaiting-retest`, and initialize all new authorization
   and evidence fields without inheriting prior passes.
5. Run `make candidate-verify` before collecting new evidence and again after
   every applicable gate. A moved receipt must be restored if the replacement
   write does not complete.

## Privacy-safe P0/P1 defect register and signoff

Keep the release-current defect register in `SOURCE_CANDIDATE.receipt`, not in
this candidate-covered runbook, the validation record, task transcripts, or
screenshots. One row contains only a local sequential reference, severity
(`P0` or `P1`), affected release-row name, first-observed timestamp, status
(`open`, `fixed-awaiting-retest`, or `closed`), current-candidate retest receipt
reference, and a short content-free symptom category. Never include prompts,
responses, commands, diffs, paths outside this repository, terminal/task IDs,
Desktop thread IDs, SSH aliases, or user preference values.

A defect may move to `closed` only after the fix is in a newly frozen source
candidate, that candidate's manifest digest verifies, all invalidated
automated/package evidence is rerun, and the exact failed manual row passes on
that candidate. At final review, record the review timestamp, exact P0 and P1
open counts, whether every closed entry has a current-candidate retest receipt,
and the wrong-scope-send count. `p0_p1_signoff=pass` requires all of these:

- `p0_open_count=0` and `p1_open_count=0`;
- `p0_p1_retest_receipts_complete=yes`;
- `wrong_scope_send_count=0`;
- a verified source-candidate digest and a directly observed final process,
  private socket, and healthy Doctor result.

`Blocked`, `not-run`, an absent register review, or zero counts without the
retest/signoff fields never closes the no-open-P0/P1 release row.

## 1. Preflight

1. Unlock the Mac and keep the console active. Confirm the production app is
   the installed 0.2.0 bundle at
   `$HOME/Applications/Codex Cove.app`.
2. Confirm one production Cove process and a healthy doctor report:

   ```sh
   ps -axo pid,etime,command | rg '/Codex Cove\.app/Contents/MacOS/CodexCove'
   "$HOME/bin/codex-cove" doctor --json
   ```

3. Confirm doctor reports strict/deep signature verification and a passing
   `appBundleIntegrity` check for the current bundle. Doctor freshly recomputes
   the installed app tree hash and compares it with the current private install
   manifest; it also verifies app bundle identity/version, owned helper/link/
   hook/editor state, schemas, socket safety, and remote artifact completeness.
   Compare the observed report and current manifest with
   [VALIDATION_0.2.0.md](VALIDATION_0.2.0.md). Do not reuse a historical hash,
   PID, backup count, or doctor result as current evidence.
4. Read the current values in System Settings for every baseline row above.
   If any value has changed, make that observed value the restore target.
5. In production Cove Settings, note the current interaction timing values,
   privacy mode, the presence or absence of the owner-pass token, the selected
   Approval notification rule, and the Task completed sound configuration. Keep
   those values transient; do not copy the Settings file or user project
   tokens into the receipt.
6. Stop if the console is locked, doctor is unhealthy, more than one
   production Cove process is present, or current signature verification
   fails.

## 2. Deterministic human fixture rehearsal

Use the already-built UI-test host, not the production app:

`<repo-root>/DerivedData/Build/Products/Debug/Codex Cove UI Test Host.app`

For each row, quit the prior fixture host, create a fresh private temporary
directory, and launch the named fixture. This example launches `mixed-20`:

```sh
COVE_FIXTURE_HOST="$PWD/DerivedData/Build/Products/Debug/Codex Cove UI Test Host.app"
COVE_FIXTURE_STATE="$(mktemp -d "${TMPDIR%/}/CodexCoveUITests-manual.XXXXXX")"
chmod 700 "$COVE_FIXTURE_STATE"
open -n "$COVE_FIXTURE_HOST" --args \
  --ui-test-fixture mixed-20 \
  --ui-test-state-dir "$COVE_FIXTURE_STATE"
```

Replace the fixture name for each row; the only additional launch argument in
this runbook is the explicitly named `--ui-test-text-scale 2.0` check. Do not
point a fixture at normal Cove Application Support. Fixture success feedback
proves one in-memory send attempt; it does not prove a production receiver or
downstream Codex acknowledgment. In production, a local success is only a
complete private-socket write. A remote relay's internal `decisionAck` confirms
only the remote helper's private-socket write, not downstream processing.

### Attention and navigation

- `mixed-20`: start a stopwatch as Cove is revealed. Identify `Only waiting
  approval` in under 5 seconds. Scroll from top to bottom and back separately
  with a mouse wheel, trackpad, and keyboard. Record each modality; `pointer`
  alone is not sufficient. Open and close focused detail with Escape; confirm
  focused -> queue -> collapsed without losing the top-center anchor.
- `collapsed-cue`: confirm the collapsed surface appears in the accessibility
  hierarchy as one Button named `Open task queue`, with identifier
  `cove.overlay.expand`, a meaningful value/hint, and keyboard activation that
  opens the queue. This fixture check supports but does not close VoiceOver,
  Full Keyboard Access, or Switch Control rows.
- Repeat the scroll path during the VoiceOver and Full Keyboard Access rows in
  the system matrix. The automated AX tree alone does not close those rows.

### Questions

- `single-question`: choose `Option Two`, change it to `Option One`, enter a
  short content-free freeform answer if offered, and submit exactly once.
- `multi-question`: choose `Native application with local public Codex
  interfaces`, enter `owner pass constraint` in Notes, verify both full labels
  remain visible, and submit exactly once.

### Approval scopes

- `command-approval`: select `Allow once`. Verify the selected scope and
  consequence copy are visible and nothing sends before `Confirm Allow`.
  Change to `Allow for this task`, verify the copy changes, change back to
  `Allow once`, and confirm exactly once.
- Relaunch `command-approval` with a fresh state directory. Select `Allow for
  this task`, verify its scope copy, and confirm exactly once.
- Launch a third fresh `command-approval` fixture. Stage a positive choice,
  move the pointer and keyboard focus away, and verify the dirty draft remains.
  Press Escape, choose Keep Editing, then repeat and choose Discard.

### Failure recovery

- `delivery-failure`: select either positive scope and confirm. Verify the
  request remains focused with the neutral text that it could not be sent.
  Choose Retry and verify the second attempt succeeds.
- Relaunch `delivery-failure`. Cause the first attempt to fail again, then use
  `Open in Codex`. Verify only that the control is present and hittable and
  that using it does not silently resolve the unsent request. The fixture jump
  result is discarded, so this is not evidence of any jump; the production
  exact-origin row below remains mandatory.

### Settings controls

Launch `settings-general`, then navigate the same Settings window rather than
restarting between panes:

1. Set Hover delay to `0.45 s`, Collapse after hover leaves to `12 s`, and
   Idle auto-hide to `45 s` using both direct text entry and a stepper or
   keyboard adjustment.
2. In Privacy & Quiet, add `Codex Cove Owner Pass`, try the same token with
   different casing and confirm it deduplicates, then remove it with Delete or
   the visible remove action. Confirm Privacy and related controls have stable,
   meaningful accessibility labels/identifiers. While Privacy is On (or Auto
   is actively redacting), confirm current task/project suggestions are
   disabled and absent from both visible and accessibility output; turn Privacy
   back off before continuing.
3. In Notifications, select Approval. Toggle Detail off, Project off, Source
   on, and Host off. Turn Privacy on and verify the live preview explicitly
   says privacy overrides the content choices; turn Privacy back off.
4. In Sounds, expand Task completed, enable it, select `Cove 8-bit`, and set
   Event volume to `65%`. Preview is intentionally disabled in this host, so
   do not claim audible playback here.
5. Visit every Settings pane. At normal text and again with
   `--ui-test-text-scale 2.0`, verify headings and first controls start at the
   top, all controls remain reachable, focused fields are not clipped, and the
   window remains usable. This is app-owned scaling, not the system Larger
   Text row.

## 3. Production interactive shim, hook trust, and exact-origin jump

This phase creates real Codex tasks and transmits prompt plus working-directory
metadata to OpenAI. Do not run it until the user explicitly authorizes the
exact prompt and task count.

For the first single-task check, use this exact prompt and no other content:

`Reply with exactly CODEX_COVE_INTERACTIVE_OK. Do not use tools, inspect files, or modify anything.`

This is the Terminal.app task already counted in batch `L-A`; it is not an
extra task. Run it from the repository root in an installed,
user-visible Terminal.app pane through the installed shim. Before starting the timed owner
attempt, have the user review System Settings > Privacy & Security for Cove's
Terminal Automation and Accessibility access. If a first real jump must prompt
for access, obtain authorization for a separate untimed bootstrap task using
the same exact content-free prompt, resolve the OS prompt under user
supervision, close that task, and restore the clean starting state. If access
cannot be reviewed or granted, mark exact origin blocked; do not include a
permission dialog in the under-eight-second measurement.

```sh
CODEX_COVE_TRACE_BROKER=1 "$HOME/bin/codex" \
  --sandbox read-only \
  --ask-for-approval never \
  'Reply with exactly CODEX_COVE_INTERACTIVE_OK. Do not use tools, inspect files, or modify anything.'
```

Pass requires all of the following:

- Broker trace reports a Cove app-server mode, currently expected to be
  `selected_mode=direct-stdio`, and does not report native fallback.
- Cove displays the task within 2 seconds and the response is exactly
  `CODEX_COVE_INTERACTIVE_OK`.
- From another app or pane, select the Cove task and time `Open in Codex`.
  The exact originating terminal pane becomes active in under 8 seconds.
- The selected card, any direct request, and the jump all retain the same
  composite origin: local CLI versus Desktop is source-scoped, and remote CLI
  additionally requires its selected host ID. A missing/ambiguous origin must
  show an exact-origin error rather than jump to the currently active task.
- Cove does not persist prompt or response content to its owned settings or
  session-metadata storage. Raw public server messages may exist in process
  memory while Cove is running; immediate memory erasure is not claimed. Do
  not inspect or add task content to the receipt.

In that same visible Codex session, open `/hooks`. Review the eleven Cove-owned
groups: SessionStart, PermissionRequest, PreToolUse, PostToolUse, PreCompact,
PostCompact, SubagentStart, SubagentStop, UserPromptSubmit, Stop, and
SessionEnd. Confirm one Cove command handler is present in each group, review
the command and timeout, preserve unrelated handlers, and approve trust only
if the displayed configuration matches the reviewed installation. Doctor will
continue to warn because trust is not machine-readable; the human-observed row
in `SOURCE_CANDIDATE.receipt` is the release evidence.

For the full required terminal matrix, execute only the placements in
authorized batch `L-A`: one Terminal.app task and three tasks in each editor.
The Terminal.app task above is the one Terminal task in that count; do not
repeat it. Record only adapter category, appearance latency, launch count, and
exact-origin pass/fail. iTerm2 remains supported but is not a required 0.2.0
placement and must not consume a task from this batch. On this host the three
required applications are installed; none had live Cove adapter evidence at
the audit.

For VS Code and Cursor, use `Cove: Create Routed Terminal` separately in the
intended editor window. Confirm each routed terminal receives a different
opaque launch identity, two windows do not cross-focus, and two sequential
authorized tasks in the same routed terminal both return to that terminal.
Each editor window exposes one content-free accessibility anchor derived from
its ephemeral focus-socket identifier. Exact Open must confirm terminal
selection, raise and verify exactly one matching native window, then confirm
terminal and window focus again. Missing Accessibility permission, zero or
multiple anchors, a stale socket, or either failed confirmation is a failed
exact-origin row, never a bundle-level fallback.
The extension may rebuild live registrations on activation, but its persisted
global state must contain only a validated opaque extension session ID—not cwd,
shell, terminal name, markers, prompt, response, command, or diff data. Record
only counts/categories, never opaque IDs.

Schema v1 cannot present two cards whose raw upstream snapshot/session/launch
IDs collide across different origins. The implemented safe behavior hides the
incoming colliding card instead of merging or misrouting it. Do not fabricate a
collision for the owner pass; if one is naturally observed, record a
content-free blocking note and do not treat the hidden task as a duplicate.

The broader two-task acceptance from [EXECPLAN.md](EXECPLAN.md) reuses the
still-visible Terminal.app Task A from `L-A` and adds exactly one separately
authorized `L-B` task in another visible local pane. Do not launch another
Task A. Task B uses this exact read-only approval prompt:

`Use the shell tool to request approval before running /usr/bin/true, with sandbox_permissions set to require_escalated and justification "Codex Cove owner-pass routing check". Do not run it before approval. Do not use any other tool, inspect files, or modify anything.`

Launch Task B with `--sandbox read-only --ask-for-approval on-request`. Pass
requires distinct terminal attribution, Task A completing, Task B remaining
waiting for its native command approval, and the waiting card staying usable.

```sh
CODEX_COVE_TRACE_BROKER=1 "$HOME/bin/codex" \
  --sandbox read-only \
  --ask-for-approval on-request \
  'Use the shell tool to request approval before running /usr/bin/true, with sandbox_permissions set to require_escalated and justification "Codex Cove owner-pass routing check". Do not run it before approval. Do not use any other tool, inspect files, or modify anything.'
```

Start Tasks A and B in two distinct visible terminal panes so terminal
attribution and exact-pane return are observable.

With the user supervising, quit Cove while Task B waits and answer in native
Codex; native interaction must remain usable. Relaunch Cove before continuing.
If the CLI version does not produce that exact read-only request, record the
row blocked rather than inventing a command or file mutation.

Record the pair's distinct terminal attribution, zero-duplicate observation,
and native-fallback result independently. A successful Task A response does
not compensate for a failed or blocked Task B/native-fallback row.

For Codex Desktop, obtain separate batch `D-B` authorization for exactly one
additional task from the repository root using the exact Task B prompt above.
Have the user create it in the visible Codex Desktop app. Do not reuse the CLI
authorization or silently increase its task count. Pass requires all of the
following:

- Cove shows exactly one card for the Desktop task through public
  hook/app-server metadata. Cove intentionally persists the opaque Desktop
  thread/session ID only in its private SQLite metadata because hydration and
  exact `Open in Codex` require it. Prompt and response content remain
  unpersisted, and neither the opaque ID nor content may be copied into this
  repository or the privacy-safe receipt.
- When the native `/usr/bin/true` approval is waiting, Cove keeps the task
  visible and offers `Open in Codex`; it does not expose Cove decision controls
  for a hook-only permission request. Public Desktop hooks lack the safe
  per-request reviewer needed for direct routing, so native fallback is the
  required behavior.
- From another app, `Open in Codex` activates that exact Desktop task in under
  8 seconds through its `codex://threads/<thread-id>` destination. Record only
  the elapsed time, not the identifier.
- The user declines or cancels the request in Codex Desktop, and
  `/usr/bin/true` is not run. If the exact prompt does not produce the expected
  request, record the row blocked rather than substituting another action.

## 4. Production Settings persistence and audible sound

Use the production app only after completing the fixture rehearsal.

1. Set the same owner-pass timing values (`0.45 s`, `12 s`, `45 s`), add the
   temporary token `Codex Cove Owner Pass`, configure the Approval notification
   rule as above, and set Task completed to `Cove 8-bit` at `65%` event volume.
2. Enable event sounds and unmute. Use Preview and obtain human confirmation
   that the sound is audible. Do not infer audibility from API success.
3. Quit and reopen Cove. Confirm all four categories persisted.
4. Restore every production value to the transient preflight snapshot,
   including removal of the temporary token if it was not present before.
5. Quit and reopen once more and confirm the restored values persisted.

Do not enable notification delivery merely to test the matrix unless the user
separately approves that external side effect.

If notification delivery is separately authorized, attention arriving during
Notification Center startup may be held only in the bounded memory-only FIFO;
the service must discard entries that resolved or became suppressed/redacted
before drain. Opening a delivered banner must resolve one exact composite
source/host plus session/launch origin. An ambiguous or stale banner must show
the exact-origin failure and must not open whichever task happens to be current.

## 5. Manual macOS accessibility and appearance matrix

For each row, obtain approval, change only the named setting, relaunch or
reactivate Cove, run the checks, and restore the preflight value. At minimum,
verify collapsed, queue, focused approval, focused multi-question, and every
Settings pane. Confirm visible focus, legible labels, no clipping, one queue
scroll owner, top-center anchoring, and Escape navigation.

| Row | Additional direct observation required |
|---|---|
| Reduce Motion | Geometry changes are immediate; no nonessential motion remains |
| Reduce Transparency | Material/noise is absent, desktop detail does not show through the content surface, and text/control boundaries remain legible |
| Increased Contrast | With separate approval for each appearance change, text, controls, borders, focus, and status remain distinct in light and dark; restore appearance between observations |
| VoiceOver | Names, values, state changes, scope, errors, and logical navigation are announced; queue scroll reaches both ends |
| Full Keyboard Access | Every actionable control is reachable in logical order; focus is visible; queue scroll reaches both ends |
| Switch Control | Scan order reaches every action without a pointer; status is not color-only |
| System Larger Text | Use the largest available system Text Size; focused forms and every Settings pane remain operable without clipping |
| Dark appearance | With approval, use Dark appearance and a representative dark background behind Cove; repeat contrast and focus checks, then restore both |
| Light appearance | With approval, use Light appearance and a representative light background behind Cove; repeat contrast and focus checks, then restore both |

VoiceOver, Full Keyboard Access, Switch Control, and system Larger Text are
human assistive-technology checks. The current 4,244-assertion result and
app-owned 200% fixture remain supporting evidence, not substitutes for these
human observations.

After the two appearance rows, directly verify that the original appearance
and every representative background changed for the checks are restored; set
`representative_background_restored=yes` only from that observation. A passing
contrast observation with an unrestored background leaves restoration open.

## 6. Display, Spaces, fullscreen, Stage Manager, and sleep/wake

- Built-in notched display: verify each transition stays centered in the safe
  top region, no informative or actionable content is obscured by the physical
  obstruction, and actions remain visible. In collapsed mode, also verify the
  resident lanes flank the obstruction. Record the point dimensions and scale,
  not a display serial number.
- External display: with explicit approval, attach user-supplied hardware,
  make that display Main, relaunch/reveal Cove, and repeat overlay widths,
  clamping, anchor, scroll, focus, and Settings-window checks. Restore the
  starting Main-display arrangement afterward. Without external hardware this
  distinct row is `Blocked`.
- No-notch condition: on a user-supplied display confirmed to have no notch,
  repeat the same overlay and Settings checks. A single external no-notch
  display may supply evidence for both rows, but record both observations;
  passing only one category cannot close the other.
- Spaces: after explicit approval, have the user confirm the existing Spaces
  in Mission Control and switch through each one. Cove is stationary and joins
  all Spaces; verify the island remains present rather than trying to move it.
  Separately open Settings and verify its move-to-active-Space behavior, then
  start an authorized task in another Space and verify `Open in Codex`
  activates that exact Space and pane. Restore the starting active Space.
- Fullscreen: with approval, put an unrelated app fullscreen. Verify the
  stationary island and the separate Settings window remain usable and do not
  appear on the wrong display; restore the original fullscreen state.
- Stage Manager: with approval, enable it, repeat island reveal, Settings,
  focus, and exact-origin jump, then restore the preflight state.
- Sleep/wake: obtain immediate approval and have the user initiate actual
  system sleep from macOS. Do not automate `pmset sleepnow` without separate
  authorization. While Cove and one authorized task are healthy, capture the
  latest content-free `pmset -g log` Sleep/Wake timestamps and process/socket/
  task counts, sleep, wake and unlock, then compare the new timestamps. Verify
  the same-process boolean, exactly one process, a healthy mode-0600 socket,
  task-count continuity, zero duplicates, and a working exact-origin jump. A
  display-only sleep or passive idle wait does not count. This closes one
  sleep/wake recovery pass; do not call it a soak.
- Local reconnect evidence is the end-to-end post-wake result above. Do not
  claim an internal broker reconnect from a process that cannot be directly
  observed. Claim relay reconnect only during the selected-host procedure with
  observable remote continuity.

## 7. User-selected SSH host

This release row remains blocked until the user supplies one exact alias and
separately authorizes the connection, deployment, exact prompts, and chosen
disconnect method. Zero configured hosts is a safe baseline, not a passing
remote test. Do not list aliases, parse SSH config, accept a new host key
automatically, or contact any other host.

Before adding the alias, confirm the installed helper includes tested local-only
`remote remove ALIAS --forget` behavior and host-list instance-lock exclusion.
Quit Cove, record the zero-host baseline, and preview add/deploy/remove plans.
The helper must refuse before SSH or config mutation if Cove is still running.
Verify the user-selected host's OS and
architecture, deploy only its matching packaged helper, and verify helper
version and checksum before running anything. Relaunch Cove after the local
alias is added so the running relay manager reads the new selection; do not
use sleep/wake as an implicit configuration reload.

Use separately authorized batch `R-A` and the same exact content-free reply
prompt from Section 3 for one basic remote task. For decision routing, obtain
separate batch `R-B` authorization for the exact `/usr/bin/true` approval
prompt from Section 3 and run it read-only on the selected host. Pass requires
remote source/host labeling, one task per batch, zero
duplicates, a visible request, one selected decision reaching native Codex,
and no replay. Cove serializes controls per host and waits for a unique
correlated internal `decisionAck`; `delivered` proves only the remote helper's
complete private-socket write. It is not a downstream Codex acknowledgment.
A failed ACK or timeout must keep the route retryable and must not consume the
request or accept a late/stale ACK. A disconnect must fail pending sends and
invalidate that relay generation's routes; after reconnect, routing must come
from newly advertised state rather than a stale route.

Have the user choose and approve a bounded disconnect method that affects only
the selected host or its relay. Record the method category, observe the remote
card become disconnected, restore connectivity, and verify one reconnected
task with zero duplicates and working routing. If no suitably scoped method is
approved, leave disconnect/reconnect blocked.

At completion, quit Cove, then run normal `remote remove ALIAS` so the remote integration is
uninstalled before the local alias is removed. Confirm the remote cleanup and
the restored zero-host local baseline, then relaunch Cove so the prior relay is
stopped. If the host is unreachable, separately
confirm that remote cleanup remains incomplete before using `--forget` only to
restore local configuration; that fallback does not count as successful remote
cleanup. Never write the alias into the receipt.

## 8. Owner first-attempt, completion, and restoration gate

After Sections 5-7 are complete or explicitly blocked, restore the baseline,
then run the full owner sequence in Sections 2-4 once without an unscripted
restart. The simulated Retry is an expected step, not a restart of the owner
attempt. Record `owner_scripted_pass=pass` only when every required owner row,
the simulated-failure Open control, the independent real production
exact-origin jump, production persistence, and audible sound all pass in that
sequence. This is an explicit composite gate: the fixture proves the failure
surface and non-resolution behavior, while production proves the real jump.

### First-attempt boundary and reset policy

Preflight, permission bootstrap, authorization review, and any separately
declared practice fixture rehearsal completed before the formal owner sequence
are setup and do not start the scored owner attempt. The scored attempt starts
when the operator begins the Section 2 attention timer for the formal sequence
after declaring the frozen candidate and `owner_candidate_attempt=1`. From
that point, a wrong-scope send, failed required observation, unplanned task or
app restart, skipped step, ad hoc prompt, extra task, or unscripted state reset
fails that candidate's first attempt. The scripted fixture delivery failure
and Retry, the scripted Cove quit/native fallback/relaunch, and the prescribed
settings restoration are expected steps rather than resets.

On failure, stop scoring, record `owner_scripted_pass=fail` and the exact
content-free failed row, update the defect register when applicable, and
restore every system/Cove/remote/background baseline before further work. Do
not erase the receipt, continue from the middle, or relabel a second run as the
first. A product fix requires a newly frozen candidate, a newly generated and
verified source manifest/digest, rerun invalidated automated/package/install
evidence, fresh task authorizations, and then
`owner_candidate_attempt=1` for that new candidate. An external interruption
or missing prerequisite after scoring begins is `Blocked`, not `Pass`; it
still leaves the release row open and any later run must be recorded as a new
attempt rather than hidden as a reset.

Before marking any release checkbox complete:

1. Confirm all system and production Cove settings equal their preflight
   values, the selected-host list equals its preflight value, and the original
   light/dark representative backgrounds are restored. Record each restoration
   field separately.
2. Reobserve and record `final_process_count=1`, a private mode-0600 event
   socket owned by that process, and `final_doctor_healthy=yes`. Historical
   PID/socket/Doctor evidence cannot fill these final fields.
3. Apply the privacy-safe register procedure above. Confirm zero open P0 and P1
   defects, current-candidate retest evidence for every closed defect, zero
   wrong-scope sends, and record `p0_p1_signoff=pass` only if every predicate
   is true.
4. Add the privacy-safe observed pass/fail rows only to the repository-root
   `SOURCE_CANDIDATE.receipt`. Do not edit candidate-covered documentation and
   never record task content.
5. Leave missing hardware, absent authorization, or unreviewed trust explicitly
   open. Do not tag 0.2.0 until every release gate passes and the user asks for
   a tag.

The separately approved uninstall/reinstall rollback drill in
[EXECPLAN.md](EXECPLAN.md) is not part of the uninterrupted owner attempt, but
it remains its own release gate. Record every structured rollback receipt row
without handler content, and do not infer it from installer unit tests. The
pre-freeze source was designed to preserve a valid helper configuration, serialize management
writers under one persistent lock, preflight and revalidate current-user path
identities, verify recorded editor cleanup targets, and keep recovery material
when commit/rollback cleanup fails. The separately authorized live drill must
still prove those properties against the installed candidate before any row is
closed. `rollback_full_verification=pass` requires direct proof of owned
artifact removal; retained settings and session metadata; unchanged unrelated
hook counts/digest, Codex threads, and SSH state; reinstall bundle/candidate
identity; strict signature; both editor targets; all packaged remote checksums;
exactly one relaunched process and its private socket; healthy Doctor; and both
non-prompting smokes. A `Blocked` or failed component keeps the aggregate and
the release row open.
