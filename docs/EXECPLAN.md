# Build Codex Cove as a local Codex-only macOS companion

Candidate-freeze rule: before candidate freeze, this ExecPlan is a living document. `Progress`,
`Surprises & Discoveries`, `Decision Log`, and `Outcomes & Retrospective` must
remain current until `SOURCE_CANDIDATE.manifest` is written. After that point,
do not edit this source-candidate input to record release results. The
repository-root `SOURCE_CANDIDATE.receipt` is the sole release-current evidence
record and is deliberately excluded from the source manifest.

The 2026-08-03 documentation-consistency, remote-plan accuracy, privacy
retention, and candidate-lineage hardening supersedes source candidate
`1ecbea6bbe3cc80141a4e5689ef8f7056eeab8717a9c19991450a6061bcf5a39`;
every candidate-bound result is reset. That candidate already superseded
candidate `bf44614f4877b98b10969e43633f0c82ac671740d078cfd729b680d5762daa4a`,
candidate `840d2e2ae07ebfa7ce5484f89998690c6ade384420476269c84665fb2f631bfb`,
and the earlier focused UI timing failure. The replacement candidate covers the
deterministic editor process tests, zero-advisory dependency gate, Linux-musl
all-target cross-builds, cold-launch-safe UI timing, patched extension packaging
dependency, Cask template, renderer, offline audit, rollback fixtures,
launch-at-login maintenance entry points, helper compensation, documentation,
and release handoff. Strict online audit plus a real Homebrew install, Doctor,
upgrade-or-reinstall, and uninstall remain post-publication gates before the
generated Cask update can merge.

## Purpose / Big Picture

Codex Cove gives a Mac user one unobtrusive notch-aligned view of local Codex
CLI, Codex Desktop, and selected SSH-hosted Codex CLI tasks. The user can see
what finished or needs attention, answer supported CLI questions and
approvals, and return to the exact terminal pane or Desktop task. Everything
owned by Cove remains local except encrypted SSH traffic to hosts selected by
the user. Running `make install`, starting a shim-routed Codex task, and
observing its state in the panel demonstrates the result.

## Progress

- [x] (2026-07-30 21:22Z) Confirmed greenfield repository and local Swift,
  Rust, Node, Codex, and signing toolchains.
- [x] (2026-07-30 21:22Z) Added packaging metadata, dependency checks,
  local-signing workflow, Make targets, install staging, and repository
  orientation.
- [x] (2026-08-01) Added and ran `make deps` for the migrated host: Swift
  package resolution, locked Cargo dependency fetch, and reproducible extension
  dependency installation with `npm ci`.
- [x] (2026-08-03) Added the repository-backed Homebrew Cask distribution
  path, immutable release-to-Cask checksum binding, fail-clean postflight,
  package-manager-owned app removal, launch-at-login maintenance entry points,
  transactional helper compensation, offline/online audit contracts, and an
  idempotent protected-branch handoff. Candidate
  `3d442eec4cba25b9fc86bca649e2c28e5c2ee1125daec1904739697dc6599603`
  was preserved and superseded; no earlier evidence transfers.
- [x] (2026-08-03) Added the exact staged-branch, immutable-asset, disposable-tap
  install/Doctor/reinstall/uninstall handoff needed before the first Cask pull
  request merges. Candidate
  `3f8935453bc4164bf262598de87470c4901a8316543562c6d8e8e74c33386140`
  was preserved and superseded; no evidence transfers to its replacement.
- [x] (2026-08-03) Added clean-tag enforcement, immutable prior-release
  anchoring, strict settings checksums, exact installed-version assertions, and
  a two-commit disposable-tap upgrade gate. Binding-only candidate
  `55e61cdb2d33c676a55537d70308a5be64918d01b53603ef0f5ec0d8039fcd63`
  was preserved and superseded before product gates; no evidence transfers.
- [x] (2026-08-03) Bound staged-Cask validation to a full Homebrew trust-state
  delta and exact restoration, rejected partial upgrade-tap replay before any
  mutation, and repeated future-upgrade cleanup requirements. The candidate
  `00bfe5bbc2d54e1e8ad02cbd1b9748ec3d6e43da0272ceb79490a4e9626a8010`
  was preserved with dependency/bootstrap-only evidence and superseded before
  product gates; no evidence transfers.
- [x] (2026-08-03) Updated the locked transitive `fast-uri` dependency from
  3.1.4 to patched 3.1.5 after the current npm advisory feed failed the
  dependency gate. Candidate
  `d22a1c6746a439ff31216e909469c331dc6a58d3e7df00a943f53ea7245333ed`
  and its failed dependency receipt were preserved before bootstrap or product
  gates; no evidence transfers.
