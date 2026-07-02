const std = @import("std");
const json = @import("../json.zig");
const parse = @import("parse.zig");
const session = @import("session.zig");
const root_dir = @import("../root_dir.zig");
const types = @import("types.zig");

const Entry = types.Entry;
const Io = std.Io;

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

/// Snapshot of memory.md at a point in time, used for consistency checking.
pub const Snapshot = struct {
    mtime: u64,
    size: u64,
    crc32: u32,
};

/// A changeset representing a proposed, approved, or applied modification to memory.md.
pub const ChangeSet = struct {
    id: []const u8,
    hard_case_id: []const u8,
    title: []const u8,
    summary: []const u8,
    old_entry: ?[]const u8,
    new_entry: []const u8,
    status: []const u8, // "draft" | "proposed" | "approved" | "applied" | "rejected" | "rolled_back"
    created: []const u8, // ISO8601
    applied: ?[]const u8, // ISO8601, null if not yet applied
    confidence: f64,
    snapshot: ?Snapshot,
};

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

/// Confidence threshold above which changesets are auto-approved.
const auto_approve_threshold: f64 = 0.75;

/// Confidence threshold below which changesets are draft.
const draft_threshold: f64 = 0.5;

/// CJK Unified Ideographs start codepoint (U+4E00).
const cjk_start: u21 = 0x4E00;

/// CJK Unified Ideographs end codepoint (U+9FFF).
const cjk_end: u21 = 0x9FFF;

// ---------------------------------------------------------------------------
// Changeset directory path
// ---------------------------------------------------------------------------

/// Build path to changesets directory under project_root/.zagent/.
/// Caller owns returned slice, must free.
fn changesetsDir(allocator: std.mem.Allocator) ![]const u8 {
    if (root_dir.project_root.len > 0) {
        return std.fs.path.join(allocator, &.{ root_dir.project_root, ".zagent", "changesets" });
    }
    return std.fs.path.join(allocator, &.{ ".zagent", "changesets" });
}

/// Build path to a changeset JSON file.
/// Caller owns returned slice, must free.
pub fn changesetPath(allocator: std.mem.Allocator, id: []const u8) ![]const u8 {
    const dir = try changesetsDir(allocator);
    defer allocator.free(dir);
    return std.fs.path.join(allocator, &.{ dir, id });
}

// ---------------------------------------------------------------------------
// CRC32 helper
// ---------------------------------------------------------------------------

/// Compute CRC32 of content using std.hash.Crc32.
/// Source: tool/memory/designer.zig — checksum for snapshot verification
pub fn computeCrc32(content: []const u8) u32 {
    var crc = std.hash.Crc32.init();
    crc.update(content);
    return crc.final();
}

// ---------------------------------------------------------------------------
// File info helpers
// ---------------------------------------------------------------------------

/// Get file mtime, size, and CRC32. Returns null on I/O error.
/// Source: tool/memory/designer.zig — snapshot creation for consistency check
pub fn getFileInfo(allocator: std.mem.Allocator, io: Io, path: []const u8) ?Snapshot {
    const file = Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only }) catch return null;
    defer file.close(io);
    const stat = file.stat(io) catch return null;
    const size: u64 = @intCast(stat.size);
    // Read content for CRC32
    if (size == 0) {
        return Snapshot{
            .mtime = @as(u64, @intCast(stat.mtime.nanoseconds)),
            .size = 0,
            .crc32 = 0,
        };
    }
    const content = allocator.alloc(u8, @as(usize, @intCast(size))) catch return null;
    defer allocator.free(content);
    _ = file.readPositionalAll(io, content, 0) catch return null;
    return Snapshot{
        .mtime = @as(u64, @intCast(stat.mtime.nanoseconds)),
        .size = size,
        .crc32 = computeCrc32(content),
    };
}

// ---------------------------------------------------------------------------
// Changeset file management
// ---------------------------------------------------------------------------

/// Load a changeset from its JSON file. Caller owns returned ChangeSet and all its fields.
/// Source: tool/memory/designer.zig — changeset persistence
pub fn loadChangeSet(allocator: std.mem.Allocator, io: Io, id: []const u8) !ChangeSet {
    const path = try changesetPath(allocator, id);
    defer allocator.free(path);

    const content = parse.readFile(allocator, io, path) orelse return error.FileNotFound;
    defer allocator.free(content);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, content, .{});
    defer parsed.deinit();

    const obj = parsed.value;
    if (obj != .object) return error.InvalidFormat;
    const map = obj.object;

    const cs_id = try allocator.dupe(u8, getStringObj(map, "id") orelse return error.MissingField);
    const hc_id = try allocator.dupe(u8, getStringObj(map, "hardCaseId") orelse "");
    const title = try allocator.dupe(u8, getStringObj(map, "title") orelse "");
    const summary = try allocator.dupe(u8, getStringObj(map, "summary") orelse "");
    const new_entry = try allocator.dupe(u8, getStringObj(map, "newEntry") orelse return error.MissingField);
    const status = try allocator.dupe(u8, getStringObj(map, "status") orelse "draft");
    const created = try allocator.dupe(u8, getStringObj(map, "created") orelse "");
    const confidence = getFloatObj(map, "confidence", 0.0);

    const old_entry = if (getStringObj(map, "oldEntry")) |s| try allocator.dupe(u8, s) else null;
    const applied = if (getStringObj(map, "applied")) |s| try allocator.dupe(u8, s) else null;

    // Parse snapshot
    const snapshot = if (map.get("snapshot")) |sn_val| blk: {
        if (sn_val != .object) break :blk null;
        const sn_map = sn_val.object;
        break :blk Snapshot{
            .mtime = @as(u64, @intCast(getIntObj(sn_map, "mtime", 0))),
            .size = @as(u64, @intCast(getIntObj(sn_map, "size", 0))),
            .crc32 = @as(u32, @intCast(getIntObj(sn_map, "crc32", 0))),
        };
    } else null;

    return ChangeSet{
        .id = cs_id,
        .hard_case_id = hc_id,
        .title = title,
        .summary = summary,
        .old_entry = old_entry,
        .new_entry = new_entry,
        .status = status,
        .created = created,
        .applied = applied,
        .confidence = confidence,
        .snapshot = snapshot,
    };
}

/// Save a changeset to its JSON file (atomic write via tmp+rename).
/// Source: tool/memory/designer.zig — changeset persistence
pub fn saveChangeSet(allocator: std.mem.Allocator, io: Io, cs: *const ChangeSet) !void {
    const path = try changesetPath(allocator, cs.id);
    defer allocator.free(path);

    var buf = std.array_list.Managed(u8).init(allocator);
    defer buf.deinit();

    try buf.append('{');
    try json.putString(&buf, "id", cs.id);
    try buf.append(',');
    try json.putString(&buf, "hardCaseId", cs.hard_case_id);
    try buf.append(',');
    try json.putString(&buf, "title", cs.title);
    try buf.append(',');
    try json.putString(&buf, "summary", cs.summary);
    try buf.append(',');

    // oldEntry (nullable)
    if (cs.old_entry) |oe| {
        try json.putString(&buf, "oldEntry", oe);
    } else {
        try buf.appendSlice("\"oldEntry\":null");
    }
    try buf.append(',');

    try json.putString(&buf, "newEntry", cs.new_entry);
    try buf.append(',');
    try json.putString(&buf, "status", cs.status);
    try buf.append(',');
    try json.putString(&buf, "created", cs.created);
    try buf.append(',');

    // applied (nullable)
    if (cs.applied) |a| {
        try json.putString(&buf, "applied", a);
    } else {
        try buf.appendSlice("\"applied\":null");
    }
    try buf.append(',');

    // confidence
    try json.putKey(&buf, "confidence");
    var score_buf: [32]u8 = undefined;
    const score_str = try std.fmt.bufPrint(&score_buf, "{d}", .{cs.confidence});
    try buf.appendSlice(score_str);

    // snapshot (nullable)
    try buf.append(',');
    if (cs.snapshot) |sn| {
        try buf.appendSlice("\"snapshot\":{");
        try json.putInt(&buf, "mtime", sn.mtime);
        try buf.append(',');
        try json.putInt(&buf, "size", sn.size);
        try buf.append(',');
        try json.putInt(&buf, "crc32", sn.crc32);
        try buf.append('}');
    } else {
        try buf.appendSlice("\"snapshot\":null");
    }

    try buf.append('}');
    const content = try buf.toOwnedSlice();
    defer allocator.free(content);

    try parse.atomicWrite(allocator, io, path, content);
}

/// List all changesets in the changesets directory, optionally filtered by status.
/// Caller owns returned slice and all changesets within.
/// Source: tool/memory/designer.zig — changeset enumeration
pub fn listChangeSets(allocator: std.mem.Allocator, io: Io, status_filter: ?[]const u8) ![]ChangeSet {
    const dir_path = try changesetsDir(allocator);
    defer allocator.free(dir_path);

    const cwd = Io.Dir.cwd();
    const dir = cwd.openDir(io, dir_path, .{ .iterate = true }) catch return &.{};
    defer dir.close(io);

    var list = std.array_list.Managed(ChangeSet).init(allocator);
    errdefer {
        for (list.items) |cs| freeChangeSet(allocator, &cs);
        list.deinit();
    }

    var iter = dir.iterate();
    while (iter.next(io)) |entry_opt| {
        const entry = entry_opt orelse continue;
        if (entry.kind != .file) continue;
        // Skip .tmp files
        if (std.mem.endsWith(u8, entry.name, ".tmp")) continue;

        const cs = loadChangeSet(allocator, io, entry.name) catch continue;

        // Apply filter
        if (status_filter) |sf| {
            if (!std.mem.eql(u8, cs.status, sf)) {
                freeChangeSet(allocator, &cs);
                continue;
            }
        }

        try list.append(cs);
    } else |_| {}

    return list.toOwnedSlice();
}

/// Delete a changeset file.
/// Source: tool/memory/designer.zig — changeset removal
pub fn deleteChangeSet(allocator: std.mem.Allocator, io: Io, id: []const u8) !void {
    const path = try changesetPath(allocator, id);
    defer allocator.free(path);
    Io.Dir.cwd().deleteFile(io, path) catch {};
}

/// Deep-free all fields in a ChangeSet.
fn freeChangeSet(allocator: std.mem.Allocator, cs: *const ChangeSet) void {
    allocator.free(cs.id);
    allocator.free(cs.hard_case_id);
    allocator.free(cs.title);
    allocator.free(cs.summary);
    if (cs.old_entry) |oe| allocator.free(oe);
    allocator.free(cs.new_entry);
    allocator.free(cs.status);
    allocator.free(cs.created);
    if (cs.applied) |a| allocator.free(a);
}

