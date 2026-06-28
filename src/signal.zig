const std = @import("std");
const builtin = @import("builtin");

var interrupted: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

pub fn isInterrupted() bool {
    return interrupted.load(.acquire);
}

fn setInterrupted() void {
    interrupted.store(true, .release);
}

pub fn reset() void {
    interrupted.store(false, .release);
}

pub fn init() void {
    if (builtin.os.tag == .windows) {
        _ = SetConsoleCtrlHandler(ctrlHandler, 1);
    } else if (@TypeOf(std.posix.SIG) != void) {
        const act = std.posix.Sigaction{
            .handler = .{ .handler = posixHandler },
            .mask = std.posix.empty_sigset,
            .flags = 0,
        };
        std.posix.sigaction(std.posix.SIG.INT, &act, null) catch {};
    }
}

/// Check if ESC key is currently pressed (Windows only).
pub fn isEscPressed() bool {
    if (builtin.os.tag == .windows) {
        const VK_ESCAPE: i32 = 0x1B;
        const state: u16 = @bitCast(GetAsyncKeyState(VK_ESCAPE));
        return (state & 0x8000) != 0;
    }
    return false;
}

/// Returns true if Ctrl+C was pressed or ESC is currently held.
pub fn isCancelled() bool {
    return isInterrupted() or isEscPressed();
}

extern "kernel32" fn SetConsoleCtrlHandler(handler_routine: ?*const fn (dwCtrlType: u32) callconv(.winapi) i32, add: i32) callconv(.winapi) i32;
extern "user32" fn GetAsyncKeyState(vKey: i32) callconv(.winapi) i16;

fn ctrlHandler(dwCtrlType: u32) callconv(.winapi) i32 {
    if (dwCtrlType == 0 or dwCtrlType == 1) {
        setInterrupted();
        return 1;
    }
    return 0;
}

fn posixHandler(_: i32) callconv(.C) void {
    setInterrupted();
}

test "signal: isInterrupted returns false by default" {
    const testing = std.testing;
    try testing.expect(!isInterrupted());
}
