const std = @import("std");
const json = @import("json.zig");
const root_dir = @import("root_dir.zig");
const ToolResult = @import("registry.zig").ToolResult;

pub const tool_name = "write_file";
pub const tool_description = "Write content to a file. Creates parent directories if they don't exist.";
pub const tool_params = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\",\"description\":\"Path to the file\"},\"content\":{\"type\":\"string\",\"description\":\"Content to write\"}},\"required\":[\"path\",\"content\"]}";

pub fn execute(allocator: std.mem.Allocator, io: std.Io, args: std.json.Value) ToolResult {
    const args_obj = args.object;
    const path = args_obj.get("path") orelse return ToolResult.fail("Error: missing 'path' argument");
    const content = args_obj.get("content") orelse return ToolResult.fail("Error: missing 'content' argument");

    const resolved = root_dir.resolvePath(allocator, path.string) catch return ToolResult.fail("Error: OOM");
    defer if (resolved.ptr != path.string.ptr) allocator.free(resolved);

    const dir_end = std.mem.lastIndexOfScalar(u8, resolved, '/') orelse
        std.mem.lastIndexOfScalar(u8, resolved, '\\') orelse 0;
    if (dir_end > 0) {
        std.Io.Dir.cwd().createDirPath(io, resolved[0..dir_end]) catch |err| {
            return ToolResult.fail(jsonErrorStr(allocator, "cannot create parent dir for '{s}': {}", .{ path.string, err }));
        };
    }

    const cwd = std.Io.Dir.cwd();
    const file = cwd.createFile(io, resolved, .{}) catch |err| {
        return ToolResult.fail(jsonErrorStr(allocator, "cannot write file '{s}': {}", .{ path.string, err }));
    };
    defer file.close(io);
    file.writeStreamingAll(io, content.string) catch |err| {
        return ToolResult.fail(jsonErrorStr(allocator, "cannot write to file '{s}': {}", .{ path.string, err }));
    };

    var buf = std.array_list.Managed(u8).init(allocator);
    defer buf.deinit();
    json.putc(&buf, '{') catch return ToolResult.fail("Error: OOM");
    json.putString(&buf, "path", path.string) catch return ToolResult.fail("Error: OOM");
    json.putc(&buf, ',') catch return ToolResult.fail("Error: OOM");
    json.putInt(&buf, "bytes", content.string.len) catch return ToolResult.fail("Error: OOM");
    json.putc(&buf, ',') catch return ToolResult.fail("Error: OOM");
    const preview_len = @min(content.string.len, @as(usize, 200));
    json.putString(&buf, "content_preview", content.string[0..preview_len]) catch return ToolResult.fail("Error: OOM");
    json.putc(&buf, '}') catch return ToolResult.fail("Error: OOM");
    return ToolResult.ok(json.finish(&buf));
}

fn jsonErrorStr(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(allocator, "Error: " ++ fmt, args) catch "Error: OOM";
}

test "write_file creates file and returns JSON" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const io = testing.io;
    const tmp_path = "zig_test_write_output.txt";

    const args_json = try std.fmt.allocPrint(allocator, "{{\"path\": \"{s}\", \"content\": \"hello zig\"}}", .{tmp_path});
    defer allocator.free(args_json);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, args_json, .{}) catch return;
    defer parsed.deinit();
    const args = parsed.value;
    const tr = execute(allocator, io, args);
    defer allocator.free(tr.output);
    defer std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};

    try testing.expect(tr.success);
    try testing.expect(std.mem.startsWith(u8, tr.output, "{"));
    try testing.expect(std.mem.indexOf(u8, tr.output, "\"bytes\":9") != null);
    try testing.expect(std.mem.indexOf(u8, tr.output, "\"content_preview\"") != null);
    try testing.expect(std.mem.indexOf(u8, tr.output, "\"path\"") != null);
}

test "write_file missing path returns error" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const io = testing.io;

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, "{\"content\": \"data\"}", .{}) catch return;
    defer parsed.deinit();
    const args = parsed.value;
    const tr = execute(allocator, io, args);
    try testing.expect(!tr.success);
    try testing.expect(std.mem.startsWith(u8, tr.output, "Error:"));
}
