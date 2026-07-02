# z-agent 子代理系统完善计划

> 完成 agent 定义文件格式、模型指定、权限嵌入
> 日期：2026-07-01

---

## 现状

`task` 工具的 `agent` 字段指定代理名，`loadAgentContent()` 尝试读 `.zagent/agents/<name>` 文件，找不到时回退内嵌的 `embedded_explore`。但：

- 无定义文件格式（`loadAgentContent` 读整文件当纯文本）
- 无默认 agent 目录（`.zagent/agents/` 不存在）
- 无 frontmatter 解析（不能指定 model/permissions/name）
- task 工具无 `model` 参数（子进程只能用 config.toml 的默认模型）
- 除了 explore 之外没有其他 agent 可用

---

## 改动范围

### P0 — Agent 文件格式

#### frontmatter 定义

`.zagent/agents/<slug>.md` 文件，YAML frontmatter + markdown body：

```markdown
---
name: 代理显示名
description: 一句话说明用途
model: deepseek/deepseek-v4-pro    # 可选，覆盖默认模型
read: allow                         # 可选，默认 deny
write: deny                         # 可选，默认 deny
bash: deny                          # 可选，默认 deny
max_tool_rounds: 10                # 可选，覆盖全局 10 轮上限
---

You are the agent's system prompt. This is your identity.
```

| 字段 | 必需 | 说明 |
|------|------|------|
| `name` | 是 | 显示名，用于 system prompt 和日志 |
| `description` | 是 | 让父 agent 知道什么场景用 |
| `model` | 否 | 格式同 `--model`，如 `deepseek/deepseek-v4-flash` |
| `read` | 否 | `read_file`/`glob`/`grep`/`skill` 权限。默认 `deny` |
| `write` | 否 | `write_file`/`edit_file` 权限。默认 `deny` |
| `bash` | 否 | `bash`/`task`/`ask_user` 权限。默认 `deny` |
| `max_tool_rounds` | 否 | 覆盖全局 10 轮上限 |
| body (---后) | 是 | agent 的 system prompt 身份段 |

### 工具分类表

| 类 | 工具 | 说明 |
|----|------|------|
| read | `read_file`, `glob`, `grep`, `skill` | 只读查询 |
| write | `write_file`, `edit_file` | 文件修改 |
| bash | `bash`, `task`, `ask_user` | 命令执行（含子进程），子进程默认 deny |
| 永远开 | `memory` | 内建记忆系统，不走权限判断 |

#### 解析器

新增 `src/skill.zig` 同级的 `src/agent_file.zig` 模块，复用 `skill.zig` 的 frontmatter 解析模式：

```zig
pub const AgentDef = struct {
    slug: []const u8,
    name: []const u8,
    description: []const u8,
    model: ?[]const u8 = null,
    permissions: ?[]const PermissionRule = null,
    max_tool_rounds: ?u32 = null,
    prompt: []const u8,   // body 内容
};
```

`task.zig` 调用 `parseAgentFile()` 解析 `.md` 文件，替换现有的 `loadAgentContent()`。

#### 内置 agent 迁移

`embedded_explore` 从 `task.zig` 中移出，改为编译期嵌入的默认 agent 表（沿用现有内嵌模式，但统一为 frontmatter 结构）：

```zig
// 编译时嵌入 src/builtin_agents.zig
pub const builtin_agents = [_]AgentDef{
    .{
        .slug = "explore",
        .name = "文件搜索专家",
        .description = "擅长在代码库中快速定位和分析文件",
        .model = null,
        .permissions = &.{
            .{ .tool = "read_file", .action = .allow },
            .{ .tool = "glob", .action = .allow },
            .{ .tool = "grep", .action = .allow },
            .{ .tool = "bash", .action = .allow },
            .{ .tool = "skill", .action = .allow },
        },
        .prompt = "You are a file search specialist...",
    },
};
```

filesystem 同名 agent 覆盖内置（同 AGENTS.md 覆盖逻辑）。

