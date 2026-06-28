const std = @import("std");
const jh = @import("json.zig");
const root_dir = @import("root_dir.zig");
const ToolResult = @import("registry.zig").ToolResult;

pub const tool_name = "edit_file";
pub const tool_description = "Edit a file by replacing exact text. oldString must match exactly (including whitespace and indentation). If multiple matches exist, set replaceAll=true or the tool will return an error.";
pub const tool_params = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\",\"description\":\"Path to the file\"},\"oldString\":{\"type\":\"string\",\"description\":\"Exact text to find (must match byte-exact, including whitespace and indentation)\"},\"newString\":{\"type\":\"string\",\"description\":\"Replacement text\"},\"replaceAll\":{\"type\":\"boolean\",\"description\":\"Replace all occurrences (default: false). Required if multiple matches exist.\"}},\"required\":[\"path\",\"oldString\",\"newString\"]}";

const BOM_LEN: usize = 3;
const BOM_BYTES: [3]u8 = .{ 0xEF, 0xBB, 0xBF };

// ---------------------------------------------------------------------------
// 内部 API：纯函数，不含 I/O
// ---------------------------------------------------------------------------

pub const LineEnding = enum { lf, crlf };

fn detectBom(content: []const u8) bool {
    return content.len >= BOM_LEN and std.mem.eql(u8, content[0..BOM_LEN], &BOM_BYTES);
}

fn detectLineEnding(content: []const u8) LineEnding {
    if (content.len < 2) return .lf;
    var i: usize = 0;
    while (i < content.len - 1) : (i += 1) {
        if (content[i] == '\r' and content[i + 1] == '\n') return .crlf;
        if (content[i] == '\n') return .lf;
    }
    return .lf;
}

fn convertToLineEnding(text: []const u8, target: LineEnding, allocator: std.mem.Allocator) ![]const u8 {
    if (target == .lf) return text;
    var result = std.array_list.Managed(u8).init(allocator);
    errdefer result.deinit();
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '\n') {
            if (i == 0 or text[i - 1] != '\r') {
                try result.appendSlice("\r\n");
            } else {
                try result.append('\n');
            }
        } else if (text[i] == '\r') {
            if (i + 1 < text.len and text[i + 1] == '\n') {
                try result.appendSlice("\r\n");
                i += 1;
            } else {
                try result.append('\r');
            }
        } else {
            try result.append(text[i]);
        }
        i += 1;
    }
    return result.toOwnedSlice();
}

fn countOccurrences(text: []const u8, pattern: []const u8) usize {
    if (pattern.len == 0) return 0;
    var count: usize = 0;
    var start: usize = 0;
    while (std.mem.indexOfPos(u8, text, start, pattern)) |pos| {
        count += 1;
        start = pos + pattern.len;
    }
    return count;
}

test "detectBom: detects BOM correctly" {
    const testing = std.testing;
    try testing.expect(detectBom("\xEF\xBB\xBFhello"));
    try testing.expect(!detectBom("hello"));
    try testing.expect(!detectBom(""));
}

test "detectLineEnding: LF vs CRLF" {
    const testing = std.testing;
    try testing.expect(detectLineEnding("line1\nline2\n") == .lf);
    try testing.expect(detectLineEnding("line1\r\nline2\r\n") == .crlf);
    try testing.expect(detectLineEnding("no newline") == .lf);
}

test "countOccurrences: basic" {
    const testing = std.testing;
    try testing.expectEqual(@as(usize, 0), countOccurrences("abc", "x"));
    try testing.expectEqual(@as(usize, 1), countOccurrences("abc", "b"));
    try testing.expectEqual(@as(usize, 2), countOccurrences("aba", "a"));
    try testing.expectEqual(@as(usize, 2), countOccurrences("aaaa", "aa")); // non-overlapping
}

test "convertToLineEnding: LF to CRLF" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const result = try convertToLineEnding("hello\nworld\n", .crlf, allocator);
    defer allocator.free(result);
    try testing.expectEqualStrings("hello\r\nworld\r\n", result);
}

// ---------------------------------------------------------------------------
// 公开 API
// ---------------------------------------------------------------------------

