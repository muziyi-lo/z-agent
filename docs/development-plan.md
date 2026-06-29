# 开发计划 — 下一阶段

> 基于 NullClaw 项目分析，按优先级排列的优化任务。

## P0 — `ToolResult` 统一返回

**问题**：工具返回 `[]const u8`，成功返回 JSON 字符串，失败返回 `"Error: ..."`。AI 无法直接判断工具调用是否成功，需要从字符串内容猜测。

**目标**：所有工具统一返回结构化结果。

```zig
pub const ToolResult = struct {
    success: bool,
    output: []const u8,
    error_msg: ?[]const u8 = null,

    pub fn ok(output: []const u8) ToolResult;
    pub fn fail(err: []const u8) ToolResult;
};
```

**改动范围**：
- `registry.zig` — 加 `ToolResult` 类型定义，改 `Handler.execute` 签名
- `tool/*.zig` — 逐个工具改为返回 `ToolResult`
- `App.zig` — 工具结果处理处读取 `.success` / `.output`

**条件**：无前置依赖

---

## P1 — `ToolVTable()` 编译期生成

**问题**：`App.zig` 中每个工具注册要手写 `Handler{name, description, parameters, execute}` 样板，description 和 parameters 是 JSON 字符串，易错且冗余。

**目标**：工具文件声明三个 `pub const` + `execute()`，vtable 自动生成。

```zig
// 工具文件内
pub const tool_name = "read_file";
pub const tool_description = "Read a file from the filesystem...";
pub const tool_params = "{\"type\":\"object\",...}";

pub fn execute(allocator, io, args) !ToolResult { ... }
```

**改动范围**：
- `registry.zig` — 加 `ToolVTable(comptime T: type)` 编译期函数
- `tool/*.zig` — 每个工具加三个 `pub const`
- `App.zig` — 注册改为自动收集模式

**条件**：依赖 P0

---

## P2 — 兼容 Provider 表

**问题**：openai_compat 已支持所有 OpenAI 兼容 API，但 AI 和用户不知道具体有哪些可选供应商。

**目标**：预置已知兼容供应商数据表，支持列表展示和查找。

```zig
const compat_providers = [_]CompatProvider{
    .{ .name = "deepseek", .url = "https://api.deepseek.com", .display = "DeepSeek" },
    .{ .name = "qwen", .url = "https://dashscope.aliyuncs.com/compatible-mode/v1", .display = "Qwen" },
    // ...更多
};
```

**改动范围**：
- 新建 `provider/compat.zig` — 数据表 + `findByModel()` / `listAll()` 查询函数
- `/list-models` 命令可展示推荐供应商
- 可选：API Key 前缀自动检测（`sk-` → OpenAI 兼容，`sk-ant-` → Anthropic）

**条件**：无前置依赖

---

## P3 — `json_miniparse`

**问题**：工具从参数中取一两个字段时，用 `std.json.parseFromSlice` 完整解析整个 JSON 树，浪费分配和 CPU。

**目标**：按需扫描 JSON 字符串提取字段值，零分配。

```zig
pub fn parseStringField(json: []const u8, key: []const u8) ?[]const u8;
pub fn parseIntField(json: []const u8, key: []const u8) ?i64;
```

**改动范围**：
- 新建或扩展 `tool/json.zig` 或 `json_miniparse.zig`
- 选择性替换现有工具中的简单字段提取

**条件**：无前置依赖

---

## P4 — `Redactor` 全路径 PII 清理

**问题**：API key 仅在 bash 输出时 redact，但可能出现在调试日志（`z-request.log`）、会话文件（`.jsonl`）、API 错误消息中。

**目标**：统一 PII 清理组件，覆盖所有输出路径。

```zig
pub const Redactor = struct {
    pub fn init(allocator, keys: []const []const u8) Redactor;
    pub fn redact(self, input: []const u8) ![]const u8;
};
```

**改动范围**：
- 新建 `redaction.zig` — 清理引擎
- 集成到 session 写入、debug log 写入、工具结果输出路径
- 可选扩展：邮箱/电话/信用卡号 PII 检测

**条件**：建议等 P0 完成（工具返回格式变化后清理路径更清晰）

---

## 优先级总览

```
P0: ToolResult      ████████████████░░  1-2 任务
P1: ToolVTable      ████████████████░░  1-2 任务（等 P0）
P2: 兼容表          ████░░░░░░░░░░░░░░  1 任务
P3: json_miniparse  ████░░░░░░░░░░░░░░  1 任务
P4: Redactor        ██████████████████  2-3 任务（等 P0）
```

各阶段从哪开始？
