const std = @import("std");
const json = @import("../json.zig");
const root_dir = @import("../root_dir.zig");
const types = @import("types.zig");
const parse = @import("parse.zig");

const Entry = types.Entry;

// ---------------------------------------------------------------------------
// cmdArchive
// ---------------------------------------------------------------------------

/// Archive entries from memory.md to memory-archive.md.
/// Supports --id, --older-than <days>, and --all flags.
pub fn cmdArchive(allocator: std.mem.Allocator, io: std.Io, args: std.json.ObjectMap) []const u8 {
    const mem_path = parse.memoryPath(allocator) catch return allocError(allocator, "OOM");
    defer allocator.free(mem_path);

    const content = parse.readFile(allocator, io, mem_path) orelse {
        return std.fmt.allocPrint(allocator, "{{\"archived\":0}}", .{}) catch allocOomError(allocator);
    };
    defer allocator.free(content);

    const entries = parse.parseEntries(allocator, content) catch return allocError(allocator, "parse failed");
    defer allocator.free(entries);

    const id_arg = if (args.get("id")) |v| if (v == .string and v.string.len > 0) v.string else null else null;
    const older_than = if (args.get("older-than")) |v| std.fmt.parseInt(i64, v.string, 10) catch 0 else 0;
    const all_flag = if (args.get("all")) |v| v == .bool and v.bool else false;

    // Read existing archive content
    const archive_path = parse.archivePath(allocator) catch return allocError(allocator, "OOM");
    defer allocator.free(archive_path);

    // Identify entries to archive
    var to_archive = std.array_list.Managed(usize).init(allocator);
    defer to_archive.deinit();

    const today_str = parse.todayDateString(io);

    for (entries, 0..) |entry, i| {
        if (entry.archived) continue;

        if (id_arg) |id| {
            if (std.mem.eql(u8, entry.id, id)) {
                to_archive.append(i) catch return allocError(allocator, "OOM");
                break;
            }
        } else if (older_than > 0) {
            // Compare logged date
            const logged_compact = compactDate(entry.logged);
            if (logged_compact) |lc| {
                const diff = dateDiff(today_str, lc);
                if (diff >= older_than) {
                    to_archive.append(i) catch return allocError(allocator, "OOM");
                }
            }
        } else if (all_flag) {
            to_archive.append(i) catch return allocError(allocator, "OOM");
        }
    }

    if (to_archive.items.len == 0) {
        return std.fmt.allocPrint(allocator, "{{\"archived\":0}}", .{}) catch allocOomError(allocator);
    }

    // Build new memory.md content (without archived entries)
    var new_mem = std.array_list.Managed(u8).init(allocator);
    defer new_mem.deinit();

    // Build archive entries to append
    var archive_buf = std.array_list.Managed(u8).init(allocator);
    defer archive_buf.deinit();

    // Read existing archive file
    const archive_content = parse.readFile(allocator, io, archive_path);
    defer if (archive_content) |c| allocator.free(c);

    if (archive_content) |ac| {
        archive_buf.appendSlice(ac) catch return allocError(allocator, "OOM");
        if (ac.len > 0 and !std.mem.endsWith(u8, ac, "\n---\n\n")) {
            archive_buf.appendSlice("\n---\n\n") catch return allocError(allocator, "OOM");
        }
    }

    var archived_count: usize = 0;

    for (entries, 0..) |entry, i| {
        var should_archive = false;
        for (to_archive.items) |idx| {
            if (i == idx) {
                should_archive = true;
                break;
            }
        }

        if (should_archive) {
            // Add to archive
            if (archive_buf.items.len > 0 and !std.mem.endsWith(u8, archive_buf.items, "\n---\n\n")) {
                archive_buf.appendSlice("\n---\n\n") catch return allocError(allocator, "OOM");
            }
            archive_buf.appendSlice(entry.raw) catch return allocError(allocator, "OOM");
            archived_count += 1;
        } else {
            // Keep in memory.md
            if (new_mem.items.len > 0) {
                new_mem.appendSlice("\n---\n\n") catch return allocError(allocator, "OOM");
            }
            new_mem.appendSlice(entry.raw) catch return allocError(allocator, "OOM");
        }
    }

    // Atomic write both files
    parse.atomicWrite(allocator, io, mem_path, new_mem.items) catch {
        return allocError(allocator, "write memory.md failed");
    };
    parse.atomicWrite(allocator, io, archive_path, archive_buf.items) catch {
        return allocError(allocator, "write memory-archive.md failed");
    };
    parse.invalidateCache(allocator);

    return std.fmt.allocPrint(allocator, "{{\"archived\":{d}}}", .{archived_count}) catch allocOomError(allocator);
}

