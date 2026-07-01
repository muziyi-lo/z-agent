const std = @import("std");
const Io = std.Io;
const session = @import("session.zig");
const ansi = @import("ansi.zig");

const builtin = @import("builtin");

extern "kernel32" fn SetConsoleOutputCP(wCodePageID: u32) callconv(.winapi) i32;
extern "kernel32" fn SetConsoleCP(wCodePageID: u32) callconv(.winapi) i32;
extern "kernel32" fn Sleep(dwMilliseconds: u32) callconv(.winapi) void;

pub fn setConsoleUtf8() void {
    _ = SetConsoleOutputCP(65001);
    _ = SetConsoleCP(65001);
}

pub fn sleepMs(ms: u64) void {
    if (ms == 0) return;
    if (builtin.os.tag == .windows) {
        const capped = @as(u32, @intCast(if (ms > 0x7FFFFFFF) @as(u64, 0x7FFFFFFF) else ms));
        Sleep(capped);
    } else {
        const ns = ms * 1_000_000;
        var ts = std.posix.timespec{
            .tv_sec = @intCast(@divFloor(ns, 1_000_000_000)),
            .tv_nsec = @intCast(ns % 1_000_000_000),
        };
        _ = std.c.nanosleep(&ts, null);
    }
}

pub fn printHelp(stdout: *Io.Writer) !void {
    try stdout.print(
        \\z-agent — Zig LLM Agent Runtime
        \\
        \\Usage:
        \\  z-agent [flags] [<prompt>]
        \\
        \\Flags:
        \\  -h, --help                   Show this help message
        \\  -l, --list                   List available sessions
        \\  -s, --session <index|id>    Resume a specific session
        \\  --agent <path>               Run as sub-agent with given agent definition
        \\  --model <provider/model>     Override default model (e.g. deepseek/deepseek-v4-flash)
        \\  --trust                      Skip all permission confirmations
        \\  --readonly                   Deny all write operations (read-only mode)
        \\
        \\If <prompt> is provided, runs in single-turn mode.
        \\Otherwise, starts an interactive REPL.
        \\
    , .{});
    try stdout.flush();
}

pub fn printSessionList(allocator: std.mem.Allocator, io: Io, stdout: *Io.Writer, session_dir: []const u8) !void {
    const sessions = session.listSessions(allocator, io, session_dir) catch {
        try stdout.print("No sessions found.\n", .{});
        try stdout.flush();
        return;
    };
    defer session.freeSessionInfo(allocator, sessions);

    if (sessions.len == 0) {
        try stdout.print("No sessions found.\n", .{});
        try stdout.flush();
        return;
    }

    const c = &ansi.C;
    try stdout.print("{s}{s}#  {s:<20}  {s:<19}  {s:>5}  {s}{s}\n", .{ c.bold, c.cyan, "session_id", "time", "msgs", "model", c.reset });
    for (sessions) |s| {
        try stdout.print("{s}{d:<2}{s}  {s:<20}  {s:<19}  {d:>5}  {s}\n", .{ c.dim, s.index, c.reset, s.id, s.timestamp, s.msg_count, s.model });
    }
    try stdout.flush();
}
