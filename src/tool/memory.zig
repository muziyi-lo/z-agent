const std = @import("std");
const json = @import("json.zig");
const root_dir = @import("root_dir.zig");
const ToolResult = @import("registry.zig").ToolResult;

pub const tool_name = "memory";
pub const tool_description = "Manage memory entries. Commands: add (add a memory entry), recall (search memory by keyword), delete (remove a memory entry by ID).";
pub const tool_params = "{\"type\":\"object\",\"properties\":{\"command\":{\"type\":\"string\",\"description\":\"Action: add, recall, or delete\"},\"content\":{\"type\":\"string\",\"description\":\"Content to remember (for add)\"},\"source\":{\"type\":\"string\",\"description\":\"Source label: 用户 or 自动 (for add, default: 自动)\"},\"pattern-key\":{\"type\":\"string\",\"description\":\"Unique key for dedup (for add, recommended)\"},\"title\":{\"type\":\"string\",\"description\":\"Override title (for add, auto-extracted from content)\"},\"query\":{\"type\":\"string\",\"description\":\"Search keyword (for recall)\"},\"id\":{\"type\":\"string\",\"description\":\"Entry ID like MEM-20260628-001 (for delete)\"}},\"required\":[\"command\",\"content\"]}";

const Entry = struct {
    id: []const u8,
    title: []const u8,
    source: []const u8,
    pattern_key: []const u8,
    priority: []const u8,
    logged: []const u8,
    /// Full raw text of the entry (includes header, metadata, content)
    raw: []const u8,
    /// First 200 chars of content body (for preview)
    preview: []const u8,
};

const ScoredEntry = struct {
    id: []const u8,
    title: []const u8,
    score: f64,
    preview: []const u8,
};

pub fn execute(allocator: std.mem.Allocator, io: std.Io, args: std.json.Value) ToolResult {
    if (args != .object) return ToolResult.fail(allocError(allocator, "args must be an object"));
    const args_obj = args.object;
    const command_val = args_obj.get("command") orelse return ToolResult.fail(allocError(allocator, "missing 'command'"));
    const command = if (command_val == .string) command_val.string else return ToolResult.fail(allocError(allocator, "'command' must be a string"));

    if (std.mem.eql(u8, command, "add")) {
        const output = cmdAdd(allocator, io, args_obj);
        if (std.mem.startsWith(u8, output, "Error:")) return ToolResult.fail(output);
        return ToolResult.ok(output);
    } else if (std.mem.eql(u8, command, "recall")) {
        const output = cmdRecall(allocator, io, args_obj);
        if (std.mem.startsWith(u8, output, "Error:")) return ToolResult.fail(output);
        return ToolResult.ok(output);
    } else if (std.mem.eql(u8, command, "delete")) {
        const output = cmdDelete(allocator, io, args_obj);
        if (std.mem.startsWith(u8, output, "Error:")) return ToolResult.fail(output);
        return ToolResult.ok(output);
    } else {
        return ToolResult.fail(std.fmt.allocPrint(allocator, "Error: unknown command '{s}'", .{command}) catch allocOomError(allocator));
    }
}

// ---------------------------------------------------------------------------
// Path & file helpers
// ---------------------------------------------------------------------------

fn memoryPath(allocator: std.mem.Allocator) ![]const u8 {
    if (root_dir.project_root.len > 0) {
        return std.fs.path.join(allocator, &.{ root_dir.project_root, ".zagent", "memory.md" });
    }
    return std.fs.path.join(allocator, &.{ ".zagent", "memory.md" });
}