// ---------------------------------------------------------------------------
// Next changeset ID generation
// ---------------------------------------------------------------------------

/// Generate next CS-YYYYMMDD-NNN id by scanning changesets directory.
/// Caller owns returned slice, must free.
fn nextChangeSetId(allocator: std.mem.Allocator, io: Io) ![]const u8 {
    const date_str = parse.todayDateString(io);
    const dir_path = try changesetsDir(allocator);
    defer allocator.free(dir_path);

    var max_seq: u32 = 0;

    const cwd = Io.Dir.cwd();
    const dir = cwd.openDir(io, dir_path, .{ .iterate = true }) catch {
        // Directory doesn't exist yet, start from 001
        return std.fmt.allocPrint(allocator, "CS-{s}-{d:0>3}", .{ &date_str, @as(u32, 1) });
    };
    defer dir.close(io);

    var iter = dir.iterate();
    while (iter.next(io)) |entry_opt| {
        const entry = entry_opt orelse continue;
        if (entry.kind != .file) continue;
        const name = entry.name;
        // Parse "CS-YYYYMMDD-NNN"
        if (name.len < 17) continue;
        if (!std.mem.startsWith(u8, name, "CS-")) continue;
        const id_date = name[3..11]; // After "CS-"
        if (!std.mem.eql(u8, id_date, &date_str)) continue;
        // Should have ".json" extension
        const json_ext = if (std.mem.endsWith(u8, name, ".json")) name.len - 5 else name.len;
        if (json_ext <= 14) continue;
        const seq_str = name[12..json_ext];
        const seq = std.fmt.parseInt(u32, seq_str, 10) catch continue;
        if (seq > max_seq) max_seq = seq;
    } else |_| {}

    return std.fmt.allocPrint(allocator, "CS-{s}-{d:0>3}.json", .{ &date_str, max_seq + 1 });
}

// ---------------------------------------------------------------------------
// Latin token extraction (first word)
// ---------------------------------------------------------------------------

/// Extract first Latin word from text (alphanumeric characters, split by space/underscore).
/// Returns slice borrowed from 'text', or "auto" if no Latin word found.
/// Source: tool/memory/designer.zig — pattern-key extraction for propose
fn extractFirstLatinWord(text: []const u8) []const u8 {
    var start: usize = 0;
    // Skip non-alphanumeric prefix
    while (start < text.len) {
        const c = text[start];
        if (std.ascii.isAlphanumeric(c)) break;
        start += 1;
    }
    if (start >= text.len) return "auto";

    var end = start;
    while (end < text.len) {
        const c = text[end];
        if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-') break;
        end += 1;
    }
    if (end - start < 2) return "auto"; // Too short
    return text[start..end];
}

// ---------------------------------------------------------------------------
// CJK bigram helpers
// ---------------------------------------------------------------------------

/// Check if a Unicode codepoint is CJK Unified Ideograph.
fn isCjkCodepoint(cp: u21) bool {
    return cp >= cjk_start and cp <= cjk_end;
}

/// Extract CJK characters from text, returns them as a string.
/// Caller owns returned slice (list of chars concatenated).
fn extractCjkChars(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var result = std.array_list.Managed(u8).init(allocator);
    errdefer result.deinit();

    var i: usize = 0;
    while (i < text.len) {
        const cp = std.unicode.utf8Decode(text[i..]) catch {
            i += 1;
            continue;
        };
        const char_len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        if (isCjkCodepoint(cp)) {
            try result.appendSlice(text[i .. i + char_len]);
        }
        i += char_len;
    }
    return result.toOwnedSlice();
}

/// Generate CJK bigrams (length-2 CJK character pairs) from text.
/// Caller owns returned slice.
fn extractCjkBigrams(allocator: std.mem.Allocator, text: []const u8) ![][]const u8 {
    const chars = try extractCjkChars(allocator, text);
    defer allocator.free(chars);

    if (chars.len < 6) return &.{}; // Need at least 2 CJK chars (6 bytes)
    // Count CJK codepoints
    var cp_count: usize = 0;
    var i: usize = 0;
    while (i < chars.len) {
        const len = std.unicode.utf8ByteSequenceLength(chars[i]) catch 1;
        cp_count += 1;
        i += len;
    }
    if (cp_count < 2) return &.{};

    var bigrams = std.array_list.Managed([]const u8).init(allocator);
    errdefer bigrams.deinit();

    var pos: usize = 0;
    var prev_char_start: usize = 0;
    var cp_index: usize = 0;

    while (pos < chars.len) {
        const len = std.unicode.utf8ByteSequenceLength(chars[pos]) catch 1;
        if (cp_index > 0) {
            // Create bigram from previous char + current char
            const bigram = try allocator.dupe(u8, chars[prev_char_start .. pos + len]);
            try bigrams.append(bigram);
        }
        prev_char_start = pos;
        pos += len;
        cp_index += 1;
    }

    return bigrams.toOwnedSlice();
}

/// Filter out stopwords from text (mutates the string in-place by removing substrings).
/// Caller owns returned slice.
fn removeStopwords(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    const stopwords = [_][]const u8{
        "的", "了", "是", "在", "有", "不", "我", "这", "那", "也", "和", "就", "都",
        "而", "及", "与", "着", "或", "一个", "没有", "我们", "他们", "你们", "它们",
        "自己", "什么", "怎么", "如何", "因为", "所以", "如果", "虽然", "但是", "而且",
        "然后", "之后", "之前", "对于", "关于", "通过",
    };

    var buf = try allocator.dupe(u8, text);
    var buf_len: usize = buf.len;

    for (stopwords) |sw| {
        var pos: usize = 0;
        while (pos + sw.len <= buf_len) {
            if (std.mem.eql(u8, buf[pos .. pos + sw.len], sw)) {
                // Shift remaining content left
                std.mem.copyForwards(u8, buf[pos .. buf_len - sw.len], buf[pos + sw.len .. buf_len]);
                buf_len -= sw.len;
                // Don't advance pos - check the same position again
            } else {
                pos += 1;
            }
        }
    }

    return allocator.realloc(buf, buf_len) catch buf[0..buf_len];
}

// ---------------------------------------------------------------------------
// Latin token overlap (Channel A)
// ---------------------------------------------------------------------------

/// Split text into lowercase Latin tokens (space/underscore separated).
/// Caller owns returned slice.
fn tokenizeLatin(allocator: std.mem.Allocator, text: []const u8) ![][]const u8 {
    var tokens = std.array_list.Managed([]const u8).init(allocator);
    errdefer {
        for (tokens.items) |t| allocator.free(t);
        tokens.deinit();
    }

    var i: usize = 0;
    while (i < text.len) {
        // Skip non-alphanumeric
        while (i < text.len and !std.ascii.isAlphanumeric(text[i])) : (i += 1) {}
        if (i >= text.len) break;
        const start = i;
        while (i < text.len and std.ascii.isAlphanumeric(text[i])) : (i += 1) {}
        const word = try allocator.dupe(u8, text[start..i]);
        // Lowercase
        for (word) |*c| {
            c.* = std.ascii.toLower(c.*);
        }
        try tokens.append(word);
    }
    return tokens.toOwnedSlice();
}

/// Channel A: Latin token overlap. Returns score 0.0-0.25.
fn channelALatinOverlap(allocator: std.mem.Allocator, text_a: []const u8, text_b: []const u8) !f64 {
    const tokens_a = try tokenizeLatin(allocator, text_a);
    defer {
        for (tokens_a) |t| allocator.free(t);
        allocator.free(tokens_a);
    }
    const tokens_b = try tokenizeLatin(allocator, text_b);
    defer {
        for (tokens_b) |t| allocator.free(t);
        allocator.free(tokens_b);
    }

    if (tokens_a.len == 0 or tokens_b.len == 0) return 0.0;

    // Count overlapping tokens (case-insensitive already)
    var overlap: usize = 0;
    for (tokens_a) |ta| {
        for (tokens_b) |tb| {
            if (std.mem.eql(u8, ta, tb)) {
                overlap += 1;
                break;
            }
        }
    }

    const max_len = @max(tokens_a.len, tokens_b.len);
    const ratio = @as(f64, @floatFromInt(overlap)) / @as(f64, @floatFromInt(max_len));
    return @min(ratio * 0.25, 0.25);
}

// ---------------------------------------------------------------------------
// CJK bigram overlap (Channel B)
// ---------------------------------------------------------------------------

/// Channel B: CJK bigram overlap. Returns score 0.0-0.25.
fn channelBCjkBigramOverlap(allocator: std.mem.Allocator, text_a: []const u8, text_b: []const u8) !f64 {
    // Remove stopwords first
    const clean_a = try removeStopwords(allocator, text_a);
    defer allocator.free(clean_a);
    const clean_b = try removeStopwords(allocator, text_b);
    defer allocator.free(clean_b);

    const bigrams_a = try extractCjkBigrams(allocator, clean_a);
    defer {
        for (bigrams_a) |b| allocator.free(b);
        allocator.free(bigrams_a);
    }
    const bigrams_b = try extractCjkBigrams(allocator, clean_b);
    defer {
        for (bigrams_b) |b| allocator.free(b);
        allocator.free(bigrams_b);
    }

    if (bigrams_a.len == 0 or bigrams_b.len == 0) return 0.0;

    // Count overlapping bigrams
    var overlap: usize = 0;
    for (bigrams_a) |ba| {
        for (bigrams_b) |bb| {
            if (std.mem.eql(u8, ba, bb)) {
                overlap += 1;
                break;
            }
        }
    }

    const max_len = @max(bigrams_a.len, bigrams_b.len);
    const ratio = @as(f64, @floatFromInt(overlap)) / @as(f64, @floatFromInt(max_len));
    return @min(ratio * 0.25, 0.25);
}

// ---------------------------------------------------------------------------
// Keyword table (Channel C)
// ---------------------------------------------------------------------------

const KeywordEntry = struct {
    latin: []const u8,
    cjk: []const u8,
};

