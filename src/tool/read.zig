const std = @import("std");
const jh = @import("json.zig");
const trunc = @import("truncate.zig");
const root_dir = @import("root_dir.zig");
const ToolResult = @import("registry.zig").ToolResult;

pub const tool_name = "read_file";
pub const tool_description = "Read a file or list a directory from the filesystem. For text files, returns content with optional offset/limit. For directories, lists entries with pagination. For images (png/jpg/gif/webp/bmp), automatically encodes as base64 data URI for vision-capable models.";
pub const tool_params = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\",\"description\":\"Path to the file or directory\"},\"offset\":{\"type\":\"number\",\"description\":\"Starting line (1-indexed), optional\"},\"limit\":{\"type\":\"number\",\"description\":\"Max lines/entries to return, optional\"}},\"required\":[\"path\"]}";

const MAX_BYTES: usize = 50 * 1024;
const MAX_READ: usize = 100 * 1024;
const MAX_LINE_LEN: usize = 2000;
const BINARY_CHECK_SIZE: usize = 4096;
const MAX_IMAGE_BYTES: usize = 20 * 1024 * 1024;
const MAX_DIR_FILES: usize = 100;
const READ_CHUNK: usize = 8 * 1024;

pub fn execute(allocator: std.mem.Allocator, io: std.Io, args: std.json.Value) ToolResult {
    const args_obj = args.object;
    const path = args_obj.get("path") orelse return ToolResult.fail("Error: missing 'path' argument");

    const resolved = root_dir.resolvePath(allocator, path.string) catch return ToolResult.fail("Error: OOM");
    defer if (resolved.ptr != path.string.ptr) allocator.free(resolved);

    // Try directory first
    if (openDir(io, resolved)) |dir| {
        defer dir.close(io);
        return listDir(allocator, io, dir, path.string, args_obj, args);
    } else |_| {}

    // Try file
    var file = std.Io.Dir.cwd().openFile(io, resolved, .{ .mode = .read_only }) catch |err| {
        return ToolResult.fail(jsonErrorStr(allocator, "cannot open '{s}': {}", .{ path.string, err }));
    };
    defer file.close(io);

    const stat = file.stat(io) catch |err| {
        return ToolResult.fail(jsonErrorStr(allocator, "cannot stat '{s}': {}", .{ path.string, err }));
    };
    const file_size: usize = @intCast(stat.size);

    // Empty file
    if (file_size == 0) {
        return okJson(allocator, path.string, "", .{}, .{ .empty = true });
    }

    // Image
    if (isImage(path.string)) {
        if (file_size > MAX_IMAGE_BYTES) {
            return ToolResult.fail(jsonErrorStr(allocator, "image too large ({d} bytes, max {d})", .{ file_size, MAX_IMAGE_BYTES }));
        }
        const raw = allocator.alloc(u8, file_size) catch return ToolResult.fail("Error: OOM");
        defer allocator.free(raw);
        _ = file.readPositionalAll(io, raw, 0) catch |err| {
            return ToolResult.fail(jsonErrorStr(allocator, "cannot read '{s}': {}", .{ path.string, err }));
        };
        return processImage(allocator, path.string, raw, file_size);
    }

    // Binary check (read header)
    const check_len = @min(BINARY_CHECK_SIZE, file_size);
    const header = allocator.alloc(u8, check_len) catch return ToolResult.fail("Error: OOM");
    defer allocator.free(header);
    _ = file.readPositionalAll(io, header, 0) catch return ToolResult.fail("Error: cannot read file");
    if (isBinary(path.string, header)) {
        return ToolResult.fail(jsonErrorStr(allocator, "cannot read binary file '{s}'", .{path.string}));
    }

    const offset = parseArg(usize, args_obj, "offset", 0);
    const limit = parseArg(usize, args_obj, "limit", 0);

    if (offset == 0 and limit == 0) {
        // Read header only
        const read_len = @min(MAX_READ, file_size);
        const raw = allocator.alloc(u8, read_len) catch return ToolResult.fail("Error: OOM");
        defer allocator.free(raw);
        _ = file.readPositionalAll(io, raw, 0) catch return ToolResult.fail("Error: cannot read file");

        if (!std.unicode.utf8ValidateSlice(raw)) {
            return ToolResult.fail(jsonErrorStr(allocator, "file is not valid UTF-8 at '{s}'", .{path.string}));
        }

        const r = trunc.truncateUtf8(raw, MAX_BYTES);
        const content = r.text;
        const truncated = r.truncated;

        const note = if (truncated) generateNote(allocator, 0, 0, raw.len) else null;
        defer if (note) |n| allocator.free(n);
        return okJson(allocator, path.string, content, .{}, .{ .truncated = truncated, .note = note });
    }

    // Line range read: read in chunks up to MAX_READ
    return readLinesRange(allocator, io, file, path.string, offset, limit, file_size);
}