pub fn execute(allocator: std.mem.Allocator, io: std.Io, args: std.json.Value) ToolResult {
    const args_obj = args.object;
    const path = args_obj.get("path") orelse return ToolResult.fail("Error: missing 'path' argument");
    const old_string = args_obj.get("oldString") orelse return ToolResult.fail("Error: missing 'oldString' argument");
    const new_string = args_obj.get("newString") orelse return ToolResult.fail("Error: missing 'newString' argument");
    const replace_all = if (args_obj.get("replaceAll")) |v| (v == .bool and v.bool) else false;

    const os = old_string.string;
    const ns = new_string.string;

    if (os.len == 0) return ToolResult.fail("Error: oldString must not be empty. Use write_file to create a file.");
    if (std.mem.eql(u8, os, ns)) return ToolResult.fail("Error: no changes to apply: oldString and newString are identical.");

    const resolved = root_dir.resolvePath(allocator, path.string) catch {
        return ToolResult.fail("Error: OOM");
    };
    defer if (resolved.ptr != path.string.ptr) allocator.free(resolved);

    const cwd = std.Io.Dir.cwd();
    const content = readFile: {
        var file = cwd.openFile(io, resolved, .{ .mode = .read_only }) catch |err| {
            return ToolResult.fail(errorString(allocator, "cannot open file '{s}': {}", .{ path.string, err }));
        };
        defer file.close(io);

        const stat = file.stat(io) catch |err| {
            return ToolResult.fail(errorString(allocator, "cannot stat file '{s}': {}", .{ path.string, err }));
        };
        const buf = allocator.alloc(u8, @as(usize, @intCast(stat.size))) catch |err| {
            return ToolResult.fail(errorString(allocator, "OOM reading file: {}", .{err}));
        };
        _ = file.readStreaming(io, &.{buf}) catch |err| {
            allocator.free(buf);
            return ToolResult.fail(errorString(allocator, "cannot read file '{s}': {}", .{ path.string, err }));
        };
        break :readFile buf;
    };
    defer allocator.free(content);

    // BOM detection
    const bom_present = detectBom(content);
    const text_start: usize = if (bom_present) BOM_LEN else 0;
    const text = content[text_start..];

    // Line ending detection
    const le = detectLineEnding(text);
    const normalized_old = convertToLineEnding(os, le, allocator) catch {
        return ToolResult.fail("Error: OOM during string conversion");
    };
    defer if (normalized_old.ptr != os.ptr) allocator.free(normalized_old);

    // Count occurrences
    const count = countOccurrences(text, normalized_old);
    if (count == 0) {
        return ToolResult.fail(errorString(allocator, "could not find oldString in '{s}'", .{path.string}));
    }
    if (count > 1 and !replace_all) {
        return ToolResult.fail(errorString(allocator, "found {d} matches. Set replaceAll=true or provide more context.", .{count}));
    }

    // Do replacement
    const normalized_new = convertToLineEnding(ns, le, allocator) catch {
        return ToolResult.fail("Error: OOM during string conversion");
    };
    defer if (normalized_new.ptr != ns.ptr) allocator.free(normalized_new);

    const new_text = if (replace_all)
        replaceAll(allocator, text, normalized_old, normalized_new)
    else
        replaceOne(allocator, text, normalized_old, normalized_new);
    const final_text = new_text catch |err| {
        return ToolResult.fail(errorString(allocator, "replacement failed: {}", .{err}));
    };
    defer allocator.free(final_text);

    // Reassemble with BOM
    const write_content = if (bom_present) blk: {
        const with_bom = allocator.alloc(u8, BOM_LEN + final_text.len) catch {
            return ToolResult.fail("Error: OOM");
        };
        @memcpy(with_bom[0..BOM_LEN], &BOM_BYTES);
        @memcpy(with_bom[BOM_LEN..], final_text);
        break :blk with_bom;
    } else final_text;

    // Reopen with truncation and write
    {
        var wfile = cwd.createFile(io, resolved, .{}) catch |err| {
            if (bom_present) allocator.free(write_content);
            return ToolResult.fail(errorString(allocator, "cannot write file '{s}': {}", .{ path.string, err }));
        };
        defer wfile.close(io);
        wfile.writeStreamingAll(io, write_content) catch |err| {
            if (bom_present) allocator.free(write_content);
            return ToolResult.fail(errorString(allocator, "write failed: {}", .{err}));
        };
    }

    if (bom_present) allocator.free(write_content);

    var buf = std.array_list.Managed(u8).init(allocator);
    defer buf.deinit();
    jh.putc(&buf, '{') catch return ToolResult.fail("Error: OOM");
    jh.putString(&buf, "path", path.string) catch return ToolResult.fail("Error: OOM");
    jh.putc(&buf, ',') catch return ToolResult.fail("Error: OOM");
    jh.putInt(&buf, "replacements", @as(u64, count)) catch return ToolResult.fail("Error: OOM");
    jh.putc(&buf, '}') catch return ToolResult.fail("Error: OOM");
    return ToolResult.ok(jh.finish(&buf));
}

