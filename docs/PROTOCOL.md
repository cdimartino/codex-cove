# Codex Cove protocol contract

Codex Cove speaks two public protocols:

1. Codex app-server JSON-RPC, proxied without private Codex storage access.
2. Cove IPC, a small versioned envelope shared by the app, helper, remote
   relay, and editor extension.

This document describes the minimum contract tested against Codex CLI 0.147.0.
Unknown JSON object fields must be tolerated.

For Desktop reconciliation, Cove first probes the existing public
app-server proxy path with a short health deadline, then falls back to one
bounded `app-server --stdio` connection. A missing or wedged proxy cannot consume
the full Desktop discovery window. Startup, Workspace opening, connection
recovery, and a bounded cadence while the Workspace is visible page through
`thread/loaded/list`, then call `thread/read` with `includeTurns=false` for each
exact loaded thread on the same connection. With the public experimental API
capability enabled, Cove also
requests a bounded `thread/turns/list` summary for each exact thread and keeps
the latest non-empty `agentMessage` in memory for card and focused-detail
display. That request is optional and never blocks metadata hydration when an
older app-server does not support it. Requests may complete out of order; Cove
retains a bounded response map keyed by JSON-RPC ID so an early response for
another requested thread is not discarded. In the currently installed public
protocol shape, Codex Desktop
threads can appear with `sourceKinds: ["vscode"]`; Cove treats those rows as
Desktop-openable because their public deep link still targets the running Codex
app. `statusKinds: ["notLoaded"]` maps to an idle card, never an active
collapsed cue. Hook-triggered hydration batches queued thread IDs the same way.
Cove does not start, restart, or manage the durable app-server daemon when the
Codex Desktop app is already the primary running client. A separate persistent,
bounded public app-server client owns only turns explicitly started by Cove and
forwards their authoritative approval or question requests to the existing
decision UI. If reconciliation or control fails, the installed native Codex
client remains the visible fallback through `codex://threads/<thread-id>`.

## Operating boundaries

- Cove does not read or write private Codex session storage.
- Cove persists content-free session metadata plus explicitly user-saved
  Workspace aliases, tags, validated HTTP(S)/local-file artifacts and manual
  order, workflow state, and prompt templates. Favicon bytes remain memory-only.
  Unsaved and submitted prompts, commands, diffs, and responses remain
  memory-only.
- Unknown request methods and unsupported hook events are handed back to native
  Codex rather than being emulated.

## Cove event envelope

Local components send one JSON object and one trailing newline:

```json
{
  "schemaVersion": 1,
  "eventId": "unique-event-id",
  "kind": "thread.status",
  "timestamp": "2026-07-30T21:30:00.000Z",
  "source": "localCli",
  "sessionId": "thread-id-or-pending",
  "turnId": "optional-turn-id",
  "launchId": "optional-terminal-launch-id",
  "hostId": "optional-remote-host-id",
  "payload": {}
}
```

`source` is closed to `localCli`, `codexDesktop`, and `remoteCli`. Local Unix
sockets cap each line at 1 MiB. Remote transport prefixes the same JSON with an
unsigned four-byte big-endian length.

Every task-facing key is a `CoveSessionIdentity`: `source`, the selected remote
host scope when and only when `source=remoteCli`, and the opaque session ID.
Parent links, selection, pins, reminders, archives, token metrics, routing, and
SQLite metadata use that composite identity. An identical opaque session ID at
another source or remote host is a different task and is never merged.

The reducer ignores unknown event kinds. Supported state updates may arrive out
of order; only newer snapshots replace the visible card order or collapsed pill.

## CLI broker transport

For each routed interactive CLI launch, Cove creates three compact, opaque socket
names under its mode-`0700` runtime directory:

- `<16-hex>.b` is the broker socket passed to Codex as `unix://...`.
- `<16-hex>.d` is the private decision socket registered with the app.
- `<16-hex>.c` is the separate private start/steer control socket.

Compact names keep the complete path within macOS's Unix-domain `sun_path`
limit even when the Application Support path is long. The opaque token is a
stable SHA-256-derived value for that launch; the launch identifier itself is
not exposed in the filename.

Codex connects to the broker with an HTTP WebSocket upgrade on `/rpc`. Cove
terminates that local WebSocket and translates each text or binary JSON message
to one newline-delimited JSON-RPC object on the official app-server process's
standard input. App-server output is translated back to WebSocket text
messages. Ping, pong, and close frames are handled explicitly. Frames and
translated lines are capped at the configured maximum size. The default is
8 MiB, which accommodates the approximately 3.5 MiB `app/list` response seen
with Codex 0.146; reinstalling migrates the former 1 MiB default while keeping
other customized settings. The HTTP upgrade is also bounded; a client that
claims the socket and sends only a partial handshake cannot retain the broker
or its child app-server indefinitely.

