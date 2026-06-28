const std = @import("std");
const jh = @import("json.zig");
const trunc = @import("truncate.zig");
const root_dir = @import("root_dir.zig");
const ToolResult = @import("registry.zig").ToolResult;

pub const tool_name = "grep";
pub const tool_description = "Search for a text pattern in files. Searches a single file or recursively through a directory. Returns matching lines with file path and line number.";
pub const tool_params = "{\"type\":\"object\",\"properties\":{\"pattern\":{\"type\":\"string\",\"description\":\"Substring to search for\"},\"path\":{\"type\":\"string\",\"description\":\"File or directory path\"},\"include\":{\"type\":\"string\",\"description\":\"File filter (e.g. *.zig), optional\"}},\"required\":[\"pattern\",\"path\"]}";

const MAX_OUTPUT: usize = 50 * 1024;
const MAX_MATCHES: usize = 500;

const Match = struct {
    file: []const u8,
    line: usize,
    content: []const u8,
};

pub fn execute(allocator: std.mem.Allocator, io: std.Io, args: std.json.Value) ToolResult {
    const args_obj = args.object;
    const pattern_val = args_obj.get("pattern") orelse return ToolResult.fail("Error: missing 'pattern' argument");
    const path_val = args_obj.get("path") orelse return ToolResult.fail("Error: missing 'path' argument");
    const pattern = pattern_val.string;
    const path = path_val.string;
    const include_pattern = if (args_obj.get("include")) |v| if (v != .null) v.string else null else null;

    const resolved = root_dir.resolvePath(allocator, path) catch return ToolResult.fail("Error: OOM");
    defer if (resolved.ptr != path.ptr) allocator.free(resolved);

    var matches = std.array_list.Managed(Match).init(allocator);
    defer {
        for (matches.items) |m| allocator.free(m.file);
        for (matches.items) |m| allocator.free(m.content);
        matches.deinit();
    }

    grepPath(allocator, io, resolved, pattern, include_pattern, &matches) catch |err| {
        return ToolResult.fail(jhErrorStr(allocator, "grep failed: {}", .{err}));
    };

    const output = buildOutput(allocator, pattern, path, matches.items) catch return ToolResult.fail("Error: OOM");
    const r = trunc.truncateLines(output, MAX_OUTPUT);
    return ToolResult.ok(r.text);
}

fn grepPath(allocator: std.mem.Allocator, io: std.Io, file_path: []const u8, pattern: []const u8, include_pattern: ?[]const u8, matches: *std.array_list.Managed(Match)) anyerror!void {
    var dir = std.Io.Dir.cwd();
    var try_dir = dir.openDir(io, file_path, .{ .iterate = true }) catch {
        try grepFile(allocator, io, file_path, pattern, matches);
        return;
    };
    defer try_dir.close(io);

    var iter = try_dir.iterate();
    while (iter.next(io) catch null) |entry| {
        if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) continue;
        if (entry.kind == .directory) {
            const sub = try std.fs.path.join(allocator, &.{ file_path, entry.name });
            defer allocator.free(sub);
            try grepPath(allocator, io, sub, pattern, include_pattern, matches);
        } else {
            if (include_pattern) |inc| {
                if (!matchGlob(entry.name, inc)) continue;
            }
            const full = try std.fs.path.join(allocator, &.{ file_path, entry.name });
            defer allocator.free(full);
            try grepFile(allocator, io, full, pattern, matches);
        }
    }
}

fn grepFile(allocator: std.mem.Allocator, io: std.Io, file_path: []const u8, pattern: []const u8, matches: *std.array_list.Managed(Match)) anyerror!void {
    var file = std.Io.Dir.cwd().openFile(io, file_path, .{ .mode = .read_only }) catch return;
    defer file.close(io);

    const size = (file.stat(io) catch return).size;
    if (size > 10 * 1024 * 1024) return; // skip files > 10MB

    const content = allocator.alloc(u8, @as(usize, @intCast(size))) catch return;
    defer allocator.free(content);
    _ = file.readStreaming(io, &.{content}) catch return;

    var line_start: usize = 0;
    var line_num: usize = 1;
    var i: usize = 0;
    while (i < content.len) : (i += 1) {
        if (content[i] == '\n') {
            const line = content[line_start..i];
            if (std.mem.indexOf(u8, line, pattern) != null) {
                try matches.append(Match{
                    .file = try allocator.dupe(u8, file_path),
                    .line = line_num,
                    .content = try allocator.dupe(u8, line),
                });
                if (matches.items.len >= MAX_MATCHES) return;
            }
            line_start = i + 1;
            line_num += 1;
        }
    }
    if (line_start < content.len) {
        const line = content[line_start..];
        if (std.mem.indexOf(u8, line, pattern) != null) {
            try matches.append(Match{
                .file = try allocator.dupe(u8, file_path),
                .line = line_num,
                .content = try allocator.dupe(u8, line),
            });
        }
    }
}

