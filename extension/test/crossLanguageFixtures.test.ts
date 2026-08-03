import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import test from "node:test";

import type { BrokerDecisionResponse, CoveEvent } from "../src/models";

const fixtureRoot = path.resolve(__dirname, "..", "..", "..", "Fixtures");

test("shared CoveEvent fixtures match the TypeScript contract", () => {
  const events = fs
    .readFileSync(path.join(fixtureRoot, "cove-events.v1.jsonl"), "utf8")
    .trim()
    .split("\n")
    .map((line) => JSON.parse(line) as CoveEvent);

  assert.equal(events.length, 6);
  assert.deepEqual(
    events.map((event) => event.kind),
    [
      "launch",
      "appServer",
      "approvalRequested",
      "questionRequested",
      "appServer",
      "hook",
    ],
  );
  assert.equal(events[5].source, "codexDesktop");
  assert.equal(events[5].sessionId, "thread-desktop");
  for (const event of events) {
    assert.equal(event.schemaVersion, 1);
    assert.equal(typeof event.eventId, "string");
    assert.equal(typeof event.timestamp, "string");
    assert.equal(typeof event.sessionId, "string");
    assert.equal(typeof event.payload, "object");
  }
});

test("shared decision fixture uses requestId and exactly one response branch", () => {
  const frame = JSON.parse(
    fs.readFileSync(path.join(fixtureRoot, "decision-frame.v1.json"), "utf8"),
  ) as BrokerDecisionResponse;

  assert.equal(frame.schemaVersion, 1);
  assert.equal(frame.requestId, 42);
  assert.deepEqual(frame.result, { decision: "accept" });
  assert.equal(frame.error, undefined);
});
