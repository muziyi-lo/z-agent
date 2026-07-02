# z-agent 身份分离计划：`--agent-prompt`

> 拆分 agents_md 与 agent_prompt，解决子 agent 身份错位
> 日期：2026-07-01

---

## 现状问题

当前 `App` 结构体用一个字段 `agents_md: ?[]const u8` 承载三个不同语义：

| 来源 | 语义 | 应放位置 |
|------|------|---------|
| AGENTS.md 文件读取 | 项目规则指令 | system prompt 中部 |
| `--agent <path>` 文件读取 | 子 agent 身份 | system prompt **开头** |
| `--agent-content <str>` 命令行 | 子 agent 身份 | system prompt **开头** |

共用同一字段导致 `buildSystemPrompt()` 无法区分"这是 AGENTS.md 还是 agent prompt"，所有内容都塞进 `<project_context>`。子 agent 读到 "You are z-agent..." 开头 + "你是 explore..." 埋在中部，身份错位。

---

## 改动方案

### 核心变更：`App` 结构体分拆

```zig
pub const App = struct {
    ...
    agents_md: ?[]const u8,    // AGENTS.md / CLAUDE.md 文件内容 → `<project_context>`
    agent_prompt: ?[]const u8,  // --agent / --agent-prompt 身份覆盖 → 替换 "You are z-agent..."
    agent_mode: bool = false,
    ...
};
```

### 分拆逻辑

| 输入 | 写入字段 |
|------|---------|
| 文件 `AGENTS.md` / `CLAUDE.md` | `agents_md` |
| `--agent <path>` | 文件内容 → `agent_prompt`，设 `agent_mode = true` |
| `--agent-prompt <str>` | 取代 `--agent-content` → `agent_prompt`，设 `agent_mode = true` |

`--agent-content` 删除（非正式版，无需兼容）。task 工具改传 `--agent-prompt`。

### `system.zig` 签名变更

```zig
// 当前
pub fn buildSystemPrompt(allocator, cwd, project_root, provider_name, model_name,
    io, agents_md, available_skills, model_family) ![]const u8

// 改为
pub fn buildSystemPrompt(allocator, cwd, project_root, provider_name, model_name,
    io, agents_md, available_skills, model_family, agent_prompt) ![]const u8
```

`agent_prompt` 非空时，身份段输出：

```
<agent_prompt>
\n
<model-specific guidance>
...
```

空时保持现有输出：

```
You are z-agent...
\n
<model-specific guidance>
...
```

### tool/task.zig

`loadAgentContent()` 读取 `.zagent/agents/<name>` 后，argv 中 `--agent-content` → `--agent-prompt`。即子进程启动参数从：

```
z-agent --agent-content "你是 explore..." --result-marker=xxx task
```

改为：

```
z-agent --agent-prompt "你是 explore..." --result-marker=xxx task
```

---

## 改动文件

| 文件 | 改动 |
|------|------|
| `App.zig` | 拆 `agents_md` / `agent_prompt` 字段 + 参数解析 |
| `App.zig` | `--agent-prompt` 新增 + `--agent-content` 删除 |
| `App.zig` | `--agent <path>` 写入 `agent_prompt` 而非 `agents_md` |
| `system.zig` | `buildSystemPrompt` 新增 `agent_prompt` 参数 + 身份段替换 |
| `App.zig` `singleTurn`/`repl` | 传递 `agent_prompt` |
| `tool/task.zig` | argv 中 `--agent-content` → `--agent-prompt` |

---

## 实施顺序

```
1. `system.zig`: `buildSystemPrompt` 加 `agent_prompt` 参数 + 身份段替换
2. `App.zig`: 拆分 `agents_md` / `agent_prompt` 字段、参数解析、删除 `--agent-content`、新增 `--agent-prompt`
3. `App.zig`: `singleTurn`/`repl` 传新参数
4. `tool/task.zig`: `--agent-content` → `--agent-prompt`
5. 测试 + 提交
```
