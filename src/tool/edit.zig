const std = @import("std");
const jh = @import("json.zig");
const ansi = @import("../ansi.zig");
const root_dir = @import("root_dir.zig");
const ToolResult = @import("registry.zig").ToolResult;

pub const tool_name = "edit_file";
pub const tool_description = "Edit a file by replacing text. Supports exact matching with automatic fallback to whitespace-agnostic matching. If multiple matches exist, set replaceAll=true or the tool will return an error.";
pub const tool_params = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\",\"description\":\"Path to the file\"},\"oldString\":{\"type\":\"string\",\"description\":\"Exact text to find (must match byte-exact, including whitespace and indentation)\"},\"newString\":{\"type\":\"string\",\"description\":\"Replacement text\"},\"replaceAll\":{\"type\":\"boolean\",\"description\":\"Replace all occurrences (default: false). Required if multiple matches exist.\"}},\"required\":[\"path\",\"oldString\",\"newString\"]}";

const BOM_LEN: usize = 3;
const BOM_BYTES: [3]u8 = .{ 0xEF, 0xBB, 0xBF };
const MAX_READ: usize = 100 * 1024;

// ---------------------------------------------------------------------------
// 内部 API：纯函数，不含 I/O
// ---------------------------------------------------------------------------

pub const LineEnding = enum { lf, crlf };

fn detectBom(content: []const u8) bool {
    return content.len >= BOM_LEN and std.mem.eql(u8, content[0..BOM_LEN], &BOM_BYTES);
}

fn detectLineEnding(content: []const u8) LineEnding {
    if (content.len < 2) return .lf;
    var i: usize = 0;
    while (i < content.len - 1) : (i += 1) {
        if (content[i] == '\r' and content[i + 1] == '\n') return .crlf;
        if (content[i] == '\n') return .lf;
    }
    return .lf;
}

fn convertToLineEnding(text: []const u8, target: LineEnding, allocator: std.mem.Allocator) ![]const u8 {
    if (target == .lf) return text;
    var result = std.array_list.Managed(u8).init(allocator);
    errdefer result.deinit();
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '\n') {
            if (i == 0 or text[i - 1] != '\r') {
                try result.appendSlice("\r\n");
            } else {
                try result.append('\n');
            }
        } else if (text[i] == '\r') {
            if (i + 1 < text.len and text[i + 1] == '\n') {
                try result.appendSlice("\r\n");
                i += 1;
            } else {
                try result.append('\r');
            }
        } else {
            try result.append(text[i]);
        }
        i += 1;
    }
    return result.toOwnedSlice();
}

fn countOccurrences(text: []const u8, pattern: []const u8) usize {
    if (pattern.len == 0) return 0;
    var count: usize = 0;
    var start: usize = 0;
    while (std.mem.indexOfPos(u8, text, start, pattern)) |pos| {
        count += 1;
        start = pos + pattern.len;
    }
    return count;
}

fn isWhitespace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r';
}

/// Normalize text by compressing consecutive whitespace to a single space,
/// and return a mapping from each normalized byte position to the original
/// text byte position. Leading/trailing whitespace is trimmed.
/// Source: edit.zig — whitespace_normalized matching layer
fn normalizeWithMapping(text: []const u8, allocator: std.mem.Allocator) !struct { normalized: []u8, mapping: []usize } {
    var norm = std.array_list.Managed(u8).init(allocator);
    var map = std.array_list.Managed(usize).init(allocator);

    var i: usize = 0;
    var prev_was_whitespace = true;
    while (i < text.len) {
        if (isWhitespace(text[i])) {
            if (!prev_was_whitespace) {
                try norm.append(' ');
                try map.append(i);
                prev_was_whitespace = true;
            }
            i += 1;
        } else {
            try norm.append(text[i]);
            try map.append(i);
            prev_was_whitespace = false;
            i += 1;
        }
    }

    if (norm.items.len > 0 and norm.items[norm.items.len - 1] == ' ') {
        norm.items.len -= 1;
    }

    return .{
        .normalized = try norm.toOwnedSlice(),
        .mapping = try map.toOwnedSlice(),
    };
}

/// Normalize text only (no mapping) — used for normalizing the pattern.
/// Source: edit.zig — whitespace_normalized matching layer
fn normalizeText(text: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var norm = std.array_list.Managed(u8).init(allocator);

    var i: usize = 0;
    var prev_was_whitespace = true;
    while (i < text.len) {
        if (isWhitespace(text[i])) {
            if (!prev_was_whitespace) {
                try norm.append(' ');
                prev_was_whitespace = true;
            }
            i += 1;
        } else {
            try norm.append(text[i]);
            prev_was_whitespace = false;
            i += 1;
        }
    }

    if (norm.items.len > 0 and norm.items[norm.items.len - 1] == ' ') {
        norm.items.len -= 1;
    }

    return norm.toOwnedSlice();
}

/// Count lines in a string (1 + number of \n).
/// Source: edit.zig — line_trimmed matching layer
fn countLines(s: []const u8) usize {
    if (s.len == 0) return 0;
    var count: usize = 1;
    for (s) |c| {
        if (c == '\n') count += 1;
    }
    return count;
}

/// Find all non-overlapping exact match positions in text.
/// Source: edit.zig — layer 1 exact matching
fn findAllExact(text: []const u8, pattern: []const u8, allocator: std.mem.Allocator) ![]usize {
    var positions = std.array_list.Managed(usize).init(allocator);
    var start: usize = 0;
    while (std.mem.indexOfPos(u8, text, start, pattern)) |pos| {
        try positions.append(pos);
        start = pos + pattern.len;
    }
    return positions.toOwnedSlice();
}

const MatchRange = struct { pos: usize, len: usize };