The helper retains a raw JSON Lines path for protocol fixtures and compatibility
tests; that path applies the same inbound line cap before forwarding.
Production `codex-cove launch` sessions use WebSocket-over-Unix. A published
broker that is never claimed expires after a bounded five-minute window, while
the launcher itself uses its much shorter configured startup deadline before
falling back to native Codex.

Each spawned app-server owns a new process group. Client input EOF, output
worker failure, WebSocket closure, and broker errors terminate that complete
group and reap the app-server, including when an MCP child still holds a pipe
open. A normal app-server exit also triggers best-effort cleanup of remaining
group members. This keeps an oversized or otherwise failed Cove transport from
leaving the Codex TUI in a permanent startup state or reparenting MCP
descendants to the system process.

## Thread control

The Workspace chooses exactly one public operation from observed state:

- an idle task sends `turn/start`;
- an active task sends `turn/steer` with the exact current turn ID.

The request contains a composite target identity, a bounded non-empty input, a
unique client message ID, and the expected turn ID for steer. Composer text is
never included in a Cove event or durable metadata store. The UI disables Send
while the target has a pending approval or question.

A completed or idle hook-observed `localCli` target without a routed control
socket may use the app's runtime-only local app-server route. Before
`turn/start`, Cove requires an exact no-turn `thread/read` result with
`source=cli` and a safe state, then an exact `thread/resume` response with
`excludeTurns=true` and idle state. An active local target can use that route
only when the same client owns its exact observed turn ID.

For a routed CLI launch, the app writes one line to the launch's private control
socket:

```json
{
  "schemaVersion": 1,
  "launchId": "launch-id",
  "target": {"source": "localCli", "sessionId": "thread-id"},
  "operation": "steer",
  "expectedTurnId": "turn-id",
  "clientMessageId": "unique-message-id",
  "input": "memory-only user text"
}
```

The broker requires the exact launch and a session it observed, rechecks its
latest active-turn map, and translates only `start` or `steer` into a reserved
`cove-thread-control:` JSON-RPC ID. The reserved response is intercepted and
cannot be claimed by the native client. Unknown operations, wrong origins,
stale turns, duplicate IDs, frames over 32 KiB, disconnects, and timeouts fail
closed. Delivery timeout is `uncertain`; Cove never retries automatically.

Desktop control uses the same validated request model through a persistent
bounded public app-server process. It tracks the active turn between preview
and send and retains an in-memory decision bridge only for turns it owns.

## Broker decisions

Every explicitly broker-routed CLI launch has a private decision socket. A client answers a
server request with one JSON line:

```json
{
  "schemaVersion": 1,
  "launchId": "launch-id",
  "requestId": 42,
  "result": {
    "decision": "accept"
  }
}
```

`requestId` is scoped to the originating launch and, when present, the current
session. Concurrent launches are tracked independently and the first matching
response wins. Exactly one of `result` or `error` is present. Cove never
invents an option: UI actions come from a known response schema and the
request’s advertised choices.

The decision socket is write-only from Cove's perspective. A successful send
means Cove connected to the validated same-user private socket and wrote the
complete bounded frame before its deadline. The channel returns no receiver
ACK, so this does not prove that the broker or downstream Codex processing
accepted or completed the decision.

### Remote relay decisions

Cove opens one persistent SSH relay only for each alias explicitly enabled in
the helper configuration. The unattended connection keeps strict host-key
checking enabled and uses `BatchMode=yes`, `ConnectTimeout=10`, and bounded
server-alive probes, so authentication or a lost host cannot leave a hidden
interactive prompt waiting behind Cove.

The app wraps a remote decision in a control frame with a unique `controlId`:

```json
{
  "schemaVersion": 1,
  "type": "decision",
  "controlId": "unique-control-id",
  "decisionSocket": "/private/remote/runtime/decision.sock",
  "decision": { "schemaVersion": 1, "requestId": 42, "result": {} }
}
```

After validating the previously advertised socket and request, the remote
helper attempts the complete bounded write. It then returns one correlated
length-prefixed acknowledgement on relay stdout:

```json
{
  "schemaVersion": 1,
  "type": "decisionAck",
  "controlId": "unique-control-id",
  "status": "delivered"
}
```

`delivered` is emitted only after the remote decision-socket write and flush
succeed; `failed` means that delivery did not complete. A failed delivery does
not consume the advertised request, so the app retains its opaque route for a
retry. The app likewise retains the route after its bounded acknowledgement
timeout, but treats any later or unknown acknowledgement as stale. A relay
disconnect fails all pending sends and invalidates that relay generation's
routes. This acknowledgement confirms only the helper's socket write; as with
the local channel, it does not prove downstream Codex accepted or completed the
decision.

### Remote relay thread control

Remote start/steer uses a distinct `threadControl` frame. The Mac sends only an
opaque route advertised by the matching relay generation; the remote helper
resolves that route to its validated private control socket.