const keyword_table = [_]KeywordEntry{
    .{ .latin = "error", .cjk = "错误" },
    .{ .latin = "panic", .cjk = "崩溃" },
    .{ .latin = "crash", .cjk = "崩溃" },
    .{ .latin = "fail", .cjk = "失败" },
    .{ .latin = "timeout", .cjk = "超时" },
    .{ .latin = "leak", .cjk = "泄漏" },
    .{ .latin = "permission", .cjk = "权限" },
    .{ .latin = "config", .cjk = "配置" },
    .{ .latin = "build", .cjk = "构建" },
    .{ .latin = "compile", .cjk = "编译" },
    .{ .latin = "memory", .cjk = "内存" },
    .{ .latin = "network", .cjk = "网络" },
    .{ .latin = "thread", .cjk = "线程" },
    .{ .latin = "deadlock", .cjk = "死锁" },
    .{ .latin = "corrupt", .cjk = "损坏" },
    .{ .latin = "null", .cjk = "空指针" },
};

/// Channel C: Keyword table match. Returns score 0.0-0.15.
/// Source: tool/memory/designer.zig — confidence computation keyword channel
fn channelCKeywords(allocator: std.mem.Allocator, pattern_key: []const u8, symptom: []const u8) !f64 {
    _ = allocator;
    var matches: usize = 0;
    for (keyword_table) |kw| {
        const latin_match = if (kw.latin.len > 0)
            indexOfInsensitive(pattern_key, kw.latin) or indexOfInsensitive(symptom, kw.latin)
        else
            false;
        const cjk_match = if (kw.cjk.len > 0)
            std.mem.indexOf(u8, pattern_key, kw.cjk) != null or
                std.mem.indexOf(u8, symptom, kw.cjk) != null
        else
            false;

        if (latin_match or cjk_match) {
            matches += 1;
        }
    }

    const ratio = @as(f64, @floatFromInt(matches)) / @as(f64, @floatFromInt(keyword_table.len));
    return @min(ratio * 0.15, 0.15);
}