fn readFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ?[]const u8 {
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

fn writeFile(io: std.Io, path: []const u8, content: []const u8) void {
    if (std.fs.path.dirname(path)) |parent| {
        std.Io.Dir.cwd().createDirPath(io, parent) catch {};
    }
    const file = std.Io.Dir.cwd().createFile(io, path, .{}) catch return;
    defer file.close(io);
    file.writeStreamingAll(io, content) catch {};
}

fn todayDateString(io: std.Io) [8]u8 {
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

fn todayFormattedDate(io: std.Io) [10]u8 {
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
// Entry parsing
// ---------------------------------------------------------------------------

fn parseEntries(allocator: std.mem.Allocator, content: []const u8) ![]Entry {
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

        // --- Parse header: "## [MEM-YYYYMMDD-NNN] title" ---
        const id_start = start + 4; // skip "## ["
        const id_end = std.mem.indexOfScalarPos(u8, content, id_start, ']') orelse {
            scan_pos = end;
            continue;
        };
        const id = content[id_start..id_end];

        const title = if (id_end + 2 < header_end) t: {
            const raw_title = std.mem.trim(u8, content[id_end + 2 .. header_end], " \r");
            break :t raw_title;
        } else "";

        // --- Parse metadata lines (after header, before first blank line) ---
        var source: []const u8 = "";
        var pattern_key: []const u8 = "";
        var priority: []const u8 = "medium";
        var logged: []const u8 = "";

        var meta_pos = header_end + 1;
        while (meta_pos < end) {
            const line_end = std.mem.indexOfScalarPos(u8, content, meta_pos, '\n') orelse end;
            const line = std.mem.trim(u8, content[meta_pos..line_end], " \r");
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
            } else if (std.mem.startsWith(u8, line, "**logged**:")) {
                logged = std.mem.trim(u8, line["**logged**:".len..], " ");
            }
            meta_pos = line_end + 1;
        }

        // Preview: first 200 chars of body
        const body_start = meta_pos;
        const preview_len = @min(end - body_start, @as(usize, 200));
        const preview = std.mem.trim(u8, content[body_start .. body_start + preview_len], " \r\n\t");

        try entries.append(.{
            .id = id,
            .title = title,
            .source = source,
            .pattern_key = pattern_key,
            .priority = priority,
            .logged = logged,
            .raw = entry_text,
            .preview = preview,
        });

        scan_pos = end;
    }

    return entries.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// ID generation
// ---------------------------------------------------------------------------

fn generateId(allocator: std.mem.Allocator, io: std.Io, existing_content: ?[]const u8) ![]const u8 {
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
// Anchor checks
// ---------------------------------------------------------------------------

const CHECK_SOURCE: usize = 0;
const CHECK_PK: usize = 1;
const CHECK_KW: usize = 2;
const CHECK_PATH: usize = 3;

fn containsEventKeywords(content: []const u8) bool {
    const keywords = [_][]const u8{ "error", "exit code", "路径", "报错", "失败", "warn", "fail", "命令" };
    for (keywords) |kw| {
        if (indexOfIgnoreCase(content, kw)) return true;
    }
    return false;
}

fn containsPathPattern(content: []const u8) bool {
    // Check for path separator ('/' or '\') surrounded by regular chars
    for (content, 0..) |c, i| {
        if (c == '/' or c == '\\') {
            if (i > 0 and i < content.len - 1) return true;
        }
    }
    // Check for common file extensions
    const extensions = [_][]const u8{ ".zig", ".md", ".json", ".toml", ".js", ".py", ".rs", ".ts", ".go", ".c", ".h", ".cpp", ".java", ".rs", ".zig", ".yaml", ".yml" };
    for (extensions) |ext| {
        if (std.mem.indexOf(u8, content, ext) != null) return true;
    }
    return false;
}

/// Returns an error message if anchors are insufficient, or null if OK.
fn checkAnchors(content: []const u8, source: []const u8, pattern_key: []const u8) ?[]const u8 {
    const source_valid = source.len > 0 and !std.mem.eql(u8, source, "自动");
    const pk_valid = pattern_key.len > 0;
    const kw_valid = containsEventKeywords(content);
    const path_valid = containsPathPattern(content);

    if (source_valid or pk_valid or kw_valid or path_valid) return null;

    // Build description of what was missing
    var parts: [4][]const u8 = undefined;
    var count: usize = 0;
    if (!source_valid) { parts[count] = "source 非空且非'自动'"; count += 1; }
    if (!pk_valid) { parts[count] = "pattern-key 有值"; count += 1; }
    if (!kw_valid) { parts[count] = "含事件关键词(error/exit code/路径等)"; count += 1; }
    if (!path_valid) { parts[count] = "含路径模式(.../... 或 *.zig 等)"; count += 1; }

    return "Error: 缺少可验证锚点，需要至少满足一项：source 非空且非'自动'、pattern-key 有值、含事件关键词、含路径模式";
}

// ---------------------------------------------------------------------------
// Title extraction
// ---------------------------------------------------------------------------

fn extractTitle(content: []const u8) []const u8 {
    const end = std.mem.indexOfAny(u8, content, "\n。") orelse content.len;
    const len = @min(end, @as(usize, 60));
    return std.mem.trim(u8, content[0..len], " \r\n\t");
}

// ---------------------------------------------------------------------------
// CJK bigram tokenization
// ---------------------------------------------------------------------------

fn isCJKStart(b: u8) bool {
    return b >= 0xE0 and b <= 0xEF;
}

fn cjkBigrams(allocator: std.mem.Allocator, query: []const u8) ![][]const u8 {
    // First collect all CJK character positions
    var cjk_chars = std.array_list.Managed(u8).init(allocator);
    defer cjk_chars.deinit();

    var i: usize = 0;
    while (i < query.len) {
        const b = query[i];
        if (isCJKStart(b) and i + 2 < query.len) {
            // Valid CJK char (3 bytes)
            try cjk_chars.appendSlice(query[i .. i + 3]);
            i += 3;
        } else {
            i += 1;
        }
    }

    const chars = cjk_chars.items;
    if (chars.len < 6) return allocator.alloc([]const u8, 0); // fewer than 2 CJK chars

    // Generate overlapping bigrams
    var bigrams = std.array_list.Managed([]const u8).init(allocator);
    var j: usize = 0;
    while (j + 6 <= chars.len) : (j += 3) {
        const bg = try allocator.dupe(u8, chars[j .. j + 6]);
        try bigrams.append(bg);
    }

    return bigrams.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// indexOfIgnoreCase (kept for body substring matching)
// ---------------------------------------------------------------------------

fn indexOfIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i <= haystack.len - needle.len) : (i += 1) {
        var matched = true;
        for (needle, 0..) |nc, j| {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(nc)) {
                matched = false;
                break;
            }
        }
        if (matched) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// cmdAdd
// ---------------------------------------------------------------------------

fn cmdAdd(allocator: std.mem.Allocator, io: std.Io, args: std.json.ObjectMap) []const u8 {
    const content_val = args.get("content") orelse return allocError(allocator, "missing 'content' for add");
    const content = if (content_val == .string) content_val.string else return allocError(allocator, "'content' must be a string");

    const source = if (args.get("source")) |v| if (v == .string) v.string else "自动" else "自动";
    const pattern_key = if (args.get("pattern-key")) |v| if (v == .string and v.string.len > 0) v.string else "" else "";
    const title_override = if (args.get("title")) |v| if (v == .string) v.string else "" else "";

    const mem_path = memoryPath(allocator) catch return allocOomError(allocator);
    defer allocator.free(mem_path);

    // Read existing content
    const existing_content = readFile(allocator, io, mem_path);
    defer if (existing_content) |c| allocator.free(c);

    // Gatekeeping: check anchors
    const anchor_err = checkAnchors(content, source, pattern_key);
    if (anchor_err) |err| {
        return std.fmt.allocPrint(allocator, "{s}", .{err}) catch allocOomError(allocator);
    }

    // Dedup: if pattern-key provided, scan existing entries
    if (pattern_key.len > 0) {
        if (existing_content) |content_data| {
            const entries = parseEntries(allocator, content_data) catch return allocOomError(allocator);
            defer {
                allocator.free(entries);
            }
            for (entries) |entry| {
                if (std.mem.eql(u8, entry.pattern_key, pattern_key)) {
                    // Dedup hit: return existing ID
                    var buf = std.array_list.Managed(u8).init(allocator);
                    defer buf.deinit();
                    json.puts(&buf, "{\"id\":") catch return allocOomError(allocator);
                    json.escapeJson(&buf, entry.id) catch return allocOomError(allocator);
                    json.puts(&buf, ",\"dedup\":true}") catch return allocOomError(allocator);
                    return json.finish(&buf);
                }
            }
        }
    }

    // Generate ID
    const id = generateId(allocator, io, existing_content) catch return allocOomError(allocator);
    defer allocator.free(id);

    // Auto-title
    const title = if (title_override.len > 0) title_override else extractTitle(content);

    // Date string
    const date_formatted = todayFormattedDate(io);

    // Build entry text
    var entry_buf = std.array_list.Managed(u8).init(allocator);
    defer entry_buf.deinit();

    // Format entry using pre-formatted strings
    {
        const line = std.fmt.allocPrint(allocator, "## [{s}] {s}\n", .{ id, title }) catch return allocOomError(allocator);
        defer allocator.free(line);
        entry_buf.appendSlice(line) catch return allocOomError(allocator);
    }
    {
        const line = std.fmt.allocPrint(allocator, "**source**: {s}\n", .{source}) catch return allocOomError(allocator);
        defer allocator.free(line);
        entry_buf.appendSlice(line) catch return allocOomError(allocator);
    }
    {
        const line = std.fmt.allocPrint(allocator, "**pattern-key**: {s}\n", .{pattern_key}) catch return allocOomError(allocator);
        defer allocator.free(line);
        entry_buf.appendSlice(line) catch return allocOomError(allocator);
    }
    {
        const line = std.fmt.allocPrint(allocator, "**priority**: medium\n", .{}) catch return allocOomError(allocator);
        defer allocator.free(line);
        entry_buf.appendSlice(line) catch return allocOomError(allocator);
    }
    {
        const line = std.fmt.allocPrint(allocator, "**logged**: {s}\n", .{&date_formatted}) catch return allocOomError(allocator);
        defer allocator.free(line);
        entry_buf.appendSlice(line) catch return allocOomError(allocator);
    }
    entry_buf.appendSlice("\n") catch return allocOomError(allocator);
    entry_buf.appendSlice(content) catch return allocOomError(allocator);
    entry_buf.appendSlice("\n") catch return allocOomError(allocator);

    const new_entry = entry_buf.items;

    // Append to file
    var full_content = std.array_list.Managed(u8).init(allocator);
    defer full_content.deinit();

    if (existing_content) |existing| {
        full_content.appendSlice(existing) catch return allocOomError(allocator);
        // Add separator if existing content doesn't end with one
        if (existing.len > 0 and !std.mem.endsWith(u8, existing, "\n---\n\n")) {
            full_content.appendSlice("\n---\n\n") catch return allocOomError(allocator);
        }
    }

    full_content.appendSlice(new_entry) catch return allocOomError(allocator);
    writeFile(io, mem_path, full_content.items);

    // Build JSON result
    var buf = std.array_list.Managed(u8).init(allocator);
    defer buf.deinit();
    json.puts(&buf, "{\"id\":") catch return allocOomError(allocator);
    json.escapeJson(&buf, id) catch return allocOomError(allocator);
    json.puts(&buf, ",\"title\":") catch return allocOomError(allocator);
    json.escapeJson(&buf, title) catch return allocOomError(allocator);
    json.puts(&buf, "}") catch return allocOomError(allocator);
    return json.finish(&buf);
}

// ---------------------------------------------------------------------------
// cmdRecall
// ---------------------------------------------------------------------------

fn cmdRecall(allocator: std.mem.Allocator, io: std.Io, args: std.json.ObjectMap) []const u8 {
    const query_val = args.get("query") orelse return allocError(allocator, "missing 'query' for recall");
    const query = if (query_val == .string) query_val.string else return allocError(allocator, "'query' must be a string");

    const mem_path = memoryPath(allocator) catch return allocOomError(allocator);
    defer allocator.free(mem_path);

    const content = readFile(allocator, io, mem_path) orelse {
        return std.fmt.allocPrint(allocator, "{{\"results\":[]}}", .{}) catch allocOomError(allocator);
    };
    defer allocator.free(content);

    // Parse entries
    const entries = parseEntries(allocator, content) catch return allocOomError(allocator);
    defer allocator.free(entries);

    // Generate CJK bigrams from query
    const bigrams = cjkBigrams(allocator, query) catch return allocOomError(allocator);
    defer allocator.free(bigrams);

    // Score each entry
    var scored_list = std.array_list.Managed(ScoredEntry).init(allocator);
    defer scored_list.deinit();

    for (entries) |entry| {
        var score: f64 = 0;

        // Level 1: pattern-key exact match → 0.8
        if (entry.pattern_key.len > 0 and std.mem.eql(u8, entry.pattern_key, query)) {
            score = 0.8;
        } else {
            // Level 2: pattern-key substring match → 0.6
            if (entry.pattern_key.len > 0 and indexOfIgnoreCase(entry.pattern_key, query)) {
                score = 0.6;
            }
            // Level 3: source match → 0.4
            if (score == 0 and entry.source.len > 0 and indexOfIgnoreCase(entry.source, query)) {
                score = 0.4;
            }
            // Level 4: body substring match → 0.2
            if (score == 0 and indexOfIgnoreCase(entry.raw, query)) {
                score = 0.2;
            }
        }

        // CJK bigram boost: if we matched via content, check for bigram hits
        if (score > 0 and bigrams.len > 0) {
            var bigram_hits: usize = 0;
            for (bigrams) |bg| {
                if (indexOfIgnoreCase(entry.raw, bg)) {
                    bigram_hits += 1;
                }
            }
            score += @as(f64, @floatFromInt(bigram_hits)) / @as(f64, @floatFromInt(bigrams.len)) * 0.1;
        }

        if (score > 0) {
            scored_list.append(.{
                .id = entry.id,
                .title = entry.title,
                .score = score,
                .preview = entry.preview,
            }) catch return allocOomError(allocator);
        }
    }

    // Sort by score descending
    std.mem.sort(ScoredEntry, scored_list.items, {}, lessThanByScore);

    // Take top 10
    const top = scored_list.items[0..@min(scored_list.items.len, @as(usize, 10))];

    // Build JSON
    var buf = std.array_list.Managed(u8).init(allocator);
    defer buf.deinit();
    json.puts(&buf, "{\"results\":[") catch return allocOomError(allocator);

    for (top, 0..) |entry, i| {
        if (i > 0) json.putc(&buf, ',') catch return allocOomError(allocator);
        json.putc(&buf, '{') catch return allocOomError(allocator);
        json.putString(&buf, "id", entry.id) catch return allocOomError(allocator);
        json.putc(&buf, ',') catch return allocOomError(allocator);
        json.putString(&buf, "title", entry.title) catch return allocOomError(allocator);
        json.putc(&buf, ',') catch return allocOomError(allocator);
        json.putKey(&buf, "score") catch return allocOomError(allocator);
        var score_buf: [32]u8 = undefined;
        const score_str = std.fmt.bufPrint(&score_buf, "{d:.2}", .{entry.score}) catch "0.00";
        json.puts(&buf, score_str) catch return allocOomError(allocator);
        json.putc(&buf, ',') catch return allocOomError(allocator);
        json.putString(&buf, "preview", entry.preview) catch return allocOomError(allocator);
        json.putc(&buf, '}') catch return allocOomError(allocator);
    }

    json.puts(&buf, "]}") catch return allocOomError(allocator);
    return json.finish(&buf);
}

fn lessThanByScore(_: void, a: ScoredEntry, b: ScoredEntry) bool {
    return a.score > b.score;
}

// ---------------------------------------------------------------------------
// cmdDelete
// ---------------------------------------------------------------------------

fn cmdDelete(allocator: std.mem.Allocator, io: std.Io, args: std.json.ObjectMap) []const u8 {
    const id_val = args.get("id") orelse return allocError(allocator, "missing 'id' for delete");
    const id = if (id_val == .string) id_val.string else return allocError(allocator, "'id' must be a string");

    const mem_path = memoryPath(allocator) catch return allocOomError(allocator);
    defer allocator.free(mem_path);

    const content = readFile(allocator, io, mem_path) orelse {
        return std.fmt.allocPrint(allocator, "{{\"deleted\":false,\"error\":\"not found\"}}", .{}) catch allocOomError(allocator);
    };
    defer allocator.free(content);

    const entries = parseEntries(allocator, content) catch return allocOomError(allocator);
    defer allocator.free(entries);

    // Check if entry exists
    var found = false;
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.id, id)) {
            found = true;
            break;
        }
    }
    if (!found) {
        return std.fmt.allocPrint(allocator, "{{\"deleted\":false,\"error\":\"not found\"}}", .{}) catch allocOomError(allocator);
    }

    // Rebuild file without the deleted entry
    var new_content = std.array_list.Managed(u8).init(allocator);
    defer new_content.deinit();

    for (entries) |entry| {
        if (std.mem.eql(u8, entry.id, id)) continue;
        if (new_content.items.len > 0) {
            new_content.appendSlice("\n---\n\n") catch return allocOomError(allocator);
        }
        new_content.appendSlice(entry.raw) catch return allocOomError(allocator);
    }

    writeFile(io, mem_path, new_content.items);

    return std.fmt.allocPrint(allocator, "{{\"deleted\":true}}", .{}) catch allocOomError(allocator);
}