/// Find all non-overlapping line_trimmed match positions and lengths in text.
/// Source: edit.zig — layer 2 line_trimmed matching
fn findAllLineTrimmed(text: []const u8, pattern: []const u8, allocator: std.mem.Allocator) ![]MatchRange {
    var positions = std.array_list.Managed(MatchRange).init(allocator);

    const n = countLines(pattern);
    if (n == 0) return positions.toOwnedSlice();

    var line_starts = std.array_list.Managed(usize).init(allocator);
    defer line_starts.deinit();
    try line_starts.append(0);
    for (text, 0..) |c, i| {
        if (c == '\n') {
            try line_starts.append(i + 1);
        }
    }

    var pat_trimmed = std.array_list.Managed([]const u8).init(allocator);
    defer pat_trimmed.deinit();
    var iter = std.mem.splitScalar(u8, pattern, '\n');
    while (iter.next()) |line| {
        try pat_trimmed.append(std.mem.trim(u8, line, " \t\r"));
    }

    var line_idx: usize = 0;
    while (line_idx + n <= line_starts.items.len) {
        var match = true;
        for (0..n) |i| {
            const t_start = line_starts.items[line_idx + i];
            const t_end = if (line_idx + i + 1 < line_starts.items.len)
                line_starts.items[line_idx + i + 1] - 1
            else
                text.len;
            const t_line = std.mem.trim(u8, text[t_start..t_end], " \t\r");
            if (!std.mem.eql(u8, t_line, pat_trimmed.items[i])) {
                match = false;
                break;
            }
        }
        if (match) {
            const match_end = if (line_idx + n < line_starts.items.len)
                line_starts.items[line_idx + n] - 1
            else
                text.len;
            try positions.append(.{ .pos = line_starts.items[line_idx], .len = match_end - line_starts.items[line_idx] });
            line_idx += n;
        } else {
            line_idx += 1;
        }
    }

    return positions.toOwnedSlice();
}

/// Find all non-overlapping whitespace_normalized match positions and lengths in text.
/// Source: edit.zig — layer 3 whitespace_normalized matching
fn findAllWhitespaceNormalized(text: []const u8, pattern: []const u8, allocator: std.mem.Allocator) ![]MatchRange {
    var positions = std.array_list.Managed(MatchRange).init(allocator);

    const nm = try normalizeWithMapping(text, allocator);
    defer allocator.free(nm.normalized);
    defer allocator.free(nm.mapping);

    const norm_pattern = try normalizeText(pattern, allocator);
    defer allocator.free(norm_pattern);

    if (norm_pattern.len == 0) return positions.toOwnedSlice();

    var start: usize = 0;
    while (std.mem.indexOfPos(u8, nm.normalized, start, norm_pattern)) |match_pos| {
        const original_start = nm.mapping[match_pos];
        const end_idx = match_pos + norm_pattern.len;
        const original_end = if (end_idx < nm.mapping.len)
            nm.mapping[end_idx]
        else
            text.len;
        try positions.append(.{ .pos = original_start, .len = original_end - original_start });
        start = match_pos + norm_pattern.len;
    }

    return positions.toOwnedSlice();
}

/// Truncate string to at most max_codepoints Unicode codepoints.
/// Source: edit.zig — context preview truncation
fn truncateToCodepoints(s: []const u8, max_codepoints: usize) []const u8 {
    var count: usize = 0;
    var i: usize = 0;
    while (i < s.len and count < max_codepoints) {
        const len = std.unicode.utf8ByteSequenceLength(s[i]) catch break;
        i += len;
        count += 1;
    }
    return s[0..i];
}

/// Extract context range (2 lines before, 2 lines after) around a match position.
/// Source: edit.zig — context preview for old_preview/new_preview
fn extractContextRange(text: []const u8, pos: usize, old_len: usize) struct { start: usize, end: usize } {
    var line_start = pos;
    while (line_start > 0 and text[line_start - 1] != '\n') {
        line_start -= 1;
    }

    var line_end = pos + old_len;
    while (line_end < text.len and text[line_end] != '\n') {
        line_end += 1;
    }
    if (line_end < text.len and text[line_end] == '\n') {
        line_end += 1;
    }

    var ctx_start = line_start;
    var lines_before: usize = 0;
    while (ctx_start > 0 and lines_before < 2) {
        ctx_start -= 1;
        if (text[ctx_start] == '\n') {
            lines_before += 1;
        }
    }
    if (ctx_start < line_start and text[ctx_start] == '\n') {
        ctx_start += 1;
    }

    var ctx_end = line_end;
    var lines_after: usize = 0;
    while (ctx_end < text.len and lines_after < 2) {
        if (text[ctx_end] == '\n') {
            lines_after += 1;
            ctx_end += 1;
        } else {
            ctx_end += 1;
        }
    }

    return .{ .start = ctx_start, .end = ctx_end };
}

const PreviewResult = struct { old_preview: []const u8, new_preview: []const u8 };

/// Build old_preview and new_preview strings for JSON output.
/// Source: edit.zig — context preview for JSON output
fn buildPreviews(
    text: []const u8,
    pos: usize,
    old_len: usize,
    new_string: []const u8,
    allocator: std.mem.Allocator,
) !PreviewResult {
    const ctx = extractContextRange(text, pos, old_len);
    const old_raw = text[ctx.start..ctx.end];
    const old_truncated = truncateToCodepoints(old_raw, 240);

    const match_ctx_start = if (pos >= ctx.start) pos - ctx.start else 0;
    const match_ctx_end = if (pos + old_len <= ctx.end)
        pos + old_len - ctx.start
    else
        ctx.end - ctx.start;

    var new_buf = std.array_list.Managed(u8).init(allocator);
    errdefer new_buf.deinit();
    if (match_ctx_start > 0) {
        try new_buf.appendSlice(old_raw[0..match_ctx_start]);
    }
    try new_buf.appendSlice(new_string);
    if (match_ctx_end < old_raw.len) {
        try new_buf.appendSlice(old_raw[match_ctx_end..]);
    }
    const new_raw = try new_buf.toOwnedSlice();
    const new_truncated = truncateToCodepoints(new_raw, 240);
    allocator.free(new_raw);

    return .{
        .old_preview = try allocator.dupe(u8, old_truncated),
        .new_preview = try allocator.dupe(u8, new_truncated),
    };
}