- [x] (2026-08-03) Increased three test-only editor process deadlines from two
  to five seconds after their parallel component run timed out while all five
  isolated serial editor-process tests passed. Candidate
  `76be4c498d4767183cdd3dc60592a4168cf54d35ace35c41090a6765af6883cc`
  and its failed component receipt were preserved after dependency, bootstrap,
  and product-build passes; no evidence transfers.
- [x] (2026-08-03) Extended the descendant fixture lifetime from five to thirty
  seconds so it cannot race the hardened five-second process-group timeout.
  Partial candidate
  `a28da0923ef9526a7ebe957e88c90fbb3a12ca99a2a1d56bd9cb6620fea75067`
  was preserved after its dependency pass but before bootstrap binding; no
  evidence transfers.
- [x] (2026-08-03) Made the dependency gate reject every current npm advisory,
  made the canonical remote builder compile all Cargo targets for both
  Linux-musl architectures, and moved the waiting-row clock after XCTest's cold
  application bootstrap. Candidate
  `89556d520ae23eb829fe9793747cdf2d40a161503ae5a86d51b5dd363eb53997`
  and its focused UI timing failure were preserved after dependency, bootstrap,
  build, component, and static passes; no evidence transfers.
- [x] (2026-08-03) Hardened release-gate reproducibility and UI timing, then
  preserved candidate
  `840d2e2ae07ebfa7ce5484f89998690c6ade384420476269c84665fb2f631bfb`
  after automated, package/install, runtime, and smoke passes but before manual
  release gates; no evidence transfers.
- [x] (2026-08-03) Added exact candidate-bound release notes, pinned workflow
  toolchains, actionlint validation, dependency updates, exact-tag dispatch,
  and split read-only audit/minimal-write Homebrew jobs. Candidate
  `bf44614f4877b98b10969e43633f0c82ac671740d078cfd729b680d5762daa4a`
  was preserved after dependency, bootstrap, product-build, component/static,
  and package passes, then superseded before UI, install/runtime, and manual
  gates for evergreen release wording, manifest-bound rendering, regression
  coverage, and corrected lineage; no evidence transfers.
- [x] (2026-08-03) Corrected documentation availability wording, narrowed
  remote plan-mode claims to supported commands, and documented macOS
  Notification Center retention. Candidate
  `1ecbea6bbe3cc80141a4e5689ef8f7056eeab8717a9c19991450a6061bcf5a39`
  was preserved after dependency, bootstrap, product-build, component/static,
  UI-bundle compilation, package/install, runtime, and smoke passes, then
  superseded before the UI execution, notarization, and manual gates; no
  evidence transfers.
- [x] (2026-07-30 23:05Z) Implemented versioned event, decision, interactive
  request, and theme schemas with cross-language fixtures and bounded framing.
- [x] (2026-07-30 23:05Z) Implemented the Rust shim, direct/durable app-server
  broker modes, hooks, typed first-response handling, management CLI, doctor,
  transactional install/uninstall, remote relay, and four cross-built helpers.
- [x] (2026-07-30 23:05Z) Implemented the Swift reducer, metadata-only SQLite
  persistence, AppKit panel, SwiftUI cards/interactions/settings, usage
  hydration, themes, notifications, sounds, privacy, terminal jumps, and SSH
  relay manager.
- [x] (2026-07-30 23:05Z) Implemented and tested the bundled VS Code/Cursor
  terminal registration and focus extension.
- [x] (2026-07-30) Reworked the live CLI broker for Codex's
  WebSocket-over-Unix `/rpc` transport, compact socket names, bounded
  handshakes, capped raw compatibility input, and large-output-safe transport
  probing.
- [x] (2026-07-30) Added quiet hours, project rules, focused-app quieting,
  reminders, pinning, recoverable session archives, menu-bar-only status mode,
  configurable hover/collapse behavior, optional usage/token metrics, and
  per-event audio source/volume/import controls.
- [x] (2026-08-01) Recorded a historical pre-hardening consolidated component
  baseline: 4,244 Swift milestone assertions, 75 Rust library tests, 12 Rust
  binary tests, 5 Rust approval-review tests, 12 extension tests, strict Rust
  formatting and Clippy, and both public app-server smoke checks. These counts
  do not describe the current source candidate.
- [x] (2026-08-01) Made the advertised remote `--forget` recovery path
  genuinely local-only. Normal removal still performs SSH uninstall first;
  failed normal removal preserves local selection, while `--forget` makes no
  executor call and only restores local configuration. Host-list mutations
  share Cove's instance lock and fail closed while the app is running so a
  stale in-memory relay cannot keep contacting a removed host.
- [x] (2026-08-01) Hardened the current source around composite source/host
  origin, fail-closed schema-v1 ID collisions, exact direct-request and
  notification Open, a bounded startup notification buffer, remote internal
  decision acknowledgments with per-host serialized writes, and exact
  per-window/per-terminal editor bindings with privacy-safe state.
