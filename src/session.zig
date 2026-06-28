const std = @import("std");
const types = @import("types.zig");
const Io = std.Io;
const serde = @import("session/serialize.zig");
const list = @import("session/list.zig");

pub const CURRENT_VERSION: u32 = 1;

pub const Entry = union(enum) {
    message: types.Message,
    compaction: struct {
        summary: []const u8,
        first_kept_index: usize,
        tokens_before: u32,
    },
};

pub const SessionHeader = struct {
    id: []const u8,
    timestamp_ns: i96,
    cwd: []const u8,
    version: u32 = CURRENT_VERSION,
    model: ?[]const u8 = null,
    provider: ?[]const u8 = null,
};

pub const SessionInfo = struct {
    index: usize,
    id: []const u8,
    timestamp_ns: i96,
    timestamp: []const u8,
    cwd: []const u8,
    msg_count: usize,
    file_path: []const u8,
    model: []const u8,
    provider: []const u8,
};

pub const freeSessionInfo = list.freeSessionInfo;
pub const listSessions = list.listSessions;
pub const continueByIndex = list.continueByIndex;
pub const continueById = list.continueById;

pub const SessionManager = struct {
    allocator: std.mem.Allocator,
    io: Io,
    session_dir: []const u8,
    session_file: ?[]const u8,
    session_id: []const u8,
    entries: std.array_list.Managed(Entry),
    flushed: bool,
    model: []const u8,
    provider: []const u8,

    pub fn create(allocator: std.mem.Allocator, io: Io, session_dir: []const u8, model: []const u8, provider: []const u8) !SessionManager {
        return SessionManager{
            .allocator = allocator,
            .io = io,
            .session_dir = try allocator.dupe(u8, session_dir),
            .session_file = null,
            .session_id = try allocator.dupe(u8, ""),
            .entries = std.array_list.Managed(Entry).init(allocator),
            .flushed = false,
            .model = try allocator.dupe(u8, model),
            .provider = try allocator.dupe(u8, provider),
        };
    }

    pub fn deinit(self: *SessionManager) void {
        for (self.entries.items) |entry| {
            switch (entry) {
                .message => |msg| {
                    if (msg.content) |parts| {
                        for (parts) |part| {
                            if (part == .tool_result) {
                                if (part.tool_result.name) |n| self.allocator.free(n);
                                self.allocator.free(part.tool_result.id);
                                self.allocator.free(part.tool_result.content);
                            }
                        }
                        self.allocator.free(parts);
                    }
                    if (msg.tool_calls) |tcs| {
                        for (tcs) |tc| {
                            self.allocator.free(tc.id);
                            self.allocator.free(tc.name);
                            self.allocator.free(tc.arguments);
                        }
                        self.allocator.free(tcs);
                    }
                    if (msg.tool_call_id) |id| self.allocator.free(id);
                    if (msg.reasoning) |r| self.allocator.free(r);
                },
                .compaction => |c| {
                    self.allocator.free(c.summary);
                },
            }
        }
        self.entries.deinit();
        self.allocator.free(self.session_dir);
        self.allocator.free(self.model);
        self.allocator.free(self.provider);
        self.allocator.free(self.session_id);
        if (self.session_file) |f| self.allocator.free(f);
    }

    pub fn continueRecent(allocator: std.mem.Allocator, io: Io, session_dir: []const u8, cwd: []const u8, model: []const u8, provider: []const u8) !SessionManager {
        _ = cwd;
        const resolved_dir = try std.fs.path.resolve(allocator, &.{session_dir});
        defer allocator.free(resolved_dir);

        const most_recent = list.findMostRecentFile(allocator, resolved_dir, io) catch null;
        if (most_recent) |path| {
            defer allocator.free(path);
            return serde.loadFromFile(allocator, io, path, session_dir) catch {
                return try create(allocator, io, session_dir, model, provider);
            };
        }

        return try create(allocator, io, session_dir, model, provider);
    }

    pub fn appendMessage(self: *SessionManager, msg: types.Message) !void {
        try self.entries.append(.{ .message = msg });
        if (!self.flushed) return;
        const line = try serde.serializeMessage(self.allocator, msg);
        defer self.allocator.free(line);
        if (self.session_file) |f| {
            const file = try Io.Dir.cwd().openFile(self.io, f, .{ .mode = .read_write });
            defer file.close(self.io);
            const end = (try file.stat(self.io)).size;
            try file.writePositionalAll(self.io, line, end);
        }
    }

    pub fn appendCompaction(self: *SessionManager, summary: []const u8, first_kept_index: usize, tokens_before: u32) !void {
        try self.entries.append(.{ .compaction = .{
            .summary = try self.allocator.dupe(u8, summary),
            .first_kept_index = first_kept_index,
            .tokens_before = tokens_before,
        } });
        if (!self.flushed) return;
        const line = try serde.serializeCompaction(self.allocator, summary, first_kept_index, tokens_before);
        defer self.allocator.free(line);
        if (self.session_file) |f| {
            const file = try Io.Dir.cwd().openFile(self.io, f, .{ .mode = .read_write });
            defer file.close(self.io);
            const end = (try file.stat(self.io)).size;
            try file.writePositionalAll(self.io, line, end);
        }
    }

    pub fn flushFile(self: *SessionManager) !void {
        if (self.flushed) return;

        const ts_ns = serde.currentTimeNs(self.io);
        const ts_str = try serde.formatNanos(self.allocator, ts_ns);
        defer self.allocator.free(ts_str);

        const filename = try std.fmt.allocPrint(self.allocator, "{s}.jsonl", .{ts_str});
        defer self.allocator.free(filename);

        Io.Dir.cwd().createDirPath(self.io, self.session_dir) catch {};

        const full_path = try std.fs.path.join(self.allocator, &.{ self.session_dir, filename });
        defer self.allocator.free(full_path);

        const tmp_path = try std.fmt.allocPrint(self.allocator, "{s}.tmp", .{full_path});
        defer self.allocator.free(tmp_path);

        {
            const file = try Io.Dir.cwd().createFile(self.io, tmp_path, .{});
            defer file.close(self.io);

            const header_line = try serde.serializeHeader(self.allocator, self.session_id, ts_ns, ".", self.model, self.provider);
            defer self.allocator.free(header_line);
            try file.writeStreamingAll(self.io, header_line);

            for (self.entries.items) |entry| {
                const line = switch (entry) {
                    .message => |msg| try serde.serializeMessage(self.allocator, msg),
                    .compaction => |c| try serde.serializeCompaction(self.allocator, c.summary, c.first_kept_index, c.tokens_before),
                };
                defer self.allocator.free(line);
                try file.writeStreamingAll(self.io, line);
            }
        }

        try Io.Dir.renameAbsolute(tmp_path, full_path, self.io);

        self.session_file = try self.allocator.dupe(u8, full_path);
        self.flushed = true;
    }

    pub fn buildContext(self: *const SessionManager) ![]types.Message {
        var list_msgs = std.array_list.Managed(types.Message).init(self.allocator);
        var start: usize = 0;
        for (self.entries.items) |e| {
            if (e == .compaction and e.compaction.first_kept_index > start)
                start = e.compaction.first_kept_index;
        }

        for (self.entries.items[start..]) |e| {
            if (e == .message) try list_msgs.append(e.message);
        }
        return try list_msgs.toOwnedSlice();
    }
    pub fn rename(self: *SessionManager, new_name: []const u8) !void {
        const new_id = try self.allocator.dupe(u8, new_name);
        self.allocator.free(self.session_id);
        self.session_id = new_id;
    }

    pub fn updateHeader(self: *SessionManager, model: []const u8, provider: []const u8) !void {
        const new_model = try self.allocator.dupe(u8, model);
        errdefer self.allocator.free(new_model);
        const new_provider = try self.allocator.dupe(u8, provider);
        errdefer self.allocator.free(new_provider);

        self.allocator.free(self.model);
        self.allocator.free(self.provider);
        self.model = new_model;
        self.provider = new_provider;

        if (self.flushed) {
            const header_line = try serde.serializeHeader(self.allocator, self.session_id, serde.currentTimeNs(self.io), ".", self.model, self.provider);
            defer self.allocator.free(header_line);
            if (self.session_file) |f| {
                const file = try Io.Dir.cwd().openFile(self.io, f, .{ .mode = .read_write });
                defer file.close(self.io);
                const end = (try file.stat(self.io)).size;
                try file.writePositionalAll(self.io, header_line, end);
            }
        }
    }
};

