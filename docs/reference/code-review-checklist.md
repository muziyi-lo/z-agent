# z-agent 代码审查清单

基于实际开发经验裁剪，仅覆盖本项目用到的 Zig 0.16.0 模式。

## Critical（一票否决）

| ID | 检查项 | 说明 |
|----|--------|------|
| M-01 | `defer` 覆盖所有返回路径 | `allocPrint` / `dupe` / `appendSlice` 等分配后，确保所有 `return` / `catch` 路径前已注册 `defer` |
| M-02 | `resize` 后切片悬垂 | `list.resize()` 后原 `items` 指针失效，必须重新获取 `list.items` |
| E-01 | `!T` 错误未处理 | 返回 `!T` 的函数调用必须 `try` / `catch`，禁止隐式假设不会出错 |
| E-02 | `catch unreachable` 范围 | 仅限编译期已知或刚验证过的值。来自外部输入/IO 的值绝对不能用 |

## High（必须修改）

| ID | 检查项 | 说明 |
|----|--------|------|
| M-03 | Struct 持有 allocator 时需 deinit | 如 `Client` 内部持有 `allocator` + `http`，调用侧必须调 `deinit` |
| M-04 | 临时文件清理 | 写入临时文件（如 `z-agent-body.json`）后必须 `defer deleteFile` |
| E-03 | curl 子进程错误处理 | 必须检查 `result.term`（exit code），不能假设 curl 总是成功 |
| T-01 | `@ptrCast` / `@intCast` 边界守卫 | 必须有 `assert(value <= max)` 或 `if` 守卫 |
| W-01 | Windows 控制台编码 | 涉及中文输入时，必须调用 `SetConsoleCP(65001)` |
| C-01 | curl `-H` 参数格式 | Header 值必须是完整 `Header-Name: value` 格式，不能裸传值 |

## Medium（视场景而定）

| ID | 检查项 | 说明 |
|----|--------|------|
| C-02 | `defer` > 3 个的函数 | 超过 3 个 `defer` 且行数 > 120 行，建议拆分 |
| C-03 | 函数嵌套 > 4 层 | 尝试早返回或提取辅助函数 |
| I-01 | 请求体 JSON 手动构造 | 使用 `appendEscapedJsonString` 确保 `"` / `\` / `\n` 转义 |
| I-02 | `parseFromSliceLeaky` 内存 | 返回值是借用还是拥有？调用侧必须清楚所有权 |

## Suggestion（风格优化）

| ID | 检查项 | 说明 |
|----|--------|------|
| D-01 | 函数名含 `And` / `Also` | 违反单一职责，建议拆分 |
| D-02 | 公开函数名 < 3 字符 | 缩写是否过于生僻？ |
| R-01 | 错误路径测试 | 至少一个 `test` 覆盖错误路径 |

## 仅适用于本项目场景

- 所有 HTTP 请求走 `curl.exe` 子进程（`std.http.Client` 在 Windows 不可用）
- 非 ASCII 文本（中文）必须通过临时文件传给 curl，不能走命令行参数
- `std.Io.Dir.*` / `std.Io.File.*` 所有函数都需要 `io` 参数（Zig 0.16 的 Io API）
- 配置文件写入/读取使用 `Io.Dir` API，非 `std.fs`
