const std = @import("std");

pub fn writeEscapedJsonString(writer: anytype, s: []const u8) !void {
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (c < 0x80) {
            switch (c) {
                '"' => try writer.writeAll("\\\""),
                '\\' => try writer.writeAll("\\\\"),
                '\n' => try writer.writeAll("\\n"),
                '\r' => try writer.writeAll("\\r"),
                '\t' => try writer.writeAll("\\t"),
                0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f => {
                    try writer.print("\\u00{x:0>2}", .{c});
                },
                else => try writer.writeByte(c),
            }
            i += 1;
        } else if (c >= 0xC0 and c <= 0xDF) {
            if (i + 1 < s.len) { try writer.writeAll(s[i..i+2]); i += 2; }
            else { try writer.writeAll("\\ufffd"); i += 1; }
        } else if (c >= 0xE0 and c <= 0xEF) {
            if (i + 2 < s.len) { try writer.writeAll(s[i..i+3]); i += 3; }
            else { try writer.writeAll("\\ufffd"); i += 1; }
        } else if (c >= 0xF0 and c <= 0xF4) {
            if (i + 3 < s.len) { try writer.writeAll(s[i..i+4]); i += 4; }
            else { try writer.writeAll("\\ufffd"); i += 1; }
        } else {
            try writer.writeAll("\\ufffd");
            i += 1;
        }
    }
}

pub fn escapeJson(buf: *std.array_list.Managed(u8), s: []const u8) !void {
    try buf.append('"');
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
                    const hex = try std.fmt.bufPrint(&hex_buf, "\\u00{x:0>2}", .{c});
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
    try buf.append('"');
}

pub fn prettyPrint(writer: anytype, value: std.json.Value, indent: usize) !void {
    switch (value) {
        .null => try writer.writeAll("null"),
        .bool => |b| try writer.writeAll(if (b) "true" else "false"),
        .integer => |i| try writer.print("{d}", .{i}),
        .float => |f| try writer.print("{d}", .{f}),
        .number_string => |s| {
            try writer.writeByte('"');
            try writeEscapedJsonString(writer, s);
            try writer.writeByte('"');
        },
        .string => |s| {
            try writer.writeByte('"');
            try writeEscapedJsonString(writer, s);
            try writer.writeByte('"');
        },
        .array => |arr| {
            if (arr.items.len == 0) return try writer.writeAll("[]");
            try writer.writeAll("[\n");
            for (arr.items, 0..) |item, i| {
                for (0..indent + 2) |_| try writer.writeByte(' ');
                try prettyPrint(writer, item, indent + 2);
                if (i < arr.items.len - 1) try writer.writeAll(",");
                try writer.writeByte('\n');
            }
            for (0..indent) |_| try writer.writeByte(' ');
            try writer.writeByte(']');
        },
        .object => |obj| {
            if (obj.count() == 0) return try writer.writeAll("{}");
            try writer.writeAll("{\n");
            var it = obj.iterator();
            var first = true;
            while (it.next()) |entry| {
                if (!first) try writer.writeAll(",\n");
                first = false;
                for (0..indent + 2) |_| try writer.writeByte(' ');
                try writer.writeByte('"');
                try writeEscapedJsonString(writer, entry.key_ptr.*);
                try writer.writeAll("\": ");
                try prettyPrint(writer, entry.value_ptr.*, indent + 2);
            }
            try writer.writeByte('\n');
            for (0..indent) |_| try writer.writeByte(' ');
            try writer.writeByte('}');
        },
    }
}

pub fn putc(buf: *std.array_list.Managed(u8), c: u8) !void {
    try buf.append(c);
}

pub fn puts(buf: *std.array_list.Managed(u8), s: []const u8) !void {
    try buf.appendSlice(s);
}

pub fn putKey(buf: *std.array_list.Managed(u8), key: []const u8) !void {
    try buf.append('"');
    try buf.appendSlice(key);
    try buf.appendSlice("\":");
}

pub fn putString(buf: *std.array_list.Managed(u8), key: []const u8, value: []const u8) !void {
    try putKey(buf, key);
    try escapeJson(buf, value);
}

pub fn putInt(buf: *std.array_list.Managed(u8), key: []const u8, value: anytype) !void {
    try putKey(buf, key);
    var num_buf: [32]u8 = undefined;
    const num_str = try std.fmt.bufPrint(&num_buf, "{d}", .{value});
    try buf.appendSlice(num_str);
}

pub fn putBool(buf: *std.array_list.Managed(u8), key: []const u8, value: bool) !void {
    try putKey(buf, key);
    try buf.appendSlice(if (value) "true" else "false");
}

pub fn finish(buf: *std.array_list.Managed(u8)) []const u8 {
    return buf.toOwnedSlice() catch "Error: OOM";
}

test "escapeJson: UTF-8 multi-byte bytes pass through verbatim" {
    const testing = std.testing;
    const allocator = testing.allocator;
    var buf = std.array_list.Managed(u8).init(allocator);
    defer buf.deinit();

    try escapeJson(&buf, "\xE4\xBD\xA0"); // 你
    const result = buf.items;
    // UTF-8 bytes pass through verbatim, not escaped as \u00XX
    try testing.expect(std.mem.indexOf(u8, result, "\"\xE4\xBD\xA0\"") != null);
    try testing.expect(std.mem.indexOf(u8, result, "\\u00e4") == null);
}