// ---------------------------------------------------------------------------
// Error helpers
// ---------------------------------------------------------------------------

fn allocError(allocator: std.mem.Allocator, msg: []const u8) []const u8 {
    return std.fmt.allocPrint(allocator, "Error: {s}", .{msg}) catch allocOomError(allocator);
}

fn allocOomError(allocator: std.mem.Allocator) []const u8 {
    return std.fmt.allocPrint(allocator, "Error: OOM", .{}) catch "Error: OOM";
}

// ---------------------------------------------------------------------------
// Test cleanup
// ---------------------------------------------------------------------------

fn cleanupTestDir(io: std.Io) void {
    _ = std.Io.Dir.cwd().deleteFile(io, "zig_test_memory_root/.zagent/memory.md") catch {};
    _ = std.Io.Dir.cwd().deleteDir(io, "zig_test_memory_root/.zagent") catch {};
    _ = std.Io.Dir.cwd().deleteDir(io, "zig_test_memory_root") catch {};
}

// ===========================================================================
// Tests
// ===========================================================================

test "memory: add creates entry and returns JSON with id and title" {
    const testing = std.testing;
    const a = testing.allocator;
    const io = testing.io;

    root_dir.init("zig_test_memory_root");
    defer {
        root_dir.init("");
        cleanupTestDir(io);
    }

    const args_json = try std.fmt.allocPrint(a, "{{\"command\":\"add\",\"content\":\"测试记忆内容\",\"source\":\"test-source\"}}", .{});
    defer a.free(args_json);
    var parsed = try std.json.parseFromSlice(std.json.Value, a, args_json, .{});
    defer parsed.deinit();

    const tr = execute(a, io, parsed.value);
    defer a.free(tr.output);

    try testing.expect(tr.success);
    try testing.expect(std.mem.startsWith(u8, tr.output, "{"));
    try testing.expect(std.mem.indexOf(u8, tr.output, "\"id\"") != null);
    try testing.expect(std.mem.indexOf(u8, tr.output, "\"MEM-") != null);
    try testing.expect(std.mem.indexOf(u8, tr.output, "\"title\"") != null);
}

