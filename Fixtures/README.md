# Protocol fixtures

These fixtures contain synthetic, non-sensitive Cove IPC examples. Swift,
Rust, and TypeScript tests should decode the same files so contract drift fails
the build.

- `cove-events.v1.jsonl`: launch, status, approval, question, and resolution
- `decision-frame.v1.json`: broker response for a command approval

No fixture represents private Codex storage. App-server messages use only
public JSON-RPC method and field names.