// ---------------------------------------------------------------------------
// cmdPromote
// ---------------------------------------------------------------------------

/// Promote an entry: modify priority. Supports --id and --priority.
pub fn cmdPromote(allocator: std.mem.Allocator, io: std.Io, args: std.json.ObjectMap) []const u8 {
    const id_val = args.get("id") orelse return allocError(allocator, "missing 'id' for promote");
    const id = if (id_val == .string) id_val.string else return allocError(allocator, "'id' must be a string");

    const priority_val = args.get("priority") orelse return allocError(allocator, "missing 'priority' for promote");
    const new_priority = if (priority_val == .string) priority_val.string else return allocError(allocator, "'priority' must be a string");

    // Validate priority value
    if (!isValidPriority(new_priority)) {
        return allocError(allocator, "invalid priority: must be low, medium, high, or critical");
    }

    const mem_path = parse.memoryPath(allocator) catch return allocError(allocator, "OOM");
    defer allocator.free(mem_path);

    const content = parse.readFile(allocator, io, mem_path) orelse {
        return std.fmt.allocPrint(allocator, "{{\"promoted\":false,\"error\":\"not found\"}}", .{}) catch allocOomError(allocator);
    };
    defer allocator.free(content);

    const entries = parse.parseEntries(allocator, content) catch return allocError(allocator, "parse failed");
    defer allocator.free(entries);

    // Find the entry (verify existence)
    var found = false;
    for (entries) |e| {
        if (std.mem.eql(u8, e.id, id)) {
            found = true;
            break;
        }
    }
    if (!found) {
        return std.fmt.allocPrint(allocator, "{{\"promoted\":false,\"error\":\"not found\"}}", .{}) catch allocOomError(allocator);
    }

    // Rebuild file with modified entry
    var new_content = std.array_list.Managed(u8).init(allocator);
    defer new_content.deinit();

    for (entries, 0..) |e, i| {
        if (i > 0) {
            new_content.appendSlice("\n---\n\n") catch return allocError(allocator, "OOM");
        }
        if (std.mem.eql(u8, e.id, id)) {
            // Modify priority in this entry
            var modified_entry = e;
            modified_entry.priority = new_priority;

            // Extract body from raw
            const body = extractBody(e.raw);
            const serialized = parse.serializeEntry(allocator, modified_entry, body) catch return allocOomError(allocator);
            defer allocator.free(serialized);
            new_content.appendSlice(serialized) catch return allocError(allocator, "OOM");
        } else {
            new_content.appendSlice(e.raw) catch return allocError(allocator, "OOM");
        }
    }

    // Atomic write
    parse.atomicWrite(allocator, io, mem_path, new_content.items) catch {
        return allocError(allocator, "write failed");
    };
    parse.invalidateCache(allocator);

    return std.fmt.allocPrint(allocator, "{{\"promoted\":true,\"id\":\"{s}\",\"priority\":\"{s}\"}}", .{ id, new_priority }) catch allocOomError(allocator);
}

// ---------------------------------------------------------------------------
// cmdStat
// ---------------------------------------------------------------------------