// ---------------------------------------------------------------------------
// Directory listing
// ---------------------------------------------------------------------------

fn openDir(io: std.Io, path: []const u8) !std.Io.Dir {
    return std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
}

fn listDir(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path_str: []const u8, _: std.json.ObjectMap, full_args: std.json.Value) ToolResult {
    const args_obj = full_args.object;
    const offset = parseArg(usize, args_obj, "offset", 0);
    const limit = parseArg(usize, args_obj, "limit", 0);

    var entries = std.array_list.Managed(DirEntry).init(allocator);
    defer entries.deinit();

    var iter = dir.iterate();
    while (iter.next(io) catch null) |entry| {
        if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) continue;
        if (entries.items.len >= MAX_DIR_FILES) break;

        const etype: EntryType = switch (entry.kind) {
            .directory => .directory,
            .sym_link => blk: {
                const target_dir = dir.openDir(io, entry.name, .{}) catch {
                    break :blk .unknown;
                };
                target_dir.close(io);
                break :blk .directory;
            },
            else => .file,
        };
        const name_dup = allocator.dupe(u8, entry.name) catch continue;
        entries.append(.{ .name = name_dup, .type = etype }) catch continue;
    }

    // Sort: directories first, then files, alphabetical within each group
    std.sort.insertion(DirEntry, entries.items, {}, lessThanDirEntry);

    // Apply offset/limit
    const start = if (offset > 0) @min(offset - 1, entries.items.len) else 0;
    const end = if (limit > 0) @min(start + limit, entries.items.len) else entries.items.len;
    const slice = if (start < end) entries.items[start..end] else entries.items[0..0];

    var buf = std.array_list.Managed(u8).init(allocator);
    defer buf.deinit();
    jh.putc(&buf, '{') catch return ToolResult.fail("Error: OOM");
    jh.putString(&buf, "path", path_str) catch return ToolResult.fail("Error: OOM");
    jh.putc(&buf, ',') catch return ToolResult.fail("Error: OOM");
    jh.putString(&buf, "type", "directory") catch return ToolResult.fail("Error: OOM");
    jh.putc(&buf, ',') catch return ToolResult.fail("Error: OOM");
    buf.appendSlice("\"entries\":[") catch return ToolResult.fail("Error: OOM");
    for (slice, 0..) |e, i| {
        if (i > 0) buf.appendSlice(",") catch {
            for (slice) |remaining| allocator.free(remaining.name);
            return ToolResult.fail("Error: OOM");
        };
        buf.appendSlice("{\"name\":\"") catch {
            for (slice) |remaining| allocator.free(remaining.name);
            return ToolResult.fail("Error: OOM");
        };
        escapeJson(&buf, e.name) catch {
            for (slice) |remaining| allocator.free(remaining.name);
            return ToolResult.fail("Error: OOM");
        };
        buf.appendSlice("\",\"type\":\"") catch {
            for (slice) |remaining| allocator.free(remaining.name);
            return ToolResult.fail("Error: OOM");
        };
        buf.appendSlice(@tagName(e.type)) catch {
            for (slice) |remaining| allocator.free(remaining.name);
            return ToolResult.fail("Error: OOM");
        };
        buf.appendSlice("\"}") catch {
            for (slice) |remaining| allocator.free(remaining.name);
            return ToolResult.fail("Error: OOM");
        };
        allocator.free(e.name);
    }
    buf.appendSlice("]") catch return ToolResult.fail("Error: OOM");
    jh.putc(&buf, ',') catch return ToolResult.fail("Error: OOM");
    jh.putInt(&buf, "offset", offset) catch return ToolResult.fail("Error: OOM");
    jh.putc(&buf, ',') catch return ToolResult.fail("Error: OOM");
    jh.putInt(&buf, "limit", limit) catch return ToolResult.fail("Error: OOM");
    jh.putc(&buf, '}') catch return ToolResult.fail("Error: OOM");

    return ToolResult.ok(jh.finish(&buf));
}