/// Case-insensitive substring search.
fn indexOfInsensitive(haystack: []const u8, needle: []const u8) bool {
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
// File reference (Channel D)
// ---------------------------------------------------------------------------

/// Check if related_files contains .zagent/ paths or project .zig/.md files.
fn hasFileReferences(related_files: []const u8) bool {
    if (related_files.len == 0) return false;

    // Check for .zagent/ paths
    if (std.mem.indexOf(u8, related_files, ".zagent") != null) return true;

    // Check for .zig or .md files
    const extensions = [_][]const u8{ ".zig", ".md" };
    for (extensions) |ext| {
        if (std.mem.indexOf(u8, related_files, ext) != null) return true;
    }
    return false;
}

/// Check if template contains file references.
fn templateHasFileRefs(template: []const u8) bool {
    if (std.mem.indexOf(u8, template, ".zagent") != null) return true;
    const extensions = [_][]const u8{ ".zig", ".md" };
    for (extensions) |ext| {
        if (std.mem.indexOf(u8, template, ext) != null) return true;
    }
    return false;
}

/// Channel D: File reference. Returns score 0.0-0.15.
/// Source: tool/memory/designer.zig — confidence computation file-reference channel
fn channelDFileRefs(related_files: []const u8, context: []const u8) f64 {
    var score: f64 = 0.0;
    if (related_files.len > 0 and hasFileReferences(related_files)) {
        score += 0.10;
    }
    if (context.len > 0 and templateHasFileRefs(context)) {
        score += 0.05;
    }
    return @min(score, 0.15);
}

// ---------------------------------------------------------------------------
// Severity alignment (Channel E)
// ---------------------------------------------------------------------------

/// Channel E: Severity alignment. Returns score 0.0-0.10.
/// Source: tool/memory/designer.zig — confidence computation severity channel
fn channelESeverity(severity: []const u8, symptom: []const u8) f64 {
    const is_critical = std.mem.eql(u8, severity, "critical") or
        indexOfInsensitive(symptom, "panic") or
        indexOfInsensitive(symptom, "崩溃") or
        indexOfInsensitive(symptom, "crash");

    const is_high = std.mem.eql(u8, severity, "high") or
        indexOfInsensitive(symptom, "error") or
        indexOfInsensitive(symptom, "错误") or
        indexOfInsensitive(symptom, "fail");

    if (is_critical) return 0.10;
    if (is_high) return 0.07;
    if (std.mem.eql(u8, severity, "medium")) return 0.05;
    return 0.02;
}

// ---------------------------------------------------------------------------
// No conflict (Channel F)
// ---------------------------------------------------------------------------

/// Channel F: No conflict with existing entries. Returns score 0.0-0.10.
/// Source: tool/memory/designer.zig — confidence computation no-conflict channel
fn channelFNoConflict(allocator: std.mem.Allocator, io: Io, pattern_key: []const u8) f64 {
    if (pattern_key.len == 0) return 0.05; // No pattern-key, partial credit

    const mem_path = parse.memoryPath(allocator) catch return 0.05;
    defer allocator.free(mem_path);

    const entries = parse.getEntries(allocator, io, mem_path) catch return 0.05;

    for (entries) |entry| {
        if (entry.pattern_key.len > 0 and std.mem.eql(u8, entry.pattern_key, pattern_key)) {
            return 0.0; // Conflict: pattern_key already exists
        }
    }
    return 0.10; // No conflict
}

// ---------------------------------------------------------------------------
// Confidence computation (6 channels, capped at 1.0)
// ---------------------------------------------------------------------------

/// Compute confidence score from symptom and context. 6 channels, max 1.0.
/// Returns score 0.0-1.0; empty/blank symptom returns 0.5.
/// Source: tool/memory/designer.zig — 6-channel confidence scoring
pub fn computeConfidence(
    allocator: std.mem.Allocator,
    io: Io,
    pattern_key: []const u8,
    symptom: []const u8,
    related_files: []const u8,
    severity: []const u8,
    context: []const u8,
    existing_entries: []const Entry,
) f64 {
    _ = existing_entries;

    // Degradation: empty or blank symptom
    if (symptom.len == 0 or isAllWhitespace(symptom)) {
        return 0.5;
    }

    // Channel A: Latin token overlap (0.25 max)
    const a_score = channelALatinOverlap(allocator, pattern_key, symptom) catch 0.0;

    // Channel B: CJK bigram overlap (0.25 max)
    const b_score = channelBCjkBigramOverlap(allocator, pattern_key, symptom) catch 0.0;

    // Channel C: Keywords (0.15 max)
    const c_score = channelCKeywords(allocator, pattern_key, symptom) catch 0.0;

    // Channel D: File references (0.15 max)
    const d_score = channelDFileRefs(related_files, context);

    // Channel E: Severity alignment (0.10 max)
    const e_score = channelESeverity(severity, symptom);

    // Channel F: No conflict (0.10 max)
    const f_score = channelFNoConflict(allocator, io, pattern_key);

    var total = a_score + b_score + c_score + d_score + e_score + f_score;
    if (total > 1.0) total = 1.0;
    if (total < 0.0) total = 0.0;
    return total;
}

fn isWhitespace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

fn isAllWhitespace(text: []const u8) bool {
    for (text) |c| {
        if (!isWhitespace(c)) return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// JSON string/build helpers (for output serialization)
// ---------------------------------------------------------------------------

fn getStringObj(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const val = obj.get(key) orelse return null;
    if (val == .string) return val.string;
    return null;
}

fn getIntObj(obj: std.json.ObjectMap, key: []const u8, default: i64) i64 {
    const val = obj.get(key) orelse return default;
    if (val == .integer) return val.integer;
    if (val == .float) return @as(i64, @intFromFloat(val.float));
    return default;
}

fn getFloatObj(obj: std.json.ObjectMap, key: []const u8, default: f64) f64 {
    const val = obj.get(key) orelse return default;
    if (val == .float) return val.float;
    if (val == .integer) return @as(f64, @floatFromInt(val.integer));
    return default;
}

fn getBoolObj(obj: std.json.ObjectMap, key: []const u8, default: bool) bool {
    const val = obj.get(key) orelse return default;
    if (val == .bool) return val.bool;
    return default;
}

// ---------------------------------------------------------------------------
// Subcommand: collect
// ---------------------------------------------------------------------------

/// Collect unconsumed hard cases from session-state. Marks them consumed.
/// Returns JSON with collected count and hard cases.
/// Source: tool/memory/designer.zig — hard case collection subcommand
pub fn cmdCollect(allocator: std.mem.Allocator, io: Io, args: std.json.ObjectMap) []const u8 {
    const limit: usize = if (args.get("limit")) |v|
        if (v == .integer) @as(usize, @intCast(v.integer)) else 10
    else
        10;

    var state = session.load(allocator, io);
    defer state.deinit(allocator);

    // Filter unconsumed hard cases
    var collected = std.array_list.Managed(session.HardCase).init(allocator);
    defer {
        for (collected.items) |*hc| {
            allocator.free(hc.id);
            allocator.free(hc.symptom);
            allocator.free(hc.context);
            allocator.free(hc.source);
            allocator.free(hc.timestamp);
        }
        collected.deinit();
    }

    for (state.hard_case_buffer, 0..) |hc, i| {
        if (collected.items.len >= limit) break;
        if (!hc.consumed) {
            // Mark as consumed
            state.hard_case_buffer[i].consumed = true;
            // Deep copy hard case
            const owned_id = allocator.dupe(u8, hc.id) catch continue;
            const owned_symptom = allocator.dupe(u8, hc.symptom) catch {
                allocator.free(owned_id);
                continue;
            };
            const owned_context = allocator.dupe(u8, hc.context) catch {
                allocator.free(owned_id);
                allocator.free(owned_symptom);
                continue;
            };
            const owned_source = allocator.dupe(u8, hc.source) catch {
                allocator.free(owned_id);
                allocator.free(owned_symptom);
                allocator.free(owned_context);
                continue;
            };
            const owned_ts = allocator.dupe(u8, hc.timestamp) catch {
                allocator.free(owned_id);
                allocator.free(owned_symptom);
                allocator.free(owned_context);
                allocator.free(owned_source);
                continue;
            };
            const owned = session.HardCase{
                .id = owned_id,
                .symptom = owned_symptom,
                .context = owned_context,
                .source = owned_source,
                .timestamp = owned_ts,
                .consumed = true,
            };
            collected.append(owned) catch {
                allocator.free(owned_id);
                allocator.free(owned_symptom);
                allocator.free(owned_context);
                allocator.free(owned_source);
                allocator.free(owned_ts);
            };
        }
    }

    // Save updated state
    session.save(allocator, io, &state) catch {
        return allocError(allocator, "save failed");
    };

    // Build JSON output
    var buf = std.array_list.Managed(u8).init(allocator);
    defer buf.deinit();

    json.puts(&buf, "{\"collected\":") catch return allocOomError(allocator);
    var num_buf: [32]u8 = undefined;
    const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{collected.items.len}) catch "0";
    json.puts(&buf, num_str) catch return allocOomError(allocator);
    json.puts(&buf, ",\"hardCases\":[") catch return allocOomError(allocator);

    for (collected.items, 0..) |hc, i| {
        if (i > 0) json.putc(&buf, ',') catch return allocOomError(allocator);
        json.putc(&buf, '{') catch return allocOomError(allocator);
        json.putString(&buf, "id", hc.id) catch return allocOomError(allocator);
        json.putc(&buf, ',') catch return allocOomError(allocator);
        json.putString(&buf, "symptom", hc.symptom) catch return allocOomError(allocator);
        json.putc(&buf, ',') catch return allocOomError(allocator);
        json.putString(&buf, "source", hc.source) catch return allocOomError(allocator);
        json.putc(&buf, '}') catch return allocOomError(allocator);
    }

    json.puts(&buf, "]}") catch return allocOomError(allocator);
    return json.finish(&buf);
}

// ---------------------------------------------------------------------------
// Subcommand: propose
// ---------------------------------------------------------------------------

/// Propose a changeset from a hard case. Creates changeset file, computes confidence.
/// Returns JSON with id, confidence, and status.
/// Source: tool/memory/designer.zig — changeset proposal subcommand
pub fn cmdPropose(allocator: std.mem.Allocator, io: Io, args: std.json.ObjectMap) []const u8 {
    const id_val = args.get("id") orelse return allocError(allocator, "missing 'id' for propose");
    const hc_id = if (id_val == .string) id_val.string else return allocError(allocator, "'id' must be a string");

    // Load session state to find the HC
    var state = session.load(allocator, io);
    defer state.deinit(allocator);

    // Find the HC
    var found_hc: ?session.HardCase = null;
    for (state.hard_case_buffer) |hc| {
        if (std.mem.eql(u8, hc.id, hc_id)) {
            found_hc = hc;
            break;
        }
    }

    const hc = found_hc orelse {
        return allocError(allocator, "hard case not found");
    };

    // Ensure changesets directory exists
    const dir_path = changesetsDir(allocator) catch return allocOomError(allocator);
    defer allocator.free(dir_path);
    Io.Dir.cwd().createDirPath(io, dir_path) catch {};

    // Generate changeset ID
    const cs_id_full = nextChangeSetId(allocator, io) catch return allocOomError(allocator);
    defer allocator.free(cs_id_full);
    // Strip .json extension from ID for storage
    const cs_id_stripped = if (std.mem.endsWith(u8, cs_id_full, ".json"))
        cs_id_full[0 .. cs_id_full.len - 5]
    else
        cs_id_full;

    // Generate memory entry ID
    const mem_path = parse.memoryPath(allocator) catch return allocOomError(allocator);
    defer allocator.free(mem_path);
    const existing_content = parse.readFile(allocator, io, mem_path);
    defer if (existing_content) |c| allocator.free(c);
    const entry_id = parse.generateId(allocator, io, existing_content) catch return allocOomError(allocator);
    defer allocator.free(entry_id);

    // Extract title
    const title = parse.extractTitle(hc.symptom);

    // Extract pattern-key: first Latin word or "auto-<HC-ID>"
    const first_word = extractFirstLatinWord(hc.symptom);
    const pattern_key = if (std.mem.eql(u8, first_word, "auto")) blk: {
        const pk = std.fmt.allocPrint(allocator, "auto-{s}", .{hc_id}) catch return allocOomError(allocator);
        break :blk pk;
    } else blk: {
        const pk = allocator.dupe(u8, first_word) catch return allocOomError(allocator);
        break :blk pk;
    };
    defer allocator.free(pattern_key);

    // Determine severity from context
    const severity = inferSeverity(hc.symptom);

    // Related files from context
    const related_files = extractFileRefs(hc.context);

    // Compute confidence
    const existing_entries = if (existing_content) |ec|
        parse.parseEntries(allocator, ec) catch &.{}
    else
        &.{};
    defer if (existing_entries.len > 0) allocator.free(existing_entries);

    const confidence = computeConfidence(allocator, io, pattern_key, hc.symptom, related_files, severity, hc.context, existing_entries);

    // Auto-assign status based on confidence
    const status = if (confidence >= auto_approve_threshold)
        "approved"
    else if (confidence >= draft_threshold)
        "proposed"
    else
        "draft";

    // Create snapshot of current memory.md
    const snapshot = getFileInfo(allocator, io, mem_path);

    // ISO8601 timestamp
    const created = session.nowISO8601(allocator, io) catch return allocOomError(allocator);
    defer allocator.free(created);

    // Build new_entry markdown using serializeEntry
    const date_formatted = parse.todayFormattedDate(io);
    const body = std.fmt.allocPrint(allocator, "{s}\n\n{s}", .{ hc.symptom, hc.context }) catch return allocOomError(allocator);
    defer allocator.free(body);

    const entry = Entry{
        .id = entry_id,
        .title = title,
        .source = hc.source,
        .pattern_key = pattern_key,
        .priority = severity,
        .scope = "project-specific",
        .status = "new",
        .handled = "pending",
        .recurrence_count = 1,
        .archived = false,
        .related_files = related_files,
        .logged = &date_formatted,
        .raw = "",
        .preview = "",
    };

    const new_entry = parse.serializeEntry(allocator, entry, body) catch return allocOomError(allocator);
    defer allocator.free(new_entry);

    // Summary: first 100 chars of symptom
    const summary_limit = if (hc.symptom.len > 100) hc.symptom[0..100] else hc.symptom;

    // Create changeset (allocate each field individually to handle errors)
    const cs_id_owned = allocator.dupe(u8, cs_id_stripped) catch return allocOomError(allocator);
    const hc_id_owned = allocator.dupe(u8, hc_id) catch { allocator.free(cs_id_owned); return allocOomError(allocator); };
    const title_owned = allocator.dupe(u8, title) catch { allocator.free(cs_id_owned); allocator.free(hc_id_owned); return allocOomError(allocator); };
    const summary_owned = allocator.dupe(u8, summary_limit) catch { allocator.free(cs_id_owned); allocator.free(hc_id_owned); allocator.free(title_owned); return allocOomError(allocator); };
    const new_entry_owned = allocator.dupe(u8, new_entry) catch { allocator.free(cs_id_owned); allocator.free(hc_id_owned); allocator.free(title_owned); allocator.free(summary_owned); return allocOomError(allocator); };
    const status_owned = allocator.dupe(u8, status) catch { allocator.free(cs_id_owned); allocator.free(hc_id_owned); allocator.free(title_owned); allocator.free(summary_owned); allocator.free(new_entry_owned); return allocOomError(allocator); };
    const created_owned = allocator.dupe(u8, created) catch { allocator.free(cs_id_owned); allocator.free(hc_id_owned); allocator.free(title_owned); allocator.free(summary_owned); allocator.free(new_entry_owned); allocator.free(status_owned); return allocOomError(allocator); };
    const cs = ChangeSet{
        .id = cs_id_owned,
        .hard_case_id = hc_id_owned,
        .title = title_owned,
        .summary = summary_owned,
        .old_entry = null,
        .new_entry = new_entry_owned,
        .status = status_owned,
        .created = created_owned,
        .applied = null,
        .confidence = confidence,
        .snapshot = snapshot,
    };
    defer freeChangeSet(allocator, &cs);

    saveChangeSet(allocator, io, &cs) catch return allocError(allocator, "save changeset failed");

    // Build JSON output
    var buf = std.array_list.Managed(u8).init(allocator);
    defer buf.deinit();
    json.puts(&buf, "{\"id\":") catch return allocOomError(allocator);
    json.escapeJson(&buf, cs_id_stripped) catch return allocOomError(allocator);
    json.puts(&buf, ",\"confidence\":") catch return allocOomError(allocator);
    var score_buf: [32]u8 = undefined;
    const score_str = std.fmt.bufPrint(&score_buf, "{d:.3}", .{confidence}) catch "0.0";
    json.puts(&buf, score_str) catch return allocOomError(allocator);
    json.puts(&buf, ",\"status\":") catch return allocOomError(allocator);
    json.escapeJson(&buf, status) catch return allocOomError(allocator);
    json.puts(&buf, ",\"entryId\":") catch return allocOomError(allocator);
    json.escapeJson(&buf, entry_id) catch return allocOomError(allocator);
    json.puts(&buf, "}") catch return allocOomError(allocator);
    return json.finish(&buf);
}

/// Infer severity from symptom text.
fn inferSeverity(symptom: []const u8) []const u8 {
    if (indexOfInsensitive(symptom, "panic") or
        indexOfInsensitive(symptom, "崩溃") or
        indexOfInsensitive(symptom, "crash") or
        indexOfInsensitive(symptom, "critical") or
        indexOfInsensitive(symptom, "fatal") or
        indexOfInsensitive(symptom, "安全") or
        indexOfInsensitive(symptom, "数据丢失")) return "critical";
    if (indexOfInsensitive(symptom, "error") or
        indexOfInsensitive(symptom, "错误") or
        indexOfInsensitive(symptom, "fail") or
        indexOfInsensitive(symptom, "失败") or
        indexOfInsensitive(symptom, "异常") or
        indexOfInsensitive(symptom, "exception")) return "high";
    if (indexOfInsensitive(symptom, "warn") or
        indexOfInsensitive(symptom, "警告") or
        indexOfInsensitive(symptom, "deprecated") or
        indexOfInsensitive(symptom, "issue")) return "medium";
    return "low";
}

/// Extract file references from text (lines containing .zig, .md, or path patterns).
/// Returns empty string if none found.
fn extractFileRefs(text: []const u8) []const u8 {
    // Look for common file patterns in the text
    var pos: usize = 0;
    while (pos < text.len) {
        const line_end = std.mem.indexOfScalarPos(u8, text, pos, '\n') orelse text.len;
        const line = text[pos..line_end];
        if (std.mem.indexOf(u8, line, ".zig") != null or
            std.mem.indexOf(u8, line, ".md") != null or
            std.mem.indexOf(u8, line, ".json") != null or
            std.mem.indexOf(u8, line, ".toml") != null or
            std.mem.indexOf(u8, line, "\\") != null or
            std.mem.indexOf(u8, line, ".zagent") != null)
        {
            return line;
        }
        pos = line_end + 1;
    }
    return "";
}

// ---------------------------------------------------------------------------
// Subcommand: list
// ---------------------------------------------------------------------------

/// List changesets, optionally filtered by status. Returns JSON array.
/// Source: tool/memory/designer.zig — changeset listing subcommand
pub fn cmdList(allocator: std.mem.Allocator, io: Io, args: std.json.ObjectMap) []const u8 {
    const status_filter = if (args.get("status")) |v|
        if (v == .string and v.string.len > 0) v.string else null
    else
        null;

    const changesets = listChangeSets(allocator, io, status_filter) catch return allocOomError(allocator);
    defer {
        for (changesets) |cs| freeChangeSet(allocator, &cs);
        allocator.free(changesets);
    }

    var buf = std.array_list.Managed(u8).init(allocator);
    defer buf.deinit();

    json.puts(&buf, "{\"changesets\":[") catch return allocOomError(allocator);
    for (changesets, 0..) |cs, i| {
        if (i > 0) json.putc(&buf, ',') catch return allocOomError(allocator);
        json.putc(&buf, '{') catch return allocOomError(allocator);
        json.putString(&buf, "id", cs.id) catch return allocOomError(allocator);
        json.putc(&buf, ',') catch return allocOomError(allocator);
        json.putString(&buf, "status", cs.status) catch return allocOomError(allocator);
        json.putc(&buf, ',') catch return allocOomError(allocator);
        json.putKey(&buf, "confidence") catch return allocOomError(allocator);
        var sb: [32]u8 = undefined;
        const ss = std.fmt.bufPrint(&sb, "{d:.3}", .{cs.confidence}) catch "0.0";
        json.puts(&buf, ss) catch return allocOomError(allocator);
        json.putc(&buf, ',') catch return allocOomError(allocator);
        json.putString(&buf, "title", cs.title) catch return allocOomError(allocator);
        json.putc(&buf, ',') catch return allocOomError(allocator);
        json.putString(&buf, "created", cs.created) catch return allocOomError(allocator);
        json.putc(&buf, ',') catch return allocOomError(allocator);
        json.putString(&buf, "summary", cs.summary) catch return allocOomError(allocator);
        json.putc(&buf, '}') catch return allocOomError(allocator);
    }
    json.puts(&buf, "]}") catch return allocOomError(allocator);
    return json.finish(&buf);
}

// ---------------------------------------------------------------------------
// Subcommand: review
// ---------------------------------------------------------------------------

/// Show changeset diff (old_entry vs new_entry). Returns JSON with details.
/// Source: tool/memory/designer.zig — changeset review subcommand
pub fn cmdReview(allocator: std.mem.Allocator, io: Io, args: std.json.ObjectMap) []const u8 {
    const id_val = args.get("id") orelse return allocError(allocator, "missing 'id' for review");
    const cs_id = if (id_val == .string) id_val.string else return allocError(allocator, "'id' must be a string");

    const cs = loadChangeSet(allocator, io, cs_id) catch return allocError(allocator, "changeset not found");
    defer freeChangeSet(allocator, &cs);

    var buf = std.array_list.Managed(u8).init(allocator);
    defer buf.deinit();

    json.puts(&buf, "{\"id\":") catch return allocOomError(allocator);
    json.escapeJson(&buf, cs.id) catch return allocOomError(allocator);
    json.puts(&buf, ",\"title\":") catch return allocOomError(allocator);
    json.escapeJson(&buf, cs.title) catch return allocOomError(allocator);
    json.puts(&buf, ",\"status\":") catch return allocOomError(allocator);
    json.escapeJson(&buf, cs.status) catch return allocOomError(allocator);
    json.puts(&buf, ",\"confidence\":") catch return allocOomError(allocator);
    var sb: [32]u8 = undefined;
    const ss = std.fmt.bufPrint(&sb, "{d:.3}", .{cs.confidence}) catch "0.0";
    json.puts(&buf, ss) catch return allocOomError(allocator);

    // old_entry
    json.puts(&buf, ",\"oldEntry\":") catch return allocOomError(allocator);
    if (cs.old_entry) |oe| {
        json.escapeJson(&buf, oe) catch return allocOomError(allocator);
    } else {
        json.puts(&buf, "null") catch return allocOomError(allocator);
    }

    // new_entry
    json.puts(&buf, ",\"newEntry\":") catch return allocOomError(allocator);
    json.escapeJson(&buf, cs.new_entry) catch return allocOomError(allocator);

    json.puts(&buf, "}") catch return allocOomError(allocator);
    return json.finish(&buf);
}

// ---------------------------------------------------------------------------
// Subcommand: approve
// ---------------------------------------------------------------------------

/// Mark a changeset as approved. Returns JSON with result.
/// Source: tool/memory/designer.zig — changeset approval subcommand
pub fn cmdApprove(allocator: std.mem.Allocator, io: Io, args: std.json.ObjectMap) []const u8 {
    const id_val = args.get("id") orelse return allocError(allocator, "missing 'id' for approve");
    const cs_id = if (id_val == .string) id_val.string else return allocError(allocator, "'id' must be a string");

    var cs = loadChangeSet(allocator, io, cs_id) catch return allocError(allocator, "changeset not found");
    defer freeChangeSet(allocator, &cs);

    // Update status
    allocator.free(cs.status);
    cs.status = allocator.dupe(u8, "approved") catch return allocOomError(allocator);

    saveChangeSet(allocator, io, &cs) catch return allocError(allocator, "save failed");

    var buf = std.array_list.Managed(u8).init(allocator);
    defer buf.deinit();
    json.puts(&buf, "{\"approved\":true,\"id\":") catch return allocOomError(allocator);
    json.escapeJson(&buf, cs.id) catch return allocOomError(allocator);
    json.puts(&buf, "}") catch return allocOomError(allocator);
    return json.finish(&buf);
}

// ---------------------------------------------------------------------------
// Subcommand: apply
// ---------------------------------------------------------------------------

/// Apply a changeset to memory.md. Verifies snapshot consistency unless force.
/// Returns JSON with result.
/// Source: tool/memory/designer.zig — changeset application subcommand
pub fn cmdApply(allocator: std.mem.Allocator, io: Io, args: std.json.ObjectMap) []const u8 {
    const id_val = args.get("id") orelse return allocError(allocator, "missing 'id' for apply");
    const cs_id = if (id_val == .string) id_val.string else return allocError(allocator, "'id' must be a string");
    const force = getBoolObj(args, "force", false);

    var cs = loadChangeSet(allocator, io, cs_id) catch return allocError(allocator, "changeset not found");
    defer freeChangeSet(allocator, &cs);

    // Check status
    if (!std.mem.eql(u8, cs.status, "approved") and !force) {
        return allocError(allocator, "changeset not approved (use --force to override)");
    }

    const mem_path = parse.memoryPath(allocator) catch return allocOomError(allocator);
    defer allocator.free(mem_path);

    // Snapshot consistency check
    if (!force) {
        if (cs.snapshot) |snapshot| {
            const current_info = getFileInfo(allocator, io, mem_path);
            if (current_info) |ci| {
                if (ci.mtime != snapshot.mtime or ci.size != snapshot.size or ci.crc32 != snapshot.crc32) {
                    return allocError(allocator, "memory.md changed since changeset created (use --force to override)");
                }
            } else {
                return allocError(allocator, "memory.md not found");
            }
        }
    }

    // Read current memory.md content
    const content = parse.readFile(allocator, io, mem_path) orelse "";
    defer if (content.len > 0) allocator.free(content);

    // Build new memory.md content: replace old_entry or append new_entry
    var new_content = std.array_list.Managed(u8).init(allocator);
    defer new_content.deinit();

    if (cs.old_entry) |old| {
        // Replace: find and replace old_entry with new_entry
        const replace_pos = std.mem.indexOf(u8, content, old) orelse
            return allocError(allocator, "old_entry not found in memory.md (may have been modified)");
        if (replace_pos > 0) {
            new_content.appendSlice(content[0..replace_pos]) catch return allocOomError(allocator);
        }
        new_content.appendSlice(cs.new_entry) catch return allocOomError(allocator);
        const after = replace_pos + old.len;
        if (after < content.len) {
            new_content.appendSlice(content[after..]) catch return allocOomError(allocator);
        }
    } else {
        // Add new: append to end
        if (content.len > 0) {
            new_content.appendSlice(content) catch return allocOomError(allocator);
            if (!std.mem.endsWith(u8, content, "\n---\n\n")) {
                new_content.appendSlice("\n---\n\n") catch return allocOomError(allocator);
            }
        }
        new_content.appendSlice(cs.new_entry) catch return allocOomError(allocator);
    }

    // Atomic write
    parse.atomicWrite(allocator, io, mem_path, new_content.items) catch {
        return allocError(allocator, "write memory.md failed");
    };
    parse.invalidateCache(allocator);

    // Update changeset status
    allocator.free(cs.status);
    cs.status = allocator.dupe(u8, "applied") catch return allocOomError(allocator);

    // Set applied timestamp
    if (cs.applied) |a| allocator.free(a);
    cs.applied = session.nowISO8601(allocator, io) catch null;

    saveChangeSet(allocator, io, &cs) catch {};

    // Record in operation log
    {
        var state = session.load(allocator, io);
        defer state.deinit(allocator);
        const ts = session.nowISO8601(allocator, io) catch "";
        if (ts.len > 0) {
            session.addLogEntry(&state, allocator, io, .{
                .ts = ts,
                .event = "apply",
                .changeset_id = cs.id,
                .entry_id = null,
                .path = mem_path,
                .reason = null,
            }) catch {};
            session.save(allocator, io, &state) catch {};
            allocator.free(ts);
        }
    }

    var buf = std.array_list.Managed(u8).init(allocator);
    defer buf.deinit();
    json.puts(&buf, "{\"applied\":true,\"id\":") catch return allocOomError(allocator);
    json.escapeJson(&buf, cs.id) catch return allocOomError(allocator);
    json.puts(&buf, "}") catch return allocOomError(allocator);
    return json.finish(&buf);
}

// ---------------------------------------------------------------------------
// Subcommand: rollback
// ---------------------------------------------------------------------------

/// Rollback an applied changeset. Reverts memory.md to previous state.
/// Returns JSON with result.
/// Source: tool/memory/designer.zig — changeset rollback subcommand
pub fn cmdRollback(allocator: std.mem.Allocator, io: Io, args: std.json.ObjectMap) []const u8 {
    const id_val = args.get("id") orelse return allocError(allocator, "missing 'id' for rollback");
    const cs_id = if (id_val == .string) id_val.string else return allocError(allocator, "'id' must be a string");

    var cs = loadChangeSet(allocator, io, cs_id) catch return allocError(allocator, "changeset not found");
    defer freeChangeSet(allocator, &cs);

    if (!std.mem.eql(u8, cs.status, "applied")) {
        return allocError(allocator, "changeset not applied");
    }

    const mem_path = parse.memoryPath(allocator) catch return allocOomError(allocator);
    defer allocator.free(mem_path);

    const content = parse.readFile(allocator, io, mem_path) orelse {
        return allocError(allocator, "memory.md not found");
    };
    defer allocator.free(content);

    const entries = parse.parseEntries(allocator, content) catch return allocOomError(allocator);
    defer allocator.free(entries);

    // Parse the new_entry to extract the entry ID
    const entry_id = extractEntryId(cs.new_entry);

    if (cs.old_entry) |old_entry_text| {
        // Replace entry with old_entry
        var new_content = std.array_list.Managed(u8).init(allocator);
        defer new_content.deinit();

        var replaced = false;
        for (entries, 0..) |e, i| {
            if (i > 0) {
                new_content.appendSlice("\n---\n\n") catch return allocOomError(allocator);
            }
            if (entry_id) |eid| {
                if (std.mem.eql(u8, e.id, eid)) {
                    new_content.appendSlice(old_entry_text) catch return allocOomError(allocator);
                    replaced = true;
                } else {
                    new_content.appendSlice(e.raw) catch return allocOomError(allocator);
                }
            } else {
                new_content.appendSlice(e.raw) catch return allocOomError(allocator);
            }
        }

        if (!replaced) {
            return allocError(allocator, "entry not found in memory.md");
        }

        parse.atomicWrite(allocator, io, mem_path, new_content.items) catch {
            return allocError(allocator, "write memory.md failed");
        };
        parse.invalidateCache(allocator);
    } else {
        // Delete the entry (was a new addition)
        var new_content = std.array_list.Managed(u8).init(allocator);
        defer new_content.deinit();

        if (entry_id) |eid| {
            var found = false;
            for (entries) |e| {
                if (std.mem.eql(u8, e.id, eid)) {
                    found = true;
                    continue;
                }
                if (new_content.items.len > 0) {
                    new_content.appendSlice("\n---\n\n") catch return allocOomError(allocator);
                }
                new_content.appendSlice(e.raw) catch return allocOomError(allocator);
            }
            if (!found) {
                return allocError(allocator, "entry not found in memory.md");
            }
        } else {
            return allocError(allocator, "cannot identify entry to remove");
        }

        parse.atomicWrite(allocator, io, mem_path, new_content.items) catch {
            return allocError(allocator, "write memory.md failed");
        };
        parse.invalidateCache(allocator);
    }

    // Update changeset status
    allocator.free(cs.status);
    cs.status = allocator.dupe(u8, "rolled_back") catch return allocOomError(allocator);

    saveChangeSet(allocator, io, &cs) catch {};

    // Record in operation log
    {
        var state = session.load(allocator, io);
        defer state.deinit(allocator);
        const ts = session.nowISO8601(allocator, io) catch "";
        if (ts.len > 0) {
            session.addLogEntry(&state, allocator, io, .{
                .ts = ts,
                .event = "rollback",
                .changeset_id = cs.id,
                .entry_id = null,
                .path = mem_path,
                .reason = null,
            }) catch {};
            session.save(allocator, io, &state) catch {};
            allocator.free(ts);
        }
    }

    var buf = std.array_list.Managed(u8).init(allocator);
    defer buf.deinit();
    json.puts(&buf, "{\"rolled_back\":true,\"id\":") catch return allocOomError(allocator);
    json.escapeJson(&buf, cs.id) catch return allocOomError(allocator);
    json.puts(&buf, "}") catch return allocOomError(allocator);
    return json.finish(&buf);
}

/// Extract entry ID from a serialized entry text (e.g., "## [MEM-20260702-001] Title").
fn extractEntryId(entry_text: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, entry_text, "## [MEM-")) return null;
    const id_start = 5; // after "## [M"
    const id_end = std.mem.indexOfScalarPos(u8, entry_text, id_start, ']') orelse return null;
    return entry_text[id_start..id_end];
}

