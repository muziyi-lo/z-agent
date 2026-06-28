const std = @import("std");

pub const COMPACTION_THRESHOLD: f64 = 0.7;
pub const COMPACTION_KEEP_RATIO: f64 = 0.25;

pub fn estimate(text: []const u8) usize {
    if (text.len == 0) return 0;
    var ascii: usize = 0;
    for (text) |c| {
        if (c <= 127) ascii += 1;
    }
    const nonascii = text.len - ascii;
    return (ascii / 4) + (nonascii * 6 / 10) + 1;
}

pub fn estimateMessages(msgs: []const std.json.Value) usize {
    var total: usize = 0;
    for (msgs) |msg| {
        total += estimateMessage(&msg);
    }
    return total;
}

fn estimateMessage(msg: *const std.json.Value) usize {
    var total: usize = 0;
    const obj = msg.object;
    if (obj.get("role")) |v| total += estimate(v.string);
    if (obj.get("content")) |v| {
        if (v == .string) {
            total += estimate(v.string);
        } else if (v == .array) {
            for (v.array.items) |part| {
                if (part.object.get("text")) |t| total += estimate(t.string);
                if (part.object.get("content")) |c| total += estimate(c.string);
            }
        }
    }
    return total;
}

test "estimate: empty returns 0" {
    const testing = std.testing;
    try testing.expectEqual(@as(usize, 0), estimate(""));
}

test "estimate: english chars" {
    const testing = std.testing;
    const r = estimate("hello world");
    try testing.expect(r > 0);
    try testing.expect(r <= 5);
}

test "estimate: chinese chars are denser" {
    const testing = std.testing;
    const ascii = estimate("aaaaaaaaaaaaaaaaaaaa"); // 20 ascii
    const zh = estimate("你好世界你好世界你好世界你好世界你好世界"); // 20 chinese
    try testing.expect(zh > ascii);
}
