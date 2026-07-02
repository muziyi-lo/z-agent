# Agent 能力增强计划

## 现状

z-agent 已有基础架构（provider/工具/会话/记忆/渲染），但 agent 本身是**直筒型**——收到用户指令 → 调一次工具 → 返回结果，无规划/反思/纠错能力。

## 候选能力

| 能力 | 复杂度 | 优先级 | 前置 |
|------|--------|--------|------|
| A. 多步工具执行（Plan-then-Execute） | 中 | **P1** | 无 |
| B. 工具结果自我纠错 | 中 | P2 | A |
| C. 多工具并行调度 | 高 | P3 | A |
| D. 结构化输出约束 | 低 | P3 | 无 |

---

## A — 多步工具执行（P1）

### 问题

当前 agent 每轮只做一次工具调用。对于"搜索代码 → 读取文件 → 编辑文件"这类多步骤任务，当前行为：
1. 返回搜索代码 → 用户确认 → 再调读取 → 用户确认 → 再调编辑
2. 或 AI 一次性输出多个工具调用，但它们是并行执行的，后一步依赖前一步结果时出错

### 方案

新增 `Plan` 类型，在 system prompt 中引导 AI 输出 JSON plan：

```
User: 把 README 里的版本号改成 2.0
AI: [PLAN]
  steps:
    - tool: grep
      args: { pattern: "version =.*", path: "README.md" }
      output_var: current_version
    - tool: edit
      args: { file: "README.md", old: "{current_version}", new: "version = \"2.0\"" }
[PLAN_END]
```

执行引擎按顺序提交每个 step，用 `output_var` 传递依赖结果。

### 文件变更

| 文件 | 操作 |
|------|------|
| `src/system.zig` | 追加 PLAN JSON 格式指令 |
| 新增 `src/plan.zig` | Plan 解析 + 执行引擎（依赖解析 + 顺序提交） |
| `src/App.zig` | 检测 `[PLAN]` 标记 → 走 plan 路径 |
| `src/types.zig` | 新增 `Plan`/`PlanStep` 类型 |

### 边界

- 不实现 fork/join（不会走到一半分歧）
- 依赖用 `{var_name}` 模板替代，不做图编排
- 超时：单步 60s，总计划 300s

---

## B — 工具结果自我纠错（P2）

### 问题

工具返回错误（文件不存在、grep 无匹配等），当前行为是直接返回给用户。需要重试能力。

### 方案

在 system prompt 中引导 AI 自行检查工具结果并修复：

```
Tool result: file not found
→ AI 自动尝试其他路径 / 创建文件 / 换工具
```

实现：检测工具结果是 `is_error` 或 `output` 含常见错误关键词，在 `App.zig` 中自动追加纠错轮次，不计入"最大工具轮次"限制。

### 文件变更

| 文件 | 操作 |
|------|------|
| `src/App.zig` | 工具结果检查 + 自动纠错轮 |
| `src/system.zig` | 追加纠错引导 |

### 边界

- 最多 2 次重试
- 重试消耗的 token 计入成本
- 含危险命令的工具（bash）不自动重试

---

## C — 多工具并行调度（P3）

### 问题

当前 `[tool_calls]` 数组中的多个调用是串行执行的。对于无依赖的工具调用（同时搜索多个关键词），可并行提升效率。

### 方案

检测 tool_calls 间的依赖关系：
- 无依赖 → 并行提交
- 有依赖 → 串行等待

### 文件变更

| 文件 | 操作 |
|------|------|
| `src/App.zig` | tool_calls 执行改为依赖分析 + 并行/串行混合 |

### 边界

- 最大并行数 3
- 不实现复杂 DAG 编排，只做简单的"一个 step 的输出不被其他 step 使用"判断

---

## D — 结构化输出约束（P3）

### 问题

JSON mode / function calling 格式不统一，各 provider 行为不同。DeepSeek 输出 `[tool_calls]`，有些 provider 输出 JSON block。

### 方案

在 system prompt 中用 `RESPONSE_FORMAT` 指令统一输出格式。不做 provider 层的 schema 约束（JSON mode 在各 provider 实现不统一，不可靠）。

### 文件变更

| 文件 | 操作 |
|------|------|
| `src/system.zig` | 追加 RESPONSE_FORMAT 指令 |
| `src/provider/openai_compat.zig` | 可选的 JSON mode 参数（provider 支持时启用） |

---

## 优先级

```
A: 多步执行  ██████████████████  P1  2-3 任务
B: 自我纠错  ██████████░░░░░░░░  P2  1 任务（依赖 A）
C: 并行调度  ██████░░░░░░░░░░░░  P3  1-2 任务（依赖 A 的依赖解析）
D: 结构化    ████░░░░░░░░░░░░░░  P3  1 任务
```

## 进度

| 阶段 | 状态 |
|------|------|
| 方案设计 | ✅ 本文档 |
| A 实现 | ⏳ |
| B 实现 | ⏳ |
| C 实现 | ⏳ |
| D 实现 | ⏳ |
