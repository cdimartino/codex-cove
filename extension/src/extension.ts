import * as fs from "node:fs";
import * as path from "node:path";
import * as os from "node:os";

import * as vscode from "vscode";

import {
  COVE_SCHEMA_VERSION,
  normalizeEditorTerminalIdentifier,
  resolveEditorHostIdentity,
  type CoveEvent,
  type StatusSnapshot,
} from "./models";
import { buildStatusText, SessionMarkerStore } from "./sessionMarkers";
import { createTerminalRegistration, TerminalRegistry } from "./terminalRegistry";
import { LocalUnixSocketClient } from "./unixSocketClient";
import { StatusPresenter } from "./status";
import {
  createEditorWindowFocusMarker,
  createFocusSocketIdentifier,
  EditorWindowTerminalFocuser,
  TerminalFocusServer,
} from "./terminalFocusServer";
import { readOrCreateOpaqueStateId, sanitizeLegacyGlobalState } from "./privacyState";
import { COVE_TERMINAL_PROFILE_ID, createCoveTerminalLaunch } from "./terminalLaunch";

function readSocketPath(config: vscode.WorkspaceConfiguration): string | undefined {
  const configured = config.get<string>("socketPath", "");
  const trimmed = configured.trim();
  if (trimmed.length > 0) {
    return trimmed;
  }

  return path.join(os.homedir(), "Library", "Application Support", "Codex Cove", "run", "events.sock");
}

function loadSchemaVersion(context: vscode.ExtensionContext): number {
  const schemaPath = path.join(context.extensionPath, "schemas", "cove-event.v1.schema.json");
  if (!fs.existsSync(schemaPath)) {
    return COVE_SCHEMA_VERSION;
  }

  try {
    const raw = JSON.parse(fs.readFileSync(schemaPath, "utf8")) as { schemaVersion?: number };
    return raw.schemaVersion ?? COVE_SCHEMA_VERSION;
  } catch {
    return COVE_SCHEMA_VERSION;
  }
}

