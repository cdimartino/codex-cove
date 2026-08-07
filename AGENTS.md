# Codex Cove agent instructions

These instructions apply to the entire repository. Keep changes consistent with
the local-only privacy model, native Codex fallback, exact-origin routing, and
recoverable current-user installation described in `docs/ARCHITECTURE.md`,
`docs/SECURITY.md`, and `docs/CONTRIBUTING.md`.

## Start safely

- Read `README.md` and the relevant document under `docs/` before changing a
  subsystem. Do not infer installation or release behavior from one script.
- Native `codex` must remain independently installed and usable. Cove owns the
  `codex-cove` helper, never a replacement `codex` command.
- Do not read or write private Codex storage. Do not persist prompts, responses,
  commands, diffs, request content, token values, or absolute socket paths.
- Preserve unrelated hooks, editor extensions, shell files, apps, SSH settings,
  and user preferences. Installation and removal must fail closed when
  ownership or identity cannot be proved.
- Use app settings for preference changes. Do not hand-edit
  `~/Library/Application Support/Codex Cove/settings.json`.
- `SOURCE_CANDIDATE.manifest`, `SOURCE_CANDIDATE.sha256`, and
  `SOURCE_CANDIDATE.receipt` are release evidence. Do not edit or regenerate
  them during ordinary feature or documentation work.

## Development and checks

```sh
make deps       # mutates local dependency trees and runs the npm audit
make bootstrap  # read-only toolchain check
make build
make test
make ui-test    # requires full Xcode and an unlocked macOS console
```

Use the narrowest relevant test while iterating, then run the proportionate
suite from `docs/CONTRIBUTING.md`. At minimum, run `git diff --check` for every
change. Remote/helper work needs `make helper-test`; UI or macOS integration
needs its foundation tests and normally `make ui-test`; extension work needs
`make extension-test`.

`make run` launches an uninstalled development app. It does not install hooks,
the helper, editor integration, login items, or remote artifacts. `make install`
installs local integration but omits cross-platform remote helpers. Use
`make install-with-remote` when a source installation must support remote hosts.

Doctor is the canonical installed-state readback:

```sh
"$HOME/bin/codex-cove" doctor --json
```

A durable app-server warning is acceptable only when Doctor confirms the direct
stdio fallback. Required identity, integrity, schema, helper, and private-socket
checks must pass. Runtime sockets and support directories must deny group and
other access.

## Routed sessions and editor integration

- A normal `codex` launch is hook-only. It can report status, but Cove cannot
  authoritatively answer approvals or questions from it.
- Use `"$HOME/bin/codex-cove" launch [CODEX_ARGS...]` for an explicitly
  broker-routed session. If Cove or both public app-server modes are unavailable,
  the helper must fall back to native Codex rather than strand the terminal.
- In VS Code or Cursor, use **Cove: Create Routed Terminal** for the strongest
  terminal/window binding. Reload editor windows after installing the bundled
  extension. **Cove: Register Active Terminal** attaches an existing terminal.
- Accessibility is optional and enables global shortcuts plus exact editor or
  OSC-marker focus. Terminal/iTerm Automation is optional and enables exact
  tab/session focus. Never grant or work around these permissions silently.
- Cove is an accessory app without a Dock icon. Use its menu-bar item or open
  `~/Applications/Codex Cove.app` to reveal it.

## Integrating a remote host

Remote support is opt-in. Work only with an SSH alias the user explicitly
names; Cove must never enumerate SSH configuration or choose a host.

1. Verify the same non-interactive SSH environment Cove will use:

   ```sh
   ssh -o BatchMode=yes my-build-host true
   ssh -o BatchMode=yes my-build-host \
     'command -v codex && codex --version && uname -s && uname -m'
   ```

   The remote native Codex must resolve on that non-interactive `PATH`. A normal
   Linux standalone installation may resolve as
   `~/.local/bin/codex -> ~/.codex/packages/standalone/current/codex`; this
   user-owned link is valid. Preserve it. If `command -v codex` fails, repair
   the remote login `PATH` or its independently owned link instead of replacing
   native Codex or hard-coding a user-specific home path.

2. Ensure the local app bundle contains the artifact matching the remote OS and
   architecture:

   | `uname -s` / `uname -m` | Artifact directory |
   | --- | --- |
   | `Darwin` / `arm64` | `aarch64-apple-darwin` |
   | `Darwin` / `x86_64` | `x86_64-apple-darwin` |
   | `Linux` / `aarch64` | `aarch64-unknown-linux-musl` |
   | `Linux` / `x86_64` | `x86_64-unknown-linux-musl` |

3. Quit Cove before changing or deploying remote integration. Add the exact
   alias, preview the deployment, apply the matching bundled artifact, and read
   back Doctor:

   ```sh
   "$HOME/bin/codex-cove" remote add my-build-host
   "$HOME/bin/codex-cove" remote deploy my-build-host --plan
   "$HOME/bin/codex-cove" remote deploy my-build-host \
     --artifact "$HOME/Applications/Codex Cove.app/Contents/Resources/remote/aarch64-unknown-linux-musl/codex-cove"
   "$HOME/bin/codex-cove" remote doctor my-build-host
   ```

   `remote add` intentionally has no plan mode. Deployment installs a private,
   checksummed helper below `~/.local/share/codex-cove`, creates the current
   link, merges only Cove-owned hooks, and leaves native Codex untouched.

4. Relaunch the local Cove app so it starts the bounded, strict-host-key,
   non-interactive relay. The local app must remain running for remote events
   and decisions to cross that relay.

5. On the remote host, start a routed session with:

   ```sh
   "$HOME/.local/bin/codex-cove" launch [CODEX_ARGS...]
   ```

   Running remote `codex` directly is hook-only, just like a local native
   launch. For a functional UI check, use one explicitly authorized,
   non-sensitive routed session. Do not pass `--ephemeral` when the check needs
   a completed task card to remain visible; an ephemeral run may leave only
   transient hook diagnostics. Verify the task details show source
   **Remote CLI** and the exact selected host alias. Never infer remote origin
   from a session identifier alone.

For removal, quit Cove, preview, apply, and relaunch:

```sh
"$HOME/bin/codex-cove" remote remove my-build-host --plan
"$HOME/bin/codex-cove" remote remove my-build-host
```

Use `--forget` only when the user confirms the host is permanently unreachable.
It removes local selection only and does not prove remote cleanup.

## Installation, Homebrew, and releases

- The supported app path is `~/Applications/Codex Cove.app`; Homebrew and
  source/manual installs intentionally converge there.
- Use normal package-manager operations. Do not use `--force`, `--zap`, remove
  quarantine, require `sudo`, or overwrite an app owned by another install path.
- Homebrew owns app replacement/removal; the embedded helper owns only verified
  current-user integration. Preserve settings and native Codex across upgrade,
  uninstall, reinstall, and rollback checks.
- Do not hand-edit generated Cask version, URL, or checksum fields. A published
  Cask must name an immutable release asset and literal SHA-256.
- Tags, releases, and protected-branch or Homebrew-Cask merges require separate
  owner confirmation. Re-read the exact PR head before requesting a merge, do
  not use admin bypass or force-push, and verify the public tag, release assets,
  checksums, Cask, and protected branch before claiming publication.

Keep public commits, fixtures, screenshots, logs, and PR text free of real SSH
aliases, usernames, home paths, task content, and opaque task/session/launch or
control identifiers.
