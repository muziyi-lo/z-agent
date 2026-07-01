const std = @import("std");
const tokenizer = @import("tokenizer.zig");
const renderer = @import("renderer.zig");

const LineIterator = std.mem.SplitIterator(u8, .sequence);

const MAX_TABLE_COLS = 20;
const MAX_TABLE_ROWS = 80;

const MAX_WRAP_LINES = 32;
const WrapSegment = struct { start: usize, end: usize };

/// Word-wrap text at spaces; force-breaks overlong words (URLs, CJK) at char boundaries.
/// Fills segments array, returns count. No allocation.
/// When max_vis_width is 0, returns single segment (no wrapping).
fn wrapCellText(text: []const u8, max_vis_width: usize, segments: *[MAX_WRAP_LINES]WrapSegment) usize {
    if (max_vis_width == 0 or text.len == 0) {
        segments[0] = .{ .start = 0, .end = text.len };
        return 1;
    }

    var count: usize = 0;
    var line_start: usize = 0;
    var line_vis: usize = 0;
    var word_end_pos: usize = 0;

    var it = std.mem.splitScalar(u8, text, ' ');
    while (it.next()) |word| {
        if (count >= MAX_WRAP_LINES) break;
        if (word.len == 0) continue;

        const w_start = @intFromPtr(word.ptr) - @intFromPtr(text.ptr);
        const w_vis = renderer.visibleWidth(word);

        if (line_vis == 0) {
            // First word on current line
            if (w_vis > max_vis_width) {
                // Force-break this word at character boundaries
                count = forceBreakWord(text, w_start, w_start + word.len, max_vis_width, segments, count);
                // After force-break, no pending content on this "line"
                line_vis = 0;
                line_start = 0;
                word_end_pos = 0;
            } else {
                line_start = w_start;
                line_vis = w_vis;
                word_end_pos = w_start + word.len;
            }
        } else {
            const candidate_vis = line_vis + 1 + w_vis;
            if (candidate_vis > max_vis_width) {
                // Wrap: emit accumulated line, start new line with this word
                segments[count] = .{ .start = line_start, .end = word_end_pos };
                count += 1;
                if (count >= MAX_WRAP_LINES) break;

                if (w_vis > max_vis_width) {
                    count = forceBreakWord(text, w_start, w_start + word.len, max_vis_width, segments, count);
                    line_vis = 0;
                    line_start = 0;
                    word_end_pos = 0;
                } else {
                    line_start = w_start;
                    line_vis = w_vis;
                    word_end_pos = w_start + word.len;
                }
            } else {
                line_vis = candidate_vis;
                word_end_pos = w_start + word.len;
            }
        }
    }

    // Trailing segment: only if content is pending on current line
    if (line_vis > 0 and count < MAX_WRAP_LINES) {
        segments[count] = .{ .start = line_start, .end = word_end_pos };
        count += 1;
    }

    // Handle all-spaces / empty input
    if (count == 0) {
        segments[0] = .{ .start = 0, .end = text.len };
        return 1;
    }

    return count;
}

/// Force-break a single word at character boundaries. Returns updated count.
fn forceBreakWord(text: []const u8, w_start: usize, w_end: usize, max_vis_width: usize, segments: *[MAX_WRAP_LINES]WrapSegment, start_count: usize) usize {
    var count = start_count;
    var seg_start = w_start;
    var i = w_start;
    var vis: usize = 0;
    while (i < w_end) {
        if (count >= MAX_WRAP_LINES) break;
        const cp_len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        const safe_len = @min(cp_len, w_end - i);
        const cp_vis = charVisWidth(text[i..], safe_len);
        if (vis + cp_vis > max_vis_width and vis > 0) {
            segments[count] = .{ .start = seg_start, .end = i };
            count += 1;
            seg_start = i;
            vis = cp_vis;
        } else {
            vis += cp_vis;
        }
        i += safe_len;
    }
    if (vis > 0 and count < MAX_WRAP_LINES) {
        segments[count] = .{ .start = seg_start, .end = w_end };
        count += 1;
    }
    return count;
}

/// Visible width of a single UTF-8 character at bytes[0..byte_len).
fn charVisWidth(bytes: []const u8, byte_len: usize) usize {
    if (byte_len == 1 and bytes[0] < 0x80) return 1;
    if (byte_len >= 3) {
        const cp = std.unicode.utf8Decode(bytes[0..byte_len]) catch return 1;
        return if (renderer.isCjkWidth(cp)) 2 else 1;
    }
    return 1;
}

/// Render markdown text to ANSI-styled output via writer. Line slices borrowed from input; caller owns markdown buffer, must not free during render. No allocation, no word-wrap (max_width=0).
pub fn render(writer: anytype, markdown: []const u8) !void {
    try renderWithWidth(writer, markdown, 0);
}

