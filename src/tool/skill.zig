const std = @import("std");
const config_mod = @import("../config.zig");
const root_dir = @import("root_dir.zig");
const ToolResult = @import("registry.zig").ToolResult;

pub const tool_name = "skill";
pub const tool_description = "Load a skill's full instructions. Use skill({\"name\": \"<skill-name>\"}) to get detailed instructions for a specific task. Skills are loaded from .opencode/skills/<name>/SKILL.md.";
pub const tool_params = "{\"type\":\"object\",\"properties\":{\"name\":{\"type\":\"string\",\"description\":\"Name of the skill to load (as listed in <available_skills>)\"}},\"required\":[\"name\"]}";

pub fn execute(allocator: std.mem.Allocator, io: std.Io, args: std.json.Value) ToolResult {
    const args_obj = args.object;
    const name_val = args_obj.get("name") orelse return ToolResult.fail(std.fmt.allocPrint(allocator, "Error: missing 'name' argument, use skill({s})", .{"{\"name\": \"<skill-name>\"}"}) catch "Error: OOM");
    const name = name_val.string;

    const using_fallback_root = root_dir.project_root.len == 0;
    const zagent_root = if (!using_fallback_root) root_dir.project_root else
        (config_mod.findZagentRoot(allocator, io) orelse return ToolResult.fail(std.fmt.allocPrint(allocator, "Error: cannot find .zagent directory", .{}) catch "Error: OOM"));
    defer if (using_fallback_root) allocator.free(zagent_root);

    const path = std.fs.path.join(allocator, &.{ zagent_root, ".zagent", "skills", name, "SKILL.md" }) catch return ToolResult.fail("Error: OOM");
    defer allocator.free(path);

    const file = std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only }) catch |err| {
        return ToolResult.fail(std.fmt.allocPrint(allocator, "Error: skill '{s}' not found at {s}: {}", .{ name, path, err }) catch "Error: OOM");
    };
    defer file.close(io);

    const stat = file.stat(io) catch return ToolResult.fail("Error: cannot stat skill file");
    const size: usize = @intCast(stat.size);
    const raw = allocator.alloc(u8, size) catch return ToolResult.fail("Error: OOM");
    defer allocator.free(raw);
    _ = file.readPositionalAll(io, raw, 0) catch return ToolResult.fail("Error: cannot read skill file");

    var buf = std.array_list.Managed(u8).init(allocator);
    defer buf.deinit();

    buf.appendSlice("{\"name\":\"") catch return ToolResult.fail("Error: OOM");
    escapeSkillString(&buf, name) catch return ToolResult.fail("Error: OOM");
    buf.appendSlice("\",\"content\":\"") catch return ToolResult.fail("Error: OOM");
    escapeSkillString(&buf, raw) catch return ToolResult.fail("Error: OOM");
    buf.appendSlice("\"}") catch return ToolResult.fail("Error: OOM");

    return ToolResult.ok(buf.toOwnedSlice() catch "Error: OOM");
}

pub fn renderResult(allocator: std.mem.Allocator, stdout: *std.Io.Writer, json_str: []const u8) !void {
    if (!std.mem.startsWith(u8, json_str, "{")) return stdout.print("  → {s}\n", .{json_str});
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, allocator, json_str, .{}) catch {
        return stdout.print("  → {s}\n", .{json_str});
    };
    const obj = parsed.object;
    const name = if (obj.get("name")) |v| if (v == .string) v.string else "" else "";
    const content = if (obj.get("content")) |v| if (v == .string) v.string else "" else "";
    if (name.len > 0) try stdout.print("  [{s}]\n", .{name});
    if (content.len > 0) {
        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |ln| {
            const trimmed = std.mem.trimEnd(u8, ln, "\r");
            try stdout.print("  | {s}\n", .{trimmed});
        }
    }
}

fn escapeSkillString(buf: *std.array_list.Managed(u8), s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice("\\\""),
            '\\' => try buf.appendSlice("\\\\"),
            '\n' => try buf.appendSlice("\\n"),
            '\r' => try buf.appendSlice("\\r"),
            '\t' => try buf.appendSlice("\\t"),
            0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f => {
                var hex_buf: [6]u8 = undefined;
                const hex = try std.fmt.bufPrint(&hex_buf, "\\u00{x:0>2}", .{@as(u8, c)});
                try buf.appendSlice(hex);
            },
            else => try buf.append(c),
        }
    }
}

test "skill execute: missing name returns error" {
    const testing = std.testing;
    const io = testing.io;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{}", .{});
    defer parsed.deinit();
    const tr = execute(testing.allocator, io, parsed.value);
    defer testing.allocator.free(tr.output);
    try testing.expect(!tr.success);
    try testing.expect(std.mem.startsWith(u8, tr.output, "Error:"));
}

test "skill execute: unknown skill returns error" {
    const testing = std.testing;
    const io = testing.io;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{\"name\": \"nonexistent-skill-xyz\"}", .{});
    defer parsed.deinit();
    const tr = execute(testing.allocator, io, parsed.value);
    defer testing.allocator.free(tr.output);
    try testing.expect(!tr.success);
    try testing.expect(std.mem.startsWith(u8, tr.output, "Error:"));
}

test "skill execute: escapeSkillString escapes special chars" {
    const testing = std.testing;
    var buf = std.array_list.Managed(u8).init(testing.allocator);
    defer buf.deinit();

    try escapeSkillString(&buf, "hello\nworld");
    try testing.expect(std.mem.indexOf(u8, buf.items, "\\n") != null);
}