// ---------------------------------------------------------------------------
// Subcommand: verify
// ---------------------------------------------------------------------------

/// Verify consistency of applied changesets against memory.md.
/// Returns JSON with verification result and any issues.
/// Source: tool/memory/designer.zig — consistency verification subcommand
pub fn cmdVerify(allocator: std.mem.Allocator, io: Io, args: std.json.ObjectMap) []const u8 {
    _ = args;

    const mem_path = parse.memoryPath(allocator) catch return allocOomError(allocator);
    defer allocator.free(mem_path);

    const content = parse.readFile(allocator, io, mem_path);
    defer if (content) |c| allocator.free(c);

    const entries = if (content) |c|
        parse.parseEntries(allocator, c) catch &.{}
    else
        &.{};
    defer if (entries.len > 0) allocator.free(entries);

    const changesets = listChangeSets(allocator, io, "applied") catch return allocOomError(allocator);
    defer {
        for (changesets) |cs| freeChangeSet(allocator, &cs);
        allocator.free(changesets);
    }

    var issues = std.array_list.Managed([]const u8).init(allocator);
    defer {
        for (issues.items) |issue| allocator.free(issue);
        issues.deinit();
    }

    for (changesets) |cs| {
        // Extract entry ID from new_entry
        const entry_id_str = extractEntryId(cs.new_entry);
        if (entry_id_str) |eid| {
            var found = false;
            for (entries) |e| {
                if (std.mem.eql(u8, e.id, eid)) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                const issue = std.fmt.allocPrint(allocator, "changeset {s}: entry {s} not found", .{ cs.id, eid }) catch return allocOomError(allocator);
                issues.append(issue) catch return allocOomError(allocator);
            }
        } else {
            const issue = std.fmt.allocPrint(allocator, "changeset {s}: cannot parse entry ID", .{cs.id}) catch return allocOomError(allocator);
            issues.append(issue) catch return allocOomError(allocator);
        }
    }

    var buf = std.array_list.Managed(u8).init(allocator);
    defer buf.deinit();

    json.puts(&buf, "{\"verified\":") catch return allocOomError(allocator);
    if (issues.items.len == 0) {
        json.puts(&buf, "true") catch return allocOomError(allocator);
    } else {
        json.puts(&buf, "false") catch return allocOomError(allocator);
    }
    json.puts(&buf, ",\"total\":") catch return allocOomError(allocator);
    var nb: [32]u8 = undefined;
    const ns = std.fmt.bufPrint(&nb, "{d}", .{changesets.len}) catch "0";
    json.puts(&buf, ns) catch return allocOomError(allocator);
    json.puts(&buf, ",\"issues\":") catch return allocOomError(allocator);
    const is = std.fmt.bufPrint(&nb, "{d}", .{issues.items.len}) catch "0";
    json.puts(&buf, is) catch return allocOomError(allocator);

    if (issues.items.len > 0) {
        json.puts(&buf, ",\"details\":[") catch return allocOomError(allocator);
        for (issues.items, 0..) |issue, i| {
            if (i > 0) json.putc(&buf, ',') catch return allocOomError(allocator);
            json.escapeJson(&buf, issue) catch return allocOomError(allocator);
        }
        json.puts(&buf, "]") catch return allocOomError(allocator);
    }

    json.puts(&buf, "}") catch return allocOomError(allocator);
    return json.finish(&buf);
}

