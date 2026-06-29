# 流式输出美化 — 开发文档

## 1. 现状分析

目前流式输出在 `src/provider/openai_compat.zig` 中内联实现：

| 供应商 | 推理字段 | 当前输出 |
|--------|----------|----------|
| DeepSeek | `reasoning_content` | `dim("[思考过程]")` + 实时刷文本 |
| Standard | `reasoning_content` | `dim("[思考过程]")` + 实时刷文本（已统一） |

推理处理逻辑（DeepSeek + Standard 共享）：

```
if delta.reasoning_content:
    phase = .reasoning
    print(dim("[思考过程]"))
    flush
    append + print(reasoning_content)
if delta.content:
    print(\n\n)  // 推理→内容过渡
    phase = .content
    append + print(content)
```

问题：

- ❌ 推理输出无视觉格式化，直接 `print("{s}", .{text})`，与普通内容混在一起
- ❌ 推理输出无视觉格式化，直接 `print("{s}", .{text})`，与普通内容混在一起（上一轮已统一 `reasoning_content` 跨供应商共享）

## 2. 设计目标

```
reasoning_content → stream.formatReasoning(out_writer, text) → dim + 分隔线 → 用户
```

- 从 `openai_compat.zig` 抽出推理处理逻辑到 `src/stream.zig`
- 增加视觉区分：`dim` + 分隔线，区别于普通内容
- 不造 TagFilter（工具调用已有独立渲染路径 `App.zig:printToolCall`，跨 chunk 标签拆分在实践中未出现）
- 不处理供应商无关的控制标签（当前无此需求）

## 3. 视觉样式

```
[思考]
│ 模型推理文本内容...
│ 多行显示
───────
（普通内容从这里继续）
```

采用 `dim` 样式 + `│` 前缀逐行 + `───` 分隔线。不使用完整 box 绘制（避免增加依赖），仅用现有 ansi 模块。

## 4. API 设计

```zig
// 推理输出格式化
pub fn formatReasoning(writer: anytype, text: []const u8) !void;
// 推理→内容过渡分隔线
pub fn formatContentTransition(writer: anytype) !void;
```

### 调用方式

不改变 `openai_compat.zig` 的供应商路由结构，仅替换打印调用：

```zig
// 改前
try out_writer.print("{s}[思考过程]{s}\n", .{ ansi.C.dim, ansi.C.reset });
try out_writer.print("{s}", .{r});

// 改后
try stream.formatReasoning(out_writer, r);
```

## 5. 文件变更

| 文件 | 操作 | 说明 |
|------|------|------|
| `src/stream.zig` | **新增** | `formatReasoning` + `formatContentTransition` |
| `src/provider/openai_compat.zig` | 重构 | 替换推理打印为 `stream.formatReasoning()` |
| `src/test.zig` | 添加 | 导入 `stream.zig` |

## 6. 测试计划

```
test "formatReasoning: prepends dim header with separator"
test "formatReasoning: handles empty text"
test "formatReasoning: multi-line preserves indentation"
test "formatContentTransition: outputs separator line"
```

## 7. 边界情况

- 空推理文本：不输出 header，直接跳过
- 非 TTY 输出：`ansi.shouldColorize()` 自动降级为纯文本
- 推理后无 content：正常输出 footer，不多余换行
