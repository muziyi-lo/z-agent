# z-agent 界面美化方案

## 参考项目分析

对 DeepSeek-Reasonix、nullclaw、pi-repos 三个 AI Agent 项目的界面美化路径拆解。

### 三项目对比

| 维度 | DeepSeek-Reasonix (Go) | nullclaw (Zig) | pi-repos (TS) |
|------|----------------------|----------------|---------------|
| UI 形式 | 全屏 TUI + Desktop + Bot | CLI + 交互式向导 | 全屏 TUI + CLI |
| 渲染框架 | Bubble Tea + Lip Gloss | 手写 ANSI（零依赖） | 自制 TUI 引擎 + chalk |
| 主题系统 | 8 变体 × 12 色槽，OSC-11 自动检测 | 无主题系统，硬编码颜色 | JSON 51 色令牌，热重载 |
| Markdown | goldmark 完整渲染 | 仅过滤 `<think>` 标签 | marked 完整渲染 |
| 语法高亮 | chroma | 无 | highlight.js |
| 编辑器 | Bubble Tea 内置 | 无（REPL + `>` 提示） | 自制编辑器（undo/kill-ring） |
| 二进制大小 | 大（Go runtime） | **678 KB** | 大（Node runtime） |
| UI 依赖数 | 15+ 库 | **0** | 3 库 |

### DeepSeek-Reasonix 关键路径

```
internal/cli/
├── chat_tui.go    # 主 TUI 模型（3898 行）
├── style.go       # ANSI 样式原语
├── theme.go       # 8 主题 × 12 色槽 + OSC-11 终端背景检测
├── md.go          # goldmark → ANSI 渲染器
├── diffview.go    # chroma 语法高亮 + 行号 diff
├── toolcard.go    # 工具调用卡片（分类彩色圆点）
├── box.go         # 圆角框绘制
├── view_helpers.go# 布局组件（header/status/hint/budget）
└── theme_osc_unix.go # 终端背景色探测
```

### nullclaw 关键路径（Zig 零依赖路线）

```
src/
├── terminal_color.zig  # ANSI 颜色常量 + NO_COLOR/TTY/Windows VT 检测
├── streaming.zig       # TagFilter（剥离工具标签）+ ThinkPassthroughFilter
├── admin_output.zig    # stdout 写入工具函数
├── onboard.zig         # ASCII banner + 分步向导（8 步）
├── doctor.zig          # [ok]/[warn]/[ERR] 彩色诊断
├── capabilities.zig    # 彩色通道状态表
├── status.zig          # 格式化 key-value 状态输出
├── qr.zig              # Unicode 半块字符 QR 码终端渲染
└── agent/cli.zig       # REPL 循环（流式输出 + usage/cost 显示）
```

### pi-repos 关键路径

```
packages/tui/src/
├── tui.ts           # 差分渲染引擎 + 覆盖层系统
├── terminal.ts      # 终端抽象（raw mode / Kitty 键盘协议）
├── components/      # markdown / editor / select-list / box / loader / image
└── utils.ts         # 宽度测量 / 文本换行 / ANSI 处理

packages/coding-agent/src/modes/interactive/theme/
├── theme.ts         # JSON 主题加载 + ANSI 转换 + 终端背景检测
├── dark.json        # 51 色令牌暗色主题
├── light.json       # 51 色令牌亮色主题
└── theme-schema.json
```

---

## 实施状态

| 层 | 文档 | 状态 |
|---|------|------|
| 第一层 — 基础配色 | `ui-basic-colors.md` | ✅ **已完成**（commit `f3a6572`） |
| 第二层 — 流式输出美化 | `ui-streaming.md` | ✅ **已完成**（commit `b3a4d41`） |
| 第三层 — 主题系统 | — | ❌ 不做（复杂度不足，当前硬编码颜色够用） |
| 第四层 — Markdown 渲染 | `ui-markdown.md` | ✅ **已完成**（段落级覆盖 + md2ansi 嵌入） |

## 核心策略

走 **nullclaw 的零依赖路线** + **pi-repos 的主题系统设计思路**。每层可独立交付，不阻塞核心功能。
