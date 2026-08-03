import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import test from "node:test";

const schemaDir = path.resolve(__dirname, "..", "..", "schemas");

function loadSchema(fileName: string): any {
  return JSON.parse(fs.readFileSync(path.join(schemaDir, fileName), "utf8"));
}

test("cove event schema uses the broker contract", () => {
  const schema = loadSchema("cove-event.v1.schema.json");

  assert.equal(schema.$id, "https://codex-cove.local/schemas/cove-event.v1.schema.json");
  assert.equal(schema.schemaVersion, 1);
  assert.deepEqual(schema.required, [
    "schemaVersion",
    "eventId",
    "kind",
    "timestamp",
    "source",
    "sessionId",
    "payload",
  ]);
  assert.deepEqual(schema.properties.source.enum, ["localCli", "codexDesktop", "remoteCli"]);
});

test("interactive request schema is available", () => {
  const schema = loadSchema("interactive-request.v1.schema.json");

  assert.equal(schema.$id, "https://codex-cove.local/schemas/interactive-request.v1.schema.json");
  assert.equal(schema.schemaVersion, 1);
  assert.deepEqual(schema.properties.kind.enum, ["approval", "question", "plan"]);
});

test("theme schema covers the expanded plan tokens", () => {
  const schema = loadSchema("theme-definition.v1.schema.json");

  assert.equal(schema.$id, "https://codex-cove.local/schemas/theme-definition.v1.schema.json");
  assert.equal(schema.schemaVersion, 1);
  assert.deepEqual(schema.properties.family.enum, ["nativeGlass", "retroTerminal", "minimalOLED"]);
  assert.deepEqual(schema.properties.palette.properties.colors.required, [
    "background",
    "surface",
    "primaryText",
    "mutedText",
    "accent",
    "working",
    "waitingApproval",
    "waitingInput",
    "compacting",
    "completed",
    "failed",
    "interrupted",
    "idle",
  ]);
  assert.deepEqual(schema.properties.animation.properties.easing.enum, [
    "linear",
    "easeIn",
    "easeOut",
    "easeInOut",
    "spring",
  ]);
  assert.equal(schema.properties.id.pattern.includes("\\.\\."), true);
  assert.equal(schema.properties.collapsedOpacity.minimum, 0.35);
  assert.equal(schema.properties.expandedOpacity.maximum, 1);
});