- [x] (2026-08-01) Made the collapsed island a real accessible `Open task
  queue` Button, added stable privacy AX controls, and hid live Settings
  suggestions from both UI and accessibility output during redaction.
- [x] (2026-08-01) Hardened doctor to recompute and compare the installed app
  tree and validate manifest/layout/app/hook/editor/socket/schema/remote state.
  Install and uninstall now preserve valid configuration, serialize writers,
  bind staged mutations to current-user filesystem identities, track exact
  editor cleanup obligations, and retain recovery material on incomplete
  cleanup.
- [x] (2026-08-01) Built and checksum-verified the current-source macOS and
  static Linux remote helpers for arm64 and x86_64 in raw, packaged, and
  installed form. The packaged/installed `SHA256SUMS` SHA-256 is
  `c2a1e797f0478f21c2c744ab77a008a250677586a0d47a35e444fdb1f2a2b76a`.
- [x] (2026-08-01) Assembled and ad-hoc signed the observed current-source bundle,
  installed it at `~/Applications/Codex Cove.app`, and verified its private
  event socket, shim, Cove hook entries, Code and Cursor extensions, four remote
  artifacts, strict/deep signatures, healthy Doctor, build/install byte
  identity, and reproducible non-prompting CLI and Desktop smokes. Nine
  timestamped app backups are retained. This replaces the historical
  pre-hardening installed baseline.
- [x] (2026-08-01) In a historical metadata-only expected-ID pass, proved the
  installed app can hydrate the running Codex Desktop app through public
  `thread/list` and `thread/read(includeTurns=false)`. The then-current task was
  present and readable without recording its identifier or content in this
  plan. Cove intentionally persists that opaque Desktop thread/session ID only
  in its private SQLite metadata for hydration and exact Open; it never
  persists prompt/response content, and the ID belongs in neither this plan nor
  the privacy-safe root `SOURCE_CANDIDATE.receipt`.
- [x] (2026-07-31 15:25Z) Removed the 16 metadata-only CLI verification rows,
  four stale test sockets, and one generated test theme. At that historical
  checkpoint the database contained three read-only Desktop cards; subsequent
  normal public hydration is expected to update metadata. Historical final
  verification therefore recorded a privacy-safe no-ID list result of five rows with
  `vscode`/`notLoaded`, rather than a fixed task ID; the earlier expected-ID
  pass owns the `thread/read` proof.
- [x] (2026-07-31) Completed historical unlocked visual and Accessibility-tree
  checks on that display: flush collapsed state, session-first expanded state,
  scrollable Settings IA, and a single floating Settings window. Subsequent
  notch work deepened the bubble to 52 points and changed its persisted width
  range to 210–420 points with a 260-point default.
- [x] (2026-08-01) Recorded the historical unlocked XCUITest baseline: 20/20 tests,
  zero failures, 392.605 seconds. The suite includes app-owned 200% text-scale
  coverage for Settings and focused forms and verifies Settings geometry of at
  least 980 x 680 points. Result bundle:
  `<repo-root>/DerivedData/Logs/Test/Test-CodexCoveUITests-2026.08.01_10-01-30--0400.xcresult`.
- [x] Replaced the historical component/static/UI counts with one complete
  pre-freeze run against the observed source: 4,244 Swift milestone assertions; 112 Rust
  library + 22 binary + 5 approval/integration tests; 23/23 extension tests;
  build/static/Linux musl checks passed; and 23/23 uninterrupted UI tests passed
  with 0 failures, 0 skipped, and 438.319 seconds. Result bundle:
  `<repo-root>/DerivedData/Logs/Test/Test-CodexCoveUITests-2026.08.01_13-54-55--0400.xcresult`.
- [x] Rebuilt all four remote helpers, packaged/installed the observed pre-freeze
  source, and recorded the pre-freeze hashes, backup count, Doctor,
  process/socket, editor/hook, bundle-identity, and non-prompting smoke
  evidence below.
- [ ] Generate and verify a deterministic source-candidate manifest/digest
  across the automated, package/install, and manual evidence. No source
  manifest or digest is claimed yet, so the observed evidence is not yet
  candidate-bound release-current evidence.
- [ ] Obtain explicit prompt authorization, complete the interactive CLI and
  Desktop checks, and review/trust the eleven Cove-owned hook groups while
  preserving unrelated handlers.
- [ ] Record real terminal-matrix, Codex Desktop interactive, and explicitly
  selected SSH-host evidence. No SSH host is selected in this build session,
  so remote deployment must remain unperformed.
- [ ] With separate destructive-action approval, complete the
  `uninstall --keep-settings` / reinstall rollback drill and verify retained
  settings, unrelated hooks, and the fully restored installed candidate.
