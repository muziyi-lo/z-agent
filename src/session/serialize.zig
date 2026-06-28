const std = @import("std");
const types = @import("../types.zig");
const Io = std.Io;
const common = @import("../provider/common.zig");
const session_mod = @import("../session.zig");

const SessionHeader = session_mod.SessionHeader;
const Entry = session_mod.Entry;
const SessionManager = session_mod.SessionManager;
const CURRENT_VERSION = session_mod.CURRENT_VERSION;

pub fn serializeMessage(allocator: std.mem.Allocator, msg: types.Message) ![]u8 {
    var buf = std.array_list.Managed(u8).init(allocator);
    defer buf.deinit();
    try buf.appendSlice("{\"type\":\"message\",\"role\":\"");
    try buf.appendSlice(@tagName(msg.role));
    try buf.appendSlice("\"");
    if (msg.timestamp_ns) |ts| {
        var ts_buf: [64]u8 = undefined;
        const ts_str = try std.fmt.bufPrint(&ts_buf, ",\"timestamp\":{d}", .{ts});
        try buf.appendSlice(ts_str);
    }
    if (msg.content) |parts| {
        if (parts.len > 0 and parts[0] == .text) {
            try buf.appendSlice(",\"content\":\"");
            try common.appendEscapedJsonString(&buf, parts[0].text);
            try buf.appendSlice("\"");
        } else if (parts.len > 0 and parts[0] == .tool_result) {
            try buf.appendSlice(",\"content\":\"");
            try common.appendEscapedJsonString(&buf, parts[0].tool_result.content);
            try buf.appendSlice("\"");
            if (parts[0].tool_result.is_error) {
                try buf.appendSlice(",\"is_error\":true");
            }
            if (parts[0].tool_result.name) |n| {
                try buf.appendSlice(",\"name\":\"");
                try common.appendEscapedJsonString(&buf, n);
                try buf.appendSlice("\"");
            }
            if (parts[0].tool_result.duration_ms) |d| {
                var d_buf: [32]u8 = undefined;
                const d_str = try std.fmt.bufPrint(&d_buf, ",\"duration_ms\":{d}", .{d});
                try buf.appendSlice(d_str);
            }
        } else if (parts.len > 0 and parts[0] == .image_url) {
            try buf.appendSlice(",\"image_url\":\"");
            try common.appendEscapedJsonString(&buf, parts[0].image_url.url);
            try buf.appendSlice("\"");
        }
    }
    if (msg.tool_call_id) |id| {
        try buf.appendSlice(",\"tool_call_id\":\"");
        try common.appendEscapedJsonString(&buf, id);
        try buf.appendSlice("\"");
    }
    if (msg.tool_calls) |tcs| {
        try buf.appendSlice(",\"tool_calls\":[");
        for (tcs, 0..) |tc, i| {
            if (i > 0) try buf.appendSlice(",");
            try buf.appendSlice("{\"id\":\"");
            try common.appendEscapedJsonString(&buf, tc.id);
            try buf.appendSlice("\",\"name\":\"");
            try common.appendEscapedJsonString(&buf, tc.name);
            try buf.appendSlice("\",\"arguments\":\"");
            try common.appendEscapedJsonString(&buf, tc.arguments);
            try buf.appendSlice("\"}");
        }
        try buf.appendSlice("]");
    }
    if (msg.reasoning) |r| {
        try buf.appendSlice(",\"reasoning\":\"");
        try common.appendEscapedJsonString(&buf, r);
        try buf.appendSlice("\"");
    }
    try buf.appendSlice("}\n");
    return buf.toOwnedSlice();
}

pub fn serializeHeader(allocator: std.mem.Allocator, id: []const u8, ts_ns: i96, cwd: []const u8, model: ?[]const u8, provider: ?[]const u8) ![]u8 {
    const model_str = model orelse "";
    const provider_str = provider orelse "";
    return std.fmt.allocPrint(allocator,
        "{{\"type\":\"session\",\"id\":\"{s}\",\"timestamp\":{d},\"cwd\":\"{s}\",\"version\":{d},\"model\":\"{s}\",\"provider\":\"{s}\"}}\n",
        .{ id, ts_ns, cwd, CURRENT_VERSION, model_str, provider_str },
    );
}

pub fn serializeCompaction(allocator: std.mem.Allocator, summary: []const u8, first_kept_index: usize, tokens_before: u32) ![]u8 {
    return std.fmt.allocPrint(allocator,
        "{{\"type\":\"compaction\",\"summary\":\"{s}\",\"first_kept_index\":{d},\"tokens_before\":{d}}}\n",
        .{ summary, first_kept_index, tokens_before },
    );
}

