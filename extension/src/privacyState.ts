import { createOpaqueUuid, isOpaqueIdentifier } from "./opaqueIdentifiers";

export interface ExtensionGlobalState {
  get<T>(key: string): T | undefined;
  update(key: string, value: unknown): PromiseLike<void>;
  keys?(): readonly string[];
}

const LEGACY_SENSITIVE_KEYS = [
  "cove.sessionMarkers",
  "cove.launchId",
  "cove.cwd",
  "cove.shell",
  "cove.sessionName",
  "cove.prompt",
  "cove.response",
  "cove.command",
  "cove.diff",
] as const;

const SENSITIVE_KEY_FRAGMENT = /(?:cwd|shell|sessionname|prompt|response|command|diff|marker)/i;

/**
 * Remove prerelease state that could contain terminal or transcript metadata.
 * Cove no longer needs persisted editor markers; live registrations are rebuilt
 * from VS Code/Cursor's open terminals on every activation.
 */
export async function sanitizeLegacyGlobalState(state: ExtensionGlobalState): Promise<void> {
  const keys = new Set<string>(LEGACY_SENSITIVE_KEYS);
  for (const key of state.keys?.() ?? []) {
    if (key.startsWith("cove.") && SENSITIVE_KEY_FRAGMENT.test(key)) {
      keys.add(key);
    }
  }

  for (const key of keys) {
    await state.update(key, undefined);
  }
}

export async function readOrCreateOpaqueStateId(
  state: ExtensionGlobalState,
  key: string,
  uuidFactory?: () => string,
): Promise<string> {
  const existing = state.get<unknown>(key);
  if (isOpaqueIdentifier(existing)) {
    return existing;
  }

  const generated = createOpaqueUuid(uuidFactory);
  await state.update(key, generated);
  return generated;
}
