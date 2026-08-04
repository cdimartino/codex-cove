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

- a `vMAJOR.MINOR.PATCH` tag naming the exact protected `main` commit used to
  dispatch the workflow;
- reviewed candidate-bound notes at `docs/releases/vMAJOR.MINOR.PATCH.md`;
- synchronized app, helper, extension, generated-project, lockfile, and Swift
  protocol-client versions;
- a deterministic source-candidate manifest and digest;
- a complete privacy-safe receipt bound to that digest;
- passing CI and every mandatory functional gate required by the receipt;
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
- version-specific release records and receipt fields;
- `docs/releases/vMAJOR.MINOR.PATCH.md`, whose first heading, embedded tag
  binding, visible `Source tag` line, required sections, and single
  `{{SOURCE_CANDIDATE_DIGEST}}` token are checked by the secret-free release
  preflight.

Regenerate the UI-test project after updating `XcodeProject.yml`:

```sh
xcodegen generate --spec XcodeProject.yml --project .
```

Verify the complete alignment:

```sh
./scripts/verify-release-version.sh v0.3.0
```

Write the release notes as user-facing descriptions of the candidate's actual
contents. Before the release exists, use forward-looking language for signing,
notarization, publication, and Homebrew availability; never claim an unrun gate
or unpublished artifact has passed. Do not update unrelated dependency
versions during the release-only change.

The notes template must contain exactly one
`{{SOURCE_CANDIDATE_DIGEST}}` token where the published source-candidate digest
belongs. Do not paste the digest into its own candidate input: that would create
a self-reference because the manifest hashes the template. The deterministic
renderer resolves the token only after the candidate has been frozen. Verify
the complete current tree first so a stale manifest cannot be mistaken for the
source under review:

```sh
make candidate-verify
./scripts/render-release-notes.sh v0.3.0
```

The renderer validates the manifest header, proves the digest hashes that
manifest, proves the release-notes template has the exact mode and checksum
recorded in the manifest, validates the tag marker and visible source tag,
requires one token, and writes the rendered notes to standard output without
changing the candidate template. The full `candidate-verify` remains necessary
because it checks every source input, not only the release-notes record.

## 2. Finish source and freeze the candidate

All code, tests, workflows, README, documentation, and versioned release notes
are candidate inputs. Finish and review them before writing release evidence.

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

`make deps` is the canonical dependency gate: the extension's locked clean
install is followed by `npm audit --audit-level=info`, and any advisory blocks
the release. `make package-with-remote` reaches the canonical remote builder,
which runs `cargo zigbuild --all-targets` for both Linux-musl architectures
before it copies and checksums their release executables.

The protected release workflow pins Node.js `22.23.2`, Rust `1.97.1`,
`cargo-zigbuild` `0.23.0`, Zig `0.16.0`, and Xcode `26.6`. A Homebrew install of
Zig is only a provisioning fallback on the hosted runner; the workflow reads
`zig version` afterward and fails unless it is exactly `0.16.0`. Do not replace
these checks with an unverified direct binary download. Update the workflow,
candidate notes when relevant, and this toolchain statement together after a
reviewed upgrade.

The following additional automated and artifact checks are mandatory:

- shell syntax checks for every script;
- both Linux-musl all-target cross-build checks;
- remote-helper version, architecture, and checksum verification;
- installed-app, Doctor, and non-prompting app-server smoke checks;
- the full XCUITest suite on an unlocked macOS console; and
- final zero-open-P0/P1 signoff backed by current regression evidence.

The following manual matrices are recommended release-quality follow-up, but
they are not distribution blockers when those mandatory gates are green and
the owner elects to ship. Record them honestly as `not-run` or `blocked`; never
convert an unobserved row into a pass:

- the version's manual Accessibility, display, Spaces, fullscreen, Stage
  Manager, sleep/wake, editor-window, Desktop, and selected-SSH-host matrices;
- the owner first-attempt decision and exact-origin pass;
- the uninstall/reinstall rollback drill; and
- baseline-restoration observations.

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
manual row is not a pass, but it does not block the streamlined functional
release profile. Automated, signing, notarization, and artifact-integrity gates
remain mandatory.

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
commit. The tag must name the exact `main` head used for the later workflow
dispatch; if `main` advances after tagging, dispatching that older tag is
rejected and the release owner must decide whether to prepare a new candidate
on the newer head. Prefer a signed annotated tag when maintainer signing is
configured:

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

### Release credential lifecycle

