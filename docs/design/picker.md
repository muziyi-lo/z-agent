# Picker 交互式选择器设计

> 设计：2026-07-01 | 实现：`src/picker.zig` | 状态：已提交

---

## 1. 架构

```
select(allocator, io, stdout, title, options, initial)
  ├─ 初始绘制：title + 逐行选项（选中行青色 > 前缀）
  ├─ 按键循环
  │     ├─ readKey(io) → Key.up/down/enter/esc
  │     ├─ ↑/↓ → 更新 selected 索引
  │     ├─ Enter → \x1b[{N+1}A\x1b[J 清理 → 返回 selected
  │     └─ Esc   → \x1b[{N+1}A\x1b[J 清理 → 返回 null
  └─ 重绘：\x1b[{N+1}A + 逐行 \x1b[2K\r + 内容 + \n

readKey(io)
  ├─ stdin_file.readStreaming(io, &.{&buf})
  ├─ \r → enter
  ├─ \x1b[A / \x1bOA → up
  ├─ \x1b[B / \x1bOB → down
  ├─ \x1b (short) → esc
  └─ EOF/error → esc（防止非交互模式死循环）
```

## 2. API

```zig
pub fn select(
    allocator: std.mem.Allocator,
    io: std.Io,
    stdout: *std.Io.Writer,
    title: []const u8,             // 标题文本
    options: []const []const u8,   // 选项标签列表
    initial: usize,                // 初始选中索引
) !?usize  // 选中索引，null=取消
```

## 3. 渲染算法

```
N = options.len
总行数 = N + 1（含标题）

初始绘制:
  lines
  Y:   继续?
  Y+1: > 是(Y)          ← 青色
  Y+2:   否(N)
  光标在 Y+3

按键后重绘:
  \x1b[3A              ← 上移 N+1 行到 Y
  \x1b[2K\r 继续?\n     ← 清行+归位+标题
  \x1b[2K\r > 是(Y)\n   ← 或 "  否(N)"
  \x1b[2K\r   否(N)\n
  光标再次在 Y+3

退出清理:
  \x1b[3A\x1b[J        ← 上移 N+1 行 + 清除到底
```

## 4. 输入模式

| 键 | VT 序列 | 行为 |
|----|---------|------|
| ↑ | `\x1b[A` / `\x1bOA` | selected = max(0, -1) |
| ↓ | `\x1b[B` / `\x1bOB` | selected = min(N-1, +1) |
| Enter | `\r` | 返回 selected |
| Esc | `\x1b` | 返回 null |
| EOF/错误 | — | 返回 null（防死循环） |

### Windows 控制台配置

`ansi.zig` `init()` 中增加输入句柄 VT 模式：

```
STD_INPUT_HANDLE = -10
GetConsoleMode(in_handle, &in_mode)
SetConsoleMode(in_handle, in_mode | 0x0200)  // ENABLE_VIRTUAL_TERMINAL_INPUT
```

`ENABLE_VIRTUAL_TERMINAL_INPUT`（0x0200）使箭头键以 VT 转义序列形式输入，而非返回 `VK_UP` 等虚拟键码。

## 5. 集成点

| 位置 | 场景 | 选项 |
|------|------|------|
| `src/agent.zig` 权限确认 | 写文件权限 | `["是(Y)", "否(N)"]` |
| `src/App.zig` 模型切换 | 上下文溢出确认 | `["继续", "取消"]` |
| `src/Cli.zig` 会话列表（未来） | 交互式会话选择 | 动态 session 列表 |
| `src/App.zig` 命令补全（未来） | / 命令弹出选择 | 动态命令列表 |

## 6. 常量

| 常量 | 值 | 用途 |
|------|-----|------|
| `ENABLE_VIRTUAL_TERMINAL_INPUT` | 0x0200 | Windows 控制台 VT 输入模式 |

## 7. 不改的

- `ask_user.zig` — 保持自由文本输入（非选择）
- `App.zig:readLine` — REPL 保持自由文本
- `permission.zig` — 不涉及交互

## 8. 文件范围

| 文件 | 改动量 | 说明 |
|------|--------|------|
| `src/picker.zig` | 122 行新增 | picker 核心 |
| `src/ansi.zig` | +6 行 | 输入句柄 VT 模式 |
| `src/agent.zig` | -16 行 | 权限确认改用 picker，删除 readlineConfirm |
| `src/App.zig` | -18 行 | 模型切换改用 picker，删除 readlineConfirm |
| `src/test.zig` | +1 行 | 引入 picker 测试 |

## 9. 测试

| 测试 | 覆盖 |
|------|------|
| Key 枚举值顺序 | up/down/enter/esc/unknown 映射正确 |
| 空选项错误 | options 为空时返回 error.EmptyOptions |