fn matchGlob(name: []const u8, pattern: []const u8) bool {
    var ni: usize = 0;
    var pi: usize = 0;
    var star_idx: ?usize = null;
    var match_idx: usize = 0;

    while (ni < name.len) {
        if (pi < pattern.len and (pattern[pi] == '?' or pattern[pi] == name[ni])) {
            ni += 1;
            pi += 1;
        } else if (pi < pattern.len and pattern[pi] == '*') {
            star_idx = pi;
            match_idx = ni;
            pi += 1;
        } else if (star_idx) |s| {
            pi = s + 1;
            match_idx += 1;
            ni = match_idx;
        } else {
            return false;
        }
    }
    while (pi < pattern.len and pattern[pi] == '*') pi += 1;
    return pi == pattern.len;
}

fn buildOutput(allocator: std.mem.Allocator, pattern: []const u8, path: []const u8, match_items: []const Match) ![]const u8 {
    var buf = std.array_list.Managed(u8).init(allocator);
    defer buf.deinit();
    jh.putc(&buf, '{') catch return "Error: OOM";
    jh.putString(&buf, "pattern", pattern) catch return "Error: OOM";
    jh.putc(&buf, ',') catch return "Error: OOM";
    jh.putString(&buf, "path", path) catch return "Error: OOM";
    jh.putc(&buf, ',') catch return "Error: OOM";
    jh.putInt(&buf, "count", @as(u64, match_items.len)) catch return "Error: OOM";
    jh.putc(&buf, ',') catch return "Error: OOM";

    jh.puts(&buf, "\"matches\":[") catch return "Error: OOM";
    for (match_items, 0..) |m, i| {
        if (i > 0) jh.putc(&buf, ',') catch return "Error: OOM";
        jh.putc(&buf, '{') catch return "Error: OOM";
        jh.putString(&buf, "file", m.file) catch return "Error: OOM";
        jh.putc(&buf, ',') catch return "Error: OOM";
        jh.putInt(&buf, "line", m.line) catch return "Error: OOM";
        jh.putc(&buf, ',') catch return "Error: OOM";
        jh.putString(&buf, "content", m.content) catch return "Error: OOM";
        jh.putc(&buf, '}') catch return "Error: OOM";
    }
    jh.puts(&buf, "]") catch return "Error: OOM";

    if (match_items.len >= MAX_MATCHES) {
        jh.putc(&buf, ',') catch return "Error: OOM";
        const note = try std.fmt.allocPrint(allocator, "Result truncated at {d} matches. Use more specific pattern.", .{MAX_MATCHES});
        defer allocator.free(note);
        jh.putString(&buf, "note", note) catch return "Error: OOM";
    }
    jh.putc(&buf, '}') catch return "Error: OOM";
    return jh.finish(&buf);
}

fn jhErrorStr(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(allocator, "Error: " ++ fmt, args) catch "Error: OOM";
}

test "grep: finds pattern in file" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const io = testing.io;

    const tmp_path = "zig_test_grep_search.txt";
    {
        var file = try std.Io.Dir.cwd().createFile(io, tmp_path, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, "hello world\nfoo bar\nhello zig");
    }
    defer std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};

    const json = try std.fmt.allocPrint(allocator, "{{\"pattern\": \"hello\", \"path\": \"{s}\"}}", .{tmp_path});
    defer allocator.free(json);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{}) catch return;
    defer parsed.deinit();
    const args = parsed.value;
    const tr = execute(allocator, io, args);
    defer allocator.free(tr.output);

    try testing.expect(tr.success);
    try testing.expect(std.mem.startsWith(u8, tr.output, "{"));
    try testing.expect(std.mem.indexOf(u8, tr.output, "\"count\":2") != null);
    try testing.expect(std.mem.indexOf(u8, tr.output, "hello world") != null);
    try testing.expect(std.mem.indexOf(u8, tr.output, "hello zig") != null);
}

test "grep: missing pattern returns error" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const io = testing.io;

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, "{\"path\": \".\"}", .{}) catch return;
    defer parsed.deinit();
    const args = parsed.value;
    const tr = execute(allocator, io, args);
    try testing.expect(!tr.success);
    try testing.expect(std.mem.startsWith(u8, tr.output, "Error:"));
}

test "grep: missing path returns error" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const io = testing.io;

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, "{\"pattern\": \"test\"}", .{}) catch return;
    defer parsed.deinit();
    const args = parsed.value;
    const tr = execute(allocator, io, args);
    try testing.expect(!tr.success);
    try testing.expect(std.mem.startsWith(u8, tr.output, "Error:"));
}
