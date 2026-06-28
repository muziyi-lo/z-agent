const std = @import("std");
const jh = @import("json.zig");
const retrieval = @import("../retrieval.zig");
const config_mod = @import("../config.zig");
const root_dir = @import("root_dir.zig");
const ToolResult = @import("registry.zig").ToolResult;

pub fn execute(allocator: std.mem.Allocator, io: std.Io, args: std.json.Value) ToolResult {
    const args_obj = args.object;
    const query_val = args_obj.get("query") orelse return ToolResult.fail("Error: missing 'query' argument");

    const using_fallback_root = root_dir.project_root.len == 0;
    const zagent_root = if (!using_fallback_root) root_dir.project_root else
        (config_mod.findZagentRoot(allocator, io) orelse return ToolResult.fail("Error: cannot find .zagent directory"));
    defer if (using_fallback_root) allocator.free(zagent_root);

    const session_dir = std.fs.path.join(allocator, &.{ zagent_root, ".zagent", "sessions" }) catch return ToolResult.fail("Error: OOM");
    defer allocator.free(session_dir);

    var dir = std.Io.Dir.cwd().openDir(io, session_dir, .{ .iterate = true }) catch {
        return ToolResult.fail(jsonErrorStr(allocator, "no sessions found", .{}));
    };
    defer dir.close(io);

    var docs = std.array_list.Managed(retrieval.Document).init(allocator);
    defer docs.deinit();

    var content_buf = std.array_list.Managed(u8).init(allocator);
    defer content_buf.deinit();

    var iter = dir.iterate();
    while (true) {
        const entry = iter.next(io) catch break orelse break;
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".jsonl")) continue;

        const full_path = std.fs.path.join(allocator, &.{ session_dir, entry.name }) catch continue;
        defer allocator.free(full_path);

        const file = std.Io.Dir.cwd().openFile(io, full_path, .{ .mode = .read_only }) catch continue;
        defer file.close(io);

        const stat = file.stat(io) catch continue;
        const size: usize = @intCast(stat.size);
        if (size == 0 or size > 5 * 1024 * 1024) continue;

        content_buf.clearRetainingCapacity();
        content_buf.ensureTotalCapacity(size) catch continue;
        _ = file.readStreaming(io, &.{content_buf.unusedCapacitySlice()[0..size]}) catch continue;
        content_buf.items.len = size;

        // Parse JSONL lines, extract text content from messages
        var lines = std.mem.splitScalar(u8, content_buf.items, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \r");
            if (trimmed.len == 0) continue;
            if (std.json.parseFromSliceLeaky(std.json.Value, allocator, trimmed, .{})) |parsed| {
                const obj = parsed.object;
                if (obj.get("role")) |role_val| {
                    const role = role_val.string;
                    const content = if (obj.get("content")) |c| blk: {
                        if (c == .string) break :blk c.string;
                        break :blk "";
                    } else "";
                    if (content.len > 0) {
                        const doc_id = std.fmt.allocPrint(allocator, "{s}:{s}", .{ entry.name, role }) catch continue;
                        docs.append(.{ .id = doc_id, .content = content }) catch continue;
                    }
                }
            } else |_| {}
        }
    }

    if (docs.items.len == 0) return ToolResult.fail(jsonErrorStr(allocator, "no searchable content in sessions", .{}));

    const results = retrieval.search(allocator, query_val.string, docs.items, 10) catch {
        return ToolResult.fail(jsonErrorStr(allocator, "search failed", .{}));
    };
    defer {
        for (results) |r| allocator.free(r.snippet);
        allocator.free(results);
    }

    var buf = std.array_list.Managed(u8).init(allocator);
    defer buf.deinit();
    jh.putc(&buf, '[') catch return ToolResult.fail("Error: OOM");
    for (results, 0..) |r, i| {
        if (i > 0) jh.putc(&buf, ',') catch return ToolResult.fail("Error: OOM");
        jh.putc(&buf, '{') catch return ToolResult.fail("Error: OOM");
        jh.putString(&buf, "file", r.id) catch return ToolResult.fail("Error: OOM");
        jh.putc(&buf, ',') catch return ToolResult.fail("Error: OOM");
        {
            var num_buf: [32]u8 = undefined;
            const score_str = std.fmt.bufPrint(&num_buf, "{d:.2}", .{r.score}) catch "0.00";
            jh.putString(&buf, "score", score_str) catch return ToolResult.fail("Error: OOM");
        }
        jh.putc(&buf, ',') catch return ToolResult.fail("Error: OOM");
        jh.putString(&buf, "snippet", r.snippet) catch return ToolResult.fail("Error: OOM");
        jh.putc(&buf, '}') catch return ToolResult.fail("Error: OOM");
    }
    jh.putc(&buf, ']') catch return ToolResult.fail("Error: OOM");
    return ToolResult.ok(jh.finish(&buf));
}

fn jsonErrorStr(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(allocator, "Error: " ++ fmt, args) catch "Error: OOM";
}

test "search: missing query returns error" {
    const testing = std.testing;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{}", .{});
    defer parsed.deinit();
    const tr = execute(testing.allocator, testing.io, parsed.value);
    try testing.expect(!tr.success);
    try testing.expect(std.mem.startsWith(u8, tr.output, "Error:"));
}