test "memory: recall finds matching entry" {
    const testing = std.testing;
    const a = testing.allocator;
    const io = testing.io;

    root_dir.init("zig_test_memory_root");
    defer {
        root_dir.init("");
        cleanupTestDir(io);
    }

    // First add an entry
    {
        const add_json = try std.fmt.allocPrint(a, "{{\"command\":\"add\",\"content\":\"test keyword for recall\",\"source\":\"test\"}}", .{});
        defer a.free(add_json);
        var parsed = try std.json.parseFromSlice(std.json.Value, a, add_json, .{});
        defer parsed.deinit();
        const tr = execute(a, io, parsed.value);
        defer a.free(tr.output);
        try testing.expect(tr.success);
    }

    // Now recall it
    const recall_json = try std.fmt.allocPrint(a, "{{\"command\":\"recall\",\"query\":\"keyword\"}}", .{});
    defer a.free(recall_json);
    var parsed = try std.json.parseFromSlice(std.json.Value, a, recall_json, .{});
    defer parsed.deinit();

    const tr = execute(a, io, parsed.value);
    defer a.free(tr.output);

    try testing.expect(tr.success);
    try testing.expect(std.mem.startsWith(u8, tr.output, "{"));
    try testing.expect(std.mem.indexOf(u8, tr.output, "\"results\"") != null);
    try testing.expect(std.mem.indexOf(u8, tr.output, "\"preview\"") != null);
    try testing.expect(std.mem.indexOf(u8, tr.output, "\"score\"") != null);
    try testing.expect(std.mem.indexOf(u8, tr.output, "MEM-") != null);
}