- [ ] Complete visual AppKit checks on additional displays, separate Spaces,
  fullscreen, Stage Manager, and hardware variants. Complete macOS system
  Larger Text, VoiceOver, Full Keyboard Access, Switch Control, Reduce Motion,
  Reduce Transparency, and Increased Contrast checks. These remain manual and
  are not implied by the automated text-scale or contrast coverage.
- [ ] Complete the owner-scripted release-validation pass.
- [ ] Complete the privacy-safe P0/P1 register review and signoff with zero
  open P0/P1 counts, current-candidate retest receipts, zero wrong-scope sends,
  and final process/private-socket/Doctor evidence.

## Surprises & Discoveries

- Observation: Current machine has Xcode 26.6 selected, Swift 6.3.3, Rust
  1.97.1, Node 23.11.0, npm 10.9.2, and Codex CLI 0.146.0, but no valid local
  code-signing identity. Zig and `cargo-zigbuild` are also available.
  Evidence: `./scripts/bootstrap.sh` passes required and optional tools while
  `security find-identity -v -p codesigning` reports zero identities.
- Observation: The Homebrew Codex 0.146.0 binary advertises the durable daemon,
  but daemon bootstrap requires the standalone installer payload at
  `~/.codex/packages/standalone/current/codex`, which is absent. The public
  `app-server --stdio` transport works and is the installed fallback; native
  Codex remains the final fallback.
  Evidence: bounded daemon bootstrap, direct app-server smoke, and broker tests.
- Observation: Zig and `cargo-zigbuild` are available. All four current-source
  remote targets built; the macOS outputs are arm64/x86_64 Mach-O, the Linux
  outputs are static stripped arm64/x86_64 ELF, and `SHA256SUMS` verified every
  raw, packaged, and installed artifact.
  Evidence: `./scripts/bootstrap.sh`, `file build/remote/*/codex-cove`, and
  `shasum -a 256 -c build/remote/SHA256SUMS`.
- Observation: Codex `--remote unix://...` does not send raw JSON Lines. It
  performs an HTTP WebSocket upgrade on `/rpc`. The first broker implementation
  also exceeded macOS's Unix socket path limit because it embedded a long
  launch identifier in both filenames. Compact opaque names plus a local
  WebSocket terminator fixed both failures.
  Evidence: captured first bytes from a diagnostic private socket, focused
  WebSocket bridge tests, partial-handshake cleanup tests, and oversized-frame
  tests.
- Observation: A smoke test initially failed with EPERM because its fixture
  passed the process-wide temporary directory as the managed theme parent and
  therefore attempted to chmod that shared root. Nesting the store under a
  test-owned directory fixed the fixture and exercised the symlink rejection.
- Observation: Historical read-only reviews found no P0 or P1 issues. P2 findings
  around WebSocket handshake lifetime, old due reminders, and notification
  completion were fixed with bounded cleanup, an indexed due-reminder query,
  completion-gated clearing, and in-flight deduplication. Imported-sound
  directory permissions now use no-follow descriptor validation.
- Observation: A later release-gap audit exposed cross-origin routing,
  notification-open, editor cleanup, and uninstall commit-integrity gaps. The
  current source addresses those gaps with composite origins, exact
  notification/editor routing, recorded cleanup obligations, identity-bound
  transactions, and surfaced commit failures. The pre-freeze source's
  consolidated and installed evidence passed and is recorded below.
- Observation: The first installed WebSocket broker could reset after the
  Codex update interstitial because it spawned app-server before the first
  protocol frame. Lazy child startup fixed that path. A second live trace
  exposed macOS error 35 on outbound broker writes because the accepted Unix
  stream inherited nonblocking mode; restoring blocking mode and bounded
  transient flush handling fixed it.
  Evidence: two simultaneous installed TUI sessions reached native Codex
  prompts through distinct mode-0600 broker and decision sockets.
- Observation: Desktop discovery initially timed out even though the direct
  public stdio smoke succeeded. The public proxy path needed a short probe
  deadline, and real `thread/read` replies arrived out of request order. The
  original sequential waiter discarded unmatched valid response IDs. A bounded
  response buffer now correlates replies by ID; regression fixtures cover a
  five-second hung proxy and `B, A, C` responses for `A, B, C` requests.
  Evidence: the installed app at that earlier checkpoint emitted no Desktop
  timeout and persisted three public Desktop cards within startup.
- Observation: One Rust transport-selection test had an artificial one-second
  timeout that could expire under the full parallel test runner. Production
  timing was unaffected. A five-second test-only budget passed 25 consecutive
  16-thread stress iterations.
- Observation: In the 2026-07-31 normal-launch baseline, the app idled at 0.0
  percent CPU and 72,576 KiB resident memory. `lsof -i` reported no network
  socket owned by Cove while no remote host was selected.

## Decision Log

