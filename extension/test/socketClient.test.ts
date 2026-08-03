import assert from "node:assert/strict";
import test from "node:test";

import { LocalUnixSocketClient } from "../src/unixSocketClient";

test("gracefully no-ops when the socket path is absent", async () => {
  const client = new LocalUnixSocketClient("");
  const result = await client.publish(
    client.createEvent("status.reported", "localCli", "session-1", "launch-1", "host-1", { ok: true }),
  );

  assert.deepEqual(result, {
    attempted: false,
    connected: false,
    bytesWritten: 0,
  });
});

test("creates a routed event envelope", () => {
  const client = new LocalUnixSocketClient();
  const event = client.createEvent("terminal.registered", "localCli", "session-1", "launch-1", "host-1", {
    terminalId: "term-1",
  });

  assert.equal(event.schemaVersion, 1);
  assert.equal(event.kind, "terminal.registered");
  assert.equal(event.source, "localCli");
  assert.equal(event.sessionId, "session-1");
  assert.equal(event.launchId, "launch-1");
  assert.equal(event.hostId, "host-1");
  assert.equal(typeof event.eventId, "string");
  assert.equal(typeof event.timestamp, "string");
});
