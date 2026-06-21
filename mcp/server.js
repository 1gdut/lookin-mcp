#!/usr/bin/env node

const fs = require("node:fs");
const path = require("node:path");
const { execFile, spawn } = require("node:child_process");
const { promisify } = require("node:util");

const execFileAsync = promisify(execFile);

const WORKSPACE_ROOT = path.resolve(__dirname, "..");
const BUNDLED_BRIDGE_BIN = path.join(WORKSPACE_ROOT, "bin", "lookinextension");
const XCODE_PROJECT = path.join(WORKSPACE_ROOT, "lookinextension", "lookinextension.xcodeproj");
const DERIVED_DATA = process.env.LOOKIN_BRIDGE_DERIVED_DATA || "/private/tmp/lookinextension-derived";
const SOURCE_BRIDGE_BIN = path.join(DERIVED_DATA, "Build", "Products", "Debug", "lookinextension");

const SERVER_INFO = {
  name: "lookin-mcp",
  version: "0.2.0",
};

const TOOLS = [
  {
    name: "lookin_list_targets",
    description: "Discover running Debug iOS apps that have LookinServer integrated and are reachable from this Mac.",
    inputSchema: {
      type: "object",
      properties: {},
      additionalProperties: false,
    },
  },
  {
    name: "lookin_list_sessions",
    description: "List persisted logical Lookin sessions and their snapshot references.",
    inputSchema: {
      type: "object",
      properties: {},
      additionalProperties: false,
    },
  },
  {
    name: "lookin_connect",
    description: "Create a persisted logical session for a target identifier returned by lookin_list_targets.",
    inputSchema: {
      type: "object",
      properties: {
        target_id: {
          type: "string",
          description: "Target identifier returned by lookin_list_targets.",
        },
      },
      required: ["target_id"],
      additionalProperties: false,
    },
  },
  {
    name: "lookin_disconnect",
    description: "Delete a persisted logical session and all snapshots captured inside it.",
    inputSchema: {
      type: "object",
      properties: {
        session_id: {
          type: "string",
          description: "Session identifier returned by lookin_connect.",
        },
      },
      required: ["session_id"],
      additionalProperties: false,
    },
  },
  {
    name: "lookin_list_snapshots",
    description: "List captured hierarchy snapshots, optionally scoped to a single session.",
    inputSchema: {
      type: "object",
      properties: {
        session_id: {
          type: "string",
          description: "Optional session identifier returned by lookin_connect.",
        },
      },
      additionalProperties: false,
    },
  },
  {
    name: "lookin_capture_snapshot",
    description: "Capture and persist a filtered hierarchy snapshot for a session.",
    inputSchema: {
      type: "object",
      properties: {
        session_id: {
          type: "string",
          description: "Session identifier returned by lookin_connect.",
        },
        name: {
          type: "string",
          description: "Optional human-readable snapshot name.",
        },
        depth: {
          type: "integer",
          description: "Optional max depth to include, where 0 means roots only.",
        },
        include_hidden: {
          type: "boolean",
          description: "Whether to retain hidden nodes in the captured hierarchy.",
        },
        focus_path: {
          type: "array",
          description: "Optional path array identifying a focused subtree, such as [0,1,2].",
          items: { type: "integer" },
        },
      },
      required: ["session_id"],
      additionalProperties: false,
    },
  },
  {
    name: "lookin_diff_hierarchy",
    description: "Diff two captured hierarchy snapshots from the same session.",
    inputSchema: {
      type: "object",
      properties: {
        session_id: {
          type: "string",
          description: "Session identifier returned by lookin_connect.",
        },
        snapshot_a: {
          type: "string",
          description: "First snapshot identifier returned by lookin_capture_snapshot.",
        },
        snapshot_b: {
          type: "string",
          description: "Second snapshot identifier returned by lookin_capture_snapshot.",
        },
      },
      required: ["session_id", "snapshot_a", "snapshot_b"],
      additionalProperties: false,
    },
  },
  {
    name: "lookin_ping_target",
    description: "Ping a specific Lookin target or session to verify reachability, foreground state, and protocol compatibility.",
    inputSchema: {
      type: "object",
      properties: {
        target_id: {
          type: "string",
          description: "Target identifier returned by lookin_list_targets.",
        },
        session_id: {
          type: "string",
          description: "Optional session identifier returned by lookin_connect.",
        },
      },
      additionalProperties: false,
    },
  },
  {
    name: "lookin_get_hierarchy",
    description: "Fetch the current runtime view hierarchy for a specific Lookin target or session as structured JSON.",
    inputSchema: {
      type: "object",
      properties: {
        target_id: {
          type: "string",
          description: "Optional target identifier returned by lookin_list_targets.",
        },
        session_id: {
          type: "string",
          description: "Optional session identifier returned by lookin_connect.",
        },
        depth: {
          type: "integer",
          description: "Optional max depth to include, where 0 means roots only.",
        },
        include_hidden: {
          type: "boolean",
          description: "Whether to retain hidden nodes in the returned hierarchy.",
        },
        focus_path: {
          type: "array",
          description: "Optional path array identifying a focused subtree, such as [0,1,2].",
          items: { type: "integer" },
        },
      },
      additionalProperties: false,
    },
  },
  {
    name: "lookin_find_nodes",
    description: "Search hierarchy nodes with richer filters including text, identifiers, and frame constraints.",
    inputSchema: {
      type: "object",
      properties: {
        target_id: {
          type: "string",
          description: "Optional target identifier returned by lookin_list_targets.",
        },
        session_id: {
          type: "string",
          description: "Optional session identifier returned by lookin_connect.",
        },
        node_id: {
          type: "integer",
          description: "Optional exact node OID filter.",
        },
        class_name_contains: {
          type: "string",
          description: "Optional case-insensitive substring match on class_name.",
        },
        custom_title_contains: {
          type: "string",
          description: "Optional case-insensitive substring match on custom_title.",
        },
        memory_address_contains: {
          type: "string",
          description: "Optional case-insensitive substring match on memory_address.",
        },
        text_contains: {
          type: "string",
          description: "Optional case-insensitive substring match on the node's best-effort visible text.",
        },
        identifier_contains: {
          type: "string",
          description: "Optional case-insensitive substring match across best-effort searchable identifiers.",
        },
        hidden: {
          type: "boolean",
          description: "Optional exact hidden-state filter.",
        },
        frame: {
          type: "object",
          description: "Optional frame constraint rectangle.",
          properties: {
            x: { type: "number" },
            y: { type: "number" },
            width: { type: "number" },
            height: { type: "number" },
          },
          required: ["x", "y", "width", "height"],
          additionalProperties: false,
        },
        frame_match: {
          type: "string",
          enum: ["exact", "intersects", "contains"],
          description: "How the node frame should relate to the query frame.",
        },
        limit: {
          type: "integer",
          description: "Optional maximum number of matches to return.",
        },
      },
      additionalProperties: false,
    },
  },
  {
    name: "lookin_find_views",
    description: "Alias of lookin_find_nodes for higher-level agent workflows that think in views.",
    inputSchema: {
      type: "object",
      properties: {
        target_id: { type: "string" },
        session_id: { type: "string" },
        node_id: { type: "integer" },
        class_name_contains: { type: "string" },
        custom_title_contains: { type: "string" },
        memory_address_contains: { type: "string" },
        text_contains: { type: "string" },
        identifier_contains: { type: "string" },
        hidden: { type: "boolean" },
        frame: {
          type: "object",
          properties: {
            x: { type: "number" },
            y: { type: "number" },
            width: { type: "number" },
            height: { type: "number" },
          },
          required: ["x", "y", "width", "height"],
          additionalProperties: false,
        },
        frame_match: {
          type: "string",
          enum: ["exact", "intersects", "contains"],
        },
        limit: { type: "integer" },
      },
      additionalProperties: false,
    },
  },
  {
    name: "lookin_get_object",
    description: "Fetch the runtime object metadata for a specific hierarchy node, including its class chain and object identity fields.",
    inputSchema: {
      type: "object",
      properties: {
        target_id: {
          type: "string",
          description: "Optional target identifier returned by lookin_list_targets.",
        },
        session_id: {
          type: "string",
          description: "Optional session identifier returned by lookin_connect.",
        },
        node_id: {
          type: "integer",
          description: "Node OID returned by lookin_get_hierarchy. The bridge will automatically resolve a view-backed node_id to its layer-backed detail node when needed.",
        },
      },
      required: ["node_id"],
      additionalProperties: false,
    },
  },
  {
    name: "lookin_get_view_details",
    description: "Fetch runtime detail data for a specific hierarchy node, including basis visual info, attr groups, optional subitems, and an optional node screenshot.",
    inputSchema: {
      type: "object",
      properties: {
        target_id: {
          type: "string",
          description: "Optional target identifier returned by lookin_list_targets.",
        },
        session_id: {
          type: "string",
          description: "Optional session identifier returned by lookin_connect.",
        },
        node_id: {
          type: "integer",
          description: "Node OID returned by lookin_get_hierarchy. The bridge will automatically resolve a view-backed node_id to its layer-backed detail node when needed.",
        },
        include_subitems: {
          type: "boolean",
          description: "Whether to request fresh subitems for the node.",
        },
        screenshot_mode: {
          type: "string",
          enum: ["none", "group", "solo"],
          description: "Whether to fetch no screenshot, a grouped screenshot, or a solo screenshot for the node.",
        },
      },
      required: ["node_id"],
      additionalProperties: false,
    },
  },
  {
    name: "lookin_get_screenshot",
    description: "Fetch either the app-level screenshot or a node-level screenshot and return a temporary local file path.",
    inputSchema: {
      type: "object",
      properties: {
        target_id: {
          type: "string",
          description: "Optional target identifier returned by lookin_list_targets.",
        },
        session_id: {
          type: "string",
          description: "Optional session identifier returned by lookin_connect.",
        },
        node_id: {
          type: "integer",
          description: "Optional node OID. Omit it to fetch the app-level screenshot. The bridge will automatically resolve a view-backed node_id to its layer-backed screenshot node when needed.",
        },
        mode: {
          type: "string",
          enum: ["app", "group", "solo"],
          description: "Screenshot mode. Use app without node_id, or group/solo with node_id.",
        },
      },
      additionalProperties: false,
    },
  },
];

