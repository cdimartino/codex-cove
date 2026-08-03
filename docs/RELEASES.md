# Release Process

Codex Cove releases are built from an existing, reviewed Git tag on `main`.
The release workflow never invents or moves a tag. It validates complete
candidate evidence, produces a Developer ID signed and notarized Apple Silicon
app, and publishes checksummed companion assets, including a Homebrew Cask
rendered from the final app archive.

This document describes distribution releases. `make package` and
`make install` remain local-development workflows and fall back to ad-hoc
signing when no configured identity is available. An ad-hoc package must never
be presented as a notarized GitHub release.

## Release invariants

A release is valid only when all of these refer to the same source commit:

- a `vMAJOR.MINOR.PATCH` tag reachable from `main`;
- synchronized app, helper, extension, generated-project, lockfile, and Swift
  protocol-client versions;
- a deterministic source-candidate manifest and digest;
- a complete privacy-safe receipt bound to that digest;
- passing CI and all release/manual gates required by the receipt;
- a Developer ID Application signature and valid notarization ticket; and
- published checksums covering every downloadable artifact; and
- a rendered Homebrew Cask whose version, URL, and SHA-256 name that exact
  published app archive.

The bundle identifier is `local.chris.codexcove`. Changing it breaks continuity
for login items, deep links, macOS privacy grants, install manifests, and app
identity checks. Keep it unchanged unless the owner explicitly approves a
coordinated migration and its rollback plan.

## 1. Prepare the version

Use a numeric semantic version. Update every product version source:

- `Packaging/Info.plist` (`CFBundleShortVersionString` and the positive integer
  `CFBundleVersion`);
- `helper/Cargo.toml` and the root package entry in `helper/Cargo.lock`;
- `extension/package.json` and both root package versions in
  `extension/package-lock.json`;
- `XcodeProject.yml` (`MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`) and the
  regenerated `CodexCoveUITests.xcodeproj`;
- the fallback client-version strings in `AppDelegate.swift`,
  `CoveAccountUsageHydration.swift`, and `CoveDesktopThreadHydration.swift`; and
- version-specific release records and receipt fields.

Regenerate the UI-test project after updating `XcodeProject.yml`:

```sh
xcodegen generate --spec XcodeProject.yml --project .
```

Verify the complete alignment:

```sh
./scripts/verify-release-version.sh v0.3.0
```

Do not update unrelated dependency versions during the release-only change.

## 2. Finish source and freeze the candidate

All code, tests, workflows, README, and documentation are candidate inputs.
Finish and review them before writing release evidence.

For a first candidate:

```sh
make candidate-write
make candidate-verify
```

Create the root `SOURCE_CANDIDATE.receipt` with the required header and exact
digest binding, then record only the content-free fields defined by the current
owner-pass runbook. The receipt must not contain prompts, responses, commands,
diffs, task/session/launch/control/Desktop identifiers, SSH aliases, usernames,
absolute paths, or user preference contents.

The exact allowed key set is
[`schemas/release-receipt-v1.keys`](../schemas/release-receipt-v1.keys). The
release-readiness verifier rejects unknown/free-form fields and independently
checks candidate hashes, counts, timing grammar, authorization placement,
carried-defect lineage, and release-gate consistency.

If a candidate fails and source changes, do not overwrite its history. Follow
the **New-candidate rollover after a failed receipt** procedure in the current
`OWNER_PASS_*.md`: preserve the old manifest, digest, and corrected receipt in
a new private directory outside the repository; move the root receipt; write a
new candidate; create a newly bound receipt carrying failures forward; and
retest every invalidated gate.

After `candidate-write`, any source or documentation edit supersedes that
candidate. Never “repair” a digest by hand.

## 3. Run local release gates

At minimum, run:

```sh
make candidate-verify
make deps
make bootstrap
make build
make test
make ui-test
cargo fmt --manifest-path helper/Cargo.toml --all -- --check
cargo clippy --locked --manifest-path helper/Cargo.toml \
  --all-targets --all-features -- -D warnings
make package-with-remote
codesign --verify --deep --strict --verbose=2 "build/Codex Cove.app"
```