// ---------------------------------------------------------------------------
// Subcommand: report
// ---------------------------------------------------------------------------

/// Generate a summary report of changesets and pending HCs. Returns JSON.
/// Source: tool/memory/designer.zig — summary report subcommand
pub fn cmdReport(allocator: std.mem.Allocator, io: Io, args: std.json.ObjectMap) []const u8 {
    _ = args;

    const changesets = listChangeSets(allocator, io, null) catch return allocOomError(allocator);
    defer {
        for (changesets) |cs| freeChangeSet(allocator, &cs);
        allocator.free(changesets);
    }

    // Count by status
    const total: usize = changesets.len;
    var draft_count: usize = 0;
    var proposed_count: usize = 0;
    var approved_count: usize = 0;
    var applied_count: usize = 0;
    var rejected_count: usize = 0;
    var rolled_back_count: usize = 0;

    for (changesets) |cs| {
        if (std.mem.eql(u8, cs.status, "draft")) draft_count += 1;
        if (std.mem.eql(u8, cs.status, "proposed")) proposed_count += 1;
        if (std.mem.eql(u8, cs.status, "approved")) approved_count += 1;
        if (std.mem.eql(u8, cs.status, "applied")) applied_count += 1;
        if (std.mem.eql(u8, cs.status, "rejected")) rejected_count += 1;
        if (std.mem.eql(u8, cs.status, "rolled_back")) rolled_back_count += 1;
    }

    // Count pending HCs
    var state = session.load(allocator, io);
    defer state.deinit(allocator);
    var pending_hc: usize = 0;
    for (state.hard_case_buffer) |hc| {
        if (!hc.consumed) pending_hc += 1;
    }

    var buf = std.array_list.Managed(u8).init(allocator);
    defer buf.deinit();

    json.puts(&buf, "{\"changesets\":{\"total\":") catch return allocOomError(allocator);
    var nb: [32]u8 = undefined;
    const ts = std.fmt.bufPrint(&nb, "{d}", .{total}) catch "0";
    json.puts(&buf, ts) catch return allocOomError(allocator);
    json.puts(&buf, ",\"byStatus\":{") catch return allocOomError(allocator);
    json.putInt(&buf, "draft", draft_count) catch return allocOomError(allocator);
    json.putc(&buf, ',') catch return allocOomError(allocator);
    json.putInt(&buf, "proposed", proposed_count) catch return allocOomError(allocator);
    json.putc(&buf, ',') catch return allocOomError(allocator);
    json.putInt(&buf, "approved", approved_count) catch return allocOomError(allocator);
    json.putc(&buf, ',') catch return allocOomError(allocator);
    json.putInt(&buf, "applied", applied_count) catch return allocOomError(allocator);
    json.putc(&buf, ',') catch return allocOomError(allocator);
    json.putInt(&buf, "rejected", rejected_count) catch return allocOomError(allocator);
    json.putc(&buf, ',') catch return allocOomError(allocator);
    json.putInt(&buf, "rolled_back", rolled_back_count) catch return allocOomError(allocator);
    json.puts(&buf, "}},") catch return allocOomError(allocator);
    json.puts(&buf, "\"pendingHC\":") catch return allocOomError(allocator);
    const ps = std.fmt.bufPrint(&nb, "{d}", .{pending_hc}) catch "0";
    json.puts(&buf, ps) catch return allocOomError(allocator);
    json.puts(&buf, "}") catch return allocOomError(allocator);
    return json.finish(&buf);
}

