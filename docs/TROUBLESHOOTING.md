# Troubleshooting

Start with Cove's diagnostic report. The text form is easiest to read; JSON is
useful when attaching a redacted machine-readable report to an issue.

```sh
"$HOME/bin/codex-cove" doctor
"$HOME/bin/codex-cove" doctor --json
```

Doctor exits nonzero when a required check fails. Warnings can be expected when
the app is not running, an optional editor is absent, remote artifacts were not
packaged, or the durable app-server proxy is unavailable but direct stdio is
working. Read each detail rather than treating every warning as corruption.

## The app is installed but not visible

Codex Cove is an accessory app, so it has no Dock icon. Look for the wave icon
in the menu bar and choose **Show Cove**.

```sh
open "$HOME/Applications/Codex Cove.app"
```

Opening a second copy does not create a second Cove process; it asks the existing
instance to reveal itself. If neither the menu item nor the island appears:

1. Quit any running Cove instance from its menu.
2. Verify the app signature with
   `codesign --verify --deep --strict "$HOME/Applications/Codex Cove.app"`.
3. Open it again and inspect **Console.app** for the `CodexCove` process.
4. Run Doctor after the app is open so its runtime-socket checks are meaningful.

## `codex` is not routed through Cove

Check command lookup in a new shell:

```sh
command -v codex
command -v codex-cove
ls -l "$HOME/bin/codex" "$HOME/bin/codex-cove"
```

Both commands should resolve below `~/bin`, and the links should point to Cove's
managed helper. If `command -v codex` resolves the original installation, put
`~/bin` before it on `PATH`:

```sh
export PATH="$HOME/bin:$PATH"
```

Restart the shell after changing a startup file. Do not replace an existing
non-Cove `~/bin/codex` path by hand; the installer intentionally refuses to
overwrite it. Move or rename that path only after you have identified its owner
and decided how it should coexist.

To bypass Cove while isolating a problem:

```sh
CODEX_COVE_BYPASS=1 codex
```

To show content-free broker readiness diagnostics:

```sh
CODEX_COVE_TRACE_BROKER=1 codex
```

## Codex stays on “Starting MCP servers”

First bypass Cove without changing MCP definitions:

```sh
CODEX_COVE_BYPASS=1 codex --no-alt-screen
```

If native Codex reaches its prompt but the routed launch does not, rerun the
current Cove installer or upgrade the Cask, then run `codex-cove doctor`.
Version 0.3.0 and newer prefer the current non-Cove Codex binary on `PATH` over
an older versioned `realCodex` path. They also migrate the legacy 1 MiB broker
frame limit to 8 MiB: Codex 0.146 can return an `app/list` response around
3.5 MiB after MCP startup. If a broker worker still fails or the client
disconnects, Cove terminates and reaps the complete app-server process group
instead of leaving the TUI waiting indefinitely.

MCP initialization messages followed by app-server `Broken pipe` output point
to a broker/client lifecycle failure, not automatically to an individual MCP
package. Do not change ownership of `~/.npm`, delete its cache, or modify MCP
configuration unless a separate native launch reproduces an npm failure.

## No CLI tasks appear

Work through these in order:

1. Open Cove and rerun Doctor.
2. Confirm the shell resolves Cove's shim as described above.
3. Start a new Codex session; an already-running native session cannot acquire a
   launch binding retroactively.
4. In Codex, review the installed hook with `/hooks` and complete the native
   trust flow.
5. Check the shim's startup message. If it says app-server is unavailable, Cove
   deliberately fell back to native Codex.

Hook events can still provide status when a full broker route is unavailable,
but authoritative in-Cove decisions require a broker-routed launch.

## An approval or question stays in Codex

This is expected for requests Cove cannot prove it owns. In particular,
Desktop questions, plan feedback, unknown request methods, ambiguous hook-only
permission events, and Codex auto-review traffic remain native.

For a local CLI approval that should be actionable:

1. confirm the session was started after Cove integration and hook trust;
2. confirm Doctor reports a working public app-server mode;
3. use **Open in Codex** if the request is stale or delivery failed; and
4. retry only while the same request remains visibly pending.

A Cove “delivered” result confirms a complete socket write, not downstream
Codex completion. Check the native terminal after responding.

## VS Code or Cursor does not register terminals

Verify the extension in each installed editor:

```sh
code --list-extensions --show-versions | grep codex-cove-local.cove-extension
cursor --list-extensions --show-versions | grep codex-cove-local.cove-extension
```

