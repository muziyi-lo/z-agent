# 子代理系统指南

## 概述

子代理是 z-agent 调用 z-agent 的递归委托机制。当前会话通过 `task` 工具 spawn 新进程执行特定任务，结果返回给主会话。

本质就是 `bash("z-agent --agent-content <prompt> <task>")` 的结构化包装。

## task 工具用法

```json
{
  "agent": "worker | critic | explore",  // 代理人设
  "task": "详细的任务描述"                 // 要执行的任务
}
```

返回值：

```json
{
  "content": "子代理的输出内容",
  "agent": "worker"
}
```

## 内置子代理

| 名称 | 定位 | 适用场景 |
|------|------|----------|
| `worker` | 泛型工作者 | 编写代码、执行多步骤实现任务 |
| `critic` | 对抗评审者 | 审查方案、挑逻辑漏洞 |
| `explore` | 文件探索者 | 在代码库中快速定位和分析文件 |
| `thinker` | 深度分析者 | 复杂问题根因分析、架构判断、多源交叉验证 |
| `skill-review` | 技能审查者 | 审查技能/agent 设计质量与权限配置 |
| `vision` | 图片分析者 | 分析 UI 截图、排查渲染问题 |
| `session-diagnose` | 会话诊断者 | 查询和分析历史会话记录 |
| `zig-worker` | Zig 代码实现者 | 编写和修改 Zig 代码，运行测试 |
| `zig-reviewer` | Zig 代码审查者 | 按审查清单逐项检查 Zig 代码 |
| `zig-debugger` | Zig 调试专家 | 诊断 Zig 内存泄漏与崩溃问题 |

## agent 文件位置

`.opencode/agents/<name>.md`。每个文件定义角色 prompt，遵循 frontmatter + markdown 格式：

```markdown
---
description: 简短描述该 agent 的定位
---

You are a ... 完整的 agent 行为定义。
```

## 自定义子代理

在 `.opencode/agents/` 下新建 `.md` 文件即可注册。例如 `docs-writer.md`：

```markdown
---
description: 技术文档撰写专家
---

You are a technical writer. Your output should be clear, concise Chinese.
Use code examples where appropriate.
```

之后就能 `task(agent="docs-writer", task="写 API 文档")` 调用了。

## 与 bash 调用的等价性

`task` 工具和 `bash("z-agent --agent-content <prompt> <task>")` 本质相同：

```
# 用 task 工具：
task(agent="worker", task="审查这段代码")

# 等价于 bash 调用：
bash("z-agent --agent-content \"$(cat .opencode/agents/worker.md)\" --result-marker=abc 审查这段代码")
  → 解析 [ZAGENT_RESULT:abc]... 标记提取结果
```

`task` 工具的优势在于自动处理路径解析、标记匹配、JSON 包装。

## 注意事项

- 子代理有独立 token 预算，主会话上下文不受影响
- 子代理的配置（provider、模型）继承自父进程 `.zagent/config.toml`
- 子代理可以调用 `task` 工具递归委托，递归深度取决于模型行为
- 退出码非零时返回错误信息而非子代理输出
- `--agent-mode` 模式下输出 `[ZAGENT_RESULT]` 标记供父进程解析
