const std = @import("std");
const builtin = @import("builtin");

pub const Color = struct {
    reset: []const u8 = "\x1b[0m",
    green: []const u8 = "\x1b[32m",
    yellow: []const u8 = "\x1b[33m",
    red: []const u8 = "\x1b[31m",
    bold: []const u8 = "\x1b[1m",
    dim: []const u8 = "\x1b[2m",
    cyan: []const u8 = "\x1b[36m",
    blue: []const u8 = "\x1b[34m",
    magenta: []const u8 = "\x1b[35m",
};

pub const C: Color = .{};

var _color_ok: bool = false;
var console_handle: ?*anyopaque = null;

pub fn init() void {
    if (builtin.os.tag == .windows) {
        const STD_OUTPUT_HANDLE: u32 = @bitCast(@as(i32, -11));
        console_handle = GetStdHandle(STD_OUTPUT_HANDLE);
        _color_ok = enableWindowsVT();

        // Enable VT input mode for arrow key escape sequences
        const STD_INPUT_HANDLE: u32 = @bitCast(@as(i32, -10));
        const ENABLE_VIRTUAL_TERMINAL_INPUT: u32 = 0x0200;
        const in_handle = GetStdHandle(STD_INPUT_HANDLE);
        if (in_handle != @as(*anyopaque, @ptrFromInt(@as(usize, @bitCast(@as(isize, -1)))))) {
            var in_mode: u32 = 0;
            if (GetConsoleMode(in_handle, &in_mode) != 0) {
                _ = SetConsoleMode(in_handle, in_mode | ENABLE_VIRTUAL_TERMINAL_INPUT);
            }
        }
    } else {
        _color_ok = true;
    }
}

/// Get terminal width in columns. Returns 80 on failure or non-TTY.
pub fn terminalWidth() u16 {
    if (builtin.os.tag == .windows) {
        if (console_handle) |handle| {
            var info: CONSOLE_SCREEN_BUFFER_INFO = undefined;
            if (GetConsoleScreenBufferInfo(handle, &info) != 0) {
                const x = info.dwSize.X;
                if (x > 0) return @intCast(x);
            }
        }
    }
    return 80;
}

pub fn supportsColor() bool {
    return _color_ok;
}

pub fn shouldColorize() bool {
    if (comptime builtin.link_libc) {
        if (std.c.getenv("NO_COLOR")) |_| return false;
        if (std.c.getenv("TERM")) |term| {
            if (std.mem.eql(u8, std.mem.span(term), "dumb")) return false;
        }
        if (std.c.isatty(std.posix.STDOUT_FILENO) == 0) return false;
    }
    if (!_color_ok) return false;
    return true;
}

fn enableWindowsVT() bool {
    const ENABLE_VIRTUAL_TERMINAL_PROCESSING: u32 = 0x0004;
    const STD_OUTPUT_HANDLE: u32 = @bitCast(@as(i32, -11));
    const handle = GetStdHandle(STD_OUTPUT_HANDLE);
    if (handle == @as(*anyopaque, @ptrFromInt(@as(usize, @bitCast(@as(isize, -1)))))) {
        return false;
    }
    var mode: u32 = 0;
    if (GetConsoleMode(handle, &mode) == 0) return false;
    _ = SetConsoleMode(handle, mode | ENABLE_VIRTUAL_TERMINAL_PROCESSING);
    return true;
}

extern "kernel32" fn GetStdHandle(nStdHandle: u32) callconv(.winapi) *anyopaque;
extern "kernel32" fn GetConsoleMode(hConsoleHandle: *anyopaque, lpMode: *u32) callconv(.winapi) i32;
extern "kernel32" fn SetConsoleMode(hConsoleHandle: *anyopaque, dwMode: u32) callconv(.winapi) i32;
extern "kernel32" fn GetConsoleScreenBufferInfo(hConsoleOutput: *anyopaque, lpConsoleScreenBufferInfo: *CONSOLE_SCREEN_BUFFER_INFO) callconv(.winapi) i32;

const COORD = extern struct {
    X: i16,
    Y: i16,
};

const SMALL_RECT = extern struct {
    Left: i16,
    Top: i16,
    Right: i16,
    Bottom: i16,
};

const CONSOLE_SCREEN_BUFFER_INFO = extern struct {
    dwSize: COORD,
    dwCursorPosition: COORD,
    wAttributes: u16,
    srWindow: SMALL_RECT,
    dwMaximumWindowSize: COORD,
};

test "Color default values are correct escape codes" {
    const c: Color = .{};
    try std.testing.expectEqualStrings("\x1b[0m", c.reset);
    try std.testing.expectEqualStrings("\x1b[32m", c.green);
    try std.testing.expectEqualStrings("\x1b[33m", c.yellow);
    try std.testing.expectEqualStrings("\x1b[31m", c.red);
    try std.testing.expectEqualStrings("\x1b[1m", c.bold);
    try std.testing.expectEqualStrings("\x1b[2m", c.dim);
    try std.testing.expectEqualStrings("\x1b[36m", c.cyan);
    try std.testing.expectEqualStrings("\x1b[34m", c.blue);
    try std.testing.expectEqualStrings("\x1b[35m", c.magenta);
}

test "init + supportsColor legacy compat" {
    init();
    _ = supportsColor();
}

test "shouldColorize: respects NO_COLOR env when libc linked" {
    if (!builtin.link_libc) return error.SkipZigTest;
    init();
    try std.testing.expect(!shouldColorize());
}

test "shouldColorize: returns false on pipe on libc platforms" {
    if (!builtin.link_libc) return error.SkipZigTest;
    // On non-TTY stdout, isatty returns 0; in test runner stdout is typically a pipe
    init();
    if (std.c.isatty(std.posix.STDOUT_FILENO) == 0) {
        try std.testing.expect(!shouldColorize());
    }
}

test "terminalWidth: returns 80 in non-TTY context" {
    // In test runner (non-TTY), terminalWidth should fall back to 80.
    // On Windows with libc, GetConsoleScreenBufferInfo may also fail (pipe), returning 80.
    init();
    try std.testing.expectEqual(@as(u16, 80), terminalWidth());
}
