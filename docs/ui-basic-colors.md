# 基础配色层 — 开发文档

## 1. 现状分析

现有 `src/ansi.zig`（70 行）提供：

- ✅ ANSI 转义码常量（red/green/yellow/blue/magenta/cyan/bold/dim/reset）
- ✅ `Color` 结构体 + 运行时 `C` 变量（init 后填充）
- ✅ Windows VT 处理（kernel32）
- ✅ `supportsColor()` 布尔查询

缺失：

- ❌ `NO_COLOR` 环境变量检测（https://no-color.org/）
- ❌ 管道/重定向检测（`file.isTty()`）
- ❌ 逐文件颜色判断（`shouldColorize(file)` 而非全局布尔）
- ❌ 便捷格式化函数（如 `green(text)`、`dim(text)` 包裹写法）
- ❌ `Color` 结构附带的 `pub const` 常量为 0，无备色

## 2. 设计目标

```
shouldColorize(file)
  ├─ NO_COLOR → false
  ├─ TERM=dumb → false
  ├─ !file.isTty() → false
  ├─ Windows VT 启用失败 → false
  └─ true
```

- 运行时按需判断，而非启动时固定
- 颜色函数通过 Writer 写入，零分配、零泄漏
- 向下兼容现有 `C.red` / `C.reset` 等字段调用
- 完整测试

## 3. API 设计

```zig
// 四级检测链
pub fn shouldColorize(file: std.fs.File) bool;

// Writer 版颜色写入函数（内部调用 shouldColorize + 写入 ANSI 包裹）
pub fn green(writer: anytype, text: []const u8, file: std.fs.File) !void;
pub fn yellow(writer: anytype, text: []const u8, file: std.fs.File) !void;
pub fn red(writer: anytype, text: []const u8, file: std.fs.File) !void;
pub fn bold(writer: anytype, text: []const u8, file: std.fs.File) !void;
pub fn dim(writer: anytype, text: []const u8, file: std.fs.File) !void;
pub fn reset(writer: anytype, text: []const u8, file: std.fs.File) !void;
```

### Color 结构体演进

```zig
pub const Color = struct {
    pub const reset = "\x1b[0m";
    pub const green = "\x1b[32m";
    pub const yellow = "\x1b[33m";
    pub const red = "\x1b[31m";
    pub const bold = "\x1b[1m";
    pub const dim = "\x1b[2m";
    pub const cyan = "\x1b[36m";
    pub const blue = "\x1b[34m";
    pub const magenta = "\x1b[35m";
};
```

现有 `pub var C: Color = .{}` 保留，但增加 `Color.xxx` 编译期常量。**不建议新代码使用 `C` 全局变量**，新代码应直接引用 `Color.xxx` 常量。

## 4. 废弃策略

- `supportsColor()` 加 `@deprecated` 注解，引导迁移到 `shouldColorize(file)`
- 旧 `C.red` / `C.green` 等运行时字段保留兼容，但标记为 deprecated

## 5. 文件变更

| 文件 | 操作 | 说明 |
|------|------|------|
| `src/ansi.zig` | 重写 | 新版 API，保持导出兼容 |
| 调用方 | 审查 | 搜索 `C.red` / `supportsColor()` 使用处，迁移到新 API |

## 6. 测试计划

```
test "shouldColorize: respects NO_COLOR env"
test "shouldColorize: returns false when TERM=dumb"
test "shouldColorize: returns false for redirected stdout"
test "shouldColorize: returns true for TTY on non-Windows"
test "shouldColorize: returns false when Windows VT fails"
test "green() writes ANSI-wrapped text when color supported"
test "green() writes plain text when color not supported"
test "green() composes with bold() dim() correctly"
test "Color pub const values are correct escape codes"
```

## 7. 边界情况

- `NO_COLOR` 设空字符串 ✅ 规范要求即使是空值也应禁用
- 同时有 `NO_COLOR` 和 TTY ✅ 优先环境变量
- `TERM=dumb` 时关闭颜色 ✅ 已纳入四级检测链
- 非 stdout 文件（stderr）由调用方传不同 file 参数自行控制
