const std = @import("std");
const Io = std.Io;

extern "kernel32" fn GetStdHandle(nStdHandle: u32) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn WriteConsoleW(h: ?*anyopaque, buf: [*]const u16, len: u32, written: *u32, _: ?*anyopaque) callconv(.winapi) i32;
extern "kernel32" fn MultiByteToWideChar(cp: u32, _: u32, src: [*]const u8, srcLen: i32, dst: ?[*]u16, dstLen: i32) callconv(.winapi) i32;
extern "kernel32" fn GetLastError() callconv(.winapi) u32;
extern "kernel32" fn WriteFile(h: ?*anyopaque, buf: [*]const u8, len: u32, written: *u32, _: ?*anyopaque) callconv(.winapi) i32;

pub fn main(_: std.process.Init) !void {
    var buf: [256]u8 = undefined;
    var w: Io.File.Writer = .init(.stdout(), undefined, &buf);
    const out = &w.interface;

    const handle = GetStdHandle(@bitCast(@as(i32, -11)));
    try out.print("handle={any}\n", .{handle});

    const text = "hello你好\x00";
    var wbuf: [32]u16 = undefined;
    const n = MultiByteToWideChar(65001, 0, text.ptr, @intCast(text.len - 1), &wbuf, wbuf.len);
    try out.print("mb2wc n={d} err={d}\n", .{ n, GetLastError() });

    if (n > 0 and handle != null) {
        var wr: u32 = 0;
        const ok = WriteConsoleW(handle, &wbuf, @intCast(n), &wr, null);
        try out.print("writecon ok={d} wr={d} err={d}\n", .{ ok, wr, GetLastError() });
    }

    // Fallback: try WriteFile
    const fallback = "FALLBACK via WriteFile: hello你好\n";
    var fw: u32 = 0;
    _ = WriteFile(handle, fallback.ptr, @intCast(fallback.len), &fw, null);
    try out.print("writefile wr={d} err={d}\n", .{ fw, GetLastError() });

    try out.flush();
}
