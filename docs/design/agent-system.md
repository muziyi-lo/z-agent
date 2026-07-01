# z-agent 代理系统设计

> 架构概览：system prompt 组装、子代理机制、上下文传递
> 日期：2026-07-01

---

## 1. 进程模型

```
z-agent 是单进程 CLI 应用。

父进程: z-agent "帮我重构代码"
  └─ 子进程: z-agent --agent-prompt "你是 worker..." --readonly "重构 src/main.zig"
      └─ 查询型任务默认 --readonly（只读）
      └─ 开发型任务显式 trust:true 传 --trust（全权限）
```

子代理通过 `std.process.run` 启动独立进程，`stdout` 全量捕获后提取 `[ZAGENT_RESULT]` 内容。

### 进程隔离是设计选择

子进程模式有以下有意为之的特性：

| 特性 | 说明 |
|------|------|
| **零上下文继承** | 子进程从零加载配置、provider、system prompt。父 agent 需在 `task` 参数中明确传递上下文 |
| **权限隔离** | 子进程默认 `--readonly`（写操作被 `permission.zig` 拦截），父 agent 决定是否给写权限 |
| **结果解析** | 子进程输出 `[ZAGENT_RESULT:nonce]` 标记边界，父进程解析提取 |
| **无实时反馈** | 子进程 stdout 被捕获到 buffer，用户看到的是"正在执行任务..."直到结果返回 |

子进程是黑盒——启动后无法交互。这也是 `--readonly` 作为子进程默认模式的原因（避免 confirm 死锁）。

---

## 2. System Prompt 组装

### 2.1 组装时机

system prompt 在**会话入口处拼一次**（`App.zig` repl/singleTurn 调一次 `buildSystemPrompt`），之后作为 `messages[0]` 固定不变。

```
REPL 入口:
  messages[0] = buildSystemPrompt(...)  ← 调用一次
  messages[1] = user input
  ...

每轮 agent loop:
  callWithRetry(messages)  ← messages[0~N] 不变
  └─ KV cache: messages[0] 前缀固定 → 从头命中
```

不重新拼装的理由：z-agent 是 CLI，AGENTS.md 不支持热重载、工具列表编译期硬编码、环境在会话期间不变。

### 2.2 组装层

`src/system.zig` `buildSystemPrompt()` 按以下顺序拼接：

```
1. [身份段]
   agent_prompt 非空: 替换为 agent_prompt 内容
   空: "You are z-agent... model via provider. z-agent v0.2.0"

2. [日期] "Today's date: Wed Jul 01 2026"

3. [行为规范]
   # Tone and style    (简洁/直接/无preamble/无emoji)
   # Security          (不猜URL/不暴露密钥)
   # Task workflow     (先读后改/最小变更/不主动提交)

4. [项目上下文] <project_context> AGENTS.md 内容（可选）

5. [可用技能] <available_skills>（可选）

6. [可用代理] <available_agents>

7. [环境块] <env>
     Working directory
     Workspace root folder
     Is directory a git repo
     Platform / Shell
     ⚠ Get-ChildItem/Select-String 开销警告

8. [模型引导]（仅 DeepSeek V4）
     1M context window / bilingual / reasoning step 使用提示
```

工具描述不由 system prompt 提供，通过 API `tools` 参数以 JSON Schema 形式下发。见 §2.4。

### 2.3 身份覆盖

`--agent-prompt` 和 `--agent` 提供的字符串替换身份段（第一层），保留其余所有层不变。子 agent 的 system prompt 由此获得独立身份，同时继承环境/工具/行为规范等基础结构。

```
--agent-prompt "你是 explore，文件搜索专家" 后 system prompt:

messages[0] = "你是 explore，文件搜索专家"
             "Today's date: Wed Jul 01 2026"
             "# Tone and style..."
             "<project_context>..."
             "<env>..."
```

### 2.4 与 OpenCode 的对比

| 维度 | z-agent | OpenCode |
|------|---------|----------|
| 组装时机 | 会话入口一次 | 每轮循环重新拼 |
| 系统消息数 | 单条 `{role:system}` | 单条 `{role:system}`（拼入所有层）|
| 环境变化 | 不变化（CLI） | 可能变化（MCP/技能） |
| KV cache | 前缀固定 → 命中 | 每轮新前缀 → 不命中 |
| 身份覆盖 | `--agent-prompt` 替换首段 | agent `.prompt` 字段替换 provider 默认 |

