const std = @import("std");
const json = @import("../json.zig");
const root_dir = @import("../root_dir.zig");
const ToolResult = @import("../registry.zig").ToolResult;
const retrieval = @import("../../retrieval.zig");
const types = @import("types.zig");
const parse = @import("parse.zig");

const Entry = types.Entry;

// ---------------------------------------------------------------------------
// Anchor checks
// ---------------------------------------------------------------------------

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

    return "Error: 缺少可验证锚点，需要至少满足一项：source 非空且非'自动'、pattern-key 有值、含事件关键词、含路径模式";
}

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

/// Add a new memory entry. Returns JSON with id/title on success.
pub fn cmdAdd(allocator: std.mem.Allocator, io: std.Io, args: std.json.ObjectMap) []const u8 {
    const content_val = args.get("content") orelse return allocError(allocator, "missing 'content' for add");
    const content = if (content_val == .string) content_val.string else return allocError(allocator, "'content' must be a string");

    const source = if (args.get("source")) |v| if (v == .string) v.string else "自动" else "自动";
    const pattern_key = if (args.get("pattern-key")) |v| if (v == .string and v.string.len > 0) v.string else "" else "";
    const title_override = if (args.get("title")) |v| if (v == .string) v.string else "" else "";

    const mem_path = parse.memoryPath(allocator) catch return allocOomError(allocator);
    defer allocator.free(mem_path);

    // Read existing content
    const existing_content = parse.readFile(allocator, io, mem_path);
    defer if (existing_content) |c| allocator.free(c);

    // Gatekeeping: check anchors
    const anchor_err = checkAnchors(content, source, pattern_key);
    if (anchor_err) |err| {
        return std.fmt.allocPrint(allocator, "{s}", .{err}) catch allocOomError(allocator);
    }

    // Dedup: if pattern-key provided, scan existing entries
    if (pattern_key.len > 0) {
        if (existing_content) |content_data| {
            const entries = parse.parseEntries(allocator, content_data) catch return allocOomError(allocator);
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
    const id = parse.generateId(allocator, io, existing_content) catch return allocOomError(allocator);
    defer allocator.free(id);

    // Auto-title
    const title = if (title_override.len > 0) title_override else parse.extractTitle(content);

    // Date string
    const date_formatted = parse.todayFormattedDate(io);

    // Build entry using serializeEntry with defaults for new fields
    const entry = Entry{
        .id = id,
        .title = title,
        .source = source,
        .pattern_key = pattern_key,
        .priority = "medium",
        .scope = "project-specific",
        .status = "new",
        .handled = "pending",
        .recurrence_count = 1,
        .archived = false,
        .related_files = "",
        .logged = &date_formatted,
        .raw = "",
        .preview = "",
    };

    const new_entry = parse.serializeEntry(allocator, entry, content) catch return allocOomError(allocator);
    defer allocator.free(new_entry);

    // Build full content
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

    // Atomic write
    parse.atomicWrite(allocator, io, mem_path, full_content.items) catch {
        return allocError(allocator, "write failed");
    };
    parse.invalidateCache(allocator);

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

/// Search memory entries by query. Returns JSON with results array.
pub fn cmdRecall(allocator: std.mem.Allocator, io: std.Io, args: std.json.ObjectMap) []const u8 {
    const query_val = args.get("query") orelse return allocError(allocator, "missing 'query' for recall");
    const query = if (query_val == .string) query_val.string else return allocError(allocator, "'query' must be a string");

    const mem_path = parse.memoryPath(allocator) catch return allocOomError(allocator);
    defer allocator.free(mem_path);

    const entries = parse.getEntries(allocator, io, mem_path) catch return allocOomError(allocator);

    // Phase 1: pattern-key exact match → score 1.0 shortcut
    for (entries) |entry| {
        if (entry.pattern_key.len > 0 and std.mem.eql(u8, entry.pattern_key, query)) {
            var buf = std.array_list.Managed(u8).init(allocator);
            defer buf.deinit();
            json.puts(&buf, "{\"results\":[{\"id\":") catch return allocOomError(allocator);
            json.escapeJson(&buf, entry.id) catch return allocOomError(allocator);
            json.puts(&buf, ",\"title\":") catch return allocOomError(allocator);
            json.escapeJson(&buf, entry.title) catch return allocOomError(allocator);
            json.puts(&buf, ",\"score\":1.00,\"preview\":") catch return allocOomError(allocator);
            json.escapeJson(&buf, entry.preview) catch return allocOomError(allocator);
            json.puts(&buf, "}]}") catch return allocOomError(allocator);
            return json.finish(&buf);
        }
    }

    // Phase 2: BM25 retrieval
    var docs = std.array_list.Managed(retrieval.Document).init(allocator);
    defer docs.deinit();
    for (entries) |entry| {
        docs.append(.{ .id = entry.id, .content = entry.raw }) catch return allocOomError(allocator);
    }

    const results = retrieval.search(allocator, query, docs.items, 10) catch return allocOomError(allocator);
    defer {
        for (results) |r| allocator.free(r.snippet);
        allocator.free(results);
    }

    // Build JSON
    var buf = std.array_list.Managed(u8).init(allocator);
    defer buf.deinit();
    json.puts(&buf, "{\"results\":[") catch return allocOomError(allocator);

    for (results, 0..) |scored, i| {
        // Find matching entry for title
        var title: []const u8 = "";
        for (entries) |entry| {
            if (std.mem.eql(u8, entry.id, scored.id)) {
                title = entry.title;
                break;
            }
        }
        if (i > 0) json.putc(&buf, ',') catch return allocOomError(allocator);
        json.putc(&buf, '{') catch return allocOomError(allocator);
        json.putString(&buf, "id", scored.id) catch return allocOomError(allocator);
        json.putc(&buf, ',') catch return allocOomError(allocator);
        json.putString(&buf, "title", title) catch return allocOomError(allocator);
        json.putc(&buf, ',') catch return allocOomError(allocator);
        json.putKey(&buf, "score") catch return allocOomError(allocator);
        var score_buf: [32]u8 = undefined;
        const score_str = std.fmt.bufPrint(&score_buf, "{d:.2}", .{scored.score}) catch "0.00";
        json.puts(&buf, score_str) catch return allocOomError(allocator);
        json.putc(&buf, ',') catch return allocOomError(allocator);
        json.putString(&buf, "preview", scored.snippet) catch return allocOomError(allocator);
        json.putc(&buf, '}') catch return allocOomError(allocator);
    }

    json.puts(&buf, "]}") catch return allocOomError(allocator);
    return json.finish(&buf);
}

// ---------------------------------------------------------------------------
// cmdDelete
// ---------------------------------------------------------------------------

/// Delete a memory entry by ID. Returns JSON with deleted:true/false.
pub fn cmdDelete(allocator: std.mem.Allocator, io: std.Io, args: std.json.ObjectMap) []const u8 {
    const id_val = args.get("id") orelse return allocError(allocator, "missing 'id' for delete");
    const id = if (id_val == .string) id_val.string else return allocError(allocator, "'id' must be a string");

    const mem_path = parse.memoryPath(allocator) catch return allocOomError(allocator);
    defer allocator.free(mem_path);

    const content = parse.readFile(allocator, io, mem_path) orelse {
        return std.fmt.allocPrint(allocator, "{{\"deleted\":false,\"error\":\"not found\"}}", .{}) catch allocOomError(allocator);
    };
    defer allocator.free(content);

    const entries = parse.parseEntries(allocator, content) catch return allocOomError(allocator);
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

    // Atomic write
    parse.atomicWrite(allocator, io, mem_path, new_content.items) catch {
        return allocError(allocator, "write failed");
    };
    parse.invalidateCache(allocator);

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
    _ = std.Io.Dir.cwd().deleteTree(io, "zig_test_memory_root/.zagent") catch {};
    _ = std.Io.Dir.cwd().deleteDir(io, "zig_test_memory_root") catch {};
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "crud: indexOfIgnoreCase basic matching and error paths" {
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

test "crud: add creates entry and returns JSON with id and title" {
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

    const output = cmdAdd(a, io, parsed.value.object);
    defer a.free(output);

    try testing.expect(std.mem.startsWith(u8, output, "{"));
    try testing.expect(std.mem.indexOf(u8, output, "\"id\"") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\"MEM-") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\"title\"") != null);
}

test "crud: recall finds matching entry" {
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
        const output = cmdAdd(a, io, parsed.value.object);
        defer a.free(output);
        try testing.expect(std.mem.startsWith(u8, output, "{"));
    }

    // Now recall it
    const recall_json = try std.fmt.allocPrint(a, "{{\"command\":\"recall\",\"query\":\"keyword\"}}", .{});
    defer a.free(recall_json);
    var parsed = try std.json.parseFromSlice(std.json.Value, a, recall_json, .{});
    defer parsed.deinit();

    const output = cmdRecall(a, io, parsed.value.object);
    defer a.free(output);

    try testing.expect(std.mem.startsWith(u8, output, "{"));
    try testing.expect(std.mem.indexOf(u8, output, "\"results\"") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\"preview\"") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\"score\"") != null);
    try testing.expect(std.mem.indexOf(u8, output, "MEM-") != null);
}

