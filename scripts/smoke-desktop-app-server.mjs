#!/usr/bin/env node

import { spawn } from "node:child_process";
import readline from "node:readline";

const codex = process.env.CODEX_COVE_REAL_CODEX;
if (!codex) {
  process.stderr.write("CODEX_COVE_REAL_CODEX must be an absolute path.\n");
  process.exit(2);
}

const expectedThreadID = process.env.CODEX_COVE_EXPECTED_THREAD_ID || "";
const timeoutMs = Number(process.env.CODEX_COVE_SMOKE_TIMEOUT_MS || "10000");
const maximumLineBytes = 1024 * 1024;
const child = spawn(codex, ["app-server", "--stdio"], {
  env: {
    ...process.env,
    CODEX_COVE_BYPASS: "1",
    RUST_LOG: "off",
  },
  stdio: ["pipe", "pipe", "pipe"],
});

let completed = false;
let stderr = "";
let threadRows = [];
let readThread = null;

const stop = () => {
  child.stdin.end();
  child.kill("SIGTERM");
};

const fail = (message) => {
  if (completed) return;
  completed = true;
  clearTimeout(timer);
  stop();
  process.stderr.write(`${message}\n`);
  if (stderr.trim()) {
    process.stderr.write(`${stderr.trim().slice(0, 2000)}\n`);
  }
  process.exitCode = 1;
};

const send = (message) => {
  child.stdin.write(`${JSON.stringify(message)}\n`);
};

const scalar = (value) =>
  typeof value === "string" && value.length <= 128 ? value : undefined;

const sourceKinds = (row) => {
  const values = [
    row?.source,
    row?.sourceKind,
    row?.source_kind,
    row?.client,
    row?.origin,
    row?.app,
    row?.source?.kind,
    row?.source?.name,
  ];
  return values.map(scalar).filter(Boolean);
};

const statusKinds = (row) => {
  const status = row?.status;
  const values =
    status && typeof status === "object"
      ? [status.type, status.state, status.status]
      : [status];
  return values.map(scalar).filter(Boolean);
};

const finish = (threadReadSucceeded) => {
  if (completed) return;
  completed = true;
  clearTimeout(timer);
  stop();
  const expectedThreadPresent =
    expectedThreadID.length > 0 &&
    threadRows.some((row) => row?.id === expectedThreadID);
  process.stdout.write(
    `${JSON.stringify({
      initialized: true,
      threadListRead: true,
      rowCount: threadRows.length,
      expectedThreadPresent,
      expectedThreadRead: threadReadSucceeded,
      sourceKinds: [...new Set(threadRows.flatMap(sourceKinds))].sort(),
      statusKinds: [...new Set(threadRows.flatMap(statusKinds))].sort(),
      readSourceKinds: readThread ? [...new Set(sourceKinds(readThread))].sort() : [],
      readStatusKinds: readThread ? [...new Set(statusKinds(readThread))].sort() : [],
    })}\n`,
  );
};

const timer = setTimeout(
  () => fail(`Timed out after ${timeoutMs} ms waiting for app-server`),
  timeoutMs,
);

child.stderr.setEncoding("utf8");
child.stderr.on("data", (chunk) => {
  stderr += chunk;
  if (stderr.length > 8192) stderr = stderr.slice(-8192);
});
child.on("error", (error) => fail(`Failed to start Codex app-server: ${error.message}`));
child.on("exit", (code, signal) => {
  if (!completed) {
    fail(`App-server exited early: code=${code} signal=${signal}`);
  }
});

const lines = readline.createInterface({ input: child.stdout });
lines.on("line", (line) => {
  if (Buffer.byteLength(line, "utf8") > maximumLineBytes) {
    fail("App-server response exceeded 1 MiB");
    return;
  }

  let message;
  try {
    message = JSON.parse(line);
  } catch {
    return;
  }

  if (message.id === "cove-desktop-smoke-initialize") {
    if (message.error) {
      fail("Initialize returned an error");
      return;
    }
    send({ jsonrpc: "2.0", method: "initialized", params: {} });
    send({
      jsonrpc: "2.0",
      id: "cove-desktop-smoke-list",
      method: "thread/list",
      params: { limit: 100, archived: false },
    });
    return;
  }

  if (message.id === "cove-desktop-smoke-list") {
    if (message.error) {
      fail("thread/list returned an error");
      return;
    }
    threadRows = Array.isArray(message.result?.data)
      ? message.result.data
      : Array.isArray(message.result?.threads)
        ? message.result.threads
        : [];
    if (!expectedThreadID) {
      finish(false);
      return;
    }
    send({
      jsonrpc: "2.0",
      id: "cove-desktop-smoke-read",
      method: "thread/read",
      params: { threadId: expectedThreadID, includeTurns: false },
    });
    return;
  }

  if (message.id === "cove-desktop-smoke-read") {
    readThread = message.result?.thread ?? null;
    finish(!message.error && readThread?.id === expectedThreadID);
  }
});

send({
  jsonrpc: "2.0",
  id: "cove-desktop-smoke-initialize",
  method: "initialize",
  params: {
    clientInfo: {
      name: "codex-cove-desktop-smoke",
      title: "Codex Cove Desktop Smoke",
      version: "0.1.0",
    },
    capabilities: { experimentalApi: false },
  },
});