/// Like render, but with max_width > 0 enables column-width capping and word-wrap for tables.
pub fn renderWithWidth(writer: anytype, markdown: []const u8, max_width: usize) !void {
    var lines = std.mem.splitSequence(u8, markdown, "\n");
    var peek: ?[]const u8 = null;
    while (true) {
        const raw = peek orelse lines.next() orelse break;
        peek = null;
        const line = if (raw.len > 0 and raw[raw.len - 1] == '\r') raw[0 .. raw.len - 1] else raw;
        try renderLine(writer, line, &lines, &peek, max_width);
    }
}

/// Render a single line of markdown. Lines parameter is for code block multi-line collection.
fn renderLine(writer: anytype, line: []const u8, lines: *LineIterator, peek: *?[]const u8, max_width: usize) !void {
    if (line.len == 0) {
        try writer.writeAll("\n");
        return;
    }

    if (tokenizer.isHeading(line)) |level| {
        try renderer.renderHeading(writer, line, level);
        return;
    }
    if (tokenizer.isBlockquote(line)) |content| {
        try renderer.renderBlockquote(writer, content);
        return;
    }
    if (tokenizer.isCodeFence(line)) |lang| {
        try renderer.renderCodeFenceOpen(writer, lang);
        // Collect inner lines until closing fence or EOF
        while (lines.next()) |inner| {
            if (tokenizer.isCodeFence(inner) != null) {
                try renderer.renderCodeFenceClose(writer);
                break;
            }
            try renderer.renderCodeContent(writer, inner);
        }
        return;
    }
    // Table detection: check if line is a table data row followed by a delimiter
    {
        var header_cells: [MAX_TABLE_COLS][]const u8 = undefined;
        const ncols = tokenizer.parseTableDataRow(line, &header_cells);
        if (ncols > 0) {
            const next_raw = peek.* orelse lines.next() orelse null;
            if (next_raw) |nr| {
                const next_line = if (nr.len > 0 and nr[nr.len - 1] == '\r') nr[0 .. nr.len - 1] else nr;
                var aligns: [MAX_TABLE_COLS]tokenizer.Align = undefined;
                const ac = tokenizer.parseTableDelimiterRow(next_line, &aligns);
                if (ac == ncols) {
                    peek.* = null; // consumed delimiter
                    try renderTable(writer, lines, peek, header_cells[0..ncols], aligns[0..ncols], ncols, max_width);
                    return;
                }
                peek.* = nr; // put back — not a delimiter
            }
            // Fall through: not a table, render as normal
        }
    }
    if (tokenizer.isHr(line)) {
        try renderer.renderHr(writer);
        return;
    }
    if (tokenizer.isTaskList(line)) |_| {
        peek.* = line;
        try renderList(writer, lines, peek, 0);
        return;
    }
    if (tokenizer.isUnorderedList(line)) |_| {
        peek.* = line;
        try renderList(writer, lines, peek, 0);
        return;
    }
    if (tokenizer.isOrderedList(line)) |_| {
        peek.* = line;
        try renderList(writer, lines, peek, 0);
        return;
    }

    // 普通段落：内联样式处理
    try renderer.renderParagraph(writer, line);
}

/// Recursively render list items at the given indent level. Handles nested lists, ordered auto-increment, and mixed list types.
fn renderList(writer: anytype, lines: *LineIterator, peek: *?[]const u8, indent: usize) !void {
    var ordered_idx: u32 = 1;
    var ordered_base: u32 = 0;
    var in_ordered = false;

    while (true) {
        const raw = peek.* orelse lines.next() orelse break;
        peek.* = null;
        const line = if (raw.len > 0 and raw[raw.len - 1] == '\r') raw[0 .. raw.len - 1] else raw;
        const depth = tokenizer.countIndent(line);

        if (depth < indent) {
            peek.* = line; // back to parent level
            return;
        }

        if (depth > indent) {
            peek.* = line; // put back for recursive call
            try renderList(writer, lines, peek, depth);
            continue;
        }

        // Strip indent spaces, then skip any extra spaces for non-multiple-of-2 indentation
        var trimmed = line[indent * 2 ..];
        while (trimmed.len > 0 and trimmed[0] == ' ') {
            trimmed = trimmed[1..];
        }

        if (tokenizer.isTaskList(trimmed)) |task| {
            in_ordered = false;
            try renderer.renderTaskList(writer, task.checked, task.content, indent);
        } else if (tokenizer.isOrderedList(trimmed)) |item| {
            if (!in_ordered) {
                in_ordered = true;
                ordered_base = item.number;
                ordered_idx = 1;
            }
            try renderer.renderOrderedList(writer, ordered_base + ordered_idx - 1, item.content, indent);
            ordered_idx += 1;
        } else if (tokenizer.isUnorderedList(trimmed)) |content| {
            in_ordered = false;
            try renderer.renderUnorderedList(writer, content, indent);
        } else {
            peek.* = line; // not a list item — back to renderLine
            return;
        }
    }
}