The named release credential owner is `cdimartino`, acting as the repository
owner and Apple Developer release owner. That owner reviews the Developer ID
certificate expiration, notary authentication, release-environment policy, and
the six expected GitHub secret names before every release and at least once per
month while releases are active.

Rotate the Developer ID Application certificate and encrypted PKCS#12 export at
least 30 days before the certificate's `Not After` date. Apple app-specific
passwords do not present a dependable certificate-style expiry date, so use an
annual internal rotation deadline and rotate sooner after an Apple Account
password reset, team or role change, authentication failure, suspected
disclosure, or unexpected notarization activity. After any planned rotation,
update the `release` environment secrets and verify only each secret's name and
GitHub `updated_at` timestamp; never print, echo, compare, or capture the secret
value in logs.

For an emergency, stop release dispatches, revoke the affected app-specific
password in the Apple Account portal, and revoke the affected Developer ID
certificate in the Apple Developer portal when its private key may be
compromised. Create replacements through the owner-controlled Apple account,
export the replacement certificate and private key as a password-protected
PKCS#12, update all dependent GitHub environment secrets as one set, verify
their names and timestamps without values, and resume only after the protected
workflow validates the new identity and notarization credentials. Never leave
an app-specific password, PKCS#12 password, private key, decoded certificate
archive, or temporary keychain in a plaintext local file. Keep the encrypted
recovery material only in the approved password manager and let the workflow
delete its ephemeral PKCS#12 and keychain after use.

The current workflow intentionally uses the Apple ID plus app-specific-password
form of `notarytool` authentication. A future credential hardening change should
prefer a narrowly scoped App Store Connect API key, store its issuer, key ID,
and private key as protected environment secrets, and update the workflow,
documentation, owner rotation runbook, and candidate evidence together.

The automatic GitHub token remains read-only during build jobs. The publisher
job receives `contents: write` only to create the release and upload assets;
the Homebrew verifier and third-party audit remain read-only with no persisted
checkout credential; and only the later minimal staging job receives
`contents: write` to reverify and push the generated Cask update branch. None
of these jobs can bypass protected `main`.

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
- the tag already exists and resolves to the exact protected `main` commit from
  which the workflow was dispatched;
- `docs/releases/<tag>.md` is a real candidate-bound file with the exact
  version heading and tag marker, all required user-facing sections, exactly
  one source-candidate digest token, no other unresolved placeholder, and
  substantive content; the deterministic rendering must contain the frozen
  digest and no remaining token;
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

The protected **Publish GitHub release** job deterministically renders the
candidate-bound template with the frozen source-candidate digest, creates a
draft using that rendered file as `--notes-file`, downloads and byte-verifies
every handoff asset plus `SHA256SUMS`, and compares GitHub's stored release body
with the same rendering. It publishes only after those comparisons succeed and
never replaces an existing asset. For recovery it accepts an existing release
only when GitHub reports it as published, non-prerelease, and immutable, its
release body equals a fresh rendering from the tagged template and digest, and
its complete asset set is byte-identical to the newly assembled handoff. It
never creates, moves, or pushes the input tag.
Public repositories
also receive GitHub artifact attestations; private repositories skip that
optional public-verification step.

After publication, **Verify and audit released Homebrew cask** runs with
`contents: read` and a checkout that does not persist credentials. It
re-downloads the immutable release, verifies its aggregate checksums and exact
Cask bytes, and runs Homebrew style plus the new-Cask or strict-online audit in
a disposable local tap. Only its validated Cask artifact crosses into the
dependent **Stage verified Homebrew cask update** job. That minimal
`contents: write` job re-resolves the tag, release state, candidate notes,
checksums, and exact Cask bytes before it creates or reuses the staging branch;
it does not execute Homebrew evaluation while push credentials are present.

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
environment only after checking the exact tag and commit, CI result, completed
receipt, signing identity, and the full candidate-bound
`docs/releases/<tag>.md` template plus its deterministic rendering containing
the exact candidate digest that will become the GitHub release body. Also
confirm **Settings > General > Releases > Immutable releases**. Approval must
not precede review of the rendered release notes, and post-approval generated
notes are not allowed. The normal workflow token cannot read that
administration-only
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

