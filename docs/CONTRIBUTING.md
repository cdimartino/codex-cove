# Contributing

Codex Cove combines Swift/AppKit, Rust, TypeScript, macOS integration, and
versioned IPC. Changes should preserve its local-only privacy model, native
Codex fallback, exact-origin guarantees, and recoverable installer behavior.

## Set up a development checkout

On an Apple Silicon Mac running macOS 14 or newer:

```sh
git clone https://github.com/cdimartino/codex-cove.git
cd codex-cove
make deps
make bootstrap
make build
make test
```

The minimum supported toolchain is documented in
[Installation](INSTALLATION.md#requirements). `make deps` uses checked-in
dependency locks, performs a clean extension install, and fails if the current
npm audit reports any advisory. `make bootstrap` reports missing tools without
installing machine-level packages.

Use `make run` for an uninstalled development app. It intentionally does not
modify hooks, shell links, editor extensions, login items, or remote hosts.
Use installation targets only when the behavior under test requires those
integrations and you are prepared to restore your local machine afterward.

## Choose the right layer

| Change | Primary location | Expected tests |
| --- | --- | --- |
| State, persistence, queue, settings model | `Sources/CoveCore` | `make swift-test` plus relevant foundation suite |
| Native UI or macOS integration | `Sources/CodexCoveApp` | Foundation coverage and `make ui-test` |
| Shim, broker, hooks, install, remote | `helper` | `make helper-test` and relevant smoke/Doctor checks |
| VS Code/Cursor adapter | `extension` | `make extension-test` and editor live check when focus changes |
| Wire/schema contract | `schemas`, `extension/schemas`, fixtures | All Swift, Rust, and extension tests |
| Packaging/install scripts | `Packaging`, `scripts`, `Makefile` | Shell syntax, package, signature, Doctor, install/rollback rehearsal |
| Homebrew distribution | Cask template/renderer, `Casks`, release workflow | Rendered checksum match, `brew style`, strict Cask audit, install/upgrade/uninstall smoke |
| UI-test project membership | `XcodeProject.yml` | Regenerate project and run `make ui-test` |

Keep pure policy and data transformations in `CoveCore` where possible. Keep
AppKit, Accessibility, notifications, sound, and process control in the app
target. The Rust helper should remain usable without a GUI and must preserve
native Codex fallback.

## Development commands

```sh
make build
make test
make ui-test
make package
make doctor
```

Individual test layers are available while iterating:

```sh
make swift-test
make store-foundation-test
make milestone13-test
make milestone2-test
make helper-test
make extension-test
```

Before opening a pull request, also run the language-native static checks
relevant to your change:

```sh
cargo fmt --manifest-path helper/Cargo.toml --all -- --check
cargo clippy --manifest-path helper/Cargo.toml --all-targets --all-features -- -D warnings
npm --prefix extension run build
sh -n scripts/*.sh Tests/*.sh
```

The UI test target requires full Xcode 26.6+ and an unlocked console. The Make
target keeps the Mac awake during the run and refuses to start when it cannot
prove the console is unlocked. Timing assertions that describe an in-app action
must start after `XCUIApplication.launch()` returns so cold XCTest and
Accessibility bootstrap time is not attributed to the product.

`make remote-artifacts` builds both macOS helper binaries and invokes
`cargo zigbuild --all-targets` for each Linux-musl architecture before copying
the release executable. This keeps CI, packaging, and the release receipt's two
Linux all-target rows on one implementation path.

## Generated and authoritative files

- `XcodeProject.yml` is authoritative for
  `CodexCoveUITests.xcodeproj`. After changing target membership, regenerate
  with XcodeGen 2.46+ and review the project diff.
- `Resources/CodexCoveIcon-1024.png` and `Resources/AppIcon.icns` are committed
  release inputs. Run `make icon` only when intentionally updating them, review
  both binary changes, and commit them together. Packaging consumes the
  committed icon and must not rewrite source files.
- `extension/package-lock.json` and `helper/Cargo.lock` are committed dependency
  locks. Update them only with the corresponding intentional dependency change.
- Built themes, sounds, the app bundle, editor output/VSIX, Rust target files,
  Swift build products, Derived Data, coverage profiles, and remote binaries are
  generated and ignored.
- The released `codex-cove.rb` is rendered only after the final app ZIP exists,
  because its literal SHA-256 is a build-derived value. The exact verified
  release file is then landed at `Casks/codex-cove.rb` through a normal pull
  request. Review it, but do not hand-edit its generated version, URL, or
  checksum or amend the already published release tag.
- `SOURCE_CANDIDATE.manifest`, `SOURCE_CANDIDATE.sha256`, and
  `SOURCE_CANDIDATE.receipt` are release evidence, not ordinary generated-file
  clutter. Do not hand-edit or casually regenerate them. A release owner must
  supersede the candidate after any source or documentation change.

## Homebrew packaging changes

Codex Cove uses its own public repository as an explicit custom tap. Keep the
documented two-step install stable:

```sh
brew tap cdimartino/codex-cove https://github.com/cdimartino/codex-cove.git
brew install --cask cdimartino/codex-cove/codex-cove
```

The Cask is a binary distribution definition, not a source build. It must:

- name the immutable `vMAJOR.MINOR.PATCH` GitHub release and matching
  `Codex-Cove-<version>-macos-arm64.zip`;
- use the exact app ZIP SHA-256 from the release's aggregate `SHA256SUMS`, never
  `sha256 :no_check` or `version :latest`;
- install the app at `~/Applications/Codex Cove.app`, which is the path enforced
  by Doctor and the current-user installation contract;
- invoke only bundle-local code in postflight: the app's maintenance entry
  point restores the persisted Launch at Login preference before the embedded
  helper transaction applies integration, without `sudo`, PATH-file edits, hook
  self-trust, TCC changes, or quarantine removal;
- let Homebrew quit and own removal of the app while the helper removes only
  Cove integration with `uninstall --keep-app --keep-settings`; and
- preserve Homebrew's upgrade rollback: old integration cleanup, app
  replacement, new postflight setup, and restoration of the prior version if a
  later phase fails.

Before release publication, run Ruby syntax, fail-clean lifecycle, `brew style`,
and strict offline Cask audit checks against the rendered file, plus isolated
helper coverage for `--keep-app --keep-settings`. After the immutable release
exists, the Cask follow-up must run the online audit (`brew audit --new` for the
first Cask), then use a clean current-user environment for fresh install,
signature/notarization checks, Doctor, an upgrade or reinstall, and
`brew uninstall --cask`. Those post-publication checks gate the Cask PR rather
than rewriting source-candidate evidence or the published tag.

## Protocol changes

The current Cove IPC schema version is `1`. Backward-compatible readers must
tolerate unknown object fields. Do not reuse a field with different semantics.

When changing a schema or event contract:

1. update the canonical file under `schemas/`;
2. update the checked-in extension schema under `extension/schemas/`;
3. update both readable and test fixtures where the contract example changes;
4. update Swift, Rust, and TypeScript models together;
5. add cross-language success and rejection cases; and
6. update [PROTOCOL.md](PROTOCOL.md) and [Architecture](ARCHITECTURE.md).

Frame limits, timeouts, socket permissions, origin scoping, and unknown-field
behavior are part of the protocol contract and require tests when changed.

## Privacy and security checklist

Every change that touches task events, persistence, logs, notifications,
installation, exact focus, or remote transport should answer these questions:

- Does any prompt, response, command, diff, plan, request detail, token value,
  absolute socket path, or filesystem path become durable?
- Can two sources or remote hosts with the same external ID collide?
- Does an ambiguous or stale route fail closed?
- Does native Codex remain usable if Cove, its socket, or app-server is absent?
- Are file and socket type, owner, mode, size, and identity validated before use?
- Are reads, writes, handshakes, child processes, and retries bounded?
- Can install or uninstall touch an artifact not proved to be Cove-owned?
- Does a package-manager path preserve the boundary between Cove-owned
  integration and the app artifact owned by that package manager?
- Are diagnostics appropriately redacted, and do test receipts remain
  content-free and safe to share?

Add a regression test for the boundary, not only the success path. Security
changes should include malformed, stale, ambiguous, oversized, partial-I/O, and
timeout cases where applicable.

## UI and accessibility expectations

- Use semantic labels and stable accessibility identifiers for interactive
  controls and meaningful status.
- Preserve keyboard navigation and the focused-surface `Escape` path.
- Verify 100% and 200% text scale, Reduce Motion, Increase Contrast, and Reduce
  Transparency for affected surfaces.
- Never encode task status by color or animation alone.
- New events must not force the island open.
- Approval scope and final confirmation must remain distinct actions.
- Changes to panel geometry should be tested on notched and non-notched display
  layouts, multiple displays, Spaces, fullscreen, and Stage Manager before a
  release.

The deterministic XCUITest fixtures exercise UI state without reading or
writing the user's real Cove/Codex data. Do not weaken fixture isolation to make
a test convenient.

## Pull requests

Keep changes focused and explain:

- the user-visible outcome;
- the trust or privacy boundary affected;
- automated tests run and their result;
- manual macOS/editor surfaces exercised; and
- any gate that could not be run locally.

Do not include private task text, prompts, responses, command history, absolute
home paths, SSH aliases, usernames, or opaque task/session/launch/control IDs in
commits, fixtures, screenshots, logs, or pull-request descriptions.

Maintainers should require a clean CI run and proportionate manual evidence
before merge. A green unit test suite alone is not sufficient for changes to
Accessibility, Automation, exact-origin focus, code signing, install/rollback,
Homebrew lifecycle behavior, or remote SSH behavior.

## Release work

Do not create a version tag from a feature pull request. Version alignment,
candidate identity, owner/manual gates, signing, checksums, and GitHub release
publication are coordinated through [Release Process](RELEASES.md).

The Homebrew Cask is the one intentional post-publication handoff: render and
publish it inside the verified release, then land that exact file through a
separate protected pull request. A valid GitHub release remains available for
manual installation if the Cask handoff fails.
