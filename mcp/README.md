# Lookin MCP Server

这个目录提供一个可长期运行的 MCP stdio server，用来把本地 `lookinextension` 原生桥接器暴露给 agent。

当前链路是：

- `mcp/server.js` 常驻
- 它会懒启动一个 `lookinextension daemon`
- daemon 在同一个原生进程里复用 `LKXBridgeService`
- MCP 层会串行化 bridge 调用，减少 LookinServer 单连接被并发请求打断的概率

bridge 二进制查找顺序：

- `LOOKIN_BRIDGE_BIN`
- 仓库或 release 包内的 `../bin/lookinextension`
- 源码模式下的本地 `DerivedData` 构建产物

## 最新状态

- 2026-06-20 已完成真机 CoreDevice + LookinServer 端到端验证，并补上真机 IPv6 监听兼容。
- MCP/CLI 现在除了基础只读查询，还补上了：
  - 逻辑会话：`lookin_list_sessions` / `lookin_connect` / `lookin_disconnect`
  - 快照层：`lookin_list_snapshots` / `lookin_capture_snapshot`
  - 层级 diff：`lookin_diff_hierarchy`
  - 更丰富的层级裁剪：`depth` / `include_hidden` / `focus_path`
  - 更丰富的查询：`text_contains` / `identifier_contains` / `hidden` / `frame` / `frame_match`
  - 语义别名：`lookin_find_views`
- 已用真实设备 `00008030-0008711C0205402E` 上的 `TodoNote` (`com.zhuanz.TodoNote`) 验证通过：
  - `lookin_list_targets` 返回 `transport = "coredevice"` 的 active target
  - `lookin_connect` 能创建持久化 session
  - `lookin_get_hierarchy` 支持按深度裁剪
  - `lookin_find_views` 可按 identifier / 文本搜索
  - `lookin_capture_snapshot` / `lookin_diff_hierarchy` 能工作
- 一次实际抓取结果：
  - `source_flat_node_count = 132`
  - `root_count = 1`
  - 主内容为一个 `UICollectionView`
  - 前两个可见 `TodoNote.NoteCollectionViewCell` 的水平间距为 `16pt`

## 当前能力

- `lookin_list_targets`
- `lookin_list_sessions`
- `lookin_connect`
- `lookin_disconnect`
- `lookin_list_snapshots`
- `lookin_capture_snapshot`
- `lookin_diff_hierarchy`
- `lookin_ping_target`
- `lookin_get_hierarchy`
- `lookin_find_nodes`
- `lookin_find_views`
- `lookin_get_object`
- `lookin_get_view_details`
- `lookin_get_screenshot`

这些能力最终都走 Lookin 原生协议，但 MCP server 侧现在默认通过 `lookinextension daemon` 持久化复用连接。

## 启动方式

```bash
node mcp/server.js
```

或者：

```bash
cd mcp
npm start
```

## 验证脚本

只验证 CoreDevice 目标发现：

```bash
cd mcp
LOOKIN_EXPECT_UDID=00008030-0008711C0205402E npm run verify:coredevice
```

完整跑一遍 MCP 会话 + 查询 + 快照 + diff：

```bash
cd mcp
LOOKIN_EXPECT_UDID=00008030-0008711C0205402E npm run verify:e2e
```

`verify:e2e` 会执行：

1. `lookin_list_targets`
2. `lookin_connect`
3. `lookin_list_sessions`
4. `lookin_get_hierarchy`
5. `lookin_find_views`
6. `lookin_capture_snapshot` x2
7. `lookin_list_snapshots`
8. `lookin_diff_hierarchy`

默认会使用这个桥接器路径：

```text
/private/tmp/lookinextension-derived/Build/Products/Debug/lookinextension
```

如果该二进制不存在，server 会尝试自动执行一次：

```bash
xcodebuild -project lookinextension/lookinextension.xcodeproj \
  -scheme lookinextension \
  -configuration Debug \
  -derivedDataPath /private/tmp/lookinextension-derived \
  build
```

如果你使用的是预打包 release，并且目录里已经包含 `bin/lookinextension`，则不会触发这一步源码编译。

## 可选环境变量

- `LOOKIN_BRIDGE_BIN`
  - 显式指定桥接器二进制路径，优先级最高。
- `LOOKIN_BRIDGE_DERIVED_DATA`
  - 显式指定 `xcodebuild` 的 `DerivedData` 路径。
