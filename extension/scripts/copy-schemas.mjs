import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const extensionRoot = path.resolve(here, "..");
const repoRoot = path.resolve(extensionRoot, "..");
const sourceDir = path.join(repoRoot, "schemas");
const targetDir = path.join(extensionRoot, "schemas");

fs.mkdirSync(targetDir, { recursive: true });

for (const fileName of fs.readdirSync(sourceDir)) {
  if (!fileName.endsWith(".json")) {
    continue;
  }
  fs.copyFileSync(path.join(sourceDir, fileName), path.join(targetDir, fileName));
}
