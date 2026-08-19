# Workspace Help

Workspace is Codex Cove's primary full-window view for supervising many Codex
tasks at once. It uses the same live state, privacy rules, approvals, remote
relays, and exact-origin navigation as the island, which remains an ambient
attention companion.

## Open and close Workspace

Direct launch, Dock reopen, notification click, and a queue-row click open
Workspace. You can also open it from:

- the menu-bar wave menu: **Open Workspace…**;
- the island queue's **More** section: **Open Workspace…**; or
- `Command-Shift-W` while Codex Cove is active.

Cove keeps one reusable Workspace window. Opening it again brings the existing
window forward instead of creating another copy. The window is resizable and
restores its previous frame.

While Workspace is open, Cove appears in the Dock and App Switcher and exposes
normal application menus. Closing Workspace returns Cove to its menu-bar
accessory behavior. Closing Workspace does not close, archive, or interrupt any
Codex task.

## Which tasks appear

Workspace shows:

- tasks currently loaded in Codex Desktop;
- live local CLI tasks observed through Cove's broker or public hooks; and
- live tasks from configured remote Cove relays.

Authoritatively loaded or live tasks are enrolled in Workspace even while its
window is closed. Once enrolled, a task stays visible until you archive it.
When Cove no longer has current task state, it is marked **Retained** instead
of being shown with a guessed status or activity time.

New tasks enter the end of Grid's saved manual order and Board's **Inbox**.
Aliases, tags, artifacts, order, and Board placement remain available if the same
exact task identity is seen again.

## Toolbar

The toolbar provides:

- **Grid / Board** — switch the visible organization without changing tasks;
- **Appearance** — follow the macOS appearance or force Light or Dark for the
  full Workspace window;
- **Search** — match visible names, tags, links, origin, status, and column;
- **Sort** — Manual, Attention, Recent Activity, Name, or Source;
- **Filters** — attention, status, source, host, tag, column, unread, pinned,
  and controllability;
- **Prompt Library** — manage and use saved templates;
- **Columns** — manage Board columns while Board is selected; and
- **Help** — open this guide.

Privacy redaction removes protected names, origins, tags, links, column names,
and templates from rendering, Accessibility, and search. Status remains visible
so the dashboard still communicates attention safely.

When redaction is active, a banner explains the reason: Privacy Mode is On,
automatic capture-app protection is active, or Cove is waiting for macOS to
confirm that the user session is unlocked. Opening Workspace is an explicit
foreground action, so it also clears a stale lock state after macOS has made the
session interactive.

## Appearance

Choose **Follow System**, **Light**, or **Dark** from the Workspace toolbar or
**Settings → Appearance → Workspace window**. The choice is durable and affects
only the full Workspace window. **Follow System** updates with the current macOS
appearance. The island continues to use its separately configured Cove theme.
This content-free preference is stored with Cove's normal settings, not with
task metadata or saved prompt content.

## Grid

Grid lays out parent task cards responsively as the window resizes. A card shows
its Cove alias or current upstream title, status, source and remote host, last
activity, unread and pin state, tags and link badges, and the number of
descendant agents needing attention. It also shows a bounded excerpt of the
newest parent-or-descendant agent output and updates that excerpt as public
app-server output deltas arrive. Output excerpts are memory-only and disappear
under privacy redaction.

Each card can show its task's stably assigned resident. Use **Settings →
Residents** to hide card residents or pause their active-state movement.
macOS Reduce Motion always pauses that movement.

Manual ordering can change only when:

1. **Sort** is **Manual**;
2. search is empty; and
3. no filter is active.

Drag a card before another card, or use **Move Earlier** and **Move Later** in
its context menu. The keyboard equivalents are `Command-Option-[` and
`Command-Option-]`. Use normal macOS Undo to reverse a reorder. Other sorts,
searches, and filters are temporary projections and never rewrite manual order.

## Board