test "memory: delete removes entry" {
    const testing = std.testing;
    const a = testing.allocator;
    const io = testing.io;

    root_dir.init("zig_test_memory_root");
    defer {
        root_dir.init("");
        cleanupTestDir(io);
    }

    // Add an entry and capture its ID
    var mem_id: ?[]const u8 = null;
    {
        const add_json = try std.fmt.allocPrint(a, "{{\"command\":\"add\",\"content\":\"待删除内容\",\"source\":\"test\"}}", .{});
        defer a.free(add_json);
        var parsed = try std.json.parseFromSlice(std.json.Value, a, add_json, .{});
        defer parsed.deinit();
        const tr = execute(a, io, parsed.value);
        defer a.free(tr.output);
        try testing.expect(tr.success);

        // Extract ID from JSON result
        var parsed_res = try std.json.parseFromSlice(std.json.Value, a, tr.output, .{});
        defer parsed_res.deinit();
        if (parsed_res.value.object.get("id")) |id_val| {
            mem_id = try a.dupe(u8, id_val.string);
        }
    }
    try testing.expect(mem_id != null);
    defer if (mem_id) |id| a.free(id);

    // Delete the entry
    const del_json = try std.fmt.allocPrint(a, "{{\"command\":\"delete\",\"id\":\"{s}\"}}", .{mem_id.?});
    defer a.free(del_json);
    var parsed = try std.json.parseFromSlice(std.json.Value, a, del_json, .{});
    defer parsed.deinit();

    const tr = execute(a, io, parsed.value);
    defer a.free(tr.output);

    try testing.expect(tr.success);
    try testing.expect(std.mem.startsWith(u8, tr.output, "{"));
    try testing.expect(std.mem.indexOf(u8, tr.output, "\"deleted\":true") != null);

    // Verify the ID is no longer in the file
    const mem_path = try memoryPath(a);
    defer a.free(mem_path);
    const file_content = readFile(a, io, mem_path) orelse return;
    defer a.free(file_content);
    try testing.expect(std.mem.indexOf(u8, file_content, mem_id.?) == null);
}