- Decision: Keep repository closed to other agent harnesses at both UI and
  type-system boundaries.
  Rationale: User explicitly narrowed product to Codex CLI and Desktop.
  Date/Author: 2026-07-30 / Codex.
- Decision: Use public Codex app-server and hooks instead of parsing or writing
  Codex internal storage.
  Rationale: Stronger compatibility and clean-room boundary.
  Date/Author: 2026-07-30 / Codex.
- Decision: Package with SwiftPM and command-line tools and use ad-hoc signing
  by default. A named identity is accepted only when it already exists.
  Rationale: Ad-hoc signing is sufficient for this local, non-notarized build
  and avoids mutating login-keychain trust. The optional identity-creation
  target is not part of the normal install path.
  Date/Author: 2026-07-30 / Codex.
- Decision: Prefer the durable app-server daemon, fall back to the public
  direct stdio transport when the standalone daemon payload is unavailable,
  and finally execute native Codex unchanged.
  Rationale: The installed official binary supports direct stdio today, while
  replacing the user’s Codex installation would exceed this project’s scope.
  Date/Author: 2026-07-30 / Codex.
- Decision: Keep prompt, response, command, and diff content memory-only.
  Rationale: Metadata persistence supports unread/reminder behavior without
  creating a second sensitive transcript store.
  Date/Author: 2026-07-30 / Codex.
- Decision: Persist an opaque Desktop thread/session ID only in Cove's private
  SQLite metadata.
  Rationale: Public hydration and exact `codex://threads/<id>` Open require the
  non-content identifier. It is excluded from repository evidence and
  privacy-safe receipts, and no Desktop prompt/response content is persisted.
  Date/Author: 2026-08-01 / Codex.
- Decision: Use source, plus selected host ID for remote CLI, as composite
  origin everywhere an upstream ID is matched or routed.
  Rationale: The same opaque ID may legally occur in local CLI, Desktop, or
  multiple remote origins. Missing/ambiguous origin must fail closed. Schema
  v1 still keys visible cards by raw ID, so an incoming cross-origin collision
  is hidden rather than merged until a future composite presentation identity.
  Date/Author: 2026-08-01 / Codex.
- Decision: Treat dismissal as a recoverable local archive.
  Rationale: Cove retains metadata-only jump state, stores only private
  dismissed identifiers, and can restore cards without touching Codex threads.
  Date/Author: 2026-07-30 / Codex.
- Decision: Minimal menu-bar mode leaves a 126-by-24 black island cue.
  Rationale: It preserves approval/input visibility without showing sensitive
  task text and keeps full controls available from the menu bar.
  Date/Author: 2026-07-30 / Codex.
- Decision: Normal and menu-only collapsed views use the same attention-cue
  policy and draw no idle placeholder.
  Rationale: The black/translucent shell remains visually joined to the notch,
  while every visible glyph corresponds to an active, waiting, failed unread,
  completed unread, or interrupted unread task. No title, theme, source,
  count, or `AppServer` text appears while collapsed.
  Date/Author: 2026-07-31 / Codex.
- Decision: Settings uses one reusable floating AppKit window.
  Rationale: Moving the window to the active Space, keeping it visible on
  deactivation, deminiaturizing it, activating the accessory app, and
  reasserting key/front order on the next run-loop turn prevents Settings from
  falling behind the primary Codex window.
  Date/Author: 2026-07-31 / Codex.
- Decision: Settings uses a sidebar with one explicitly scrollable detail pane.
  Rationale: Appearance, General, Sounds, Privacy & Quiet, and Sessions & Data
  stay discoverable without forcing every control into one over-tall form. A
  wider landscape window and versioned frame autosave avoid restoring the old
  clipped geometry.
  Date/Author: 2026-07-31 / Codex.
- Decision: Normal collapsed width is a persisted 210-to-420-point setting,
  defaulting to 260 points; the 52-point collapsed and 520-point expanded
  states use the same resolved width and fixed screen-top edge.
  Rationale: Physical notch dimensions vary by Mac. The lower lane must fit
  animated task residents below the obstruction, while the expanded body
  should read as the same island sliding downward rather than a separate card.
  Date/Author: 2026-07-31 / Codex.

## Outcomes & Retrospective

The source implementation is complete, including the final origin,
notification, editor, Doctor, and installer/uninstaller hardening. The observed
pre-freeze source passed the consolidated component/static/UI run, four-target
build, package/install replacement, Doctor, process/socket, editor, signature,
and non-prompting CLI/Desktop smoke checks; their exact pre-freeze evidence is
recorded below and is not candidate-bound. The historical Desktop metadata pass
demonstrated public hydration/read behavior. Cove keeps
the opaque Desktop thread/session ID only in private SQLite metadata for
hydration and exact Open, while this plan and the root
`SOURCE_CANDIDATE.receipt` retain neither that ID nor prompt/response content.
No SSH host was selected, crawled,
contacted, or modified by Cove. Manual accessibility/hardware/Spaces,
real-terminal and interactive Desktop prompts, hook trust, selected-host,
rollback, and owner-scripted gates all remain open.