fn replaceOne(allocator: std.mem.Allocator, text: []const u8, old: []const u8, new: []const u8) ![]const u8 {
    const pos = std.mem.indexOf(u8, text, old) orelse return text;
    var result = std.array_list.Managed(u8).init(allocator);
    try result.appendSlice(text[0..pos]);
    try result.appendSlice(new);
    try result.appendSlice(text[pos + old.len ..]);
    return result.toOwnedSlice();
}

fn replaceAll(allocator: std.mem.Allocator, text: []const u8, old: []const u8, new: []const u8) ![]const u8 {
    var result = std.array_list.Managed(u8).init(allocator);
    var start: usize = 0;
    while (std.mem.indexOfPos(u8, text, start, old)) |pos| {
        try result.appendSlice(text[start..pos]);
        try result.appendSlice(new);
        start = pos + old.len;
    }
    try result.appendSlice(text[start..]);
    return result.toOwnedSlice();
}

fn errorString(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(allocator, "Error: " ++ fmt, args) catch "Error: internal (OOM)";
}

// ---------------------------------------------------------------------------
// 集成测试
// ---------------------------------------------------------------------------

fn readTestFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    const cwd = std.Io.Dir.cwd();
    var file = try cwd.openFile(io, path, .{ .mode = .read_only });
    defer file.close(io);
    const stat = try file.stat(io);
    const content = try allocator.alloc(u8, @as(usize, @intCast(stat.size)));
    _ = try file.readStreaming(io, &.{content});
    return content;
}

fn writeTestFile(io: std.Io, path: []const u8, data: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    var file = try cwd.createFile(io, path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, data);
}

test "edit: basic string replacement" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const io = testing.io;
    const tmp_path = "zig_test_edit_basic.txt";

    try writeTestFile(io, tmp_path, "hello world");
    defer std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};

    const jargs = try std.fmt.allocPrint(allocator, "{{\"path\": \"{s}\", \"oldString\": \"world\", \"newString\": \"there\"}}", .{tmp_path});
    defer allocator.free(jargs);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, jargs, .{}) catch return;
    defer parsed.deinit();
    const args = parsed.value;
    const tr = execute(allocator, io, args);
    defer allocator.free(tr.output);

    try testing.expect(tr.success);
    try testing.expect(std.mem.startsWith(u8, tr.output, "{"));
    try testing.expect(std.mem.indexOf(u8, tr.output, "\"replacements\":1") != null);

    const read_content = try readTestFile(allocator, io, tmp_path);
    defer allocator.free(read_content);
    try testing.expectEqualStrings("hello there", read_content);
}

test "edit: oldString not found" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const io = testing.io;
    const tmp_path = "zig_test_edit_notfound.txt";

    try writeTestFile(io, tmp_path, "hello world");
    defer std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};

    const jargs = try std.fmt.allocPrint(allocator, "{{\"path\": \"{s}\", \"oldString\": \"xyz\", \"newString\": \"abc\"}}", .{tmp_path});
    defer allocator.free(jargs);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, jargs, .{}) catch return;
    defer parsed.deinit();
    const args = parsed.value;
    const tr = execute(allocator, io, args);
    defer allocator.free(tr.output);

    try testing.expect(!tr.success);
    try testing.expect(std.mem.startsWith(u8, tr.output, "Error:"));
    try testing.expect(std.mem.indexOf(u8, tr.output, "could not find") != null);
}

