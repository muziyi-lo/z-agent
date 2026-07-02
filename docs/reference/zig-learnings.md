# Zig 踩坑记录（z-agent 项目）

## 1. std.ArrayList 改为 std.array_list.Managed

Zig 0.16.0 中 `std.ArrayList(T)` 返回的 `Aligned(T, null)` **没有 `.init()` 方法**。

```zig
// ❌ 编译错误
var list = std.ArrayList(u8).init(allocator);

// ✅ 正确用法
var list = std.array_list.Managed(u8).init(allocator);
defer list.deinit();
try list.appendSlice("hello");
return list.toOwnedSlice();
```

也没有 `initCapacity`，直接用 `appendSlice` 追加即可。

## 2. std.fs.cwd() 已移除，改用 Io.Dir.cwd()

`std.fs.cwd()` 不存在。所有文件操作必须通过 `std.Io.Dir.cwd()`。

```zig
// ❌ 编译错误
std.fs.cwd().writeFile(.{ ... });

// ✅ 正确用法
const io = ...; // 从 init.io 或 testing.io 获取
const cwd = std.Io.Dir.cwd();
var file = try cwd.openFile(io, path, .{ .mode = .read_only });
defer file.close(io);
```

注意：
- `Io.Dir` 不提供 `removeFile`
- `Io.File` 不提供 `seekTo` / `setLength`
- 写入模式：先 close 读句柄，再 `createFile` 截断写入

## 3. 测试中获取 Io 实例用 testing.io

```zig
// ❌ 编译错误
const io = std.Io.init();

// ✅ 正确用法
const io = testing.io; // 来自 std.testing 模块
```

`std.testing` 已预定义 `io: Io.Threaded`，可直接使用。

## 4. 匿名枚举跨函数类型不匹配

两个匿名 `enum { lf, crlf }` 即使变体完全相同，在不同函数签名中也是**不同类型**。

```zig
// ❌ 编译错误：type mismatch
fn fn1() enum { lf, crlf } { return .lf; }
fn fn2(x: enum { lf, crlf }) void {}
fn2(fn1()); // 类型不匹配

// ✅ 提取为具名类型
pub const LineEnding = enum { lf, crlf };
fn fn1() LineEnding { return .lf; }
fn fn2(x: LineEnding) void {}
```

## 5. 函数指针类型避免 error union

Zig 函数指针类型**不能使用 inferred error set**（`!T` 语法）。

```zig
// ❌ 不能这样写
execute: *const fn (allocator, io, args) ![]const u8,

// ✅ 返回纯字符串，错误转为字符串
execute: *const fn (allocator, io, args) []const u8,
```

handler 内部用 `catch` 替代 `try` 将所有错误转为字符串。

## 6. defer 重复 close 文件句柄

`defer file.close(io)` 后再次显式 `file.close(io)` 会导致 `INVALID_HANDLE`。

```zig
// ❌ 错误：defer 在函数返回时再次 close 已关闭的句柄
var file = try cwd.openFile(io, path, .{ .mode = .read_only });
defer file.close(io);
// ... 读取内容 ...
file.close(io); // 显式关闭
// ... 后续 createFile 写入 ...
// 函数返回时 defer 再次 close → INVALID_HANDLE

// ✅ 用块作用域控制生命周期
const content = readFile: {
    var f = try cwd.openFile(io, path, .{ .mode = .read_only });
    defer f.close(io);
    // ... 读取内容 ...
    break :readFile buf; // 块结束时 defer 自动 close
};
// 此时句柄已关闭，可以安全地 createFile
```