Board starts with **Inbox**, **Doing**, **Review**, and **Blocked**. Workflow
placement is Cove-only: moving a card never changes its live Codex status.

Move a card by:

- dragging it to another column;
- choosing **Move to Column** in its context menu; or
- choosing **Board column** in the task inspector.

Use **Columns** in the toolbar to add, rename, or reorder up to 32 columns.
**Inbox** cannot be deleted. Deleting any other column moves its cards to
Inbox.

## Cards and the inspector

Select a card to open the right-side inspector. Selection does not mark the task
read. The inspector contains:

- the task's current status and exact origin;
- the latest bounded assistant output held in memory;
- a recursive agent hierarchy;
- any authoritative Cove approval or question controls;
- Cove-only alias, tags, links, and Board placement;
- the prompt composer; and
- Open, Pin, Mark Read, Remind Me, and Archive actions.

**Open in Codex** targets the exact originating task. If the origin is stale,
closed, unsupported, or ambiguous, Cove reports the failure instead of opening
an unrelated window.

### Agent hierarchy

Cove attaches an agent only when Codex provides an authoritative
`parentThreadId` within the same local, Desktop, or selected remote origin. It
never infers a parent from similar names, output, or timing.

Each hierarchy row shows the agent's status. Select the row to inspect, start,
or steer that exact agent; the owning task card remains highlighted and the
full hierarchy stays available. **Open in Codex** first targets the exact
selected agent. If it has no independent location, Cove reports that failure
and may offer a separately labeled **Open Parent Location** action for a
verified same-origin parent. Missing parents, conflicting parent claims, and
cycles remain under **Unattached agents** rather than being guessed.

## Workspace details

### Alias

An alias changes only the name shown by Cove. It does not rename the upstream
Codex task. Clear the field to return to the current upstream title.

### Tags

Enter comma-separated tags and press Return. Tags are deduplicated
case-insensitively and sorted for stable display. A card can hold up to 32 tags,
each up to 64 UTF-8 bytes.

### Artifacts

