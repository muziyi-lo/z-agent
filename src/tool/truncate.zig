const std = @import("std");

pub const TruncatedText = struct {
    text: []const u8,
    truncated: bool,
    original_len: usize,
};

pub fn truncateBytes(text: []const u8, max_bytes: usize) TruncatedText {
    if (text.len <= max_bytes) {
        return .{ .text = text, .truncated = false, .original_len = text.len };
    }
    return .{ .text = text[0..max_bytes], .truncated = true, .original_len = text.len };
}

pub fn truncateLines(text: []const u8, max_lines: usize) TruncatedText {
    var line_count: usize = 0;
    var end: usize = 0;
    while (line_count < max_lines and end < text.len) {
        const nl = std.mem.indexOfScalarPos(u8, text, end, '\n') orelse {
            end = text.len;
            line_count += 1;
            break;
        };
        end = nl + 1;
        line_count += 1;
    }
    if (end >= text.len) {
        return .{ .text = text, .truncated = false, .original_len = text.len };
    }
    return .{ .text = text[0..end], .truncated = true, .original_len = text.len };
}

pub fn countLines(text: []const u8) usize {
    var count: usize = 0;
    for (text) |c| {
        if (c == '\n') count += 1;
    }
    return count;
}

test "truncateBytes: under limit returns unchanged" {
    const testing = std.testing;
    const r = truncateBytes("hello", 100);
    try testing.expectEqualStrings("hello", r.text);
    try testing.expect(!r.truncated);
    try testing.expectEqual(@as(usize, 5), r.original_len);
}

test "truncateBytes: over limit truncates" {
    const testing = std.testing;
    const r = truncateBytes("hello world", 5);
    try testing.expectEqualStrings("hello", r.text);
    try testing.expect(r.truncated);
}

test "truncateLines: under limit returns unchanged" {
    const testing = std.testing;
    const r = truncateLines("a\nb\nc", 10);
    try testing.expectEqualStrings("a\nb\nc", r.text);
    try testing.expect(!r.truncated);
}

test "truncateLines: over limit truncates" {
    const testing = std.testing;
    const r = truncateLines("a\nb\nc\nd\ne", 3);
    try testing.expectEqualStrings("a\nb\nc\n", r.text);
    try testing.expect(r.truncated);
}

test "countLines: counts newline characters" {
    const testing = std.testing;
    try testing.expectEqual(@as(usize, 0), countLines("hello"));
    try testing.expectEqual(@as(usize, 2), countLines("a\nb\nc"));
    try testing.expectEqual(@as(usize, 3), countLines("a\nb\nc\n"));
}