test "session: empty session has no messages" {
    const testing = std.testing;
    var sm = try SessionManager.create(testing.allocator, testing.io, ".", "", "");
    defer sm.deinit();
    const ctx = try sm.buildContext();
    defer testing.allocator.free(ctx);
    try testing.expectEqual(@as(usize, 0), ctx.len);
}

test "session: append and buildContext returns messages in order" {
    const testing = std.testing;
    const a = testing.allocator;
    var sm = try SessionManager.create(a, testing.io, ".", "", "");
    defer sm.deinit();

    var c1 = try a.alloc(types.ContentPart, 1);
    c1[0] = .{ .text = "first" };
    try sm.appendMessage(.{ .role = .user, .content = c1 });

    var c2 = try a.alloc(types.ContentPart, 1);
    c2[0] = .{ .text = "second" };
    try sm.appendMessage(.{ .role = .assistant, .content = c2 });

    const ctx = try sm.buildContext();
    defer a.free(ctx);
    try testing.expectEqual(@as(usize, 2), ctx.len);
    try testing.expectEqualStrings("first", ctx[0].content.?[0].text);
    try testing.expectEqualStrings("second", ctx[1].content.?[0].text);
}

test "session: compaction skips entries before first_kept_index" {
    const testing = std.testing;
    const a = testing.allocator;
    var sm = try SessionManager.create(a, testing.io, ".", "", "");
    defer sm.deinit();

    for (0..5) |i| {
        var c = try a.alloc(types.ContentPart, 1);
        c[0] = .{ .text = try std.fmt.allocPrint(a, "msg{d}", .{i}) };
        try sm.appendMessage(.{ .role = .user, .content = c });
    }
    try sm.appendCompaction("compact", 3, 0);
    const ctx = try sm.buildContext();
    defer a.free(ctx);
    try testing.expectEqual(@as(usize, 2), ctx.len);
    try testing.expectEqualStrings("msg3", ctx[0].content.?[0].text);
}