/// Compute maximum visible width for each column across all table rows. No allocation.
fn computeTableColWidths(
    all_cells: [MAX_TABLE_ROWS][MAX_TABLE_COLS][]const u8,
    nrows: usize,
    ncols: usize,
    col_widths: *[MAX_TABLE_COLS]usize,
) void {
    for (0..nrows) |ri| {
        for (0..ncols) |j| {
            const w = renderer.visibleWidth(all_cells[ri][j]);
            if (w > col_widths[j]) col_widths[j] = w;
        }
    }
}

/// Render a table border line: left + (─ * col_width) + mid + ⋯ + right, dim wrapped. No allocation.
fn renderTableBorder(
    writer: anytype,
    ncols: usize,
    col_widths: []const usize,
    left: []const u8,
    mid: []const u8,
    right: []const u8,
) !void {
    const dim_ansi = "\x1b[2m";
    const reset_ansi = "\x1b[0m";
    try writer.writeAll(dim_ansi);
    try writer.writeAll(left);
    for (0..ncols) |j| {
        if (j > 0) try writer.writeAll(mid);
        const w = col_widths[j] + 2;
        var k: usize = 0;
        while (k < w) : (k += 1) {
            try writer.writeAll("─");
        }
    }
    try writer.writeAll(right);
    try writer.writeAll(reset_ansi);
    try writer.writeAll("\n");
}

/// Render a table data row with word-wrap support. Returns number of physical lines rendered. No allocation.
fn renderTableRow(
    writer: anytype,
    ncols: usize,
    col_widths: []const usize,
    aligns: []const tokenizer.Align,
    cells: []const []const u8,
    is_header: bool,
) !usize {
    const dim_ansi = "\x1b[2m";
    const bold_ansi = "\x1b[1m";
    const reset_ansi = "\x1b[0m";

    var line_counts: [MAX_TABLE_COLS]usize = [_]usize{0} ** MAX_TABLE_COLS;
    var segments: [MAX_TABLE_COLS][MAX_WRAP_LINES]WrapSegment = undefined;
    var max_lines: usize = 0;

    for (0..ncols) |j| {
        const cnt = wrapCellText(cells[j], col_widths[j], &segments[j]);
        line_counts[j] = cnt;
        if (cnt > max_lines) max_lines = cnt;
    }
    if (max_lines == 0) max_lines = 1;

    for (0..max_lines) |li| {
        try writer.writeAll(dim_ansi);
        try writer.writeAll("│");
        try writer.writeAll(reset_ansi);

        for (0..ncols) |j| {
            if (j > 0) {
                try writer.writeAll(dim_ansi);
                try writer.writeAll("│");
                try writer.writeAll(reset_ansi);
            }

            try writer.writeAll(" ");

            if (li < line_counts[j]) {
                const seg = segments[j][li];
                const seg_text = cells[j][seg.start..seg.end];
                if (is_header) {
                    try writer.writeAll(bold_ansi);
                    try writeAligned(writer, seg_text, col_widths[j], aligns[j], renderer.visibleWidth(seg_text));
                    try writer.writeAll(" ");
                    try writer.writeAll(reset_ansi);
                } else {
                    var cell_buf: [4096]u8 = undefined;
                    var cell_w: std.Io.Writer = .fixed(&cell_buf);
                    const rendered: []const u8 = blk: {
                        renderer.renderInline(&cell_w, seg_text) catch {
                            // safe fallback: content preserved but inline style lost
                            break :blk seg_text;
                        };
                        break :blk cell_w.buffered();
                    };
                    const vis_w = renderer.visibleWidth(rendered);
                    try writeAligned(writer, rendered, col_widths[j], aligns[j], vis_w);
                    try writer.writeAll(reset_ansi);
                    try writer.writeAll(" ");
                }
            } else {
                if (is_header) {
                    try writer.writeAll(bold_ansi);
                }
                var k: usize = 0;
                while (k < col_widths[j]) : (k += 1) {
                    try writer.writeAll(" ");
                }
                if (is_header) {
                    try writer.writeAll(" ");
                    try writer.writeAll(reset_ansi);
                } else {
                    try writer.writeAll(reset_ansi);
                    try writer.writeAll(" ");
                }
            }
        }

        try writer.writeAll(dim_ansi);
        try writer.writeAll("│");
        try writer.writeAll(reset_ansi);
        try writer.writeAll("\n");
    }

    return max_lines;
}

