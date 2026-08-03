export const COVE_SCHEMA_VERSION = 1 as const;

export type CoveEventSource = "localCli" | "codexDesktop" | "remoteCli";
export type DecisionKind = "approval" | "question" | "plan";
export type ThemeFamily = "nativeGlass" | "retroTerminal" | "minimalOLED";
export type ThemeBlur = "off" | "thin" | "regular" | "thick";

export interface CoveEvent<TPayload extends Record<string, unknown> = Record<string, unknown>> {
  readonly schemaVersion: typeof COVE_SCHEMA_VERSION;
  readonly eventId: string;
  readonly kind: string;
  readonly timestamp: string;
  readonly source: CoveEventSource;
  readonly sessionId: string;
  readonly turnId?: string;
  readonly launchId?: string;
  readonly hostId?: string;
  readonly payload: TPayload;
}

export interface TerminalRegistration {
  readonly terminalId: string;
  readonly terminalName: string;
  readonly processId?: number;
  readonly launchId?: string;
  readonly createdAt: string;
}

export interface EditorHostIdentity {
  readonly applicationName: string;
  readonly bundleIdentifier?: string;
  readonly uriScheme: string;
}

export function resolveEditorHostIdentity(
  applicationName: string,
  uriScheme: string,
): EditorHostIdentity {
  const normalizedName = applicationName.toLowerCase();
  const normalizedScheme = uriScheme.toLowerCase();
  if (normalizedName.includes("cursor") || normalizedScheme.includes("cursor")) {
    return {
      applicationName: "Cursor",
      bundleIdentifier: "com.todesktop.230313mzl4w4u92",
      uriScheme,
    };
  }
  if (
    normalizedName.includes("insider")
    || normalizedScheme === "vscode-insiders"
  ) {
    return {
      applicationName: "Visual Studio Code - Insiders",
      bundleIdentifier: "com.microsoft.VSCodeInsiders",
      uriScheme,
    };
  }
  if (
    normalizedName.includes("visual studio code")
    || normalizedScheme === "vscode"
  ) {
    return {
      applicationName: "Visual Studio Code",
      bundleIdentifier: "com.microsoft.VSCode",
      uriScheme,
    };
  }
  return { applicationName, uriScheme };
}

export function normalizeEditorTerminalIdentifier(identifier: string): string {
  const normalized = identifier
    .replace(/[^A-Za-z0-9%+.:@_-]/g, "_")
    .slice(0, 256);
  return normalized.length > 0 ? normalized : "terminal";
}

export interface SessionMarker {
  readonly markerId: string;
  readonly terminalId: string;
  readonly registeredAt: string;
}

export interface ThemePalette {
  readonly name: string;
  readonly colors: {
    readonly background: string;
    readonly surface: string;
    readonly text: string;
    readonly muted: string;
    readonly accent: string;
    readonly working: string;
    readonly waiting: string;
    readonly completed: string;
    readonly failed: string;
  };
}

export interface ThemeTypography {
  readonly family: string;
  readonly sizeScale?: number;
  readonly weight?: "light" | "regular" | "medium" | "semibold" | "bold";
  readonly lineHeight?: number;
}

export interface ThemeBorder {
  readonly width?: number;
  readonly style?: "solid" | "dashed" | "none";
}

export interface ThemeShadow {
  readonly x?: number;
  readonly y?: number;
  readonly blur?: number;
  readonly opacity?: number;
}

export interface ThemeAnimation {
  readonly enabled: boolean;
  readonly durationMs?: number;
  readonly easing?: string;
}

export interface ThemeDefinition {
  readonly schemaVersion: typeof COVE_SCHEMA_VERSION;
  readonly family: ThemeFamily;
  readonly palette: ThemePalette;
  readonly typography: ThemeTypography;
  readonly cornerRadius: number;
  readonly border?: ThemeBorder;
  readonly shadow?: ThemeShadow;
  readonly noise?: number;
  readonly blur: ThemeBlur;
  readonly collapsedOpacity: number;
  readonly expandedOpacity: number;
  readonly animation: ThemeAnimation;
}

export interface DecisionOption {
  readonly id: string;
  readonly label: string;
  readonly shortcut?: string;
  readonly destructive?: boolean;
}

export interface BrokerDecisionResponse {
  readonly schemaVersion: typeof COVE_SCHEMA_VERSION;
  readonly launchId: string;
  readonly requestId: string | number;
  readonly sessionId?: string;
  readonly result?: Record<string, unknown>;
  readonly error?: Record<string, unknown>;
}

export interface InteractiveRequest {
  readonly requestId: string | number;
  readonly kind: DecisionKind;
  readonly sessionId: string;
  readonly launchId?: string;
  readonly decisionSocket?: string;
  readonly title: string;
  readonly body: string;
  readonly options: readonly DecisionOption[];
  readonly raw: Record<string, unknown>;
}

export interface StatusSnapshot {
  readonly socketPath?: string;
  readonly socketState: "disabled" | "connected" | "disconnected" | "error";
  readonly openTerminals: number;
  readonly registeredTerminals: number;
  readonly activeTerminalName?: string;
  readonly lastMarker?: SessionMarker;
  readonly lastEventType?: string;
}