// ---------------------------------------------------------------------------
// 替换操作
// ---------------------------------------------------------------------------

fn replaceOne(allocator: std.mem.Allocator, text: []const u8, old: []const u8, new: []const u8) ![]const u8 {
    const pos = std.mem.indexOf(u8, text, old) orelse return text;
    var result = std.array_list.Managed(u8).init(allocator);
    try result.appendSlice(text[0..pos]);
    try result.appendSlice(new);
    try result.appendSlice(text[pos + old.len ..]);
    return result.toOwnedSlice();
}

fn replaceAll(allocator: std.mem.Allocator, text: []const u8, old: []const u8, new: []const u8) ![]const u8 {
    var result = std.array_list.Managed(u8).init(allocator);
    var start: usize = 0;
    while (std.mem.indexOfPos(u8, text, start, old)) |pos| {
        try result.appendSlice(text[start..pos]);
        try result.appendSlice(new);
        start = pos + old.len;
    }
    try result.appendSlice(text[start..]);
    return result.toOwnedSlice();
}

/// Replace at a specific position with given old_len.
/// Source: edit.zig — fuzzy match replacement
fn replaceAt(allocator: std.mem.Allocator, text: []const u8, pos: usize, old_len: usize, new: []const u8) ![]const u8 {
    var result = std.array_list.Managed(u8).init(allocator);
    try result.appendSlice(text[0..pos]);
    try result.appendSlice(new);
    try result.appendSlice(text[pos + old_len ..]);
    return result.toOwnedSlice();
}

fn errorString(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(allocator, "Error: " ++ fmt, args) catch "Error: internal (OOM)";
}

// ---------------------------------------------------------------------------
// 公开 API
// ---------------------------------------------------------------------------

