# Installation

Codex Cove installs entirely within the current macOS user account. It does not
require `sudo`, write system directories, or modify machine-wide Codex state.

## Requirements

The native app supports Apple Silicon Macs running macOS 14 or newer.

Building from source requires:

- Swift 6.0+
- Rust 1.85+
- Node.js 22+ with npm
- Codex CLI 0.145.0+
- GNU Make
- Apple `codesign`, `plutil`, and the Command Line Tools
- Full Xcode 26.6+ for `make bootstrap` and `make ui-test`; a compatible Swift
  Command Line Tools install is sufficient for the non-UI test targets

Optional remote-helper cross-builds additionally require a rustup-managed
stable toolchain, Zig, and `cargo-zigbuild`. XcodeGen 2.46+ is needed only when
regenerating the checked-in UI-test project.

After installing or changing Xcode, select it before running the checks:

```sh
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
```

## Build and install from source

```sh
git clone https://github.com/cdimartino/codex-cove.git
cd codex-cove
make deps
make bootstrap
make test
make install
```

`make deps` resolves Swift packages, fetches the locked Rust graph, and runs
`npm ci` for the editor extension. It does not install machine-level tools.
`make bootstrap` is a read-only version and dependency check.

The install target:

1. builds and signs `build/Codex Cove.app`;
2. stops a currently running Cove instance after validating its identity;
3. installs the app at `~/Applications/Codex Cove.app`;
4. installs a managed helper and the `~/bin/codex` and
   `~/bin/codex-cove` links;
5. merges Cove entries into `~/.codex/hooks.json` without replacing unrelated
   hook groups;
6. installs the bundled private extension in VS Code and Cursor when their
   command-line launchers are available; and
7. records checksums and cleanup obligations in a private install manifest.

An upgrade moves the prior app to a timestamped backup before committing the
replacement. If integration setup then fails, the installer restores that
backup and retains the failed package for inspection.

The default source build uses an ad-hoc signature. To use an existing compatible
identity, pass its exact keychain name:

```sh
CODEX_COVE_SIGNING_IDENTITY="Developer ID Application: Example (TEAMID)" make install
```

`make signing-identity` is an advanced local-development helper that creates a
new identity and changes login-keychain trust. It is not required for normal
installation and should not be run casually.

## Install a GitHub release

Published release notes are authoritative for asset names, supported
architectures, signing, and notarization status. Download the app archive and
`SHA256SUMS` from the same release into an otherwise clean directory. Compare
the archive's `shasum -a 256` output with its exact line in `SHA256SUMS`. To
machine-check the aggregate manifest, download every listed asset and run:

```sh
shasum -a 256 -c SHA256SUMS
```

Expand the verified archive, then verify the app bundle itself:

```sh
codesign --verify --deep --strict "/path/to/Codex Cove.app"
xcrun stapler validate "/path/to/Codex Cove.app"
spctl --assess --type execute --verbose=4 "/path/to/Codex Cove.app"
```

Move the verified app to `~/Applications`, then run its bundled helper to apply
the current-user integration:

```sh
mkdir -p "$HOME/Applications"
"$HOME/Applications/Codex Cove.app/Contents/Resources/bin/codex-cove" \
  install --app-path "$HOME/Applications/Codex Cove.app"
open "$HOME/Applications/Codex Cove.app"
"$HOME/bin/codex-cove" doctor
```

Do not bypass Gatekeeper or remove quarantine attributes solely to make an
unverified artifact open. An ad-hoc-signed development asset is not equivalent
to a Developer ID signed and notarized distribution.

## Shell setup and hook trust

The Cove shim participates only when `~/bin/codex` wins command lookup. Add
this to the appropriate shell startup file if needed:

```sh
export PATH="$HOME/bin:$PATH"
```

Open a new shell and verify:

```sh
command -v codex
command -v codex-cove
codex-cove doctor
```

Both commands should resolve under `~/bin`. The shim discovers and executes the
original Codex binary; `CODEX_COVE_BYPASS=1 codex` is the emergency route around
Cove when troubleshooting.

Codex owns hook trust. After installation, start Codex and use its `/hooks`
flow to review and trust the Cove hook through the normal Codex UI. Cove does
not silently approve its own hook.

## macOS permissions

Cove remains useful without optional permissions, but exact focus and alerts
depend on the capabilities below.

### Accessibility