fn lessThanDirEntry(_: void, a: DirEntry, b: DirEntry) bool {
    if (a.type != b.type) return a.type == .directory;
    return std.mem.lessThan(u8, a.name, b.name);
}

const EntryType = enum { file, directory, unknown };

const DirEntry = struct {
    name: []const u8,
    type: EntryType,
};

// ---------------------------------------------------------------------------
// Line range reader
// ---------------------------------------------------------------------------

fn readLinesRange(allocator: std.mem.Allocator, io: std.Io, file: std.Io.File, path_str: []const u8, offset: usize, limit: usize, file_size: usize) ToolResult {
    _ = file_size;
    var buf = std.array_list.Managed(u8).init(allocator);
    defer buf.deinit();

    var result = std.array_list.Managed(u8).init(allocator);
    defer result.deinit();

    var chunk: [READ_CHUNK]u8 = undefined;
    var total_read: usize = 0;
    var line_count: usize = 0;
    var included: usize = 0;
    var eof = false;

    while (!eof) {
        const nread = file.readStreaming(io, &.{&chunk}) catch |err| {
            return ToolResult.fail(jsonErrorStr(allocator, "cannot read '{s}': {}", .{ path_str, err }));
        };
        if (nread == 0) { eof = true; break; }
        total_read += nread;

        if (total_read > MAX_READ) {
            // Cap reached, flush remaining buffer
            var bi: usize = 0;
            while (bi < buf.items.len) : (bi += 1) {
                if (buf.items[bi] == '\n') line_count += 1;
            }
            buf.items.len = 0;
            break;
        }

        for (chunk[0..nread]) |c| {
            buf.append(c) catch return ToolResult.fail("Error: OOM");
            if (c == '\n') {
                line_count += 1;
                // Check if this line is in our target range
                // line_count is the number of lines seen so far (including current)
                // We want lines where: line_count >= offset (1-indexed)
                if (offset == 0 or line_count >= offset) {
                    if (limit == 0 or included < limit) {
                        // Emit the line (minus the trailing newline, which will be added back)
                        const line = buf.items[0 .. buf.items.len - 1]; // strip '\n'
                        // Apply line length truncation
                        if (line.len > MAX_LINE_LEN) {
                            const truncated_line = std.fmt.allocPrint(allocator, "{s}... [truncated {d} chars]", .{ line[0..MAX_LINE_LEN], line.len - MAX_LINE_LEN }) catch return ToolResult.fail("Error: OOM");
                            defer allocator.free(truncated_line);
                            result.appendSlice(truncated_line) catch return ToolResult.fail("Error: OOM");
                        } else {
                            result.appendSlice(line) catch return ToolResult.fail("Error: OOM");
                        }
                        result.append('\n') catch return ToolResult.fail("Error: OOM");
                        included += 1;
                    }
                }
                buf.items.len = 0;
                if (limit > 0 and included >= limit) break;
            }
        }
        if (limit > 0 and included >= limit) break;
    }

    // Flush trailing line (file without trailing \n)
    if (buf.items.len > 0) {
        line_count += 1;
        if (offset == 0 or line_count >= offset) {
            if (limit == 0 or included < limit) {
                const line = buf.items[0..];
                if (line.len > MAX_LINE_LEN) {
                    const tl = std.fmt.allocPrint(allocator, "{s}... [truncated {d} chars]", .{ line[0..MAX_LINE_LEN], line.len - MAX_LINE_LEN }) catch return ToolResult.fail("Error: OOM");
                    defer allocator.free(tl);
                    result.appendSlice(tl) catch return ToolResult.fail("Error: OOM");
                } else {
                    result.appendSlice(line) catch return ToolResult.fail("Error: OOM");
                }
                result.append('\n') catch return ToolResult.fail("Error: OOM");
                included += 1;
            }
        }
        buf.items.len = 0;
    }

    // Check if offset is valid
    if (offset > 0 and offset > line_count) {
        return ToolResult.fail(jsonErrorStr(allocator, "offset {d} is out of range (file has {d} lines)", .{ offset, line_count }));
    }

    const truncated = limit > 0 and included >= limit;
    const content = result.toOwnedSlice() catch return ToolResult.fail("Error: OOM");
    errdefer allocator.free(content);

    if (!std.unicode.utf8ValidateSlice(content)) {
        allocator.free(content);
        return ToolResult.fail(jsonErrorStr(allocator, "file is not valid UTF-8 at '{s}'", .{path_str}));
    }

    const note = if (truncated) generateNote(allocator, offset, limit, included) else null;
    defer if (note) |n| allocator.free(n);
    return okJson(allocator, path_str, content, .{ .needs_free = true }, .{ .truncated = truncated, .offset = offset, .limit = limit, .note = note });
}

