const std = @import("std");
const ansi = @import("ansi.zig");

/// 推理阶段进入：dim header + │ 前缀（仅在首次进入推理时调用一次）
pub fn formatReasoningHeader(writer: anytype) !void {
    if (ansi.shouldColorize()) {
        try writer.print("{s}[思考]{s}\n{s}│{s} ", .{ ansi.C.dim, ansi.C.reset, ansi.C.dim, ansi.C.reset });
    } else {
        try writer.writeAll("[思考]\n│ ");
    }
}

/// 输出推理文本片段（流式追加，无前缀无换行）
pub fn formatReasoningText(writer: anytype, text: []const u8) !void {
    try writer.writeAll(text);
}

/// 推理→内容过渡分隔线
pub fn formatContentTransition(writer: anytype) !void {
    if (ansi.shouldColorize()) {
        try writer.print("\n{s}───────{s}\n", .{ ansi.C.dim, ansi.C.reset });
    } else {
        try writer.writeAll("\n-------\n");
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "formatReasoningHeader: dim header + prefix" {
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try formatReasoningHeader(&w);
    const out = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "[思考]") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "│") != null);
}

test "formatReasoningText: writes text directly" {
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try formatReasoningText(&w, "hello");
    try formatReasoningText(&w, " world");
    const out = w.buffered();
    try std.testing.expectEqualStrings("hello world", out);
}

test "formatReasoningText: empty text is no-op" {
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try formatReasoningText(&w, "");
    try std.testing.expectEqual(@as(usize, 0), w.buffered().len);
}

test "formatContentTransition: separator line" {
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try formatContentTransition(&w);
    const out = w.buffered();
    try std.testing.expect(
        std.mem.indexOf(u8, out, "───") != null or
        std.mem.indexOf(u8, out, "---") != null
    );
}

test "formatContentTransition: leads with newline" {
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try formatContentTransition(&w);
    const out = w.buffered();
    try std.testing.expect(out[0] == '\n');
}
