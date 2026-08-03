# Release Process

Codex Cove releases are built from an existing, reviewed Git tag on `main`.
The release workflow never invents or moves a tag. It validates complete
candidate evidence, produces a Developer ID signed and notarized Apple Silicon
app, and publishes checksummed companion assets.

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
- published checksums covering every downloadable artifact.

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

Create a GitHub environment named `release` with required reviewers and limit
deployment to the protected release branch/tag policy. Prefer environment
secrets so review protects access to distribution credentials; repository
secrets are also technically supported by the workflow when repository
governance requires them. Never store credentials in plaintext files or
workflow inputs.

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

The automatic GitHub token remains read-only during build jobs. Only the final
publisher job receives the minimal `contents: write` permission needed to
create the release and upload assets.

## 7. Run the release workflow

In GitHub Actions, open **Release**, choose **Run workflow** on the protected
default branch, and enter the existing tag. The same operation with GitHub CLI
is:

```sh
gh workflow run release.yml --ref main \
  -f tag=v0.3.0
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
that comparison succeeds. It refuses to replace an existing GitHub release and
never creates, moves, or pushes the input tag. Public repositories also receive
GitHub artifact attestations; private repositories skip that optional
public-verification step.

If draft download or verification fails, the workflow deliberately leaves the
unpublished draft for inspection and a rerun refuses to overwrite it. Review
the failure, remove only that draft through the GitHub Releases UI, and rerun
the same immutable tag; never delete or move the tag to recover the workflow.

The protected `release` environment approval should occur only after the owner
has checked the tag, CI result, completed receipt, signing identity, and release
notes.

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

Install on a clean Apple Silicon test account, run Doctor, exercise one
non-sensitive routed session, verify exact-origin behavior, and perform a safe
`--keep-settings` uninstall/reinstall smoke before announcing broadly.

The first transition from an ad-hoc/local identity to the Developer ID release
may appear to macOS as a different trusted client despite the unchanged bundle
ID. If global shortcuts or exact focus fail, remove the old Codex Cove entries
from Accessibility and Automation, add/enable the installed release again, and
relaunch it. This is a user-supervised permission renewal, not an installer
mutation.

## 10. Publish notes and close the release

Release notes should state:

- supported macOS and architecture;
- Developer ID and notarization status;
- user-visible changes and fixed defects;
- privacy, permission, persistence, protocol, and installer changes;
- known limitations and any intentionally not-required matrix row;
- upgrade and rollback instructions; and
- the source tag and candidate digest.

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
4. run Doctor and verify hooks, links, editor extension, settings, metadata,
   remote checksums, and exact permissions after rollback; and
5. fix forward with a new patch version, full candidate freeze, gates, tag, and
   release workflow run.

Never solve a release rollback with `git reset --hard`, a moved tag, blanket
file deletion, hook replacement, TCC database edits, or unverified remote
cleanup.
