import assert from "node:assert/strict";
import test from "node:test";

import {
  type ExtensionGlobalState,
  readOrCreateOpaqueStateId,
  sanitizeLegacyGlobalState,
} from "../src/privacyState";
import { createSessionMarker } from "../src/sessionMarkers";
import { createTerminalRegistration } from "../src/terminalRegistry";
import { CODEX_COVE_LAUNCH_ID } from "../src/terminalLaunch";

class FakeGlobalState implements ExtensionGlobalState {
  readonly values = new Map<string, unknown>();
  readonly updates: Array<{ key: string; value: unknown }> = [];

  constructor(initial: Record<string, unknown>) {
    for (const [key, value] of Object.entries(initial)) {
      this.values.set(key, value);
    }
  }

  get<T>(key: string): T | undefined {
    return this.values.get(key) as T | undefined;
  }

  keys(): readonly string[] {
    return [...this.values.keys()];
  }

  async update(key: string, value: unknown): Promise<void> {
    this.updates.push({ key, value });
    if (value === undefined) {
      this.values.delete(key);
    } else {
      this.values.set(key, value);
    }
  }
}

test("removes legacy terminal and transcript metadata instead of repersisting it", async () => {
  const state = new FakeGlobalState({
    "cove.sessionMarkers": [{
      markerId: "legacy-marker",
      terminalId: "legacy-terminal",
      label: "secret session name",
      commandLine: "/bin/zsh --cwd /Users/example/private-project",
    }],
    "cove.lastPrompt": "private prompt",
    "cove.lastResponse": "private response",
    "cove.lastCommand": "private command",
    "cove.lastDiff": "private diff",
    "cove.launchId": "one-global-launch-id",
    "cove.sessionId": "9ea91256-4b7b-44ef-bdf8-f9f74e10b464",
    "unrelated.setting": "preserved",
  });

  await sanitizeLegacyGlobalState(state);

  assert.deepEqual(Object.fromEntries(state.values), {
    "cove.sessionId": "9ea91256-4b7b-44ef-bdf8-f9f74e10b464",
    "unrelated.setting": "preserved",
  });
  assert.equal(JSON.stringify(Object.fromEntries(state.values)).includes("private"), false);
  assert.equal(state.updates.every((update) => update.value === undefined), true);
});

test("replaces a non-opaque legacy session value with only an opaque identifier", async () => {
  const state = new FakeGlobalState({
    "cove.sessionId": "/Users/example/private-project",
  });
  const uuid = "1609ac36-dd17-4f84-a2c8-c3fed4dcde24";

  const sessionId = await readOrCreateOpaqueStateId(state, "cove.sessionId", () => uuid);

  assert.equal(sessionId, uuid);
  assert.deepEqual(Object.fromEntries(state.values), {
    "cove.sessionId": uuid,
  });
});

test("preserves an existing opaque session identifier without rewriting state", async () => {
  const sessionId = "9ea91256-4b7b-44ef-bdf8-f9f74e10b464";
  const state = new FakeGlobalState({ "cove.sessionId": sessionId });

  assert.equal(await readOrCreateOpaqueStateId(state, "cove.sessionId"), sessionId);
  assert.deepEqual(state.updates, []);
});

test("in-memory markers contain no sensitive terminal metadata", () => {
  const registration = createTerminalRegistration({
    name: "private terminal name",
    creationOptions: {
      env: {
        COVE_SESSION_NAME: "private session name",
        [CODEX_COVE_LAUNCH_ID]: "cove-editor-62245f58-e261-4306-9af8-42a1e7b1b176",
      },
      cwd: "/Users/example/private-project",
      shellPath: "/bin/zsh",
    },
  } as never);
  const marker = createSessionMarker(registration);

  assert.deepEqual(marker, {
    markerId: "cove-editor-62245f58-e261-4306-9af8-42a1e7b1b176",
    terminalId: "cove-editor-62245f58-e261-4306-9af8-42a1e7b1b176",
    registeredAt: registration.createdAt,
  });
  assert.equal(registration.terminalName, "Integrated Terminal");
  const serialized = JSON.stringify({ registration, marker });
  assert.equal(serialized.includes("private"), false);
  assert.equal(serialized.includes("/bin/zsh"), false);
  assert.equal(serialized.includes("private-project"), false);
});