test "crud: delete removes entry" {
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
        const output = cmdAdd(a, io, parsed.value.object);
        defer a.free(output);
        try testing.expect(std.mem.startsWith(u8, output, "{"));

        // Extract ID from JSON result
        var parsed_res = try std.json.parseFromSlice(std.json.Value, a, output, .{});
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

    const output = cmdDelete(a, io, parsed.value.object);
    defer a.free(output);

    try testing.expect(std.mem.startsWith(u8, output, "{"));
    try testing.expect(std.mem.indexOf(u8, output, "\"deleted\":true") != null);

    // Verify the ID is no longer in the file
    const mem_path = try parse.memoryPath(a);
    defer a.free(mem_path);
    const file_content = parse.readFile(a, io, mem_path) orelse return;
    defer a.free(file_content);
    try testing.expect(std.mem.indexOf(u8, file_content, mem_id.?) == null);
}

test "crud: missing content for add returns error" {
    const testing = std.testing;
    const a = testing.allocator;
    const io = testing.io;

    var parsed = try std.json.parseFromSlice(std.json.Value, a, "{\"command\":\"add\"}", .{});
    defer parsed.deinit();

    const output = cmdAdd(a, io, parsed.value.object);
    defer a.free(output);
    try testing.expect(std.mem.startsWith(u8, output, "Error:"));
    try testing.expect(std.mem.indexOf(u8, output, "content") != null);
}

