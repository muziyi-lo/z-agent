const std = @import("std");

const dim = "\x1b[2m";
const bold = "\x1b[1m";
const italic = "\x1b[3m";
const strikethrough = "\x1b[9m";
const blue = "\x1b[34m";
const underline = "\x1b[4m";
const cyan = "\x1b[36m";
const yellow = "\x1b[33m";
const reset = "\x1b[0m";

const StyleFlags = packed struct {
    bold: bool = false,
    italic: bool = false,
    dim: bool = false,
    strikethrough: bool = false,
};

/// Render heading line as bold+cyan, including # markers. No allocation.
pub fn renderHeading(writer: anytype, line: []const u8, _: u8) !void {
    try writer.writeAll(bold);
    try writer.writeAll(cyan);
    try writer.writeAll(line);
    try writer.writeAll(reset);
    try writer.writeAll("\n");
}

/// Render blockquote: cyan "┃ " prefix, content in italic. No allocation.
pub fn renderBlockquote(writer: anytype, content: []const u8) !void {
    try writer.writeAll(cyan);
    try writer.writeAll("┃ ");
    try writer.writeAll(reset);
    try writer.writeAll(italic);
    try writer.writeAll(content);
    try writer.writeAll(reset);
    try writer.writeAll("\n");
}

/// Render code fence open marker with optional lang label beside it.
pub fn renderCodeFenceOpen(writer: anytype, lang: []const u8) !void {
    try writer.writeAll(dim);
    try writer.writeAll("┌───────┐");
    if (lang.len > 0) {
        try writer.writeAll(" ");
        try writer.writeAll(lang);
    }
    try writer.writeAll(reset);
    try writer.writeAll("\n");
}

/// Render code fence close marker. No allocation.
pub fn renderCodeFenceClose(writer: anytype) !void {
    try writer.writeAll(dim);
    try writer.writeAll("└───────┘");
    try writer.writeAll(reset);
    try writer.writeAll("\n");
}

/// Render a single line inside a code block with dim "│ " prefix. No allocation.
pub fn renderCodeContent(writer: anytype, line: []const u8) !void {
    try writer.writeAll(dim);
    try writer.writeAll("│ ");
    try writer.writeAll(reset);
    try writer.writeAll(line);
    try writer.writeAll("\n");
}

/// Render horizontal rule: dim 40-char line. No allocation.
pub fn renderHr(writer: anytype) !void {
    try writer.writeAll(dim);
    var i: u8 = 0;
    while (i < 40) : (i += 1) {
        try writer.writeAll("─");
    }
    try writer.writeAll(reset);
    try writer.writeAll("\n");
}

/// Render unordered list item: indent spaces + "  " + cyan "•" + content via renderInline. No allocation.
pub fn renderUnorderedList(writer: anytype, content: []const u8, indent: usize) !void {
    var i: usize = 0;
    while (i < indent * 2) : (i += 1) { try writer.writeAll(" "); }
    try writer.writeAll("  ");
    try writer.writeAll(cyan);
    try writer.writeAll("•");
    try writer.writeAll(reset);
    try writer.writeAll(" ");
    try renderInline(writer, content);
    try writer.writeAll("\n");
}

/// Render ordered list item: indent spaces + cyan " N. " + content via renderInline. No allocation.
pub fn renderOrderedList(writer: anytype, number: u32, content: []const u8, indent: usize) !void {
    var i: usize = 0;
    while (i < indent * 2) : (i += 1) { try writer.writeAll(" "); }
    var buf: [16]u8 = undefined;
    const num_str = std.fmt.bufPrint(&buf, "{d}.", .{number}) catch unreachable;
    try writer.writeAll(" ");
    try writer.writeAll(cyan);
    try writer.writeAll(num_str);
    try writer.writeAll(reset);
    try writer.writeAll(" ");
    try renderInline(writer, content);
    try writer.writeAll("\n");
}

/// Render task list item: indent spaces + "  " + cyan marker + content via renderInline. Checked items use strikethrough.
pub fn renderTaskList(writer: anytype, checked: bool, content: []const u8, indent: usize) !void {
    var i: usize = 0;
    while (i < indent * 2) : (i += 1) { try writer.writeAll(" "); }
    try writer.writeAll("  ");
    try writer.writeAll(cyan);
    if (checked) {
        try writer.writeAll("\xe2\x9c\x93");
    } else {
        try writer.writeAll("\xe2\x96\xa1");
    }
    try writer.writeAll(reset);
    try writer.writeAll(" ");
    if (checked) {
        try writer.writeAll(strikethrough);
    }
    try renderInline(writer, content);
    if (checked) {
        try writer.writeAll(reset);
    }
    try writer.writeAll("\n");
}