Enable **Codex Cove** in **System Settings → Privacy & Security →
Accessibility** for:

- global `Command-Shift-O`, `Command-Shift-E`, and `Command-Shift-T` shortcuts;
- exact VS Code and Cursor window restoration; and
- the accessibility fallback for terminal hosts exposing an opaque Cove title
  marker.

After changing the setting, quit and reopen Cove. Replacing an ad-hoc-signed app
can invalidate the previous macOS privacy grant even if the visible toggle is
still on. The first move from a local/ad-hoc identity to a Developer ID release
can also require the old Cove privacy entries to be removed and granted again.
If shortcuts or editor focus stop working immediately after an upgrade, renew
only the exact Cove grant, then relaunch it.

### Automation

The first exact jump to Terminal.app or iTerm2 can cause macOS to ask whether
Codex Cove may control that application. Allow only the terminal applications
you intend Cove to restore. Existing decisions are visible under **System
Settings → Privacy & Security → Automation → Codex Cove**.

### Notifications and login item

Cove asks for notification permission only after notifications are enabled in
Settings. **Launch at login** uses the public macOS login-item service and can
be changed at any time from Cove Settings or macOS Login Items.

## Editor integration

The source and release packages contain a private extension with ID
`codex-cove-local.cove-extension`. The installer uses the `code` and `cursor`
command-line launchers when available.

Verify installation with:

```sh
code --list-extensions --show-versions | grep codex-cove-local.cove-extension
cursor --list-extensions --show-versions | grep codex-cove-local.cove-extension
```

Reload any editor windows that were open during installation. In the Command
Palette, use **Cove: Create Routed Terminal** for a new session or **Cove:
Register Active Terminal** for an existing terminal.

## Remote CLI helpers

Remote support is opt-in. Build or install the package containing all four
remote targets:

```sh
make install-with-remote
```

The bundle contains helpers for:

- `aarch64-apple-darwin`
- `x86_64-apple-darwin`
- `aarch64-unknown-linux-musl`
- `x86_64-unknown-linux-musl`

Configure SSH host keys and non-interactive authentication yourself first.
Cove never searches SSH configuration or chooses a host. Quit Cove before
changing its remote-host list, then add exactly one existing SSH alias, preview
the deployment, and deploy the matching helper:

```sh
"$HOME/bin/codex-cove" remote add my-build-host
"$HOME/bin/codex-cove" remote deploy my-build-host --plan
"$HOME/bin/codex-cove" remote deploy my-build-host \
  --artifact "$HOME/Applications/Codex Cove.app/Contents/Resources/remote/aarch64-unknown-linux-musl/codex-cove"
"$HOME/bin/codex-cove" remote doctor my-build-host
```

Relaunch Cove after the host-list update. The relay uses strict host-key
checking, batch mode, bounded connection and keepalive timeouts, and only the
aliases recorded in Cove's private configuration.

For removal, quit Cove and preview before applying:

```sh
"$HOME/bin/codex-cove" remote remove my-build-host --plan
"$HOME/bin/codex-cove" remote remove my-build-host
```

If the host is permanently unreachable, `remote remove my-build-host --forget`
performs local-only cleanup. It deliberately makes no claim that the remote
helper was removed.

## Upgrade and repair

Use the same `make install` or bundled-helper install command for an upgrade.
The install transaction refuses to replace unexpected files, directories, or
links. Inspect a proposed helper mutation before applying it:

```sh
"$HOME/Applications/Codex Cove.app/Contents/Resources/bin/codex-cove" \
  install --app-path "$HOME/Applications/Codex Cove.app" --plan
```

After an upgrade, reopen Cove, reload VS Code/Cursor windows, run Doctor, and
recheck macOS permissions if exact focus changed.

## Safe removal

Quit Cove, then preview removal:

```sh
"$HOME/bin/codex-cove" uninstall --keep-settings --plan
```

To remove Cove-owned integration and the installed app while retaining local
preferences, imported assets, and session metadata:

```sh
"$HOME/bin/codex-cove" uninstall --keep-settings
```

Omit `--keep-settings` only when you intentionally want to delete Cove's local
settings and metadata as well. Uninstall verifies the install manifest and
checksums, removes only Cove-owned hooks, links, extension obligations, helper,
and app, preserves modified or unowned paths, and never deletes Codex tasks,
threads, unrelated hooks, or SSH configuration.