## Context and Orientation

`Package.swift`, `Sources/CodexCoveApp`, and `Sources/CoveCore` form the native
application. `helper` is one Rust executable whose behavior depends on its
command or executable name; a symlink named `codex` acts as the transparent
shim. `extension` contains the editor terminal adapter. `schemas` contains the
cross-language event contracts. `Packaging` and `scripts` assemble and install
the application without Xcode.

A broker is a local process between the interactive Codex terminal UI and
Codex app-server. It forwards protocol messages while associating them with the
terminal launch and composite source/host origin that created the connection.
A hook is a Codex-owned process invocation used for Desktop and fallback
lifecycle events. A relay carries
bounded event frames over a normal SSH standard-input/standard-output channel;
it never opens a remote listening port. Its internal `decisionAck` confirms a
remote helper's private-socket write, not downstream Codex acceptance.

## Plan of Work

First define shared event, theme, decision, usage, and terminal-location
schemas. Implement decoders that accept new fields, reject oversized frames,
and ignore unknown event kinds.

Next implement the Rust helper. The shim identifies commands that can use
`--remote`, registers terminal metadata, and safely invokes the real Codex
binary. Management commands install only Cove-owned files, merge hook JSON
structurally, diagnose manifest/layout/tree/app/hook/editor/socket integrity,
manage privacy/theme state, and remove identity- and checksum-matching
artifacts. Management writers serialize under the persistent instance/config
lock. Install preserves valid configuration; uninstall preflights and stages
reversibly before commit. Hook and relay modes must fail open to native Codex
behavior.

Implement the Swift state reducer and native panel in parallel. The panel uses
AppKit for window behavior and SwiftUI for content. It must support collapsed
and expanded forms, session priority, settings, themes, privacy, and a
mode-0600 Unix socket listener. Task matching and exact Open use composite
source/host origin and fail closed on ambiguity. The schema-v1 presentation
layer hides an incoming cross-origin raw-ID collision rather than risking a
wrong card or jump.

Build the editor extension as a bundled VSIX. Each editor window owns a live
focus server; each Cove-created routed terminal receives a fresh opaque launch
ID. Registration can arrive before or after launch, sequential sessions remain
bound to that terminal, and focus targets only an exact match. A content-free
per-window accessibility anchor lets Cove raise and verify exactly one native
editor window between two confirmed terminal-focus phases. Missing, duplicate,
stale, or inaccessible anchors fail closed. Clear legacy sensitive global state
and persist only a validated opaque extension session ID.

Finally assemble nested executables, schemas, and extension into the app
bundle. Sign nested code first, sign the app last, verify strictly, stage an
atomic installation, run component and integration tests, then perform bounded
live CLI/Desktop checks.

## Concrete Steps

Work from the repository root:

    make deps
    make bootstrap
    make build
    make test
    make ui-test
    make package
    make install
    ~/bin/codex-cove doctor

To include opt-in remote helpers:

    make package-with-remote
    make install-with-remote

`make deps` resolves Swift packages, fetches Cargo's locked graph, and runs the
extension's `npm ci`. The bootstrap check should list every required command as
`ok`, and tests must exit zero. Packaging must end with successful strict
`codesign` verification.
Doctor must report the installed app, freshly recomputed tree-hash match, app
identity/version, real Codex binary and supported version, owned shim/hooks,
socket safety, schemas/remote bundle state, and recorded editor targets.

## Validation and Acceptance

Unit tests cover state priority, deduplication, stale usage, theme bounds,
redaction, shim command routing, recursion prevention, hook timeout, and
length-framed relay input. Protocol fixture tests cover unknown fields and
resolved request races.

The current-source automated observations passed 4,244 milestone assertions, 112 Rust
library tests, 22 Rust binary tests, 5 Rust approval/integration tests, 23/23
extension tests, and 23/23 XCUITests with zero failures, zero skipped, and
438.319 seconds. `xcresulttool` summarized the result as `Passed`; the bundle is
`<repo-root>/DerivedData/Logs/Test/Test-CodexCoveUITests-2026.08.01_13-54-55--0400.xcresult`.
This supersedes the historical pre-hardening 20/20 UI result and adds
collapsed-Button and privacy-hidden-suggestion coverage. App-owned 200%
text-scale fixture coverage is not a substitute
for the remaining macOS system Larger Text or assistive-technology matrix.