/// Inline style parsing only — no trailing reset or \n. Used by list renderers and table cells.
pub fn renderInline(writer: anytype, line: []const u8) !void {
    var i: usize = 0;
    var start: usize = 0;
    var style = StyleFlags{};
    var is_image = false;

    while (i < line.len) {
        if (i + 1 < line.len and line[i] == '*' and line[i + 1] == '*') {
            if (i > start) {
                try writeStyled(writer, line[start..i], style);
            }
            style.bold = !style.bold;
            i += 2;
            start = i;
        } else if (i + 1 < line.len and line[i] == '~' and line[i + 1] == '~') {
            var valid = false;
            if (!style.strikethrough) {
                valid = i + 2 >= line.len or line[i + 2] != ' ';
            } else {
                valid = i > 0 and line[i - 1] != ' ';
            }
            if (valid) {
                if (i > start) {
                    try writeStyled(writer, line[start..i], style);
                }
                style.strikethrough = !style.strikethrough;
                i += 2;
                start = i;
            } else {
                i += 1;
            }
        } else if (line[i] == '*') {
            if (i > start) {
                try writeStyled(writer, line[start..i], style);
            }
            style.italic = !style.italic;
            i += 1;
            start = i;
        } else if (line[i] == '`') {
            if (i > start) {
                try writeStyled(writer, line[start..i], style);
            }
            style.dim = !style.dim;
            i += 1;
            start = i;
        } else if (i + 1 < line.len and line[i] == '!' and line[i + 1] == '[') {
            if (i > start) {
                try writeStyled(writer, line[start..i], style);
            }
            is_image = true;
            i += 1;
            start = i;
        } else if (line[i] == '[') {
            try renderInlineLink(writer, line, &i, &start, &is_image, style);
        } else {
            i += 1;
        }
    }

    if (start < line.len) {
        try writeStyled(writer, line[start..], style);
    }
}

/// Render paragraph: inline style parsing + reset + \n. No allocation.
pub fn renderParagraph(writer: anytype, line: []const u8) !void {
    try renderInline(writer, line);
    try writer.writeAll(reset);
    try writer.writeAll("\n");
}

/// Write text with active ANSI styles applied.
fn writeStyled(writer: anytype, text: []const u8, style: StyleFlags) !void {
    if (text.len == 0) return;
    try writer.writeAll(reset);
    if (style.bold) try writer.writeAll(bold);
    if (style.italic) try writer.writeAll(italic);
    if (style.dim) try writer.writeAll(yellow);
    if (style.strikethrough) try writer.writeAll(strikethrough);
    try writer.writeAll(text);
}

/// Parse and render markdown link [label](url) or image ![alt](url). Flushes preceding text with active styles, renders label (blue+underline or dim+italic), deduplicates label==url by omitting (url) suffix. No allocation.
fn renderInlineLink(writer: anytype, line: []const u8, i: *usize, start: *usize, is_image: *bool, style: StyleFlags) !void {
    const label_start = i.* + 1;
    const label_end = std.mem.indexOf(u8, line[label_start..], "]") orelse {
        i.* += 1;
        return;
    };
    const label = line[label_start .. label_start + label_end];
    const paren_pos = label_start + label_end + 1;
    if (paren_pos >= line.len or line[paren_pos] != '(') {
        i.* += 1;
        return;
    }
    const url_start = paren_pos + 1;
    const url_end = std.mem.indexOf(u8, line[url_start..], ")") orelse {
        i.* += 1;
        return;
    };
    const url = line[url_start .. url_start + url_end];

    // Flush text before link
    if (i.* > start.*) {
        try writeStyled(writer, line[start.*..i.*], style);
    }

    // Render label: dim+italic for image, blue+underline for link
    try writer.writeAll(reset);
    if (is_image.*) {
        try writer.writeAll(dim);
        try writer.writeAll(italic);
    } else {
        try writer.writeAll(blue);
        try writer.writeAll(underline);
    }
    try writer.writeAll(label);
    try writer.writeAll(reset);
    is_image.* = false;

    // Render URL suffix (skip if url equals label)
    if (!std.mem.eql(u8, label, url)) {
        try writer.writeAll(" (");
        try writer.writeAll(dim);
        try writer.writeAll(url);
        try writer.writeAll(reset);
        try writer.writeAll(")");
    }

    // Advance past the entire [label](url) to resume inline parsing
    const after = url_start + url_end + 1;
    start.* = after;
    i.* = after;
}