Also complete:

- shell syntax checks for every script;
- both Linux-musl all-target cross-build checks;
- remote-helper version, architecture, and checksum verification;
- installed-app, Doctor, and non-prompting app-server smoke checks;
- the full XCUITest suite on an unlocked macOS console;
- the version's manual Accessibility, display, Spaces, fullscreen, Stage
  Manager, sleep/wake, editor-window, Desktop, and selected-SSH-host matrices;
- the owner first-attempt decision and exact-origin pass;
- the uninstall/reinstall rollback drill; and
- final zero-open-P0/P1 signoff with baseline restoration.

When Homebrew packaging changes, also render the Cask from the final local app
archive and run its Ruby syntax, fail-clean lifecycle, Homebrew style, and
strict offline audit checks. Exercise the helper's package-manager-safe
`--keep-app --keep-settings` path in an isolated fixture. Record these
prepublication observations under the existing component, packaging, and
rollback gates in the candidate receipt; a Cask that merely parses is not
release evidence.

The strict online/new-Cask audit and a real Homebrew install, Doctor,
upgrade-or-reinstall, and uninstall cannot run until the immutable release URL
exists and the Cask has been staged in a tap. They are a required
post-publication, pre-Cask-merge handoff in section 10, not a circular input to
the source candidate or GitHub release receipt.

Record direct observations in the candidate receipt only. A blocked or not-run
row is not a pass and cannot be waived by CI.

When all fields are complete, enforce the machine-readable release contract:

```sh
VERSION=0.3.0 make verify-release-readiness
# After that non-strict run passes, record receipt_strict_release_verify=pass.
CODEX_COVE_REQUIRE_RECORDED_STRICT_VERIFY=1 \
  VERSION=0.3.0 \
  make verify-release-readiness
make candidate-verify
```

The first invocation validates every other receipt field without trusting the
strict-verification stamp. Record `receipt_strict_release_verify=pass` only
after it succeeds, then run the strict invocation to verify the stamp and the
unchanged candidate together.

Commit the versioned source and completed evidence together. Do not amend that
commit after tagging.

## 4. CI and branch protection

`.github/workflows/ci.yml` has two required jobs on pushes to `main`, pull
requests, and manual dispatches:

- **Build, test, and package** runs the build, unit/foundation suites, Rust
  static checks, shell syntax checks, release compilation, extension packaging,
  UI-test compilation, and an ad-hoc packaging smoke test.
- **Cross-build remote helpers** builds all four supported remote targets and
  verifies their architecture, version, and checksum manifest.

Both jobs have read-only repository permissions and pin third-party actions by
commit.

Protect `main` in GitHub with:

- pull requests required before merge;
- both CI jobs required and up to date;
- conversations resolved;
- force pushes and branch deletion disabled; and
- direct bypass limited to an explicit emergency owner path.

The release owner should confirm the exact release commit has a green CI run
before tagging. CI packaging proves that an app can be assembled; it does not
claim Developer ID signing, notarization, manual macOS behavior, or release
readiness.

## 5. Create and push the tag

Update local `main`, confirm a clean tree, and identify the reviewed release
commit. Prefer a signed annotated tag when maintainer signing is configured:

```sh
git switch main
git pull --ff-only
git status --short
git tag -s v0.3.0 -m "Codex Cove 0.3.0"
git push origin v0.3.0
```

If tag signing is not configured, use an annotated tag and document that fact
in the release notes. Never retag a published version. Correct a release with a
new patch version.

Pushing the tag does not publish binaries. The release workflow is
`workflow_dispatch` only so a protected, deliberate action remains between the
tag and distribution.

## 6. Configure the protected release environment

Create a GitHub environment named `release`, limit deployment to protected
branches, and add required reviewers when the repository billing plan supports
that protection rule. Some private-repository plans reject environment
reviewers; in that case, record the limitation, retain the protected-branch
restriction, and rely on the workflow's exact `RELEASE <tag>` confirmation as
the deliberate approval boundary. Prefer environment secrets so supported
review rules protect access to distribution credentials; repository secrets
are also technically supported by the workflow when repository governance
requires them. Never store credentials in plaintext files or workflow inputs.

