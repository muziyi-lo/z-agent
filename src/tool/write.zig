const std = @import("std");
const json = @import("json.zig");
const root_dir = @import("root_dir.zig");
const ToolResult = @import("registry.zig").ToolResult;
const ansi = @import("../ansi.zig");

pub const tool_name = "write_file";
pub const tool_description = "Write content to a file. Creates parent directories if they don't exist.";
pub const tool_params = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\",\"description\":\"Path to the file\"},\"content\":{\"type\":\"string\",\"description\":\"Content to write\"}},\"required\":[\"path\",\"content\"]}";

const MAX_WRITE: usize = 512 * 1024; // 512 KB
const PREVIEW_MAX_CP: usize = 200;

/// Source: tool/write.zig — execute write_file tool
pub fn execute(allocator: std.mem.Allocator, io: std.Io, args: std.json.Value) ToolResult {
    const args_obj = args.object;
    const path = args_obj.get("path") orelse return ToolResult.fail("Error: missing 'path' argument");
    const content = args_obj.get("content") orelse return ToolResult.fail("Error: missing 'content' argument");

    if (content.string.len > MAX_WRITE) {
        return ToolResult.fail(jsonErrorStr(allocator, "content too large: {d} bytes (max {d} KB)", .{ content.string.len, MAX_WRITE / 1024 }));
    }

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

    // Atomic write: write to .tmp then rename

    const abs_resolved = abs_resolved: {
        if (std.fs.path.isAbsolute(resolved)) break :abs_resolved resolved;
        var cwd_buf: [4096]u8 = undefined;
        const cwd_len = cwd.realPath(io, &cwd_buf) catch break :abs_resolved resolved;
        const joined = std.fs.path.join(allocator, &.{ cwd_buf[0..cwd_len], resolved }) catch break :abs_resolved resolved;
        break :abs_resolved joined;
    };
    defer if (abs_resolved.ptr != resolved.ptr) allocator.free(abs_resolved);

    const tmp_path = std.fmt.allocPrint(allocator, "{s}.tmp", .{abs_resolved}) catch {
        return ToolResult.fail("Error: OOM");
    };
    defer allocator.free(tmp_path);

    var rename_succeeded = false;
    defer if (!rename_succeeded) cwd.deleteFile(io, tmp_path) catch {};

    {
        var wfile = cwd.createFile(io, tmp_path, .{}) catch |err| {
            return ToolResult.fail(jsonErrorStr(allocator, "cannot write file '{s}': {}", .{ path.string, err }));
        };
        wfile.writeStreamingAll(io, content.string) catch |err| {
            wfile.close(io);
            return ToolResult.fail(jsonErrorStr(allocator, "write failed: {}", .{err}));
        };
        wfile.close(io);
    }

    std.Io.Dir.renameAbsolute(tmp_path, abs_resolved, io) catch |err| {
        return ToolResult.fail(jsonErrorStr(allocator, "rename failed: {}", .{err}));
    };
    rename_succeeded = true;

    var buf = std.array_list.Managed(u8).init(allocator);
    defer buf.deinit();
    json.putc(&buf, '{') catch return ToolResult.fail("Error: OOM");
    json.putString(&buf, "path", path.string) catch return ToolResult.fail("Error: OOM");
    json.putc(&buf, ',') catch return ToolResult.fail("Error: OOM");
    json.putInt(&buf, "bytes", content.string.len) catch return ToolResult.fail("Error: OOM");
    json.putc(&buf, ',') catch return ToolResult.fail("Error: OOM");
    var preview_byte_end: usize = 0;
    var preview_cp_count: usize = 0;
    while (preview_byte_end < content.string.len and preview_cp_count < PREVIEW_MAX_CP) {
        const seq_len = std.unicode.utf8ByteSequenceLength(content.string[preview_byte_end]) catch break;
        if (preview_byte_end + seq_len > content.string.len) break;
        preview_byte_end += seq_len;
        preview_cp_count += 1;
    }
    json.putString(&buf, "content_preview", content.string[0..preview_byte_end]) catch return ToolResult.fail("Error: OOM");
    json.putc(&buf, '}') catch return ToolResult.fail("Error: OOM");
    return ToolResult.ok(json.finish(&buf));
}

fn jsonErrorStr(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(allocator, "Error: " ++ fmt, args) catch "Error: OOM";
}

