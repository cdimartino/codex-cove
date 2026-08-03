#!/usr/bin/env node

import { spawn } from "node:child_process";
import readline from "node:readline";

const codex = process.env.CODEX_COVE_REAL_CODEX || "/opt/homebrew/bin/codex";
const timeoutMs = Number(process.env.CODEX_COVE_SMOKE_TIMEOUT_MS || "8000");
const child = spawn(codex, ["app-server", "--stdio"], {
  env: {
    ...process.env,
    CODEX_COVE_BYPASS: "1",
    RUST_LOG: "off",
  },
  stdio: ["pipe", "pipe", "pipe"],
});

let completed = false;
let ignoredLines = 0;
let stderr = "";

const fail = (message) => {
  if (completed) return;
  completed = true;
  clearTimeout(timer);
  child.kill("SIGTERM");
  process.stderr.write(`${message}\n`);
  if (stderr.trim()) {
    process.stderr.write(`${stderr.trim().slice(0, 2000)}\n`);
  }
  process.exitCode = 1;
};

const send = (message) => {
  child.stdin.write(`${JSON.stringify(message)}\n`);
};

const timer = setTimeout(() => {
  fail(`Timed out after ${timeoutMs} ms waiting for app-server usage response`);
}, timeoutMs);

child.stderr.setEncoding("utf8");
child.stderr.on("data", (chunk) => {
  stderr += chunk;
  if (stderr.length > 8192) stderr = stderr.slice(-8192);
});

child.on("error", (error) => fail(`Failed to start ${codex}: ${error.message}`));
child.on("exit", (code, signal) => {
  if (!completed) {
    fail(`App-server exited before completing the smoke check: code=${code} signal=${signal}`);
  }
});

const lines = readline.createInterface({ input: child.stdout });
lines.on("line", (line) => {
  let message;
  try {
    message = JSON.parse(line);
  } catch {
    ignoredLines += 1;
    return;
  }

  if (message.id === "cove-smoke-initialize") {
    if (message.error) {
      fail(`Initialize failed: ${JSON.stringify(message.error)}`);
      return;
    }
    send({ jsonrpc: "2.0", method: "initialized", params: {} });
    send({
      jsonrpc: "2.0",
      id: "cove-smoke-usage",
      method: "account/rateLimits/read",
      params: null,
    });
    return;
  }

  if (message.id !== "cove-smoke-usage") return;
  if (message.error) {
    fail(`Rate-limit read failed: ${JSON.stringify(message.error)}`);
    return;
  }

  const snapshot = message.result?.rateLimits;
  if (!snapshot || typeof snapshot !== "object") {
    fail("Rate-limit response did not contain result.rateLimits");
    return;
  }

  completed = true;
  clearTimeout(timer);
  child.stdin.end();
  child.kill("SIGTERM");
  process.stdout.write(
    `${JSON.stringify({
      initialized: true,
      rateLimitsRead: true,
      primaryPresent: snapshot.primary != null,
      secondaryPresent: snapshot.secondary != null,
      resetCreditsPresent: message.result?.rateLimitResetCredits != null,
      ignoredNonProtocolLines: ignoredLines,
    })}\n`,
  );
});

send({
  jsonrpc: "2.0",
  id: "cove-smoke-initialize",
  method: "initialize",
  params: {
    clientInfo: {
      name: "codex-cove-smoke",
      title: "Codex Cove Smoke",
      version: "0.1.0",
    },
    capabilities: { experimentalApi: false },
  },
});