// ---------------------------------------------------------------------------
// Top-level dispatcher
// ---------------------------------------------------------------------------

/// Execute designer subcommands: collect, propose, list, review, approve, apply,
/// rollback, verify, report. Returns JSON output.
/// Source: tool/memory/designer.zig — top-level command dispatcher
pub fn cmdDesigner(allocator: std.mem.Allocator, io: Io, args: std.json.ObjectMap) []const u8 {
    const subcommand_val = args.get("subcommand") orelse
        return allocError(allocator, "missing 'subcommand' for designer");
    const subcommand = if (subcommand_val == .string) subcommand_val.string else
        return allocError(allocator, "'subcommand' must be a string");

    if (std.mem.eql(u8, subcommand, "collect")) {
        return cmdCollect(allocator, io, args);
    } else if (std.mem.eql(u8, subcommand, "propose")) {
        return cmdPropose(allocator, io, args);
    } else if (std.mem.eql(u8, subcommand, "list")) {
        return cmdList(allocator, io, args);
    } else if (std.mem.eql(u8, subcommand, "review")) {
        return cmdReview(allocator, io, args);
    } else if (std.mem.eql(u8, subcommand, "approve")) {
        return cmdApprove(allocator, io, args);
    } else if (std.mem.eql(u8, subcommand, "apply")) {
        return cmdApply(allocator, io, args);
    } else if (std.mem.eql(u8, subcommand, "rollback")) {
        return cmdRollback(allocator, io, args);
    } else if (std.mem.eql(u8, subcommand, "verify")) {
        return cmdVerify(allocator, io, args);
    } else if (std.mem.eql(u8, subcommand, "report")) {
        return cmdReport(allocator, io, args);
    } else {
        return allocError(allocator, "unknown subcommand");
    }
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

fn cleanupTestDir(io: Io) void {
    _ = Io.Dir.cwd().deleteTree(io, "zig_test_designer/.zagent") catch {};
    _ = Io.Dir.cwd().deleteDir(io, "zig_test_designer") catch {};
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "designer: collect returns empty when no HCs" {
    const testing = std.testing;
    const a = testing.allocator;
    const io = testing.io;

    root_dir.init("zig_test_designer");
    defer {
        root_dir.init("");
        cleanupTestDir(io);
    }

    // Create empty session-state (no HCs)
    var state = session.SessionState{
        .last_topic = "",
        .last_update = "",
        .pending_decisions = &.{},
        .active_learnings = &.{},
        .hard_case_buffer = &.{},
        .skill_metrics = .{
            .recall = .{ .calls = 0, .failures = 0, .anchors_rejected = 0, .avg_score = 0.0 },
            .add = .{ .calls = 0, .failures = 0, .anchors_rejected = 0, .avg_score = 0.0 },
        },
        .designer_runs = &.{},
        .task_calls = &.{},
        .operation_log = &.{},
        .unfinished_tasks = &.{},
        .last_session_end = null,
    };
    try session.save(a, io, &state);

    var parsed = try std.json.parseFromSlice(std.json.Value, a, "{\"subcommand\":\"collect\",\"limit\":5}", .{});
    defer parsed.deinit();

    const output = cmdCollect(a, io, parsed.value.object);
    defer a.free(output);

    try testing.expect(std.mem.startsWith(u8, output, "{"));
    try testing.expect(std.mem.indexOf(u8, output, "\"collected\":0") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\"hardCases\":[]") != null);
}

test "designer: propose creates changeset with valid confidence" {
    const testing = std.testing;
    const a = testing.allocator;
    const io = testing.io;

    root_dir.init("zig_test_designer");
    defer {
        root_dir.init("");
        cleanupTestDir(io);
    }

    // Create a session-state with a hard case
    const hc_id = "HC-0001";
    var state = session.SessionState{
        .last_topic = "",
        .last_update = "",
        .pending_decisions = &.{},
        .active_learnings = &.{},
        .hard_case_buffer = &.{},
        .skill_metrics = .{
            .recall = .{ .calls = 0, .failures = 0, .anchors_rejected = 0, .avg_score = 0.0 },
            .add = .{ .calls = 0, .failures = 0, .anchors_rejected = 0, .avg_score = 0.0 },
        },
        .designer_runs = &.{},
        .task_calls = &.{},
        .operation_log = &.{},
        .unfinished_tasks = &.{},
        .last_session_end = null,
    };
    try session.addHardCase(&state, a, io, .{
        .id = hc_id,
        .symptom = "test symptom",
        .context = "test context",
        .source = "bash_error",
        .timestamp = "2026-07-02T00:00:00Z",
        .consumed = false,
    });
    try session.save(a, io, &state);
    state.deinit(a);

    // Create a fresh state and HC for cmdPropose
    var state2 = session.SessionState{
        .last_topic = "",
        .last_update = "",
        .pending_decisions = &.{},
        .active_learnings = &.{},
        .hard_case_buffer = &.{},
        .skill_metrics = .{
            .recall = .{ .calls = 0, .failures = 0, .anchors_rejected = 0, .avg_score = 0.0 },
            .add = .{ .calls = 0, .failures = 0, .anchors_rejected = 0, .avg_score = 0.0 },
        },
        .designer_runs = &.{},
        .task_calls = &.{},
        .operation_log = &.{},
        .unfinished_tasks = &.{},
        .last_session_end = null,
    };
    defer state2.deinit(a);
    try session.addHardCase(&state2, a, io, .{
        .id = hc_id,
        .symptom = "test symptom",
        .context = "test context",
        .source = "bash_error",
        .timestamp = "2026-07-02T00:00:00Z",
        .consumed = false,
    });
    try session.save(a, io, &state2);

    // Test that cmdPropose returns JSON with id field
    const propose_json = try std.fmt.allocPrint(a, "{{\"subcommand\":\"propose\",\"id\":\"{s}\"}}", .{hc_id});
    defer a.free(propose_json);
    var parsed = try std.json.parseFromSlice(std.json.Value, a, propose_json, .{});
    defer parsed.deinit();

    const output = cmdPropose(a, io, parsed.value.object);
    defer a.free(output);

    try testing.expect(std.mem.startsWith(u8, output, "{"));
    try testing.expect(std.mem.indexOf(u8, output, "\"id\"") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\"confidence\"") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\"status\"") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\"entryId\"") != null);
}

test "designer: list returns changesets" {
    const testing = std.testing;
    const a = testing.allocator;
    const io = testing.io;

    root_dir.init("zig_test_designer");
    defer {
        root_dir.init("");
        cleanupTestDir(io);
    }

    // Create a session-state with a hard case
    const hc_id = "HC-0002";
    var state = session.SessionState{
        .last_topic = "",
        .last_update = "",
        .pending_decisions = &.{},
        .active_learnings = &.{},
        .hard_case_buffer = &.{},
        .skill_metrics = .{
            .recall = .{ .calls = 0, .failures = 0, .anchors_rejected = 0, .avg_score = 0.0 },
            .add = .{ .calls = 0, .failures = 0, .anchors_rejected = 0, .avg_score = 0.0 },
        },
        .designer_runs = &.{},
        .task_calls = &.{},
        .operation_log = &.{},
        .unfinished_tasks = &.{},
        .last_session_end = null,
    };
    defer state.deinit(a);
    try session.addHardCase(&state, a, io, .{
        .id = hc_id,
        .symptom = "build error test case",
        .context = "some context",
        .source = "test",
        .timestamp = "2026-07-02T00:00:00Z",
        .consumed = false,
    });
    try session.save(a, io, &state);

    // Create a changeset via propose
    const propose_json = try std.fmt.allocPrint(a, "{{\"subcommand\":\"propose\",\"id\":\"{s}\"}}", .{hc_id});
    defer a.free(propose_json);
    var parsed = try std.json.parseFromSlice(std.json.Value, a, propose_json, .{});
    defer parsed.deinit();
    const propose_output = cmdPropose(a, io, parsed.value.object);
    defer a.free(propose_output);

    // Extract the changeset ID from the response
    var parsed_res = try std.json.parseFromSlice(std.json.Value, a, propose_output, .{});
    defer parsed_res.deinit();
    const cs_id = try a.dupe(u8, parsed_res.value.object.get("id").?.string);
    defer a.free(cs_id);

    // List all changesets
    var parsed_list = try std.json.parseFromSlice(std.json.Value, a, "{\"subcommand\":\"list\"}", .{});
    defer parsed_list.deinit();

    const list_output = cmdList(a, io, parsed_list.value.object);
    defer a.free(list_output);

    try testing.expect(std.mem.startsWith(u8, list_output, "{"));
    try testing.expect(std.mem.indexOf(u8, list_output, "\"changesets\"") != null);
    try testing.expect(std.mem.indexOf(u8, list_output, cs_id) != null);
}

test "designer: approve changes status" {
    const testing = std.testing;
    const a = testing.allocator;
    const io = testing.io;

    root_dir.init("zig_test_designer");
    defer {
        root_dir.init("");
        cleanupTestDir(io);
    }

    // Create session with HC
    const hc_id = "HC-0003";
    var state = session.SessionState{
        .last_topic = "",
        .last_update = "",
        .pending_decisions = &.{},
        .active_learnings = &.{},
        .hard_case_buffer = &.{},
        .skill_metrics = .{
            .recall = .{ .calls = 0, .failures = 0, .anchors_rejected = 0, .avg_score = 0.0 },
            .add = .{ .calls = 0, .failures = 0, .anchors_rejected = 0, .avg_score = 0.0 },
        },
        .designer_runs = &.{},
        .task_calls = &.{},
        .operation_log = &.{},
        .unfinished_tasks = &.{},
        .last_session_end = null,
    };
    defer state.deinit(a);
    try session.addHardCase(&state, a, io, .{
        .id = hc_id,
        .symptom = "approve test case",
        .context = "test",
        .source = "test",
        .timestamp = "2026-07-02T00:00:00Z",
        .consumed = false,
    });
    try session.save(a, io, &state);

    // Propose
    const propose_json = try std.fmt.allocPrint(a, "{{\"subcommand\":\"propose\",\"id\":\"{s}\"}}", .{hc_id});
    defer a.free(propose_json);
    var parsed = try std.json.parseFromSlice(std.json.Value, a, propose_json, .{});
    defer parsed.deinit();
    const propose_output = cmdPropose(a, io, parsed.value.object);
    defer a.free(propose_output);

    // Extract changeset ID
    var parsed_res = try std.json.parseFromSlice(std.json.Value, a, propose_output, .{});
    defer parsed_res.deinit();
    const cs_id = try a.dupe(u8, parsed_res.value.object.get("id").?.string);
    defer a.free(cs_id);

    // Approve
    const approve_json = try std.fmt.allocPrint(a, "{{\"subcommand\":\"approve\",\"id\":\"{s}\"}}", .{cs_id});
    defer a.free(approve_json);
    parsed = try std.json.parseFromSlice(std.json.Value, a, approve_json, .{});
    defer parsed.deinit();

    const approve_output = cmdApprove(a, io, parsed.value.object);
    defer a.free(approve_output);

    try testing.expect(std.mem.startsWith(u8, approve_output, "{"));
    try testing.expect(std.mem.indexOf(u8, approve_output, "\"approved\":true") != null);
    try testing.expect(std.mem.indexOf(u8, approve_output, cs_id) != null);

    // Verify the changeset status changed to "approved"
    const cs = loadChangeSet(a, io, cs_id) catch {
        try testing.expect(false);
        return;
    };
    defer freeChangeSet(a, &cs);
    try testing.expectEqualStrings("approved", cs.status);
}