/// Execute the edit_file tool with fuzzy matching (3 layers), size limit,
/// atomic write, and enhanced JSON output with strategy and preview.
/// Source: edit.zig — tool execution
pub fn execute(allocator: std.mem.Allocator, io: std.Io, args: std.json.Value) ToolResult {
    const args_obj = args.object;
    const path = args_obj.get("path") orelse return ToolResult.fail("Error: missing 'path' argument");
    const old_string = args_obj.get("oldString") orelse return ToolResult.fail("Error: missing 'oldString' argument");
    const new_string = args_obj.get("newString") orelse return ToolResult.fail("Error: missing 'newString' argument");
    const replace_all = if (args_obj.get("replaceAll")) |v| (v == .bool and v.bool) else false;

    const os = old_string.string;
    const ns = new_string.string;

    if (os.len == 0) return ToolResult.fail("Error: oldString must not be empty. Use write_file to create a file.");
    if (std.mem.eql(u8, os, ns)) return ToolResult.fail("Error: no changes to apply: oldString and newString are identical.");

    const resolved = root_dir.resolvePath(allocator, path.string) catch {
        return ToolResult.fail("Error: OOM");
    };
    defer if (resolved.ptr != path.string.ptr) allocator.free(resolved);

    const cwd = std.Io.Dir.cwd();

    // Read file with size limit
    const content = readFile: {
        var file = cwd.openFile(io, resolved, .{ .mode = .read_only }) catch |err| {
            return ToolResult.fail(errorString(allocator, "cannot open file '{s}': {}", .{ path.string, err }));
        };
        defer file.close(io);

        const stat = file.stat(io) catch |err| {
            return ToolResult.fail(errorString(allocator, "cannot stat file '{s}': {}", .{ path.string, err }));
        };
        const file_size = @as(usize, @intCast(stat.size));
        if (file_size > MAX_READ) {
            return ToolResult.fail(errorString(allocator, "'{s}' is too large ({d} bytes). Max edit size is 100KB. Use write_file for larger files.", .{ path.string, file_size }));
        }
        const buf = allocator.alloc(u8, file_size) catch |err| {
            return ToolResult.fail(errorString(allocator, "OOM reading file: {}", .{err}));
        };
        _ = file.readStreaming(io, &.{buf}) catch |err| {
            allocator.free(buf);
            return ToolResult.fail(errorString(allocator, "cannot read file '{s}': {}", .{ path.string, err }));
        };
        break :readFile buf;
    };
    defer allocator.free(content);

    // BOM detection
    const bom_present = detectBom(content);
    const text_start: usize = if (bom_present) BOM_LEN else 0;
    const text = content[text_start..];

    // Line ending detection
    const le = detectLineEnding(text);
    const normalized_old = convertToLineEnding(os, le, allocator) catch {
        return ToolResult.fail("Error: OOM during string conversion");
    };
    defer if (normalized_old.ptr != os.ptr) allocator.free(normalized_old);

    const normalized_new = convertToLineEnding(ns, le, allocator) catch {
        return ToolResult.fail("Error: OOM during string conversion");
    };
    defer if (normalized_new.ptr != ns.ptr) allocator.free(normalized_new);

    // -----------------------------------------------------------------------
    // Matching: 3-layer fuzzy chain
    // -----------------------------------------------------------------------
    const MatchStrategy = enum { exact, line_trimmed, whitespace_normalized };

    var strategy: MatchStrategy = .exact;
    const exact_count = countOccurrences(text, normalized_old);
    var match_count = exact_count;
    var match_ranges: []MatchRange = &[_]MatchRange{};
    var match_ranges_allocated = false;

    if (exact_count == 0) {
        strategy = .line_trimmed;
        const lt_ranges = findAllLineTrimmed(text, normalized_old, allocator) catch {
            return ToolResult.fail("Error: OOM during line_trimmed matching");
        };
        defer allocator.free(lt_ranges);

        if (lt_ranges.len == 0) {
            strategy = .whitespace_normalized;
            const wn_ranges = findAllWhitespaceNormalized(text, normalized_old, allocator) catch {
                return ToolResult.fail("Error: OOM during whitespace_normalized matching");
            };
            defer allocator.free(wn_ranges);

            if (wn_ranges.len == 0) {
                return ToolResult.fail(errorString(allocator, "could not find oldString in '{s}'\n  -- no match via any strategy (exact / line_trimmed / whitespace_normalized)", .{path.string}));
            }

            if (wn_ranges.len > 1) {
                return ToolResult.fail(errorString(allocator, "found {d} approximate matches via whitespace_normalized, provide more context", .{wn_ranges.len}));
            }

            match_count = 1;
            match_ranges = allocator.dupe(MatchRange, wn_ranges) catch {
                return ToolResult.fail("Error: OOM");
            };
            match_ranges_allocated = true;
        } else if (lt_ranges.len > 1) {
            return ToolResult.fail(errorString(allocator, "found {d} approximate matches via line_trimmed, provide more context", .{lt_ranges.len}));
        } else {
            match_count = 1;
            match_ranges = allocator.dupe(MatchRange, lt_ranges) catch {
                return ToolResult.fail("Error: OOM");
            };
            match_ranges_allocated = true;
        }
    } else if (exact_count > 1 and !replace_all) {
        return ToolResult.fail(errorString(allocator, "found {d} exact matches, set replaceAll=true", .{exact_count}));
    } else {
        match_ranges = &[_]MatchRange{};
    }

    // -----------------------------------------------------------------------
    // Replacement
    // -----------------------------------------------------------------------
    const final_text = if (strategy == .exact and (replace_all or exact_count == 1))
        if (replace_all)
            replaceAll(allocator, text, normalized_old, normalized_new) catch |err| {
                if (match_ranges_allocated) allocator.free(match_ranges);
                return ToolResult.fail(errorString(allocator, "replacement failed: {}", .{err}));
            }
        else
            replaceOne(allocator, text, normalized_old, normalized_new) catch |err| {
                if (match_ranges_allocated) allocator.free(match_ranges);
                return ToolResult.fail(errorString(allocator, "replacement failed: {}", .{err}));
            }
    else blk: {
        if (match_ranges.len == 0) {
            return ToolResult.fail("Error: no match positions found");
        }

        if (match_ranges.len == 1) {
            break :blk replaceAt(allocator, text, match_ranges[0].pos, match_ranges[0].len, normalized_new) catch |err| {
                return ToolResult.fail(errorString(allocator, "replacement failed: {}", .{err}));
            };
        }

        var result = std.array_list.Managed(u8).init(allocator);
        errdefer result.deinit();
        var current_start: usize = 0;
        for (match_ranges) |mr| {
            result.appendSlice(text[current_start..mr.pos]) catch {
                return ToolResult.fail("Error: OOM");
            };
            result.appendSlice(normalized_new) catch {
                return ToolResult.fail("Error: OOM");
            };
            current_start = mr.pos + mr.len;
        }
        result.appendSlice(text[current_start..]) catch {
            return ToolResult.fail("Error: OOM");
        };
        break :blk result.toOwnedSlice() catch {
            return ToolResult.fail("Error: OOM");
        };
    };
    defer if (match_ranges_allocated) allocator.free(match_ranges);

    // -----------------------------------------------------------------------
    // Context previews for single replacement
    // -----------------------------------------------------------------------
    var owned_old_preview: []const u8 = "";
    var owned_new_preview: []const u8 = "";
    defer {
        if (owned_old_preview.len > 0) allocator.free(owned_old_preview);
        if (owned_new_preview.len > 0) allocator.free(owned_new_preview);
    }

    if (match_count == 1) {
        const preview_pos = if (strategy == .exact)
            std.mem.indexOf(u8, text, normalized_old) orelse 0
        else if (match_ranges.len > 0)
            match_ranges[0].pos
        else
            0;
        const preview_len = if (strategy == .exact) normalized_old.len else (if (match_ranges.len > 0) match_ranges[0].len else normalized_old.len);

        const previews = buildPreviews(text, preview_pos, preview_len, normalized_new, allocator) catch PreviewResult{
            .old_preview = "",
            .new_preview = "",
        };
        if (previews.old_preview.len > 0) {
            owned_old_preview = previews.old_preview;
            owned_new_preview = previews.new_preview;
        }
    }

    // -----------------------------------------------------------------------
    // Atomic write: .tmp → rename
    // -----------------------------------------------------------------------
    // renameAbsolute requires absolute paths; make them absolute if needed
    const abs_resolved = abs_resolved: {
        if (std.fs.path.isAbsolute(resolved)) break :abs_resolved resolved;
        var cwd_buf: [4096]u8 = undefined;
        const cwd_len = cwd.realPath(io, &cwd_buf) catch {
            break :abs_resolved resolved;
        };
        const joined = std.fs.path.join(allocator, &.{ cwd_buf[0..cwd_len], resolved }) catch {
            break :abs_resolved resolved;
        };
        break :abs_resolved joined;
    };
    defer if (abs_resolved.ptr != resolved.ptr) allocator.free(abs_resolved);

    const tmp_path = std.fmt.allocPrint(allocator, "{s}.tmp", .{abs_resolved}) catch {
        return ToolResult.fail("Error: OOM");
    };
    defer allocator.free(tmp_path);

    const write_content = if (bom_present) blk: {
        const with_bom = allocator.alloc(u8, BOM_LEN + final_text.len) catch {
            return ToolResult.fail("Error: OOM");
        };
        @memcpy(with_bom[0..BOM_LEN], &BOM_BYTES);
        @memcpy(with_bom[BOM_LEN..], final_text);
        break :blk with_bom;
    } else final_text;

    {
        var wfile = cwd.createFile(io, tmp_path, .{}) catch |err| {
            if (bom_present and write_content.ptr != final_text.ptr) allocator.free(write_content);
            return ToolResult.fail(errorString(allocator, "cannot write file '{s}': {}", .{ path.string, err }));
        };
        wfile.writeStreamingAll(io, write_content) catch |err| {
            if (bom_present and write_content.ptr != final_text.ptr) allocator.free(write_content);
            wfile.close(io);
            return ToolResult.fail(errorString(allocator, "write failed: {}", .{err}));
        };
        wfile.close(io);
    }

    std.Io.Dir.renameAbsolute(tmp_path, abs_resolved, io) catch |err| {
        if (bom_present and write_content.ptr != final_text.ptr) allocator.free(write_content);
        allocator.free(final_text);
        return ToolResult.fail(errorString(allocator, "rename failed: {}", .{err}));
    };

    if (bom_present and write_content.ptr != final_text.ptr) allocator.free(write_content);
    allocator.free(final_text);

    // -----------------------------------------------------------------------
    // JSON output
    // -----------------------------------------------------------------------
    const strategy_str = switch (strategy) {
        .exact => "exact",
        .line_trimmed => "line_trimmed",
        .whitespace_normalized => "whitespace_normalized",
    };

    var buf = std.array_list.Managed(u8).init(allocator);
    defer buf.deinit();
    jh.putc(&buf, '{') catch return ToolResult.fail("Error: OOM");
    jh.putString(&buf, "path", path.string) catch return ToolResult.fail("Error: OOM");
    jh.putc(&buf, ',') catch return ToolResult.fail("Error: OOM");
    jh.putInt(&buf, "replacements", @as(u64, match_count)) catch return ToolResult.fail("Error: OOM");
    jh.putc(&buf, ',') catch return ToolResult.fail("Error: OOM");
    jh.putString(&buf, "strategy", strategy_str) catch return ToolResult.fail("Error: OOM");

    if (match_count == 1) {
        if (owned_old_preview.len > 0) {
            jh.putc(&buf, ',') catch return ToolResult.fail("Error: OOM");
            jh.putString(&buf, "old_preview", owned_old_preview) catch return ToolResult.fail("Error: OOM");
        }
        if (owned_new_preview.len > 0) {
            jh.putc(&buf, ',') catch return ToolResult.fail("Error: OOM");
            jh.putString(&buf, "new_preview", owned_new_preview) catch return ToolResult.fail("Error: OOM");
        }
    }

    jh.putc(&buf, '}') catch return ToolResult.fail("Error: OOM");
    return ToolResult.ok(jh.finish(&buf));
}