test "session: message serialization round-trips through JSON" {
    const testing = std.testing;
    const a = testing.allocator;

    var c = try a.alloc(types.ContentPart, 1);
    c[0] = .{ .text = "hello world" };
    const msg = types.Message{ .role = .user, .content = c };

    const json_line = try serde.serializeMessage(a, msg);
    defer a.free(json_line);

    try testing.expect(std.mem.startsWith(u8, json_line, "{\"type\":\"message\""));
    try testing.expect(std.mem.indexOf(u8, json_line, "\"role\":\"user\"") != null);
    try testing.expect(std.mem.indexOf(u8, json_line, "\"content\":\"hello world\"") != null);
}

test "listSessions: empty dir returns empty" {
    const testing = std.testing;
    const a = testing.allocator;

    const tmp_dir = try std.fs.path.join(a, &.{ ".zig-test-sessions", "list-empty" });
    defer {
        Io.Dir.cwd().deleteTree(testing.io, tmp_dir) catch {};
        a.free(tmp_dir);
    }
    try Io.Dir.cwd().createDirPath(testing.io, tmp_dir);

    const sessions = try listSessions(a, testing.io, tmp_dir);
    defer freeSessionInfo(a, sessions);
    try testing.expectEqual(@as(usize, 0), sessions.len);
}