test "designer: apply with snapshot mismatch rejects" {
    const testing = std.testing;
    const a = testing.allocator;
    const io = testing.io;

    root_dir.init("zig_test_designer");
    defer {
        root_dir.init("");
        cleanupTestDir(io);
    }

    // Create session with HC
    const hc_id = "HC-0004";
    var state = session.SessionState{
        .last_topic = "",
        .last_update = "",
        .pending_decisions = &.{},
        .active_learnings = &.{},
        .hard_case_buffer = &.{},
        .skill_metrics = .{
            .recall = .{ .calls = 0, .failures = 0, .anchors_rejected = 0, .avg_score = 0.0 },
            .add = .{ .calls = 0, .failures = 0, .anchors_rejected = 0, .avg_score = 0.0 },
        },
        .designer_runs = &.{},
        .task_calls = &.{},
        .operation_log = &.{},
        .unfinished_tasks = &.{},
        .last_session_end = null,
    };
    defer state.deinit(a);
    try session.addHardCase(&state, a, io, .{
        .id = hc_id,
        .symptom = "apply mismatch test",
        .context = "test",
        .source = "test",
        .timestamp = "2026-07-02T00:00:00Z",
        .consumed = false,
    });
    try session.save(a, io, &state);

    // Create a changeset with a deliberately wrong snapshot
    // First create the changesets directory
    const dir_path = try changesetsDir(a);
    defer a.free(dir_path);
    Io.Dir.cwd().createDirPath(io, dir_path) catch {};

    const cs_id = "CS-00000000-999";
    const bad_cs = ChangeSet{
        .id = try a.dupe(u8, cs_id),
        .hard_case_id = try a.dupe(u8, hc_id),
        .title = try a.dupe(u8, "test"),
        .summary = try a.dupe(u8, "test summary"),
        .old_entry = null,
        .new_entry = try a.dupe(u8, "## [MEM-00000000-999] Test\n\nBody\n"),
        .status = try a.dupe(u8, "approved"),
        .created = try a.dupe(u8, "2026-07-02T00:00:00Z"),
        .applied = null,
        .confidence = 0.9,
        .snapshot = Snapshot{
            .mtime = 1, // Wrong mtime
            .size = 1, // Wrong size
            .crc32 = 1, // Wrong CRC32
        },
    };
    defer freeChangeSet(a, &bad_cs);
    try saveChangeSet(a, io, &bad_cs);

    // Try to apply (should fail due to snapshot mismatch)
    const apply_json = try std.fmt.allocPrint(a, "{{\"subcommand\":\"apply\",\"id\":\"{s}\"}}", .{cs_id});
    defer a.free(apply_json);
    var parsed = try std.json.parseFromSlice(std.json.Value, a, apply_json, .{});
    defer parsed.deinit();

    const apply_output = cmdApply(a, io, parsed.value.object);
    defer a.free(apply_output);

    // Should return an error because memory.md doesn't exist yet (snapshot mismatch)
    try testing.expect(std.mem.startsWith(u8, apply_output, "Error:"));
    try testing.expect(std.mem.indexOf(u8, apply_output, "memory.md") != null);
}

test "designer: report returns summary stats" {
    const testing = std.testing;
    const a = testing.allocator;
    const io = testing.io;

    root_dir.init("zig_test_designer");
    defer {
        root_dir.init("");
        cleanupTestDir(io);
    }

    // Create session with an unconsumed HC
    var state = session.SessionState{
        .last_topic = "",
        .last_update = "",
        .pending_decisions = &.{},
        .active_learnings = &.{},
        .hard_case_buffer = &.{},
        .skill_metrics = .{
            .recall = .{ .calls = 0, .failures = 0, .anchors_rejected = 0, .avg_score = 0.0 },
            .add = .{ .calls = 0, .failures = 0, .anchors_rejected = 0, .avg_score = 0.0 },
        },
        .designer_runs = &.{},
        .task_calls = &.{},
        .operation_log = &.{},
        .unfinished_tasks = &.{},
        .last_session_end = null,
    };
    defer state.deinit(a);
    try session.addHardCase(&state, a, io, .{
        .id = "HC-REPORT-001",
        .symptom = "report test",
        .context = "test",
        .source = "test",
        .timestamp = "2026-07-02T00:00:00Z",
        .consumed = false,
    });
    try session.save(a, io, &state);

    // Create a changeset
    {
        const propose_json = "{\"subcommand\":\"propose\",\"id\":\"HC-REPORT-001\"}";
        var parsed = try std.json.parseFromSlice(std.json.Value, a, propose_json, .{});
        defer parsed.deinit();
        const output = cmdPropose(a, io, parsed.value.object);
        defer a.free(output);
    }

    // Get report
    var parsed = try std.json.parseFromSlice(std.json.Value, a, "{\"subcommand\":\"report\"}", .{});
    defer parsed.deinit();

    const output = cmdReport(a, io, parsed.value.object);
    defer a.free(output);

    try testing.expect(std.mem.startsWith(u8, output, "{"));
    try testing.expect(std.mem.indexOf(u8, output, "\"changesets\"") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\"pendingHC\"") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\"byStatus\"") != null);
}

test "designer: collect retrieves unconsumed HCs" {
    const testing = std.testing;
    const a = testing.allocator;
    const io = testing.io;

    root_dir.init("zig_test_designer");
    defer {
        root_dir.init("");
        cleanupTestDir(io);
    }

    // Create session with an unconsumed HC
    var state = session.SessionState{
        .last_topic = "",
        .last_update = "",
        .pending_decisions = &.{},
        .active_learnings = &.{},
        .hard_case_buffer = &.{},
        .skill_metrics = .{
            .recall = .{ .calls = 0, .failures = 0, .anchors_rejected = 0, .avg_score = 0.0 },
            .add = .{ .calls = 0, .failures = 0, .anchors_rejected = 0, .avg_score = 0.0 },
        },
        .designer_runs = &.{},
        .task_calls = &.{},
        .operation_log = &.{},
        .unfinished_tasks = &.{},
        .last_session_end = null,
    };
    defer state.deinit(a);
    try session.addHardCase(&state, a, io, .{
        .id = "HC-COLLECT-001",
        .symptom = "collect test symptom",
        .context = "collect context",
        .source = "user",
        .timestamp = "2026-07-02T00:00:00Z",
        .consumed = false,
    });
    try session.save(a, io, &state);

    // Collect
    var parsed = try std.json.parseFromSlice(std.json.Value, a, "{\"subcommand\":\"collect\",\"limit\":10}", .{});
    defer parsed.deinit();

    const output = cmdCollect(a, io, parsed.value.object);
    defer a.free(output);

    try testing.expect(std.mem.startsWith(u8, output, "{"));
    try testing.expect(std.mem.indexOf(u8, output, "\"collected\":1") != null);
    try testing.expect(std.mem.indexOf(u8, output, "HC-COLLECT-001") != null);

    // Verify HCs are now marked consumed
    var loaded_state = session.load(a, io);
    defer loaded_state.deinit(a);
    try testing.expectEqual(@as(usize, 1), loaded_state.hard_case_buffer.len);
    try testing.expectEqual(true, loaded_state.hard_case_buffer[0].consumed);
}

test "designer: list with status filter" {
    const testing = std.testing;
    const a = testing.allocator;
    const io = testing.io;

    root_dir.init("zig_test_designer");
    defer {
        root_dir.init("");
        cleanupTestDir(io);
    }

    // Create HC and propose
    var state = session.SessionState{
        .last_topic = "",
        .last_update = "",
        .pending_decisions = &.{},
        .active_learnings = &.{},
        .hard_case_buffer = &.{},
        .skill_metrics = .{
            .recall = .{ .calls = 0, .failures = 0, .anchors_rejected = 0, .avg_score = 0.0 },
            .add = .{ .calls = 0, .failures = 0, .anchors_rejected = 0, .avg_score = 0.0 },
        },
        .designer_runs = &.{},
        .task_calls = &.{},
        .operation_log = &.{},
        .unfinished_tasks = &.{},
        .last_session_end = null,
    };
    defer state.deinit(a);
    try session.addHardCase(&state, a, io, .{
        .id = "HC-LIST-001",
        .symptom = "list filter test",
        .context = "test",
        .source = "test",
        .timestamp = "2026-07-02T00:00:00Z",
        .consumed = false,
    });
    try session.save(a, io, &state);

    // Propose
    {
        const pj = "{\"subcommand\":\"propose\",\"id\":\"HC-LIST-001\"}";
        var p = try std.json.parseFromSlice(std.json.Value, a, pj, .{});
        defer p.deinit();
        const o = cmdPropose(a, io, p.value.object);
        a.free(o);
    }

    // List with filter for a status that shouldn't match
    var parsed = try std.json.parseFromSlice(std.json.Value, a, "{\"subcommand\":\"list\",\"status\":\"applied\"}", .{});
    defer parsed.deinit();

    const output = cmdList(a, io, parsed.value.object);
    defer a.free(output);

    try testing.expect(std.mem.startsWith(u8, output, "{"));
    try testing.expect(std.mem.indexOf(u8, output, "\"changesets\":[]") != null);
}
