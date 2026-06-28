const std = @import("std");

pub const SseStream = struct {
    file_reader: std.Io.File.Reader,
    allocator: std.mem.Allocator,
    read_buf: []u8,

    pub fn init(file: std.Io.File, io: std.Io, allocator: std.mem.Allocator) SseStream {
        const read_buf = allocator.alloc(u8, 4096) catch @panic("OOM");
        return .{
            .file_reader = file.readerStreaming(io, read_buf),
            .allocator = allocator,
            .read_buf = read_buf,
        };
    }

    pub fn deinit(self: *SseStream) void {
        self.allocator.free(self.read_buf);
    }

    pub fn next(self: *SseStream) !?[]const u8 {
        const reader = &self.file_reader.interface;
        while (true) {
            const line_opt = reader.takeDelimiter('\n') catch |err| switch (err) {
                error.ReadFailed => return error.ReadFailed,
                error.StreamTooLong => return error.StreamTooLong,
            };
            const raw_line = line_opt orelse return null;
            const line = std.mem.trimEnd(u8, raw_line, "\r");

            if (!std.mem.startsWith(u8, line, "data: ")) continue;
            const payload = line[6..];

            if (std.mem.eql(u8, payload, "[DONE]")) return null;

            return payload;
        }
    }
};

test "SseStream: reads data payload" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const io = testing.io;
    const tmp_path = "zig_test_sse_payload.txt";

    {
        const f = std.Io.Dir.cwd().createFile(io, tmp_path, .{ .read = true }) catch return;
        defer f.close(io);
        _ = f.writeStreamingAll(io, "data: {\"a\":1}\n\n") catch return;
    }
    defer std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};

    const opened = std.Io.Dir.cwd().openFile(io, tmp_path, .{ .mode = .read_only }) catch return;
    defer opened.close(io);

    var stream = SseStream.init(opened, io, allocator);
    defer stream.deinit();

    const p1 = try stream.next();
    try testing.expect(p1 != null);
    try testing.expectEqualStrings("{\"a\":1}", p1.?);

    try testing.expect((try stream.next()) == null);
}

test "SseStream: skips non-data lines" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const io = testing.io;
    const tmp_path = "zig_test_sse_skip.txt";

    {
        const f = std.Io.Dir.cwd().createFile(io, tmp_path, .{ .read = true }) catch return;
        defer f.close(io);
        _ = f.writeStreamingAll(io, ":\n\nevent: foo\ndata: {\"b\":2}\n\n") catch return;
    }
    defer std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};

    const opened = std.Io.Dir.cwd().openFile(io, tmp_path, .{ .mode = .read_only }) catch return;
    defer opened.close(io);

    var stream = SseStream.init(opened, io, allocator);
    defer stream.deinit();

    const p1 = try stream.next();
    try testing.expect(p1 != null);
    try testing.expectEqualStrings("{\"b\":2}", p1.?);

    try testing.expect((try stream.next()) == null);
}

test "SseStream: DONE terminates" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const io = testing.io;
    const tmp_path = "zig_test_sse_done.txt";

    {
        const f = std.Io.Dir.cwd().createFile(io, tmp_path, .{ .read = true }) catch return;
        defer f.close(io);
        _ = f.writeStreamingAll(io, "data: {\"c\":3}\n\ndata: [DONE]\n\n") catch return;
    }
    defer std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};

    const opened = std.Io.Dir.cwd().openFile(io, tmp_path, .{ .mode = .read_only }) catch return;
    defer opened.close(io);

    var stream = SseStream.init(opened, io, allocator);
    defer stream.deinit();

    try testing.expect((try stream.next()) != null);
    try testing.expect((try stream.next()) == null);
}

test "SseStream: handles CRLF" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const io = testing.io;
    const tmp_path = "zig_test_sse_crlf.txt";

    {
        const f = std.Io.Dir.cwd().createFile(io, tmp_path, .{ .read = true }) catch return;
        defer f.close(io);
        _ = f.writeStreamingAll(io, "data: hello\r\n\r\n") catch return;
    }
    defer std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};

    const opened = std.Io.Dir.cwd().openFile(io, tmp_path, .{ .mode = .read_only }) catch return;
    defer opened.close(io);

    var stream = SseStream.init(opened, io, allocator);
    defer stream.deinit();

    const p1 = try stream.next();
    try testing.expect(p1 != null);
    try testing.expectEqualStrings("hello", p1.?);

    try testing.expect((try stream.next()) == null);
}

test "SseStream: empty file returns null" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const io = testing.io;
    const tmp_path = "zig_test_sse_empty.txt";

    {
        const f = std.Io.Dir.cwd().createFile(io, tmp_path, .{ .read = true }) catch return;
        defer f.close(io);
    }
    defer std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};

    const opened = std.Io.Dir.cwd().openFile(io, tmp_path, .{ .mode = .read_only }) catch return;
    defer opened.close(io);

    var stream = SseStream.init(opened, io, allocator);
    defer stream.deinit();

    try testing.expect((try stream.next()) == null);
}
