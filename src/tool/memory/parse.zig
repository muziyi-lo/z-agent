const std = @import("std");
const trunc = @import("../truncate.zig");
const root_dir = @import("../root_dir.zig");
const types = @import("types.zig");

const Entry = types.Entry;

// ---------------------------------------------------------------------------
// Cache
// ---------------------------------------------------------------------------

var entry_cache: ?struct {
    entries: []Entry,
    content: []const u8,
    mtime: u64,
} = null;

/// Get mtime of a file, or 0 if file doesn't exist / error.
/// Source: tool/memory/parse.zig — cache invalidation helper
pub fn getMtime(io: std.Io, path: []const u8) u64 {
    const file = std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only }) catch return 0;
    defer file.close(io);
    const stat = file.stat(io) catch return 0;
    return @as(u64, @intCast(stat.mtime.nanoseconds));
}

/// Get cached or freshly-parsed entries. Caller must not free the returned slice
/// — it is owned by the cache and invalidated by the next write.
/// Source: tool/memory/parse.zig — cached entry access
pub fn getEntries(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]Entry {
    const current_mtime = getMtime(io, path);
    if (entry_cache) |*cache| {
        if (cache.mtime == current_mtime) return cache.entries;
        // mtime changed, invalidate
        allocator.free(cache.content);
        allocator.free(cache.entries);
        entry_cache = null;
    }

    const content = readFile(allocator, io, path) orelse return &[_]Entry{};
    const entries = try parseEntries(allocator, content);
    entry_cache = .{
        .entries = entries,
        .content = content,
        .mtime = current_mtime,
    };
    return entries;
}

/// Invalidate the entry cache and free cached memory (called after write operations).
/// Source: tool/memory/parse.zig — cache invalidation and memory cleanup
pub fn invalidateCache(allocator: std.mem.Allocator) void {
    if (entry_cache) |*cache| {
        allocator.free(cache.content);
        allocator.free(cache.entries);
    }
    entry_cache = null;
}

// ---------------------------------------------------------------------------
// Path & file helpers
// ---------------------------------------------------------------------------

/// Build path to memory.md under project_root/.zagent/.
/// Caller owns returned slice, must free.
pub fn memoryPath(allocator: std.mem.Allocator) ![]const u8 {
    if (root_dir.project_root.len > 0) {
        return std.fs.path.join(allocator, &.{ root_dir.project_root, ".zagent", "memory.md" });
    }
    return std.fs.path.join(allocator, &.{ ".zagent", "memory.md" });
}

/// Build path to memory-archive.md under project_root/.zagent/.
/// Caller owns returned slice, must free.
pub fn archivePath(allocator: std.mem.Allocator) ![]const u8 {
    if (root_dir.project_root.len > 0) {
        return std.fs.path.join(allocator, &.{ root_dir.project_root, ".zagent", "memory-archive.md" });
    }
    return std.fs.path.join(allocator, &.{ ".zagent", "memory-archive.md" });
}

/// Read entire file into allocated buffer. Returns null if file doesn't exist.
/// Caller owns returned slice, must free.
pub fn readFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ?[]const u8 {
    const file = std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only }) catch return null;
    defer file.close(io);
    const stat = file.stat(io) catch return null;
    const size: usize = @intCast(stat.size);
    if (size == 0) return null;
    const content = allocator.alloc(u8, size) catch return null;
    _ = file.readPositionalAll(io, content, 0) catch {
        allocator.free(content);
        return null;
    };
    return content;
}

/// Atomic write: write to .tmp then rename to target.
/// Source: tool/memory/parse.zig — atomic write helper
pub fn atomicWrite(allocator: std.mem.Allocator, io: std.Io, path: []const u8, content: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    if (std.fs.path.dirname(path)) |parent| {
        cwd.createDirPath(io, parent) catch {};
    }

    // Resolve to absolute path for renameAbsolute assertion
    const abs_path = abs_path: {
        if (std.fs.path.isAbsolute(path)) break :abs_path path;
        var cwd_buf: [4096]u8 = undefined;
        const cwd_len = cwd.realPath(io, &cwd_buf) catch break :abs_path path;
        const joined = try std.fs.path.join(allocator, &.{ cwd_buf[0..cwd_len], path });
        break :abs_path joined;
    };
    defer if (abs_path.ptr != path.ptr) allocator.free(abs_path);

    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{abs_path});
    defer allocator.free(tmp_path);

    var rename_succeeded = false;
    defer if (!rename_succeeded) cwd.deleteFile(io, tmp_path) catch {};

    {
        const file = cwd.createFile(io, tmp_path, .{}) catch |err| return err;
        defer file.close(io);
        file.writeStreamingAll(io, content) catch |err| return err;
    }

    try std.Io.Dir.renameAbsolute(tmp_path, abs_path, io);
    rename_succeeded = true;
}