Execute the remaining production scenarios only through
[OWNER_PASS_0.2.0.md](OWNER_PASS_0.2.0.md). It requires an unlocked console,
captures every mutable baseline before a change, restores each approved system
setting, and keeps a privacy-safe receipt. Starting live CLI or Desktop tasks
also requires explicit authorization for the exact prompt and metadata that
will be transmitted.

Its task-count table is the canonical minimum: seven Task A local CLI launches
cover Terminal.app and the VS Code/Cursor two-window plus sequential
checks; one local Task B reuses the Terminal Task A for the two-task and native
fallback checks; Desktop has one separately authorized Task B; and the selected
remote host has separately authorized Task A and Task B launches. iTerm2 remains
supported but is not a required 0.2.0 placement. The clean minimum is 11 new
tasks, or 12 if the separately authorized, unscored
permission-bootstrap Task A is required. This arithmetic is not authorization,
and an expired or failed task cannot be replaced under an already consumed
count.

The root `SOURCE_CANDIDATE.receipt` supplies the exact release evidence for
editor routing and state privacy, two-task native fallback, production persistence/audibility,
system/Cove/remote/background restoration, final process/socket/Doctor state,
full rollback verification, and the P0/P1 register signoff. `Blocked` leaves a
row open; it never passes or waives a release requirement. A scored first-run
failure or unscripted reset remains failed for that candidate. Only a newly
frozen candidate with a newly verified manifest/digest and rerun invalidated
evidence receives a new candidate first attempt.

Treat uninstall as a separate destructive rollback drill, not an implicit
owner-pass step. Run it only after explicit approval. Before doing so, record
the installed hashes and a content-free count/hash baseline for unrelated hook
entries. With the user supervising, quit Cove normally and verify that no Cove
process remains; otherwise the maintenance launch will fail the instance lock.
Run `$HOME/bin/codex-cove uninstall --keep-settings`, making retained
preferences and session metadata an explicit exception to artifact removal.
Then verify Cove-owned artifacts were removed without touching Codex threads,
unrelated hooks, retained Cove settings, SSH configuration, or modified files.
Reinstall immediately with `make install-with-remote`, explicitly relaunch
`$HOME/Applications/Codex Cove.app`, and only then repeat doctor,
signature, bundle/candidate comparison, editor-target installation, remote
checksums, process/socket, and both nonprompting smoke verifications. Record
every structured rollback component from the owner runbook; the aggregate
passes only when all components do. If approval is not granted, leave the
uninstall drill open.

## Idempotence and Recovery

Builds replace only repository `build`, Swift `.build`, Rust `target`, and
extension output. Installation stages a fully verified app before replacing an
existing app and retains a timestamped previous-app backup for each successful
replacement. It preserves a valid existing helper configuration and rejects
malformed or layout-unsafe configuration before mutation. Hook writes use a
parsed merge and timestamped backup. All management/config writers serialize
under the persistent instance/config lock. An unexpected existing `~/bin/codex`
blocks installation instead of overwriting it.

Install/uninstall preflight captures current-user filesystem identities and
revalidates them at stage, replacement, commit, rollback, and recovery cleanup.
Uninstall validates the manifest, app identity/tree hash, helper, links, hooks,
and recorded editor targets before staging; it is reversible until commit and
does not report success if commit cleanup fails. Modified, missing, wrong-owner,
wrong-type, symlinked, or concurrently replaced artifacts fail closed, with
recovery material retained when automatic restoration cannot finish.

Remote deployment uses version directories and an atomic `current` symlink. A
failed upload leaves the prior version selected. Unknown SSH host keys block
deployment until normal SSH trust is established.

## Pre-freeze artifacts and notes