Create an active tag ruleset for `refs/tags/v*` that restricts both updates and
deletions, with no routine bypass actor. Release tags are immutable inputs: if a
tag is wrong, cut a new version instead of moving or deleting the old tag. The
workflow independently resolves the exact tag target through GitHub's API at
preflight, at each job boundary, after draft creation, immediately before
publication, and after publication. These checks complement the ruleset and
fail closed if the tag ever stops naming the reviewed commit.

The workflow requires all of the following secrets:

| Secret | Purpose |
| --- | --- |
| `MACOS_CERTIFICATE_P12` | Base64-encoded Developer ID Application certificate and private key |
| `MACOS_CERTIFICATE_PASSWORD` | Password for the imported PKCS#12 file |
| `MACOS_SIGNING_IDENTITY` | Exact `Developer ID Application: …` identity name |
| `APPLE_NOTARY_APPLE_ID` | Apple account used by `notarytool` |
| `APPLE_NOTARY_PASSWORD` | App-specific password for notarization |
| `APPLE_NOTARY_TEAM_ID` | Apple Developer team identifier |

Use a narrowly scoped App Store Connect API key instead if the workflow is
intentionally migrated to key-based `notarytool` authentication; change the
workflow and this table together. Missing or partial credentials must fail the
distribution workflow. It sets `CODEX_COVE_DISTRIBUTION_BUILD=1`, so the
packager itself also refuses ad-hoc signing; there is no “skip notarization”
release mode.

The automatic GitHub token remains read-only during build jobs. The publisher
job receives `contents: write` only to create the release and upload assets;
the later Homebrew staging job receives `contents: write` only to push the
generated Cask update branch. Neither job can bypass protected `main`.

## 7. Run the release workflow

In GitHub Actions, open **Release**, choose **Run workflow** on the protected
default branch, and enter the existing tag. The same operation with GitHub CLI
is:

```sh
gh workflow run release.yml --ref main \
  -f tag=v0.3.0 \
  -f confirm='RELEASE v0.3.0'
```

The secret-free **Verify release candidate** job first verifies that:

- the input is a valid `vMAJOR.MINOR.PATCH` tag;
- the tag already exists, resolves to the checked-out commit, and is contained
  in `main`;
- version metadata matches the tag;
- the candidate manifest, digest, receipt binding, and readiness fields pass;
- all tests and static checks succeed; and
- all four remote helpers can be cross-built with their declared targets and
  checksums.

Only after that secret-free preflight does the protected-environment **Sign,
notarize, and assemble** job access credentials. It verifies that:

- the app and embedded helper are arm64;
- the app and macOS helpers have the expected Developer ID identity;
- Apple notarization succeeds, the ticket is stapled, and Gatekeeper accepts
  the app; and
- the final aggregate checksum file matches the exact publish set.

The protected **Publish GitHub release** job creates a draft, downloads and
byte-verifies every handoff asset plus `SHA256SUMS`, and publishes only after
that comparison succeeds. It never replaces an existing asset. For recovery it
accepts an existing release only when GitHub reports it as published,
non-prerelease, and immutable and its complete asset set is byte-identical to
the newly assembled handoff. It never creates, moves, or pushes the input tag.
Public repositories
also receive GitHub artifact attestations; private repositories skip that
optional public-verification step.

The canonical asset assembler computes the final
`Codex-Cove-<version>-macos-arm64.zip` SHA-256 before rendering
`codex-cove.rb`. The rendered Cask must use a numeric version and that exact
checksum; `version :latest`, `sha256 :no_check`, a mutable download URL, or a
checksum copied from a different build is a release failure. The Cask joins the
same verified handoff and aggregate checksum set as every other public asset.

If draft download or verification fails, the workflow deliberately leaves the
unpublished draft for inspection and a rerun refuses to overwrite it. Review
the failure, remove only that draft through the GitHub Releases UI, and rerun
the same immutable tag; never delete or move the tag to recover the workflow.

