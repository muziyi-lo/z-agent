const std = @import("std");
const ToolResult = @import("registry.zig").ToolResult;
const crud = @import("memory/crud.zig");
const archive_mod = @import("memory/archive.zig");
const designer = @import("memory/designer.zig");
const skill_bank = @import("memory/skill_bank.zig");

pub const tool_name = "memory";
pub const tool_description = "Manage memory entries, designer pipeline, and skill bank. Commands: add, recall, delete, archive, promote, stat, designer, skill-bank.";
pub const tool_params = "{\"type\":\"object\",\"properties\":{\"command\":{\"type\":\"string\",\"description\":\"Action: add, recall, delete, archive, promote, stat, designer, or skill-bank\"},\"subcommand\":{\"type\":\"string\",\"description\":\"Designer subcommand: collect, propose, list, review, approve, apply, rollback, verify, report; skill-bank subcommand: list, update\"},\"content\":{\"type\":\"string\",\"description\":\"Content to remember (for add)\"},\"source\":{\"type\":\"string\",\"description\":\"Source label: 用户 or 自动 (for add, default: 自动)\"},\"pattern-key\":{\"type\":\"string\",\"description\":\"Unique key for dedup (for add, recommended)\"},\"title\":{\"type\":\"string\",\"description\":\"Override title (for add, auto-extracted from content)\"},\"query\":{\"type\":\"string\",\"description\":\"Search keyword (for recall)\"},\"id\":{\"type\":\"string\",\"description\":\"Entry ID like MEM-20260628-001 or changeset ID like CS-20260702-001 (for delete/archive/promote/designer)\"},\"priority\":{\"type\":\"string\",\"description\":\"New priority: low, medium, high, critical (for promote)\"},\"older-than\":{\"type\":\"integer\",\"description\":\"Archive entries older than N days (for archive)\"},\"all\":{\"type\":\"boolean\",\"description\":\"Archive all non-archived entries (for archive)\"},\"limit\":{\"type\":\"integer\",\"description\":\"Max items to collect (for designer collect)\"},\"status\":{\"type\":\"string\",\"description\":\"Filter by status: draft, proposed, approved, applied, rejected, rolled_back (for designer list)\"},\"force\":{\"type\":\"boolean\",\"description\":\"Skip snapshot consistency check (for designer apply)\"},\"slug\":{\"type\":\"string\",\"description\":\"Skill slug (for skill-bank update)\"},\"change\":{\"type\":\"string\",\"description\":\"Change description (for skill-bank update)\"}},\"required\":[\"command\",\"content\"]}";

/// Execute memory tool commands by routing to submodules.
pub fn execute(allocator: std.mem.Allocator, io: std.Io, args: std.json.Value) ToolResult {
    if (args != .object) return ToolResult.fail(allocError(allocator, "args must be an object"));
    const args_obj = args.object;
    const command_val = args_obj.get("command") orelse return ToolResult.fail(allocError(allocator, "missing 'command'"));
    const command = if (command_val == .string) command_val.string else return ToolResult.fail(allocError(allocator, "'command' must be a string"));

    if (std.mem.eql(u8, command, "add")) {
        const output = crud.cmdAdd(allocator, io, args_obj);
        if (std.mem.startsWith(u8, output, "Error:")) return ToolResult.fail(output);
        return ToolResult.ok(output);
    } else if (std.mem.eql(u8, command, "recall")) {
        const output = crud.cmdRecall(allocator, io, args_obj);
        if (std.mem.startsWith(u8, output, "Error:")) return ToolResult.fail(output);
        return ToolResult.ok(output);
    } else if (std.mem.eql(u8, command, "delete")) {
        const output = crud.cmdDelete(allocator, io, args_obj);
        if (std.mem.startsWith(u8, output, "Error:")) return ToolResult.fail(output);
        return ToolResult.ok(output);
    } else if (std.mem.eql(u8, command, "archive")) {
        const output = archive_mod.cmdArchive(allocator, io, args_obj);
        if (std.mem.startsWith(u8, output, "Error:")) return ToolResult.fail(output);
        return ToolResult.ok(output);
    } else if (std.mem.eql(u8, command, "promote")) {
        const output = archive_mod.cmdPromote(allocator, io, args_obj);
        if (std.mem.startsWith(u8, output, "Error:")) return ToolResult.fail(output);
        return ToolResult.ok(output);
    } else if (std.mem.eql(u8, command, "stat")) {
        const output = archive_mod.cmdStat(allocator, io, args_obj);
        if (std.mem.startsWith(u8, output, "Error:")) return ToolResult.fail(output);
        return ToolResult.ok(output);
    } else if (std.mem.eql(u8, command, "designer")) {
        const output = designer.cmdDesigner(allocator, io, args_obj);
        if (std.mem.startsWith(u8, output, "Error:")) return ToolResult.fail(output);
        return ToolResult.ok(output);
    } else if (std.mem.eql(u8, command, "skill-bank")) {
        const output = skill_bank.cmdSkillBank(allocator, io, args_obj);
        if (std.mem.startsWith(u8, output, "Error:")) return ToolResult.fail(output);
        return ToolResult.ok(output);
    } else {
        return ToolResult.fail(std.fmt.allocPrint(allocator, "Error: unknown command '{s}'", .{command}) catch allocOomError(allocator));
    }
}

fn allocError(allocator: std.mem.Allocator, msg: []const u8) []const u8 {
    return std.fmt.allocPrint(allocator, "Error: {s}", .{msg}) catch allocOomError(allocator);
}

fn allocOomError(allocator: std.mem.Allocator) []const u8 {
    return std.fmt.allocPrint(allocator, "Error: OOM", .{}) catch "Error: OOM";
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "memory: missing command returns error" {
    const testing = std.testing;
    const a = testing.allocator;
    const io = testing.io;

    var parsed = try std.json.parseFromSlice(std.json.Value, a, "{}", .{});
    defer parsed.deinit();

    const tr = execute(a, io, parsed.value);
    defer a.free(tr.output);
    try testing.expect(!tr.success);
    try testing.expect(std.mem.startsWith(u8, tr.output, "Error:"));
    try testing.expect(std.mem.indexOf(u8, tr.output, "command") != null);
}

test "memory: unknown command returns error" {
    const testing = std.testing;
    const a = testing.allocator;
    const io = testing.io;

    var parsed = try std.json.parseFromSlice(std.json.Value, a, "{\"command\":\"nonexistent\"}", .{});
    defer parsed.deinit();

    const tr = execute(a, io, parsed.value);
    defer a.free(tr.output);
    try testing.expect(!tr.success);
    try testing.expect(std.mem.startsWith(u8, tr.output, "Error:"));
    try testing.expect(std.mem.indexOf(u8, tr.output, "unknown") != null);
}