// ---------------------------------------------------------------------------
// Binary detection
// ---------------------------------------------------------------------------

const binary_exts = [_][]const u8{ ".exe", ".dll", ".so", ".dylib", ".zip", ".tar", ".gz", ".7z", ".rar", ".bin", ".dat", ".wasm", ".pyc", ".pyo", ".class", ".jar", ".war", ".o", ".a", ".lib", ".obj", ".doc", ".docx", ".xls", ".xlsx", ".ppt", ".pptx", ".pdf" };

fn isBinary(path: []const u8, header: []const u8) bool {
    // Extension check
    inline for (binary_exts) |ext| {
        if (endsWithIgnoreCase(path, ext)) return true;
    }
    // Content heuristic
    var non_printable: usize = 0;
    for (header) |b| {
        if (b == 0) return true; // null byte = binary
        if (b < 0x20 and b != '\t' and b != '\n' and b != '\r') non_printable += 1;
    }
    return non_printable > header.len * 30 / 100;
}

// ---------------------------------------------------------------------------
// Image handling
// ---------------------------------------------------------------------------

fn isImage(path: []const u8) bool {
    return endsWithIgnoreCase(path, ".png") or endsWithIgnoreCase(path, ".jpg") or
        endsWithIgnoreCase(path, ".jpeg") or endsWithIgnoreCase(path, ".gif") or
        endsWithIgnoreCase(path, ".webp") or endsWithIgnoreCase(path, ".bmp");
}