When reviewer protection is available, approve the protected `release`
environment only after checking the tag, CI result, completed receipt, signing
identity, release notes, and **Settings > General > Releases > Immutable
releases**. The normal workflow token cannot read that administration-only
repository setting before publication. The publisher therefore checks the
release's `isImmutable` result immediately after publication; this detects
drift and stops the Homebrew handoff, but it is not pre-publication prevention.
GitHub does not apply a newly enabled immutable-release setting retroactively.
If that assertion fails, stop the handoff, treat the publication as a release
incident, restore the repository setting for future releases, and cut a new
patch release rather than replacing or relabeling the mutable release's assets.
Otherwise, perform the manual checks before entering the workflow's exact
`RELEASE <tag>` confirmation.

## 8. Published artifacts

After signing, notarization, stapling, and Gatekeeper validation, the workflow
uses `VERSION=0.3.0 make release-assets` as the sole canonical asset assembler.
That target refuses an ad-hoc, unstapled, non-arm64, or incomplete package.

For version `0.3.0`, the workflow publishes:

| Asset | Contents |
| --- | --- |
| `Codex-Cove-0.3.0-macos-arm64.zip` | Developer ID signed, notarized, stapled Apple Silicon app with embedded helper, extension, schemas, and remote helpers |
| `Codex-Cove-0.3.0.vsix` | Bundled private VS Code/Cursor extension |
| `Codex-Cove-0.3.0-remote-helpers.tar.gz` | Checksummed helpers for arm64/x86_64 macOS and arm64/x86_64 Linux musl |
| `Codex-Cove-0.3.0-source-candidate.manifest` | Deterministic candidate file manifest |
| `Codex-Cove-0.3.0-source-candidate.sha256` | Candidate-manifest digest |
| `Codex-Cove-0.3.0-release.receipt` | Privacy-safe completed release evidence |
| `codex-cove.rb` | Homebrew Cask rendered from the final app ZIP version and SHA-256 |
| `SHA256SUMS` | SHA-256 for every other published asset |

No `.p12`, private key, temporary keychain, notarization password, raw workflow
handoff, absolute build path, or unredacted test log belongs in the release.

## 9. Verify the published release

Download every asset into a clean directory and verify the aggregate manifest:

```sh
shasum -a 256 -c SHA256SUMS
```

Expand the app archive without modifying it, then verify identity, architecture,
notarization, and Gatekeeper:

```sh
codesign --verify --deep --strict --verbose=2 "Codex Cove.app"
codesign -dv --verbose=4 "Codex Cove.app"
lipo -archs "Codex Cove.app/Contents/MacOS/CodexCove"
xcrun stapler validate "Codex Cove.app"
spctl --assess --type execute --verbose=4 "Codex Cove.app"
```

Confirm the displayed authority is the intended Developer ID Application team
and the only app architecture is `arm64`. Verify the candidate files again from
the tagged checkout and compare the published receipt to the reviewed one.

Inspect the published `codex-cove.rb` before landing it in the tap. Its `url`
must name the immutable release tag and
`Codex-Cove-<version>-macos-arm64.zip`; its `sha256` must equal the app archive's
line in `SHA256SUMS`; and its app target must remain
`~/Applications/Codex Cove.app`. Run Homebrew style and strict Cask audit checks
against the exact downloaded file, not a separately reconstructed copy.

Install on a clean Apple Silicon test account, run Doctor, exercise one
non-sensitive routed session, verify exact-origin behavior, and perform a safe
`--keep-settings` uninstall/reinstall smoke before announcing broadly.

The first transition from an ad-hoc/local identity to the Developer ID release
may appear to macOS as a different trusted client despite the unchanged bundle
ID. If global shortcuts or exact focus fail, remove the old Codex Cove entries
from Accessibility and Automation, add/enable the installed release again, and
relaunch it. This is a user-supervised permission renewal, not an installer
mutation.

## 10. Land the Homebrew Cask

The repository is also the explicit custom tap used by the documented install:

```sh
brew tap cdimartino/codex-cove https://github.com/cdimartino/codex-cove.git
brew install --cask cdimartino/codex-cove/codex-cove
```