export async function activate(context: vscode.ExtensionContext): Promise<void> {
  const config = vscode.workspace.getConfiguration("cove");
  const outputChannel = vscode.window.createOutputChannel(config.get<string>("statusChannel", "Cove"));
  const statusBar = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Left, 1000);
  const presenter = new StatusPresenter(outputChannel, statusBar);
  const registry = new TerminalRegistry();
  const socketClient = new LocalUnixSocketClient(readSocketPath(config));
  const markerStore = new SessionMarkerStore();
  loadSchemaVersion(context);
  await sanitizeLegacyGlobalState(context.globalState);
  const sessionId = await readOrCreateOpaqueStateId(context.globalState, "cove.sessionId");
  const hostId = os.hostname();
  const editorHost = resolveEditorHostIdentity(vscode.env.appName, vscode.env.uriScheme);
  const focusSocketId = createFocusSocketIdentifier();
  const editorWindowFocusMarker = createEditorWindowFocusMarker(focusSocketId);
  statusBar.name = editorWindowFocusMarker;
  statusBar.accessibilityInformation = {
    label: editorWindowFocusMarker,
    role: "button",
  };
  statusBar.command = "cove.showStatus";
  const focusSocketPath = path.join(
    os.homedir(),
    "Library",
    "Application Support",
    "Codex Cove",
    "run",
    `editor-${focusSocketId}.sock`,
  );
  const terminalFocuser = new EditorWindowTerminalFocuser(registry, {
    activeTerminal: () => vscode.window.activeTerminal,
    windowFocused: () => vscode.window.state.focused,
  });
  const focusServer = new TerminalFocusServer(
    focusSocketPath,
    terminalFocuser,
    (phase, result) => {
      // Keep exact-focus diagnostics content-free: phase/result booleans and
      // the fixed error category are sufficient for a live contract probe.
      outputChannel.appendLine([
        `Exact focus ${phase}`,
        `ok=${result.ok}`,
        `terminalSelected=${result.terminalSelected}`,
        `windowFocused=${result.windowFocused}`,
        result.error ? `error=${result.error}` : undefined,
      ].filter((part): part is string => Boolean(part)).join(" | "));
    },
  );
  try {
    await focusServer.start();
    context.subscriptions.push(focusServer);
  } catch (error) {
    outputChannel.appendLine(`Focus server unavailable: ${String(error)}`);
  }
  let lastEventType: string | undefined;

  context.subscriptions.push(outputChannel, statusBar);

  const currentSnapshot = (): StatusSnapshot => {
    const active = registry.active();
    return {
      socketPath: readSocketPath(vscode.workspace.getConfiguration("cove")),
      socketState: socketClient.isEnabled() ? "connected" : "disabled",
      openTerminals: registry.list().length,
      registeredTerminals: markerStore.all().length,
      activeTerminalName: active?.registration.terminalName,
      lastMarker: markerStore.all().at(-1),
      lastEventType,
    };
  };

  const publish = async <TPayload extends Record<string, unknown>>(
    kind: string,
    payload: TPayload,
    launchId?: string,
  ): Promise<void> => {
    const envelope: CoveEvent<TPayload> = socketClient.createEvent(kind, "localCli", sessionId, launchId, hostId, payload);
    lastEventType = kind;
    await socketClient.publish(envelope);
    presenter.render(currentSnapshot());
  };

  // processId is asynchronous. Remember close events so a slow processId
  // resolution cannot resurrect and publish a terminal that was disposed in
  // the meantime.
  const closedTerminals = new WeakSet<vscode.Terminal>();

  const registerTerminal = async (terminal: vscode.Terminal): Promise<void> => {
    if (closedTerminals.has(terminal)) {
      return;
    }
    const processId = await terminal.processId;
    if (closedTerminals.has(terminal) || !vscode.window.terminals.includes(terminal)) {
      return;
    }
    const discoveredRegistration = createTerminalRegistration(
      terminal,
      processId,
    );
    const registration = {
      ...discoveredRegistration,
      terminalId: normalizeEditorTerminalIdentifier(
        discoveredRegistration.terminalId,
      ),
    };
    const record = registry.register(terminal, registration);
    markerStore.upsert(record.marker);
    presenter.showMarker(record.marker);
    await publish(
      "terminal.registered",
      {
        terminal: record.registration,
        marker: record.marker,
        focusSocket: focusSocketPath,
        focusSocketId,
        editorHost,
      },
      record.registration.launchId,
    );
  };

  const registerOpenTerminals = async (): Promise<void> => {
    for (const terminal of vscode.window.terminals) {
      await registerTerminal(terminal);
    }
  };

  context.subscriptions.push(
    vscode.window.registerTerminalProfileProvider(COVE_TERMINAL_PROFILE_ID, {
      provideTerminalProfile: () => {
        const launch = createCoveTerminalLaunch();
        return new vscode.TerminalProfile(launch.options);
      },
    }),
  );

  context.subscriptions.push(
    vscode.commands.registerCommand("cove.createRoutedTerminal", () => {
      const launch = createCoveTerminalLaunch();
      const terminal = vscode.window.createTerminal(launch.options);
      terminal.show();
    }),
  );

  context.subscriptions.push(
    vscode.window.onDidOpenTerminal((terminal) => {
      closedTerminals.delete(terminal);
      void registerTerminal(terminal);
    }),
  );

  context.subscriptions.push(
    vscode.window.onDidCloseTerminal((terminal) => {
      closedTerminals.add(terminal);
      for (const record of registry.unregister(terminal)) {
        markerStore.remove(record.registration.terminalId);
      }
      presenter.render(currentSnapshot());
    }),
  );

  if (config.get<boolean>("registerOnStartup", true)) {
    await registerOpenTerminals();
  }

  context.subscriptions.push(
    vscode.window.onDidChangeActiveTerminal((terminal) => {
      if (!terminal) {
        return;
      }
      const record = [...registry.list()].find((entry) => entry.terminal === terminal);
      if (record) {
        lastEventType = "terminal.focused";
        presenter.render(currentSnapshot());
      }
    }),
  );

  context.subscriptions.push(
    vscode.commands.registerCommand("cove.registerActiveTerminal", async () => {
      const terminal = vscode.window.activeTerminal;
      if (!terminal) {
        vscode.window.showWarningMessage("Cove: no active terminal to register.");
        return;
      }
      await registerTerminal(terminal);
    }),
  );

  context.subscriptions.push(
    vscode.commands.registerCommand("cove.focusExactRegisteredTerminal", async (terminalId?: string) => {
      const record = terminalId ? registry.get(terminalId) : registry.active();
      if (!record) {
        vscode.window.showInformationMessage("Cove: no registered terminal found.");
        return;
      }
      const focused = await terminalFocuser.focus(record.registration.terminalId, "focus");
      if (!focused.ok) {
        vscode.window.showInformationMessage("Cove: the registered terminal window could not be focused.");
        return;
      }
      lastEventType = "terminal.focused";
      presenter.render(currentSnapshot());
    }),
  );

  context.subscriptions.push(
    vscode.commands.registerCommand("cove.showStatus", () => {
      presenter.render(currentSnapshot());
      vscode.window.showInformationMessage(buildStatusText(currentSnapshot()));
    }),
  );

  context.subscriptions.push(
    vscode.commands.registerCommand("cove.copyStatus", async () => {
      const text = buildStatusText(currentSnapshot());
      await vscode.env.clipboard.writeText(text);
      vscode.window.showInformationMessage("Cove status copied to clipboard.");
    }),
  );

  presenter.render(currentSnapshot());
}

export function deactivate(): void {
  return;
}