test "memory: missing command returns error" {
    const testing = std.testing;
    const a = testing.allocator;
    const io = testing.io;

    var parsed = try std.json.parseFromSlice(std.json.Value, a, "{}", .{});
    defer parsed.deinit();

    const tr = execute(a, io, parsed.value);
    defer a.free(tr.output);
    try testing.expect(!tr.success);
    try testing.expect(std.mem.startsWith(u8, tr.output, "Error:"));
    try testing.expect(std.mem.indexOf(u8, tr.output, "command") != null);
}

test "memory: missing content for add returns error" {
    const testing = std.testing;
    const a = testing.allocator;
    const io = testing.io;

    var parsed = try std.json.parseFromSlice(std.json.Value, a, "{\"command\":\"add\"}", .{});
    defer parsed.deinit();

    const tr = execute(a, io, parsed.value);
    defer a.free(tr.output);
    try testing.expect(!tr.success);
    try testing.expect(std.mem.startsWith(u8, tr.output, "Error:"));
    try testing.expect(std.mem.indexOf(u8, tr.output, "content") != null);
}

test "memory: missing query for recall returns error" {
    const testing = std.testing;
    const a = testing.allocator;
    const io = testing.io;

    var parsed = try std.json.parseFromSlice(std.json.Value, a, "{\"command\":\"recall\"}", .{});
    defer parsed.deinit();

    const tr = execute(a, io, parsed.value);
    defer a.free(tr.output);
    try testing.expect(!tr.success);
    try testing.expect(std.mem.startsWith(u8, tr.output, "Error:"));
    try testing.expect(std.mem.indexOf(u8, tr.output, "query") != null);
}

