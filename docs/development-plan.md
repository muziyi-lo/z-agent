# 开发计划 — 下一阶段

> 基于 NullClaw 项目分析，按优先级排列的优化任务。
> 
> 详细设计文档：`plan-*.md`。本文件为执行状态总览。

## ✅ P0 — `ToolResult` 统一返回

**已完成**。`src/tool/registry.zig` 定义 `ToolResult{ success, output, ok(), fail() }`，全部工具已迁移。详见 `plan-toolresult.md`。

---

## ✅ P1 — `ToolVTable()` 编译期生成

**部分完成**。`registry.zig:buildHandler(comptime tool: type)` 已从工具模块的三个 `pub const`（tool_name/tool_description/tool_params）+ `execute()` 自动构造 `Handler`。工具注册由 `App.zig` 调用 `buildHandler(ToolModule)` 完成。

剩余工作：P1 原始目标"手写 Handler 样板 → 全自动"已通过 `buildHandler()` 实现，无需额外改动。

---

## 📋 P2 — 兼容 Provider 表

**状态**：待实施，无前置依赖。

改进 config.toml 默认模板，将已验证的供应商示例以注释形式写入（OpenAI/Ollama 等），用户按需取消注释。不编译数据表进二进制（无法测试）。

详见 `plan-compat-providers.md`。

---

## 🔮 P3 — `json_miniparse` 零分配字段提取

**状态**：暂不实施。

分析结论：当前工具参数 JSON <200 字节，`parseFromSliceLeaky` 分配成本可忽略。`std.json.Value.object.get()` 已 O(1) 无额外分配。零分配解析收益/成本不成比例。保留为未来选项。

详见 `plan-json-miniparse.md`。

---

## 🔮 P4 — `Redactor` 全路径 PII 清理

**状态**：待规划，无详细文档。

API key 仅 bash 输出时 redact，但可能泄漏到调试日志、会话文件、API 错误消息。需统一清理组件覆盖所有输出路径。

---

## 优先级总览

```
P0: ToolResult      ██████████████████  ✅ 完成
P1: ToolVTable      ██████████████████  ✅ 完成（buildHandler）
P1: 多步执行        ██████████████████  ⏳ 待实施（见 plan-advanced-agent.md）
P2: 兼容表          ████████████░░░░░░  📋 待实施（1 任务）
P2: 自我纠错        ██████████░░░░░░░░  ⏳ 待实施（见 plan-advanced-agent.md）
P3: json_miniparse  ██░░░░░░░░░░░░░░░░  🔮 延期
P3: 并行调度        ██████░░░░░░░░░░░░  ⏳ 待实施（见 plan-advanced-agent.md）
P3: 结构化输出      ████░░░░░░░░░░░░░░  ⏳ 待实施（见 plan-advanced-agent.md）
P4: Redactor        ██████████████████  ⏳ 待规划（2-3 任务）
```

各阶段从哪开始？
