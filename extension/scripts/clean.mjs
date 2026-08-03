import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const extensionRoot = path.resolve(here, "..");

for (const name of ["out", "schemas", "dist"]) {
  fs.rmSync(path.join(extensionRoot, name), { recursive: true, force: true });
}