test "indexOfIgnoreCase: basic matching and error paths" {
    const testing = std.testing;

    try testing.expect(indexOfIgnoreCase("Hello World", "WORLD"));
    try testing.expect(indexOfIgnoreCase("Hello World", "hello"));
    try testing.expect(indexOfIgnoreCase("HELLO", "hello"));
    try testing.expect(indexOfIgnoreCase("anything", ""));
    try testing.expect(!indexOfIgnoreCase("abc", "abcd"));
    try testing.expect(!indexOfIgnoreCase("abc", "xyz"));
    try testing.expect(!indexOfIgnoreCase("", "x"));
    try testing.expect(indexOfIgnoreCase("", ""));
    try testing.expect(indexOfIgnoreCase("find the END", "end"));
    try testing.expect(indexOfIgnoreCase("ABC-DEF-GHI", "def"));
}

test "memory: unknown command returns error" {
    const testing = std.testing;
    const a = testing.allocator;
    const io = testing.io;

    var parsed = try std.json.parseFromSlice(std.json.Value, a, "{\"command\":\"nonexistent\"}", .{});
    defer parsed.deinit();

    const tr = execute(a, io, parsed.value);
    defer a.free(tr.output);
    try testing.expect(!tr.success);
    try testing.expect(std.mem.startsWith(u8, tr.output, "Error:"));
    try testing.expect(std.mem.indexOf(u8, tr.output, "unknown") != null);
}

test "memory: gatekeeping rejects missing anchors" {
    const testing = std.testing;
    const a = testing.allocator;
    const io = testing.io;

    root_dir.init("zig_test_memory_root");
    defer {
        root_dir.init("");
        cleanupTestDir(io);
    }

    // Content without any anchor (no keywords, no path pattern, source=自动, no pattern-key)
    const args_json = try std.fmt.allocPrint(a, "{{\"command\":\"add\",\"content\":\"普通描述性文字\",\"source\":\"自动\"}}", .{});
    defer a.free(args_json);
    var parsed = try std.json.parseFromSlice(std.json.Value, a, args_json, .{});
    defer parsed.deinit();

    const tr = execute(a, io, parsed.value);
    defer a.free(tr.output);

    try testing.expect(!tr.success);
    try testing.expect(std.mem.indexOf(u8, tr.output, "锚点") != null);
}

test "memory: dedup by pattern-key returns existing id" {
    const testing = std.testing;
    const a = testing.allocator;
    const io = testing.io;

    root_dir.init("zig_test_memory_root");
    defer {
        root_dir.init("");
        cleanupTestDir(io);
    }

    // Add first entry with pattern-key
    const add_json1 = try std.fmt.allocPrint(a, "{{\"command\":\"add\",\"content\":\"第一条内容\",\"source\":\"test\",\"pattern-key\":\"unique-key-001\"}}", .{});
    defer a.free(add_json1);
    var parsed1 = try std.json.parseFromSlice(std.json.Value, a, add_json1, .{});
    defer parsed1.deinit();
    const tr1 = execute(a, io, parsed1.value);
    defer a.free(tr1.output);
    try testing.expect(tr1.success);

    // Extract first ID
    var parsed_res1 = try std.json.parseFromSlice(std.json.Value, a, tr1.output, .{});
    defer parsed_res1.deinit();
    const first_id = try a.dupe(u8, parsed_res1.value.object.get("id").?.string);
    defer a.free(first_id);

    // Add second entry with same pattern-key → should return existing ID
    const add_json2 = try std.fmt.allocPrint(a, "{{\"command\":\"add\",\"content\":\"第二条内容(应去重)\",\"source\":\"test\",\"pattern-key\":\"unique-key-001\"}}", .{});
    defer a.free(add_json2);
    var parsed2 = try std.json.parseFromSlice(std.json.Value, a, add_json2, .{});
    defer parsed2.deinit();
    const tr2 = execute(a, io, parsed2.value);
    defer a.free(tr2.output);

    try testing.expect(tr2.success);
    try testing.expect(std.mem.indexOf(u8, tr2.output, "\"dedup\":true") != null);
    try testing.expect(std.mem.indexOf(u8, tr2.output, first_id) != null);
}