/// Render the edit_file result to stdout with color-coded diff display.
/// Source: edit.zig — renderResult display
pub fn renderResult(allocator: std.mem.Allocator, stdout: *std.Io.Writer, json_str: []const u8) !void {
    if (!std.mem.startsWith(u8, json_str, "{")) {
        try stdout.print("  {s}{s}{s}\n", .{ ansi.C.red, json_str, ansi.C.reset });
        return;
    }

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, json_str, .{}) catch return;
    defer parsed.deinit();
    const obj = parsed.value.object;

    const path_str = if (obj.get("path")) |v| if (v == .string) v.string else "" else "";
    const replacements = if (obj.get("replacements")) |v| @as(usize, @intCast(v.integer)) else 0;
    const strategy_str = if (obj.get("strategy")) |v| if (v == .string) v.string else "exact" else "exact";

    if (replacements == 0) {
        try stdout.print("  {s}\u{2717}{s} {s}\n", .{ ansi.C.red, ansi.C.reset, path_str });
        return;
    }

    if (replacements > 1) {
        try stdout.print("  {s}\u{2713}{s} {s}  ({d} replacements, {s})\n", .{ ansi.C.green, ansi.C.reset, path_str, replacements, strategy_str });
        return;
    }

    try stdout.print("  {s}\u{2713}{s} {s}  (1 replacement, {s})\n", .{ ansi.C.green, ansi.C.reset, path_str, strategy_str });

    const old_preview = if (obj.get("old_preview")) |v| if (v == .string) v.string else "" else "";
    const new_preview = if (obj.get("new_preview")) |v| if (v == .string) v.string else "" else "";

    if (old_preview.len > 0) {
        var iter = std.mem.splitScalar(u8, old_preview, '\n');
        while (iter.next()) |line| {
            try stdout.print("  {s}\u{2500} {s}{s}\n", .{ ansi.C.red, line, ansi.C.reset });
        }
    }

    if (new_preview.len > 0) {
        var iter = std.mem.splitScalar(u8, new_preview, '\n');
        while (iter.next()) |line| {
            try stdout.print("  {s}+ {s}{s}\n", .{ ansi.C.green, line, ansi.C.reset });
        }
    }
}

// ---------------------------------------------------------------------------
// 集成测试
// ---------------------------------------------------------------------------

fn readTestFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    const cwd = std.Io.Dir.cwd();
    var file = try cwd.openFile(io, path, .{ .mode = .read_only });
    defer file.close(io);
    const stat = try file.stat(io);
    const content = try allocator.alloc(u8, @as(usize, @intCast(stat.size)));
    _ = try file.readStreaming(io, &.{content});
    return content;
}