let buildEnsured = false;
let readBuffer = Buffer.alloc(0);
let bridgeCommandQueue = Promise.resolve();
let bridgeDaemon = null;
let bridgeDaemonReady = null;
let bridgeDaemonBuffer = "";
let bridgeDaemonNextRequestId = 1;
const bridgeDaemonRequests = new Map();
let resolvedBridgeBin = null;

function resolveBridgeBinaryPath() {
  if (resolvedBridgeBin && fs.existsSync(resolvedBridgeBin)) {
    return resolvedBridgeBin;
  }

  const envBridgeBin = process.env.LOOKIN_BRIDGE_BIN;
  if (envBridgeBin && fs.existsSync(envBridgeBin)) {
    resolvedBridgeBin = envBridgeBin;
    return resolvedBridgeBin;
  }

  if (fs.existsSync(BUNDLED_BRIDGE_BIN)) {
    resolvedBridgeBin = BUNDLED_BRIDGE_BIN;
    return resolvedBridgeBin;
  }

  if (fs.existsSync(SOURCE_BRIDGE_BIN)) {
    resolvedBridgeBin = SOURCE_BRIDGE_BIN;
    return resolvedBridgeBin;
  }

  return null;
}

async function ensureBridgeBinary() {
  const existingBridgeBin = resolveBridgeBinaryPath();
  if (buildEnsured && existingBridgeBin) {
    buildEnsured = true;
    return;
  }

  if (existingBridgeBin) {
    buildEnsured = true;
    return;
  }

  if (!fs.existsSync(XCODE_PROJECT)) {
    throw new Error(
      "No native bridge binary was found. " +
      `Expected one of: LOOKIN_BRIDGE_BIN, bundled ${BUNDLED_BRIDGE_BIN}, or source build output ${SOURCE_BRIDGE_BIN}.`
    );
  }

  const args = [
    "-project", XCODE_PROJECT,
    "-scheme", "lookinextension",
    "-configuration", "Debug",
    "-derivedDataPath", DERIVED_DATA,
    "build",
  ];

  try {
    await execFileAsync("xcodebuild", args, {
      cwd: WORKSPACE_ROOT,
      maxBuffer: 8 * 1024 * 1024,
    });
  } catch (error) {
    const stderr = error.stderr || "";
    const stdout = error.stdout || "";
    throw new Error(`Failed to build native bridge.\n${stderr || stdout}`);
  }

  resolvedBridgeBin = resolveBridgeBinaryPath();
  if (!resolvedBridgeBin) {
    throw new Error(`Native bridge binary was not produced at ${SOURCE_BRIDGE_BIN}`);
  }

  buildEnsured = true;
}