- `LOOKIN_EXPECT_UDID`
  - 供验证脚本筛选指定真机。
- `LOOKIN_EXPECT_DEVICE_IDENTIFIER`
  - 供验证脚本筛选指定 device identifier。

## 配置示例

可以参考 [config.example.json](./config.example.json) 把这个 server 挂到支持 MCP 的客户端里。

## 当前返回格式

- `lookin_list_targets`
  - 返回可连接目标数组；每项包含 `target_id`、`transport`、`port`、`state` 以及 app/device 基本信息。
  - 现代真机链路会优先通过 Xcode `devicectl` / CoreDevice 获取 `tunnelIPAddress`，并把真机 target 标记为 `transport = "coredevice"`；旧版 `usbmuxd/PTUSBHub` 仍作为补充路径保留。
  - 当真机 tunnel 已建立、但目标端口上没有 `LookinServer` 监听时，会返回 `state = "connection_refused"`，方便区分“设备没发现”与“app 未暴露 Lookin 端口”。
- `lookin_list_sessions`
  - 返回已持久化的逻辑 session 列表，每项会带 `session_id`、`target_id`、时间戳以及快照摘要。
- `lookin_connect` / `lookin_disconnect`
  - 创建或删除逻辑 session；session 数据和快照索引会持久化到临时状态目录。
- `lookin_list_snapshots` / `lookin_capture_snapshot`
  - 为指定 session 列出或保存 hierarchy snapshot。
  - snapshot 支持 `depth`、`include_hidden`、`focus_path` 裁剪参数，并保存裁剪后的树与统计信息。
- `lookin_diff_hierarchy`
  - 基于两个 snapshot 的路径键做 added / removed / changed diff。
  - 当前比较字段包括 `class_name`、`custom_title`、`text`、`identifier`、`hidden`、`alpha`、`frame`、`bounds`、`child_count`。
- `lookin_ping_target`
  - 返回单个目标或 session 的可达性、前后台状态、协议版本信息。
- `lookin_get_hierarchy`
  - 返回目标 app 的 runtime view hierarchy，包含 app 信息、根节点数量和递归节点树。
  - 支持 `depth`、`include_hidden`、`focus_path`。
  - 返回里会区分投影后的 `flat_node_count` 与源树的 `source_flat_node_count`。
- `lookin_find_nodes` / `lookin_find_views`
  - 按 `node_id`、`class_name_contains`、`custom_title_contains`、`memory_address_contains`、`text_contains`、`identifier_contains`、`hidden`、`frame`、`frame_match`、`limit` 检索节点。
  - `text_contains` 与 `identifier_contains` 会按需拉取 detail 信息做富化匹配。
- `lookin_get_object`
  - 返回某个节点对应的 runtime object 信息，比如 `oid`、内存地址、类链、special trace。
- `lookin_get_view_details`
  - 返回单个节点的 basis visual info、属性组、自定义属性组、可选 subitems，以及可选节点截图引用。
  - 如果传入的是 view-backed `node_id`，bridge 会自动解析到对应 `detail_node_id` / `layer_oid`，并在返回里补充 `requested_node_id`、`resolved_node_id`、`matched_node`。
- `lookin_get_screenshot`
  - 返回 app 级截图或节点级截图，对应一个本地临时文件路径。
  - 当前 bridge 会把对外落盘的截图保存为 PNG。
  - 如果传入的是 view-backed `node_id`，bridge 会自动解析到对应的 layer-backed detail node 再取图。

## 已知限制

- 当前仍是只读能力，没有对运行中 App 的修改能力。
- session / snapshot 目前是“逻辑层”持久化；底层对 LookinServer 的实际访问仍是串行桥接，不适合把它当成多目标并行调试总线。
- `identifier_contains` 的匹配质量高于返回字段本身：查询时会扫 `search_identifiers`，但结果里的顶层 `identifier` 目前只是挑出的一个代表值，未必是最有辨识度的那个。
- snapshot diff 目前按层级 `path` 做身份匹配；如果页面重排很大、同类节点整体换位，diff 结果会更像结构变化而不是“同一节点改了什么”。
- 当前真机发现已经补上 CoreDevice tunnel fallback，但若目标 app 本身没有接入 `LookinServer`、不是 Debug 构建，或当前没有在设备 tunnel IP 的 `47175~47179` 端口上监听，`lookin_list_targets` 仍会返回空数组或 `connection_refused`。
