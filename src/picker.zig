const std = @import("std");
const ansi = @import("ansi.zig");

const Key = enum(u8) {
    up,
    down,
    enter,
    esc,
    unknown,
};

/// Read a single keypress from stdin. Handles Enter, Escape, and arrow key VT sequences.
/// Returns .esc on EOF/error to prevent infinite loops in non-interactive mode.
fn readKey(io: std.Io) Key {
    const stdin_file = std.Io.File.stdin();
    var buf: [4]u8 = undefined;
    const n = stdin_file.readStreaming(io, &.{&buf}) catch return .esc;
    if (n == 0) return .esc;

    if (buf[0] == '\r') return .enter;
    if (buf[0] == '\x1b') {
        if (n < 3) return .esc;
        // ANSI/VT encoding: \x1b[A (up), \x1b[B (down)
        // DEC encoding: \x1bOA (up), \x1bOB (down)
        if (buf[1] == '[' or buf[1] == 'O') {
            return switch (buf[2]) {
                'A' => .up,
                'B' => .down,
                else => .unknown,
            };
        }
        return .esc;
    }
    return .unknown;
}

/// Interactive picker — display a title and selectable options, navigate with ↑↓, confirm with Enter, cancel with Esc.
/// Returns the index of the selected option, or null if cancelled via Esc.
/// Caller owns nothing; returned value is a simple `?usize`.
///
pub fn select(
    allocator: std.mem.Allocator,
    io: std.Io,
    stdout: *std.Io.Writer,
    title: []const u8,
    options: []const []const u8,
    initial: usize,
) !?usize {
    _ = allocator;
    const n = options.len;
    if (n == 0) return error.EmptyOptions;
    var selected = if (initial < n) initial else 0;

    // Initial draw
    try stdout.print("{s}\n", .{title});
    for (options, 0..) |opt, i| {
        if (i == selected) {
            try stdout.print("{s}> {s}{s}\n", .{ ansi.C.cyan, opt, ansi.C.reset });
        } else {
            try stdout.print("  {s}\n", .{opt});
        }
    }
    try stdout.flush();

    while (true) {
        const key = readKey(io);
        switch (key) {
            .up => {
                if (selected > 0) selected -= 1;
            },
            .down => {
                if (selected + 1 < n) selected += 1;
            },
            .enter => {
                try stdout.print("\x1b[{d}A\x1b[J", .{n + 1});
                try stdout.flush();
                return selected;
            },
            .esc => {
                try stdout.print("\x1b[{d}A\x1b[J", .{n + 1});
                try stdout.flush();
                return null;
            },
            else => continue,
        }

        // Redraw all rows: move cursor up, then rewrite each line
        try stdout.print("\x1b[{d}A", .{n + 1});
        for (0..n + 1) |i| {
            try stdout.print("\x1b[2K\r", .{});
            if (i == 0) {
                try stdout.print("{s}", .{title});
            } else {
                const opt_idx = i - 1;
                if (opt_idx == selected) {
                    try stdout.print("{s}> {s}{s}", .{ ansi.C.cyan, options[opt_idx], ansi.C.reset });
                } else {
                    try stdout.print("  {s}", .{options[opt_idx]});
                }
            }
            try stdout.print("\n", .{});
        }
        try stdout.flush();
    }
}

test "Key enum values match expected order" {
    const testing = std.testing;
    try testing.expectEqual(@as(u8, 0), @intFromEnum(Key.up));
    try testing.expectEqual(@as(u8, 1), @intFromEnum(Key.down));
    try testing.expectEqual(@as(u8, 2), @intFromEnum(Key.enter));
    try testing.expectEqual(@as(u8, 3), @intFromEnum(Key.esc));
    try testing.expectEqual(@as(u8, 4), @intFromEnum(Key.unknown));
}

test "select: empty options returns error" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const io = testing.io;
    var buf: [256]u8 = undefined;
    var w: std.Io.File.Writer = .init(.stdout(), io, &buf);
    const stdout = &w.interface;

    try testing.expectError(error.EmptyOptions, select(allocator, io, stdout, "title", &.{}, 0));
}