async function runBridge(command, args = [], timeoutMs = 30000) {
  const child = await ensureBridgeDaemon();
  const requestID = bridgeDaemonNextRequestId++;

  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      bridgeDaemonRequests.delete(requestID);
      reject(bridgeError("request_timeout", `Bridge daemon request timed out after ${timeoutMs}ms.`));
    }, timeoutMs);

    bridgeDaemonRequests.set(requestID, {
      resolve,
      reject,
      timer,
    });

    const envelope = JSON.stringify({
      id: requestID,
      command,
      args,
    });

    child.stdin.write(`${envelope}\n`, (error) => {
      if (!error) {
        return;
      }

      clearTimeout(timer);
      bridgeDaemonRequests.delete(requestID);
      reject(bridgeError("bridge_exec_failed", error.message || "Failed to write to bridge daemon stdin."));
    });
  });
}

function runBridgeSerial(command, args = [], timeoutMs = 30000) {
  const task = bridgeCommandQueue.catch(() => {}).then(() => runBridge(command, args, timeoutMs));
  bridgeCommandQueue = task.catch(() => {});
  return task;
}

function parseBridgePayload(stdout) {
  try {
    return JSON.parse(stdout);
  } catch (error) {
    throw bridgeError("bridge_invalid_json", `Failed to parse bridge JSON output: ${error.message}`);
  }
}