// ---------------------------------------------------------------------------
// Date helpers
// ---------------------------------------------------------------------------

/// Return today's date as YYYYMMDD string (8 bytes, comptime-known).
pub fn todayDateString(io: std.Io) [8]u8 {
    const now_ns = std.Io.Clock.Timestamp.now(io, .real).raw.nanoseconds;
    const now_s: u64 = @intCast(@divFloor(now_ns, 1_000_000_000));
    const epoch_sec = std.time.epoch.EpochSeconds{ .secs = now_s };
    const epoch_day = epoch_sec.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    var buf: [8]u8 = undefined;
    _ = std.fmt.bufPrint(&buf, "{d:0>4}{d:0>2}{d:0>2}", .{
        year_day.year,
        @as(u32, @intCast(@intFromEnum(month_day.month))),
        month_day.day_index + 1,
    }) catch {};
    return buf;
}

/// Return today's date as YYYY-MM-DD string (10 bytes, comptime-known).
pub fn todayFormattedDate(io: std.Io) [10]u8 {
    const raw = todayDateString(io);
    var buf: [10]u8 = undefined;
    buf[0..4].* = raw[0..4].*;
    buf[4] = '-';
    buf[5..7].* = raw[4..6].*;
    buf[7] = '-';
    buf[8..10].* = raw[6..8].*;
    return buf;
}

// ---------------------------------------------------------------------------
// ID generation
// ---------------------------------------------------------------------------

/// Generate next MEM-YYYYMMDD-NNN id based on existing content.
/// Caller owns returned slice, must free.
pub fn generateId(allocator: std.mem.Allocator, io: std.Io, existing_content: ?[]const u8) ![]const u8 {
    const date_str = todayDateString(io);

    var max_seq: u32 = 0;

    if (existing_content) |content| {
        var pos: usize = 0;
        while (true) {
            const marker = std.mem.indexOfPos(u8, content, pos, "## [MEM-") orelse break;
            const id_start = marker + 4; // position of 'M' in "MEM-"
            const id_end = std.mem.indexOfScalarPos(u8, content, id_start, ']') orelse {
                pos = marker + 1;
                continue;
            };
            const id_str = content[id_start..id_end];
            // id_str = "MEM-YYYYMMDD-NNN"
            if (id_str.len >= 17) {
                const id_date = id_str[4..12]; // after "MEM-"
                if (std.mem.eql(u8, id_date, &date_str)) {
                    const seq_part = id_str[13..];
                    const seq = std.fmt.parseInt(u32, seq_part, 10) catch 0;
                    if (seq > max_seq) max_seq = seq;
                }
            }
            pos = id_end + 1;
        }
    }

    var buf: [32]u8 = undefined;
    const id = try std.fmt.bufPrint(&buf, "MEM-{s}-{d:0>3}", .{ &date_str, max_seq + 1 });
    return try allocator.dupe(u8, id);
}

// ---------------------------------------------------------------------------
// Title extraction
// ---------------------------------------------------------------------------

/// Extract first line or sentence as title (max 60 codepoints).
/// Returns slice borrowed from 'content'.
pub fn extractTitle(content: []const u8) []const u8 {
    const nl_end = std.mem.indexOfScalar(u8, content, '\n') orelse content.len;
    const cp_end = std.mem.indexOf(u8, content, "。") orelse content.len;
    const end = @min(nl_end, cp_end);
    const limited = trunc.truncateUtf8(content[0..end], 60);
    return std.mem.trim(u8, limited.text, " \r\n\t");
}

// ---------------------------------------------------------------------------
// Entry parsing
// ---------------------------------------------------------------------------