fn writeTestFile(io: std.Io, path: []const u8, data: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    var file = try cwd.createFile(io, path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, data);
}

test "detectBom: detects BOM correctly" {
    const testing = std.testing;
    try testing.expect(detectBom("\xEF\xBB\xBFhello"));
    try testing.expect(!detectBom("hello"));
    try testing.expect(!detectBom(""));
}

test "detectLineEnding: LF vs CRLF" {
    const testing = std.testing;
    try testing.expect(detectLineEnding("line1\nline2\n") == .lf);
    try testing.expect(detectLineEnding("line1\r\nline2\r\n") == .crlf);
    try testing.expect(detectLineEnding("no newline") == .lf);
}

test "countOccurrences: basic" {
    const testing = std.testing;
    try testing.expectEqual(@as(usize, 0), countOccurrences("abc", "x"));
    try testing.expectEqual(@as(usize, 1), countOccurrences("abc", "b"));
    try testing.expectEqual(@as(usize, 2), countOccurrences("aba", "a"));
    try testing.expectEqual(@as(usize, 2), countOccurrences("aaaa", "aa"));
}

test "convertToLineEnding: LF to CRLF" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const result = try convertToLineEnding("hello\nworld\n", .crlf, allocator);
    defer allocator.free(result);
    try testing.expectEqualStrings("hello\r\nworld\r\n", result);
}

test "edit: basic string replacement" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const io = testing.io;
    const tmp_path = "zig_test_edit_basic.txt";

    try writeTestFile(io, tmp_path, "hello world");
    defer std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, "zig_test_edit_basic.txt.tmp") catch {};

    const jargs = try std.fmt.allocPrint(allocator, "{{\"path\": \"{s}\", \"oldString\": \"world\", \"newString\": \"there\"}}", .{tmp_path});
    defer allocator.free(jargs);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, jargs, .{}) catch return;
    defer parsed.deinit();
    const args = parsed.value;
    const tr = execute(allocator, io, args);
    defer allocator.free(tr.output);

    try testing.expect(tr.success);
    try testing.expect(std.mem.startsWith(u8, tr.output, "{"));
    try testing.expect(std.mem.indexOf(u8, tr.output, "\"replacements\":1") != null);
    try testing.expect(std.mem.indexOf(u8, tr.output, "\"strategy\":\"exact\"") != null);

    const read_content = try readTestFile(allocator, io, tmp_path);
    defer allocator.free(read_content);
    try testing.expectEqualStrings("hello there", read_content);
}

test "edit: oldString not found" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const io = testing.io;
    const tmp_path = "zig_test_edit_notfound.txt";

    try writeTestFile(io, tmp_path, "hello world");
    defer std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, "zig_test_edit_notfound.txt.tmp") catch {};

    const jargs = try std.fmt.allocPrint(allocator, "{{\"path\": \"{s}\", \"oldString\": \"xyz\", \"newString\": \"abc\"}}", .{tmp_path});
    defer allocator.free(jargs);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, jargs, .{}) catch return;
    defer parsed.deinit();
    const args = parsed.value;
    const tr = execute(allocator, io, args);
    defer allocator.free(tr.output);

    try testing.expect(!tr.success);
    try testing.expect(std.mem.startsWith(u8, tr.output, "Error:"));
    try testing.expect(std.mem.indexOf(u8, tr.output, "could not find") != null);
    try testing.expect(std.mem.indexOf(u8, tr.output, "no match via any strategy") != null);
}

test "edit: oldString empty returns error" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const io = testing.io;

    const jargs = "{\"path\": \"test.txt\", \"oldString\": \"\", \"newString\": \"abc\"}";
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, jargs, .{}) catch return;
    defer parsed.deinit();
    const args = parsed.value;
    const tr = execute(allocator, io, args);

    try testing.expect(!tr.success);
    try testing.expect(std.mem.startsWith(u8, tr.output, "Error:"));
    try testing.expect(std.mem.indexOf(u8, tr.output, "oldString must not be empty") != null);
}

test "edit: oldString equals newString returns error" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const io = testing.io;

    const jargs = "{\"path\": \"test.txt\", \"oldString\": \"abc\", \"newString\": \"abc\"}";
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, jargs, .{}) catch return;
    defer parsed.deinit();
    const args = parsed.value;
    const tr = execute(allocator, io, args);

    try testing.expect(!tr.success);
    try testing.expect(std.mem.startsWith(u8, tr.output, "Error:"));
    try testing.expect(std.mem.indexOf(u8, tr.output, "no changes to apply") != null);
}

test "edit: multiple matches without replaceAll" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const io = testing.io;
    const tmp_path = "zig_test_edit_multi.txt";

    try writeTestFile(io, tmp_path, "a a a");
    defer std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, "zig_test_edit_multi.txt.tmp") catch {};

    const jargs = try std.fmt.allocPrint(allocator, "{{\"path\": \"{s}\", \"oldString\": \"a\", \"newString\": \"b\"}}", .{tmp_path});
    defer allocator.free(jargs);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, jargs, .{}) catch return;
    defer parsed.deinit();
    const args = parsed.value;
    const tr = execute(allocator, io, args);
    defer allocator.free(tr.output);

    try testing.expect(!tr.success);
    try testing.expect(std.mem.indexOf(u8, tr.output, "found") != null);
    try testing.expect(std.mem.indexOf(u8, tr.output, "replaceAll") != null);
}