async function ensureBridgeDaemon() {
  if (bridgeDaemon && !bridgeDaemon.killed) {
    return bridgeDaemon;
  }

  if (bridgeDaemonReady) {
    return bridgeDaemonReady;
  }

  bridgeDaemonReady = (async () => {
    await ensureBridgeBinary();
    const bridgeBin = resolveBridgeBinaryPath();
    if (!bridgeBin) {
      throw bridgeError("bridge_exec_failed", "No native bridge binary is available.");
    }

    const child = spawn(bridgeBin, ["daemon"], {
      cwd: WORKSPACE_ROOT,
      stdio: ["pipe", "pipe", "pipe"],
    });

    child.stdout.setEncoding("utf8");
    child.stdout.on("data", (chunk) => {
      bridgeDaemonBuffer += chunk;
      flushBridgeDaemonLines();
    });

    child.stderr.setEncoding("utf8");
    child.stderr.on("data", (chunk) => {
      const lines = String(chunk)
        .split(/\r?\n/)
        .map((line) => line.trim())
        .filter(Boolean);
      for (const line of lines) {
        if (line.startsWith("{")) {
          try {
            handleBridgeDaemonPayload(JSON.parse(line));
          } catch {
            // Ignore non-protocol stderr noise from the native bridge.
          }
        }
      }
    });

    child.on("error", (error) => {
      rejectBridgeDaemonPending(bridgeError("bridge_exec_failed", error.message || "Bridge daemon failed to start."));
      bridgeDaemon = null;
      bridgeDaemonReady = null;
    });

    child.on("exit", (code, signal) => {
      const reason = code !== null
        ? `Bridge daemon exited with code ${code}.`
        : `Bridge daemon exited due to signal ${signal}.`;
      rejectBridgeDaemonPending(bridgeError("bridge_exec_failed", reason));
      bridgeDaemon = null;
      bridgeDaemonReady = null;
      bridgeDaemonBuffer = "";
    });

    bridgeDaemon = child;
    return child;
  })();

  try {
    return await bridgeDaemonReady;
  } finally {
    if (!bridgeDaemon) {
      bridgeDaemonReady = null;
    }
  }
}