test "memory: weighted ranking" {
    const testing = std.testing;
    const a = testing.allocator;
    const io = testing.io;

    root_dir.init("zig_test_memory_root");
    defer {
        root_dir.init("");
        cleanupTestDir(io);
    }

    // Add entries with different pattern-keys
    // Entry A: pattern-key = "zig-compiler"
    {
        const j = try std.fmt.allocPrint(a, "{{\"command\":\"add\",\"content\":\"Zig compiler location and build configuration\",\"source\":\"auto\",\"pattern-key\":\"zig-compiler\"}}", .{});
        defer a.free(j);
        var p = try std.json.parseFromSlice(std.json.Value, a, j, .{});
        defer p.deinit();
        const r = execute(a, io, p.value);
        defer a.free(r.output);
        try testing.expect(r.success);
    }
    // Entry B: pattern-key = "workspace-layout"
    {
        const j = try std.fmt.allocPrint(a, "{{\"command\":\"add\",\"content\":\"Workspace layout structure for projects\",\"source\":\"auto\",\"pattern-key\":\"workspace-layout\"}}", .{});
        defer a.free(j);
        var p = try std.json.parseFromSlice(std.json.Value, a, j, .{});
        defer p.deinit();
        const r = execute(a, io, p.value);
        defer a.free(r.output);
        try testing.expect(r.success);
    }
    // Entry C: some random content about zig
    {
        const j = try std.fmt.allocPrint(a, "{{\"command\":\"add\",\"content\":\"Mention of zig build system\",\"source\":\"user\"}}", .{});
        defer a.free(j);
        var p = try std.json.parseFromSlice(std.json.Value, a, j, .{});
        defer p.deinit();
        const r = execute(a, io, p.value);
        defer a.free(r.output);
        try testing.expect(r.success);
    }

    // Recall with query matching entry A's pattern-key exactly
    const recall_json = try std.fmt.allocPrint(a, "{{\"command\":\"recall\",\"query\":\"zig-compiler\"}}", .{});
    defer a.free(recall_json);
    var parsed = try std.json.parseFromSlice(std.json.Value, a, recall_json, .{});
    defer parsed.deinit();

    const tr = execute(a, io, parsed.value);
    defer a.free(tr.output);

    try testing.expect(tr.success);
    // Entry A (pattern-key exact match) should be first result with score 0.80
    try testing.expect(std.mem.indexOf(u8, tr.output, "\"score\":0.80") != null);
}

test "memory: single file append" {
    const testing = std.testing;
    const a = testing.allocator;
    const io = testing.io;

    root_dir.init("zig_test_memory_root");
    defer {
        root_dir.init("");
        cleanupTestDir(io);
    }

    // Add first entry
    {
        const j = try std.fmt.allocPrint(a, "{{\"command\":\"add\",\"content\":\"第一条记忆\",\"source\":\"test\"}}", .{});
        defer a.free(j);
        var p = try std.json.parseFromSlice(std.json.Value, a, j, .{});
        defer p.deinit();
        const r = execute(a, io, p.value);
        defer a.free(r.output);
        try testing.expect(r.success);
    }

    // Add second entry
    {
        const j = try std.fmt.allocPrint(a, "{{\"command\":\"add\",\"content\":\"第二条记忆\",\"source\":\"test\"}}", .{});
        defer a.free(j);
        var p = try std.json.parseFromSlice(std.json.Value, a, j, .{});
        defer p.deinit();
        const r = execute(a, io, p.value);
        defer a.free(r.output);
        try testing.expect(r.success);
    }

    // Read the file and verify both entries exist
    const mem_path = try memoryPath(a);
    defer a.free(mem_path);
    const file_content = readFile(a, io, mem_path) orelse {
        try testing.expect(false); // file should exist
        return;
    };
    defer a.free(file_content);

    // Count entries
    var count: usize = 0;
    var pos: usize = 0;
    while (true) {
        const marker = std.mem.indexOfPos(u8, file_content, pos, "## [MEM-") orelse break;
        count += 1;
        pos = marker + 1;
    }
    try testing.expectEqual(@as(usize, 2), count);
}