If it is absent, rerun the installer while that editor's CLI is available. If
it is present, run **Developer: Reload Window**, then use **Cove: Show Status**.
For a new task, prefer **Cove: Create Routed Terminal**. For an existing one,
focus it and run **Cove: Register Active Terminal**.

The extension Output channel is named **Codex Cove** by default. Its exact-focus
lines contain only phase and result fields. A focus server unavailable message
usually means the private runtime directory is unavailable, unsafe, or already
has a conflicting endpoint.

## Cove selects a terminal but raises the wrong editor window

Exact editor focus requires both the extension handshake and native
Accessibility focus. Cove now fails closed instead of accepting a merely
selected terminal, so a failed window verification should report that the exact
origin is unavailable.

1. Enable **Codex Cove** under **System Settings → Privacy & Security →
   Accessibility**.
2. Quit and reopen Cove.
3. Reload every VS Code/Cursor window that should participate.
4. Create a routed terminal in each intended window.
5. Retry from the matching Cove card, not only from the global “current” action.

If the app was replaced by an ad-hoc-signed build, macOS may retain a visible
but stale privacy entry. Toggle that exact entry off and on, then relaunch Cove.
Do not add unrelated binaries to Accessibility as a workaround.

## Global shortcuts do nothing

In **Settings → General**, enable **Global shortcuts**. Confirm Accessibility
permission is effective, then quit and reopen Cove. The shortcuts are global
event monitors and are not registered when Accessibility trust is absent at
startup.

The menu-bar **Show Cove** and task **Open** actions remain available without
global shortcuts.

## Terminal.app or iTerm2 exact jump fails

Cove restores a terminal by exact TTY, not by title guesswork.

- Keep the original tab/session open.
- Confirm **System Settings → Privacy & Security → Automation → Codex Cove**
  allows the intended terminal app.
- If macOS never prompted, trigger one exact jump from Cove and review the
  resulting permission prompt.
- If a session moved into tmux or WezTerm, verify that the corresponding CLI is
  installed and the original pane still exists.

Cove reports failure when a TTY, pane, or marker is closed or ambiguous; it does
not focus a random terminal as a fallback.

## Notifications or sounds are missing

For notifications:

1. enable them in **Settings → Notifications**;
2. allow Codex Cove in macOS Notification settings;
3. verify the event type is enabled in Cove's notification matrix;
4. check Privacy, quiet hours, focused-app quieting, and project silence rules.

For sounds, check both **Play event sounds** and **Mute all sounds**, then use
the per-event **Preview** button. An imported sound must still exist in Cove's
private manifest and decode as WAV, MP3, AIFF, or M4A.

Events from before the current Cove launch are deliberately not replayed as new
system banners or sounds.

## Settings could not be loaded

Cove disables persistence rather than overwriting a malformed or newer-schema
settings file. Quit Cove and make a recoverable copy before any change:

```sh
cp "$HOME/Library/Application Support/Codex Cove/settings.json" \
  "$HOME/Desktop/codex-cove-settings.backup.json"
```

Inspect the copy for truncation, invalid JSON, unsafe permissions, or a schema
newer than the installed app. Prefer reinstalling the matching/newer Cove
version. Resetting the file should be a deliberate last resort because it loses
local preferences; do not delete the session database when only settings fail.

## Homebrew install or upgrade fails

The repository used as the documented tap is public now, but a version becomes
installable only after its binary release and matching `Casks/codex-cove.rb`
land. A missing Cask before then does not mean Homebrew should be pointed at a
private or unverified artifact. Do not install Homebrew's similarly named
deprecated `codex-app` Cask: it is a different product, not a Cove dependency.
Use the source or manual release path instead.

Once the Cask is live, refresh and inspect the resolved package before retrying:

```sh
brew update
brew trust --cask cdimartino/codex-cove/codex-cove
brew info --cask cdimartino/codex-cove/codex-cove
brew fetch --cask cdimartino/codex-cove/codex-cove
```

For common failures:

- **Homebrew says the Cask is unavailable or untrusted.** Review the tap with
  `brew tap-info cdimartino/codex-cove`, run the item-specific `brew trust`
  command above, and retry the fully qualified Cove token. Do not install
  `codex-app` or another fuzzy-search suggestion.