function flushBridgeDaemonLines() {
  while (true) {
    const newlineIndex = bridgeDaemonBuffer.indexOf("\n");
    if (newlineIndex === -1) {
      return;
    }

    const line = bridgeDaemonBuffer.slice(0, newlineIndex).trim();
    bridgeDaemonBuffer = bridgeDaemonBuffer.slice(newlineIndex + 1);
    if (!line) {
      continue;
    }

    let payload;
    try {
      payload = JSON.parse(line);
    } catch (error) {
      rejectBridgeDaemonPending(bridgeError("bridge_invalid_json", `Failed to parse daemon output: ${error.message}`));
      return;
    }

    handleBridgeDaemonPayload(payload);
  }
}

function handleBridgeDaemonPayload(payload) {
  const requestID = payload?.id;
  const pending = bridgeDaemonRequests.get(requestID);
  if (!pending) {
    return;
  }

  clearTimeout(pending.timer);
  bridgeDaemonRequests.delete(requestID);

  if (!payload.ok) {
    pending.reject(bridgeError(payload.error?.code || "bridge_error", payload.error?.message || "Bridge command failed."));
    return;
  }

  pending.resolve(payload.result);
}

function rejectBridgeDaemonPending(error) {
  for (const [requestID, pending] of bridgeDaemonRequests.entries()) {
    clearTimeout(pending.timer);
    pending.reject(error);
    bridgeDaemonRequests.delete(requestID);
  }
}

function bridgeError(code, message) {
  const error = new Error(message);
  error.code = code;
  error.__isBridgeError = true;
  return error;
}

function successToolResult(result) {
  const text = JSON.stringify(result, null, 2);
  return {
    content: [
      {
        type: "text",
        text,
      },
    ],
    structuredContent: result,
  };
}

function errorToolResult(error) {
  const message = error.message || "Unknown error";
  const code = error.code || "tool_error";
  return {
    content: [
      {
        type: "text",
        text: JSON.stringify({ code, message }, null, 2),
      },
    ],
    isError: true,
    structuredContent: {
      code,
      message,
    },
  };
}

