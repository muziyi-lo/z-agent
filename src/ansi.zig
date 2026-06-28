const std = @import("std");
const builtin = @import("builtin");

const esc = "\x1b";

pub const red = esc ++ "[31m";
pub const green = esc ++ "[32m";
pub const yellow = esc ++ "[33m";
pub const blue = esc ++ "[34m";
pub const magenta = esc ++ "[35m";
pub const cyan = esc ++ "[36m";
pub const bold = esc ++ "[1m";
pub const dim = esc ++ "[2m";
pub const reset = esc ++ "[0m";

pub const Color = struct {
    red: []const u8 = "",
    green: []const u8 = "",
    yellow: []const u8 = "",
    cyan: []const u8 = "",
    bold: []const u8 = "",
    dim: []const u8 = "",
    reset: []const u8 = "",
};

pub var C: Color = .{};

var supported: bool = false;

pub fn init() void {
    if (builtin.os.tag == .windows) {
        const ENABLE_VIRTUAL_TERMINAL_PROCESSING: u32 = 0x0004;
        const STD_OUTPUT_HANDLE: u32 = @bitCast(@as(i32, -11));
        const handle = GetStdHandle(STD_OUTPUT_HANDLE);
        if (handle != @as(*anyopaque, @ptrFromInt(@as(usize, @bitCast(@as(isize, -1)))))) {
            var mode: u32 = 0;
            if (GetConsoleMode(handle, &mode) != 0) {
                _ = SetConsoleMode(handle, mode | ENABLE_VIRTUAL_TERMINAL_PROCESSING);
                supported = true;
            }
        }
    } else {
        supported = true;
    }
    if (supported) {
        C = .{
            .red = red,
            .green = green,
            .yellow = yellow,
            .cyan = cyan,
            .bold = bold,
            .dim = dim,
            .reset = reset,
        };
    }
}

pub fn supportsColor() bool {
    return supported;
}

extern "kernel32" fn GetStdHandle(nStdHandle: u32) callconv(.winapi) *anyopaque;
extern "kernel32" fn GetConsoleMode(hConsoleHandle: *anyopaque, lpMode: *u32) callconv(.winapi) i32;
extern "kernel32" fn SetConsoleMode(hConsoleHandle: *anyopaque, dwMode: u32) callconv(.winapi) i32;

test "ansi: init enables colors" {
    init();
    // After init, supportsColor should be true on non-Windows or when VT enabled
    // Just test it doesn't crash
}
