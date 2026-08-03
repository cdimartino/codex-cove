import assert from "node:assert/strict";
import test from "node:test";

import { TerminalRegistry, createTerminalRegistration } from "../src/terminalRegistry";
import {
  normalizeEditorTerminalIdentifier,
  resolveEditorHostIdentity,
} from "../src/models";

test("reveals the exact registered terminal", () => {
  let shown = false;
  let preserveFocus: boolean | undefined;
  const terminal = {
    name: "backend",
    show: (value?: boolean) => {
      shown = true;
      preserveFocus = value;
    },
    creationOptions: {},
  } as const;

  const registry = new TerminalRegistry();
  const registration = createTerminalRegistration(terminal as never);
  registry.register(terminal as never, registration);

  assert.equal(registry.reveal(registration.terminalId)?.registration.terminalId, registration.terminalId);
  assert.equal(shown, true);
  assert.equal(preserveFocus, false);
});

test("returns undefined when no registered terminal exists", () => {
  const registry = new TerminalRegistry();
  assert.equal(registry.reveal("missing"), undefined);
});

test("unregisters a closed terminal", () => {
  const terminal = {
    name: "closed",
    show: () => undefined,
    creationOptions: {},
  } as const;
  const registry = new TerminalRegistry();
  const registration = createTerminalRegistration(terminal as never);
  registry.register(terminal as never, registration);

  registry.unregister(terminal as never);

  assert.equal(registry.get(registration.terminalId), undefined);
});

test("publishes explicit VS Code and Cursor host identities", () => {
  assert.deepEqual(resolveEditorHostIdentity("Visual Studio Code", "vscode"), {
    applicationName: "Visual Studio Code",
    bundleIdentifier: "com.microsoft.VSCode",
    uriScheme: "vscode",
  });
  assert.deepEqual(resolveEditorHostIdentity("Cursor", "cursor"), {
    applicationName: "Cursor",
    bundleIdentifier: "com.todesktop.230313mzl4w4u92",
    uriScheme: "cursor",
  });
});

test("normalizes persisted editor terminal identifiers without paths", () => {
  const identifier = normalizeEditorTerminalIdentifier(
    "backend / shell-2026-07-30T12:00:00Z-a1",
  );
  assert.equal(identifier, "backend___shell-2026-07-30T12:00:00Z-a1");
  assert.equal(identifier.includes("/"), false);
});
