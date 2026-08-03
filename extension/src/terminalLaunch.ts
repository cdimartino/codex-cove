import type * as vscode from "vscode";

import { createOpaqueIdentifier, isOpaqueIdentifier } from "./opaqueIdentifiers";

export const CODEX_COVE_LAUNCH_ID = "CODEX_COVE_LAUNCH_ID";
export const COVE_TERMINAL_PROFILE_ID = "cove.routedTerminal";

export interface CoveTerminalLaunch {
  readonly launchId: string;
  readonly options: vscode.TerminalOptions;
}

export function createCoveTerminalLaunch(uuidFactory?: () => string): CoveTerminalLaunch {
  const launchId = createOpaqueIdentifier("editor", uuidFactory);
  return {
    launchId,
    options: {
      name: "Codex Cove",
      env: {
        [CODEX_COVE_LAUNCH_ID]: launchId,
      },
    },
  };
}

export function readCoveLaunchId(
  creationOptions: vscode.Terminal["creationOptions"] | undefined,
): string | undefined {
  const options = creationOptions as Partial<{ env: Record<string, string | null | undefined> }> | undefined;
  const candidate = options?.env?.[CODEX_COVE_LAUNCH_ID];
  return isOpaqueIdentifier(candidate) ? candidate : undefined;
}
