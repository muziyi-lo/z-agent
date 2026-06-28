const std = @import("std");
const jh = @import("json.zig");
const trunc = @import("truncate.zig");
const root_dir = @import("root_dir.zig");
const ToolResult = @import("registry.zig").ToolResult;

pub const tool_name = "glob";
pub const tool_description = "Find files matching a glob pattern. Supports *, **, ?. Returns relative file paths.";
pub const tool_params = "{\"type\":\"object\",\"properties\":{\"pattern\":{\"type\":\"string\",\"description\":\"Glob pattern (e.g. 'src/**/*.zig')\"},\"path\":{\"type\":\"string\",\"description\":\"Directory to search in (default: cwd)\"}},\"required\":[\"pattern\"]}";

const MAX_OUTPUT: usize = 50 * 1024;
const MAX_MATCHES: usize = 1000;

pub fn execute(allocator: std.mem.Allocator, io: std.Io, args: std.json.Value) ToolResult {
    const args_obj = args.object;
    const pattern_val = args_obj.get("pattern") orelse return ToolResult.fail("Error: missing 'pattern' argument");
    const pattern = pattern_val.string;
    const base_path = if (args_obj.get("path")) |v| if (v != .null) v.string else "." else ".";
    const resolved = root_dir.resolvePath(allocator, base_path) catch return ToolResult.fail("Error: OOM");
    defer if (resolved.ptr != base_path.ptr) allocator.free(resolved);

    var matches = std.array_list.Managed([]const u8).init(allocator);
    defer {
        for (matches.items) |m| allocator.free(m);
        matches.deinit();
    }

    globWalk(allocator, io, resolved, pattern, &matches) catch |err| {
        return ToolResult.fail(jhErrorStr(allocator, "glob failed: {}", .{err}));
    };

    const output = buildOutput(allocator, pattern, base_path, matches.items) catch return ToolResult.fail("Error: OOM");
    const r = trunc.truncateLines(output, MAX_OUTPUT);
    return ToolResult.ok(r.text);
}

fn globWalk(allocator: std.mem.Allocator, io: std.Io, root: []const u8, pattern: []const u8, matches: *std.array_list.Managed([]const u8)) !void {
    var dir = std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch return;
    defer dir.close(io);

    const segments = try splitPattern(allocator, pattern);
    defer allocator.free(segments);
    try walkSegments(allocator, io, &dir, root, segments, matches);
}

fn splitPattern(allocator: std.mem.Allocator, pattern: []const u8) ![]const []const u8 {
    var list = std.array_list.Managed([]const u8).init(allocator);
    errdefer list.deinit();

    var start: usize = 0;
    var i: usize = 0;
    while (i < pattern.len) : (i += 1) {
        if (pattern[i] == '/' or pattern[i] == '\\') {
            if (i > start) try list.append(pattern[start..i]);
            start = i + 1;
        }
    }
    if (start < pattern.len) try list.append(pattern[start..]);
    return list.toOwnedSlice();
}

fn walkSegments(allocator: std.mem.Allocator, io: std.Io, dir: *std.Io.Dir, prefix: []const u8, segments: []const []const u8, matches: *std.array_list.Managed([]const u8)) anyerror!void {
    if (segments.len == 0) return;

    const seg = segments[0];
    const rest = if (segments.len > 1) segments[1..] else &.{};
    const is_last = rest.len == 0;

    if (std.mem.eql(u8, seg, "**")) {
        try matchDoubleStar(allocator, io, dir, prefix, rest, matches);
        return;
    }

    try matchSingleSegment(allocator, io, dir, prefix, seg, is_last, rest, matches);
}

fn matchDoubleStar(allocator: std.mem.Allocator, io: std.Io, dir: *std.Io.Dir, prefix: []const u8, rest: []const []const u8, matches: *std.array_list.Managed([]const u8)) anyerror!void {
    if (rest.len == 0) {
        try collectAllFiles(allocator, io, dir, prefix, matches);
        return;
    }
    try walkSegments(allocator, io, dir, prefix, rest, matches);

    var iter = dir.iterate();
    while (iter.next(io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) continue;
        const sub_path = if (prefix.len == 0 or std.mem.eql(u8, prefix, "."))
            try allocator.dupe(u8, entry.name)
        else
            try std.fs.path.join(allocator, &.{ prefix, entry.name });
        defer allocator.free(sub_path);
        var sub_dir = try dir.openDir(io, entry.name, .{ .iterate = true });
        defer sub_dir.close(io);
        try matchDoubleStar(allocator, io, &sub_dir, sub_path, rest, matches);
    }
}