test "escapeJson: invalid UTF-8 continuation byte replaced with \\ufffd" {
    const testing = std.testing;
    const allocator = testing.allocator;
    var buf = std.array_list.Managed(u8).init(allocator);
    defer buf.deinit();

    try escapeJson(&buf, "\xAA"); // lone continuation byte
    const result = buf.items;
    try testing.expect(std.mem.indexOf(u8, result, "\\ufffd") != null);
}

test "escapeJson: ASCII passthrough" {
    const testing = std.testing;
    const allocator = testing.allocator;
    var buf = std.array_list.Managed(u8).init(allocator);
    defer buf.deinit();

    try escapeJson(&buf, "hello");
    const result = buf.items;
    try testing.expect(std.mem.indexOf(u8, result, "\"hello\"") != null);
}

const TestWriter = struct {
    buf: []u8,
    pos: *usize,

    fn writeByte(self: @This(), byte: u8) !void {
        if (self.pos.* >= self.buf.len) return error.NoSpaceLeft;
        self.buf[self.pos.*] = byte;
        self.pos.* += 1;
    }

    fn writeAll(self: @This(), bytes: []const u8) !void {
        const end = self.pos.* + bytes.len;
        if (end > self.buf.len) return error.NoSpaceLeft;
        @memcpy(self.buf[self.pos.*..end], bytes);
        self.pos.* = end;
    }

    fn writeByteNTimes(self: @This(), byte: u8, n: usize) !void {
        const end = self.pos.* + n;
        if (end > self.buf.len) return error.NoSpaceLeft;
        @memset(self.buf[self.pos.*..end], byte);
        self.pos.* += n;
    }

    fn print(self: @This(), comptime fmt: []const u8, args: anytype) !void {
        const written = try std.fmt.bufPrint(self.buf[self.pos.*..], fmt, args);
        self.pos.* += written.len;
    }
};

fn testingWriter(buf: []u8, pos: *usize) TestWriter {
    return .{ .buf = buf, .pos = pos };
}

test "prettyPrint: null, bool, int, float" {
    const testing = std.testing;
    var storage: [512]u8 = undefined;
    var pos: usize = 0;

    inline for (&.{ "null", "true", "42", "3.14" }) |expected| {
        var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, expected, .{});
        defer parsed.deinit();
        try prettyPrint(testingWriter(&storage, &pos), parsed.value, 0);
        try testing.expectEqualStrings(expected, storage[0..pos]);
        pos = 0;
    }
}

test "prettyPrint: string" {
    const testing = std.testing;
    var storage: [512]u8 = undefined;
    var pos: usize = 0;

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, "\"hello\"", .{});
    defer parsed.deinit();
    try prettyPrint(testingWriter(&storage, &pos), parsed.value, 0);
    try testing.expectEqualStrings("\"hello\"", storage[0..pos]);
}

test "prettyPrint: string with escaping" {
    const testing = std.testing;
    var storage: [512]u8 = undefined;
    var pos: usize = 0;

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, "\"hello\\nworld\\t\\\"quoted\\\"\"", .{});
    defer parsed.deinit();
    try prettyPrint(testingWriter(&storage, &pos), parsed.value, 0);
    try testing.expectEqualStrings("\"hello\\nworld\\t\\\"quoted\\\"\"", storage[0..pos]);
}

test "prettyPrint: empty containers" {
    const testing = std.testing;
    var storage: [512]u8 = undefined;
    var pos: usize = 0;

    inline for (&.{ "[]", "{}" }) |expected| {
        var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, expected, .{});
        defer parsed.deinit();
        try prettyPrint(testingWriter(&storage, &pos), parsed.value, 0);
        try testing.expectEqualStrings(expected, storage[0..pos]);
        pos = 0;
    }
}

test "prettyPrint: nested object" {
    const testing = std.testing;
    var storage: [2048]u8 = undefined;
    var pos: usize = 0;

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        "{\"name\":\"Alice\",\"age\":30}", .{});
    defer parsed.deinit();
    try prettyPrint(testingWriter(&storage, &pos), parsed.value, 0);
    const result = storage[0..pos];
    try testing.expect(std.mem.indexOf(u8, result, "\"name\"") != null);
    try testing.expect(std.mem.indexOf(u8, result, "\"Alice\"") != null);
    try testing.expect(std.mem.indexOf(u8, result, "\"age\"") != null);
    try testing.expect(std.mem.indexOf(u8, result, "30") != null);
    try testing.expect(std.mem.indexOf(u8, result, "{\n") != null);
    try testing.expect(std.mem.indexOf(u8, result, "\n}") != null);
}

test "prettyPrint: array" {
    const testing = std.testing;
    var storage: [2048]u8 = undefined;
    var pos: usize = 0;

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        "[1,\"two\",true,null]", .{});
    defer parsed.deinit();
    try prettyPrint(testingWriter(&storage, &pos), parsed.value, 2);
    const result = storage[0..pos];
    try testing.expect(std.mem.indexOf(u8, result, "[\n") != null);
    try testing.expect(std.mem.indexOf(u8, result, "1") != null);
    try testing.expect(std.mem.indexOf(u8, result, "\"two\"") != null);
    try testing.expect(std.mem.indexOf(u8, result, "true") != null);
    try testing.expect(std.mem.indexOf(u8, result, "null") != null);
}