/// Render a markdown table with box-drawing characters. header_cells and aligns slices must have ncols elements.
/// When max_width > 0, cells wrap at word boundaries. No allocation.
fn renderTable(
    writer: anytype,
    lines: *LineIterator,
    peek: *?[]const u8,
    header_cells: []const []const u8,
    aligns: []const tokenizer.Align,
    ncols: usize,
    max_width: usize,
) !void {
    // Collect all rows: header (row 0) + data rows
    var all_cells: [MAX_TABLE_ROWS][MAX_TABLE_COLS][]const u8 = undefined;
    var nrows: usize = 0;

    for (0..ncols) |j| {
        all_cells[0][j] = header_cells[j];
    }
    nrows = 1;

    // Collect data rows
    while (nrows < MAX_TABLE_ROWS) {
        const raw = peek.* orelse lines.next() orelse break;
        peek.* = null;
        const row_line = if (raw.len > 0 and raw[raw.len - 1] == '\r') raw[0 .. raw.len - 1] else raw;

        var cells: [MAX_TABLE_COLS][]const u8 = undefined;
        const count = tokenizer.parseTableDataRow(row_line, &cells);
        if (count == 0 or count != ncols) {
            peek.* = raw;
            break;
        }
        for (0..ncols) |j| {
            all_cells[nrows][j] = cells[j];
        }
        nrows += 1;
    }

    // Compute column widths
    var col_widths: [MAX_TABLE_COLS]usize = [_]usize{0} ** MAX_TABLE_COLS;
    computeTableColWidths(all_cells, nrows, ncols, &col_widths);

    // Cap column widths if max_width is set
    if (max_width > 0) {
        const overhead = ncols * 3 + 1;
        const available = if (max_width > overhead) max_width - overhead else 1;
        const per_col = @max(if (ncols > 0) available / ncols else available, 3);
        for (0..ncols) |j| {
            if (col_widths[j] > per_col) col_widths[j] = per_col;
        }
    }

    // Top border
    try renderTableBorder(writer, ncols, col_widths[0..ncols], "┌", "┬", "┐");

    // Header row
    _ = try renderTableRow(writer, ncols, col_widths[0..ncols], aligns, all_cells[0][0..ncols], true);

    // Data rows
    for (1..nrows) |ri| {
        try renderTableBorder(writer, ncols, col_widths[0..ncols], "├", "┼", "┤");
        _ = try renderTableRow(writer, ncols, col_widths[0..ncols], aligns, all_cells[ri][0..ncols], false);
    }

    // Bottom border
    try renderTableBorder(writer, ncols, col_widths[0..ncols], "└", "┴", "┘");
}

/// Write cell text aligned within a fixed-width field. padding = width - vis_width spaces.
fn writeAligned(writer: anytype, text: []const u8, width: usize, alignment: tokenizer.Align, vis_width: usize) !void {
    const padding = if (width > vis_width) width - vis_width else 0;
    switch (alignment) {
        .left => {
            try writer.writeAll(text);
            var k: usize = 0;
            while (k < padding) : (k += 1) {
                try writer.writeAll(" ");
            }
        },
        .center => {
            const left_pad = padding / 2;
            var k: usize = 0;
            while (k < left_pad) : (k += 1) {
                try writer.writeAll(" ");
            }
            try writer.writeAll(text);
            k = 0;
            while (k < padding - left_pad) : (k += 1) {
                try writer.writeAll(" ");
            }
        },
        .right => {
            var k: usize = 0;
            while (k < padding) : (k += 1) {
                try writer.writeAll(" ");
            }
            try writer.writeAll(text);
        },
    }
}

// ============================================================================
// Tests
// ============================================================================

test "render: heading" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);

    try render(&w, "# Title");
    const output = w.buffered();

    try std.testing.expect(std.mem.indexOf(u8, output, "\x1b[1m") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\x1b[36m") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Title") != null);
}

test "render: bold inline" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);

    try render(&w, "hello **world** here");
    const output = w.buffered();

    try std.testing.expect(std.mem.indexOf(u8, output, "\x1b[1m") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "world") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "here") != null);
}

test "render: italic inline" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);

    try render(&w, "this is *italic* text");
    const output = w.buffered();

    try std.testing.expect(std.mem.indexOf(u8, output, "\x1b[3m") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "italic") != null);
}

test "render: blockquote" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);

    try render(&w, "> quoted text");
    const output = w.buffered();

    try std.testing.expect(std.mem.indexOf(u8, output, "\x1b[36m") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\xe2\x94\x83") != null); // "┃" U+2503
    try std.testing.expect(std.mem.indexOf(u8, output, "quoted text") != null);
}

test "render: code inline" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);

    try render(&w, "use `malloc` for allocation");
    const output = w.buffered();

    try std.testing.expect(std.mem.indexOf(u8, output, "\x1b[33m") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "malloc") != null);
}

test "render: code fence" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);

    try render(&w, "```zig");
    const output = w.buffered();

    try std.testing.expect(std.mem.indexOf(u8, output, "\x1b[2m") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\xe2\x94\x8c\xe2\x94\x80") != null); // "┌─"
    try std.testing.expect(std.mem.indexOf(u8, output, "zig") != null);
}

test "render: hr" {
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);

    try render(&w, "---");
    const output = w.buffered();

    try std.testing.expect(std.mem.indexOf(u8, output, "\x1b[2m") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\xe2\x94\x80") != null); // "─"
}

test "render: hr with underscores" {
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);

    try render(&w, "___");
    const output = w.buffered();

    try std.testing.expect(std.mem.indexOf(u8, output, "\x1b[2m") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\xe2\x94\x80") != null); // "─"
}