pub fn formatNanos(allocator: std.mem.Allocator, ts_ns: i96) ![]u8 {
    return std.fmt.allocPrint(allocator, "{d}", .{ts_ns});
}

pub fn formatTimestamp(allocator: std.mem.Allocator, ts_ns: i96) ![]const u8 {
    const s = @divFloor(ts_ns, 1_000_000_000);
    const z = @divFloor(s, 86400) + 719468;
    const era = @divFloor(if (z >= 0) z else z - 146096, 146097);
    const doe = @as(u64, @intCast(z - era * 146097));
    const yoe = @as(u64, @intCast((doe - doe / 1460 + doe / 36524 - doe / 146096) / 365));
    const y = @as(i64, @intCast(yoe)) + @as(i64, @intCast(era * 400));
    const doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    const mp = (5 * doy + 2) / 153;
    const d = doy - (153 * mp + 2) / 5 + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    const year = if (m <= 2) y + 1 else y;
    const tod = @mod(s, 86400);
    const h = @divFloor(tod, 3600);
    const min = @mod(@divFloor(tod, 60), 60);
    const sec = @mod(tod, 60);
    return std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{ year, m, d, h, min, sec });
}

pub fn currentTimeNs(io: Io) i96 {
    return Io.Clock.Timestamp.now(io, .real).raw.nanoseconds;
}

pub fn readFile(allocator: std.mem.Allocator, path: []const u8, io: Io) ![]u8 {
    const file = try Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only });
    defer file.close(io);
    const size = @as(usize, @intCast((try file.stat(io)).size));
    var buf = try allocator.alloc(u8, size);
    const n = try file.readPositionalAll(io, buf, 0);
    return buf[0..n];
}

pub fn parseSessionHeader(allocator: std.mem.Allocator, parsed: std.json.Value) !SessionHeader {
    const id = parsed.object.get("id") orelse return error.MissingField;
    const ts_val = parsed.object.get("timestamp") orelse return error.MissingField;
    const ts_ns = if (ts_val == .integer) ts_val.integer else @as(i64, 0);
    const cwd = if (parsed.object.get("cwd")) |v| if (v == .string) v.string else "" else "";
    const ver = if (parsed.object.get("version")) |v| @as(u32, @intCast(@min(@max(v.integer, 0), std.math.maxInt(u32)))) else 1;
    const model_val = if (parsed.object.get("model")) |v| if (v == .string) v.string else null else null;
    const provider_val = if (parsed.object.get("provider")) |v| if (v == .string) v.string else null else null;
    return SessionHeader{
        .id = try allocator.dupe(u8, id.string),
        .timestamp_ns = ts_ns,
        .cwd = try allocator.dupe(u8, cwd),
        .version = ver,
        .model = if (model_val) |m| try allocator.dupe(u8, m) else null,
        .provider = if (provider_val) |p| try allocator.dupe(u8, p) else null,
    };
}

pub fn readSessionHeaderFromContent(allocator: std.mem.Allocator, content: []const u8) !SessionHeader {
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, "\r");
        if (line.len == 0) continue;
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, allocator, line, .{}) catch continue;
        const type_val = parsed.object.get("type") orelse continue;
        if (!std.mem.eql(u8, type_val.string, "session")) continue;
        return parseSessionHeader(allocator, parsed);
    }
    return error.MissingSessionHeader;
}

pub fn loadFromFile(allocator: std.mem.Allocator, io: Io, file_path: []const u8, session_dir: []const u8) !SessionManager {
    const content = try readFile(allocator, file_path, io);
    defer allocator.free(content);
    const loaded = try loadEntries(allocator, content);
    return SessionManager{
        .allocator = allocator,
        .io = io,
        .session_dir = try allocator.dupe(u8, session_dir),
        .session_file = try allocator.dupe(u8, file_path),
        .session_id = try allocator.dupe(u8, loaded.header.id),
        .entries = loaded.entries,
        .flushed = true,
        .model = loaded.header.model orelse try allocator.dupe(u8, ""),
        .provider = loaded.header.provider orelse try allocator.dupe(u8, ""),
    };
}

