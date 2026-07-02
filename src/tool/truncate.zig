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

/// Truncate at the largest valid UTF-8 boundary ≤ max_bytes.
/// Source: truncate.zig — UTF-8 safe truncation
pub fn truncateUtf8(text: []const u8, max_bytes: usize) TruncatedText {
    if (text.len <= max_bytes) return .{ .text = text, .truncated = false, .original_len = text.len };
    if (max_bytes == 0) return .{ .text = "", .truncated = true, .original_len = text.len };
    var i: usize = 0;
    while (i < max_bytes) {
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        if (i + len > max_bytes) break;
        i += len;
    }
    return .{ .text = text[0..i], .truncated = true, .original_len = text.len };
}

/// Count codepoints up to max.
/// Source: truncate.zig — codepoint-based truncation
pub fn truncateCodepoints(text: []const u8, max_codepoints: usize) TruncatedText {
    var count: usize = 0;
    var i: usize = 0;
    while (i < text.len and count < max_codepoints) {
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch break;
        i += len;
        count += 1;
    }
    return .{ .text = text[0..i], .truncated = i < text.len, .original_len = text.len };
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

test "truncateUtf8: under limit returns unchanged" {
    const testing = std.testing;
    const r = truncateUtf8("hello", 100);
    try testing.expectEqualStrings("hello", r.text);
    try testing.expect(!r.truncated);
    try testing.expectEqual(@as(usize, 5), r.original_len);
}

test "truncateUtf8: zero max returns empty" {
    const testing = std.testing;
    const r = truncateUtf8("hello", 0);
    try testing.expectEqualStrings("", r.text);
    try testing.expect(r.truncated);
    try testing.expectEqual(@as(usize, 5), r.original_len);
}

test "truncateUtf8: avoids splitting multi-byte" {
    const testing = std.testing;
    // "中" (U+4E2D) is 3 bytes: E4 B8 AD
    // Truncating at 2 bytes should exclude the partial character
    const r = truncateUtf8("中", 2);
    try testing.expect(r.truncated);
    try testing.expectEqualStrings("", r.text);
    try testing.expectEqual(@as(usize, 3), r.original_len);
}

test "truncateUtf8: preserves multi-byte boundary at exact char boundary" {
    const testing = std.testing;
    // "中" (3 bytes) + "文" (3 bytes) + "字" (3 bytes) + "符" (3 bytes) = 12 bytes
    // Truncate at 6 bytes -> should include "中文"
    const r = truncateUtf8("中文字符", 6);
    try testing.expect(r.truncated);
    try testing.expectEqualStrings("中文", r.text);
    try testing.expectEqual(@as(usize, 12), r.original_len);
}

test "truncateCodepoints: under limit returns unchanged" {
    const testing = std.testing;
    const r = truncateCodepoints("hello", 10);
    try testing.expectEqualStrings("hello", r.text);
    try testing.expect(!r.truncated);
    try testing.expectEqual(@as(usize, 5), r.original_len);
}

test "truncateCodepoints: limits by codepoint count" {
    const testing = std.testing;
    const r = truncateCodepoints("中文字符", 2);
    try testing.expect(r.truncated);
    try testing.expectEqualStrings("中文", r.text);
    try testing.expectEqual(@as(usize, 12), r.original_len);
}

test "truncateCodepoints: empty text returns empty" {
    const testing = std.testing;
    const r = truncateCodepoints("", 10);
    try testing.expect(!r.truncated);
    try testing.expectEqualStrings("", r.text);
    try testing.expectEqual(@as(usize, 0), r.original_len);
}