The GitHub release body is the deterministic rendering of the candidate-bound
`docs/releases/v0.3.0.md` template and the tagged commit's
`SOURCE_CANDIDATE.sha256`. It includes the exact candidate digest, retains the
exact tag marker, and is not reconstructed by GitHub's generated-notes service.

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
3. let the read-only Homebrew job run `brew style` and `brew audit --new` for
   the first Cask (strict online audit thereafter) against the exact released
   file in a disposable tap;
4. let the dependent minimal write job reverify that validated artifact and
   copy it byte-for-byte to `Casks/codex-cove.rb` on its
   `automation/homebrew-vMAJOR.MINOR.PATCH` branch, then use the emitted compare
   URL to open a normal pull request; do not hand-edit the generated version or
   checksum, and complete a real fresh install/Doctor check;
5. exercise an upgrade from the prior Cask when one exists, then verify
   `brew uninstall --cask` removes integration and the app while retaining
   settings; and
6. merge the Cask pull request through normal protected-branch CI.

### Validate the staged Cask before merging

The public tap commands above cannot validate a Cask that exists only on the
workflow's staging branch. Before merging that branch, run the following from
the tagged checkout on a clean Apple Silicon test account. Substitute the exact
40-character head SHA reported by the Cask pull request; do not use a branch
name as the expected identity.