fn processImage(allocator: std.mem.Allocator, path_str: []const u8, data: []const u8, size: usize) ToolResult {
    const mime = if (endsWithIgnoreCase(path_str, ".png")) "image/png"
        else if (endsWithIgnoreCase(path_str, ".jpg") or endsWithIgnoreCase(path_str, ".jpeg")) "image/jpeg"
        else if (endsWithIgnoreCase(path_str, ".gif")) "image/gif"
        else if (endsWithIgnoreCase(path_str, ".webp")) "image/webp"
        else if (endsWithIgnoreCase(path_str, ".bmp")) "image/bmp"
        else "image/png";
    const b64_len = std.base64.standard.Encoder.calcSize(size);
    const b64_buf = allocator.alloc(u8, b64_len) catch return ToolResult.fail("Error: OOM");
    defer allocator.free(b64_buf);
    const encoded = std.base64.standard.Encoder.encode(b64_buf, data);
    const uri = std.fmt.allocPrint(allocator, "data:{s};base64,{s}", .{ mime, encoded }) catch return ToolResult.fail("Error: OOM");
    defer allocator.free(uri);

    var buf = std.array_list.Managed(u8).init(allocator);
    defer buf.deinit();
    jh.putc(&buf, '{') catch return ToolResult.fail("Error: OOM");
    jh.putString(&buf, "path", path_str) catch return ToolResult.fail("Error: OOM");
    jh.putc(&buf, ',') catch return ToolResult.fail("Error: OOM");
    jh.putString(&buf, "type", "file") catch return ToolResult.fail("Error: OOM");
    jh.putc(&buf, ',') catch return ToolResult.fail("Error: OOM");
    jh.putString(&buf, "image", uri) catch return ToolResult.fail("Error: OOM");
    jh.putc(&buf, '}') catch return ToolResult.fail("Error: OOM");
    return ToolResult.ok(jh.finish(&buf));
}

// ---------------------------------------------------------------------------
// JSON builder
// ---------------------------------------------------------------------------

const JsonMeta = struct {
    truncated: bool = false,
    offset: usize = 0,
    limit: usize = 0,
    note: ?[]const u8 = null,
    empty: bool = false,
    needs_free: bool = false,
};

fn okJson(allocator: std.mem.Allocator, path_str: []const u8, content: []const u8, content_meta: struct { needs_free: bool = false }, meta: JsonMeta) ToolResult {
    var buf = std.array_list.Managed(u8).init(allocator);
    defer buf.deinit();
    jh.putc(&buf, '{') catch return ToolResult.fail("Error: OOM");
    jh.putString(&buf, "path", path_str) catch return ToolResult.fail("Error: OOM");
    jh.putc(&buf, ',') catch return ToolResult.fail("Error: OOM");
    jh.putString(&buf, "type", "file") catch return ToolResult.fail("Error: OOM");
    jh.putc(&buf, ',') catch return ToolResult.fail("Error: OOM");
    jh.putString(&buf, "content", content) catch return ToolResult.fail("Error: OOM");
    jh.putc(&buf, ',') catch return ToolResult.fail("Error: OOM");
    jh.putInt(&buf, "offset", meta.offset) catch return ToolResult.fail("Error: OOM");
    jh.putc(&buf, ',') catch return ToolResult.fail("Error: OOM");
    jh.putInt(&buf, "limit", meta.limit) catch return ToolResult.fail("Error: OOM");
    jh.putc(&buf, ',') catch return ToolResult.fail("Error: OOM");
    jh.putBool(&buf, "truncated", meta.truncated) catch return ToolResult.fail("Error: OOM");
    if (meta.note) |n| {
        jh.putc(&buf, ',') catch return ToolResult.fail("Error: OOM");
        jh.putString(&buf, "note", n) catch return ToolResult.fail("Error: OOM");
    }
    jh.putc(&buf, '}') catch return ToolResult.fail("Error: OOM");

    if (content_meta.needs_free) allocator.free(content);
    return ToolResult.ok(jh.finish(&buf));
}

fn generateNote(allocator: std.mem.Allocator, offset: usize, limit: usize, included: usize) ?[]const u8 {
    const result = if (offset == 0 and limit == 0)
        std.fmt.allocPrint(allocator, "Output truncated at {d} bytes. Use read_file with offset={d} limit=2000 to continue.", .{ MAX_BYTES, MAX_BYTES })
    else if (offset == 0)
        std.fmt.allocPrint(allocator, "Output truncated at line {d}. Use read_file with offset={d} limit=2000 to continue.", .{ included, included + 1 })
    else
        std.fmt.allocPrint(allocator, "Showing lines {d}-{d}. Use read_file with offset={d} limit=2000 to continue.", .{ offset, offset + included - 1, offset + included });
    return result catch null;
}

// ---------------------------------------------------------------------------
// renderResult (user display)
// ---------------------------------------------------------------------------

