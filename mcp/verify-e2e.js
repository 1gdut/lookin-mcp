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
  let nextID = 1;

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

  function request(method, params, timeoutMs = 120000) {
    const id = nextID++;
    return new Promise((resolve, reject) => {
      let settled = false;
      const timer = setTimeout(() => {
        if (settled) {
          return;
        }
        settled = true;
        pending.delete(id);
        reject(new Error(`Timed out waiting for ${method}`));
      }, timeoutMs);

      pending.set(id, (value) => {
        if (settled) {
          return;
        }
        settled = true;
        clearTimeout(timer);
        resolve(value);
      });

      child.stdin.write(encode({
        jsonrpc: "2.0",
        id,
        method,
        params,
      }));
    });
  }

  async function callTool(name, args = {}, timeoutMs = 120000) {
    const response = await request("tools/call", { name, arguments: args }, timeoutMs);
    const result = response.result?.structuredContent;
    if (response.result?.isError) {
      throw new Error(`${name} failed: ${JSON.stringify(result)}`);
    }
    return result;
  }

  try {
    await request("initialize", {
      protocolVersion: "2024-11-05",
      capabilities: {},
      clientInfo: { name: "lookin-e2e", version: "1.0" },
    });
    child.stdin.write(encode({ jsonrpc: "2.0", method: "notifications/initialized", params: {} }));

    const targets = await callTool("lookin_list_targets");
    const activeTargets = targets.filter((target) => target.state === "active");
    const matchingTargets = activeTargets.filter((target) => {
      if (expectedUDID && target.udid !== expectedUDID) {
        return false;
      }
      if (expectedIdentifier && target.device_identifier !== expectedIdentifier) {
        return false;
      }
      return true;
    });

    if (matchingTargets.length === 0) {
      throw new Error("No active matching Lookin target was found.");
    }

    const target = matchingTargets[0];
    const session = await callTool("lookin_connect", { target_id: target.target_id });
    const sessionID = session.session_id;

    const sessions = await callTool("lookin_list_sessions");
    if (!sessions.some((item) => item.session_id === sessionID)) {
      throw new Error("Connected session did not appear in lookin_list_sessions.");
    }

    const hierarchy = await callTool("lookin_get_hierarchy", {
      session_id: sessionID,
      depth: 2,
      include_hidden: false,
    });
    if (!(hierarchy.flat_node_count > 0)) {
      throw new Error("Filtered hierarchy returned no nodes.");
    }

    const viewMatches = await callTool("lookin_find_views", {
      session_id: sessionID,
      class_name_contains: "UILabel",
      identifier_contains: "lb_t_t",
      limit: 3,
    });
    if (!(viewMatches.match_count > 0)) {
      throw new Error("Richer view query returned no matches.");
    }

    const snapshotA = await callTool("lookin_capture_snapshot", {
      session_id: sessionID,
      name: "verify-depth-1",
      depth: 1,
      include_hidden: false,
    });
    const snapshotB = await callTool("lookin_capture_snapshot", {
      session_id: sessionID,
      name: "verify-depth-2",
      depth: 2,
      include_hidden: false,
    });

    const snapshots = await callTool("lookin_list_snapshots", { session_id: sessionID });
    if (!snapshots.some((item) => item.snapshot_id === snapshotA.snapshot_id) ||
        !snapshots.some((item) => item.snapshot_id === snapshotB.snapshot_id)) {
      throw new Error("Captured snapshots did not appear in lookin_list_snapshots.");
    }

    const diff = await callTool("lookin_diff_hierarchy", {
      session_id: sessionID,
      snapshot_a: snapshotA.snapshot_id,
      snapshot_b: snapshotB.snapshot_id,
    });
    if (!(diff.summary?.after_flat_node_count > diff.summary?.before_flat_node_count)) {
      throw new Error("Hierarchy diff did not report the expected depth-based node increase.");
    }

    console.log(JSON.stringify({
      target_id: target.target_id,
      session_id: sessionID,
      hierarchy_flat_node_count: hierarchy.flat_node_count,
      richer_query_match_count: viewMatches.match_count,
      snapshot_a: snapshotA.snapshot_id,
      snapshot_b: snapshotB.snapshot_id,
      diff_summary: diff.summary,
    }, null, 2));
  } finally {
    child.kill("SIGTERM");
  }
}

main().catch((error) => {
  console.error(error.stack || error.message || String(error));
  process.exit(1);
});