```sh
set -eu

cove_tag='<exact vMAJOR.MINOR.PATCH release tag>'
printf '%s\n' "$cove_tag" |
  grep -Eq '^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
cove_version=${cove_tag#v}
cove_branch="automation/homebrew-$cove_tag"
cove_expected_head='<exact 40-character Cask PR head>'
cove_validation_root=$(mktemp -d "${TMPDIR:-/tmp}/codex-cove-homebrew.XXXXXX")
cove_staged_checkout="$cove_validation_root/staged"
cove_release_assets="$cove_validation_root/release"
cove_tap_suffix=$(printf '%s' "$cove_version" | tr '.' '-')
cove_tap="codexcovevalidation/codex-cove-$cove_tap_suffix"
cove_cask="$cove_tap/codex-cove"
cove_app="$HOME/Applications/Codex Cove.app"
cove_support="$HOME/Library/Application Support/Codex Cove"
cove_settings="$cove_support/settings.json"
cove_socket="$cove_support/run/events.sock"

test -z "$(git status --porcelain=v1 --untracked-files=all)"
cove_release_head=$(./scripts/resolve-github-tag.sh \
  cdimartino/codex-cove "$cove_tag")
test "$(git rev-parse HEAD)" = "$cove_release_head"
test "$(git rev-parse "$cove_tag^{commit}")" = "$cove_release_head"
test "${#cove_expected_head}" -eq 40
case "$cove_expected_head" in
  *[!0-9a-f]*) exit 1 ;;
esac
test "$(uname -m)" = arm64
test "$(gh repo view cdimartino/codex-cove --json visibility --jq .visibility)" = PUBLIC
cove_default_branch=$(gh repo view cdimartino/codex-cove \
  --json defaultBranchRef --jq .defaultBranchRef.name)
cove_default_head=$(gh api \
  "repos/cdimartino/codex-cove/commits/$cove_default_branch" --jq .sha)
test "${#cove_default_head}" -eq 40
case "$cove_default_head" in
  *[!0-9a-f]*) exit 1 ;;
esac
cove_prior_cask_count=$(gh api \
  "repos/cdimartino/codex-cove/git/trees/$cove_default_head?recursive=1" \
  --jq '[.tree[] | select(.path == "Casks/codex-cove.rb" and .type == "blob")] | length')
case "$cove_prior_cask_count" in
  0 | 1) ;;
  *) exit 1 ;;
esac
test "$(gh release view "$cove_tag" -R cdimartino/codex-cove --json isDraft --jq .isDraft)" = false
test "$(gh release view "$cove_tag" -R cdimartino/codex-cove --json isPrerelease --jq .isPrerelease)" = false
test "$(gh release view "$cove_tag" -R cdimartino/codex-cove --json isImmutable --jq .isImmutable)" = true
test ! -e "$cove_app"
test ! -L "$cove_app"
test ! -e "$cove_support"
test ! -L "$cove_support"
test ! -e "$HOME/bin/codex-cove"
test ! -L "$HOME/bin/codex-cove"
test ! -e "$HOME/bin/codex"
test ! -L "$HOME/bin/codex"
test ! -e "$cove_socket"
test ! -S "$cove_socket"
if pgrep -u "$(id -u)" -x CodexCove >/dev/null 2>&1; then
  exit 1
fi
cove_existing_taps=$(HOMEBREW_NO_AUTO_UPDATE=1 brew tap)
if printf '%s\n' "$cove_existing_taps" | grep -Fx "$cove_tap" >/dev/null; then
  exit 1
fi
cove_installed_casks=$(HOMEBREW_NO_AUTO_UPDATE=1 brew list --cask --versions)
if printf '%s\n' "$cove_installed_casks" | \
  awk '$1 == "codex-cove" { found = 1 } END { exit !found }'; then
  exit 1
fi
cove_trust_before=$(HOMEBREW_NO_AUTO_UPDATE=1 brew trust --json=v1)
cove_assert_one_cask_trust_added() {
  cove_trust_now=$(HOMEBREW_NO_AUTO_UPDATE=1 brew trust --json=v1)
  COVE_TRUST_BASELINE="$cove_trust_before" \
    COVE_TRUST_CURRENT="$cove_trust_now" \
    ruby -rjson -e '
      baseline = JSON.parse(ENV.fetch("COVE_TRUST_BASELINE"))
      current = JSON.parse(ENV.fetch("COVE_TRUST_CURRENT"))
      keys = %w[taps formulae casks commands]
      valid = baseline.is_a?(Hash) && current.is_a?(Hash) &&
              baseline.keys.sort == keys.sort &&
              current.keys.sort == keys.sort &&
              keys.all? { |key| baseline.fetch(key).is_a?(Array) } &&
              keys.all? { |key| current.fetch(key).is_a?(Array) } &&
              %w[taps formulae commands].all? do |key|
                baseline.fetch(key) == current.fetch(key)
              end &&
              (baseline.fetch("casks") - current.fetch("casks")).empty? &&
              current.fetch("casks").length ==
                baseline.fetch("casks").length + 1
      exit(valid ? 0 : 1)
    '
}
cove_assert_trust_restored() {
  cove_trust_now=$(HOMEBREW_NO_AUTO_UPDATE=1 brew trust --json=v1)
  COVE_TRUST_BASELINE="$cove_trust_before" \
    COVE_TRUST_CURRENT="$cove_trust_now" \
    ruby -rjson -e '
      baseline = JSON.parse(ENV.fetch("COVE_TRUST_BASELINE"))
      current = JSON.parse(ENV.fetch("COVE_TRUST_CURRENT"))
      exit(baseline == current ? 0 : 1)
    '
}
cove_assert_cask_state() {
  cove_expected_available=$1
  cove_expected_installed=$2
  cove_expected_outdated=$3
  HOMEBREW_NO_AUTO_UPDATE=1 brew info --json=v2 --cask "$cove_cask" |
    COVE_EXPECTED_TOKEN="$cove_cask" \
    COVE_EXPECTED_TAP="$cove_tap" \
    COVE_EXPECTED_AVAILABLE="$cove_expected_available" \
    COVE_EXPECTED_INSTALLED="$cove_expected_installed" \
    COVE_EXPECTED_OUTDATED="$cove_expected_outdated" \
    ruby -rjson -e '
      casks = JSON.parse($stdin.read).fetch("casks")
      exit 1 unless casks.length == 1
      cask = casks.fetch(0)
      expected_outdated = ENV.fetch("COVE_EXPECTED_OUTDATED") == "true"
      valid = cask.fetch("full_token") == ENV.fetch("COVE_EXPECTED_TOKEN") &&
              cask.fetch("tap") == ENV.fetch("COVE_EXPECTED_TAP") &&
              cask.fetch("version") == ENV.fetch("COVE_EXPECTED_AVAILABLE") &&
              cask.fetch("installed") == ENV.fetch("COVE_EXPECTED_INSTALLED") &&
              cask.fetch("outdated") == expected_outdated
      exit(valid ? 0 : 1)
    '
}

mkdir "$cove_release_assets"
gh repo clone cdimartino/codex-cove "$cove_staged_checkout" -- \
  --branch "$cove_branch" --single-branch
test "$(git -C "$cove_staged_checkout" rev-parse HEAD)" = "$cove_expected_head"
cove_staged_version=$(./scripts/read-homebrew-cask-version.sh \
  "$cove_staged_checkout/Casks/codex-cove.rb")
test "$cove_staged_version" = "$cove_version"
git -C "$cove_staged_checkout" fetch --no-tags origin \
  "refs/heads/$cove_default_branch:refs/remotes/origin/$cove_default_branch"
test "$(git -C "$cove_staged_checkout" rev-parse \
  "origin/$cove_default_branch^{commit}")" = "$cove_default_head"
test "$(git -C "$cove_staged_checkout" merge-base \
  "$cove_default_head" HEAD)" = "$cove_default_head"
test "$(git -C "$cove_staged_checkout" diff --name-only \
  "$cove_default_head...HEAD")" = Casks/codex-cove.rb
gh release download "$cove_tag" -R cdimartino/codex-cove \
  -D "$cove_release_assets"
(
  cd "$cove_release_assets"
  shasum -a 256 --strict -c SHA256SUMS
)
./scripts/verify-homebrew-cask-release.sh \
  "$cove_staged_checkout/Casks/codex-cove.rb" \
  "$cove_release_assets"

HOMEBREW_NO_AUTO_UPDATE=1 brew tap "$cove_tap" "$cove_staged_checkout"
cove_tapped_checkout=$(brew --repository "$cove_tap")
test "$(git -C "$cove_tapped_checkout" rev-parse HEAD)" = "$cove_expected_head"
cmp "$cove_staged_checkout/Casks/codex-cove.rb" \
  "$cove_tapped_checkout/Casks/codex-cove.rb"
cmp "$cove_release_assets/codex-cove.rb" \
  "$cove_tapped_checkout/Casks/codex-cove.rb"

HOMEBREW_NO_AUTO_UPDATE=1 brew trust --cask "$cove_cask"
cove_assert_one_cask_trust_added
HOMEBREW_NO_AUTO_UPDATE=1 brew style --cask "$cove_cask"
case "$cove_prior_cask_count" in
  0) HOMEBREW_NO_AUTO_UPDATE=1 brew audit --cask --new "$cove_cask" ;;
  1) HOMEBREW_NO_AUTO_UPDATE=1 brew audit --cask --strict --online "$cove_cask" ;;
esac
```

