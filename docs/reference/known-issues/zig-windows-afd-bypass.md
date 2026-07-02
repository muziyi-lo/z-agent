# Zig Windows AFD 直调缺陷

## 问题

Zig 0.16.0 在 Windows 上绕过标准 Winsock (`ws2_32.dll`)，直接通过 `DeviceIoControl` 调用内核 `\Device\Afd` 驱动（PR #31571）。这导致 `std.http.Client` 在此环境完全不可用：

- **TCP 连接超时**：`STATUS_IO_TIMEOUT`（0xc00000b5）
- **网络不可达**：`STATUS_NETWORK_UNREACHABLE`（0xc000023c）
- 所有 HTTPS 请求均失败，无论目标地址

Zig stdlib 未将这些 NTSTATUS 码映射为合适错误，直接抛 `error.Unexpected`（issue #31956）。

## 现象

```
error.Unexpected NTSTATUS=0xc00000b5 (IO_TIMEOUT)
  lib/std/Io/Threaded.zig:12121:57 in netConnectIpWindows
    else => |status| return windows.unexpectedStatus(status),
```

## 根因

Zig 的 `std.Io.Threaded` 为实现统一的跨平台异步 I/O 模型（对标 Linux io_uring），在 Windows 上选择 IOCP + `\Device\Afd` 直调方案，绕过了 `ws2_32.dll`。该路径存在多个已知问题：

| Issue | 问题 | 状态 |
|-------|------|------|
| #31956 | AFD 操作返回的 NTSTATUS 码缺少映射，大量合理状态被抛为 `error.Unexpected` | 未修复 |
| #31499 | Windows 内核 bug 导致 Unix socket 超时 | 未修复 |
| #32088 | 无法调用 `setsockopt`（缺少 Winsock 封装层） | 未修复 |
| #35649 | 无法设置 `Io.net` socket options | 未修复 |

## 缓解方案

本项目改用 `curl.exe` 子进程发送 HTTP 请求，规避 `std.http.Client`。

```zig
const result = try std.process.Child.run(.{
    .allocator = allocator,
    .argv = &.{ "curl.exe", "-s", "--max-time", "30", ... },
});
```

## 追踪

- [PR #31571](https://codeberg.org/ziglang/zig/pulls/31571) — windows networking without ws2_32
- [Issue #31956](https://codeberg.org/ziglang/zig/issues/31956) — NTSTATUS values unmapped
- [Issue #31499](https://codeberg.org/ziglang/zig/issues/31499) — Windows kernel Unix socket timeout
- 预计 Zig 0.18.0+ 可能改进 Windows 网络层
