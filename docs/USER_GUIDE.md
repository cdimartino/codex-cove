# User Guide

Codex Cove is a menu-bar app with a collapsed task island, an attention queue,
a focused action surface, and a reusable Workspace window. It observes Codex
through public app-server and hook interfaces and leaves the native Codex client
in charge whenever it cannot handle an action safely.

## Start a tracked task

### Terminal and iTerm2

Open Cove and launch native Codex normally for hook-based task status:

```sh
codex
```

When you want actionable approvals and questions inside Cove, opt in for that
session:

```sh
codex-cove launch [CODEX_ARGS...]
```

The launcher attempts to establish Cove's local app-server broker. If that
public transport is unavailable, it reports the fallback and executes native
Codex instead of blocking the session. Installation never replaces `codex`.

### VS Code and Cursor

After installing or upgrading Cove, reload editor windows so the bundled
extension activates. The Command Palette provides:

- **Cove: Create Routed Terminal** — creates a terminal with a launch identifier
  bound to that exact editor terminal. Run `codex-cove launch` there when you
  also want in-Cove approvals and questions.
- **Cove: Register Active Terminal** — registers an already-open terminal.
- **Cove: Focus Exact Registered Terminal** — exercises the extension's exact
  terminal focus path.
- **Cove: Show Status** and **Cove: Copy Status** — report content-free extension
  diagnostics.

The extension publishes a private per-window focus endpoint. When you jump from
Cove, the extension selects the terminal, Cove raises the uniquely marked
editor window, and the extension verifies that both the terminal and native
window are focused. Ambiguous or stale registrations fail closed.

### Codex Desktop

Cove reconciles loaded Desktop tasks through the public Codex app-server.
Opening one uses its exact `codex://threads/<id>` link. An explicit Workspace
Send can start an idle turn or steer the exact active turn; Cove never reads or
writes private Desktop storage and does not emulate unsupported actions.

## Read the island

The collapsed island is intentionally content-light. Each active, waiting, or
unread task gets a stable visual resident. Semantic callouts distinguish:

- active work;
- approval or user-input waits;
- blocked work;
- completed, failed, or interrupted work.

The island stays anchored at the top center and accommodates the physical notch
with side and lower lanes. When resident count exceeds the measured capacity,
residents rotate through the available route. With Reduce Motion enabled, that
motion pauses and Cove presents an accessible `+N` cue instead.

Incoming events do not force Cove open. Hover, click, the menu-bar command, or a
global shortcut begins an explicit interaction. Collapse and idle-hide delays
are configurable in **Settings → General**.

## Work the attention queue

The expanded queue uses one scroll surface ordered as:

1. **Needs Attention**
2. **Active**
3. **Recently Finished**
4. **More**

**More** contains search and filtering, aggregate local diagnostics, recoverable
archives, and a Settings entry. Select a card for full details. Long task
details, plans, questions, and approvals open in a wider focused surface;
`Escape` returns to the queue without creating another window.

When Codex exposes an assistant message for a task, its card summarizes that
latest output instead of a generic hook or tool-event label. Selecting the card
shows the full in-memory output. If output is unavailable, Cove keeps the
content-free task summary and exact **Open** action.

Available task actions depend on authoritative metadata:

- **Open** returns to the exact registered origin when one can be proved.
- **Pin** preserves priority across launches.
- **Remind** schedules one local follow-up.
- **Mark read** clears Cove's local unread state.
- **Archive** hides Cove's local task card.

Archiving is not a Codex mutation. It never archives or deletes the underlying
task, and the task remains available in Codex. Use **Archived Sessions** in the
menu-bar menu or **Settings → Sessions & Data** to restore a hidden card while
its local metadata remains available.

## Organize work in Workspace

For a complete control-by-control reference, see
[Workspace Help](WORKSPACE.md).

Choose **Open Workspace…** from the island's More section or the menu-bar menu.
The single resizable Workspace window restores its frame and gives Cove a Dock
and App-Switcher presence while it is open. Closing it returns Cove to its
menu-bar accessory behavior.

Workspace shows loaded Desktop threads and live routed or hook tasks, including
idle tasks that remain open. Closed successful tasks leave the Workspace.
Closed failed or interrupted tasks remain until you mark them read or archive
them. New tasks enter both the end of Grid's manual order and Board's Inbox.

Use the toolbar to switch views, search, filter, sort, open the prompt library,
or manage Board columns:

- **Grid** offers Manual, Attention, Recent Activity, Name, and Source sorts.
  Dragging is available only under Manual with no active search or filter.
  Move Earlier/Later commands provide keyboard and menu alternatives and can be
  undone.
- **Board** starts with Inbox, Doing, Review, and Blocked. Rename, reorder, add,
  or delete custom columns; deleting one moves its cards to Inbox. Column
  placement is a Cove workflow choice and never changes live Codex status.

Search matches visible aliases, live titles, tags, link labels, source/host,
status, and workflow column. Filters cover attention/status, source/host, tag,
column, unread, pinned, and whether Cove can prompt the task. Privacy redaction
removes protected fields from the visible UI, Accessibility tree, and search.

Selecting a card opens the right-side inspector without marking it read. It
contains the authoritative recursive subagent hierarchy, per-agent exact Open
action, latest memory-only output, existing approval/question controls,
Cove-only alias/tags/HTTP(S) links, reminders, pin/read/archive actions, and the
prompt composer. Parent links are accepted only within the same origin; missing
parents and cycles appear under **Unattached agents** rather than being guessed.

### Prompt library and Send

The prompt library is one searchable, manually ordered list with favorites and
recent use. Favorites and recent templates also appear in card menus. Choosing
a template copies its body into the selected card's editable composer; edits do
not change the saved template unless you explicitly save them.

Send is available only for a validated control route:

- an idle target starts a turn;
- an active target steers its exact observed turn;
- a pending approval or question must be resolved first.

If the task changes after preview, the route is stale, the active turn is
missing, or delivery is unsupported, Cove rejects the Send and offers exact
**Open in Codex**. An uncertain result is never retried automatically; inspect
the native task before deciding what to do next. Hook-only tasks remain
read-only in Cove.

Aliases, tags, links, Board columns, and saved templates are stored locally in
the private `workspace.json`. Unsaved composer text, prompts actually submitted,
outputs, approvals, commands, and transcripts remain memory-only. Links and
tags are manual context only; Cove stores no Jira, Slack, GitHub, Grafana, or
other connector credentials.

## Approvals and questions

Cove renders only approval choices advertised by an authoritative, explicitly
broker-routed request. Positive approval scopes use two steps: select a scope,
then confirm.
Decline and cancel remain distinct when Codex advertises them.

Question drafts are protected while editing. Navigation that would discard a
dirty draft asks for confirmation. A successful Cove delivery means the entire
bounded response frame was written to the validated private decision socket; it
does not prove that downstream Codex accepted or completed the action. If local
delivery fails, the focused surface keeps the request available for **Retry** or
**Open in Codex**.

Unsupported, stale, ambiguous, and auto-review requests are never guessed:

- unknown request methods stay native;
- Desktop questions and plan feedback open in Codex;
- hook-only permission events without an authoritative per-request reviewer stay
  native; and
- Codex's automated approval reviewer is filtered before task state, history,
  sounds, notifications, and persistence.

Ordinary task subagents remain visible.

## Return to the origin

Use a task's **Open** action or `Command-Shift-T` for the current task. Cove
chooses the narrowest exact adapter available:

- Codex Desktop task ID and deep link;
- VS Code/Cursor terminal ID plus a unique editor-window marker;
- tmux or WezTerm pane ID;
- Terminal/iTerm2 TTY;
- an opaque OSC title marker for an eligible local or remote terminal.

Cove does not fall back to whichever window happens to be frontmost. If the
stored location is closed, duplicated, stale, or otherwise ambiguous, it says
the exact origin is unavailable.

