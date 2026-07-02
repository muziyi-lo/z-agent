const std = @import("std");
const json = @import("../json.zig");
const root_dir = @import("../root_dir.zig");
const crud = @import("crud.zig");
const parse = @import("parse.zig");
const session = @import("session.zig");
const trunc = @import("../truncate.zig");

const Io = std.Io;

// ---------------------------------------------------------------------------
// checkInterrupt
// ---------------------------------------------------------------------------

/// Check interrupt_flag by examining the message buffer. If >= 3 messages,
/// combine last 3, extract a title, and record as a memory entry with
/// pattern-key "interrupt-<date>". Source is "自动".
pub fn checkInterrupt(allocator: std.mem.Allocator, io: Io, msg_buffer: []const []const u8) void {
    if (msg_buffer.len < 3) return;

    // Take last 3 messages
    const count = @min(msg_buffer.len, @as(usize, 3));
    var combined = std.array_list.Managed(u8).init(allocator);
    defer combined.deinit();
    for (msg_buffer[msg_buffer.len - count ..]) |msg| {
        combined.appendSlice(msg) catch return;
        combined.appendSlice("\n---\n") catch return;
    }

    // Extract title from combined text
    const end = std.mem.indexOfAny(u8, combined.items, "\n。") orelse combined.items.len;
    const limited = trunc.truncateUtf8(combined.items[0..end], 60);
    const title = std.mem.trim(u8, limited.text, " \r\n\t");

    // pattern-key = "interrupt-" + todayDateString
    const date_buf = parse.todayDateString(io);

    // Build JSON args string for crud.cmdAdd
    var buf = std.array_list.Managed(u8).init(allocator);
    defer buf.deinit();

    json.puts(&buf, "{\"content\":") catch return;
    json.escapeJson(&buf, combined.items) catch return;
    json.puts(&buf, ",\"source\":\"自动\"") catch return;
    json.puts(&buf, ",\"pattern-key\":\"interrupt-") catch return;
    json.puts(&buf, &date_buf) catch return;
    json.puts(&buf, "\"") catch return;
    if (title.len > 0) {
        json.puts(&buf, ",\"title\":") catch return;
        json.escapeJson(&buf, title) catch return;
    }
    json.puts(&buf, "}") catch return;
    const json_str = json.finish(&buf);
    defer allocator.free(json_str);

    // Parse and call crud.cmdAdd
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, json_str, .{}) catch return;
    defer parsed.deinit();
    if (parsed.value != .object) return;
    const result = crud.cmdAdd(allocator, io, parsed.value.object);
    allocator.free(result);
}

// ---------------------------------------------------------------------------
// recordBashFailure
// ---------------------------------------------------------------------------

/// Automatically record a bash failure. Uses first 8 chars of command as
/// pattern-key prefix with "-fail" suffix. Source is "自动".
pub fn recordBashFailure(allocator: std.mem.Allocator, io: Io, command: []const u8, stderr: []const u8) void {
    // pattern-key = first 8 chars of command + "-fail"
    const prefix_len = @min(command.len, @as(usize, 8));
    const key_prefix = command[0..prefix_len];

    // Build content = command [+ "\n" + stderr]
    var content_buf = std.array_list.Managed(u8).init(allocator);
    defer content_buf.deinit();
    content_buf.appendSlice(command) catch return;
    if (stderr.len > 0) {
        content_buf.appendSlice("\n") catch return;
        content_buf.appendSlice(stderr) catch return;
    }

    // Build JSON args string for crud.cmdAdd
    var buf = std.array_list.Managed(u8).init(allocator);
    defer buf.deinit();

    json.puts(&buf, "{\"content\":") catch return;
    json.escapeJson(&buf, content_buf.items) catch return;
    json.puts(&buf, ",\"source\":\"自动\"") catch return;
    json.puts(&buf, ",\"pattern-key\":\"") catch return;
    json.puts(&buf, key_prefix) catch return;
    json.puts(&buf, "-fail\"") catch return;
    json.puts(&buf, "}") catch return;
    const json_str = json.finish(&buf);
    defer allocator.free(json_str);

    // Parse and call crud.cmdAdd
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, json_str, .{}) catch return;
    defer parsed.deinit();
    if (parsed.value != .object) return;
    const result = crud.cmdAdd(allocator, io, parsed.value.object);
    allocator.free(result);
}