test "render: unordered list" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);

    try render(&w, "- **bold** item");
    const output = w.buffered();

    try std.testing.expect(std.mem.indexOf(u8, output, "\xe2\x80\xa2") != null); // "•"
    try std.testing.expect(std.mem.indexOf(u8, output, "\x1b[36m") != null); // cyan bullet
    try std.testing.expect(std.mem.indexOf(u8, output, "\x1b[1m") != null); // bold
    try std.testing.expect(std.mem.indexOf(u8, output, "bold") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "item") != null);
    // Literal ** markers should NOT appear
    try std.testing.expect(std.mem.indexOf(u8, output, "**") == null);
}

test "render: paragraph plain" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);

    try render(&w, "just plain text");
    const output = w.buffered();

    try std.testing.expect(std.mem.indexOf(u8, output, "just plain text") != null);
}

test "render: empty input" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);

    try render(&w, "");
    const output = w.buffered();

    // Empty input: splitSequence("") yields one empty slice → triggers "\n"
    try std.testing.expect(std.mem.indexOf(u8, output, "\n") != null);
}

test "render: hash without space is not heading" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);

    // "#not-a-heading" should render as plain text, not bold
    try render(&w, "#not-a-heading");
    const output = w.buffered();

    // Should NOT contain bold ANSI code
    try std.testing.expect(std.mem.indexOf(u8, output, "\x1b[1m") == null);
    // Should contain the text as-is
    try std.testing.expect(std.mem.indexOf(u8, output, "#not-a-heading") != null);
}

test "render: code block collects multi-line content" {
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);

    try render(&w,
        \\```zig
        \\const x = 1;
        \\const y = 2;
        \\```
    );
    const output = w.buffered();

    // Content lines should appear
    try std.testing.expect(std.mem.indexOf(u8, output, "const x = 1;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "const y = 2;") != null);
    // Content lines should have "│ " prefix (box-drawing pipe)
    try std.testing.expect(std.mem.indexOf(u8, output, "\xe2\x94\x82") != null); // "│"
    // Fence markers should be present (open + close with matching width)
    try std.testing.expect(std.mem.indexOf(u8, output, "zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\xe2\x94\x8c") != null); // "┌" open
    try std.testing.expect(std.mem.indexOf(u8, output, "\xe2\x94\x94") != null); // "└" close
}

test "render: code block with tilde fence" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);

    try render(&w,
        \\~~~
        \\tilde content
        \\~~~
    );
    const output = w.buffered();

    // Content should appear with "│ " prefix
    try std.testing.expect(std.mem.indexOf(u8, output, "tilde content") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\xe2\x94\x82 ") != null); // "│ "
    // Fence markers should be present
    try std.testing.expect(std.mem.indexOf(u8, output, "\xe2\x94\x8c") != null); // "┌"
}

test "render: code block empty" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);

    try render(&w,
        \\```
        \\```
    );
    const output = w.buffered();

    // Two fence markers should be present (open and close)
    try std.testing.expect(std.mem.indexOf(u8, output, "\xe2\x94\x8c") != null); // "┌" open
    try std.testing.expect(std.mem.indexOf(u8, output, "\xe2\x94\x94") != null); // "└" close
}

test "render: code block with lang" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);

    try render(&w,
        \\```javascript
        \\console.log("hi");
        \\```
    );
    const output = w.buffered();

    // Lang label should appear next to fence
    try std.testing.expect(std.mem.indexOf(u8, output, "javascript") != null);
    // Content should appear with "│ " prefix
    try std.testing.expect(std.mem.indexOf(u8, output, "console.log") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\xe2\x94\x82") != null); // "│"
}

