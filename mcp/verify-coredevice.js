#!/usr/bin/env node

const { spawn } = require("node:child_process");
const path = require("node:path");

const workspaceRoot = path.resolve(__dirname, "..");
const expectedUDID = process.env.LOOKIN_EXPECT_UDID || "";
const expectedIdentifier = process.env.LOOKIN_EXPECT_DEVICE_IDENTIFIER || "";

function encode(message) {
  const json = JSON.stringify(message);
  return `Content-Length: ${Buffer.byteLength(json, "utf8")}\r\n\r\n${json}`;
}

async function main() {
  const child = spawn("node", [path.join(__dirname, "server.js")], {
    cwd: workspaceRoot,
    stdio: ["pipe", "pipe", "inherit"],
  });

  let readBuffer = Buffer.alloc(0);
  const pending = new Map();

  function flush() {
    while (true) {
      const headerEnd = readBuffer.indexOf("\r\n\r\n");
      if (headerEnd === -1) {
        return;
      }

      const headerText = readBuffer.slice(0, headerEnd).toString("utf8");
      const match = headerText.match(/Content-Length:\s*(\d+)/i);
      if (!match) {
        throw new Error("Missing Content-Length header.");
      }

      const contentLength = Number(match[1]);
      const totalLength = headerEnd + 4 + contentLength;
      if (readBuffer.length < totalLength) {
        return;
      }

      const body = readBuffer.slice(headerEnd + 4, totalLength).toString("utf8");
      readBuffer = readBuffer.slice(totalLength);
      const message = JSON.parse(body);
      if (message.id && pending.has(message.id)) {
        pending.get(message.id)(message);
        pending.delete(message.id);
      }
    }
  }

  child.stdout.on("data", (chunk) => {
    readBuffer = Buffer.concat([readBuffer, chunk]);
    flush();
  });

  function request(message, timeoutMs = 120000) {
    return new Promise((resolve, reject) => {
      let settled = false;
      const timer = setTimeout(() => {
        if (settled) {
          return;
        }
        settled = true;
        pending.delete(message.id);
        reject(new Error(`Timed out waiting for ${message.method}`));
      }, timeoutMs);

      pending.set(message.id, (value) => {
        if (settled) {
          return;
        }
        settled = true;
        clearTimeout(timer);
        resolve(value);
      });
      child.stdin.write(encode(message));
    });
  }

  try {
    await request({
      jsonrpc: "2.0",
      id: 1,
      method: "initialize",
      params: {
        protocolVersion: "2024-11-05",
        capabilities: {},
        clientInfo: { name: "lookin-verify", version: "1.0" },
      },
    });
    child.stdin.write(encode({ jsonrpc: "2.0", method: "notifications/initialized", params: {} }));

    const response = await request({
      jsonrpc: "2.0",
      id: 2,
      method: "tools/call",
      params: { name: "lookin_list_targets", arguments: {} },
    });

    const targets = response.result?.structuredContent || [];
    const coreDeviceTargets = targets.filter((target) => target.transport === "coredevice");
    const matchingTargets = coreDeviceTargets.filter((target) => {
      if (expectedUDID && target.udid !== expectedUDID) {
        return false;
      }
      if (expectedIdentifier && target.device_identifier !== expectedIdentifier) {
        return false;
      }
      return true;
    });

    console.log(JSON.stringify({
      expected_udid: expectedUDID || null,
      expected_device_identifier: expectedIdentifier || null,
      coredevice_target_count: coreDeviceTargets.length,
      matching_target_count: matchingTargets.length,
      matching_targets: matchingTargets,
    }, null, 2));

    if (matchingTargets.length === 0) {
      process.exitCode = 1;
    }
  } finally {
    child.kill("SIGTERM");
  }
}

main().catch((error) => {
  console.error(error.stack || error.message || String(error));
  process.exit(1);
});
