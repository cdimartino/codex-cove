import type { SessionMarker, StatusSnapshot, TerminalRegistration } from "./models";

export class SessionMarkerStore {
  private readonly markers = new Map<string, SessionMarker>();

  upsert(marker: SessionMarker): SessionMarker {
    this.markers.set(marker.terminalId, marker);
    return marker;
  }

  get(terminalId: string): SessionMarker | undefined {
    return this.markers.get(terminalId);
  }

  remove(terminalId: string): void {
    this.markers.delete(terminalId);
  }

  all(): readonly SessionMarker[] {
    return [...this.markers.values()].sort((left, right) => left.registeredAt.localeCompare(right.registeredAt));
  }

  clear(): void {
    this.markers.clear();
  }
}

export function createSessionMarker(registration: TerminalRegistration): SessionMarker {
  return {
    markerId: registration.terminalId,
    terminalId: registration.terminalId,
    registeredAt: registration.createdAt,
  };
}

export function buildStatusText(snapshot: StatusSnapshot): string {
  const parts = [
    `socket=${snapshot.socketState}`,
    `terminals=${snapshot.openTerminals}`,
    `registered=${snapshot.registeredTerminals}`,
  ];

  if (snapshot.activeTerminalName) {
    parts.push(`active=${snapshot.activeTerminalName}`);
  }

  if (snapshot.lastEventType) {
    parts.push(`event=${snapshot.lastEventType}`);
  }

  return parts.join(" | ");
}