The frame is flat and follows `thread-control.v1.schema.json`: it carries the
schema and frame type, correlated control ID, advertised opaque route, launch,
composite target (including `remoteHostId`), operation, optional expected turn,
client message ID, and bounded memory-only input. It does not wrap those fields
inside a nested request object.

The correlated `threadControlAck` status is `accepted`, `rejected`, or
`uncertain`; accepted may include the new turn ID, while rejected may include a
closed rejection category such as `turnMismatch`. Relay disconnect invalidates
the generation and fails every pending control. An uncertain result is not safe
to retry until the user inspects the native Codex task.

Current direct request methods:

- `item/commandExecution/requestApproval`
- `item/fileChange/requestApproval`
- `item/permissions/requestApproval`
- `item/tool/requestUserInput`

Command and file decisions use `accept`, `acceptForSession`, `decline`, or
`cancel`. User-input responses have this shape:

```json
{
  "answers": {
    "question-id": {
      "answers": ["selected or typed answer"]
    }
  }
}
```

Unknown request methods, Desktop requests for turns Cove does not own, and plan
feedback remain in the native Codex client and appear as an Open in Codex
action. Current
`PermissionRequest` hooks remain entirely native because their public payload
does not identify the effective per-request reviewer. Cove answers only
authoritative approval requests observed through its app-server broker.

Codex's automated approval reviewer is internal control-plane work, not a Cove
task. Cove rejects hook events whose model is `codex-auto-review`, app-server
threads whose canonical source is `subAgent.other = guardian`, and
`item/autoApprovalReview/*` lifecycle traffic before state reduction. Current
`PermissionRequest` hook input does not identify its per-request reviewer, so
Cove emits no event for that ambiguous hook and leaves native Codex in control.
Authoritative broker-routed app-server approvals remain actionable. Rejected
traffic creates no session, request, event-history entry, persisted metadata,
sound, or notification. Normal spawned subagents remain visible.

## Terminal metadata

The only terminal-location data Cove persists is non-sensitive metadata needed
for exact jump restoration:

- adapter family, such as terminal, tmux, WezTerm, VS Code, or Cursor
- opaque location identifier
- host bundle identifier, when available
- tty identifier
- tmux pane identifier
- WezTerm pane identifier
- OSC marker identifier
- editor terminal identifier

Absolute socket paths are reconstructed at runtime and are never persisted.

## Hook bridge

The installed hook command reads one Codex hook object from standard input.
Common fields use Codex’s snake-case names: `session_id`, `thread_id`,
`turn_id`, `cwd`, `hook_event_name`, `model`, and `permission_mode`; camelCase
variants are accepted for compatibility. Global Desktop hooks are emitted as
`source=codexDesktop`, and Cove preserves the opaque Desktop thread and turn
identifiers in its own event envelope.

For `PermissionRequest`, a Cove allow response is:

```json
{
  "hookSpecificOutput": {
    "hookEventName": "PermissionRequest",
    "decision": {
      "behavior": "allow"
    }
  }
}
```

Denial changes `behavior` to `deny` and may add `message`. Missing Cove,
timeout, disconnect, malformed response, or unsupported event produces exit
status zero with empty standard output. Native Codex then owns the decision.

## App-server notifications

The state reducer recognizes at least:

- `thread/started`
- `thread/status/changed`
- `turn/started`
- `turn/completed`
- `turn/aborted`
- `turn/interrupted`
- `turn/failed`
- `item/started`
- `item/completed`
- `item/agentMessage/delta`
- `item/plan/delta`
- `thread/tokenUsage/updated`
- `account/rateLimits/updated`
- `serverRequest/resolved`

The broker preserves each JSON-RPC object while translating between the CLI's
WebSocket messages and app-server JSON Lines. It also emits a Cove event
containing the parsed message for in-memory rendering. Persistent state
excludes raw messages, prompts, commands, diffs, and responses.

The helper also emits `privacy.changed` when `codex-cove privacy auto|on|off`
updates shared privacy state. That event is consumed as a control signal only;
it does not create a transcript entry.

## Account usage polling

Cove's utility-priority account hydrator uses the public Codex app-server over
stdio. After the normal `initialize` / `initialized` handshake it requests:

- `account/rateLimits/read` for rate-limit windows and reset-card inventory.
- `account/usage/read` for the nullable Profile summary fields
  `lifetimeTokens`, `peakDailyTokens`, `longestRunningTurnSec`,
  `currentStreakDays`, and `longestStreakDays`, plus optional daily buckets.

Profile usage is independently optional. A rejected, unavailable, oversized,
or timed-out `account/usage/read` response never discards a successful
rate-limit response. Cove labels the Profile section unavailable or stale and
does not substitute zeroes. Daily buckets remain transient in memory. Weekly
and cumulative views are derived locally from the supplied rolling 52-week
daily window; cumulative means that displayed window, not lifetime usage.