Homebrew does not accept a Cask file path for the online audit. The disposable
tap and three-part `user/repository/cask` token above ensure the audited bytes
are the staged bytes. Item-specific trust also avoids trusting future content
from the entire temporary tap. The default branch's exact tree selects
`--new` only when no prior Cask exists; updates use `--strict --online`.

For the first Cask release, continue in the same shell on the same clean
account. The explicit version and prior-Cask checks below prevent a future
release from accidentally claiming this 0.2.0 same-version replacement path as
a real upgrade. The management command exits nonzero when Doctor is unhealthy;
keep both private JSON reports for review. The waits are bounded so launch or
termination failure cannot turn this gate into an indefinite hang.

```sh
set -eu
: "${cove_validation_root:?run the preparation block in this shell first}"
: "${cove_cask:?run the preparation block in this shell first}"
: "${cove_app:?run the preparation block in this shell first}"
: "${cove_settings:?run the preparation block in this shell first}"
: "${cove_socket:?run the preparation block in this shell first}"
test "$cove_tag" = v0.2.0
test "$cove_prior_cask_count" -eq 0

test ! -e "$cove_app"
test ! -L "$cove_app"
test ! -e "$HOME/bin/codex-cove"
test ! -L "$HOME/bin/codex-cove"
test ! -e "$HOME/bin/codex"
test ! -L "$HOME/bin/codex"
test ! -e "$cove_settings"

cove_wait_for_socket() {
  cove_wait_count=0
  until [ -S "$cove_socket" ]; do
    cove_wait_count=$((cove_wait_count + 1))
    [ "$cove_wait_count" -lt 20 ] || return 1
    sleep 1
  done
}

cove_wait_for_exit() {
  cove_wait_count=0
  while pgrep -u "$(id -u)" -x CodexCove >/dev/null; do
    cove_wait_count=$((cove_wait_count + 1))
    [ "$cove_wait_count" -lt 20 ] || return 1
    sleep 1
  done
}

HOMEBREW_NO_AUTO_UPDATE=1 \
  brew install --cask --require-sha "$cove_cask"
open "$cove_app"
cove_wait_for_socket
"$HOME/bin/codex-cove" doctor --json \
  >"$cove_validation_root/doctor-fresh.json"
test "$("$HOME/bin/codex-cove" --version)" = "codex-cove $cove_version"
cove_assert_cask_state "$cove_version" "$cove_version" false
codesign --verify --deep --strict --verbose=2 "$cove_app"
xcrun stapler validate "$cove_app"
spctl --assess --type execute --verbose=4 "$cove_app"
test "$(lipo -archs "$cove_app/Contents/MacOS/CodexCove")" = arm64
```