- **An app already exists in `~/Applications`.** If it is a source or manual
  Cove installation, quit it and run
  `"$HOME/bin/codex-cove" uninstall --keep-settings` before the Homebrew
  install. Do not use `--force` to adopt an unverified bundle.
- **The archive checksum does not match.** Stop. Run `brew update`, confirm the
  Cask version and release tag agree, and report the mismatch. Do not edit the
  Cask, use `sha256 :no_check`, replace the release asset, or disable quarantine.
- **Postflight integration is blocked.** Inspect the install plan and the exact
  path named by the error. Cove intentionally preserves a modified shim, hook,
  helper, extension obligation, or manifest instead of overwriting it.
- **An upgrade or uninstall is blocked.** Keep the app in place while
  investigating. Homebrew coordinates its app artifact with the helper's
  package-manager-only `--keep-app --keep-settings` cleanup. Running the ordinary
  helper uninstall first can remove the app before Homebrew finishes.

After resolving an ownership problem, repair only the published version with:

```sh
brew reinstall --cask cdimartino/codex-cove/codex-cove
```

If the public Cask itself is wrong but the GitHub release is valid, use the
manual verified-release instructions and report the Cask defect. Maintainers
must correct the generated Cask without moving the release tag or replacing the
published binary.

## Install, repair, or uninstall is blocked

The transaction stops when a managed path is missing, modified, replaced, has
an unexpected owner/type, or no longer matches its manifest. This is a safety
feature.

```sh
"$HOME/Applications/Codex Cove.app/Contents/Resources/bin/codex-cove" \
  install --app-path "$HOME/Applications/Codex Cove.app" --plan
"$HOME/bin/codex-cove" uninstall --keep-settings --plan
```

Do not delete the blocked path to force progress. Identify whether it belongs
to Cove, another tool, or the user. Retain timestamped `.backup.*` and
`.failed.*` app bundles until the working installation has been verified and
you intentionally decide to remove them.

## Remote host does not connect

First validate SSH outside Cove:

```sh
ssh -o BatchMode=yes my-build-host true
```

Then confirm the alias was explicitly added and the matching architecture
artifact was deployed:

```sh
"$HOME/bin/codex-cove" remote doctor my-build-host
```

Common causes are an unaccepted host key, an agent or key unavailable to
non-interactive SSH, wrong helper architecture, missing remote Codex CLI, a
changed remote helper checksum, or Cove still running while its host list is
being changed.

Quit Cove before `remote add`, `remote remove`, or `--forget`, and relaunch it
afterward. Use `--forget` only for a permanently unreachable host; it removes
the local selection without claiming to clean the remote machine.

## Build failures

Run the read-only environment check first:

```sh
make bootstrap
```

If it reports missing or inconsistent dependencies, install the locked graphs
and repeat the read-only check:

```sh
make deps
make bootstrap
```

`make deps` is not read-only: it resolves and fetches Swift and Rust packages,
replaces the extension's local dependency tree with `npm ci`, and runs the
zero-advisory npm audit.

Frequent causes:

- `xcodebuild` points at Command Line Tools: select full Xcode with
  `sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer`.
- extension dependencies are missing or inconsistent: rerun `make deps`, which
  uses the checked-in lockfile and `npm ci`. If the npm audit then reports an
  advisory, inspect it and intentionally update the affected dependency and
  checked-in lockfile. Do not raise the audit threshold or use a forced audit
  fix merely to bypass the gate; rerun `make deps` and the relevant tests.
- remote targets fail: install rustup, Zig, and `cargo-zigbuild`, and ensure the
  same rustup toolchain supplies both Cargo and rustc.
- `make ui-test` refuses to start: unlock the macOS console and use full Xcode
  26.6 or newer.
- Xcode project membership changed: regenerate only after intentional edits with
  `xcodegen generate --spec XcodeProject.yml --project .` and review the diff.

Run individual layers while narrowing a failure:

```sh
make swift-test
make store-foundation-test
make milestone13-test
make milestone2-test
make helper-test
make extension-test
make ui-test
```

## Asking for help

Include the Cove version or commit, macOS version, affected surface, a redacted
Doctor report, and the smallest reproducible sequence. Never include private
prompt, response, command, or diff content, SSH aliases, usernames, absolute
home paths, or task, session, launch, control, or Desktop identifiers in a
public report. Replace sensitive arguments in any diagnostic command with
clearly marked placeholders.

For a potential vulnerability, follow [Security & Privacy](SECURITY.md#report-a-vulnerability).
