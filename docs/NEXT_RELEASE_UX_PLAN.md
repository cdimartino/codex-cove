# Codex Cove Next Release UX Plan

**Proposed release:** 0.2.0  
**Release theme:** Glance, review, act  
**Audit date:** 2026-07-31  
**Method:** IxDF 7 UX factors, 5 usability characteristics, 5 interaction
dimensions, plus UI/UX Pro Max accessibility and SwiftUI checks

## Outcome

Keep Cove's distinctive notch resident and local-only privacy model. Rework the
expanded experience around one fast path:

```text
Glance at status -> Find attention item -> Review enough context -> Act safely
                                                        -> Jump to exact source
```

The next release should not be a broad visual rebrand. It should make task
triage, approvals, questions, and source jumps safer and easier to scan while
preserving the current character system, theme families, and native Settings
shell.

## Evidence and limits

This plan is based on:

- Live inspection of the packaged macOS app's collapsed island, expanded
  panel, Accessibility tree, and all seven Settings panes.
- Static review of the SwiftUI overlay, Settings, panel sizing, theme tokens,
  decision delivery, and current test suite.
- UI/UX Pro Max design-system, accessibility, motion, and SwiftUI queries.
- A green `make test` baseline: Swift smoke suite, 84 Rust tests, and 12
  TypeScript tests.

Important limits:

- No user interviews, analytics, or moderated task tests were available.
- Screen capture appeared to trigger privacy-safe content, so real task-title
  information scent could not be judged from the live panel.
- No approval or multi-question request was pending during live inspection;
  those surfaces were reviewed from source and fixtures.
- Keyboard focus behavior needs a controlled Full Keyboard Access and
  VoiceOver matrix; one live Tab pass was inconclusive.

## Provisional UX score

| Framework | Score | Main evidence |
|---|---:|---|
| 7 UX factors | 26/35 | Strong utility, trust, privacy, and visual identity; weaker findability and accessibility |
| 5 usability characteristics | 16/25 | Core tasks work; dense scanning and consequential one-click decisions lower efficiency and error tolerance |
| 5 interaction dimensions | 17/25 | Good native words, visuals, and feedback; constrained space and hidden actions weaken behavior |
| **Total** | **59/85 (69%)** | **Good product concept with material interaction debt** |

Factor detail:

| Factor | Score | Notes |
|---|---:|---|
| Useful | 5/5 | Unifies CLI, Desktop, and selected remote task attention in one local companion |
| Usable | 3/5 | Core actions exist, but narrow cards, nested scrolling, and hidden context actions add friction |
| Findable | 3/5 | Settings navigation is strong; overlay actions rely on icon buttons, menus, and context menus |
| Credible | 4/5 | Native shell, explicit privacy copy, public-interface boundaries, and broad component tests build trust |
| Desirable | 4/5 | Pixel residents and theme system are distinctive and coherent |
| Accessible | 3/5 | Good AX labels and motion/transparency handling; very small text and incomplete matrix remain |
| Valuable | 4/5 | Saves attention and source-switching cost without adding cloud state |

## Highest-priority findings

### P0: Make consequential approvals harder to trigger accidentally

Approval choices call `store.respond` immediately. The same path covers
`accept`, `acceptForSession`, `decline`, and `cancel`. A mistaken click can
authorize a command, file action, or broader session permission before the
user can recover.

Required change:

- Keep decline and cancel one-click.
- Require a review/confirmation step for `acceptForSession` and for sensitive
  command, file, or permission approvals.
- State scope in plain language: "Allow once" versus "Allow for this task."
- Keep the request visible until the local decision-frame write succeeds or
  fails; show sending, success, failure, retry, and "Open in Codex" fallback
  without layout movement. The public channel exposes no receiver ACK, so
  success must not be described as downstream processing acknowledgment.
- Give destructive or privilege-expanding actions distinct semantic styling,
  not accent color alone.

Acceptance:

- Zero accidental approvals across moderated approval tasks.
- Every approval exposes category, scope, consequence, and source before send.
- Double-clicking or repeated Return presses produce at most one decision.