test "edit: oldString empty returns error" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const io = testing.io;

    const jargs = "{\"path\": \"test.txt\", \"oldString\": \"\", \"newString\": \"abc\"}";
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, jargs, .{}) catch return;
    defer parsed.deinit();
    const args = parsed.value;
    const tr = execute(allocator, io, args);

    try testing.expect(!tr.success);
    try testing.expect(std.mem.startsWith(u8, tr.output, "Error:"));
    try testing.expect(std.mem.indexOf(u8, tr.output, "oldString must not be empty") != null);
}

test "edit: oldString equals newString returns error" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const io = testing.io;

    const jargs = "{\"path\": \"test.txt\", \"oldString\": \"abc\", \"newString\": \"abc\"}";
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, jargs, .{}) catch return;
    defer parsed.deinit();
    const args = parsed.value;
    const tr = execute(allocator, io, args);

    try testing.expect(!tr.success);
    try testing.expect(std.mem.startsWith(u8, tr.output, "Error:"));
    try testing.expect(std.mem.indexOf(u8, tr.output, "no changes to apply") != null);
}

test "edit: multiple matches without replaceAll" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const io = testing.io;
    const tmp_path = "zig_test_edit_multi.txt";

    try writeTestFile(io, tmp_path, "a a a");
    defer std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};

    const jargs = try std.fmt.allocPrint(allocator, "{{\"path\": \"{s}\", \"oldString\": \"a\", \"newString\": \"b\"}}", .{tmp_path});
    defer allocator.free(jargs);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, jargs, .{}) catch return;
    defer parsed.deinit();
    const args = parsed.value;
    const tr = execute(allocator, io, args);
    defer allocator.free(tr.output);

    try testing.expect(!tr.success);
    try testing.expect(std.mem.indexOf(u8, tr.output, "found") != null);
    try testing.expect(std.mem.indexOf(u8, tr.output, "replaceAll") != null);
}

test "edit: replaceAll replaces all occurrences" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const io = testing.io;
    const tmp_path = "zig_test_edit_all.txt";

    try writeTestFile(io, tmp_path, "a a a");
    defer std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};

    const jargs = try std.fmt.allocPrint(allocator, "{{\"path\": \"{s}\", \"oldString\": \"a\", \"newString\": \"b\", \"replaceAll\": true}}", .{tmp_path});
    defer allocator.free(jargs);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, jargs, .{}) catch return;
    defer parsed.deinit();
    const args = parsed.value;
    const tr = execute(allocator, io, args);
    defer allocator.free(tr.output);

    try testing.expect(tr.success);
    try testing.expect(std.mem.startsWith(u8, tr.output, "{"));
    try testing.expect(std.mem.indexOf(u8, tr.output, "\"replacements\":3") != null);

    const read_content = try readTestFile(allocator, io, tmp_path);
    defer allocator.free(read_content);
    try testing.expectEqualStrings("b b b", read_content);
}

test "edit: BOM preservation" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const io = testing.io;
    const tmp_path = "zig_test_edit_bom.txt";

    const cwd = std.Io.Dir.cwd();
    const bom = [_]u8{ 0xEF, 0xBB, 0xBF };
    {
        var file = try cwd.createFile(io, tmp_path, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, bom[0..]);
        try file.writeStreamingAll(io, "hello world");
    }
    defer cwd.deleteFile(io, tmp_path) catch {};

    const jargs = try std.fmt.allocPrint(allocator, "{{\"path\": \"{s}\", \"oldString\": \"world\", \"newString\": \"there\"}}", .{tmp_path});
    defer allocator.free(jargs);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, jargs, .{}) catch return;
    defer parsed.deinit();
    const args = parsed.value;
    const tr = execute(allocator, io, args);
    defer allocator.free(tr.output);

    try testing.expect(tr.success);
    try testing.expect(std.mem.startsWith(u8, tr.output, "{"));
    try testing.expect(std.mem.indexOf(u8, tr.output, "\"replacements\"") != null);

    const read_content = try readTestFile(allocator, io, tmp_path);
    defer allocator.free(read_content);
    try testing.expect(read_content.len >= 3);
    try testing.expect(std.mem.eql(u8, read_content[0..3], &bom));
    try testing.expectEqualStrings("hello there", read_content[3..]);
}