---

## 3. 上下文组装（消息队列）

### 3.1 Agent Loop

`agent.zig` `agentLoop()`：

```
while (tool_rounds < 10):
  1. compact() → 检查是否需压缩（BM25 检索 + LLM 摘要）
  2. callWithRetry() → 调用 provider API
  3. 如果 response 含 tool_calls:
     逐个执行工具 → 结果 append 到 messages
     continue（下一轮循环）
  4. 如果 response 含 content:
     append 到 messages → return

超出 10 轮:
  1. 注入 CRITICAL 消息（工具禁用，要求输出摘要）
  2. 再做一次 API 调用获取文本总结
  3. 输出 [告警] 提示
```

### 3.2 消息队列结构

```
messages = [
  { role: "system",    content: buildSystemPrompt() },
  { role: "user",      content: "帮我重构这个模块" },
  { role: "assistant", content: null, tool_calls: [...] },
  { role: "tool",      content: tool_result },
  { role: "assistant", content: "分析结果..." },
]
```

`messages[0]` 在会话期间固定。后续新增的只有 user/assistant/tool 角色消息。

### 3.3 子代理的任务消息

子代理通过 `--agent-prompt` + `task` 参数收到：

```
子进程 argv = z-agent --agent-prompt "你是 worker..." [--readonly|--trust] --result-marker=xxx "重构 src/main.zig"

子进程 messages = [
  { role: "system", content: "你是 worker..." + 环境/工具/AGENTS.md },
  { role: "user",   content: "重构 src/main.zig" },
]
```

如果调用了 `files` 参数：

```
{ role: "user", content: "Referenced files:\n--- src/main.zig ---\n<内容>\n---\n\n重构 src/main.zig" }
```

---

## 4. 权限模型

### 4.1 三模式

| 模式 | CLI flag | 读操作 | 写操作 | 子进程默认 |
|------|----------|--------|--------|-----------|
| 信任 | `--trust` | allow | allow | `trust:true` 时 |
| 只读 | `--readonly` | allow | deny | 默认 |
| 交互 | 无 | confirm | confirm | 终端用户 |

### 4.2 拦截链

```
perm.check(tool, subject, command, trust)
  1. trust=true? → allow（跳过所有规则）
  2. readonly + isWriteTool? → deny
  3. 查 learned 表 → 命中则返回
  4. engine.evaluate(tool, subject) → 规则匹配
```

写工具列表：`write_file`、`edit_file`、`bash`、`task`、`ask_user`、`memory`。

### 4.3 子进程权限传递

```
task.zig execute():
  trust_val = args_obj.get("trust")
  is_trust = trust_val == true

  argv 中:
    默认为 "--readonly"    → 子进程只读
    trust:true → "--trust" → 子进程全权限
```

---

## 5. 文件引用（`files` 参数）

task 工具的 `files` 参数允许父 agent 传文件路径，工具层代为读取并拼入 prompt：

```
父 agent 调用:
  task(agent="critic", task="审查代码", files=["src/main.zig"])

子 agent 收到的 prompt:
  Referenced files:
  --- src/main.zig ---
  <内容>
  ---

  审查代码
```

边界处理全部不阻塞 task 执行：

| 场景 | 处理 |
|------|------|
| 文件不存在 | 标注 `(error: can't open: FileNotFound)` |
| 二进制文件 | 标注 `(skipped: binary)` |
| 文件 > 50KB | 截断，标注 `...(truncated)` |
| OOM | 标注 `(error: OOM)` |
| 路径解析失败 | 标注 `(error: path resolution failed)` |

路径优先使用 `root_dir.resolvePath()` 解析相对路径，绝对路径原样使用。

---

## 6. 一致性检查

`zig build check` 运行 `scripts/check-consistency.ps1`，验证两项：

1. **CLI flag 一致性** — `App.zig` 参数解析中的 flag 名与 `AGENTS.md` 记录的一致
2. **argv 与文档对齐** — `task.zig` argv 中的 flag 名在 AGENTS.md 中有提及

工具描述由各 `tool/*.zig` 文件的 `tool_description` 常量单独维护，不再纳入一致性检查。

检查失败不影响编译，仅输出警告。在 CI 中可配置为阻止合并。