With Cove still open, note the current value of one benign preference, change
it to a different valid value, wait for the control to settle, and quit Cove
normally from its app menu. Do not manufacture or edit `settings.json`
directly. Then continue in the same shell:

```sh
set -eu
: "${cove_validation_root:?run the preparation block in this shell first}"
: "${cove_cask:?run the preparation block in this shell first}"
: "${cove_settings:?run the preparation block in this shell first}"
cove_wait_for_exit
test ! -e "$cove_socket"
test -f "$cove_settings"
test ! -L "$cove_settings"
cove_changed_settings_checksum="$cove_validation_root/settings-after-change.sha256"
shasum -a 256 "$cove_settings" >"$cove_changed_settings_checksum"
HOMEBREW_NO_AUTO_UPDATE=1 \
  brew reinstall --cask --require-sha "$cove_cask"
shasum -a 256 --strict -c "$cove_changed_settings_checksum"
open "$cove_app"
cove_wait_for_socket
"$HOME/bin/codex-cove" doctor --json \
  >"$cove_validation_root/doctor-reinstall.json"
test "$("$HOME/bin/codex-cove" --version)" = "codex-cove $cove_version"
cove_assert_cask_state "$cove_version" "$cove_version" false
```

Before continuing, obtain explicit authorization for one non-sensitive routed
session. Run it while the reinstalled app is live and verify its exact origin.
Inspect both Doctor reports for `healthy: true`, the private socket, the
installed signature, all remote helpers, and every editor target expected on
that account. Restore the noted preference in Cove Settings, wait for the
control to settle, and quit Cove normally. Only then continue in the same shell
and uninstall:

```sh
set -eu
: "${cove_changed_settings_checksum:?complete the reinstall block first}"
cove_wait_for_exit
test ! -e "$cove_socket"
if shasum -a 256 --strict -c "$cove_changed_settings_checksum" \
  >/dev/null 2>&1; then
  exit 1
fi
cove_retained_settings_checksum="$cove_validation_root/settings-before-uninstall.sha256"
shasum -a 256 "$cove_settings" >"$cove_retained_settings_checksum"
HOMEBREW_NO_AUTO_UPDATE=1 brew uninstall --cask "$cove_cask"
test ! -e "$cove_app"
test ! -L "$cove_app"
test ! -e "$HOME/bin/codex-cove"
test ! -L "$HOME/bin/codex-cove"
test ! -e "$HOME/bin/codex"
test ! -L "$HOME/bin/codex"
test -f "$cove_settings"
test ! -L "$cove_settings"
shasum -a 256 --strict -c "$cove_retained_settings_checksum"

HOMEBREW_NO_AUTO_UPDATE=1 brew untrust --cask "$cove_cask"
HOMEBREW_NO_AUTO_UPDATE=1 brew untap "$cove_tap"
cove_assert_trust_restored
```

After uninstall, verify Cove handlers and installed editor extensions are absent
while unrelated handlers and extensions remain. Never use `--force` or `--zap`
for this gate: normal uninstall must retain the settings file byte-for-byte.
Preserve the private validation directory until the reports and command output
are reviewed and archived; remove only that exact directory afterward.

If a command fails, do not rerun over the partial state. Preserve the validation
directory and inspect it first. Then use normal `brew uninstall --cask` if the
Cask was installed, followed by item-specific `brew untrust --cask` and
`brew untap`; stop for manual recovery if any cleanup step fails.

For 0.2.0, same-version `reinstall` is the available replacement-path test.

### Validate upgrades after the first Cask

For every later release, a same-version reinstall does not satisfy the upgrade
gate. Run the common preparation and audit block above from the new tag, with
the new staged-branch head. It will report `cove_prior_cask_count=1` and leave
the exact new Cask in the disposable tap, but not install it. Continue in that
same shell on a clean account. This replaces the first-Cask blocks above.

First, replace the disposable tap with a local two-commit tap whose initial
commit contains the exact prior Cask from the default branch, then install and
verify that prior public release:

```sh
set -eu
: "${cove_validation_root:?run the common preparation block first}"
: "${cove_staged_checkout:?run the common preparation block first}"
: "${cove_tapped_checkout:?run the common preparation block first}"
test "$cove_tag" != v0.2.0
test "$cove_prior_cask_count" -eq 1

cove_upgrade_tap_source="$cove_validation_root/upgrade-tap-source"
cove_prior_cask="$cove_validation_root/prior-codex-cove.rb"
test ! -e "$cove_upgrade_tap_source"
test ! -L "$cove_upgrade_tap_source"
test ! -e "$cove_prior_cask"
test ! -L "$cove_prior_cask"

HOMEBREW_NO_AUTO_UPDATE=1 brew untrust --cask "$cove_cask"
HOMEBREW_NO_AUTO_UPDATE=1 brew untap "$cove_tap"
cove_assert_trust_restored

mkdir "$cove_upgrade_tap_source"
mkdir "$cove_upgrade_tap_source/Casks"
git -C "$cove_staged_checkout" show \
  "$cove_default_head:Casks/codex-cove.rb" >"$cove_prior_cask"
cove_prior_version=$(./scripts/read-homebrew-cask-version.sh "$cove_prior_cask")
cove_prior_tag="v$cove_prior_version"
./scripts/verify-homebrew-cask-update.sh \
  "$cove_prior_cask" \
  "$cove_staged_checkout/Casks/codex-cove.rb"

cove_prior_release_assets="$cove_validation_root/prior-release"
test "$(gh release view "$cove_prior_tag" -R cdimartino/codex-cove \
  --json isDraft --jq .isDraft)" = false
test "$(gh release view "$cove_prior_tag" -R cdimartino/codex-cove \
  --json isPrerelease --jq .isPrerelease)" = false
test "$(gh release view "$cove_prior_tag" -R cdimartino/codex-cove \
  --json isImmutable --jq .isImmutable)" = true
mkdir "$cove_prior_release_assets"
gh release download "$cove_prior_tag" -R cdimartino/codex-cove \
  -D "$cove_prior_release_assets"
(
  cd "$cove_prior_release_assets"
  shasum -a 256 --strict -c SHA256SUMS
)
./scripts/verify-homebrew-cask-release.sh \
  "$cove_prior_cask" \
  "$cove_prior_release_assets"

install -m 0644 "$cove_prior_cask" \
  "$cove_upgrade_tap_source/Casks/codex-cove.rb"
git -C "$cove_upgrade_tap_source" init -q -b main
git -C "$cove_upgrade_tap_source" add Casks/codex-cove.rb
git -C "$cove_upgrade_tap_source" \
  -c user.name='Codex Cove Release Validation' \
  -c user.email='validation@example.invalid' \
  -c commit.gpgsign=false \
  commit -qm 'stage prior Codex Cove cask'
cove_prior_tap_head=$(git -C "$cove_upgrade_tap_source" rev-parse HEAD)

HOMEBREW_NO_AUTO_UPDATE=1 \
  brew tap "$cove_tap" "$cove_upgrade_tap_source"
cove_tapped_checkout=$(brew --repository "$cove_tap")
test "$(git -C "$cove_tapped_checkout" rev-parse HEAD)" = \
  "$cove_prior_tap_head"
cmp "$cove_prior_cask" "$cove_tapped_checkout/Casks/codex-cove.rb"
HOMEBREW_NO_AUTO_UPDATE=1 brew trust --cask "$cove_cask"
cove_assert_one_cask_trust_added

cove_wait_for_socket() {
  cove_wait_count=0
  until [ -S "$cove_socket" ]; do
    cove_wait_count=$((cove_wait_count + 1))
    [ "$cove_wait_count" -lt 20 ] || return 1
    sleep 1
  done
}

cove_wait_for_exit() {
  cove_wait_count=0
  while pgrep -u "$(id -u)" -x CodexCove >/dev/null; do
    cove_wait_count=$((cove_wait_count + 1))
    [ "$cove_wait_count" -lt 20 ] || return 1
    sleep 1
  done
}

HOMEBREW_NO_AUTO_UPDATE=1 \
  brew install --cask --require-sha "$cove_cask"
open "$cove_app"
cove_wait_for_socket
"$HOME/bin/codex-cove" doctor --json \
  >"$cove_validation_root/doctor-prior.json"
test "$("$HOME/bin/codex-cove" --version)" = \
  "codex-cove $cove_prior_version"
cove_assert_cask_state "$cove_prior_version" "$cove_prior_version" false
codesign --verify --deep --strict --verbose=2 "$cove_app"
xcrun stapler validate "$cove_app"
spctl --assess --type execute --verbose=4 "$cove_app"
```

With the prior release still open, note one benign preference, change it to a
different valid value, wait for it to settle, and quit Cove normally. Continue
in the same shell to advance the exact same tap to its second commit and perform
the real upgrade:

```sh
set -eu
cove_wait_for_exit
test ! -e "$cove_socket"
test -f "$cove_settings"
test ! -L "$cove_settings"
cove_preupgrade_settings_checksum="$cove_validation_root/settings-before-upgrade.sha256"
shasum -a 256 "$cove_settings" >"$cove_preupgrade_settings_checksum"

install -m 0644 "$cove_staged_checkout/Casks/codex-cove.rb" \
  "$cove_upgrade_tap_source/Casks/codex-cove.rb"
git -C "$cove_upgrade_tap_source" add Casks/codex-cove.rb
git -C "$cove_upgrade_tap_source" \
  -c user.name='Codex Cove Release Validation' \
  -c user.email='validation@example.invalid' \
  -c commit.gpgsign=false \
  commit -qm 'advance to staged Codex Cove cask'
cove_staged_tap_head=$(git -C "$cove_upgrade_tap_source" rev-parse HEAD)
git -C "$cove_tapped_checkout" pull --ff-only origin main
test "$(git -C "$cove_tapped_checkout" rev-parse HEAD)" = \
  "$cove_staged_tap_head"
cmp "$cove_staged_checkout/Casks/codex-cove.rb" \
  "$cove_tapped_checkout/Casks/codex-cove.rb"
cmp "$cove_release_assets/codex-cove.rb" \
  "$cove_tapped_checkout/Casks/codex-cove.rb"
HOMEBREW_NO_AUTO_UPDATE=1 brew style --cask "$cove_cask"
HOMEBREW_NO_AUTO_UPDATE=1 \
  brew audit --cask --strict --online "$cove_cask"
cove_assert_cask_state "$cove_version" "$cove_prior_version" true

HOMEBREW_NO_AUTO_UPDATE=1 \
  brew upgrade --cask --require-sha "$cove_cask"
shasum -a 256 --strict -c "$cove_preupgrade_settings_checksum"
open "$cove_app"
cove_wait_for_socket
"$HOME/bin/codex-cove" doctor --json \
  >"$cove_validation_root/doctor-upgrade.json"
test "$("$HOME/bin/codex-cove" --version)" = "codex-cove $cove_version"
cove_assert_cask_state "$cove_version" "$cove_version" false
codesign --verify --deep --strict --verbose=2 "$cove_app"
xcrun stapler validate "$cove_app"
spctl --assess --type execute --verbose=4 "$cove_app"
test "$(lipo -archs "$cove_app/Contents/MacOS/CodexCove")" = arm64
```

Obtain explicit authorization for one non-sensitive routed session on the new
version and verify its exact origin. Inspect the prior and upgraded Doctor
reports, restore the noted preference, wait for it to settle, and quit Cove
normally. Finish in the same shell:

```sh
set -eu
cove_wait_for_exit
test ! -e "$cove_socket"
if shasum -a 256 --strict -c "$cove_preupgrade_settings_checksum" \
  >/dev/null 2>&1; then
  exit 1
fi
cove_upgrade_retained_checksum="$cove_validation_root/settings-before-upgrade-uninstall.sha256"
shasum -a 256 "$cove_settings" >"$cove_upgrade_retained_checksum"
HOMEBREW_NO_AUTO_UPDATE=1 brew uninstall --cask "$cove_cask"
test ! -e "$cove_app"
test ! -L "$cove_app"
test ! -e "$HOME/bin/codex-cove"
test ! -L "$HOME/bin/codex-cove"
test ! -e "$HOME/bin/codex"
test ! -L "$HOME/bin/codex"
test -f "$cove_settings"
test ! -L "$cove_settings"
shasum -a 256 --strict -c "$cove_upgrade_retained_checksum"
HOMEBREW_NO_AUTO_UPDATE=1 brew untrust --cask "$cove_cask"
HOMEBREW_NO_AUTO_UPDATE=1 brew untap "$cove_tap"
cove_assert_trust_restored
```

After the future-upgrade uninstall, perform the same handler and
editor-extension cleanup check as the first-Cask path: Cove-owned entries must
be absent and unrelated entries must remain. On any failure, preserve the
validation directory, use only normal Cask uninstall plus item-specific
untrust/untap cleanup, require the full trust snapshot to match its baseline,
and stop for manual recovery if any cleanup assertion fails.

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

If only **Stage verified Homebrew cask update** fails after the release is public because
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
