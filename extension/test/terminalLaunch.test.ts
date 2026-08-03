import assert from "node:assert/strict";
import test from "node:test";

import { LocalUnixSocketClient } from "../src/unixSocketClient";
import { createTerminalRegistration } from "../src/terminalRegistry";
import {
  CODEX_COVE_LAUNCH_ID,
  createCoveTerminalLaunch,
  readCoveLaunchId,
} from "../src/terminalLaunch";

const FIRST_UUID = "62245f58-e261-4306-9af8-42a1e7b1b176";
const SECOND_UUID = "4e1a2ee5-d282-47be-87ca-deb43f4de6c0";

test("injects a distinct opaque launch ID into every Cove terminal launch", () => {
  const first = createCoveTerminalLaunch(() => FIRST_UUID);
  const second = createCoveTerminalLaunch(() => SECOND_UUID);

  assert.equal(first.launchId, `cove-editor-${FIRST_UUID}`);
  assert.equal(first.options.env?.[CODEX_COVE_LAUNCH_ID], first.launchId);
  assert.equal(second.options.env?.[CODEX_COVE_LAUNCH_ID], second.launchId);
  assert.notEqual(first.launchId, second.launchId);
  assert.equal(first.launchId.includes("/"), false);
  assert.equal(first.launchId.includes("Codex Cove"), false);
});

test("uses the injected launch ID as the registered and published exact-focus ID", () => {
  const launch = createCoveTerminalLaunch(() => FIRST_UUID);
  const terminal = {
    name: "private terminal name",
    creationOptions: launch.options,
    show: () => undefined,
  } as const;
  const registration = createTerminalRegistration(
    terminal as never,
    4321,
  );
  const event = new LocalUnixSocketClient().createEvent(
    "terminal.registered",
    "localCli",
    "session-id",
    registration.launchId,
    "host-id",
    { terminalId: registration.terminalId },
  );

  assert.equal(readCoveLaunchId(terminal.creationOptions as never), launch.launchId);
  assert.equal(registration.launchId, launch.launchId);
  assert.equal(registration.terminalId, launch.launchId);
  assert.equal(event.launchId, registration.terminalId);
  assert.equal(event.payload.terminalId, registration.terminalId);
});

test("unrelated terminals receive distinct opaque focus IDs but no false launch attribution", () => {
  const terminal = {
    name: "project / secret",
    creationOptions: {},
    show: () => undefined,
  } as const;

  const first = createTerminalRegistration(terminal as never);
  const second = createTerminalRegistration(terminal as never);

  assert.equal(first.launchId, undefined);
  assert.equal(second.launchId, undefined);
  assert.notEqual(first.terminalId, second.terminalId);
  assert.match(first.terminalId, /^cove-terminal-[0-9a-f-]+$/);
  assert.equal(first.terminalId.includes("project"), false);
  assert.equal(first.terminalId.includes("private"), false);
});

test("rejects non-opaque inherited launch values", () => {
  const terminal = {
    name: "terminal",
    creationOptions: {
      env: {
        [CODEX_COVE_LAUNCH_ID]: "/Users/example/private-project",
      },
    },
    show: () => undefined,
  } as const;

  const registration = createTerminalRegistration(terminal as never);

  assert.equal(readCoveLaunchId(terminal.creationOptions as never), undefined);
  assert.equal(registration.launchId, undefined);
  assert.notEqual(registration.terminalId, terminal.creationOptions.env[CODEX_COVE_LAUNCH_ID]);
});

test("rejects an oversized launch value before registration can truncate it", () => {
  const oversized = `cove-${"a".repeat(300)}-b-c`;
  const terminal = {
    name: "terminal",
    creationOptions: {
      env: { [CODEX_COVE_LAUNCH_ID]: oversized },
    },
    show: () => undefined,
  } as const;

  const registration = createTerminalRegistration(terminal as never);

  assert.equal(readCoveLaunchId(terminal.creationOptions as never), undefined);
  assert.equal(registration.launchId, undefined);
  assert.notEqual(registration.terminalId, oversized.slice(0, 256));
});
