# Settings Help

Open **Settings…** from the menu-bar wave menu, the island queue's **More**
section, or `Command-,`. Cove keeps one reusable resizable Settings window.
Opening Settings collapses the island so configuration does not compete with
the form.

Each Settings pane has a help button in its heading. Hover any non-obvious
control for a concise explanation.

## Appearance

### Workspace window

**Appearance** chooses **Follow System**, **Light**, or **Dark** for the full
Workspace window. Follow System is the default and tracks macOS. This setting
does not change the island's style family, palette, or custom theme.

### Text

**Text size** scales Cove and Settings from 100% to 200%. The slider makes quick
changes; the number field and stepper provide exact keyboard control. Layouts
reflow as the value grows.

### Theme

- **Style family** chooses Native Glass, Retro Terminal, or Minimal OLED.
- **Palette** chooses a built-in color set for that family.
- **Custom theme** replaces the built-in selection with a locally saved theme.
- **Import Theme…** validates and copies a theme JSON document.
- **Export Selected…** writes the selected theme as portable JSON.
- **Remove Custom Theme** deletes only the selected local custom theme.

### Custom theme colors

Edit the theme name, solid/gradient fill, semantic text and task-state colors,
border, and shadow. Changes preview live but remain unsaved until **Save Custom
Theme**. **Reset from Selected** discards the current draft.

Cove reports contrast violations before save. Privacy and macOS Reduce
Transparency can still force an opaque presentation.

### Surface

- **Opacity preset** sets coordinated transparency defaults.
- **Collapsed width** matches the physical notch or a preferred menu-bar width.
- **Straight top edge** removes rounding along the screen edge.
- **Collapsed / Expanded opacity** set exact tint opacity for each surface.
- **Blur** chooses the native macOS material behind the tint.
- **Animate expansion and hiding** controls the slide transition.
- **Slide duration** controls that transition's timing; Reduce Motion overrides
  it.

## Residents

**Character set** chooses Dungeon/D&D, Tech Creatures, or Virus/Bacteria.
**Task state** previews the full selected family in one status. Cove assigns an
individual resident automatically and stably; residents are not selected
manually per task.

**Show residents on Workspace cards** controls whether Grid and Board cards
include that task's resident. **Animate active card residents** independently
pauses movement on those cards.

Active residents animate with character-specific activities. Attention and
terminal states use static icon-integrated callouts. Reduce Motion disables
nonessential animation.

## General

### App

- **Launch at login** registers Cove as a standard current-user macOS login
  item.
- **Enable global shortcuts** enables system-wide Cove shortcuts. macOS
  Accessibility permission is required.
- **Glance mode** keeps the island collapsed unless you explicitly open it.

### Usage

- **Show account usage** displays public Codex rate-limit windows.
- **Show usage remaining** switches between used and remaining presentation.
- **Show profile token usage** displays public account token totals when
  available.
- **Show per-task token metrics** displays memory-only values from public live
  task events.

Cove never scrapes the Codex UI or private session storage. Missing and stale
usage values are labeled instead of estimated.

### Interaction

- **Hover delay** controls how long pointer hover waits before expanding Cove.
- **Collapse after hover leaves** starts only after pointer and keyboard focus
  both leave.
- **Idle auto-hide** hides an idle island after the selected interval; zero
  disables hiding.
- **Reset Interaction Defaults** resets only those three timings.
- **One-shot follow-up** chooses the delay used by **Remind Me**.

Events and requests do not expand the island automatically.

## Notifications

### System banners

**Show Codex Cove notifications** requests native macOS notification delivery.
System authorization can still deny delivery. Cove drops events older than the
current app launch rather than replaying stale banners.

### Event and content

For each event, choose whether a banner is enabled and whether it may include
task title, event detail, project, source, and remote host. Select an event name
to update **Live Preview**.

Privacy redaction overrides every content choice. Commands, paths, prompts,
answers, and diffs are excluded unless the source event explicitly exposes
them as selected event detail.

## Sounds

- **Play event sounds** enables the sound system.
- **Mute all sounds** temporarily silences all events without replacing their
  individual choices.
- **Global volume** scales every enabled sound.
- Expand an event to enable it, choose a source, preview it, and set per-event
  volume.
- **Import Sound…** copies a WAV, MP3, AIFF, or M4A file up to 25 MB into
  Cove's private local storage.
- **Remove Imported Sound** removes a copied file from that library.

Effective volume is global volume multiplied by the event volume. Quiet and
privacy policies can suppress playback without rewriting these choices.

## Privacy and Quiet

### Privacy

- **On** always redacts sensitive task content.
- **Auto** applies the configured automatic privacy policy.
- **Off** allows configured content to render when the Mac is unlocked.
- **Conservative capture-app privacy** makes Auto redact while a known
  conferencing or recording application is running. This is a conservative
  heuristic, not proof that recording is active.

Privacy affects the island, Workspace, Accessibility labels, search, and
notifications. It does not delete saved local aliases, tags, links, columns, or
templates.

Workspace shows an inline banner that distinguishes explicit Privacy On,
automatic capture-app privacy, and the temporary lock-screen privacy state.

### Quiet hours

Enable quiet hours and choose start/end times. The interval may cross midnight;
matching sounds and banners are suppressed while approval and question cards
remain visible.

### Focus

**Follow focused app** keeps Cove quiet while another application is frontmost.
Project silence rules suppress matching sounds and banners. Press Return or
comma to add a rule. Live suggestions are memory-only and are not saved unless
you choose them.

## Sessions and Data

### Island

**Minimal island / menu-bar mode** replaces the full island with a small status
cue that omits task text. Attention counts remain available. Restore the full
island from the menu bar.

**Expand / Collapse overlay** changes only the current queue presentation and
is disabled while minimal mode is active.

### Archived tasks

Archive is Cove-only. Restore one task or all tasks from **Review Archived
Tasks**. Restoring does not change the upstream Codex archive state.

### Diagnostics

**Clear recent events** removes only Cove's memory-only recent event list. It
does not delete tasks, transcripts, saved Workspace content, or persisted
session metadata.

## Menu-bar quick settings

The menu-bar wave menu keeps these settings available without opening the
window:

- Privacy Auto, On, or Off;
- Mute Sounds;
- minimal/full island restoration;
- archived-task restoration; and
- Help, Doctor, and About.

For Workspace-specific controls, see [Workspace Help](WORKSPACE.md). For
integration failures and recovery, see [Troubleshooting](TROUBLESHOOTING.md).
