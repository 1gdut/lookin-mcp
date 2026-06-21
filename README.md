# lookin-mcp

English | [中文](#中文说明)

An MCP server for inspecting runtime iOS UI through `LookinServer`.

This repository contains two parts:

- `lookinextension/`
  A macOS native bridge that talks to `LookinServer` over the Lookin protocol.
- `mcp/`
  A stdio MCP server that starts and reuses the native bridge, then exposes structured tools for agents.

## What It Can Do

- Discover reachable Debug apps with `LookinServer` integrated
- Create logical sessions for targets
- Fetch runtime view hierarchy as structured JSON
- Search nodes by class name, text, identifier, hidden state, and frame
- Fetch node details and screenshots
- Capture hierarchy snapshots and diff them

Current screenshots returned by the bridge are persisted as PNG files.

## Requirements

- macOS
- Xcode command line tools
- Node.js
- A running iOS Simulator app or a foreground Debug build on device
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

See [mcp/README.md](mcp/README.md) for the full tool list, verification scripts, and bridge behavior.

---

## 中文说明

`lookin-mcp` 是一个基于 `LookinServer` 的 MCP 服务，用来把 iOS App 的运行时 UI 信息暴露给 agent 或其他支持 MCP 的客户端。

这个仓库主要包含两部分：

- `lookinextension/`
  macOS 原生桥接层，直接通过 Lookin 协议与 `LookinServer` 通信。
- `mcp/`
  stdio 形式的 MCP server，负责启动并复用原生 bridge，再把能力包装成 MCP tools。

## 能做什么

- 发现当前可连接、已集成 `LookinServer` 的 Debug App
- 为目标创建逻辑会话
- 以结构化 JSON 形式获取运行时 view hierarchy
- 按类名、文本、identifier、hidden 状态、frame 搜索节点
- 获取节点详情和截图
- 保存 hierarchy snapshot，并比较两次 snapshot 的差异

当前 bridge 对外落盘返回的截图格式为 PNG。

## 环境要求

- macOS
- Xcode 命令行工具
- Node.js
- 正在运行的 iOS 模拟器 App，或前台运行中的真机 Debug App
- 目标 App 已集成 `LookinServer`

## 快速开始

1. 克隆本仓库。
2. 在你的 MCP 客户端里配置 `mcp/server.js` 作为 server 启动入口。
3. 先调用 `lookin_list_targets`，再调用 `lookin_connect`，然后用 `lookin_get_hierarchy` 拉取运行时层级。

示例 MCP 配置：

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

## 仓库结构

- `lookinextension/lookinextension/main.swift`
  CLI 入口与 daemon 模式入口
- `lookinextension/lookinextension/LKXBridgeService.m`
  原生 bridge 核心实现
- `lookinextension/lookinextension/Vendor/`
  构建 bridge 所需的 Lookin 协议与共享模型代码
- `mcp/server.js`
  MCP server 入口
- `mcp/verify-coredevice.js`
  CoreDevice 发现链路验证脚本
- `mcp/verify-e2e.js`
  端到端验证脚本

## 更多说明

更完整的工具列表、验证脚本和 bridge 行为说明见 [mcp/README.md](mcp/README.md)。