test "crud: missing query for recall returns error" {
    const testing = std.testing;
    const a = testing.allocator;
    const io = testing.io;

    var parsed = try std.json.parseFromSlice(std.json.Value, a, "{\"command\":\"recall\"}", .{});
    defer parsed.deinit();

    const output = cmdRecall(a, io, parsed.value.object);
    defer a.free(output);
    try testing.expect(std.mem.startsWith(u8, output, "Error:"));
    try testing.expect(std.mem.indexOf(u8, output, "query") != null);
}

test "crud: gatekeeping rejects missing anchors" {
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

    const output = cmdAdd(a, io, parsed.value.object);
    defer a.free(output);

    try testing.expect(std.mem.startsWith(u8, output, "Error:"));
    try testing.expect(std.mem.indexOf(u8, output, "锚点") != null);
}

test "crud: dedup by pattern-key returns existing id" {
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
    const output1 = cmdAdd(a, io, parsed1.value.object);
    defer a.free(output1);
    try testing.expect(std.mem.startsWith(u8, output1, "{"));

    // Extract first ID
    var parsed_res1 = try std.json.parseFromSlice(std.json.Value, a, output1, .{});
    defer parsed_res1.deinit();
    const first_id = try a.dupe(u8, parsed_res1.value.object.get("id").?.string);
    defer a.free(first_id);

    // Add second entry with same pattern-key → should return existing ID
    const add_json2 = try std.fmt.allocPrint(a, "{{\"command\":\"add\",\"content\":\"第二条内容(应去重)\",\"source\":\"test\",\"pattern-key\":\"unique-key-001\"}}", .{});
    defer a.free(add_json2);
    var parsed2 = try std.json.parseFromSlice(std.json.Value, a, add_json2, .{});
    defer parsed2.deinit();
    const output2 = cmdAdd(a, io, parsed2.value.object);
    defer a.free(output2);

    try testing.expect(std.mem.startsWith(u8, output2, "{"));
    try testing.expect(std.mem.indexOf(u8, output2, "\"dedup\":true") != null);
    try testing.expect(std.mem.indexOf(u8, output2, first_id) != null);
}