/// Parse a single entry text into an Entry struct.
/// Returns error if entry is malformed (no `]` after `[` in header).
/// Fields are slices borrowed from 'entry_text'.
pub fn parseSingleEntry(entry_text: []const u8) !Entry {
    // Header: "## [MEM-YYYYMMDD-NNN] title"
    const header_end = std.mem.indexOfScalar(u8, entry_text, '\n') orelse return error.MalformedEntry;
    const header = entry_text[0..header_end];

    const id_start = 4; // skip "## ["
    if (header.len < 5 or header[3] != '[') return error.MalformedEntry;
    const id_end = std.mem.indexOfScalarPos(u8, header, id_start, ']') orelse return error.MalformedEntry;
    const id = header[id_start..id_end];

    const title = if (id_end + 2 < header.len) t: {
        const raw_title = std.mem.trim(u8, header[id_end + 2 ..], " \r");
        break :t raw_title;
    } else "";

    // Parse metadata lines (after header, before first blank line)
    var source: []const u8 = "";
    var pattern_key: []const u8 = "";
    var priority: []const u8 = "medium";
    var scope: []const u8 = "project-specific";
    var status: []const u8 = "new";
    var handled: []const u8 = "pending";
    var recurrence_count: usize = 1;
    var archived: bool = false;
    var related_files: []const u8 = "";
    var logged: []const u8 = "";

    var meta_pos = header_end + 1;
    const end = entry_text.len;

    while (meta_pos < end) {
        const line_end = std.mem.indexOfScalarPos(u8, entry_text, meta_pos, '\n') orelse end;
        const line = std.mem.trim(u8, entry_text[meta_pos..line_end], " \r");
        if (line.len == 0) {
            meta_pos = line_end + 1;
            break;
        }
        if (std.mem.startsWith(u8, line, "**source**:")) {
            source = std.mem.trim(u8, line["**source**:".len..], " ");
        } else if (std.mem.startsWith(u8, line, "**pattern-key**:")) {
            pattern_key = std.mem.trim(u8, line["**pattern-key**:".len..], " ");
        } else if (std.mem.startsWith(u8, line, "**priority**:")) {
            priority = std.mem.trim(u8, line["**priority**:".len..], " ");
        } else if (std.mem.startsWith(u8, line, "**scope**:")) {
            scope = std.mem.trim(u8, line["**scope**:".len..], " ");
        } else if (std.mem.startsWith(u8, line, "**status**:")) {
            status = std.mem.trim(u8, line["**status**:".len..], " ");
        } else if (std.mem.startsWith(u8, line, "**handled**:")) {
            handled = std.mem.trim(u8, line["**handled**:".len..], " ");
        } else if (std.mem.startsWith(u8, line, "**recurrence-count**:")) {
            recurrence_count = std.fmt.parseInt(usize, std.mem.trim(u8, line["**recurrence-count**:".len..], " "), 10) catch 1;
        } else if (std.mem.startsWith(u8, line, "**archived**:")) {
            const val = std.mem.trim(u8, line["**archived**:".len..], " ");
            archived = std.mem.eql(u8, val, "true");
        } else if (std.mem.startsWith(u8, line, "**related-files**:")) {
            related_files = std.mem.trim(u8, line["**related-files**:".len..], " ");
        } else if (std.mem.startsWith(u8, line, "**logged**:")) {
            logged = std.mem.trim(u8, line["**logged**:".len..], " ");
        }
        meta_pos = line_end + 1;
    }

    // Preview: first 200 chars of body
    const body_start = meta_pos;
    const preview_trunc = trunc.truncateUtf8(entry_text[body_start..end], 200);
    const preview = std.mem.trim(u8, preview_trunc.text, " \r\n\t");

    return Entry{
        .id = id,
        .title = title,
        .source = source,
        .pattern_key = pattern_key,
        .priority = priority,
        .scope = scope,
        .status = status,
        .handled = handled,
        .recurrence_count = recurrence_count,
        .archived = archived,
        .related_files = related_files,
        .logged = logged,
        .raw = entry_text,
        .preview = preview,
    };
}

