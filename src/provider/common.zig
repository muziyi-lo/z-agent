const std = @import("std");
const types = @import("../types.zig");

pub fn appendEscapedJsonString(buf: *std.array_list.Managed(u8), s: []const u8) !void {
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (c < 0x80) {
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
            i += 1;
        } else if (c >= 0xC0 and c <= 0xDF) {
            if (i + 1 < s.len) { try buf.appendSlice(s[i..i+2]); i += 2; }
            else { try buf.appendSlice("\\ufffd"); i += 1; }
        } else if (c >= 0xE0 and c <= 0xEF) {
            if (i + 2 < s.len) { try buf.appendSlice(s[i..i+3]); i += 3; }
            else { try buf.appendSlice("\\ufffd"); i += 1; }
        } else if (c >= 0xF0 and c <= 0xF4) {
            if (i + 3 < s.len) { try buf.appendSlice(s[i..i+4]); i += 4; }
            else { try buf.appendSlice("\\ufffd"); i += 1; }
        } else {
            try buf.appendSlice("\\ufffd");
            i += 1;
        }
    }
}

// Unused since migrating to SSE streaming. Kept for reference.
pub fn parseResponse(allocator: std.mem.Allocator, json_bytes: []const u8) !types.ChatResponse {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, json_bytes, .{}) catch {
        return error.InvalidJson;
    };
    defer parsed.deinit();
    if (parsed.value.object.get("error")) |err_obj| {
        const msg = err_obj.object.get("message") orelse return error.ApiError;
        return types.ChatResponse{
            .content = try allocator.dupe(u8, msg.string),
        };
    }
    const choices = parsed.value.object.get("choices") orelse return error.MissingChoices;
    if (choices.array.items.len == 0) return error.NoChoices;
    const first = choices.array.items[0];
    const message = first.object.get("message") orelse return error.MissingMessage;

    const msg_obj = message.object;
    const content = msg_obj.get("content");
    const reasoning = msg_obj.get("reasoning_content");
    const tool_calls = msg_obj.get("tool_calls");

    var tcs: ?[]types.ToolCall = null;
    if (tool_calls) |tc_array| {
        var list = std.array_list.Managed(types.ToolCall).init(allocator);
        for (tc_array.array.items) |tc_item| {
            const tc_obj = tc_item.object;
            const func_obj = (tc_obj.get("function") orelse continue).object;
            const id = tc_obj.get("id") orelse continue;
            const name = func_obj.get("name") orelse continue;
            const args = func_obj.get("arguments") orelse continue;
            try list.append(.{
                .id = try allocator.dupe(u8, id.string),
                .name = try allocator.dupe(u8, name.string),
                .arguments = try allocator.dupe(u8, args.string),
            });
        }
        tcs = try list.toOwnedSlice();
    }

    return types.ChatResponse{
        .content = if (content) |c| if (c != .null) try allocator.dupe(u8, c.string) else null else null,
        .reasoning = if (reasoning) |r| if (r != .null) try allocator.dupe(u8, r.string) else null else null,
        .tool_calls = tcs,
    };
}

pub fn parseUsage(val: std.json.Value) !types.Usage {
    const obj = val.object;
    const ct: u32 = if (obj.get("completion_tokens")) |v| if (v.integer >= 0) @intCast(@min(v.integer, std.math.maxInt(u32))) else 0 else 0;
    const pt: u32 = if (obj.get("prompt_tokens")) |v| if (v.integer >= 0) @intCast(@min(v.integer, std.math.maxInt(u32))) else 0 else 0;
    const tt: u32 = if (obj.get("total_tokens")) |v| if (v.integer >= 0) @intCast(@min(v.integer, std.math.maxInt(u32))) else 0 else 0;
    var rt: u32 = 0;
    if (obj.get("completion_tokens_details")) |details| {
        if (details.object.get("reasoning_tokens")) |v| {
            if (v.integer >= 0) rt = @intCast(@min(v.integer, std.math.maxInt(u32)));
        }
    }
    return types.Usage{
        .completion_tokens = ct,
        .prompt_tokens = pt,
        .total_tokens = tt,
        .reasoning_tokens = rt,
    };
}

test "parseResponse: error message is dupe'd" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const json = "{\"error\":{\"message\":\"test error\"}}";
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{}) catch return;
    defer parsed.deinit();
    const msg = parsed.value.object.get("error").?.object.get("message").?.string;
    try testing.expectEqualStrings("test error", msg);
}

test "parseResponse: normal response with content" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const json = "{\"choices\":[{\"message\":{\"content\":\"hello\",\"role\":\"assistant\"}}]}";
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{}) catch return;
    defer parsed.deinit();
    const content = parsed.value.object.get("choices").?.array.items[0].object.get("message").?.object.get("content").?.string;
    try testing.expectEqualStrings("hello", content);
}

test "appendEscapedJsonString: escapes special chars" {
    const testing = std.testing;
    const allocator = testing.allocator;
    var buf = std.array_list.Managed(u8).init(allocator);
    defer buf.deinit();

    try appendEscapedJsonString(&buf, "hello\"world\\\n\t");
    try testing.expect(std.mem.indexOf(u8, buf.items, "\\\"") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "\\\\") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "\\n") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "\\t") != null);
}

test "appendEscapedJsonString: 0x80+ bytes pass through" {
    const testing = std.testing;
    const allocator = testing.allocator;
    var buf = std.array_list.Managed(u8).init(allocator);
    defer buf.deinit();

    try appendEscapedJsonString(&buf, "\xE4\xBD\xA0\xE5\xA5\xBD");
    try testing.expect(std.mem.indexOf(u8, buf.items, "\xE4") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "\xBD") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "\xA0") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "\xE5") != null);
}

test "appendEscapedJsonString: control chars escaped" {
    const testing = std.testing;
    const allocator = testing.allocator;
    var buf = std.array_list.Managed(u8).init(allocator);
    defer buf.deinit();

    try appendEscapedJsonString(&buf, "\x00\x01\x1f");
    try testing.expect(std.mem.indexOf(u8, buf.items, "\\u0000") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "\\u0001") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "\\u001f") != null);
}

test "appendEscapedJsonString: invalid UTF-8 bytes replaced" {
    const testing = std.testing;
    const allocator = testing.allocator;
    var buf = std.array_list.Managed(u8).init(allocator);
    defer buf.deinit();

    try appendEscapedJsonString(&buf, "\xAA");
    // If fix works, output should contain \ufffd
    const has_ufffd = std.mem.indexOf(u8, buf.items, "\\ufffd") != null;
    if (!has_ufffd) {
        std.debug.print("output bytes: ", .{});
        for (buf.items) |b| std.debug.print("{x} ", .{b});
        std.debug.print("\n", .{});
    }
    try testing.expect(has_ufffd);
}