async function handleToolCall(name, args) {
  switch (name) {
    case "lookin_list_targets":
      return successToolResult(await runBridgeSerial("list-targets"));
    case "lookin_list_sessions":
      return successToolResult(await runBridgeSerial("list-sessions"));
    case "lookin_connect":
      requireString(args, "target_id");
      return successToolResult(await runBridgeSerial("connect", ["--target", args.target_id]));
    case "lookin_disconnect":
      requireString(args, "session_id");
      return successToolResult(await runBridgeSerial("disconnect", ["--session", args.session_id]));
    case "lookin_list_snapshots": {
      const commandArgs = [];
      if (args.session_id !== undefined) {
        requireString(args, "session_id");
        commandArgs.push("--session", args.session_id);
      }
      return successToolResult(await runBridgeSerial("list-snapshots", commandArgs, 30000));
    }
    case "lookin_capture_snapshot": {
      requireString(args, "session_id");
      const commandArgs = ["--session", args.session_id];
      if (args.name !== undefined) {
        requireString(args, "name");
        commandArgs.push("--name", args.name);
      }
      appendHierarchyOptions(commandArgs, args);
      return successToolResult(await runBridgeSerial("capture-snapshot", commandArgs, 60000));
    }
    case "lookin_diff_hierarchy":
      requireString(args, "session_id");
      requireString(args, "snapshot_a");
      requireString(args, "snapshot_b");
      return successToolResult(await runBridgeSerial("diff-hierarchy", [
        "--session", args.session_id,
        "--snapshot-a", args.snapshot_a,
        "--snapshot-b", args.snapshot_b,
      ], 60000));
    case "lookin_ping_target":
      return successToolResult(await runBridgeSerial("ping", targetOrSessionArgs(args)));
    case "lookin_get_hierarchy": {
      const commandArgs = targetOrSessionArgs(args);
      appendHierarchyOptions(commandArgs, args);
      return successToolResult(await runBridgeSerial("hierarchy", commandArgs, 60000));
    }
    case "lookin_find_nodes":
    case "lookin_find_views": {
      const commandArgs = targetOrSessionArgs(args);
      if (args.node_id !== undefined) {
        requireInteger(args, "node_id");
        commandArgs.push("--node-id", String(args.node_id));
      }
      if (args.class_name_contains) {
        requireString(args, "class_name_contains");
        commandArgs.push("--class-name-contains", args.class_name_contains);
      }
      if (args.custom_title_contains) {
        requireString(args, "custom_title_contains");
        commandArgs.push("--custom-title-contains", args.custom_title_contains);
      }
      if (args.memory_address_contains) {
        requireString(args, "memory_address_contains");
        commandArgs.push("--memory-address-contains", args.memory_address_contains);
      }
      if (args.text_contains) {
        requireString(args, "text_contains");
        commandArgs.push("--text-contains", args.text_contains);
      }
      if (args.identifier_contains) {
        requireString(args, "identifier_contains");
        commandArgs.push("--identifier-contains", args.identifier_contains);
      }
      if (args.hidden !== undefined) {
        requireBoolean(args, "hidden");
        commandArgs.push("--hidden", String(args.hidden));
      }
      if (args.frame !== undefined) {
        requireFrame(args, "frame");
        commandArgs.push("--frame", `${args.frame.x},${args.frame.y},${args.frame.width},${args.frame.height}`);
      }
      if (args.frame_match !== undefined) {
        requireString(args, "frame_match");
        commandArgs.push("--frame-match", args.frame_match);
      }
      if (args.limit !== undefined) {
        requireInteger(args, "limit");
        commandArgs.push("--limit", String(args.limit));
      }
      return successToolResult(await runBridgeSerial("find-nodes", commandArgs, 60000));
    }
    case "lookin_get_object": {
      requireInteger(args, "node_id");
      const commandArgs = targetOrSessionArgs(args);
      commandArgs.push("--node-id", String(args.node_id));
      return successToolResult(await runBridgeSerial("object", commandArgs, 30000));
    }
    case "lookin_get_view_details": {
      requireInteger(args, "node_id");
      const commandArgs = targetOrSessionArgs(args);
      commandArgs.push("--node-id", String(args.node_id));
      if (args.screenshot_mode) {
        commandArgs.push("--screenshot-mode", args.screenshot_mode);
      }
      if (args.include_subitems === true) {
        commandArgs.push("--include-subitems");
      }
      return successToolResult(await runBridgeSerial("view-details", commandArgs, 60000));
    }
    case "lookin_get_screenshot": {
      const commandArgs = targetOrSessionArgs(args);
      if (args.node_id !== undefined) {
        requireInteger(args, "node_id");
        commandArgs.push("--node-id", String(args.node_id));
      }
      if (args.mode) {
        commandArgs.push("--mode", args.mode);
      }
      return successToolResult(await runBridgeSerial("screenshot", commandArgs, 60000));
    }
    default:
      throw bridgeError("tool_not_found", `Unknown tool: ${name}`);
  }
}

function targetOrSessionArgs(args) {
  const targetID = args?.target_id;
  const sessionID = args?.session_id;
  if (typeof targetID === "string" && targetID.trim() !== "") {
    return ["--target", targetID];
  }
  if (typeof sessionID === "string" && sessionID.trim() !== "") {
    return ["--session", sessionID];
  }
  throw bridgeError("invalid_arguments", "Expected either target_id or session_id.");
}

function appendHierarchyOptions(commandArgs, args) {
  if (args.depth !== undefined) {
    requireInteger(args, "depth");
    commandArgs.push("--depth", String(args.depth));
  }
  if (args.include_hidden !== undefined) {
    requireBoolean(args, "include_hidden");
    commandArgs.push("--include-hidden", String(args.include_hidden));
  }
  if (args.focus_path !== undefined) {
    if (!Array.isArray(args.focus_path) || args.focus_path.some((value) => !Number.isInteger(value) || value < 0)) {
      throw bridgeError("invalid_arguments", "focus_path must be an array of non-negative integers.");
    }
    commandArgs.push("--focus-path", args.focus_path.join(","));
  }
}

function requireString(args, key) {
  if (!args || typeof args[key] !== "string" || args[key].trim() === "") {
    throw bridgeError("invalid_arguments", `Expected a non-empty string argument: ${key}`);
  }
}

