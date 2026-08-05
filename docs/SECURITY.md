# Security & Privacy

Codex Cove is designed as a current-user, local-only companion. Its primary
security goals are to keep Codex content out of durable Cove storage, route
decisions only to an authoritative request, fail safely when identity is
ambiguous, and remove only artifacts Cove can prove it owns.

## Trust boundaries

Cove trusts:

- public Codex CLI app-server and hook contracts;
- local processes and filesystem objects only after current-user, type,
  ownership, permission, and identity checks;
- the VS Code/Cursor extension bundled in the same app package;
- macOS Accessibility and Automation only for user-enabled exact-focus actions;
  and
- SSH aliases that the user explicitly adds after configuring host-key and
  authentication policy outside Cove.

Cove does not trust externally supplied task IDs, socket paths, JSON fields,
editor registrations, remote acknowledgements, or existing install paths
without validation. It does not use private Codex databases, transcript files,
cookies, credentials, or UI scraping.

## Data classification

### Memory only

The following may be displayed while Cove is running but are not written to
Cove's durable state:

- prompts, answers, responses, commands, diffs, and request detail;
- plan and agent-message text;
- rate-limit values, profile token totals, and per-task token metrics; and
- notification content assembled for a current event.

macOS Notification Center may retain a delivered banner according to the
system's own settings. Cove's notification matrix and Privacy mode control what
is placed in that banner.

### Persisted locally

Cove stores only what it needs to restore settings and bounded task behavior:

- versioned UI, privacy, sound, notification, quiet, and interaction settings;
- opaque session, turn, launch, parent, source, and selected-host identifiers;
- status, timestamps, unread, pin, reminder, and local archive state;
- opaque TTY, pane, editor-terminal, host-bundle, and focus-socket identifiers;
- imported theme definitions and manifest-owned audio copies; and
- helper configuration, install checksums, and explicitly selected SSH aliases.

Absolute editor and decision socket paths are reconstructed at runtime rather
than stored as terminal metadata. SSH credentials and private keys are never
copied into Cove configuration.

### Codex-owned data

Cove never deletes, archives, edits, or creates Codex tasks or transcripts.
Mark-read, pin, reminder, and archive actions affect Cove metadata only. The
native Codex client remains authoritative for unsupported decisions and task
state.

## Privacy controls

- **Privacy On** redacts content in Cove surfaces and notification output.
- **Privacy Auto** conservatively redacts when a known conferencing or recording
  app is running and **Conservative capture privacy** is enabled. This is
  deliberately over-inclusive and does not prove that a recording is active.
- **Privacy Off** permits only the content fields independently enabled in Cove.
- Locking or deactivating the macOS user session hides Cove and applies its
  locked privacy scene.
- Quiet hours, focused-app quieting, and project silence rules suppress sounds
  and notifications but do not hide an approval or input request from the Cove
  queue.

Privacy can also be changed with `codex-cove privacy auto|on|off`. The helper
updates the same private configuration and sends a bounded local event to a
running Cove instance.

## Decision safety

Cove shows actionable controls only for an authoritative request received from
its per-launch app-server broker. It does not infer a choice or broaden an
approval scope.

- Positive scopes require selection and explicit confirmation.
- Requests are correlated by origin, launch, session, and request ID where the
  protocol supplies them.
- Concurrent launches keep separate decision sockets.
- The first matching response wins; stale or duplicate responses do not route.
- A successful local or remote delivery receipt proves only a complete bounded
  socket write, not acceptance or completion by Codex.
- Unknown, malformed, stale, unsupported, auto-review, and ambiguous requests
  are suppressed or returned to native Codex.

## Filesystem and IPC protections

The main private root is `~/Library/Application Support/Codex Cove`. Runtime
and data directories are required to be real current-user directories and are
restricted to the user. Configuration, manifests, state files, imported assets,
and socket endpoints are written with private permissions.

Critical operations use:

- no-follow opens and regular-file/socket type checks;
- owner, link-count, mode, inode, and device validation where identity matters;
- atomic writes or staged transactions;
- bounded frames, files, handshakes, queues, and response maps;
- monotonic deadlines for connects, reads, writes, and child startup; and
- opaque hashed or random socket names to remain within Unix path limits without
  exposing task content.

The app holds a process-lifetime singleton lock. Installer and remote-host
mutations use separate advisory locks so concurrent commands cannot overwrite a
newer configuration snapshot.

## Installation boundary

The installer may manage only these current-user surfaces:

| Surface | Purpose |
| --- | --- |
| `~/Applications/Codex Cove.app` | Native app bundle |
| `~/Library/Application Support/Codex Cove` | Helper, config, manifest, runtime, settings, metadata, imports |
| `~/bin/codex-cove` | Cove-owned link to the managed helper; native `codex` is not replaced |
| `~/.codex/hooks.json` | Structurally merged Cove hook entries |
| VS Code/Cursor extension stores | The recorded private Cove extension |
| Selected remote helper path | Helper deployed only through an explicit SSH alias |

Before replacing or removing anything, Cove validates the expected bundle ID,
checksums, link targets, hook structure, and install manifest. An unexpected or
modified path blocks the transaction and is preserved. Uninstall never edits
SSH configuration or unrelated hooks and never contacts an unselected host.
An upgrade removes a former `~/bin/codex` interception link only when it is
still the exact Cove-owned link recorded by the legacy install; all foreign
paths are preserved.

