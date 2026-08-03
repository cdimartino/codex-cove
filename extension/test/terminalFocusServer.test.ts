import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as net from "node:net";
import * as os from "node:os";
import * as path from "node:path";
import test from "node:test";

import {
  createEditorWindowFocusMarker,
  createFocusSocketIdentifier,
  EditorWindowTerminalFocuser,
  type TerminalFocusPhase,
  TerminalFocusServer,
} from "../src/terminalFocusServer";
import { TerminalRegistry, createTerminalRegistration } from "../src/terminalRegistry";

interface FocusResponse {
  readonly ok: boolean;
  readonly terminalSelected?: boolean;
  readonly windowFocused?: boolean;
  readonly error?: string;
}

async function requestFocus(
  socketPath: string,
  terminalId: string,
  phase?: TerminalFocusPhase,
): Promise<FocusResponse> {
  const response = await new Promise<string>((resolve, reject) => {
    const client = net.createConnection(socketPath);
    let received = "";
    client.on("connect", () => {
      client.write(`${JSON.stringify({ terminalId, phase })}\n`);
    });
    client.on("data", (chunk) => {
      received += chunk.toString("utf8");
    });
    client.on("end", () => resolve(received));
    client.on("error", reject);
  });
  return JSON.parse(response) as FocusResponse;
}

test("allocates a distinct opaque focus socket identifier per editor window", () => {
  const first = createFocusSocketIdentifier(
    () => "62245f58-e261-4306-9af8-42a1e7b1b176",
  );
  const second = createFocusSocketIdentifier(
    () => "4e1a2ee5-d282-47be-87ca-deb43f4de6c0",
  );

  assert.notEqual(first, second);
  assert.match(first, /^[0-9a-f]{12}$/);
  assert.match(second, /^[0-9a-f]{12}$/);
});

test("derives a content-free accessibility marker from the focus socket identifier", () => {
  assert.equal(
    createEditorWindowFocusMarker("62245f58e261"),
    "Codex Cove editor window 62245f58e261",
  );
  assert.throws(() => createEditorWindowFocusMarker("not-an-opaque-id"));
});

test("focus server selects the exact terminal over a private socket", async () => {
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), "codex-cove-focus-"));
  const socketPath = path.join(temporary, "focus.sock");
  let shown = false;
  let preserveFocus: boolean | undefined;
  let activeTerminal: unknown;
  const terminal = {
    name: "editor-terminal",
    show: (value?: boolean) => {
      shown = true;
      preserveFocus = value;
      activeTerminal = terminal;
    },
    creationOptions: {},
  } as const;
  const registry = new TerminalRegistry();
  const registration = createTerminalRegistration(terminal as never, 1234);
  registry.register(terminal as never, registration);
  const focuser = new EditorWindowTerminalFocuser(registry, {
    activeTerminal: () => activeTerminal as never,
    windowFocused: () => true,
  });
  const reports: Array<{ phase: TerminalFocusPhase; result: FocusResponse }> = [];
  const server = new TerminalFocusServer(
    socketPath,
    focuser,
    (phase, result) => reports.push({ phase, result }),
  );

  try {
    await server.start();
    assert.equal((await requestFocus(socketPath, registration.terminalId, "prepare")).ok, true);
    assert.equal((await requestFocus(socketPath, registration.terminalId, "focus")).ok, true);
    assert.equal(shown, true);
    assert.equal(preserveFocus, false);
    assert.equal(fs.statSync(socketPath).mode & 0o077, 0);
    assert.deepEqual(reports, [
      {
        phase: "prepare",
        result: { ok: true, terminalSelected: true, windowFocused: true },
      },
      {
        phase: "focus",
        result: {
          ok: true,
          terminalSelected: true,
          windowFocused: true,
          error: undefined,
        },
      },
    ]);
  } finally {
    server.dispose();
    fs.rmSync(temporary, { recursive: true, force: true });
  }
});

test("prepare confirms terminal selection without claiming native window focus", async () => {
  let activeTerminal: unknown;
  const terminal = {
    name: "background-window",
    show: () => {
      activeTerminal = terminal;
    },
    creationOptions: {},
  } as const;
  const registry = new TerminalRegistry();
  const registration = createTerminalRegistration(terminal as never);
  registry.register(terminal as never, registration);
  const focuser = new EditorWindowTerminalFocuser(registry, {
    activeTerminal: () => activeTerminal as never,
    windowFocused: () => false,
  }, 20, 1);

  const result = await focuser.focus(registration.terminalId, "prepare");

  assert.deepEqual(result, {
    ok: true,
    terminalSelected: true,
    windowFocused: false,
  });
});