test "readSessionHeaderFromContent: parses session header from content" {
    const testing = std.testing;
    const a = testing.allocator;
    const content = "{\"type\":\"session\",\"id\":\"abc123\",\"timestamp\":1000000000000,\"cwd\":\".\",\"version\":1}\n" ++
        "{\"type\":\"message\",\"role\":\"user\",\"content\":\"hi\"}\n";
    const header = try serde.readSessionHeaderFromContent(a, content);
    defer {
        a.free(header.id);
        a.free(header.cwd);
    }
    try testing.expectEqualStrings("abc123", header.id);
    try testing.expectEqual(@as(u32, 1), header.version);
}

test "formatTimestamp: formats nanoseconds to human-readable" {
    const testing = std.testing;
    const ts = try serde.formatTimestamp(testing.allocator, 0);
    defer testing.allocator.free(ts);
    try testing.expect(ts.len > 0);
    try testing.expect(std.mem.indexOf(u8, ts, ":") != null);
}

test "continueByIndex: invalid index returns error" {
    const testing = std.testing;
    const a = testing.allocator;

    const tmp_dir = try std.fs.path.join(a, &.{ ".zig-test-sessions", "by-index-err" });
    defer {
        Io.Dir.cwd().deleteTree(testing.io, tmp_dir) catch {};
        a.free(tmp_dir);
    }
    try Io.Dir.cwd().createDirPath(testing.io, tmp_dir);

    try testing.expectError(error.SessionNotFound, continueByIndex(a, testing.io, tmp_dir, 0));
}

test "loadEntries: parses valid JSONL content" {
    const testing = std.testing;
    const a = testing.allocator;
    const content = "{\"type\":\"session\",\"id\":\"test-session\",\"timestamp\":1000,\"cwd\":\".\",\"version\":1}\n" ++
        "{\"type\":\"message\",\"role\":\"user\",\"content\":\"hi\"}\n";
    const loaded = try serde.loadEntries(a, content);
    defer loaded.entries.deinit();
    try testing.expectEqualStrings("test-session", loaded.header.id);
}

test "loadEntries: missing header returns error" {
    const testing = std.testing;
    const a = testing.allocator;
    const content = "{\"type\":\"message\",\"role\":\"user\",\"content\":\"hi\"}\n";
    try testing.expectError(error.MissingSessionHeader, serde.loadEntries(a, content));
}

test "continueById: no match returns error" {
    const testing = std.testing;
    const a = testing.allocator;

    const tmp_dir = try std.fs.path.join(a, &.{ ".zig-test-sessions", "by-id-err" });
    defer {
        Io.Dir.cwd().deleteTree(testing.io, tmp_dir) catch {};
        a.free(tmp_dir);
    }
    try Io.Dir.cwd().createDirPath(testing.io, tmp_dir);

    const path = try std.fs.path.join(a, &.{ tmp_dir, "100.jsonl" });
    defer a.free(path);
    {
        const file = try Io.Dir.cwd().createFile(testing.io, path, .{});
        defer file.close(testing.io);
        try file.writeStreamingAll(testing.io,
            "{\"type\":\"session\",\"id\":\"abc123\",\"timestamp\":5000000000000,\"cwd\":\".\",\"version\":1}\n" ++
            "{\"type\":\"message\",\"role\":\"user\",\"content\":\"hi\"}\n",
        );
    }

    try testing.expectError(error.SessionNotFound, continueById(a, testing.io, tmp_dir, "xyz"));
}