#### tool_params 更新

task 工具 JSON schema 新增 `model` 字段：

```json
{
  "agent": "worker",
  "task": "写代码",
  "model": "deepseek/deepseek-v4-pro",
  "files": ["src/main.zig"],
  "trust": true
}
```

`model` 优先级：task 参数 > agent 定义文件 > 父进程模型（不传 `--model` 时）。

| 改动 | 文件 |
|------|------|
| 新增 `agent_file.zig` 模块 | `src/agent_file.zig` |
| frontmatter 解析 | 复用 `skill.zig` 的 `parseFrontmatter()` + `normalizeLF()` |
| `AgentDef` 结构体 | 同上 |
| 编译时内置 agent 表 | `src/builtin_agents.zig` |
| `loadAgentContent` 替换 | `tool/task.zig` |

---

### P1 — 默认 agent 文件

在 `.zagent/agents/` 创建默认 agent：

```markdown
# .zagent/agents/explore.md
---
name: explore
description: 文件搜索专家，擅长在代码库中快速定位和分析文件
permissions:
  - tool: "*"
    action: deny
  - tool: grep,glob,read_file,bash,skill
    action: allow
---
You are a file search specialist...
```

| agent | 模型 | 权限 | 说明 |
|-------|------|------|------|
| explore | 默认 | read=allow, write=deny, bash=deny | 文件搜索 |
| worker | 默认 | read=allow, write=allow, bash=allow | 编码开发 |
| reviewer | 默认 | read=allow, write=deny, bash=deny | 代码审查（仅读不出报告） |

`z-agent init` 命令（当前已有 `/init` 模板）扩展为自动创建 `.zagent/agents/` 目录和默认 agent。

---

### P2 — Agent 可发现性

当前 `system.zig` 硬编码 `<available_agents>`：

```zig
try buf.appendSlice(
    \\<available_agents>
    \\  <agent>
    \\    <name>explore</name>
    \\    <description>文件搜索专家...</description>
    \\  </agent>
    \\</available_agents>
);
```

改为从 `builtin_agents` + filesystem agents 动态构建：

```zig
pub fn buildAvailableAgents(allocator, io, project_root) ![]const u8 {
    // 扫描 .zagent/agents/*.md → 合并内置 agent → 渲染 XML
}
```

内置 agent 保持可被发现。filesystem agent 覆盖同名内置。

---

### 权限传递链

```
子进程启动:
  1. task 工具 argv 传 --agent-prompt + --model（可选）
  2. 不再传 --readonly/--trust（CLI flag 退化为备用）
  3. 子进程 init() 中解析 agent 文件 frontmatter:
     - read/write/bash 三字段 → 设置 perm.allow_read 等开关
     - 无 agent 文件时 fallback 到 config.toml 权限或 --readonly
  4. perm.check() 中:
     - memory 永远 allow
     - read 类: allow
     - write/bash/ask_user 类: 按 perm 三字段判断
  5. task 参数的 "trust: true" 覆盖:

     trust:true 时子进程传 --trust, 跳过 perm.check
```

### 改动汇总

| 优先级 | 改动 | 文件 |
|--------|------|------|
| P0 | Agent file 模块 + frontmatter 解析 | `src/agent_file.zig`（新增）|
| P0 | 内置 agent 表 | `src/builtin_agents.zig`（新增）|
| P0 | `isWriteTool()` 重构为三字段分类 | `src/permission.zig` |
| P0 | `memory` 移出权限判断 | `src/permission.zig` |
| P0 | task 工具集成 agent_file | `tool/task.zig` |
| P0 | task 工具 `model` 参数 + argv 传 `--model` | `tool/task.zig` |
| P0 | `readonly/trust` flag 降级为备用 | `App.zig` / task argv |
| P1 | 默认 agent 文件 | `.zagent/agents/*.md` |
| P1 | `init` 命令创建 agents 目录 | `Command.zig` |
| P2 | 动态 agent 列表 | `system.zig` → `agent_file.zig` |