test "render: code block no closing fence reaches EOF" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);

    try render(&w,
        \\```
        \\orphaned content
    );
    const output = w.buffered();

    // Content after opening fence (no closing) should be rendered as code content
    try std.testing.expect(std.mem.indexOf(u8, output, "orphaned content") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\xe2\x94\x82 ") != null); // "│ "
    // Opening fence should be present
    try std.testing.expect(std.mem.indexOf(u8, output, "\xe2\x94\x8c") != null); // "┌"
}

test "render: CRLF line endings stripped" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);

    try render(&w, "# Title\r\n- item\r\n");
    const output = w.buffered();

    // "Title" should appear without trailing \r
    try std.testing.expect(std.mem.indexOf(u8, output, "Title") != null);
    // "item" should appear without trailing \r
    try std.testing.expect(std.mem.indexOf(u8, output, "item") != null);
    // bullet should appear
    try std.testing.expect(std.mem.indexOf(u8, output, "\xe2\x80\xa2") != null); // "•"
}

test "render: ordered list single item" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);

    try render(&w, "1. first item");
    const output = w.buffered();

    try std.testing.expect(std.mem.indexOf(u8, output, "1.") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "first item") != null);
}

test "render: ordered list multiple items auto-increment" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);

    // Both source items use "1." — auto-increment should output 1. and 2.
    try render(&w,
        \\1. alpha
        \\1. beta
    );
    const output = w.buffered();

    // First item: " 1. alpha"
    try std.testing.expect(std.mem.indexOf(u8, output, "alpha") != null);
    // Second item: " 2. beta" (auto-incremented from 1 to 2)
    try std.testing.expect(std.mem.indexOf(u8, output, "2.") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "beta") != null);
}

test "render: ordered list multiple items with varying source numbers" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);

    // Source numbers are 5, 1, 99 — all ignored; auto-increment from first (5)
    try render(&w,
        \\5. apple
        \\1. banana
        \\99. cherry
    );
    const output = w.buffered();

    // First item: 5. (uses start number from first item)
    try std.testing.expect(std.mem.indexOf(u8, output, "5.") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "apple") != null);
    // Second item: 6. (auto-incremented)
    try std.testing.expect(std.mem.indexOf(u8, output, "6.") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "banana") != null);
    // Third item: 7. (auto-incremented)
    try std.testing.expect(std.mem.indexOf(u8, output, "7.") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "cherry") != null);
}

test "render: ordered list with inline bold" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);

    try render(&w, "1. hello **world** here");
    const output = w.buffered();

    try std.testing.expect(std.mem.indexOf(u8, output, "1.") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\x1b[1m") != null); // bold ANSI
    try std.testing.expect(std.mem.indexOf(u8, output, "world") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "here") != null);
    // Literal ** markers should NOT appear (parsed, not raw)
    try std.testing.expect(std.mem.indexOf(u8, output, "**") == null);
}

test "render: ordered list not a match when no space after dot" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);

    // "1.no-space" is NOT an ordered list item — should render as paragraph
    try render(&w, "1.no-space");
    const output = w.buffered();

    // Should render as plain paragraph, not have "1." prefix pattern
    try std.testing.expect(std.mem.indexOf(u8, output, "1.no-space") != null);
    // Should NOT have the ordered list number prefix " 1. " (with spaces around)
    try std.testing.expect(std.mem.indexOf(u8, output, " 1. ") == null);
}

test "render: ordered list non-list line after list is rendered" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);

    try render(&w,
        \\1. list item
        \\plain paragraph
    );
    const output = w.buffered();

    try std.testing.expect(std.mem.indexOf(u8, output, "list item") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "plain paragraph") != null);
}

test "render: strikethrough" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);

    try render(&w, "this is ~~deleted~~ text");
    const output = w.buffered();

    try std.testing.expect(std.mem.indexOf(u8, output, "\x1b[9m") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "deleted") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "this is") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "text") != null);
}

test "render: strikethrough with whitespace constraint" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);

    // ~~ with trailing space should NOT toggle strikethrough
    try render(&w, "~~ no strike ~~ not active");
    const output = w.buffered();

    // Should NOT contain SGR 9 (strikethrough)
    try std.testing.expect(std.mem.indexOf(u8, output, "\x1b[9m") == null);
    // The text should appear as-is
    try std.testing.expect(std.mem.indexOf(u8, output, "~~ no strike ~~ not active") != null);
}

test "render: link text and url" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);

    try render(&w, "see [the docs](https://example.com) for more");
    const output = w.buffered();

    // Label should be rendered with blue + underline
    try std.testing.expect(std.mem.indexOf(u8, output, "\x1b[34m") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\x1b[4m") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "the docs") != null);
    // URL suffix should appear in dim (label != url)
    try std.testing.expect(std.mem.indexOf(u8, output, "https://example.com") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, " (") != null);
    // Surrounding text should be present
    try std.testing.expect(std.mem.indexOf(u8, output, "see") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "for more") != null);
}

test "render: link text equals url dedup" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);

    try render(&w, "visit [https://ziglang.org](https://ziglang.org) now");
    const output = w.buffered();

    // Label should be rendered with blue + underline
    try std.testing.expect(std.mem.indexOf(u8, output, "\x1b[34m") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\x1b[4m") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "https://ziglang.org") != null);
    // URL suffix should NOT appear (label == url)
    try std.testing.expect(std.mem.indexOf(u8, output, " (") == null);
}

test "render: image renders alt text dim+italic" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);

    try render(&w, "see ![logo](img.png) here");
    const output = w.buffered();

    // Alt text should be dim+italic
    try std.testing.expect(std.mem.indexOf(u8, output, "\x1b[2m") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\x1b[3m") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "logo") != null);
    // URL should show for user to inspect
    try std.testing.expect(std.mem.indexOf(u8, output, "img.png") != null);
    // Surrounding text preserved
    try std.testing.expect(std.mem.indexOf(u8, output, "see") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "here") != null);
}

test "render: nested unordered list" {
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try render(&w,
        \\- item 1
        \\  - sub a
        \\  - sub b
        \\- item 2
    );
    const output = w.buffered();
    // item 1 visible
    try std.testing.expect(std.mem.indexOf(u8, output, "item 1") != null);
    // sub a visible (deeper indent)
    try std.testing.expect(std.mem.indexOf(u8, output, "sub a") != null);
    // sub b visible
    try std.testing.expect(std.mem.indexOf(u8, output, "sub b") != null);
    // item 2 visible
    try std.testing.expect(std.mem.indexOf(u8, output, "item 2") != null);
    // All should have bullets (at least 4 bullets: item1, item2, sub a, sub b)
    var bullet_count: usize = 0;
    var i: usize = 0;
    while (i < output.len) {
        const pos = std.mem.indexOf(u8, output[i..], "\xe2\x80\xa2") orelse break;
        bullet_count += 1;
        i += pos + 3;
    }
    try std.testing.expect(bullet_count >= 4);
}

test "render: nested ordered list" {
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try render(&w,
        \\1. first
        \\   1. nested a
        \\   2. nested b
        \\2. second
    );
    const output = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "first") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "second") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "nested a") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "nested b") != null);
}

test "render: mixed nested list" {
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try render(&w,
        \\- unordered
        \\  1. ordered inside
        \\  2. item two
        \\- back to unordered
    );
    const output = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "unordered") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "ordered inside") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "item two") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "back to unordered") != null);
}

test "render: task list unchecked" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try render(&w, "- [ ] todo item");
    const output = w.buffered();
    // unchecked marker cube
    try std.testing.expect(std.mem.indexOf(u8, output, "\xe2\x96\xa1") != null); // "□"
    try std.testing.expect(std.mem.indexOf(u8, output, "todo item") != null);
    // Should NOT have strikethrough
    try std.testing.expect(std.mem.indexOf(u8, output, "\x1b[9m") == null);
}

test "render: task list checked" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try render(&w, "- [x] done item");
    const output = w.buffered();
    // checked marker
    try std.testing.expect(std.mem.indexOf(u8, output, "\xe2\x9c\x93") != null); // "✓"
    try std.testing.expect(std.mem.indexOf(u8, output, "done item") != null);
    // Should have strikethrough for checked
    try std.testing.expect(std.mem.indexOf(u8, output, "\x1b[9m") != null);
}

test "render: task list with inline formatting" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try render(&w, "- [x] ~~done~~ and `code`");
    const output = w.buffered();
    // inline formatting still works in task content
    try std.testing.expect(std.mem.indexOf(u8, output, "\x1b[9m") != null); // strikethrough via ~~
    try std.testing.expect(std.mem.indexOf(u8, output, "done") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "code") != null);
}

test "render: simple table" {
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try render(&w,
        \\| col1 | col2  |
        \\|------|-------|
        \\| a    | b     |
        \\| c    | **d** |
    );
    const output = w.buffered();
    // Box-drawing characters
    try std.testing.expect(std.mem.indexOf(u8, output, "\xe2\x94\x8c") != null); // "┌"
    try std.testing.expect(std.mem.indexOf(u8, output, "\xe2\x94\x94") != null); // "└"
    // Header cells in bold
    try std.testing.expect(std.mem.indexOf(u8, output, "\x1b[1m") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "col1") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "col2") != null);
    // Data cells
    try std.testing.expect(std.mem.indexOf(u8, output, "a") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "b") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "c") != null);
    // Inline bold in table cell: "d" should be bold, no literal ** markers
    try std.testing.expect(std.mem.indexOf(u8, output, "d") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "**") == null);
}

test "render: table with alignment" {
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try render(&w,
        \\| left   | center  | right |
        \\|:-------|:-------:|------:|
        \\| L      |   **C** |     R |
    );
    const output = w.buffered();
    // All alignments should render
    try std.testing.expect(std.mem.indexOf(u8, output, "left") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "center") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "right") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "L") != null);
    // Inline bold in table cell: "C" should be bold, no literal ** markers
    try std.testing.expect(std.mem.indexOf(u8, output, "C") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "**") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "R") != null);
    // Box-drawing should be present
    try std.testing.expect(std.mem.indexOf(u8, output, "\xe2\x94\x8c") != null); // "┌"
    try std.testing.expect(std.mem.indexOf(u8, output, "\xe2\x94\x94") != null); // "└"
}

test "render: table long cell no wrap when max_width=0" {
    // Build a table with a long sentence that wraps when max_width is set
    var md_buf: [512]u8 = undefined;
    const hdr: []const u8 = "| h1 | h2 |\n";
    const del: []const u8 = "|---|---|\n";
    const row: []const u8 = "| s | this is a long sentence that should wrap |\n";
    @memcpy(md_buf[0..hdr.len], hdr);
    @memcpy(md_buf[hdr.len..hdr.len+del.len], del);
    @memcpy(md_buf[hdr.len+del.len..hdr.len+del.len+row.len], row);
    const total = hdr.len + del.len + row.len;

    var buf: [2048]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);

    try render(&w, md_buf[0..total]);
    const output = w.buffered();
    // With max_width=0 (no wrapping), all content appears in one row
    try std.testing.expect(std.mem.indexOf(u8, output, "\xe2\x94\x8c") != null); // "┌"
    try std.testing.expect(std.mem.indexOf(u8, output, "\xe2\x94\x94") != null); // "└"
    try std.testing.expect(std.mem.indexOf(u8, output, "h1") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "h2") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "s") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "long") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "sentence") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "should") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "wrap") != null);
}

test "wrapCellText: word wrap at boundary" {
    var segments: [MAX_WRAP_LINES]WrapSegment = undefined;
    const text = "hello world foo bar";
    const count = wrapCellText(text, 10, &segments);
    try std.testing.expect(count >= 2);
    try std.testing.expectEqual(@as(usize, 0), segments[0].start);
    try std.testing.expectEqual(@as(usize, 5), segments[0].end);
    try std.testing.expectEqualSlices(u8, "hello", text[segments[0].start..segments[0].end]);
    try std.testing.expectEqual(@as(usize, 6), segments[1].start);
}

test "wrapCellText: max_width=0 returns single segment" {
    var segments: [MAX_WRAP_LINES]WrapSegment = undefined;
    const text = "hello world foo bar";
    const count = wrapCellText(text, 0, &segments);
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqual(@as(usize, 0), segments[0].start);
    try std.testing.expectEqual(@as(usize, text.len), segments[0].end);
}

test "wrapCellText: empty text" {
    var segments: [MAX_WRAP_LINES]WrapSegment = undefined;
    const count = wrapCellText("", 10, &segments);
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqual(@as(usize, 0), segments[0].start);
    try std.testing.expectEqual(@as(usize, 0), segments[0].end);
}

test "wrapCellText: short text no wrap" {
    var segments: [MAX_WRAP_LINES]WrapSegment = undefined;
    const text = "short";
    const count = wrapCellText(text, 10, &segments);
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqual(@as(usize, 0), segments[0].start);
    try std.testing.expectEqual(@as(usize, 5), segments[0].end);
}

test "wrapCellText: consecutive spaces skipped" {
    var segments: [MAX_WRAP_LINES]WrapSegment = undefined;
    const text = "hello   world";
    const count = wrapCellText(text, 10, &segments);
    try std.testing.expect(count >= 1);
}

test "wrapCellText: all-spaces returns valid segment" {
    var segments: [MAX_WRAP_LINES]WrapSegment = undefined;
    const text = "   ";
    const count = wrapCellText(text, 5, &segments);
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqual(@as(usize, 0), segments[0].start);
    try std.testing.expectEqual(@as(usize, 3), segments[0].end);
}

test "render: pipe in paragraph not treated as table" {
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try render(&w,
        \\some | pipe | in text
        \\more text here
    );
    const output = w.buffered();
    // Should render as plain paragraph, not table (no box-drawing)
    try std.testing.expect(std.mem.indexOf(u8, output, "\xe2\x94\x8c") == null); // no "┌"
    try std.testing.expect(std.mem.indexOf(u8, output, "pipe") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "more text here") != null);
}

test "render: table header without delimiter not a table" {
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    // | a | b | without a |---| delimiter on next line
    try render(&w,
        \\| a | b |
        \\plain text
    );
    const output = w.buffered();
    // Should NOT render as table (no box-drawing top border)
    try std.testing.expect(std.mem.indexOf(u8, output, "\xe2\x94\x8c") == null); // no "┌"
    // Content should still appear as paragraph
    try std.testing.expect(std.mem.indexOf(u8, output, "a") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "b") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "plain text") != null);
}

test "render: table single column" {
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try render(&w,
        \\| item |
        \\|------|
        \\| one  |
        \\| two  |
    );
    const output = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "\xe2\x94\x8c") != null); // "┌"
    try std.testing.expect(std.mem.indexOf(u8, output, "\xe2\x94\x94") != null); // "└"
    try std.testing.expect(std.mem.indexOf(u8, output, "item") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "one") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "two") != null);
    // Single column: no ┬ ┼ ┴ (no inner junctions)
    try std.testing.expect(std.mem.indexOf(u8, output, "\xe2\x94\xac") == null); // no "┬"
    try std.testing.expect(std.mem.indexOf(u8, output, "\xe2\x94\xbc") == null); // no "┼"
    try std.testing.expect(std.mem.indexOf(u8, output, "\xe2\x94\xb4") == null); // no "┴"
}

test "render: table with column count mismatch skips row" {
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try render(&w,
        \\| a | b |
        \\|---|---|
        \\| 1 | 2 |
        \\| extra | col | here |
        \\| 3 | 4 |
    );
    const output = w.buffered();
    // Valid table rows should appear in box-drawing table
    try std.testing.expect(std.mem.indexOf(u8, output, "1") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "a") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "b") != null);
    // Mismatched row is put back and rendered as paragraph text (with pipes)
    try std.testing.expect(std.mem.indexOf(u8, output, "extra") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "col") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "here") != null);
    // Subsequent line after mismatch re-enters normal rendering
    try std.testing.expect(std.mem.indexOf(u8, output, "3") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "4") != null);
}