Those commands become live for a version only after the public GitHub release
exists and its exact rendered `codex-cove.rb` has landed at
`Casks/codex-cove.rb` on the default branch. Do not publish a Cask that points
at a draft, private, missing, or replaceable artifact.

After immutable release publication:

1. download `codex-cove.rb`, `SHA256SUMS`, and the app ZIP from that release;
2. verify the aggregate manifest and independently verify that the Cask's
   version, URL, and SHA-256 match the ZIP, and require GitHub to report the
   published release as immutable;
3. let the release workflow copy the verified Cask byte-for-byte to
   `Casks/codex-cove.rb` on its `automation/homebrew-vMAJOR.MINOR.PATCH` branch,
   then use the emitted compare URL to open a normal pull request; do not
   hand-edit the generated version or checksum;
4. run `brew style`, `brew audit --new` for the first Cask (strict online audit
   thereafter), and a real fresh install/Doctor check;
5. exercise an upgrade from the prior Cask when one exists, then verify
   `brew uninstall --cask` removes integration and the app while retaining
   settings; and
6. merge the Cask pull request through normal protected-branch CI.

The Cask's uninstall contract must let Homebrew retain ownership of app removal:
Homebrew quits Cove, invokes the embedded helper with
`uninstall --keep-app --keep-settings`, then removes the verified app artifact.
Its postflight first invokes the app's bounded maintenance entry point to
restore the persisted Launch at Login preference, then invokes the embedded
helper transaction to apply current-user integration. A failure compensates by
unregistering Launch at Login before Homebrew rolls the app artifact back. Do
not replace this with broad file deletion, a privileged installer, or an
uninstall that removes the app before Homebrew reaches its app artifact.

If Cask publication fails, keep the GitHub release and manual verified-download
instructions available, fix the Cask through a new pull request, and rerun its
tests. Never move the release tag or replace published binaries to make a Cask
checksum pass. If the binary itself is wrong, cut a new patch release.

If only **Stage Homebrew cask update** fails after the release is public because
of a transient service failure or corrected external state, use GitHub Actions'
**Re-run failed jobs** operation on that same workflow run while its
`release-assets` artifact is still retained (14 days). GitHub reruns the
original workflow revision, so do not expect a rerun to repair a deterministic
workflow bug or a mismatched pre-existing automation branch. In either of
those cases—or after artifact expiry—download and verify the immutable public
assets immediately, prepare the byte-identical Cask update in a normal pull
request, and record that manual recovery in the release evidence. Never replace
published binaries to make the Cask pass.

## 11. Publish notes and close the release

Release notes should state:

- supported macOS and architecture;
- Developer ID and notarization status;
- user-visible changes and fixed defects;
- privacy, permission, persistence, protocol, and installer changes;
- known limitations and any intentionally not-required matrix row;
- upgrade and rollback instructions;
- the source tag and candidate digest; and
- whether the matching Homebrew Cask has landed and the tap install is live.

The automated distribution path has no prerelease or incomplete-gate mode. If
compatibility or owner gates are blocked, do not run it. Resolve the gate and
freeze a new candidate rather than publishing a blocked row as supported.

After publication, monitor the workflow and first-install feedback. Preserve
the tag and GitHub release. Remove or deprecate a bad binary asset rather than
moving the tag; publish a corrected patch version with a new candidate and
receipt.

## Rollback

The local installer retains the previous app as a timestamped backup and
restores it if integration installation fails. For a distribution regression:

1. stop promoting the affected GitHub release and document the impact;
2. keep the tag and evidence immutable;
3. advise affected users to quit Cove and use the last verified package or the
   installer-retained backup;
4. remove or disable promotion of the affected Cask without changing the
   immutable release tag, and point Homebrew users to the last verified version;
5. run Doctor and verify hooks, links, editor extension, settings, metadata,
   remote checksums, and exact permissions after rollback; and
6. fix forward with a new patch version, full candidate freeze, gates, tag, and
   release workflow run.

Never solve a release rollback with `git reset --hard`, a moved tag, blanket
file deletion, hook replacement, TCC database edits, or unverified remote
cleanup.
