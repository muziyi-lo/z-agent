const std = @import("std");
const jh = @import("json.zig");
const trunc = @import("truncate.zig");
const root_dir = @import("root_dir.zig");
const ToolResult = @import("registry.zig").ToolResult;

pub const tool_name = "read_file";
pub const tool_description = "Read a file from the filesystem. For text files, returns content with optional offset/limit. For images (png/jpg/gif/webp/bmp), automatically encodes as base64 data URI for vision-capable models.";
pub const tool_params = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\",\"description\":\"Path to the file\"},\"offset\":{\"type\":\"number\",\"description\":\"Starting line (1-indexed), optional\"},\"limit\":{\"type\":\"number\",\"description\":\"Max lines to return, optional\"}},\"required\":[\"path\"]}";

const MAX_BYTES: usize = 50 * 1024;
const MAX_IMAGE_BYTES: usize = 20 * 1024 * 1024;

pub fn execute(allocator: std.mem.Allocator, io: std.Io, args: std.json.Value) ToolResult {
    const args_obj = args.object;
    const path = args_obj.get("path") orelse return ToolResult.fail("Error: missing 'path' argument");
    const offset = if (args_obj.get("offset")) |v|
        if (v != .null and v.integer >= 0) @as(usize, @intCast(v.integer)) else 0
    else
        0;
    const limit = if (args_obj.get("limit")) |v|
        if (v != .null and v.integer >= 0) @as(usize, @intCast(v.integer)) else 0
    else
        0;

    const resolved = root_dir.resolvePath(allocator, path.string) catch return ToolResult.fail("Error: OOM");
    defer if (resolved.ptr != path.string.ptr) allocator.free(resolved);

    var file = std.Io.Dir.cwd().openFile(io, resolved, .{ .mode = .read_only }) catch |err| {
        return ToolResult.fail(jsonErrorStr(allocator, "cannot open file '{s}': {}", .{ path.string, err }));
    };
    defer file.close(io);

    const stat = file.stat(io) catch |err| {
        return ToolResult.fail(jsonErrorStr(allocator, "cannot stat file '{s}': {}", .{ path.string, err }));
    };
    const file_size = @as(usize, @intCast(stat.size));
    const contents = allocator.alloc(u8, file_size) catch {
        return ToolResult.fail("Error: OOM");
    };
    defer allocator.free(contents);
    const nread = file.readStreaming(io, &.{contents}) catch |err| {
        return ToolResult.fail(jsonErrorStr(allocator, "cannot read file '{s}': {}", .{ path.string, err }));
    };
    const effective_size = @min(nread, file_size);

    var content_slice: []const u8 = undefined;
    var own_content = false;
    var truncated = false;
    var image_uri: ?[]const u8 = null;
    defer if (image_uri) |u| allocator.free(u);

    const is_image = blk: {
        const p = path.string;
        break :blk endsWithIgnoreCase(p, ".png") or endsWithIgnoreCase(p, ".jpg") or
            endsWithIgnoreCase(p, ".jpeg") or endsWithIgnoreCase(p, ".gif") or
            endsWithIgnoreCase(p, ".webp") or endsWithIgnoreCase(p, ".bmp");
    };
    if (is_image) {
        if (effective_size > MAX_IMAGE_BYTES) {
            return ToolResult.fail(jsonErrorStr(allocator, "image too large ({d} bytes, max {d})", .{ effective_size, MAX_IMAGE_BYTES }));
        }
        const mime = if (endsWithIgnoreCase(path.string, ".png")) "image/png"
            else if (endsWithIgnoreCase(path.string, ".jpg") or endsWithIgnoreCase(path.string, ".jpeg")) "image/jpeg"
            else if (endsWithIgnoreCase(path.string, ".gif")) "image/gif"
            else if (endsWithIgnoreCase(path.string, ".webp")) "image/webp"
            else if (endsWithIgnoreCase(path.string, ".bmp")) "image/bmp"
            else "image/png";
        const b64_len = std.base64.standard.Encoder.calcSize(effective_size);
        const b64_buf = allocator.alloc(u8, b64_len) catch return ToolResult.fail("Error: OOM");
        defer allocator.free(b64_buf);
        const encoded = std.base64.standard.Encoder.encode(b64_buf, contents[0..effective_size]);
        image_uri = std.fmt.allocPrint(allocator, "data:{s};base64,{s}", .{ mime, encoded }) catch return ToolResult.fail("Error: OOM");
    }

    if (offset == 0 and limit == 0) {
        const r = trunc.truncateBytes(contents, MAX_BYTES);
        content_slice = r.text;
        truncated = r.truncated;
    } else {
        var result_data = std.array_list.Managed(u8).init(allocator);
        defer result_data.deinit();

        var included: usize = 0;
        var i: usize = 0;
        while (i < contents.len) {
            const end = std.mem.indexOfScalarPos(u8, contents, i, '\n') orelse contents.len;
            if (offset == 0 or included + 1 >= offset) {
                if (limit == 0 or included < limit) {
                    result_data.appendSlice(contents[i..end]) catch return ToolResult.fail("Error: OOM");
                    result_data.append('\n') catch return ToolResult.fail("Error: OOM");
                    included += 1;
                }
            }
            i = end + 1;
        }
        truncated = limit > 0 and included >= limit;
        content_slice = result_data.toOwnedSlice() catch return ToolResult.fail("Error: OOM");
        own_content = true;
    }
    defer if (own_content) allocator.free(content_slice);

    var buf = std.array_list.Managed(u8).init(allocator);
    defer buf.deinit();
    jh.putc(&buf, '{') catch return ToolResult.fail("Error: OOM");
    jh.putString(&buf, "path", path.string) catch return ToolResult.fail("Error: OOM");
    jh.putc(&buf, ',') catch return ToolResult.fail("Error: OOM");
    jh.putString(&buf, "content", content_slice) catch return ToolResult.fail("Error: OOM");
    if (image_uri) |uri| {
        jh.putc(&buf, ',') catch return ToolResult.fail("Error: OOM");
        jh.putString(&buf, "image", uri) catch return ToolResult.fail("Error: OOM");
    }
    jh.putc(&buf, ',') catch return ToolResult.fail("Error: OOM");
    jh.putInt(&buf, "offset", offset) catch return ToolResult.fail("Error: OOM");
    jh.putc(&buf, ',') catch return ToolResult.fail("Error: OOM");
    jh.putInt(&buf, "limit", limit) catch return ToolResult.fail("Error: OOM");
    jh.putc(&buf, ',') catch return ToolResult.fail("Error: OOM");
    jh.putBool(&buf, "truncated", truncated) catch return ToolResult.fail("Error: OOM");
    if (truncated) {
        jh.putc(&buf, ',') catch return ToolResult.fail("Error: OOM");
        const note = std.fmt.allocPrint(allocator, "Output truncated at {d} bytes. Use read_file with offset={d} limit=2000 to read from byte offset.", .{ MAX_BYTES, MAX_BYTES }) catch "OOM";
        defer allocator.free(note);
        jh.putString(&buf, "note", note) catch return ToolResult.fail("Error: OOM");
    }
    jh.putc(&buf, '}') catch return ToolResult.fail("Error: OOM");
    return ToolResult.ok(jh.finish(&buf));
}

fn jsonErrorStr(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(allocator, "Error: " ++ fmt, args) catch "Error: OOM";
}

fn endsWithIgnoreCase(s: []const u8, suffix: []const u8) bool {
    if (suffix.len > s.len) return false;
    const end = s[s.len - suffix.len ..];
    return std.ascii.eqlIgnoreCase(end, suffix);
}

test "read_file returns error for nonexistent file" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const io = testing.io;

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, "{\"path\": \"/nonexistent_file_xyz\"}", .{}) catch return;
    defer parsed.deinit();
    const args = parsed.value;
    const tr = execute(allocator, io, args);
    defer allocator.free(tr.output);

    try testing.expect(!tr.success);
    try testing.expect(std.mem.startsWith(u8, tr.output, "Error:"));
}
