import { randomUUID } from "node:crypto";

export type OpaqueIdentifierScope = "editor" | "session" | "terminal";

const UUID_PATTERN = "[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}";
const OPAQUE_IDENTIFIER_PATTERN = new RegExp(
  `^(?:${UUID_PATTERN}|cove-(?:editor|session|terminal)-${UUID_PATTERN}|cove-[0-9a-f]+-[0-9a-f]+-[0-9a-f]+)$`,
  "i",
);

export function isOpaqueIdentifier(value: unknown): value is string {
  return typeof value === "string"
    && value.length <= 128
    && OPAQUE_IDENTIFIER_PATTERN.test(value);
}

export function createOpaqueUuid(uuidFactory: () => string = randomUUID): string {
  const uuid = uuidFactory().toLowerCase();
  if (!new RegExp(`^${UUID_PATTERN}$`, "i").test(uuid)) {
    throw new Error("Opaque identifier source did not return a UUID.");
  }
  return uuid;
}

export function createOpaqueIdentifier(
  scope: OpaqueIdentifierScope,
  uuidFactory: () => string = randomUUID,
): string {
  return `cove-${scope}-${createOpaqueUuid(uuidFactory)}`;
}