### P0: Establish a legible, testable type and contrast floor

The overlay uses theme-scaled text from 8 to 13 points. Retro Terminal further
scales it to 96 percent. The current 272-point live panel is readable at normal
vision but dense; token metrics and usage details are especially small.

All 15 opaque theme token pairs pass static contrast checks. A conservative
simulation of the current Retro Terminal Ocean theme at 55 percent expanded
opacity over a white desktop yields about 3.6:1 for muted text, below the 4.5:1
target for small text. Material rendering can alter the actual result, so this
must become a rendered-state test rather than an assumption.

Required change:

- Define semantic text roles: title, body, metadata, badge, and data.
- Set 11 points as the minimum for non-decorative overlay text; prefer 12-13
  points for body and status content.
- Preserve theme personality through family and weight, not sub-10-point text.
- Enforce 4.5:1 for text and 3:1 for non-text UI across every built-in theme,
  opacity endpoint, increased-contrast state, and representative light/dark
  desktop backgrounds.
- Verify text growth without clipped controls or hidden actions.

Acceptance:

- No actionable or informative text below 11 points.
- Automated theme contrast test covers all 15 built-in themes.
- Largest supported text size remains operable in overlay focus mode and all
  Settings panes.

### P1: Separate glance width from action width

Expanded width currently equals collapsed notch width, which may be only 210
points. This preserves visual continuity but forces session metadata,
multi-question forms, approval context, and buttons into a status-sized
column.

Required change:

- Keep collapsed width tied to the physical notch.
- Give expanded queue a readable minimum width near 360-420 points, centered on
  the same screen anchor.
- Open selected approvals, questions, plans, and long task details in a focused
  440-520-point action surface when needed.
- Preserve a predictable Escape/back path to the queue and exact source jump.
- Test small and large notch widths, no-notch displays, and external displays.

Acceptance:

- Multi-question forms never truncate question text or choice labels.
- Primary and secondary actions never wrap into ambiguous order.
- Width transitions respect Reduce Motion and do not move the screen-top
  anchor.

### P1: Replace nested session scrolling with one attention-first queue

The outer expanded panel scrolls while the session list has its own
fixed-height 180-point scroller. Recent Events is enabled and expanded by
default. Live data showed repetitive `Hook Pretooluse` and `Hook Posttooluse`
rows competing with task cards.

Required change:

- Use one vertical scroll surface.
- Order sections: Needs Attention, Active, Recently Finished.
- Aggregate low-level hook events by task and turn; expose raw events only in a
  disclosure or diagnostics view.
- Default Recent Events to hidden or collapsed for new installs.
- Keep search and filter controls sticky only when the list is long.
- Show explicit status badge text and icon; do not depend on colored dots.

Acceptance:

- Wheel, trackpad, keyboard, and VoiceOver scrolling have one clear owner.
- A user can find the only waiting task in under 5 seconds with 20 mixed tasks.
- Repeated low-level hooks occupy at most one summarized row per task/turn.

### P1: Make top-level actions visible and predictable

Previous, next, open, and filter are icon-only in the narrow header. Pin,
remind, mark read, and dismiss exist only in each card's context menu. AX names,
help text, and keyboard shortcuts are present, but mouse discoverability is
weak.

Required change:

- Make the selected task's primary action a labeled "Open in Codex" button.
- Put pin, reminder, mark-read, and archive in a visible overflow menu on each
  row.
- Keep keyboard shortcuts and expose them in menus/tooltips.
- Provide clear hover, pressed, selected, disabled, and focus states.
- Ensure compact icon controls have a desktop-appropriate minimum hit area and
  spacing.

Acceptance:

- New users discover open, pin, remind, and archive without right-click
  coaching.
- Every interactive element has an AX name, visible focus state, and logical
  focus order.

### P2: Simplify expert settings without removing control

Settings already has a strong native sidebar and grouped forms. Main friction
comes from precision sliders, repeated event controls, and technical text
entry.

Required change:

- Pair timing sliders with editable steppers or numeric fields and a Reset to
  Default action.
