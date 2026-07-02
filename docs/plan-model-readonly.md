# z-agent 模型覆盖 & 权限模式计划

> 改进子进程权限死锁，支持启动时指定模型
> 日期：2026-07-01

---

## 定位说明

z-agent 是 CLI coding agent，当前存在两个问题：

1. **模型不可覆盖** — 只能在 `config.toml` 设置 `default_model`，CLI 无覆盖入口。子 agent 无法指定不同模型
2. **子进程权限死锁** — 子 agent 的 stdout 被捕获、stdin 不可控，confirm 模式打印的提示用户看不见，子进程永远挂起

---

## 改动范围

### P0 — CLI `--model` 参数

| 改动 | 文件 | 说明 |
|------|------|------|
| 新增 `--model` CLI flag | `App.zig` init 参数解析 | 覆盖 `config.toml` 的 `default_model` |
| 更新 help | `Cli.zig` `printHelp` | 添加 `--model` 说明 |

#### 使用方式

```
z-agent --model deepseek/deepseek-v4-flash "分析这个文件"
z-agent --model openai/gpt-4o
```

#### 实现

当前 `App.zig:105-134` 已从 `default_model` 解析 provider/model，只需在参数解析阶段（`App.zig:224-286`）新增 `--model` 分支，将值覆盖给 `cfg.default_model`：

```zig
if (std.mem.eql(u8, arg, "--model")) {
    i += 1;
    if (i >= args.len) {
        try stdout.print("Error: --model requires an argument (e.g. deepseek/deepseek-v4-flash)\n", .{});
        try stdout.flush();
        return error.MissingModelArg;
    }
    cfg.default_model = try arena.dupe(u8, args[i]);
    continue;
}
```

需要在 `App.zig:init()` 中将 `cfg` 从 `const` 改为 `var`（当前 `cfg` 在行 96 为 `const loaded = try config_mod.Config.load(...)`，`var cfg = loaded.config` 已在行 404）。


#### 子进程继承

`task.zig` 当前仅传 `--agent-content` + `--result-marker` + task。传 `--model` 需要判断：子 agent 是否该用父 agent 的模型？

方案：默认不传（子 agent 自行按 config 加载模型）。如需指定，可后续在 task 参数加 `model` 字段。

---

### P1 — 权限模式改造：trust / readonly / default

#### 当前问题

| 模式 | 用途 | 子进程表现 |
|------|------|-----------|
| `--trust` | 全跳过 | ✅ 正常 |
| 默认 (无 flag) | 用户交互 confirm | ❌ stdout 被捕获 → 用户看不见提示 → 死锁 |

#### 方案：三元权限模式

| CLI flag | 模式名 | 读操作 | 写操作 | 适用场景 |
|----------|--------|--------|--------|----------|
| `--trust` | 信任 | allow | allow | 用户主动启动、子 agent 收到信任标记 |
| `--readonly` | 只读 | allow | **deny** | 调研/审查子 agent（默认） |
| 无 flag | 默认交互 | confirm | confirm | 用户终端交互 |

#### 改动清单

| 改动 | 文件 | 说明 |
|------|------|------|
| 新增 `readonly` 字段 | `App.zig` | `App` struct + `init()` 参数解析 |
| 新增 `--readonly` CLI flag | `App.zig` | 参数解析 |
| 更新 `agent.zig` 权限路径 | `agent.zig` | 在 `perm.check` 前插入 `readonly` 拦截 |
| 更新 task 工具 | `tool/task.zig` | 子进程默认加 `--readonly`，可选 `trust` 参数加 `--trust` |
| 更新 help | `Cli.zig` | 添加 `--readonly` 描述 |
| 更新系统提示词 | `system.zig` | `task` 工具描述增加 `trust` 参数说明 |

#### 只读操作的判定规则

写操作 = 可能修改文件系统或状态的操作：

| 工具 | readonly 行为 |
|------|-------------|
| `read_file` | ✅ allow |
| `glob` | ✅ allow |
| `grep` | ✅ allow |
| `ask_user` | ❌ deny（子进程 stdin 不可控，避免死锁） |
| `skill` | ✅ allow |
| `memory` | ❌ deny（学习操作是写） |
| `write_file` | ❌ deny |
| `edit_file` | ❌ deny |
| `bash` | ❌ deny |
| `task` | ❌ deny（子 agent 无法 spawn 子 agent） |

#### 实现：readonly 拦截点

在 `agent.zig:393-487` 的工具调度中，`readonly` 在 `perm.check` 前拦截：

```zig
if (readonly) {
    if (isWriteTool(tc.name)) {
        skip_result = "Error: readonly mode — modify operations are denied";
        result = skip_result.?;
        is_error = true;
        // ... 继续跳过执行
        continue;
    }
}
```

`isWriteTool` 函数检查工具名是否在写操作列表中。

此方式不侵入 `Permission` 模块，在调度层做拦截。

#### 启动日志

子进程启动时，`App.zig` 在 `init()` 中检测 `readonly`，输出提示：

```
z-agent v0.2.0 (build 123456)
[只读模式] 写操作（write/edit/bash/task/ask_user）已被禁止
```

子进程不输出的后果是用户只看得到子 agent 反复报 "Error: permission denied"，不知道原因。只读模式提示解决了这个问题。

#### task 工具子进程权限传递

`task.zig` 当前在 `std.process.run` 中不传任何权限 flag。修改：

- task 参数新增可选 `trust: bool` 字段
- `trust: true` → 子进程传 `--trust`
- 默认（或 `trust: false/未提供`）→ 子进程传 `--readonly`

```json
// 调研任务 → 只读
{ "agent": "explore", "task": "分析架构" }

// 开发任务 → 信任
{ "agent": "worker", "task": "实现功能", "trust": true }
```

#### 修改文件

| 文件 | 改动 |
|------|------|
| `App.zig` | 新增 `readonly: bool` 字段，参数解析增加 `--model` 和 `--readonly` |
| `agent.zig` | 新增参数 `readonly: bool`，工具调度前插入拦截 |
| `tool/task.zig` | 新增 `trust` 参数支持，argv 中根据 trust 传 `--trust` 或 `--readonly` |
| `Cli.zig` | `printHelp` 更新 |
| `system.zig` | task 工具描述更新 |

---

## 实施顺序

```
P0: --model 参数
  ├── App.zig: 参数解析 + cfg.default_model 覆盖
  └── Cli.zig: help 更新

P1: 权限模式
  ├── App.zig: readonly 字段 + 参数解析
  ├── agent.zig: readonly 拦截点 + 参数传递
  ├── tool/task.zig: trust 参数 + 子进程 flag 传递
  ├── system.zig: 工具描述更新
  └── Cli.zig: help 更新
```

每步停一次确认。
