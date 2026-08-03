import * as fs from "node:fs";
import * as net from "node:net";
import * as path from "node:path";

import { TerminalRegistry } from "./terminalRegistry";
import { createOpaqueUuid } from "./opaqueIdentifiers";

const MAX_REQUEST_BYTES = 64 * 1024;
const DEFAULT_FOCUS_TIMEOUT_MS = 750;
const DEFAULT_FOCUS_POLL_MS = 20;

export type TerminalFocusPhase = "prepare" | "focus";

interface FocusRequest {
  readonly terminalId: string;
  readonly phase?: TerminalFocusPhase;
}

export interface TerminalFocusEnvironment {
  readonly activeTerminal: () => import("vscode").Terminal | undefined;
  readonly windowFocused: () => boolean;
}

export interface TerminalFocusResult {
  readonly ok: boolean;
  readonly terminalSelected: boolean;
  readonly windowFocused: boolean;
  readonly error?: string;
}

export function createEditorWindowFocusMarker(focusSocketId: string): string {
  if (!/^[0-9a-f]{12}$/.test(focusSocketId)) {
    throw new Error("invalid editor focus socket identifier");
  }
  return `Codex Cove editor window ${focusSocketId}`;
}

export class EditorWindowTerminalFocuser {
  constructor(
    private readonly registry: TerminalRegistry,
    private readonly environment: TerminalFocusEnvironment,
    private readonly timeoutMs = DEFAULT_FOCUS_TIMEOUT_MS,
    private readonly pollMs = DEFAULT_FOCUS_POLL_MS,
  ) {}

  async focus(terminalId: string, phase: TerminalFocusPhase): Promise<TerminalFocusResult> {
    const deadline = Date.now() + this.timeoutMs;
    let record: ReturnType<TerminalRegistry["reveal"]>;
    try {
      // show(false) is the public VS Code API for revealing this exact
      // terminal and allowing it to take focus. Avoid the generic
      // workbench.action.terminal.focus command: that command is not
      // cancellable and could act on a different active terminal if it
      // completed after our deadline.
      record = this.registry.reveal(terminalId);
    } catch {
      return {
        ok: false,
        terminalSelected: false,
        windowFocused: false,
        error: "terminal-reveal-failed",
      };
    }
    if (!record) {
      return {
        ok: false,
        terminalSelected: false,
        windowFocused: false,
        error: "terminal-not-found",
      };
    }

    const terminalSelected = await this.waitUntil(
      () => this.environment.activeTerminal() === record.terminal,
      deadline,
    );
    if (!terminalSelected) {
      return {
        ok: false,
        terminalSelected: false,
        windowFocused: this.environment.windowFocused(),
        error: "terminal-not-selected",
      };
    }

    if (phase === "prepare") {
      return {
        ok: true,
        terminalSelected: true,
        windowFocused: this.environment.windowFocused(),
      };
    }

    const windowFocused = await this.waitUntil(
      () => this.environment.windowFocused()
        && this.environment.activeTerminal() === record.terminal,
      deadline,
    );
    return {
      ok: windowFocused,
      terminalSelected: true,
      windowFocused,
      error: windowFocused ? undefined : "editor-window-not-focused",
    };
  }

  private async waitUntil(
    predicate: () => boolean,
    deadline: number,
  ): Promise<boolean> {
    while (!predicate()) {
      if (Date.now() >= deadline) {
        return false;
      }
      await new Promise<void>((resolve) => setTimeout(
        resolve,
        Math.min(this.pollMs, Math.max(1, deadline - Date.now())),
      ));
    }
    return true;
  }
}

/**
 * Each extension host owns its own focus socket. VS Code global state is shared
 * by every window, so a persisted global identifier cannot safely name this
 * process-local server: a second window would unlink and replace the first
 * window's live socket. The opaque identifier is published with every terminal
 * registration and can therefore be persisted by Cove for exact restoration.
 */
export function createFocusSocketIdentifier(uuidFactory?: () => string): string {
  // Keep the suffix compact: Darwin's sockaddr_un path is limited to 104
  // bytes, and Cove's private Application Support directory consumes most of
  // that budget. Twelve random hexadecimal characters (48 bits) are ample to
  // distinguish concurrent editor windows while leaving room for the prefix.
  return createOpaqueUuid(uuidFactory).replaceAll("-", "").slice(0, 12);
}

export class TerminalFocusServer {
  private server: net.Server | undefined;

  constructor(
    readonly socketPath: string,
    private readonly focuser: EditorWindowTerminalFocuser,
    private readonly onFocusResult?: (
      phase: TerminalFocusPhase,
      result: TerminalFocusResult,
    ) => void,
  ) {}

  async start(): Promise<void> {
    if (this.server) {
      return;
    }

    fs.mkdirSync(path.dirname(this.socketPath), { recursive: true, mode: 0o700 });
    if (fs.existsSync(this.socketPath)) {
      const existing = fs.lstatSync(this.socketPath);
      const owned = typeof process.getuid !== "function" || existing.uid === process.getuid();
      if (!existing.isSocket() || !owned) {
        throw new Error(`refusing to replace non-owned focus socket: ${this.socketPath}`);
      }
      fs.unlinkSync(this.socketPath);
    }

    const server = net.createServer((client) => this.handle(client));
    this.server = server;
    await new Promise<void>((resolve, reject) => {
      const onError = (error: Error) => {
        server.off("listening", onListening);
        reject(error);
      };
      const onListening = () => {
        server.off("error", onError);
        resolve();
      };
      server.once("error", onError);
      server.once("listening", onListening);
      server.listen(this.socketPath);
    });
    fs.chmodSync(this.socketPath, 0o600);
  }

  dispose(): void {
    const server = this.server;
    this.server = undefined;
    server?.close();
    try {
      const existing = fs.lstatSync(this.socketPath);
      if (existing.isSocket() && (typeof process.getuid !== "function" || existing.uid === process.getuid())) {
        fs.unlinkSync(this.socketPath);
      }
    } catch {
      // Socket already absent.
    }
  }

  private handle(client: net.Socket): void {
    let buffered = Buffer.alloc(0);
    let finished = false;

    const finish = (response: Record<string, unknown>) => {
      if (finished) {
        return;
      }
      finished = true;
      client.end(`${JSON.stringify(response)}\n`);
    };

    client.setTimeout(1_000, () => finish({ ok: false, error: "timeout" }));
    client.on("data", (chunk: Buffer) => {
      if (finished) {
        return;
      }
      buffered = Buffer.concat([buffered, chunk]);
      if (buffered.length > MAX_REQUEST_BYTES) {
        finish({ ok: false, error: "request-too-large" });
        return;
      }
      const newline = buffered.indexOf(0x0a);
      if (newline < 0) {
        return;
      }
      try {
        const request = JSON.parse(buffered.subarray(0, newline).toString("utf8")) as Partial<FocusRequest>;
        if (typeof request.terminalId !== "string" || request.terminalId.length === 0) {
          finish({ ok: false, error: "invalid-terminal-id" });
          return;
        }
        const phase = request.phase ?? "focus";
        if (phase !== "prepare" && phase !== "focus") {
          finish({ ok: false, error: "invalid-focus-phase" });
          return;
        }
        void this.focuser.focus(request.terminalId, phase).then((result) => {
          try {
            this.onFocusResult?.(phase, result);
          } catch {
            // Diagnostics must never change the private focus protocol.
          }
          finish({ ...result });
        }, () => {
          finish({ ok: false, error: "focus-failed" });
        });
      } catch {
        finish({ ok: false, error: "invalid-json" });
      }
    });
    client.on("error", () => {
      client.destroy();
    });
  }
}