- Replace comma-separated silenced projects with removable tokens and
  suggestions from known local projects.
- Present notification rules as an event-by-content matrix or compact event
  list with a privacy preview.
- Collapse per-event sound details; keep global sound state prominent.
- Clarify that Residents is an automatically assigned library, not a character
  picker, unless selection becomes supported.
- Add search to Settings only if moderated tests show sidebar findability is
  insufficient.

## Target information architecture

```text
Collapsed island
└── Expanded queue
    ├── Needs Attention
    │   ├── Approval
    │   └── Question
    ├── Active
    ├── Recently Finished
    └── More
        ├── Search and filters
        ├── Event diagnostics
        ├── Archived tasks
        └── Settings

Selected item
└── Focused action surface
    ├── Task identity and source
    ├── Context / consequence / scope
    ├── Response controls
    ├── Delivery state and recovery
    └── Open exact source
```

## Delivery plan

### Milestone 1: Research and baseline

- Create four canonical task scripts: find attention, jump to origin, answer a
  question, and review an approval.
- Run five moderated sessions spanning Codex CLI and Desktop users.
- Capture current time-on-task, completion, misclick, and confidence scores.
- Add deterministic UI fixture modes for empty, busy, approval, multi-question,
  privacy-redacted, stale-usage, and failure states.

Exit gate: findings validate or revise P0/P1 order before implementation.

### Milestone 2: Accessibility and decision safety

- Add semantic type roles and contrast enforcement.
- Add scoped approval review/confirmation.
- Stabilize sending, success, failure, retry, and fallback states.
- Add AX identifiers and tests for queue, cards, decisions, and Settings.

Exit gate: approval safety and accessibility acceptance criteria pass.

### Milestone 3: Queue and focused action surface

- Decouple expanded width from collapsed width.
- Replace nested scrolling with the attention-first queue.
- Add focused detail/action surface and explicit back/Escape behavior.
- Aggregate raw hook events and change new-install event defaults.

Exit gate: all four canonical tasks meet timing and completion targets.

### Milestone 4: Settings polish and release matrix

- Improve precision controls, project rules, notifications, and sounds.
- Run the full macOS matrix: Reduce Motion, Reduce Transparency, Increased
  Contrast, VoiceOver, Full Keyboard Access, light/dark desktop, multiple text
  sizes, external display, Spaces, fullscreen, and Stage Manager.
- Run component tests, package/install, doctor, and live CLI/Desktop flows.

Exit gate: no open P0/P1 UX defects and existing `make test` remains green.

## Success metrics

- At least 90 percent unassisted completion across the four canonical tasks.
- Median under 5 seconds to identify a waiting task.
- Median under 8 seconds to jump from Cove to the exact originating task.
- Zero wrong-scope approvals in moderated tests.
- 100 percent of text/theme/rendered-background combinations meet contrast
  targets.
- 100 percent keyboard and VoiceOver completion for core queue and decision
  flows.
- No nested scrolling in the expanded queue.

## Non-goals

- No cloud service, telemetry, account system, or transcript persistence.
- No support for non-Codex agent harnesses.
- No wholesale replacement of pixel residents or existing theme families.
- No protocol expansion unless a validated focused-action requirement cannot
  be met with current public events and decision channels.

## Likely code ownership

- Overlay layout and queue: `Sources/CodexCoveApp/CoveOverlayView.swift`
- Panel width and animation: `Sources/CodexCoveApp/CovePanelSizing.swift`,
  `Sources/CodexCoveApp/CoveOverlayController.swift`
- Decision safety and delivery state: `Sources/CodexCoveApp/CoveStore.swift`,
  `Sources/CoveCore/CoveDecision.swift`
- Settings polish: `Sources/CodexCoveApp/SettingsView.swift`,
  `Sources/CodexCoveApp/CoveSoundSettingsSection.swift`
- Theme and contrast rules: `Sources/CoveCore/CoveTheme.swift`,
  `Resources/Themes/`
- UI fixtures and acceptance coverage: `Fixtures/`, `Tests/`, plus a new macOS
  UI test target or deterministic screenshot harness