test "edit: replaceAll replaces all occurrences" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const io = testing.io;
    const tmp_path = "zig_test_edit_all.txt";

    try writeTestFile(io, tmp_path, "a a a");
    defer std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, "zig_test_edit_all.txt.tmp") catch {};

    const jargs = try std.fmt.allocPrint(allocator, "{{\"path\": \"{s}\", \"oldString\": \"a\", \"newString\": \"b\", \"replaceAll\": true}}", .{tmp_path});
    defer allocator.free(jargs);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, jargs, .{}) catch return;
    defer parsed.deinit();
    const args = parsed.value;
    const tr = execute(allocator, io, args);
    defer allocator.free(tr.output);

    try testing.expect(tr.success);
    try testing.expect(std.mem.startsWith(u8, tr.output, "{"));
    try testing.expect(std.mem.indexOf(u8, tr.output, "\"replacements\":3") != null);
    try testing.expect(std.mem.indexOf(u8, tr.output, "\"strategy\":\"exact\"") != null);

    const read_content = try readTestFile(allocator, io, tmp_path);
    defer allocator.free(read_content);
    try testing.expectEqualStrings("b b b", read_content);
}

test "edit: BOM preservation" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const io = testing.io;
    const tmp_path = "zig_test_edit_bom.txt";

    const cwd = std.Io.Dir.cwd();
    const bom = [_]u8{ 0xEF, 0xBB, 0xBF };
    {
        var file = try cwd.createFile(io, tmp_path, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, bom[0..]);
        try file.writeStreamingAll(io, "hello world");
    }
    defer cwd.deleteFile(io, tmp_path) catch {};
    defer cwd.deleteFile(io, "zig_test_edit_bom.txt.tmp") catch {};

    const jargs = try std.fmt.allocPrint(allocator, "{{\"path\": \"{s}\", \"oldString\": \"world\", \"newString\": \"there\"}}", .{tmp_path});
    defer allocator.free(jargs);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, jargs, .{}) catch return;
    defer parsed.deinit();
    const args = parsed.value;
    const tr = execute(allocator, io, args);
    defer allocator.free(tr.output);

    try testing.expect(tr.success);
    try testing.expect(std.mem.startsWith(u8, tr.output, "{"));
    try testing.expect(std.mem.indexOf(u8, tr.output, "\"replacements\"") != null);

    const read_content = try readTestFile(allocator, io, tmp_path);
    defer allocator.free(read_content);
    try testing.expect(read_content.len >= 3);
    try testing.expect(std.mem.eql(u8, read_content[0..3], &bom));
    try testing.expectEqualStrings("hello there", read_content[3..]);
}

// ---------------------------------------------------------------------------
// 新测试：模糊匹配
// ---------------------------------------------------------------------------

test "edit: fuzzy exact first" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const io = testing.io;
    const tmp_path = "zig_test_fuzzy_exact.txt";

    try writeTestFile(io, tmp_path, "hello world");
    defer std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, "zig_test_fuzzy_exact.txt.tmp") catch {};

    const jargs = try std.fmt.allocPrint(allocator, "{{\"path\": \"{s}\", \"oldString\": \"world\", \"newString\": \"there\"}}", .{tmp_path});
    defer allocator.free(jargs);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, jargs, .{}) catch return;
    defer parsed.deinit();
    const args = parsed.value;
    const tr = execute(allocator, io, args);
    defer allocator.free(tr.output);

    try testing.expect(tr.success);
    try testing.expect(std.mem.indexOf(u8, tr.output, "\"strategy\":\"exact\"") != null);
    try testing.expect(std.mem.indexOf(u8, tr.output, "\"replacements\":1") != null);

    const read_content = try readTestFile(allocator, io, tmp_path);
    defer allocator.free(read_content);
    try testing.expectEqualStrings("hello there", read_content);
}

test "edit: line trimmed match" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const io = testing.io;
    const tmp_path = "zig_test_line_trimmed.txt";

    try writeTestFile(io, tmp_path, "hello world");
    defer std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, "zig_test_line_trimmed.txt.tmp") catch {};

    const jargs = try std.fmt.allocPrint(allocator, "{{\"path\": \"{s}\", \"oldString\": \"hello world \", \"newString\": \"hi\"}}", .{tmp_path});
    defer allocator.free(jargs);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, jargs, .{}) catch return;
    defer parsed.deinit();
    const args = parsed.value;
    const tr = execute(allocator, io, args);
    defer allocator.free(tr.output);

    try testing.expect(tr.success);
    try testing.expect(std.mem.indexOf(u8, tr.output, "\"strategy\":\"line_trimmed\"") != null);
    try testing.expect(std.mem.indexOf(u8, tr.output, "\"replacements\":1") != null);

    const read_content = try readTestFile(allocator, io, tmp_path);
    defer allocator.free(read_content);
    try testing.expectEqualStrings("hi", read_content);
}

test "edit: whitespace normalized match" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const io = testing.io;
    const tmp_path = "zig_test_ws_norm.txt";

    try writeTestFile(io, tmp_path, "hello world");
    defer std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, "zig_test_ws_norm.txt.tmp") catch {};

    const jargs = try std.fmt.allocPrint(allocator, "{{\"path\": \"{s}\", \"oldString\": \"hello\tworld\", \"newString\": \"hi\tworld\"}}", .{tmp_path});
    defer allocator.free(jargs);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, jargs, .{}) catch return;
    defer parsed.deinit();
    const args = parsed.value;
    const tr = execute(allocator, io, args);
    defer allocator.free(tr.output);

    try testing.expect(tr.success);
    try testing.expect(std.mem.indexOf(u8, tr.output, "\"strategy\":\"whitespace_normalized\"") != null);
    try testing.expect(std.mem.indexOf(u8, tr.output, "\"replacements\":1") != null);
}

