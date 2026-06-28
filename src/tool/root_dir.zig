const std = @import("std");

pub var project_root: []const u8 = "";

pub fn init(path: []const u8) void {
    project_root = path;
}

/// Resolve a path against project_root.
/// - Absolute paths (C:\... or /...) returned as-is (no allocation).
/// - Relative paths joined with project_root (caller must free).
/// - If project_root not initialized, fall back to cwd-relative (no allocation).
pub fn resolvePath(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(path) or project_root.len == 0) {
        return path;
    }
    return std.fs.path.join(allocator, &.{ project_root, path });
}

test "resolvePath: absolute returned as-is" {
    const testing = std.testing;
    const result = try resolvePath(testing.allocator, "C:\\absolute\\path");
    // result points to the input literal, no free needed
    try testing.expectEqualStrings("C:\\absolute\\path", result);
}

test "resolvePath: relative joins with project_root when initialized" {
    const testing = std.testing;
    const allocator = testing.allocator;
    init("C:\\root");
    defer init("");
    const result = try resolvePath(allocator, "sub\\file.txt");
    defer allocator.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "C:\\root") != null);
    try testing.expect(std.mem.indexOf(u8, result, "sub\\file.txt") != null);
}

test "resolvePath: relative falls back to cwd-relative when not initialized" {
    const testing = std.testing;
    const result = try resolvePath(testing.allocator, "relative.txt");
    // project_root is empty, returns input directly (no allocation)
    try testing.expectEqualStrings("relative.txt", result);
}

test "resolvePath: unix absolute path returned as-is" {
    const testing = std.testing;
    const result = try resolvePath(testing.allocator, "/unix/absolute/path");
    // result points to the input literal, no free needed
    try testing.expectEqualStrings("/unix/absolute/path", result);
}
