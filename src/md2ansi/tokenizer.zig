const std = @import("std");

/// Table column alignment direction.
pub const Align = enum { left, center, right };

/// Detect # heading — returns heading level (1-6), null if not a heading.
pub fn isHeading(line: []const u8) ?u8 {
    if (line.len < 2) return null;
    if (line[0] != '#') return null;

    var count: u8 = 0;
    var i: usize = 0;
    while (i < line.len and line[i] == '#') : (i += 1) {
        count += 1;
        if (count > 6) return null;
    }
    if (i >= line.len or line[i] != ' ') return null;
    return count;
}

/// Returns content slice after '> ', borrowed from 'line'. null if not a blockquote.
pub fn isBlockquote(line: []const u8) ?[]const u8 {
    if (line.len < 2) return null;
    if (line[0] == '>' and line[1] == ' ') {
        return line[2..];
    }
    return null;
}

/// Returns info string slice borrowed from 'line' (may be ""). null if not a fence.
pub fn isCodeFence(line: []const u8) ?[]const u8 {
    if (line.len < 3) return null;
    if (std.mem.startsWith(u8, line, "```")) {
        return std.mem.trim(u8, line[3..], " ");
    }
    if (std.mem.startsWith(u8, line, "~~~")) {
        return std.mem.trim(u8, line[3..], " ");
    }
    return null;
}

/// Detect --- / *** / ___ horizontal rule (entire line must be same char).
pub fn isHr(line: []const u8) bool {
    if (line.len < 3) return false;
    return (allSameChar(line, '-') or allSameChar(line, '*') or allSameChar(line, '_'));
}

fn allSameChar(s: []const u8, c: u8) bool {
    for (s) |ch| {
        if (ch != c) return false;
    }
    return true;
}

/// Returns content slice after '- ' or '* ', borrowed from 'line'. null if not a list item.
pub fn isUnorderedList(line: []const u8) ?[]const u8 {
    if (line.len < 2) return null;
    if (line[0] == '-' and line[1] == ' ') return line[2..];
    if (line[0] == '*' and line[1] == ' ') return line[2..];
    return null;
}

/// Parse N. content — returns .number (u32) and .content slice borrowed from 'line'. null if not an ordered list item. Caller auto-increments: display_num = start.number + index.
pub fn isOrderedList(line: []const u8) ?struct { number: u32, content: []const u8 } {
    var i: usize = 0;
    while (i < line.len and line[i] >= '0' and line[i] <= '9') : (i += 1) {}
    if (i == 0) return null;
    var n: u32 = 0;
    for (line[0..i]) |c| {
        // Overflow guard: if n > 429496729, next n*10 would overflow u32
        if (n > 429496729) return null;
        n = n * 10 + @as(u32, c - '0');
    }
    if (i >= line.len or line[i] != '.') return null;
    i += 1;
    if (i >= line.len or line[i] != ' ') return null;
    return .{ .number = n, .content = line[i + 1 ..] };
}

/// Count leading spaces (tab→4 spaces), return indent level in 2-space units.
pub fn countIndent(line: []const u8) usize {
    var spaces: usize = 0;
    for (line) |c| {
        if (c == ' ') {
            spaces += 1;
            continue;
        }
        if (c == '\t') {
            spaces += 4;
            continue;
        }
        break;
    }
    return spaces / 2;
}

/// Detect - [ ] (unchecked) / - [x] (checked) task list. Returns .checked and .content slice borrowed from 'line'.
pub fn isTaskList(line: []const u8) ?struct { checked: bool, content: []const u8 } {
    if (line.len < 6) return null;
    if (line[0] != '-' or line[1] != ' ') return null;
    if (line[2] != '[') return null;
    if (line[3] != ' ' and line[3] != 'x' and line[3] != 'X') return null;
    if (line[4] != ']' or line[5] != ' ') return null;
    return .{ .checked = line[3] == 'x' or line[3] == 'X', .content = line[6..] };
}

/// Parse table delimiter row: |---|:---:|---:|. Fills aligns array, returns column count. 0 = not a delimiter. Handles escaped \| inside delimiter segments.
pub fn parseTableDelimiterRow(line: []const u8, aligns: []Align) usize {
    const trimmed = std.mem.trim(u8, line, " ");
    if (trimmed.len < 3 or trimmed[0] != '|' or trimmed[trimmed.len - 1] != '|') return 0;

    const inner = trimmed[1 .. trimmed.len - 1];
    var count: usize = 0;
    var seg_start: usize = 0;
    var i: usize = 0;
    while (i < inner.len) {
        if (inner[i] == '|') {
            if (i > 0 and inner[i - 1] == '\\') {
                i += 1;
                continue;
            }
            if (count >= aligns.len) return 0;
            const p = std.mem.trim(u8, inner[seg_start..i], " ");
            if (p.len == 0) return 0;
            for (p) |c| {
                if (c != ':' and c != '-') return 0;
            }
            const left_colon = p[0] == ':';
            const right_colon = p[p.len - 1] == ':';
            if (left_colon and right_colon) {
                aligns[count] = .center;
            } else if (right_colon) {
                aligns[count] = .right;
            } else {
                aligns[count] = .left;
            }
            count += 1;
            i += 1;
            seg_start = i;
        } else {
            i += 1;
        }
    }
    if (seg_start <= inner.len) {
        if (count >= aligns.len) return 0;
        const p = std.mem.trim(u8, inner[seg_start..], " ");
        if (p.len == 0) return 0;
        for (p) |c| {
            if (c != ':' and c != '-') return 0;
        }
        const left_colon = p[0] == ':';
        const right_colon = p[p.len - 1] == ':';
        if (left_colon and right_colon) {
            aligns[count] = .center;
        } else if (right_colon) {
            aligns[count] = .right;
        } else {
            aligns[count] = .left;
        }
        count += 1;
    }
    return count;
}

/// Parse table data row: | cell | cell |. Fills cells with slices borrowed from line, returns cell count. 0 = not a table data row. Handles escaped \| inside cells.
pub fn parseTableDataRow(line: []const u8, cells: [][]const u8) usize {
    const trimmed = std.mem.trim(u8, line, " ");
    if (trimmed.len < 1 or trimmed[0] != '|') return 0;

    const inner = if (trimmed.len >= 2 and trimmed[trimmed.len - 1] == '|')
        trimmed[1 .. trimmed.len - 1]
    else
        trimmed[1..];

    var count: usize = 0;
    var cell_start: usize = 0;
    var i: usize = 0;
    while (i < inner.len) {
        if (inner[i] == '|') {
            if (i > 0 and inner[i - 1] == '\\') {
                i += 1;
                continue;
            }
            if (count >= cells.len) return 0;
            cells[count] = std.mem.trim(u8, inner[cell_start..i], " ");
            count += 1;
            i += 1;
            cell_start = i;
        } else {
            i += 1;
        }
    }
    if (cell_start <= inner.len) {
        if (count >= cells.len) return 0;
        cells[count] = std.mem.trim(u8, inner[cell_start..], " ");
        count += 1;
    }
    return count;
}