/// Source: tool/write.zig — render write_file result for user display
pub fn renderResult(allocator: std.mem.Allocator, stdout: *std.Io.Writer, json_str: []const u8) !void {
    if (!std.mem.startsWith(u8, json_str, "{")) {
        try stdout.print("  {s}\u{2717}{s} {s}\n", .{ ansi.C.red, ansi.C.reset, json_str });
        return;
    }
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, json_str, .{}) catch return;
    defer parsed.deinit();
    const obj = parsed.value.object;

    const path_str = if (obj.get("path")) |v| if (v == .string) v.string else "" else "";
    const bytes = if (obj.get("bytes")) |v| @as(u64, @intCast(v.integer)) else 0;
    const preview = if (obj.get("content_preview")) |v| if (v == .string) v.string else "" else "";

    try stdout.print("  {s}\u{2713}{s} {d} bytes → {s}\n", .{ ansi.C.green, ansi.C.reset, bytes, path_str });
    if (preview.len > 0) {
        var lines = std.mem.splitScalar(u8, preview, '\n');
        while (lines.next()) |line| {
            try stdout.print("  | {s}\n", .{std.mem.trimEnd(u8, line, "\r")});
        }
    }
}

fn readTestFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    const cwd = std.Io.Dir.cwd();
    var file = try cwd.openFile(io, path, .{ .mode = .read_only });
    defer file.close(io);
    const stat = try file.stat(io);
    const content = try allocator.alloc(u8, @as(usize, @intCast(stat.size)));
    _ = try file.readStreaming(io, &.{content});
    return content;
}

test "write_file creates file and returns JSON" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const io = testing.io;
    const tmp_path = "zig_test_write_output.txt";
    const tmp_tmp_path = "zig_test_write_output.txt.tmp";

    const args_json = try std.fmt.allocPrint(allocator, "{{\"path\": \"{s}\", \"content\": \"hello zig\"}}", .{tmp_path});
    defer allocator.free(args_json);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, args_json, .{}) catch return;
    defer parsed.deinit();
    const args = parsed.value;
    const tr = execute(allocator, io, args);
    defer allocator.free(tr.output);
    defer std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, tmp_tmp_path) catch {};

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

test "write_file content too large" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const io = testing.io;
    const tmp_path = "zig_test_write_large.txt";
    defer std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, "zig_test_write_large.txt.tmp") catch {};

    const content_buf = try allocator.alloc(u8, MAX_WRITE + 1);
    defer allocator.free(content_buf);
    @memset(content_buf, 'x');
    const content = content_buf;

    var map = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    try map.put(allocator, "path", std.json.Value{ .string = try allocator.dupe(u8, tmp_path) });
    try map.put(allocator, "content", std.json.Value{ .string = content });
    const args = std.json.Value{ .object = map };
    const tr = execute(allocator, io, args);
    defer allocator.free(tr.output);
    map.deinit(allocator);

    try testing.expect(!tr.success);
    try testing.expect(std.mem.indexOf(u8, tr.output, "too large") != null);
}

test "write_file codepoint preview" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const io = testing.io;
    const tmp_path = "zig_test_write_cp.txt";

    const args_json = try std.fmt.allocPrint(allocator, "{{\"path\": \"{s}\", \"content\": \"{s}\"}}", .{tmp_path, "你好世界abc"});
    defer allocator.free(args_json);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, args_json, .{}) catch return;
    defer parsed.deinit();
    const args = parsed.value;
    const tr = execute(allocator, io, args);
    defer allocator.free(tr.output);
    defer std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, "zig_test_write_cp.txt.tmp") catch {};

    try testing.expect(tr.success);
    try testing.expect(std.mem.indexOf(u8, tr.output, "\"content_preview\"") != null);
    try testing.expect(std.mem.indexOf(u8, tr.output, "你好世界") != null);
    try testing.expect(std.mem.indexOf(u8, tr.output, "\"bytes\"") != null);
}

test "write_file atomic write cleanup" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const io = testing.io;
    const tmp_path = "zig_test_write_atomic.txt";
    const tmp_tmp_path = "zig_test_write_atomic.txt.tmp";

    const args_json = try std.fmt.allocPrint(allocator, "{{\"path\": \"{s}\", \"content\": \"atomic test\"}}", .{tmp_path});
    defer allocator.free(args_json);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, args_json, .{}) catch return;
    defer parsed.deinit();
    const args = parsed.value;
    const tr = execute(allocator, io, args);
    defer allocator.free(tr.output);
    defer std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, tmp_tmp_path) catch {};

    try testing.expect(tr.success);

    // Verify content was written
    const read_content = try readTestFile(allocator, io, tmp_path);
    defer allocator.free(read_content);
    try testing.expectEqualStrings("atomic test", read_content);

    // Verify .tmp file was cleaned up
    const cwd = std.Io.Dir.cwd();
    if (cwd.openFile(io, tmp_tmp_path, .{ .mode = .read_only })) |file| {
        file.close(io);
        try testing.expect(false); // .tmp should not exist
    } else |_| {}
}
