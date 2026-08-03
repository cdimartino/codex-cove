import type * as vscode from "vscode";

import { createSessionMarker } from "./sessionMarkers";
import type { SessionMarker, TerminalRegistration } from "./models";
import { createOpaqueIdentifier } from "./opaqueIdentifiers";
import { readCoveLaunchId } from "./terminalLaunch";

export interface RegisteredTerminalRecord {
  readonly terminal: vscode.Terminal;
  readonly registration: TerminalRegistration;
  readonly marker: SessionMarker;
}

export class TerminalRegistry {
  private readonly records = new Map<string, RegisteredTerminalRecord>();

  register(terminal: vscode.Terminal, registration: TerminalRegistration): RegisteredTerminalRecord {
    const marker = createSessionMarker(registration);
    const record = { terminal, registration, marker };
    this.records.set(registration.terminalId, record);
    return record;
  }

  get(terminalId: string): RegisteredTerminalRecord | undefined {
    return this.records.get(terminalId);
  }

  list(): readonly RegisteredTerminalRecord[] {
    return [...this.records.values()];
  }

  unregister(terminal: vscode.Terminal): readonly RegisteredTerminalRecord[] {
    const removed: RegisteredTerminalRecord[] = [];
    for (const [terminalId, record] of this.records) {
      if (record.terminal === terminal) {
        this.records.delete(terminalId);
        removed.push(record);
      }
    }
    return removed;
  }

  active(): RegisteredTerminalRecord | undefined {
    const terminals = this.list();
    return terminals.at(-1);
  }

  reveal(terminalId?: string): RegisteredTerminalRecord | undefined {
    const record = terminalId ? this.records.get(terminalId) : this.active();
    if (!record) {
      return undefined;
    }

    record.terminal.show(false);
    return record;
  }
}

export function createTerminalRegistration(
  terminal: vscode.Terminal,
  processId?: number,
): TerminalRegistration {
  const now = new Date().toISOString();
  const launchId = readCoveLaunchId(terminal.creationOptions);

  return {
    terminalId: launchId ?? createOpaqueIdentifier("terminal"),
    terminalName: "Integrated Terminal",
    processId,
    launchId,
    createdAt: now,
  };
}
