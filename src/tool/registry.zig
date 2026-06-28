const std = @import("std");
const types = @import("../types.zig");
const trunc = @import("truncate.zig");

const MAX_OUTPUT_BYTES: usize = 100 * 1024;

pub const ToolResult = struct {
    success: bool,
    output: []const u8,

    pub fn ok(output: []const u8) ToolResult {
        return .{ .success = true, .output = output };
    }

    pub fn fail(err: []const u8) ToolResult {
        return .{ .success = false, .output = err };
    }
};

pub const Handler = struct {
    name: []const u8,
    description: []const u8,
    parameters: []const u8,
    execute: *const fn (allocator: std.mem.Allocator, io: std.Io, args: std.json.Value) ToolResult,
    renderResult: ?*const fn (allocator: std.mem.Allocator, stdout: *std.Io.Writer, json_str: []const u8) anyerror!void = null,
};

pub const Registry = struct {
    handlers: []const Handler,

    pub fn execute(self: Registry, allocator: std.mem.Allocator, io: std.Io, tc: types.ToolCall) ToolResult {
        for (self.handlers) |h| {
            if (std.mem.eql(u8, h.name, tc.name)) {
                const args = std.json.parseFromSliceLeaky(std.json.Value, allocator, tc.arguments, .{}) catch |err| {
                    return ToolResult.fail(std.fmt.allocPrint(allocator, "Error: invalid arguments JSON: {}", .{err}) catch "Error: OOM");
                };
                const tr = h.execute(allocator, io, args);
                const r = trunc.truncateBytes(tr.output, MAX_OUTPUT_BYTES);
                if (!r.truncated) return tr;
                const dup = allocator.dupe(u8, r.text) catch return ToolResult.fail("Error: OOM");
                allocator.free(tr.output);
                return ToolResult{ .success = tr.success, .output = dup };
            }
        }
        return ToolResult.fail(std.fmt.allocPrint(allocator, "Error: unknown tool '{s}'", .{tc.name}) catch "Error: OOM");
    }

    pub fn toTools(self: Registry, allocator: std.mem.Allocator) ![]types.Tool {
        const tools = try allocator.alloc(types.Tool, self.handlers.len);
        for (self.handlers, 0..) |h, i| {
            tools[i] = types.Tool{
                .name = try allocator.dupe(u8, h.name),
                .description = try allocator.dupe(u8, h.description),
                .parameters = try allocator.dupe(u8, h.parameters),
            };
        }
        return tools;
    }

    pub fn findHandler(self: Registry, name: []const u8) ?Handler {
        for (self.handlers) |h| {
            if (std.mem.eql(u8, h.name, name)) return h;
        }
        return null;
    }
};

pub fn buildHandler(comptime tool: type) Handler {
    return .{
        .name = tool.tool_name,
        .description = tool.tool_description,
        .parameters = tool.tool_params,
        .execute = tool.execute,
        .renderResult = if (@hasDecl(tool, "renderResult")) tool.renderResult else null,
    };
}

test "Registry: dispatch to handler by name" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const handler = Handler{
        .name = "ping",
        .description = "test tool",
        .parameters = "{}",
        .execute = struct {
            fn exec(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value) ToolResult {
                _ = io;
                _ = args;
                return ToolResult.ok(std.fmt.allocPrint(alloc, "pong", .{}) catch "OOM");
            }
        }.exec,
    };

    const reg = Registry{ .handlers = &.{handler} };
    const result = reg.execute(allocator, undefined, types.ToolCall{
        .id = "call_1",
        .name = "ping",
        .arguments = "{}",
    });
    defer allocator.free(result.output);

    try testing.expect(result.success);
    try testing.expectEqualStrings("pong", result.output);
}

test "Registry: unknown tool returns error" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const reg = Registry{ .handlers = &.{} };
    const result = reg.execute(allocator, undefined, types.ToolCall{
        .id = "call_1",
        .name = "nonexistent",
        .arguments = "{}",
    });
    defer allocator.free(result.output);

    try testing.expect(!result.success);
    try testing.expect(result.output.len > 0);
    try testing.expect(std.mem.startsWith(u8, result.output, "Error:"));
}

test "Registry: toTools generates correct array" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const handler = Handler{
        .name = "test_tool",
        .description = "a test",
        .parameters = "{\"type\":\"object\"}",
        .execute = struct {
            fn exec(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value) ToolResult {
                _ = alloc;
                _ = io;
                _ = args;
                return ToolResult.ok("");
            }
        }.exec,
    };

    const reg = Registry{ .handlers = &.{handler} };
    const tools = try reg.toTools(allocator);

    try testing.expectEqual(@as(usize, 1), tools.len);
    try testing.expectEqualStrings("test_tool", tools[0].name);
    try testing.expectEqualStrings("a test", tools[0].description);

    allocator.free(tools[0].name);
    allocator.free(tools[0].description);
    allocator.free(tools[0].parameters);
    allocator.free(tools);
}