test "serializeMessage: tool result includes name, duration_ms, is_error" {
    const testing = std.testing;
    const a = testing.allocator;

    var c = try a.alloc(types.ContentPart, 1);
    c[0] = .{ .tool_result = .{
        .id = "call_1",
        .content = "output",
        .is_error = true,
        .name = "bash",
        .duration_ms = 320,
    } };
    const msg = types.Message{ .role = .tool, .content = c, .tool_call_id = "call_1", .timestamp_ns = 1000 };

    const json_line = try serde.serializeMessage(a, msg);
    defer a.free(json_line);

    try testing.expect(std.mem.indexOf(u8, json_line, "\"name\":\"bash\"") != null);
    try testing.expect(std.mem.indexOf(u8, json_line, "\"duration_ms\":320") != null);
    try testing.expect(std.mem.indexOf(u8, json_line, "\"is_error\":true") != null);
    try testing.expect(std.mem.indexOf(u8, json_line, "\"timestamp\":1000") != null);
}

test "serializeMessage: tool result without optional fields omits them" {
    const testing = std.testing;
    const a = testing.allocator;

    var c = try a.alloc(types.ContentPart, 1);
    c[0] = .{ .tool_result = .{ .id = "call_1", .content = "ok" } };
    const msg = types.Message{ .role = .tool, .content = c };

    const json_line = try serde.serializeMessage(a, msg);
    defer a.free(json_line);

    try testing.expect(std.mem.indexOf(u8, json_line, "\"name\"") == null);
    try testing.expect(std.mem.indexOf(u8, json_line, "\"duration_ms\"") == null);
    try testing.expect(std.mem.indexOf(u8, json_line, "\"is_error\"") == null);
}

test "readSessionHeaderFromContent: parses model and provider" {
    const testing = std.testing;
    const a = testing.allocator;
    const content = "{\"type\":\"session\",\"id\":\"abc\",\"timestamp\":1,\"cwd\":\".\",\"version\":1,\"model\":\"deepseek-v4-flash\",\"provider\":\"deepseek\"}\n";
    const header = try serde.readSessionHeaderFromContent(a, content);
    defer {
        a.free(header.id);
        a.free(header.cwd);
        if (header.model) |m| a.free(m);
        if (header.provider) |p| a.free(p);
    }
    try testing.expectEqualStrings("deepseek-v4-flash", header.model.?);
    try testing.expectEqualStrings("deepseek", header.provider.?);
}

test "readSessionHeaderFromContent: missing model/provider returns null" {
    const testing = std.testing;
    const a = testing.allocator;
    const content = "{\"type\":\"session\",\"id\":\"old\",\"timestamp\":1,\"cwd\":\".\",\"version\":1}\n";
    const header = try serde.readSessionHeaderFromContent(a, content);
    defer {
        a.free(header.id);
        a.free(header.cwd);
        if (header.model) |m| a.free(m);
        if (header.provider) |p| a.free(p);
    }
    try testing.expect(header.model == null);
    try testing.expect(header.provider == null);
}

test "loadEntries: parses new fields from JSONL" {
    const testing = std.testing;
    const a = testing.allocator;
    const content = "{\"type\":\"session\",\"id\":\"ts\",\"timestamp\":1000,\"cwd\":\".\",\"version\":1,\"model\":\"gpt-4o\",\"provider\":\"openai\"}\n" ++
        "{\"type\":\"message\",\"role\":\"tool\",\"tool_call_id\":\"c1\",\"content\":\"result\",\"timestamp\":2000,\"is_error\":false,\"name\":\"read\",\"duration_ms\":150}\n";
    const loaded = try serde.loadEntries(a, content);
    defer {
        for (loaded.entries.items) |e| {
            if (e == .message) {
                if (e.message.content) |p| a.free(p);
            }
        }
        loaded.entries.deinit();
        a.free(loaded.header.id);
        a.free(loaded.header.cwd);
        if (loaded.header.model) |m| a.free(m);
        if (loaded.header.provider) |p| a.free(p);
    }
    try testing.expectEqualStrings("gpt-4o", loaded.header.model.?);
    try testing.expectEqualStrings("openai", loaded.header.provider.?);
    try testing.expectEqual(@as(usize, 1), loaded.entries.items.len);
    const msg = loaded.entries.items[0].message;
    try testing.expect(msg.content != null);
    try testing.expect(msg.content.?[0] == .tool_result);
    try testing.expectEqualStrings("result", msg.content.?[0].tool_result.content);
    try testing.expectEqual(false, msg.content.?[0].tool_result.is_error);
    try testing.expectEqualStrings("read", msg.content.?[0].tool_result.name.?);
    try testing.expectEqual(@as(u32, 150), msg.content.?[0].tool_result.duration_ms.?);
    try testing.expect(msg.timestamp_ns.? == 2000);
}