pub fn renderResult(allocator: std.mem.Allocator, stdout: *std.Io.Writer, json_str: []const u8) !void {
    if (!std.mem.startsWith(u8, json_str, "{")) return stdout.print("  {s}\n", .{json_str});

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, json_str, .{}) catch return;
    defer parsed.deinit();
    const obj = parsed.value.object;

    const path_str = if (obj.get("path")) |v| if (v == .string) v.string else "" else "";

    // Error
    if (obj.get("type")) |t| {
        if (t == .string and std.mem.eql(u8, t.string, "directory")) {
            const entries = if (obj.get("entries")) |v| if (v == .array) v.array.items.len else 0 else 0;
            const off = if (obj.get("offset")) |v| if (v.integer > 0) @as(u64, @intCast(v.integer)) else 0 else 0;
            if (off > 0) {
                return stdout.print("  \u{2713} {s}/  ({d} entries, offset {d})\n", .{ path_str, entries, off });
            }
            return stdout.print("  \u{2713} {s}/  ({d} entries)\n", .{ path_str, entries });
        }
    }

    // Image
    if (obj.get("image")) |_| {
        return stdout.print("  \u{2713} {s}  (image)\n", .{path_str});
    }

    // Empty file
    const content = if (obj.get("content")) |v| if (v == .string) v.string else "" else "";
    if (content.len == 0) {
        return stdout.print("  \u{2713} {s}  (0 bytes)\n", .{path_str});
    }

    // Text file
    const off = if (obj.get("offset")) |v| if (v.integer > 0) @as(u64, @intCast(v.integer)) else 0 else 0;
    const truncated = if (obj.get("truncated")) |v| v == .bool and v.bool else false;
    const file_size = content.len;

    const size_str = try formatSize(allocator, file_size);
    defer allocator.free(size_str);

    if (off > 0 and truncated) {
        const lim = if (obj.get("limit")) |v| @as(u64, @intCast(v.integer)) else 0;
        if (lim > 0) {
            return stdout.print("  \u{2713} {s}  lines {d}-{d}  ({s}) truncated.\n", .{ path_str, off, off + lim - 1, size_str });
        }
        return stdout.print("  \u{2713} {s}  line {d}+  ({s}) truncated.\n", .{ path_str, off, size_str });
    }
    if (off > 0) {
        const lim = if (obj.get("limit")) |v| @as(u64, @intCast(v.integer)) else 0;
        if (lim > 0) {
            return stdout.print("  \u{2713} {s}  lines {d}-{d}  ({s})\n", .{ path_str, off, off + lim - 1, size_str });
        }
        return stdout.print("  \u{2713} {s}  line {d}+  ({s})\n", .{ path_str, off, size_str });
    }
    if (truncated) {
        return stdout.print("  \u{2713} {s}  ({s}) truncated.\n", .{ path_str, size_str });
    }
    return stdout.print("  \u{2713} {s}  ({s})\n", .{ path_str, size_str });
}

fn formatSize(allocator: std.mem.Allocator, bytes: usize) ![]const u8 {
    if (bytes < 1024) return std.fmt.allocPrint(allocator, "{d} B", .{bytes});
    if (bytes < 1024 * 1024) return std.fmt.allocPrint(allocator, "{d:.1} KB", .{@as(f64, @floatFromInt(bytes)) / 1024});
    return std.fmt.allocPrint(allocator, "{d:.1} MB", .{@as(f64, @floatFromInt(bytes)) / (1024 * 1024)});
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn parseArg(comptime T: type, obj: std.json.ObjectMap, key: []const u8, default: T) T {
    if (obj.get(key)) |v| {
        if (v != .null and v.integer >= 0) return @as(T, @intCast(v.integer));
    }
    return default;
}

fn escapeJson(buf: *std.array_list.Managed(u8), s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice("\\\""),
            '\\' => try buf.appendSlice("\\\\"),
            '\n' => try buf.appendSlice("\\n"),
            '\r' => try buf.appendSlice("\\r"),
            '\t' => try buf.appendSlice("\\t"),
            0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f => {
                var hex: [6]u8 = undefined;
                const h = try std.fmt.bufPrint(&hex, "\\u00{x:0>2}", .{@as(u8, c)});
                try buf.appendSlice(h);
            },
            else => try buf.append(c),
        }
    }
}

