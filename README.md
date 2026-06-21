# lookin-mcp

An MCP server for inspecting runtime iOS UI through LookinServer.

This repository contains two parts:

- `lookinextension/`
  A macOS native bridge that talks to `LookinServer` over the Lookin protocol.
- `mcp/`
  A stdio MCP server that starts and reuses the native bridge, then exposes structured tools for agents.

## What It Can Do

- Discover reachable Debug apps with `LookinServer` integrated
- Create logical sessions for targets
- Fetch runtime view hierarchy as JSON
- Search nodes by class name, text, identifier, hidden state, and frame
- Fetch node details and screenshots
- Capture hierarchy snapshots and diff them

Current screenshots returned by the bridge are persisted as PNG files.

## Requirements

- macOS
- Xcode command line tools
- Node.js
- A running iOS Simulator app or foreground Debug build on device
- `LookinServer` integrated into the target app

## Quick Start

1. Clone this repository.
2. Configure your MCP client to launch `mcp/server.js`.
3. Start with `lookin_list_targets`, then `lookin_connect`, then `lookin_get_hierarchy`.

Example MCP config:

```json
{
  "mcpServers": {
    "lookin-mcp": {
      "command": "node",
      "args": [
        "/absolute/path/to/lookin-mcp/mcp/server.js"
      ],
      "env": {
        "LOOKIN_BRIDGE_DERIVED_DATA": "/tmp/lookinextension-derived"
      }
    }
  }
}
```

## Repo Layout

- `lookinextension/lookinextension/main.swift`
  CLI entrypoint and daemon mode
- `lookinextension/lookinextension/LKXBridgeService.m`
  Core native bridge implementation
- `lookinextension/lookinextension/Vendor/`
  Embedded Lookin shared protocol and model code required to build the bridge
- `mcp/server.js`
  MCP server entrypoint
- `mcp/verify-coredevice.js`
  Lightweight CoreDevice discovery verification
- `mcp/verify-e2e.js`
  End-to-end verification script

## More Details

See [mcp/README.md](mcp/README.md) for tool list, verification scripts, and bridge behavior.