test "session: updateHeader updates model and provider in memory" {
    const testing = std.testing;
    const a = testing.allocator;
    var sm = try SessionManager.create(a, testing.io, ".", "old-model", "old-provider");
    defer sm.deinit();

    try testing.expectEqualStrings("old-model", sm.model);
    try testing.expectEqualStrings("old-provider", sm.provider);

    try sm.updateHeader("new-model", "new-provider");

    try testing.expectEqualStrings("new-model", sm.model);
    try testing.expectEqualStrings("new-provider", sm.provider);
}

test "loadEntries: last session header wins (supports model switches)" {
    const testing = std.testing;
    const a = testing.allocator;
    // Two session headers: second should override first
    const content =
        "{\"type\":\"session\",\"id\":\"first-session\",\"timestamp\":1000,\"cwd\":\".\",\"version\":1,\"model\":\"gpt-4\",\"provider\":\"openai\"}\n" ++
        "{\"type\":\"message\",\"role\":\"user\",\"content\":\"hello\"}\n" ++
        "{\"type\":\"session\",\"id\":\"second-session\",\"timestamp\":2000,\"cwd\":\".\",\"version\":1,\"model\":\"deepseek-v4-flash\",\"provider\":\"deepseek\"}\n" ++
        "{\"type\":\"message\",\"role\":\"assistant\",\"content\":\"world\"}\n";
    const loaded = try serde.loadEntries(a, content);
    defer {
        a.free(loaded.header.id);
        a.free(loaded.header.cwd);
        if (loaded.header.model) |m| a.free(m);
        if (loaded.header.provider) |p| a.free(p);
        for (loaded.entries.items) |e| {
            if (e == .message) {
                if (e.message.content) |p| a.free(p);
            }
        }
        loaded.entries.deinit();
    }
    // Last header wins — should be second-session
    try testing.expectEqualStrings("second-session", loaded.header.id);
    try testing.expectEqualStrings("deepseek-v4-flash", loaded.header.model.?);
    try testing.expectEqualStrings("deepseek", loaded.header.provider.?);
    // Both messages should be present
    try testing.expectEqual(@as(usize, 2), loaded.entries.items.len);
    try testing.expectEqualStrings("hello", loaded.entries.items[0].message.content.?[0].text);
    try testing.expectEqualStrings("world", loaded.entries.items[1].message.content.?[0].text);
}

test "loadEntries: single session header unchanged" {
    const testing = std.testing;
    const a = testing.allocator;
    const content = "{\"type\":\"session\",\"id\":\"only-session\",\"timestamp\":1000,\"cwd\":\".\",\"version\":1,\"model\":\"gpt-4o\",\"provider\":\"openai\"}\n" ++
        "{\"type\":\"message\",\"role\":\"user\",\"content\":\"hi\"}\n";
    const loaded = try serde.loadEntries(a, content);
    defer {
        a.free(loaded.header.id);
        a.free(loaded.header.cwd);
        if (loaded.header.model) |m| a.free(m);
        if (loaded.header.provider) |p| a.free(p);
        for (loaded.entries.items) |e| {
            if (e == .message) {
                if (e.message.content) |p| a.free(p);
            }
        }
        loaded.entries.deinit();
    }
    try testing.expectEqualStrings("only-session", loaded.header.id);
    try testing.expectEqualStrings("gpt-4o", loaded.header.model.?);
    try testing.expectEqualStrings("openai", loaded.header.provider.?);
    try testing.expectEqual(@as(usize, 1), loaded.entries.items.len);
}
