# 第四层 — Markdown 渲染（md2ansi 集成）

## 目标

z-agent 的 AI 回复内容从纯文本升级为 Markdown → ANSI 渲染，提升可读性。

## 策略

md2ansi 核心渲染文件（3 个）嵌入到 z-agent 源码树中，不依赖路径引用。`projects/md2ansi/` 作为独立 CLI + 文档独立存在，两边各自维护。

## 文件变更

### 新增

| 文件 | 来源 | 说明 |
|------|------|------|
| `src/md2ansi/lib.zig` | 从 `projects/md2ansi/src/lib.zig` 拷贝 | 公共 API（render/renderLine/renderList/renderTable） |
| `src/md2ansi/renderer.zig` | 从 `projects/md2ansi/src/renderer.zig` 拷贝 | ANSI 样式映射 + 内联状态机 |
| `src/md2ansi/tokenizer.zig` | 从 `projects/md2ansi/src/tokenizer.zig` 拷贝 | 逐行 Markdown 解析 |

### 修改

| 文件 | 改动 |
|------|------|
| `build.zig` | 新增 `md2ansi` module，引用 `src/md2ansi/lib.zig` |
| `src/provider/openai_compat.zig` | 内容输出行调 `md2ansi.render()` 替代原始 `print("{s}", .{c})` |
| `docs/ui-overview.md` | 第四层状态改为 ✅ 已完成 |

### 不改

| 文件 | 理由 |
|------|------|
| `src/stream.zig` | 推理阶段（`[思考]`）有独立前缀格式，不走 markdown 渲染 |
| `src/ansi.zig` | md2ansi 自带颜色常量，不依赖外部 ansi module |
| `src/App.zig` / `src/tool/registry.zig` | 工具结果渲染已有独立路径，暂不改 |

## 渲染策略

段落级实时覆盖。以 blank line（`\n\n`）为段落边界，每检测到一个完整段落，回溯行数 + 覆盖重绘为 ANSI 彩色版本。

```
流式过程：print 原始文本行              ← 用户看到原稿
检测到 \n\n → 回溯段落到覆盖起点         ← ANSI 转义上移
          → md2ansi.renderLine() 逐行   ← 覆盖为彩色
          → 更新覆盖起点                 ← 下一段从此开始
```

### 行数计算

每收到一行原始内容即记录其占用的终端行数（`visibleWidth / terminal_width`，向上取整，最小 1）。覆盖时用 `\033[<N>A` 上移 N 行 + `\033[0J` 清屏。

### 阶段边界

| 阶段 | 渲染策略 | 理由 |
|------|----------|------|
| 推理（`[思考]`） | 不改，保持 raw text + `│` 前缀 | 不是 Markdown，`│` 前缀干扰解析 |
| 分隔线 `───────` | 不改，保持现有样式 | 属于推理阶段收尾 |
| **内容阶段** | **段落级覆盖** | Markdown 内容，需要 ANSI 彩色 |

覆盖从分隔线后的第一段内容行开始。

### 段落边界

| 边界条件 | 触发覆盖 | 说明 |
|----------|----------|------|
| `\n\n` blank line | ✅ 段落结束 | 独立段落，安全渲染 |
| 代码块闭合 ```` ``` ```` | ✅ 代码块结束 | fence 闭合后才安全，避免中途闪烁 |
| 表格结束（列数不匹配或 EOF） | ✅ 当前表格完成后 | 表格需完整才能计算列宽 |
| chunk 最终块（回复完成） | ✅ 强制刷新 | 追加剩余内容 |
| 不完整 fences/tables/list | ❌ 延迟 | 跨 chunk 等待闭合 |

### openai_compat.zig 内容渲染

```zig
// 伪代码逻辑：
const md2ansi = @import("md2ansi");

// 状态
var content_buf = std.ArrayList(u8);     // 完整内容累积
var raw_lines = std.ArrayList(RawLine);   // 原始文本行 + 行数
var overlay_start: usize = 0;             // 下一段覆盖起点（content_buf 偏移）
var in_content = false;                   // 是否已过分隔线

// 每个 delta content chunk：
content_buf.appendSlice(c);
if (!in_content) {
    try out_writer.print("{s}", .{c});   // 原稿实时输出
} else {
    // 追加到 raw_lines，检测段落边界
    raw_lines.append(c);
    try out_writer.print("{s}", .{c});   // 原稿实时输出
    if (isParagraphBoundary(content_buf.items, raw_lines)) {
        try overlayParagraph(out_writer, content_buf, &raw_lines, &overlay_start);
    }
}

// 回复完成：强制覆盖剩余行
if (in_content and raw_lines.items.len > 0) {
    try overlayParagraph(out_writer, content_buf, &raw_lines, &overlay_start);
}

fn overlayParagraph(...) !void {
    // 1. 计算 raw_lines 占用的终端行数 N
    // 2. 上移 N 行 + 清屏
    // 3. 对表覆盖段的每个完整行调 md2ansi.renderLine()
    // 4. 更新 overlay_start
}
```

## 嵌入 vs 依赖

| 方式 | 结论 |
|------|------|
| 路径依赖 `../md2ansi` | ❌ `publish/z-agent/` 中无 md2ansi 目录，编译断裂 |
| build.zig.zon 发布引用 | ❌ md2ansi 未发布到 GitHub 独立仓库 |
| **源码嵌入 `src/md2ansi/`** | ✅ publish 自包含，推 GitHub 即编译 |

## 同步策略

两边的渲染核心文件各自维护，不自动同步。当修复涉及渲染逻辑时，手动同步到另一侧。

| 方向 | 操作 |
|------|------|
| z-agent 修了 bug → md2ansi | 手动改 `projects/md2ansi/src/` 对应文件 |
| md2ansi 修了 bug → z-agent | 手动改 `z-agent/src/md2ansi/` 对应文件 |

## 进度

| 阶段 | 状态 |
|------|------|
| 方案设计（全量→v2 段落级覆盖） | ✅ 已完成 |
| 嵌入渲染核心 | ✅ 已完成 |
| build.zig 加 module | ✅ 已完成 |
| openai_compat.zig 段落级覆盖集成 | ✅ 已完成 |
| 行数计算 + ANSI 覆盖逻辑 | ✅ 已完成（含列偏移/分隔线/emoji/缓冲区等修复） |
| 验证编译 + 测试 | ✅ 已完成（zig build + 真实终端验证） |
| ui-overview.md 更新 | ✅ 已完成 |
