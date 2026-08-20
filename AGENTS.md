# Codex Cove agent instructions

These instructions apply to the whole repository. Keep changes consistent with
the local-only privacy model, native Codex fallback, exact-origin routing, and
recoverable current-user installation described in `docs/ARCHITECTURE.md`,
`docs/SECURITY.md`, and `docs/CONTRIBUTING.md`.

## Safety and privacy

- Native `codex` must remain independently installed and usable. Cove owns the
  `codex-cove` helper, never a replacement `codex` command.
- Do not read or write private Codex storage. Do not persist prompts, responses,
  commands, diffs, request content, token values, or absolute socket paths.
- Preserve unrelated hooks, editor extensions, shell files, apps, SSH settings,
  and user preferences. Installation and removal must fail closed when
  ownership or identity cannot be proved.
- Use app settings for preference changes. Do not hand-edit
  `~/Library/Application Support/Codex Cove/settings.json`.
- Keep public commits, fixtures, screenshots, logs, and PR text free of real
  usernames, SSH aliases, task content, and opaque task/session/launch/control
  identifiers.
- `SOURCE_CANDIDATE.manifest`, `SOURCE_CANDIDATE.sha256`, and
  `SOURCE_CANDIDATE.receipt` are release evidence. Do not edit or regenerate
  them during ordinary feature or documentation work.

## Development and checks

Use the narrowest relevant test while iterating, then run the proportional
suite from `docs/CONTRIBUTING.md`. At minimum, run `git diff --check`.

```sh
make deps       # mutates dependency trees and runs npm audit
make bootstrap  # read-only toolchain check
make build
make test
```

- Helper or remote work: `make helper-test` and the relevant remote build.
- UI or macOS integration: focused foundation tests plus native UI coverage.
- Extension work: `make extension-test`.
- Use `make ui-test-build` for compile-only validation while Codex is open.
  Normal `make ui-test` can crash the running Codex app during macOS Automation
  teardown, so run it only after quitting Codex or on a separate Mac/VM. On the
  explicitly validated Xcode build, `make ui-test-legacy-ax` is the opt-in
  fallback documented in `docs/CONTRIBUTING.md`.

`make run` launches an uninstalled development app. `make install` omits remote
helpers; use `make install-with-remote` when a source installation must support
remote hosts. Doctor is the canonical installed-state readback:

```sh
"$HOME/bin/codex-cove" doctor --json
```

A durable app-server warning is acceptable only when Doctor confirms the direct
stdio fallback. Identity, integrity, schema, helper, and private-socket checks
must pass.

## Sessions, UI, and remote hosts

- Raw session IDs are not identities. Scope task state and control by source,
  remote host, and opaque session ID.
- A normal `codex` launch is hook-observed. Use
  `"$HOME/bin/codex-cove" launch [CODEX_ARGS...]` or **Cove: Create Routed
  Terminal** in VS Code/Cursor when authoritative routing is required.
- Never grant or work around Accessibility, Automation, or other macOS
  permissions silently.
- The ambient island is an accessory surface. Opening Workspace gives Cove a
  normal Dock/App-Switcher presence until that window closes.
- Remote support is opt-in. Work only with an SSH alias the user explicitly
  names; never enumerate SSH configuration or choose a host. Follow
  `docs/INSTALLATION.md` for add, plan, deploy, Doctor, routed validation, and
  removal. Preserve strict host-key checking and the remote native `codex`.

## Installation and releases

- The supported app path is `~/Applications/Codex Cove.app`; Homebrew and
  source/manual installs intentionally converge there.
- Use normal package-manager operations. Do not use `--force`, `--zap`, remove
  quarantine, require `sudo`, or overwrite an app owned by another install path.
- Homebrew owns app replacement/removal; the helper owns only verified
  current-user integration. Preserve settings and native Codex across upgrade,
  uninstall, reinstall, and rollback checks.
- Do not hand-edit generated Cask version, URL, or checksum fields.
- Follow `docs/RELEASES.md`. Protected source merges, signed tag/release
  publication, and the generated Cask merge each require a fresh exact-head
  confirmation. Never bypass protection, force-push, or move an immutable tag.