fn matchSingleSegment(allocator: std.mem.Allocator, io: std.Io, dir: *std.Io.Dir, prefix: []const u8, seg: []const u8, is_last: bool, rest: []const []const u8, matches: *std.array_list.Managed([]const u8)) anyerror!void {
    var iter = dir.iterate();
    while (iter.next(io) catch null) |entry| {
        if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) continue;

        if (!matchGlob(entry.name, seg)) continue;

        if (is_last) {
            const full = if (prefix.len == 0 or std.mem.eql(u8, prefix, "."))
                try allocator.dupe(u8, entry.name)
            else
                try std.fs.path.join(allocator, &.{ prefix, entry.name });
            try matches.append(full);
            if (matches.items.len >= MAX_MATCHES) return;
        } else {
            if (entry.kind != .directory) continue;
            const sub_prefix = if (prefix.len == 0 or std.mem.eql(u8, prefix, "."))
                try allocator.dupe(u8, entry.name)
            else
                try std.fs.path.join(allocator, &.{ prefix, entry.name });
            defer allocator.free(sub_prefix);
            var sub_dir = try dir.openDir(io, entry.name, .{ .iterate = true });
            defer sub_dir.close(io);
            try walkSegments(allocator, io, &sub_dir, sub_prefix, rest, matches);
        }
    }
}

fn collectAllFiles(allocator: std.mem.Allocator, io: std.Io, dir: *std.Io.Dir, prefix: []const u8, matches: *std.array_list.Managed([]const u8)) anyerror!void {
    var iter = dir.iterate();
    while (iter.next(io) catch null) |entry| {
        if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) continue;
        const full = if (prefix.len == 0 or std.mem.eql(u8, prefix, "."))
            try allocator.dupe(u8, entry.name)
        else
            try std.fs.path.join(allocator, &.{ prefix, entry.name });
        try matches.append(full);
        if (matches.items.len >= MAX_MATCHES) return;
        if (entry.kind == .directory) {
            var sub_dir = try dir.openDir(io, entry.name, .{ .iterate = true });
            defer sub_dir.close(io);
            try collectAllFiles(allocator, io, &sub_dir, full, matches);
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

fn buildOutput(allocator: std.mem.Allocator, pattern: []const u8, base_path: []const u8, matche_items: []const []const u8) ![]const u8 {
    var buf = std.array_list.Managed(u8).init(allocator);
    defer buf.deinit();
    jh.putc(&buf, '{') catch return "Error: OOM";
    jh.putString(&buf, "pattern", pattern) catch return "Error: OOM";
    jh.putc(&buf, ',') catch return "Error: OOM";
    jh.putString(&buf, "path", base_path) catch return "Error: OOM";
    jh.putc(&buf, ',') catch return "Error: OOM";
    jh.putInt(&buf, "count", @as(u64, matche_items.len)) catch return "Error: OOM";
    jh.putc(&buf, ',') catch return "Error: OOM";

    jh.puts(&buf, "\"matches\":[") catch return "Error: OOM";
    for (matche_items, 0..) |m, i| {
        if (i > 0) jh.putc(&buf, ',') catch return "Error: OOM";
        jh.escapeJson(&buf, m) catch return "Error: OOM";
    }
    jh.puts(&buf, "]") catch return "Error: OOM";

    if (matche_items.len >= MAX_MATCHES) {
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

test "glob: matchGlob basic" {
    const testing = std.testing;
    try testing.expect(matchGlob("file.zig", "*.zig"));
    try testing.expect(matchGlob("file.txt", "*.txt"));
    try testing.expect(!matchGlob("file.zig", "*.txt"));
    try testing.expect(matchGlob("hello.zig", "hello*"));
    try testing.expect(matchGlob("hello world.zig", "hello*"));
    try testing.expect(!matchGlob("xhello.zig", "hello*"));
    try testing.expect(matchGlob("a.zig", "?.zig"));
    try testing.expect(!matchGlob("ab.zig", "?.zig"));
    try testing.expect(matchGlob("ab.zig", "*.zig"));
}

test "glob: returns matches for existing files" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const io = testing.io;

    const json = "{\"pattern\": \"glob.zig\", \"path\": \"src/tool\"}";
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{}) catch return;
    defer parsed.deinit();
    const args = parsed.value;
    const tr = execute(allocator, io, args);
    defer allocator.free(tr.output);

    try testing.expect(tr.success);
    try testing.expect(std.mem.startsWith(u8, tr.output, "{"));
    try testing.expect(std.mem.indexOf(u8, tr.output, "\"count\":1") != null);
    try testing.expect(std.mem.indexOf(u8, tr.output, "glob.zig") != null);
}

test "glob: no matches returns zero count" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const io = testing.io;

    const json = "{\"pattern\": \"nonexistent_xyz_123.txt\", \"path\": \".\"}";
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{}) catch return;
    defer parsed.deinit();
    const args = parsed.value;
    const tr = execute(allocator, io, args);
    defer allocator.free(tr.output);

    try testing.expect(tr.success);
    try testing.expect(std.mem.indexOf(u8, tr.output, "\"count\":0") != null);
}

test "glob: missing pattern returns error" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const io = testing.io;

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, "{}", .{}) catch return;
    defer parsed.deinit();
    const args = parsed.value;
    const tr = execute(allocator, io, args);
    try testing.expect(!tr.success);
    try testing.expect(std.mem.startsWith(u8, tr.output, "Error:"));
}