Terminal.app and iTerm2 restoration can trigger macOS Automation prompts.
VS Code/Cursor exact-window focus and global shortcuts require Accessibility
permission. See [Installation](INSTALLATION.md#macos-permissions).

## Global shortcuts

Enable **Global shortcuts** in **Settings → General** and grant Accessibility
permission to use:

| Shortcut | Action |
| --- | --- |
| `Command-Shift-O` | Toggle Cove visibility |
| `Command-Shift-E` | Toggle the expanded attention queue |
| `Command-Shift-T` | Jump to the most recently registered exact origin |

The menu-bar controls remain available when shortcuts are disabled.

## Menu-bar controls

The wave menu provides:

- **Show Cove**
- **Open Workspace…**
- **Collapse to Menu Bar** or **Restore Island**
- **Archived Sessions**, when local archives exist
- **Settings…**
- **Doctor…**
- **About Codex Cove**
- **Privacy: Auto / On / Off**
- **Mute Sounds**
- **Quit Codex Cove**

Minimal island mode and idle auto-hide keep a small themed status cue at the
menu-bar level instead of making Cove unreachable. Waiting approval and input
counts remain visible. Click the cue, use **Restore Island** in the menu, or use
the global visibility shortcut to restore the full island.

## Privacy and quiet behavior

Privacy has three settings:

- **On** redacts sensitive content in Cove surfaces and delivered banners.
- **Auto** can apply conservative redaction while a known conferencing or
  recording application is running when **Conservative capture privacy** is
  enabled. This is a safety heuristic, not proof that recording is active.
- **Off** allows the content choices configured for Cove's UI and notifications.

Privacy redaction also applies to Workspace rendering, Accessibility labels,
and search matching. Saved user-authored Workspace content remains in its local
private file until you edit or remove it; redaction prevents displaying or
matching it while privacy is active.

Workspace displays a content-free banner identifying whether redaction comes
from Privacy On, automatic capture-app protection, or the macOS lock state. Its
toolbar also offers **Follow System**, **Light**, and **Dark** appearances for
the full window without changing the island theme.

Locking the user session hides Cove and forces its locked privacy state.

Change the shared helper setting from a shell if needed:

```sh
codex-cove privacy auto
codex-cove privacy on
codex-cove privacy off
```

Quiet hours and project silence rules suppress matching sounds and
notifications, not approval or input cards. Focus quieting keeps Cove quiet
while another application is frontmost. Suggestions for project rules are
derived from in-memory task identities and are not saved until you choose one.

## Notifications, sounds, and reminders

Notifications are off until enabled and authorized. They are grouped by task
and turn; stale events from before the current Cove launch are not replayed as
new system banners. Configure each event's title, detail, project, source, and
host disclosure independently. Privacy redaction overrides those choices.

Sounds can use Cove's bundled 8-bit audio, Apple system sounds, or imported WAV,
MP3, AIFF, and M4A files up to 25 MB. Imports are copied into Cove's private
Application Support directory and can be removed from Settings. Global mute and
per-event volume/source controls are independent.

Reminders are one-shot local notifications. They do not create a Codex task,
calendar event, or cloud reminder.

## Themes and accessibility

**Settings → Appearance** includes three style families, five palettes, native
color-wheel controls for every theme color, a selectable solid fill or
two-color gradient, live unsaved preview, save/import/export for custom themes,
text scaling from 100% to 200%, independent collapsed/expanded tint opacity,
native backdrop blur, collapsed width, corner treatment, and expansion
animation. Theme documents are validated against Cove's versioned schema
before import. Privacy mode and macOS Reduce Transparency force an opaque
surface.

**Settings → Residents** selects and previews the Dungeon/D&D, Tech Creatures,
or Virus/Bacteria set. Cove still assigns an individual resident automatically
and stably within the selected set. Opening Settings collapses the island so it
does not compete with the configuration window.

Cove honors Reduce Motion, exposes named controls and status through the
Accessibility tree, maintains contrast floors, and reflows its queue and
Settings layouts at larger text sizes.

## Optional usage views

Account limits, profile token totals, and per-task token metrics are independently
optional. Cove uses only public `account/usage/read` and
`thread/tokenUsage/updated` responses. It does not scrape the Codex UI or read
private session files. Rate limits and token metrics are memory-only; stale or
missing data is labeled instead of estimated.

## Settings reference

For detailed behavior and hover-help equivalents for every pane, see
[Settings Help](SETTINGS.md).

| Pane | Main controls |
| --- | --- |
| Appearance | Text scale, style, palette, solid/gradient color-wheel themes, width, opacity, native blur, corners, animation |
| Residents | Character set, state preview, and resident library |
| General | Login launch, shortcuts, Glance mode, usage views, collapse, idle hide, reminder delay |
| Notifications | Authorization, event matrix, content disclosure, live preview |
| Sounds | Global playback and mute, event source, volume, preview, imports |
| Privacy & Quiet | Privacy, conservative capture mode, quiet hours, focus quieting, project rules |
| Sessions & Data | Minimal mode, archived-task restoration, local event diagnostics |

For failures and recovery steps, continue with [Troubleshooting](TROUBLESHOOTING.md).