test "edit: layer 2 multi candidate" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const io = testing.io;
    const tmp_path = "zig_test_l2_multi.txt";

    try writeTestFile(io, tmp_path, "abc\nabc");
    defer std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, "zig_test_l2_multi.txt.tmp") catch {};

    const jargs = try std.fmt.allocPrint(allocator, "{{\"path\": \"{s}\", \"oldString\": \"abc \", \"newString\": \"xyz\"}}", .{tmp_path});
    defer allocator.free(jargs);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, jargs, .{}) catch return;
    defer parsed.deinit();
    const args = parsed.value;
    const tr = execute(allocator, io, args);
    defer allocator.free(tr.output);

    try testing.expect(!tr.success);
    try testing.expect(std.mem.indexOf(u8, tr.output, "line_trimmed") != null);
    try testing.expect(std.mem.indexOf(u8, tr.output, "provide more context") != null);
}

test "edit: layer 3 multi candidate" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const io = testing.io;
    const tmp_path = "zig_test_l3_multi.txt";

    try writeTestFile(io, tmp_path, "aaa aaa");
    defer std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, "zig_test_l3_multi.txt.tmp") catch {};

    const jargs = try std.fmt.allocPrint(allocator, "{{\"path\": \"{s}\", \"oldString\": \"aaa\naaa\", \"newString\": \"bbb bbb\"}}", .{tmp_path});
    defer allocator.free(jargs);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, jargs, .{}) catch return;
    defer parsed.deinit();
    const args = parsed.value;
    const tr = execute(allocator, io, args);
    defer allocator.free(tr.output);

    try testing.expect(!tr.success);
    try testing.expect(std.mem.indexOf(u8, tr.output, "whitespace_normalized") != null);
    try testing.expect(std.mem.indexOf(u8, tr.output, "provide more context") != null);
}

test "edit: replaceAll with fuzzy" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const io = testing.io;
    const tmp_path = "zig_test_fuzzy_all.txt";

    try writeTestFile(io, tmp_path, "hello world");
    defer std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, "zig_test_fuzzy_all.txt.tmp") catch {};

    const jargs = try std.fmt.allocPrint(allocator, "{{\"path\": \"{s}\", \"oldString\": \"hello world \", \"newString\": \"hi\", \"replaceAll\": true}}", .{tmp_path});
    defer allocator.free(jargs);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, jargs, .{}) catch return;
    defer parsed.deinit();
    const args = parsed.value;
    const tr = execute(allocator, io, args);
    defer allocator.free(tr.output);

    try testing.expect(tr.success);
    try testing.expect(std.mem.indexOf(u8, tr.output, "\"strategy\":\"line_trimmed\"") != null);
    try testing.expect(std.mem.indexOf(u8, tr.output, "\"replacements\":1") != null);

    const read_content = try readTestFile(allocator, io, tmp_path);
    defer allocator.free(read_content);
    try testing.expectEqualStrings("hi", read_content);
}

test "edit: no match after all layers" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const io = testing.io;
    const tmp_path = "zig_test_all_fail.txt";

    try writeTestFile(io, tmp_path, "hello world");
    defer std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, "zig_test_all_fail.txt.tmp") catch {};

    const jargs = try std.fmt.allocPrint(allocator, "{{\"path\": \"{s}\", \"oldString\": \"xyz\", \"newString\": \"abc\"}}", .{tmp_path});
    defer allocator.free(jargs);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, jargs, .{}) catch return;
    defer parsed.deinit();
    const args = parsed.value;
    const tr = execute(allocator, io, args);
    defer allocator.free(tr.output);

    try testing.expect(!tr.success);
    try testing.expect(std.mem.indexOf(u8, tr.output, "could not find") != null);
    try testing.expect(std.mem.indexOf(u8, tr.output, "no match via any strategy") != null);
}

test "edit: file too large" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const io = testing.io;
    const tmp_path = "zig_test_too_large.txt";

    {
        const cwd = std.Io.Dir.cwd();
        var file = try cwd.createFile(io, tmp_path, .{});
        defer file.close(io);
        var buf: [1024]u8 = undefined;
        @memset(&buf, 'a');
        var written: usize = 0;
        while (written < MAX_READ + 1) {
            const to_write = @min(buf.len, MAX_READ + 1 - written);
            try file.writeStreamingAll(io, buf[0..to_write]);
            written += to_write;
        }
    }
    defer std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, "zig_test_too_large.txt.tmp") catch {};

    const jargs = try std.fmt.allocPrint(allocator, "{{\"path\": \"{s}\", \"oldString\": \"a\", \"newString\": \"b\"}}", .{tmp_path});
    defer allocator.free(jargs);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, jargs, .{}) catch return;
    defer parsed.deinit();
    const args = parsed.value;
    const tr = execute(allocator, io, args);
    defer allocator.free(tr.output);

    try testing.expect(!tr.success);
    try testing.expect(std.mem.indexOf(u8, tr.output, "too large") != null);
    try testing.expect(std.mem.indexOf(u8, tr.output, "100KB") != null);
}

test "edit: atomic write" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const io = testing.io;
    const tmp_path = "zig_test_atomic.txt";
    const tmp_tmp_path = "zig_test_atomic.txt.tmp";

    try writeTestFile(io, tmp_path, "hello world");
    defer std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, tmp_tmp_path) catch {};

    const jargs = try std.fmt.allocPrint(allocator, "{{\"path\": \"{s}\", \"oldString\": \"world\", \"newString\": \"there\"}}", .{tmp_path});
    defer allocator.free(jargs);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, jargs, .{}) catch return;
    defer parsed.deinit();
    const args = parsed.value;
    const tr = execute(allocator, io, args);
    defer allocator.free(tr.output);

    try testing.expect(tr.success);

    const read_content = try readTestFile(allocator, io, tmp_path);
    defer allocator.free(read_content);
    try testing.expectEqualStrings("hello there", read_content);

    const cwd = std.Io.Dir.cwd();
    if (cwd.openFile(io, tmp_tmp_path, .{ .mode = .read_only })) |file| {
        file.close(io);
        try testing.expect(false);
    } else |_| {}
}