test("focus fails closed when the native editor window is not focused", async () => {
  let activeTerminal: unknown;
  const terminal = {
    name: "background-window",
    show: () => {
      activeTerminal = terminal;
    },
    creationOptions: {},
  } as const;
  const registry = new TerminalRegistry();
  const registration = createTerminalRegistration(terminal as never);
  registry.register(terminal as never, registration);
  const focuser = new EditorWindowTerminalFocuser(registry, {
    activeTerminal: () => activeTerminal as never,
    windowFocused: () => false,
  }, 20, 1);

  const result = await focuser.focus(registration.terminalId, "focus");

  assert.deepEqual(result, {
    ok: false,
    terminalSelected: true,
    windowFocused: false,
    error: "editor-window-not-focused",
  });
});

test("concurrent editor windows keep independent exact-focus sockets", async () => {
  // Darwin's sockaddr_un path limit is short, so keep the fixture root compact.
  const temporary = fs.mkdtempSync("/tmp/cove-fw-");
  const firstPath = path.join(
    temporary,
    `editor-${createFocusSocketIdentifier(
      () => "62245f58-e261-4306-9af8-42a1e7b1b176",
    )}.sock`,
  );
  const secondPath = path.join(
    temporary,
    `editor-${createFocusSocketIdentifier(
      () => "4e1a2ee5-d282-47be-87ca-deb43f4de6c0",
    )}.sock`,
  );
  let firstShown = false;
  let secondShown = false;
  let firstPreserveFocus: boolean | undefined;
  let secondPreserveFocus: boolean | undefined;
  let firstActiveTerminal: unknown;
  let secondActiveTerminal: unknown;
  const firstTerminal = {
    name: "first-window",
    show: (value?: boolean) => {
      firstShown = true;
      firstPreserveFocus = value;
      firstActiveTerminal = firstTerminal;
    },
    creationOptions: {},
  } as const;
  const secondTerminal = {
    name: "second-window",
    show: (value?: boolean) => {
      secondShown = true;
      secondPreserveFocus = value;
      secondActiveTerminal = secondTerminal;
    },
    creationOptions: {},
  } as const;
  const firstRegistry = new TerminalRegistry();
  const secondRegistry = new TerminalRegistry();
  const firstRegistration = createTerminalRegistration(firstTerminal as never, 1_001);
  const secondRegistration = createTerminalRegistration(secondTerminal as never, 2_002);
  firstRegistry.register(firstTerminal as never, firstRegistration);
  secondRegistry.register(secondTerminal as never, secondRegistration);
  const firstFocuser = new EditorWindowTerminalFocuser(firstRegistry, {
    activeTerminal: () => firstActiveTerminal as never,
    windowFocused: () => true,
  });
  const secondFocuser = new EditorWindowTerminalFocuser(secondRegistry, {
    activeTerminal: () => secondActiveTerminal as never,
    windowFocused: () => true,
  });
  const firstServer = new TerminalFocusServer(firstPath, firstFocuser);
  const secondServer = new TerminalFocusServer(secondPath, secondFocuser);

  try {
    await firstServer.start();
    await secondServer.start();
    assert.equal(fs.existsSync(firstPath), true);
    assert.equal(fs.existsSync(secondPath), true);
    assert.equal((await requestFocus(firstPath, secondRegistration.terminalId)).ok, false);
    assert.equal((await requestFocus(secondPath, firstRegistration.terminalId)).ok, false);
    assert.equal((await requestFocus(firstPath, firstRegistration.terminalId)).ok, true);
    assert.equal((await requestFocus(secondPath, secondRegistration.terminalId)).ok, true);
    assert.equal(firstShown, true);
    assert.equal(secondShown, true);
    assert.equal(firstPreserveFocus, false);
    assert.equal(secondPreserveFocus, false);
  } finally {
    firstServer.dispose();
    secondServer.dispose();
    fs.rmSync(temporary, { recursive: true, force: true });
  }
});