Pre-freeze toolchain, automated, and installed-artifact evidence follows. Values
are content-free observations from the observed source and installed state.

    swift 6.3.3
    rustc 1.97.1
    node 23.11.0
    codex-cli 0.146.0
    Xcode 26.6 selected
    valid signing identities: 0
    zig: available
    cargo-zigbuild: available
    make deps: passed on migrated host
    make test: passed
    pre-freeze Swift milestone assertions: 4,244
    pre-freeze Rust tests: 112 library + 22 binary + 5 approval/integration
    pre-freeze editor extension tests: 23/23
    make build and static gates: passed
    static gates: shell syntax; cargo fmt --check; Clippy all targets/features -D warnings
    Linux musl all-target check: passed
    pre-freeze unlocked XCUITests: 23/23, zero failures, zero skipped, 438.319 seconds
    pre-freeze xcresult summary: Passed
    pre-freeze xcresult bundle: <repo-root>/DerivedData/Logs/Test/Test-CodexCoveUITests-2026.08.01_13-54-55--0400.xcresult
    installedAt: 2026-08-01T18:30:35.421Z
    pre-freeze remote artifacts: all four raw/package/installed checksum sets passed
    pre-freeze remote file types: macOS Mach-O arm64/x86_64; Linux static stripped ELF arm64/x86_64
    packaged/installed remote SHA256SUMS SHA-256: c2a1e797f0478f21c2c744ab77a008a250677586a0d47a35e444fdb1f2a2b76a
    pre-freeze build/install bundle diff: identical
    pre-freeze installed app tree SHA-256: cf6e54e6f38810ee0c51cdc8e72ebf09fe07b9ef2683cca18caa1e9078a12222
    pre-freeze installed helper SHA-256: 42d3ecd060d1ab8fc91f7a65205be4479c382b2ade954a1305f7567388f8d051
    pre-freeze install-manifest file SHA-256: 49d8b6801f6c6ed88969320eefcc34a7a0e2206004d1f938d89f88cb5caf258b
    pre-freeze helper copies: build app, installed app resource, and support/bin hashes match
    pre-freeze strict/deep code-signing verification: build and installed apps passed
    pre-freeze editor installs: Code and Cursor codex-cove-local.cove-extension@0.2.0
    pre-freeze versions: codex-cove 0.2.0; codex-cli 0.146.0
    pre-freeze retained timestamped app backups: 9
    latest backup: $HOME/Applications/Codex Cove.app.backup.20260801T183035Z
    pre-freeze non-prompting rate-limit smoke: initialized/read passed; primary=false; secondary=false; resetCredits=true; ignored lines=0
    pre-freeze non-prompting Desktop smoke: initialized/list passed; 5 rows; vscode/notLoaded; expected ID unset; no IDs/content recorded
    pre-freeze installed process: exactly one, PID 90751
    pre-freeze event socket: Socket; srw-------; uid 501/current user; PID 90751 fd 4u
    pre-freeze doctor: exit 0; healthy true; 18 checks
    pre-freeze doctor passes: codexVersion, installManifest, managedBinaryIntegrity,
      codexShim, managementLink, hooks, installedApp, appBundleIntegrity,
      appIdentity, appSignature, schemaCompatibility, remoteArtifacts,
      editorExtension, eventSocket
    pre-freeze doctor warnings: appServerTransport direct-stdio fallback ready;
      terminalAutomation not probed; terminalAccessibility manual; hookTrust manual
    source candidate manifest: not created; no digest claimed
    source candidate digest verification: not run; release evidence binding open

## Interfaces and Dependencies

The shared `CoveEvent` envelope contains schema version, event ID, timestamp,
source, session ID, optional turn/launch/host IDs, and event payload. Local IPC
uses newline-delimited JSON over a user-only Unix socket. Remote IPC uses a
four-byte big-endian length followed by the same JSON, capped at one MiB.
Source and, for remote CLI, selected host ID form the non-content composite
origin for matching and routing. Schema v1 still presents cards under raw
upstream IDs, so an incoming cross-origin raw-ID collision is hidden
fail-closed rather than displayed or routed incorrectly.

Local decision success is only a complete validated private-socket write and
has no receiver ACK. Remote decision controls add a unique `controlId` and a
correlated internal `decisionAck` after the remote helper's socket write;
per-host writers are serialized, and failure/timeout preserves the route for
retry. Disconnect fails pending sends and invalidates that relay generation's
routes. Neither mechanism acknowledges downstream Codex processing.

Swift exposes `SessionSnapshot`, `SessionLocation`, `SessionState`,
`ApprovalRequest`, `QuestionRequest`, `PlanSnapshot`, `UsageSnapshot`,
`ThemeDefinition`, `PrivacyScene`, and `RemoteHost`. Source values are closed
to local CLI, Codex Desktop, and remote CLI.

Rust exposes management commands `install`, `repair`, `doctor`, `uninstall`,
`remote`, `privacy`, and `theme`. Invoking the installed binary as `codex`
activates shim routing. `CODEX_COVE_BYPASS=1` always invokes the recorded real
Codex binary directly.

The editor extension owns one ephemeral focus server per VS Code/Cursor window
and creates a fresh opaque launch ID per routed terminal. It persists only one
validated opaque extension session ID. Desktop hydration persists the opaque
thread/session ID only in private Cove SQLite metadata so exact Open remains
possible; prompt and response content remain memory-only.

Revision note: Initial implementation-state plan created 2026-07-30 and
updated after the WebSocket broker corrections, Desktop response-correlation
fix, historical component and parallel-stress gates, remote cross-build,
user-requested collapsed/settings refinements, adjustable notch width, Settings
IA migration, historical 20-test UI validation and local installation, plus
the later composite-origin, exact notification/editor routing, startup buffer,
remote decision acknowledgment, accessibility/privacy, doctor, and
transactional-management hardening, followed by current-source automated and
installed-state verification. Manual system accessibility,
hardware/Spaces, prompted interaction, hook trust, selected-host, rollback, and
owner-validation gates remain open.