Artifacts are parent-task context. The inspector lists every attached web link,
local file, and folder with its real host or path plus **Open** and **Remove**.
Edit a saved label in place; press Return or move focus to save, or Escape to
restore the saved value. Drag rows or use **Move Earlier**/**Move Later** to
change the single order shared by the parent and its agents. Reordering is
undoable.
Enter a short label and an absolute `http://` or `https://` URL, then choose
**Add Link**, or choose **Add File or Folder…** for local plans such as an
`EXECPLAN.md`. URLs with embedded user names or passwords, remote file URLs,
packages, apps, scripts, executables, and special files are rejected.

Saved web links attempt to display the host's HTTPS `/favicon.ico` in the
inspector and card badges. Cove sends no cookies, credentials, saved path, query,
or fragment, follows no redirects, and keeps successful icons only in bounded
process memory. Missing, invalid, local/private-host, or oversized icons retain
the generic link symbol. Suggestions never trigger a favicon request before you
add them. Showing cards or the artifact inspector can therefore contact the
hosts of links you explicitly saved.

Suggestions are confirmation-only: Cove looks only at bounded live assistant
output from the selected parent and its authoritative agents. It never scans a
repository, transcript, prompt, or private Codex storage, and it never opens or
saves a suggestion until you choose **Add**. Cove stores no Jira, Confluence,
Slack, GitHub, GitLab, Gerrit, Grafana, or other connector credentials.

## Prompt library

The prompt library is a searchable, manually ordered list of up to 500 saved
templates. Each template has a name, body, favorite flag, and last-used time.

- **Add Template** saves a new template.
- Select a row, edit it, then choose **Save Changes** to update it.
- **Use in Composer** copies the selected saved body into the selected task's
  memory-only composer and closes the library.
- Arrow buttons change manual template order.
- **Delete** removes the selected saved template.

Favorites and recently used templates appear first in card context menus and
the inspector's **Insert Template** menu. Using a template copies its saved
body. Composer edits never modify the template unless you explicitly save
those edits in the library.

Template names are limited to 128 UTF-8 bytes and bodies to 32 KiB.

## Start and steer

The composer chooses an operation from authoritative task state:

- an idle target uses **Start Turn**; and
- an active target uses **Steer Active Turn** with its exact current turn ID.

Choose the button, review the confirmation, and choose **Send**. Cove sends the
prompt once. It does not retry automatically.

Send is unavailable when:

- an approval or question is pending for the task;
- the route or exact origin is stale;
- an active turn lacks its authoritative turn ID;
- the server does not support the required public operation; or
- another send is already in progress.

For a local CLI task observed only through hooks, Cove first uses the public
local Codex app-server to read that exact thread without resuming it. Spawned
agents are accepted only when their bounded, non-cyclic parent chain ends at an
exact CLI root. Cove also reads the bounded turn summary: idle/completed state
enables **Start Turn**, while active state enables **Steer Active Turn** only
with the exact current turn ID. Before delivery it repeats the same source and
turn checks. Missing, conflicting, review/compact, or stale provenance remains
unavailable.

Cove rechecks the target, operation, route, turn ID, pending requests, and
composer text at confirmation time. If anything changed, Send fails visibly.
The public Codex `turn/start` operation has no atomic idle precondition, so a
different client starting that same task in the final delivery race can cause
Codex itself to treat the submitted input as a steer.
An uncertain result means the transport may have delivered the prompt; inspect
the task in Codex before deciding whether to try again.

## Read, pin, remind, and archive

- **Mark Read** acknowledges Cove's unread state without removing a retained
  task from Workspace.
- **Pin** affects Cove ordering only.
- **Remind Me** schedules one local, one-shot notification using the delay from
  **Settings → General**.
- **Archive** hides the task locally in Cove. It does not archive or delete the
  Codex task. Restore it from the menu-bar menu or **Settings → Sessions &
  Data**.

## Privacy and local storage

The following explicitly user-authored Workspace content is durable:

- aliases, tags, and validated web/local artifacts;
- Grid order, Board columns, and assignments;
- saved prompt templates; and
- the last selected Grid or Board view.

It is stored in
`~/Library/Application Support/Codex Cove/workspace.json`, a versioned,
atomically replaced file restricted to the current user with mode `0600`.

Unsaved composer text, prompts submitted to Codex, upstream task titles,
assistant output, approvals, questions, commands, diffs, and transcripts are
not written to Workspace storage, Cove diagnostics, logs, notifications,
fixtures, or public artifacts.

## Troubleshooting

### A Desktop task is missing

Confirm it is loaded in Codex Desktop, then reopen Workspace or wait for the
visible-window reconciliation. Update Codex CLI if Doctor reports a version
older than 0.147.0.

### Send is disabled

Read the explanation beneath the composer. Resolve any pending request first.
If Cove lacks the exact route or active turn ID, use **Open in Codex**.

### A card cannot be dragged in Grid

Choose **Manual** sort, clear search, and clear all filters. Keyboard and context
menu reorder actions follow the same rule.

### Workspace says details are hidden while Privacy is Off

Privacy Off permits content only after Cove knows the macOS session is
unlocked. Bring Workspace forward again; that explicit foreground action clears
a stale lock state. If the banner instead names automatic capture-app privacy,
choose Privacy Off or disable **Conservative capture-app privacy** in Settings.

### A column disappeared

Deleting a custom column moves its assignments to Inbox. It does not delete
cards or Codex tasks.

### Saved Workspace content cannot load

Cove leaves an invalid, unsafe, corrupt, or newer-schema file untouched and
shows a local warning. Review filesystem ownership and permissions before
replacing it. Never work around a symlink or unsafe parent-directory warning.

For installation, integration, and recovery details, continue with
[Troubleshooting](TROUBLESHOOTING.md).