test "crud: weighted ranking" {
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
        const output = cmdAdd(a, io, p.value.object);
        defer a.free(output);
        try testing.expect(std.mem.startsWith(u8, output, "{"));
    }
    // Entry B: pattern-key = "workspace-layout"
    {
        const j = try std.fmt.allocPrint(a, "{{\"command\":\"add\",\"content\":\"Workspace layout structure for projects\",\"source\":\"auto\",\"pattern-key\":\"workspace-layout\"}}", .{});
        defer a.free(j);
        var p = try std.json.parseFromSlice(std.json.Value, a, j, .{});
        defer p.deinit();
        const output = cmdAdd(a, io, p.value.object);
        defer a.free(output);
        try testing.expect(std.mem.startsWith(u8, output, "{"));
    }
    // Entry C: some random content about zig
    {
        const j = try std.fmt.allocPrint(a, "{{\"command\":\"add\",\"content\":\"Mention of zig build system\",\"source\":\"user\"}}", .{});
        defer a.free(j);
        var p = try std.json.parseFromSlice(std.json.Value, a, j, .{});
        defer p.deinit();
        const output = cmdAdd(a, io, p.value.object);
        defer a.free(output);
        try testing.expect(std.mem.startsWith(u8, output, "{"));
    }

    // Recall with query matching entry A's pattern-key exactly
    const recall_json = try std.fmt.allocPrint(a, "{{\"command\":\"recall\",\"query\":\"zig-compiler\"}}", .{});
    defer a.free(recall_json);
    var parsed = try std.json.parseFromSlice(std.json.Value, a, recall_json, .{});
    defer parsed.deinit();

    const output = cmdRecall(a, io, parsed.value.object);
    defer a.free(output);

    // Entry A (pattern-key exact match) should be first result with score 1.00
    try testing.expect(std.mem.startsWith(u8, output, "{"));
    try testing.expect(std.mem.indexOf(u8, output, "\"score\":1.00") != null);
}

test "crud: single file append" {
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
        const output = cmdAdd(a, io, p.value.object);
        defer a.free(output);
        try testing.expect(std.mem.startsWith(u8, output, "{"));
    }

    // Add second entry
    {
        const j = try std.fmt.allocPrint(a, "{{\"command\":\"add\",\"content\":\"第二条记忆\",\"source\":\"test\"}}", .{});
        defer a.free(j);
        var p = try std.json.parseFromSlice(std.json.Value, a, j, .{});
        defer p.deinit();
        const output = cmdAdd(a, io, p.value.object);
        defer a.free(output);
        try testing.expect(std.mem.startsWith(u8, output, "{"));
    }

    // Read the file and verify both entries exist
    const mem_path = try parse.memoryPath(a);
    defer a.free(mem_path);
    const file_content = parse.readFile(a, io, mem_path) orelse {
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
