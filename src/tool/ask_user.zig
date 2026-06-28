const std = @import("std");
const jh = @import("json.zig");
const ToolResult = @import("registry.zig").ToolResult;

pub const tool_name = "ask_user";
pub const tool_description = "Ask the user a question and get their answer. Use when you need clarification, confirmation, or additional information to continue.";
pub const tool_params = "{\"type\":\"object\",\"properties\":{\"question\":{\"type\":\"string\",\"description\":\"Question to ask the user\"}},\"required\":[\"question\"]}";

pub fn execute(allocator: std.mem.Allocator, io: std.Io, args: std.json.Value) ToolResult {
    const args_obj = args.object;
    const question = args_obj.get("question") orelse return ToolResult.fail("Error: missing 'question' argument");

    var buf = std.array_list.Managed(u8).init(allocator);
    defer buf.deinit();
    jh.putc(&buf, '{') catch return ToolResult.fail("Error: OOM");
    jh.putString(&buf, "question", question.string) catch return ToolResult.fail("Error: OOM");
    jh.putc(&buf, ',') catch return ToolResult.fail("Error: OOM");

    const stdin_file = std.Io.File.stdin();
    var read_buf: [4096]u8 = undefined;

    {
        var out_buf: [256]u8 = undefined;
        var stdout_writer: std.Io.File.Writer = .init(.stdout(), io, &out_buf);
        stdout_writer.interface.writeAll(">>> ") catch {};
        stdout_writer.interface.flush() catch {};
    }

    var total: usize = 0;
    var done = false;
    while (total < read_buf.len) {
        const n = stdin_file.readStreaming(io, &.{read_buf[total..]}) catch break;
        if (n == 0) break;
        total += n;
        for (read_buf[total - n .. total]) |c| {
            if (c == '\n') {
                done = true;
                break;
            }
        }
        if (done) break;
    }
    const answer_raw = read_buf[0..total];
    const answer = std.mem.trim(u8, answer_raw, "\r\n");

    jh.putString(&buf, "answer", answer) catch return ToolResult.fail("Error: OOM");
    jh.putc(&buf, '}') catch return ToolResult.fail("Error: OOM");
    return ToolResult.ok(jh.finish(&buf));
}

test "ask_user: missing question returns error" {
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
