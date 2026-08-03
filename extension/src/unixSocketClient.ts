import * as net from "node:net";

import { COVE_SCHEMA_VERSION, type CoveEvent, type CoveEventSource } from "./models";

export interface SocketPublishResult {
  readonly attempted: boolean;
  readonly connected: boolean;
  readonly bytesWritten: number;
}

export class LocalUnixSocketClient {
  constructor(private readonly socketPath?: string) {}

  isEnabled(): boolean {
    return Boolean(this.socketPath && this.socketPath.trim().length > 0);
  }

  async publish<TPayload extends Record<string, unknown>>(event: CoveEvent<TPayload>): Promise<SocketPublishResult> {
    if (!this.isEnabled()) {
      return { attempted: false, connected: false, bytesWritten: 0 };
    }

    return await new Promise<SocketPublishResult>((resolve) => {
      const client = net.createConnection(this.socketPath as string);
      let settled = false;
      let bytesWritten = 0;

      const finish = (result: SocketPublishResult) => {
        if (settled) {
          return;
        }
        settled = true;
        resolve(result);
      };

      client.on("connect", () => {
        const payload = `${JSON.stringify(event)}\n`;
        bytesWritten = client.write(payload) ? Buffer.byteLength(payload) : 0;
        client.end();
      });

      client.on("close", () => {
        finish({ attempted: true, connected: true, bytesWritten });
      });

      client.on("error", () => {
        client.destroy();
        finish({ attempted: true, connected: false, bytesWritten: 0 });
      });
    });
  }

  createEvent<TPayload extends Record<string, unknown>>(
    kind: string,
    source: CoveEventSource,
    sessionId: string,
    launchId: string | undefined,
    hostId: string | undefined,
    payload: TPayload,
    turnId?: string,
  ): CoveEvent<TPayload> {
    return {
      schemaVersion: COVE_SCHEMA_VERSION,
      eventId: globalThis.crypto?.randomUUID?.() ?? `${Date.now()}-${Math.random().toString(16).slice(2)}`,
      kind,
      timestamp: new Date().toISOString(),
      source,
      sessionId,
      turnId,
      launchId,
      hostId,
      payload,
    };
  }
}