/// Count visible column width: ASCII/single-width = 1, CJK/fullwidth = 2. Strips ANSI escape codes.
/// Width=2 codepoint ranges: Hangul Jamo, CJK Radicals/Symbols/Punctuation, Hiragana/Katakana/Bopomofo,
/// CJK Unified Extension A, CJK Unified Ideographs, Hangul Syllables, CJK Compatibility Ideographs,
/// Vertical Forms/CJK Compat Forms, Fullwidth ASCII/Punctuation, Fullwidth Signs.
pub fn visibleWidth(text: []const u8) usize {
    var w: usize = 0;
    var i: usize = 0;
    var need_emoji_promotion: bool = false;
    while (i < text.len) {
        if (text[i] == '\x1b') {
            while (i < text.len and text[i] != 'm') : (i += 1) {}
            i += 1;
            continue;
        }
        if (text[i] < 0x80) {
            w += 1;
            need_emoji_promotion = false;
            i += 1;
        } else {
            const len = std.unicode.utf8ByteSequenceLength(text[i]) catch {
                w += 1;
                need_emoji_promotion = false;
                i += 1;
                continue;
            };
            if (i + len > text.len) {
                w += 1;
                need_emoji_promotion = false;
                i = text.len;
                continue;
            }
            const cp = std.unicode.utf8Decode(text[i..i+len]) catch {
                w += 1;
                need_emoji_promotion = false;
                i += len;
                continue;
            };
            // Variation Selectors: FE0F promotes preceding single-width to emoji (1→2)
            if (cp >= 0xFE00 and cp <= 0xFE0F) {
                if (need_emoji_promotion) {
                    w += 1;
                    need_emoji_promotion = false;
                }
                i += len;
                continue;
            }
            need_emoji_promotion = false;
            // Regional Indicators (U+1F1E6-U+1F1FF): each is width 1, a pair=flag has width 2
            if (cp >= 0x1F1E6 and cp <= 0x1F1FF) {
                w += 1;
                i += len;
                continue;
            }
            if (isCjkWidth(cp)) {
                w += 2;
            } else {
                w += 1;
                need_emoji_promotion = true;
            }
            i += len;
        }
    }
    return w;
}

/// Returns true if codepoint is CJK, fullwidth, or emoji (visible width 2). Based on Unicode East Asian Width ranges + emoji Supplement.
pub fn isCjkWidth(cp: u21) bool {
    return (cp >= 0x1100 and cp <= 0x115F) or // Hangul Jamo
        (cp >= 0x2E80 and cp <= 0x303E) or // CJK Radicals/Kangxi/Symbols/Punctuation
        (cp >= 0x3040 and cp <= 0x33BF) or // Hiragana/Katakana/Bopomofo/Compat
        (cp >= 0x3400 and cp <= 0x4DBF) or // CJK Unified Extension A
        (cp >= 0x4E00 and cp <= 0x9FFF) or // CJK Unified Ideographs (core)
        (cp >= 0xAC00 and cp <= 0xD7AF) or // Hangul Syllables
        (cp >= 0xF900 and cp <= 0xFAFF) or // CJK Compatibility Ideographs
        (cp >= 0xFE10 and cp <= 0xFE1F) or // Vertical Forms
        (cp >= 0xFE30 and cp <= 0xFE4F) or // CJK Compatibility Forms
        (cp >= 0xFE50 and cp <= 0xFE6F) or // Small Form Variants
        (cp >= 0xFF01 and cp <= 0xFF60) or // Fullwidth ASCII/Punctuation
        (cp >= 0xFFE0 and cp <= 0xFFE6) or // Fullwidth Signs
        (cp >= 0x1F300 and cp <= 0x1F9FF) or // Misc Symbols/Dingbats/Emoticons/Supplemental (wide)
        (cp >= 0x2B50 and cp <= 0x2B59) or // Star + circle + misc shapes (⭐🌟●)
        (cp == 0x2648) or // Aries (♈) — renders emoji width 2 in most terminals
        (cp == 0x26A1) or // High voltage (⚡)
        (cp == 0x26BD); // Soccer ball (⚽)
}

// ============================================================================
// Tests
// ============================================================================

test "visibleWidth: CJK vs em dash" {
    // Em dash (U+2014, 3-byte UTF-8) is single-width
    try std.testing.expectEqual(@as(usize, 1), visibleWidth("—"));
    // CJK character (U+4E2D, 3-byte UTF-8) is double-width
    try std.testing.expectEqual(@as(usize, 2), visibleWidth("中"));
    // Two CJK characters
    try std.testing.expectEqual(@as(usize, 4), visibleWidth("中文"));
}

test "visibleWidth: ANSI escapes" {
    try std.testing.expectEqual(@as(usize, 5), visibleWidth("\x1b[31mhello\x1b[0m"));
    try std.testing.expectEqual(@as(usize, 2), visibleWidth("\x1b[1m中\x1b[0m"));
    try std.testing.expectEqual(@as(usize, 0), visibleWidth("\x1b[0m"));
}

test "visibleWidth: empty" {
    try std.testing.expectEqual(@as(usize, 0), visibleWidth(""));
}

test "visibleWidth: ASCII only" {
    try std.testing.expectEqual(@as(usize, 5), visibleWidth("hello"));
}

test "visibleWidth: mixed CJK and ASCII" {
    try std.testing.expectEqual(@as(usize, 4), visibleWidth("a中b"));
}

test "visibleWidth: star emoji is width 2" {
    try std.testing.expectEqual(@as(usize, 2), visibleWidth("⭐"));
}

test "visibleWidth: invalid UTF-8" {
    try std.testing.expectEqual(@as(usize, 1), visibleWidth("\xFF"));          // invalid leading byte
    try std.testing.expectEqual(@as(usize, 1), visibleWidth("\xE4\xB8"));      // truncated 3-byte sequence
    try std.testing.expectEqual(@as(usize, 1), visibleWidth("\xE4\xB8\xFF"));  // invalid continuation byte
}