function requireInteger(args, key) {
  if (!args || !Number.isInteger(args[key]) || args[key] < 0) {
    throw bridgeError("invalid_arguments", `Expected a non-negative integer argument: ${key}`);
  }
}

function requireBoolean(args, key) {
  if (!args || typeof args[key] !== "boolean") {
    throw bridgeError("invalid_arguments", `Expected a boolean argument: ${key}`);
  }
}

function requireFrame(args, key) {
  const frame = args?.[key];
  if (!frame || typeof frame !== "object") {
    throw bridgeError("invalid_arguments", `Expected an object argument: ${key}`);
  }
  for (const prop of ["x", "y", "width", "height"]) {
    if (typeof frame[prop] !== "number" || Number.isNaN(frame[prop])) {
      throw bridgeError("invalid_arguments", `Expected numeric frame.${prop}.`);
    }
  }
}

function writeMessage(message) {
  const json = JSON.stringify(message);
  const bytes = Buffer.byteLength(json, "utf8");
  process.stdout.write(`Content-Length: ${bytes}\r\n\r\n${json}`);
}

function sendResult(id, result) {
  writeMessage({
    jsonrpc: "2.0",
    id,
    result,
  });
}

function sendError(id, code, message, data) {
  writeMessage({
    jsonrpc: "2.0",
    id,
    error: {
      code,
      message,
      ...(data !== undefined ? { data } : {}),
    },
  });
}

async function handleRequest(message) {
  const { id, method, params } = message;

  try {
    switch (method) {
      case "initialize":
        sendResult(id, {
          protocolVersion: "2024-11-05",
          capabilities: {
            tools: {
              listChanged: false,
            },
          },
          serverInfo: SERVER_INFO,
        });
        return;

      case "ping":
        sendResult(id, {});
        return;

      case "tools/list":
        sendResult(id, { tools: TOOLS });
        return;

      case "tools/call": {
        const name = params?.name;
        const argumentsObject = params?.arguments || {};
        try {
          const result = await handleToolCall(name, argumentsObject);
          sendResult(id, result);
        } catch (error) {
          sendResult(id, errorToolResult(error));
        }
        return;
      }

      case "notifications/initialized":
        return;

      default:
        sendError(id, -32601, `Method not found: ${method}`);
    }
  } catch (error) {
    const code = error.__isBridgeError ? -32001 : -32603;
    sendError(id, code, error.message || "Internal error", error.code ? { code: error.code } : undefined);
  }
}

function tryReadMessages() {
  while (true) {
    const headerEnd = readBuffer.indexOf("\r\n\r\n");
    if (headerEnd === -1) {
      return;
    }

    const headerText = readBuffer.slice(0, headerEnd).toString("utf8");
    const headers = Object.fromEntries(
      headerText
        .split("\r\n")
        .map((line) => {
          const index = line.indexOf(":");
          return [line.slice(0, index).trim().toLowerCase(), line.slice(index + 1).trim()];
        }),
    );

    const contentLength = Number(headers["content-length"]);
    if (!Number.isFinite(contentLength)) {
      throw new Error("Invalid Content-Length header.");
    }

    const totalLength = headerEnd + 4 + contentLength;
    if (readBuffer.length < totalLength) {
      return;
    }

    const body = readBuffer.slice(headerEnd + 4, totalLength).toString("utf8");
    readBuffer = readBuffer.slice(totalLength);

    let message;
    try {
      message = JSON.parse(body);
    } catch (error) {
      sendError(null, -32700, `Parse error: ${error.message}`);
      continue;
    }

    Promise.resolve(handleRequest(message)).catch((error) => {
      sendError(message.id ?? null, -32603, error.message || "Internal error");
    });
  }
}

process.stdin.on("data", (chunk) => {
  readBuffer = Buffer.concat([readBuffer, chunk]);
  try {
    tryReadMessages();
  } catch (error) {
    sendError(null, -32603, error.message || "Internal server error");
  }
});

process.stdin.on("end", () => {
  // Let the event loop drain naturally so any in-flight tool call can still reply.
});

process.on("exit", () => {
  if (bridgeDaemon && !bridgeDaemon.killed) {
    bridgeDaemon.kill();
  }
});