pub fn loadEntries(allocator: std.mem.Allocator, content: []const u8) !struct { header: SessionHeader, entries: std.array_list.Managed(Entry) } {
    var entries = std.array_list.Managed(Entry).init(allocator);
    var header: ?SessionHeader = null;

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, "\r");
        if (line.len == 0) continue;

        const parsed = std.json.parseFromSliceLeaky(std.json.Value, allocator, line, .{}) catch continue;
        const type_val = parsed.object.get("type") orelse continue;

        if (std.mem.eql(u8, type_val.string, "session")) {
            // Last session header wins (supports model switches)
            const new_header = parseSessionHeader(allocator, parsed) catch continue;
            if (header != null) {
                allocator.free(header.?.id);
                allocator.free(header.?.cwd);
                if (header.?.model) |m| allocator.free(m);
                if (header.?.provider) |p| allocator.free(p);
            }
            header = new_header;
            continue;
        }

        if (std.mem.eql(u8, type_val.string, "compaction")) {
            const summary = if (parsed.object.get("summary")) |v| if (v == .string) v.string else "" else "";
            const fki = if (parsed.object.get("first_kept_index")) |v| @as(usize, @intCast(@min(@max(v.integer, 0), std.math.maxInt(usize)))) else 0;
            const tb = if (parsed.object.get("tokens_before")) |v| @as(u32, @intCast(@min(@max(v.integer, 0), std.math.maxInt(u32)))) else 0;
            try entries.append(.{ .compaction = .{
                .summary = try allocator.dupe(u8, summary),
                .first_kept_index = fki,
                .tokens_before = tb,
            } });
            continue;
        }

        if (!std.mem.eql(u8, type_val.string, "message")) continue;

        const role_str = if (parsed.object.get("role")) |v| v.string else continue;
        const role: types.Role = if (std.mem.eql(u8, role_str, "user")) .user else if (std.mem.eql(u8, role_str, "assistant")) .assistant else if (std.mem.eql(u8, role_str, "tool")) .tool else .system;

        const content_val = if (parsed.object.get("content")) |v| if (v == .string) v.string else null else null;
        const tc_id_val = if (parsed.object.get("tool_call_id")) |v| if (v == .string) v.string else null else null;
        const reasoning_val = if (parsed.object.get("reasoning")) |v| if (v == .string) v.string else null else null;
        const ts_val = if (parsed.object.get("timestamp")) |v| if (v == .integer) @as(i96, @intCast(v.integer)) else null else null;
        const is_error_val = if (parsed.object.get("is_error")) |v| if (v == .bool) v.bool else null else null;
        const tool_name_val = if (parsed.object.get("name")) |v| if (v == .string) v.string else null else null;
        const duration_val = if (parsed.object.get("duration_ms")) |v| @as(u32, @intCast(@min(@max(v.integer, 0), std.math.maxInt(u32)))) else null;

        var tool_calls: ?[]types.ToolCall = null;
        if (parsed.object.get("tool_calls")) |tcs_val| {
            const tc_array = tcs_val.array;
            var list = std.array_list.Managed(types.ToolCall).init(allocator);
            for (tc_array.items) |tc_item| {
                const obj = tc_item.object;
                try list.append(.{
                    .id = try allocator.dupe(u8, obj.get("id").?.string),
                    .name = try allocator.dupe(u8, obj.get("name").?.string),
                    .arguments = try allocator.dupe(u8, obj.get("arguments").?.string),
                });
            }
            tool_calls = try list.toOwnedSlice();
        }

        var content_parts: ?[]types.ContentPart = null;
        if (parsed.object.get("image_url")) |img_url_val| {
            if (img_url_val != .null) {
                content_parts = try allocator.alloc(types.ContentPart, 1);
                content_parts.?[0] = .{ .image_url = .{ .url = try allocator.dupe(u8, img_url_val.string) } };
            }
        } else if (content_val) |c| {
            content_parts = try allocator.alloc(types.ContentPart, 1);
            if (role == .tool) {
                content_parts.?[0] = .{ .tool_result = .{
                    .id = if (tc_id_val) |id_str| try allocator.dupe(u8, id_str) else try allocator.dupe(u8, ""),
                    .content = try allocator.dupe(u8, c),
                    .is_error = is_error_val orelse false,
                    .name = if (tool_name_val) |n| try allocator.dupe(u8, n) else null,
                    .duration_ms = duration_val,
                } };
            } else {
                content_parts.?[0] = .{ .text = try allocator.dupe(u8, c) };
            }
        }

        try entries.append(.{ .message = .{
            .role = role,
            .content = if (content_parts) |cp| cp else null,
            .tool_calls = tool_calls,
            .tool_call_id = if (tc_id_val) |id_str| try allocator.dupe(u8, id_str) else null,
            .reasoning = if (reasoning_val) |r| try allocator.dupe(u8, r) else null,
            .timestamp_ns = if (ts_val) |ts| ts else null,
        } });
    }

    if (header == null) return error.MissingSessionHeader;
    return .{ .header = header.?, .entries = entries };
}
