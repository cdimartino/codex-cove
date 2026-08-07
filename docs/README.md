# Codex Cove documentation

Start with the guide that matches what you are trying to do.

## Users

- [Installation](INSTALLATION.md) — Homebrew, source, and manual release
  installs, macOS permissions, migration, upgrades, remote helpers, and removal.
- [User Guide](USER_GUIDE.md) — the island, queue, decisions, exact-origin
  navigation, editor commands, privacy, notifications, and settings.
- [Troubleshooting](TROUBLESHOOTING.md) — diagnostic commands and common
  Homebrew, local, editor, permission, and remote-integration failures.
- [Security & Privacy](SECURITY.md) — data handling, trust boundaries,
  permissions, filesystem protections, network behavior, and reporting.

## Contributors and maintainers

- [Architecture](ARCHITECTURE.md) — components, event and decision flows,
  persistence, focus protocol, and failure behavior.
- [Protocol contract](PROTOCOL.md) — versioned Cove IPC and the public Codex
  app-server interfaces Cove consumes.
- [Contributing](CONTRIBUTING.md) — development setup, test layers, change
  discipline, and review expectations.
- [Release Process](RELEASES.md) — versioning, candidate freeze, CI, packaging,
  signing, GitHub releases, Homebrew Cask handoff, and rollback.
- [Codex Cove 0.2.0 release notes](releases/v0.2.0.md) — immutable user-facing
  contents and compatibility notes for the `v0.2.0` release contract.
- [Codex Cove 0.3.0 release notes](releases/v0.3.0.md) — queue organization,
  bulk archiving, direct task opening, and installed theme rendering fixes.
- [Codex Cove 0.4.0 release notes](releases/v0.4.0.md) — custom theme
  authoring, resident sets, Settings collapse, and native Codex-by-default
  installation.
- [Codex Cove 0.5.0 release notes](releases/v0.5.0.md) — live solid and gradient
  themes, native translucency, restorable idle hide, and latest task output.
- [Codex Cove 0.5.1 release notes](releases/v0.5.1.md) — corrected native
  backdrop transparency for the collapsed island.
- [Codex Cove 0.5.2 release notes](releases/v0.5.2.md) — reliable Linux remote
  helper setup with the standard native Codex installation path.

## Version-specific engineering records

The remaining documents capture implementation plans, handoffs, manual test
matrices, and release evidence for a specific development cycle:

- `EXECPLAN.md`
- `EXECUTION_PLAN_0.2.0.md`
- `NEXT_RELEASE_UX_PLAN.md`
- `VALIDATION_0.2.0.md`
- `OWNER_PASS_0.2.0.md`
- `HANDOFF.md`

These records may describe incomplete gates or historical observations. Use the
guides above for current product behavior, the release notes for immutable
contents and compatibility, and GitHub Releases plus the Homebrew Cask for
artifact availability.
