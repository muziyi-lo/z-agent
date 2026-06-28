const std = @import("std");
const Io = std.Io;
const session_mod = @import("../session.zig");
const serde = @import("serialize.zig");

const SessionInfo = session_mod.SessionInfo;
const SessionHeader = session_mod.SessionHeader;
const SessionManager = session_mod.SessionManager;

pub fn freeSessionItems(allocator: std.mem.Allocator, infos: []SessionInfo) void {
    for (infos) |s| {
        allocator.free(s.id);
        allocator.free(s.timestamp);
        allocator.free(s.cwd);
        allocator.free(s.file_path);
        allocator.free(s.model);
        allocator.free(s.provider);
    }
}

pub fn freeSessionInfo(allocator: std.mem.Allocator, infos: []SessionInfo) void {
    freeSessionItems(allocator, infos);
    allocator.free(infos);
}

fn deinitSessionInfoList(allocator: std.mem.Allocator, list: *std.array_list.Managed(SessionInfo)) void {
    freeSessionItems(allocator, list.items);
    list.deinit();
}

pub fn listSessions(allocator: std.mem.Allocator, io: Io, session_dir: []const u8) ![]SessionInfo {
    const dir_handle = Io.Dir.cwd().openDir(io, session_dir, .{ .iterate = true }) catch return try allocator.alloc(SessionInfo, 0);
    defer dir_handle.close(io);

    var list = std.array_list.Managed(SessionInfo).init(allocator);
    errdefer deinitSessionInfoList(allocator, &list);

    var iter = dir_handle.iterate();
    while (true) {
        const entry = iter.next(io) catch break orelse break;
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".jsonl")) continue;

        const full_path = try std.fs.path.join(allocator, &.{ session_dir, entry.name });
        defer allocator.free(full_path);

        const content = serde.readFile(allocator, full_path, io) catch continue;
        defer allocator.free(content);

        const header = serde.readSessionHeaderFromContent(allocator, content) catch continue;
        defer {
            allocator.free(header.id);
            allocator.free(header.cwd);
            if (header.model) |m| allocator.free(m);
            if (header.provider) |p| allocator.free(p);
        }

        var msg_count: usize = 0;
        var msg_lines = std.mem.splitScalar(u8, content, '\n');
        while (msg_lines.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, "\r");
            if (line.len == 0) continue;
            if (std.mem.indexOf(u8, line, "\"type\":\"message\"") != null) msg_count += 1;
        }

        try list.append(.{
            .index = 0,
            .id = try allocator.dupe(u8, header.id),
            .timestamp_ns = header.timestamp_ns,
            .timestamp = try serde.formatTimestamp(allocator, header.timestamp_ns),
            .cwd = try allocator.dupe(u8, header.cwd),
            .msg_count = msg_count,
            .file_path = try allocator.dupe(u8, full_path),
            .model = try allocator.dupe(u8, header.model orelse ""),
            .provider = try allocator.dupe(u8, header.provider orelse ""),
        });
    }

    std.mem.sort(SessionInfo, list.items, {}, struct {
        fn lessThan(_: void, a: SessionInfo, b: SessionInfo) bool {
            return a.timestamp_ns > b.timestamp_ns;
        }
    }.lessThan);

    for (list.items, 0..) |*info, i| info.index = i + 1;
    return list.toOwnedSlice();
}

pub fn findMostRecentFile(allocator: std.mem.Allocator, dir_path: []const u8, io: Io) !?[]const u8 {
    const dir_handle = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return null;
    defer dir_handle.close(io);

    var result: ?[]const u8 = null;
    var latest_mtime: i96 = 0;

    var iter = dir_handle.iterate();
    while (true) {
        const entry = iter.next(io) catch break orelse break;
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".jsonl")) continue;

        const full = std.fs.path.join(allocator, &.{ dir_path, entry.name }) catch continue;
        defer allocator.free(full);

        const file = Io.Dir.cwd().openFile(io, full, .{ .mode = .read_only }) catch continue;
        defer file.close(io);

        const stat = file.stat(io) catch continue;
        const mtime = stat.mtime.nanoseconds;
        if (result == null or mtime > latest_mtime) {
            latest_mtime = mtime;
            if (result) |old| allocator.free(old);
            result = try allocator.dupe(u8, full);
        }
    }

    return result;
}

pub fn continueByIndex(allocator: std.mem.Allocator, io: Io, session_dir: []const u8, index: usize) !SessionManager {
    const sessions = try listSessions(allocator, io, session_dir);
    if (index >= sessions.len) {
        freeSessionInfo(allocator, sessions);
        return error.SessionNotFound;
    }
    const target_path = try allocator.dupe(u8, sessions[index].file_path);
    freeSessionInfo(allocator, sessions);
    defer allocator.free(target_path);
    return serde.loadFromFile(allocator, io, target_path, session_dir);
}

pub fn continueById(allocator: std.mem.Allocator, io: Io, session_dir: []const u8, id_prefix: []const u8) !SessionManager {
    const dir_handle = Io.Dir.cwd().openDir(io, session_dir, .{ .iterate = true }) catch return error.SessionNotFound;
    defer dir_handle.close(io);

    var best_match: ?[]const u8 = null;

    var iter = dir_handle.iterate();
    while (true) {
        const entry = iter.next(io) catch break orelse break;
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".jsonl")) continue;

        const full_path = try std.fs.path.join(allocator, &.{ session_dir, entry.name });
        defer allocator.free(full_path);

        const content = try serde.readFile(allocator, full_path, io);
        defer allocator.free(content);

        const header = try serde.readSessionHeaderFromContent(allocator, content);
        defer {
            allocator.free(header.id);
            allocator.free(header.cwd);
            if (header.model) |m| allocator.free(m);
            if (header.provider) |p| allocator.free(p);
        }

        if (std.mem.startsWith(u8, header.id, id_prefix)) {
            if (best_match != null) {
                return error.AmbiguousSessionId;
            }
            best_match = try allocator.dupe(u8, full_path);
        }
    }

    if (best_match) |path| {
        defer allocator.free(path);
        return serde.loadFromFile(allocator, io, path, session_dir);
    }
    return error.SessionNotFound;
}