The Homebrew Cask preserves this boundary rather than reimplementing integration
with broad shell mutations. It installs the app at the same
`~/Applications/Codex Cove.app` path and invokes only code embedded in the
verified app: a bounded app maintenance mode first restores the persisted
Launch at Login preference, then the helper transaction applies integration.
Postflight failure compensates by unregistering Launch at Login before
Homebrew rolls the app back. During removal or upgrade, Homebrew first quits
Cove, asks that helper to remove Cove-owned integration with
`--keep-app --keep-settings`, and then removes or replaces the app artifact
Homebrew owns. `--keep-app` is a narrow package-manager handoff; it does not
relax manifest, ownership, bundle identity, or checksum validation.

The helper stages and validates its local filesystem transaction before it
invokes bounded editor or login-item cleanup, then revalidates before commit.
Those external stores do not share a transaction with Cove. If a later step
fails, Cove restores its local retry state and attempts idempotent compensation:
only editor targets proven present before cleanup are reinstalled, and the
persisted Launch at Login preference is resynchronized. Compensation failure is
reported explicitly; it is not claimed as an atomic rollback. Rerunning the
Cask operation safely rechecks the recorded cleanup obligations.

Use `codex-cove install --app-path PATH --plan`,
`codex-cove uninstall --plan`, `codex-cove remote deploy ALIAS --plan`, and
`codex-cove remote remove ALIAS --plan` to inspect supported planned mutations
before applying them. `remote add` updates local configuration directly and has
no plan mode.

## macOS permissions

Cove is not App-Sandboxed. It requests narrowly scoped user-controlled macOS
capabilities instead:

- **Accessibility** enables global shortcuts and exact editor-window or OSC
  marker focus.
- **Automation → Terminal/iTerm2** enables exact TTY-based tab/session focus.
- **Notifications** enables configured system banners.
- **Login Items** enables optional launch at login.

Accessibility and Automation are sensitive permissions. Grant them only to an
app bundle you built or verified, and revoke them from System Settings when no
longer needed. An ad-hoc-signed replacement may require the grant to be toggled
and renewed.

## Network behavior

Cove has no telemetry, analytics, crash-report upload, account service, update
service, or Cove-hosted backend. Public account usage is read through the local
Codex app-server; Codex itself remains responsible for its own authenticated
network traffic.

The only Cove-initiated network transport is SSH to aliases explicitly stored
with `codex-cove remote add`. Relay commands use strict host-key checking,
`BatchMode=yes`, a bounded connection timeout, and bounded keepalive probes. No
password prompt is hidden behind the app, and Cove does not enumerate SSH
configuration.

Homebrew and a web browser may separately contact GitHub to obtain a tap or
release. That package-manager download is not runtime network behavior by the
Cove app. The public Cask must use the immutable version-tag URL and a literal
SHA-256 for the matching app archive; users should not substitute a private
mirror or disable checksum/quarantine checks merely to make installation pass.

## Diagnostics

`codex-cove doctor` reports installation identity, schemas, app-server
availability, editor extension state, sockets, and remote artifacts. It does
not intentionally include task content, but it does show local installation
and socket paths needed to explain what it inspected. Event payload redaction
removes fields with sensitive content keys. Editor focus logs contain only
fixed phase, boolean result, and fixed error-category fields.

Before sharing any diagnostic output, review it for usernames, paths, host
details, opaque identifiers, and anything else you do not intend to disclose.

## Build and release trust

Rust and npm dependencies are locked. Release source is bound to a Git commit
and, when the release runbook requires it, a deterministic source-candidate
manifest and detached privacy-safe receipt. Published archives should include a
SHA-256 checksum.

The Homebrew definition is executable Ruby from an explicit custom tap. Inspect
the repository URL before tapping it, and install the fully qualified
`cdimartino/codex-cove/codex-cove` token. For each version, the release pipeline
renders `codex-cove.rb` from the final local app ZIP checksum, includes that Cask
in the aggregate `SHA256SUMS`, and publishes it with the immutable release. The
verified file is then reviewed and landed unchanged at `Casks/codex-cove.rb`.
Never accept `sha256 :no_check`, `version :latest`, a mutable asset URL, code
that removes quarantine, or a Cask that requires `sudo` for Cove integration.

The default local packaging path is ad hoc signed. Ad-hoc signing validates
bundle structure at package/install time but does not establish publisher
identity or Apple notarization. A release must state its signing and notarization
status explicitly; never infer either from the presence of a code signature.

## Report a vulnerability

Do not place secrets, private Codex content, SSH details, task identifiers, or a
working exploit in a public issue. Use GitHub's
[private vulnerability report](https://github.com/cdimartino/codex-cove/security/advisories/new)
when available. If private reporting is unavailable, open a minimal public issue
requesting a private contact channel without disclosing the vulnerability.

Include the affected Cove version or commit, macOS and editor versions, the
smallest redacted reproduction, expected versus actual trust boundary, and
whether the behavior requires Accessibility, Automation, or a remote helper.