/// Parse all entries from content. Invalid entries are skipped.
/// Caller owns returned slice and all entry slices borrow from 'content'.
pub fn parseEntries(allocator: std.mem.Allocator, content: []const u8) ![]Entry {
    var entries = std.array_list.Managed(Entry).init(allocator);

    var scan_pos: usize = 0;
    while (true) {
        const start = std.mem.indexOfPos(u8, content, scan_pos, "## [MEM-") orelse break;

        const header_end = std.mem.indexOfScalarPos(u8, content, start, '\n') orelse content.len;
        if (header_end == start) {
            scan_pos = start + 1;
            continue;
        }

        // Find end of this entry (next "\n## [" or EOF)
        const end = if (header_end < content.len)
            (std.mem.indexOfPos(u8, content, header_end, "\n## [") orelse content.len)
        else
            content.len;

        const entry_text = content[start..end];

        // Try to parse single entry; skip on error
        const entry = parseSingleEntry(entry_text) catch {
            scan_pos = end;
            continue;
        };

        try entries.append(entry);
        scan_pos = end;
    }

    return entries.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// Serialization
// ---------------------------------------------------------------------------

/// Serialize an Entry to its markdown representation. 'body' is the content
/// body text (placed after metadata section).
/// Caller owns returned slice, must free.
pub fn serializeEntry(allocator: std.mem.Allocator, entry: Entry, body: []const u8) ![]u8 {
    var buf = std.array_list.Managed(u8).init(allocator);
    defer buf.deinit();

    // Header
    try buf.appendSlice("## [");
    try buf.appendSlice(entry.id);
    try buf.appendSlice("] ");
    try buf.appendSlice(entry.title);
    try buf.appendSlice("\n");

    // Metadata lines
    {
        const line = try std.fmt.allocPrint(allocator, "**source**: {s}\n", .{entry.source});
        defer allocator.free(line);
        try buf.appendSlice(line);
    }
    {
        const line = try std.fmt.allocPrint(allocator, "**pattern-key**: {s}\n", .{entry.pattern_key});
        defer allocator.free(line);
        try buf.appendSlice(line);
    }
    {
        const line = try std.fmt.allocPrint(allocator, "**priority**: {s}\n", .{entry.priority});
        defer allocator.free(line);
        try buf.appendSlice(line);
    }
    {
        const line = try std.fmt.allocPrint(allocator, "**scope**: {s}\n", .{entry.scope});
        defer allocator.free(line);
        try buf.appendSlice(line);
    }
    {
        const line = try std.fmt.allocPrint(allocator, "**status**: {s}\n", .{entry.status});
        defer allocator.free(line);
        try buf.appendSlice(line);
    }
    {
        const line = try std.fmt.allocPrint(allocator, "**handled**: {s}\n", .{entry.handled});
        defer allocator.free(line);
        try buf.appendSlice(line);
    }
    {
        const line = try std.fmt.allocPrint(allocator, "**recurrence-count**: {d}\n", .{entry.recurrence_count});
        defer allocator.free(line);
        try buf.appendSlice(line);
    }
    {
        const line = try std.fmt.allocPrint(allocator, "**archived**: {s}\n", .{if (entry.archived) "true" else "false"});
        defer allocator.free(line);
        try buf.appendSlice(line);
    }
    {
        const line = try std.fmt.allocPrint(allocator, "**related-files**: {s}\n", .{entry.related_files});
        defer allocator.free(line);
        try buf.appendSlice(line);
    }
    {
        const line = try std.fmt.allocPrint(allocator, "**logged**: {s}\n", .{entry.logged});
        defer allocator.free(line);
        try buf.appendSlice(line);
    }

    // Blank line then body
    try buf.appendSlice("\n");
    try buf.appendSlice(body);
    try buf.appendSlice("\n");

    return buf.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "parse: generateId produces correct format" {
    const testing = std.testing;
    const a = testing.allocator;
    const io = testing.io;

    // First verify todayDateString returns valid format
    const date_str = todayDateString(io);
    try testing.expectEqual(@as(usize, 8), date_str.len);

    // Test with null existing content -> should return MEM-{date}-001
    const id1 = try generateId(a, io, null);
    defer a.free(id1);
    try testing.expect(std.mem.startsWith(u8, id1, "MEM-"));
    // ID = "MEM-" (4) + date (8) + "-" (1) + seq (3) = 16 chars minimum
    try testing.expect(id1.len >= 16);
    try testing.expect(std.mem.endsWith(u8, id1, "-001"));

    // Verify date portion is 8 digits followed by dash
    const after_mem = id1[4..];
    const dash_pos = std.mem.indexOfScalar(u8, after_mem, '-') orelse @as(usize, 0);
    try testing.expectEqual(@as(usize, 8), dash_pos);
    // Verify the 8 chars are all digits
    for (after_mem[0..8]) |c| {
        try testing.expect(c >= '0' and c <= '9');
    }

    // Test with existing content - verify it doesn't crash
    const existing =
        \\## [MEM-20260702-005] Test
        \\**source**: test
        \\
        \\Body
        \\
    ;
    const id2 = try generateId(a, io, existing);
    a.free(id2);
}

test "parse: extractTitle truncates at newline" {
    const testing = std.testing;
    const title = extractTitle("hello world\nsecond line");
    try testing.expectEqualStrings("hello world", title);
}

test "parse: extractTitle truncates at Chinese period" {
    const testing = std.testing;
    const title = extractTitle("第一段。第二段");
    try testing.expectEqualStrings("第一段", title);
}

test "parse: parseEntries with new fields defaults" {
    const testing = std.testing;
    const a = testing.allocator;

    const content =
        \\## [MEM-20260702-001] Test title
        \\**source**: test
        \\**pattern-key**: pk-1
        \\**priority**: high
        \\**logged**: 2026-07-02
        \\
        \\Body content here
        \\
    ;

    const entries = try parseEntries(a, content);
    defer a.free(entries);

    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqualStrings("MEM-20260702-001", entries[0].id);
    try testing.expectEqualStrings("high", entries[0].priority);
    // New fields should have defaults
    try testing.expectEqualStrings("project-specific", entries[0].scope);
    try testing.expectEqualStrings("new", entries[0].status);
    try testing.expectEqualStrings("pending", entries[0].handled);
    try testing.expectEqual(@as(usize, 1), entries[0].recurrence_count);
    try testing.expectEqual(false, entries[0].archived);
    try testing.expectEqualStrings("", entries[0].related_files);
}

test "parse: parseEntries with all new fields" {
    const testing = std.testing;
    const a = testing.allocator;

    const content =
        \\## [MEM-20260702-002] Full fields
        \\**source**: user
        \\**pattern-key**: full-test
        \\**priority**: critical
        \\**scope**: cross-project
        \\**status**: fixed
        \\**handled**: yes
        \\**recurrence-count**: 3
        \\**archived**: true
        \\**related-files**: src/main.zig
        \\**logged**: 2026-07-02
        \\
        \\Body
        \\
    ;

    const entries = try parseEntries(a, content);
    defer a.free(entries);

    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqualStrings("cross-project", entries[0].scope);
    try testing.expectEqualStrings("fixed", entries[0].status);
    try testing.expectEqualStrings("yes", entries[0].handled);
    try testing.expectEqual(@as(usize, 3), entries[0].recurrence_count);
    try testing.expectEqual(true, entries[0].archived);
    try testing.expectEqualStrings("src/main.zig", entries[0].related_files);
}

test "parse: parseEntries skips malformed entries" {
    const testing = std.testing;
    const a = testing.allocator;

    const content =
        \\## [MEM-20260702-003] Valid
        \\**source**: test
        \\
        \\Body
        \\
        \\## [INVALID]
        \\**source**: skip
        \\
        \\Skip
        \\
        \\## [MEM-20260702-004] Valid again
        \\**source**: test
        \\
        \\Body
        \\
    ;

    const entries = try parseEntries(a, content);
    defer a.free(entries);

    try testing.expectEqual(@as(usize, 2), entries.len);
    try testing.expectEqualStrings("MEM-20260702-003", entries[0].id);
    try testing.expectEqualStrings("MEM-20260702-004", entries[1].id);
}

test "parse: serializeEntry produces correct markdown" {
    const testing = std.testing;
    const a = testing.allocator;

    const entry = Entry{
        .id = "MEM-20260702-005",
        .title = "Serialize Test",
        .source = "test",
        .pattern_key = "ser-test",
        .priority = "medium",
        .scope = "project-specific",
        .status = "new",
        .handled = "pending",
        .recurrence_count = 1,
        .archived = false,
        .related_files = "",
        .logged = "2026-07-02",
        .raw = "",
        .preview = "",
    };

    const result = try serializeEntry(a, entry, "Hello world");
    defer a.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "## [MEM-20260702-005]") != null);
    try testing.expect(std.mem.indexOf(u8, result, "**source**: test") != null);
    try testing.expect(std.mem.indexOf(u8, result, "**scope**: project-specific") != null);
    try testing.expect(std.mem.indexOf(u8, result, "**status**: new") != null);
    try testing.expect(std.mem.indexOf(u8, result, "Hello world") != null);
    try testing.expect(std.mem.indexOf(u8, result, "**archived**: false") != null);
    try testing.expect(std.mem.indexOf(u8, result, "**recurrence-count**: 1") != null);
}

test "parse: serializeEntry archived true" {
    const testing = std.testing;
    const a = testing.allocator;

    const entry = Entry{
        .id = "MEM-20260702-006",
        .title = "Archived",
        .source = "auto",
        .pattern_key = "",
        .priority = "low",
        .scope = "project-specific",
        .status = "fixed",
        .handled = "yes",
        .recurrence_count = 2,
        .archived = true,
        .related_files = "notes.txt",
        .logged = "2026-07-01",
        .raw = "",
        .preview = "",
    };

    const result = try serializeEntry(a, entry, "Archived body");
    defer a.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "**archived**: true") != null);
    try testing.expect(std.mem.indexOf(u8, result, "**related-files**: notes.txt") != null);
    try testing.expect(std.mem.indexOf(u8, result, "**recurrence-count**: 2") != null);
    try testing.expect(std.mem.indexOf(u8, result, "**status**: fixed") != null);
}