/// Compute statistics over memory entries. Returns JSON with counts.
pub fn cmdStat(allocator: std.mem.Allocator, io: std.Io, args: std.json.ObjectMap) []const u8 {
    _ = args;

    const mem_path = parse.memoryPath(allocator) catch return allocError(allocator, "OOM");
    defer allocator.free(mem_path);

    const entries = parse.getEntries(allocator, io, mem_path) catch return allocError(allocator, "read failed");

    var total: usize = 0;
    var by_priority = std.StringHashMapUnmanaged(usize){};
    defer by_priority.deinit(allocator);
    var by_scope = std.StringHashMapUnmanaged(usize){};
    defer by_scope.deinit(allocator);
    var by_status = std.StringHashMapUnmanaged(usize){};
    defer by_status.deinit(allocator);

    for (entries) |entry| {
        if (entry.archived) continue;
        total += 1;

        const p_key = allocator.dupe(u8, entry.priority) catch continue;
        const gop = by_priority.getOrPut(allocator, p_key) catch {
            allocator.free(p_key);
            continue;
        };
        if (gop.found_existing) allocator.free(p_key);
        gop.value_ptr.* += 1;

        const s_key = allocator.dupe(u8, entry.scope) catch continue;
        const gop2 = by_scope.getOrPut(allocator, s_key) catch {
            allocator.free(s_key);
            continue;
        };
        if (gop2.found_existing) allocator.free(s_key);
        gop2.value_ptr.* += 1;

        const st_key = allocator.dupe(u8, entry.status) catch continue;
        const gop3 = by_status.getOrPut(allocator, st_key) catch {
            allocator.free(st_key);
            continue;
        };
        if (gop3.found_existing) allocator.free(st_key);
        gop3.value_ptr.* += 1;
    }

    // Build JSON
    var buf = std.array_list.Managed(u8).init(allocator);
    defer buf.deinit();

    json.puts(&buf, "{\"total\":") catch return allocOomError(allocator);
    var num_buf: [32]u8 = undefined;
    const total_str = std.fmt.bufPrint(&num_buf, "{d}", .{total}) catch "0";
    json.puts(&buf, total_str) catch return allocOomError(allocator);
    json.puts(&buf, ",\"byPriority\":{") catch return allocOomError(allocator);
    appendHashMap(&buf, by_priority) catch return allocOomError(allocator);
    json.puts(&buf, "},\"byScope\":{") catch return allocOomError(allocator);
    appendHashMap(&buf, by_scope) catch return allocOomError(allocator);
    json.puts(&buf, "},\"byStatus\":{") catch return allocOomError(allocator);
    appendHashMap(&buf, by_status) catch return allocOomError(allocator);
    json.puts(&buf, "}}") catch return allocOomError(allocator);

    return json.finish(&buf);
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

fn appendHashMap(buf: *std.array_list.Managed(u8), map: std.StringHashMapUnmanaged(usize)) !void {
    var it = map.iterator();
    var first = true;
    while (it.next()) |entry| {
        if (!first) try buf.append(',');
        first = false;
        try json.escapeJson(buf, entry.key_ptr.*);
        try buf.append(':');
        var nb: [32]u8 = undefined;
        const ns = try std.fmt.bufPrint(&nb, "{d}", .{entry.value_ptr.*});
        try buf.appendSlice(ns);
    }
}

fn isValidPriority(p: []const u8) bool {
    return std.mem.eql(u8, p, "low") or
        std.mem.eql(u8, p, "medium") or
        std.mem.eql(u8, p, "high") or
        std.mem.eql(u8, p, "critical");
}

/// Extract body text from raw entry text (content after metadata section).
/// Returns slice borrowed from 'raw'.
fn extractBody(raw: []const u8) []const u8 {
    const header_end = std.mem.indexOfScalar(u8, raw, '\n') orelse return raw;
    var meta_pos = header_end + 1;
    while (meta_pos < raw.len) {
        const line_end = std.mem.indexOfScalarPos(u8, raw, meta_pos, '\n') orelse raw.len;
        const line = std.mem.trim(u8, raw[meta_pos..line_end], " \r");
        if (line.len == 0) {
            meta_pos = line_end + 1;
            break;
        }
        meta_pos = line_end + 1;
    }
    if (meta_pos >= raw.len) return "";
    return raw[meta_pos..];
}

/// Convert "YYYY-MM-DD" to "YYYYMMDD" for comparison.
/// Returns null on parse failure.
fn compactDate(date_str: []const u8) ?[8]u8 {
    if (date_str.len < 10) return null;
    var buf: [8]u8 = undefined;
    buf[0..4].* = date_str[0..4].*;
    buf[4..6].* = date_str[5..7].*;
    buf[6..8].* = date_str[8..10].*;
    return buf;
}

/// Calculate difference in days between two YYYYMMDD dates (today - logged).
fn dateDiff(today: [8]u8, logged: [8]u8) i64 {
    const t_y = std.fmt.parseInt(i64, today[0..4], 10) catch return 0;
    const t_m = std.fmt.parseInt(i64, today[4..6], 10) catch return 0;
    const t_d = std.fmt.parseInt(i64, today[6..8], 10) catch return 0;
    const l_y = std.fmt.parseInt(i64, logged[0..4], 10) catch return 0;
    const l_m = std.fmt.parseInt(i64, logged[4..6], 10) catch return 0;
    const l_d = std.fmt.parseInt(i64, logged[6..8], 10) catch return 0;

    const today_days = ymdToDays(t_y, t_m, t_d);
    const logged_days = ymdToDays(l_y, l_m, l_d);
    return today_days - logged_days;
}

/// Simple days-since-epoch (not accounting for leap seconds, good for date diff).
fn ymdToDays(year: i64, month: i64, day: i64) i64 {
    const y = if (month <= 2) year - 1 else year;
    const m = if (month <= 2) month + 12 else month;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const doy = @divFloor(153 * (m - 3) + 2, 5) + day - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

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
    _ = std.Io.Dir.cwd().deleteTree(io, "zig_test_memory_root/.zagent") catch {};
    _ = std.Io.Dir.cwd().deleteDir(io, "zig_test_memory_root") catch {};
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "archive: stat with empty file" {
    const testing = std.testing;
    const a = testing.allocator;
    const io = testing.io;

    root_dir.init("zig_test_memory_root");
    defer {
        root_dir.init("");
        cleanupTestDir(io);
    }

    var parsed = try std.json.parseFromSlice(std.json.Value, a, "{}", .{});
    defer parsed.deinit();

    const output = cmdStat(a, io, parsed.value.object);
    defer a.free(output);

    try testing.expect(std.mem.startsWith(u8, output, "{"));
    try testing.expect(std.mem.indexOf(u8, output, "\"total\":0") != null);
}

test "archive: promote changes priority" {
    const testing = std.testing;
    const a = testing.allocator;
    const io = testing.io;

    root_dir.init("zig_test_memory_root");
    defer {
        root_dir.init("");
        cleanupTestDir(io);
    }

    // Add an entry via crud.cmdAdd (imported in test context via crud.zig)
    const crud_mod = @import("crud.zig");
    const add_json = try std.fmt.allocPrint(a, "{{\"command\":\"add\",\"content\":\"测试提升优先级\",\"source\":\"test\"}}", .{});
    defer a.free(add_json);
    var parsed = try std.json.parseFromSlice(std.json.Value, a, add_json, .{});
    const add_output = crud_mod.cmdAdd(a, io, parsed.value.object);
    parsed.deinit();
    defer a.free(add_output);

    // Extract ID
    var parsed_res = try std.json.parseFromSlice(std.json.Value, a, add_output, .{});
    defer parsed_res.deinit();
    const mem_id = try a.dupe(u8, parsed_res.value.object.get("id").?.string);
    defer a.free(mem_id);

    // Promote it
    const promote_json = try std.fmt.allocPrint(a, "{{\"command\":\"promote\",\"id\":\"{s}\",\"priority\":\"high\"}}", .{mem_id});
    defer a.free(promote_json);
    parsed = try std.json.parseFromSlice(std.json.Value, a, promote_json, .{});
    defer parsed.deinit();

    const output = cmdPromote(a, io, parsed.value.object);
    defer a.free(output);

    try testing.expect(std.mem.startsWith(u8, output, "{"));
    try testing.expect(std.mem.indexOf(u8, output, "\"promoted\":true") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\"priority\":\"high\"") != null);
    try testing.expect(std.mem.indexOf(u8, output, mem_id) != null);
}

test "archive: promote with invalid priority returns error" {
    const testing = std.testing;
    const a = testing.allocator;
    const io = testing.io;

    const promote_json = try std.fmt.allocPrint(a, "{{\"command\":\"promote\",\"id\":\"MEM-00000000-001\",\"priority\":\"invalid\"}}", .{});
    defer a.free(promote_json);
    var parsed = try std.json.parseFromSlice(std.json.Value, a, promote_json, .{});
    defer parsed.deinit();

    const output = cmdPromote(a, io, parsed.value.object);
    defer a.free(output);

    try testing.expect(std.mem.startsWith(u8, output, "Error:"));
    try testing.expect(std.mem.indexOf(u8, output, "invalid priority") != null);
}

test "archive: stat with entries" {
    const testing = std.testing;
    const a = testing.allocator;
    const io = testing.io;

    root_dir.init("zig_test_memory_root");
    defer {
        root_dir.init("");
        cleanupTestDir(io);
    }

    // Add two entries via crud
    const crud_mod = @import("crud.zig");
    {
        const j = try std.fmt.allocPrint(a, "{{\"command\":\"add\",\"content\":\"first entry with high priority test\",\"source\":\"test\",\"pattern-key\":\"first\"}}", .{});
        defer a.free(j);
        var p = try std.json.parseFromSlice(std.json.Value, a, j, .{});
        defer p.deinit();
        const output = crud_mod.cmdAdd(a, io, p.value.object);
        defer a.free(output);
        try testing.expect(std.mem.startsWith(u8, output, "{"));
    }
    {
        const j = try std.fmt.allocPrint(a, "{{\"command\":\"add\",\"content\":\"second entry test\",\"source\":\"user\"}}", .{});
        defer a.free(j);
        var p = try std.json.parseFromSlice(std.json.Value, a, j, .{});
        defer p.deinit();
        const output = crud_mod.cmdAdd(a, io, p.value.object);
        defer a.free(output);
        try testing.expect(std.mem.startsWith(u8, output, "{"));
    }

    // Stat
    var parsed = try std.json.parseFromSlice(std.json.Value, a, "{}", .{});
    defer parsed.deinit();

    const output = cmdStat(a, io, parsed.value.object);
    defer a.free(output);

    try testing.expect(std.mem.startsWith(u8, output, "{"));
    try testing.expect(std.mem.indexOf(u8, output, "\"total\":2") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\"byPriority\"") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\"byScope\"") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\"byStatus\"") != null);
}

test "archive: missing id for promote returns error" {
    const testing = std.testing;
    const a = testing.allocator;
    const io = testing.io;

    var parsed = try std.json.parseFromSlice(std.json.Value, a, "{\"command\":\"promote\"}", .{});
    defer parsed.deinit();

    const output = cmdPromote(a, io, parsed.value.object);
    defer a.free(output);
    try testing.expect(std.mem.startsWith(u8, output, "Error:"));
    try testing.expect(std.mem.indexOf(u8, output, "id") != null);
}
