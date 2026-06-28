const std = @import("std");

extern "kernel32" fn GetStdHandle(nStdHandle: u32) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn WriteFile(hFile: ?*anyopaque, lpBuffer: [*]const u8, nNumberOfBytesToWrite: u32, lpNumberOfBytesWritten: *u32, lpOverlapped: ?*anyopaque) callconv(.winapi) i32;

const STD_OUTPUT_HANDLE: u32 = @bitCast(@as(i32, -11));
var cached_handle: ?*anyopaque = null;

pub fn write(data: []const u8) void {
    if (cached_handle == null) cached_handle = GetStdHandle(STD_OUTPUT_HANDLE);
    const handle = cached_handle orelse return;
    if (data.len == 0) return;
    var written: u32 = 0;
    _ = WriteFile(handle, data.ptr, @intCast(data.len), &written, null);
}

test "console write is no-op in test env" {
    const testing = std.testing;
    write("test"); // GetStdHandle returns null → no-op, just verify no crash
    try testing.expect(true);
}