fn jsonErrorStr(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(allocator, "Error: " ++ fmt, args) catch "Error: OOM";
}

fn endsWithIgnoreCase(s: []const u8, suffix: []const u8) bool {
    if (suffix.len > s.len) return false;
    const end = s[s.len - suffix.len ..];
    return std.ascii.eqlIgnoreCase(end, suffix);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "read_file returns error for nonexistent file" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const io = testing.io;

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, "{\"path\": \"/nonexistent_file_xyz\"}", .{}) catch return;
    defer parsed.deinit();
    const tr = execute(allocator, io, parsed.value);
    defer allocator.free(tr.output);

    try testing.expect(!tr.success);
    try testing.expect(std.mem.startsWith(u8, tr.output, "Error:"));
}

test "read_file binary detection rejects known extension" {
    const testing = std.testing;
    try testing.expect(isBinary("foo.exe", ""));
    try testing.expect(isBinary("lib.dll", ""));
    try testing.expect(isBinary("archive.zip", ""));
    try testing.expect(isBinary("data.dat", ""));
}

test "read_file binary detection rejects null byte content" {
    const testing = std.testing;
    const header = [_]u8{ 0x48, 0x65, 0x6c, 0x6c, 0x6f, 0x00, 0x57, 0x6f, 0x72, 0x6c, 0x64 };
    try testing.expect(isBinary("test.txt", &header));
}

test "read_file binary detection passes text content" {
    const testing = std.testing;
    const header = "Hello, World!\nThis is a normal text file.\n";
    try testing.expect(!isBinary("test.txt", header));
}

test "read_file isImage detects image extensions" {
    const testing = std.testing;
    try testing.expect(isImage("photo.png"));
    try testing.expect(isImage("photo.jpg"));
    try testing.expect(isImage("photo.jpeg"));
    try testing.expect(isImage("photo.gif"));
    try testing.expect(isImage("photo.webp"));
    try testing.expect(isImage("photo.bmp"));
}

test "read_file isImage rejects non-image" {
    const testing = std.testing;
    try testing.expect(!isImage("main.zig"));
    try testing.expect(!isImage("readme.md"));
}

test "read_file formatSize shows human-readable sizes" {
    const testing = std.testing;
    const a = testing.allocator;
    const s1 = try formatSize(a, 0);
    defer a.free(s1);
    try testing.expect(std.mem.indexOf(u8, s1, "0 B") != null);

    const s2 = try formatSize(a, 1536);
    defer a.free(s2);
    try testing.expect(std.mem.indexOf(u8, s2, "1.5") != null or std.mem.indexOf(u8, s2, "1.4") != null);
}

test "read_file escapeJson escapes special chars" {
    const testing = std.testing;
    var buf = std.array_list.Managed(u8).init(testing.allocator);
    defer buf.deinit();
    try escapeJson(&buf, "hello\nworld\"test\\");
    try testing.expect(std.mem.indexOf(u8, buf.items, "\\n") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "\\\"") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "\\\\") != null);
}

test "read_file generateNote context-dependent" {
    const testing = std.testing;
    const a = testing.allocator;

    const n1 = generateNote(a, 0, 0, 100).?;
    defer a.free(n1);
    try testing.expect(std.mem.indexOf(u8, n1, "offset=51200") != null);

    const n2 = generateNote(a, 0, 50, 50).?;
    defer a.free(n2);
    try testing.expect(std.mem.indexOf(u8, n2, "offset=51") != null);

    const n3 = generateNote(a, 100, 50, 50).?;
    defer a.free(n3);
    try testing.expect(std.mem.indexOf(u8, n3, "offset=150") != null);
}
