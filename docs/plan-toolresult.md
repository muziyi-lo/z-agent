# P0 — `ToolResult` 统一返回 ✅ 已完成

## 状态

**已完成**，无需额外工作。

## 实现摘要

`src/tool/registry.zig` 已包含：

- `ToolResult` 结构体（`success: bool`, `output: []const u8`）
- `ToolResult.ok(output)` / `ToolResult.fail(err)` 工厂函数
- `Handler.execute` 签名：`fn (allocator, io, args: std.json.Value) ToolResult`
- 全部 20+ 工具（bash/read/write/edit/glob/grep/ask_user/skill/task/console/truncate/json/token/memory/search）均已使用 `ToolResult.ok()` / `ToolResult.fail()` 返回
- `Registry.execute()` 在 dispatch 后调用 `truncateBytes()` 截断过长输出

## 历史

原本工具返回 `[]const u8`，成功返回 JSON 字符串、失败返回 `"Error: ..."`。AI 需从字符串猜测成败。已在早期迭代统一为结构化返回。
