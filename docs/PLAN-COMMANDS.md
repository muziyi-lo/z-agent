# z-agent 命令系统改进计划

> 对比 opencode 命令系统后的改进方案
> 日期：2026-07-01 (v2 — 简化版)

---

## 定位说明

z-agent 是单二进制 CLI coding agent，个人开发、仅 DeepSeek V4。改进限定在 **提升现有模板质量**，不引入新基础设施或代码操作类命令。

---

## 问题现状

### 模板命令（4 个内嵌）

| 模板 | 当前行数 | 问题 |
|------|---------|------|
| `/init` | 18 行 | 纯规则列表，无调研方法论 |
| `/learn` | 16 行 | 质量可接受 |
| `/recall` | 7 行 | 质量可接受 |
| `/summary` | 13 行 | 质量可接受 |

### 对比 opencode 的差距

| 维度 | opencode `initialize.txt` | z-agent `embedded_init` |
|------|--------------------------|------------------------|
| **风格** | 方法驱动 — 教模型"怎么调研" | 规则驱动 — 告诉模型"什么能做" |
| **调研路径** | README → 配置 → CI → 指令 → 代码 | ❌ 无 |
| **提取信号** | 精确命令/单测/monorepo/工具链怪癖 | ❌ 无 |
| **交互策略** | 最多问一轮 | ❌ 无 |
| **占位符** | `$ARGUMENTS` + `${path}` | `${args}` |

---

## 改动范围

### P0 — `/init` 模板改进（唯一改动）

| 改动 | 文件 | 说明 |
|------|------|------|
| 替换 `embedded_init` 字符串 | `src/Command.zig` | 18 行 → ~50 行，三章结构 |
| 新增测试 | `src/Command.zig` | 验证 `/init` 包含调研指引关键词 |

#### 新结构

```
---
description: Analyze project and write a concise AGENTS.md
args: (optional extra instructions)
---
## How to investigate

Read the highest-value sources first:
- README, build config, lockfiles
- CI workflows and task runner config
- existing instruction files (AGENTS.md, CLAUDE.md)
- representative code files for architecture

Prefer executable sources of truth over prose.

Avoid reading generated or dependency directories (zig-cache, node_modules, .git, target, dist, build, .next). Use glob with -Depth N or grep with -Path/-Filter to keep searches bounded.

## What to extract

Look for high-signal facts an agent would miss:
- exact developer commands, especially non-obvious ones
- how to run a single test
- monorepo boundaries and entrypoints
- framework or toolchain quirks
- testing quirks: fixtures, integration prerequisites
- repo-specific conventions that differ from defaults

Good AGENTS.md content is hard-earned context that took multiple files to infer.

## Writing rules

Every line must answer: "Would an agent miss this without help?" If no, delete it.
Only project-specific rules. Skip generic language advice.
NO directory trees or file catalogs.
If existing AGENTS.md exists, improve it, don't replace blindly.

## Questions

Only ask the user if the repo cannot answer something important.
Use the question tool for at most one short batch.

${args}
```

---

## 不涉及的变更

| 项目 | 理由 |
|------|------|
| `subtask: true` frontmatter | z-agent 的 task 工具已支持子代理，模板内容可引导，无需架构改动 |
| `model:` frontmatter | 个人项目只用一个模型，功能无意义 |
| `$1`-`$N` / `$ARGUMENTS` 多参数 | 4 个模板全用 `${args}`，单参数场景无需解析器 |
| `/review` 模板 | 代码操作类指令，用户直接说即可，不需要模板入口 |
| `/rmslop` 模板 | 同上 |
| `.zagent/commands/*.md` 协议变更 | 无新字段，保持向后兼容 |

---

## 预期效果

| 场景 | 当前行为 | 改后行为 |
|------|---------|---------|
| 用户输入 `/init` | 得到 12 条规则列表 | 调研方法论+提取指南+写入规则，AGENTS.md 质量提升 |
| 复杂项目首次初始化 | 模型不知从何入手 | 有明确的调研路径（README→配置→CI→代码） |
| 已有 AGENTS.md 需改进 | 可能盲目重写或漏掉有用内容 | 先读现有文件→验证→改进不重写 |
