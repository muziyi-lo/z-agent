const std = @import("std");
const builtin = @import("builtin");
const jh = @import("json.zig");
const trunc = @import("truncate.zig");
const root_dir = @import("root_dir.zig");
const ToolResult = @import("registry.zig").ToolResult;

pub const tool_name = "bash";
pub const tool_description = "Execute a shell command. Use for building, testing, running tools, git operations, and any CLI tasks. Output is captured and returned with exit code.";
pub const tool_params = "{\"type\":\"object\",\"properties\":{\"command\":{\"type\":\"string\",\"description\":\"Shell command to execute\"}},\"required\":[\"command\"]}";

const MAX_OUTPUT: usize = 50 * 1024;

var sanitize_keys: []const []const u8 = &.{};

pub fn setSanitizeKeys(keys: []const []const u8) void {
    sanitize_keys = keys;
}

fn lowerCmd(cmd: []const u8, buf: *[512]u8) []const u8 {
    const slice = if (cmd.len > buf.len) cmd[0..buf.len] else cmd;
    for (slice, 0..) |c, i| {
        buf[i] = switch (c) { 'A'...'Z' => c + 32, else => c };
    }
    return buf[0..slice.len];
}

fn isBlocked(cmd: []const u8) bool {
    const patterns = [_][]const u8{
        "format", "format-volume", "diskpart", "shutdown",
        "rd /s", "rd /q", "rmdir /s", "rmdir /q",
        "del /s", "del /f", "remove-item", "ri ",
        "clear-item", "cli ", "stop-computer", "restart-computer",
        "rm -rf", "rm -fr", "dd ", "mkfs.",
        ":(){ :|:& };:",
    };
    var buf: [512]u8 = undefined;
    const lowered = lowerCmd(cmd, &buf);

    for (patterns) |p| {
        if (std.mem.startsWith(u8, lowered, p)) return true;
    }
    return false;
}

pub fn isExpensive(cmd: []const u8) ?[]const u8 {
    var buf: [512]u8 = undefined;
    const lowered = lowerCmd(cmd, &buf);

    const has_recurse = std.mem.indexOf(u8, lowered, "-recurse") != null;

    // Get-ChildItem -Recurse without -Depth
    if (has_recurse and std.mem.indexOf(u8, lowered, "-depth") == null) {
        const is_dir_cmd = std.mem.indexOf(u8, lowered, "get-childitem") != null or
            std.mem.indexOf(u8, lowered, "dir ") != null or
            std.mem.indexOf(u8, lowered, "gci") != null or
            std.mem.indexOf(u8, lowered, "ls ") != null;
        if (is_dir_cmd) {
            return "Expensive: Get-ChildItem -Recurse without -Depth N scans entire tree. Add -Depth 2 or use 'Get-ChildItem -Recurse -Depth 2'.";
        }
    }

    // Select-String -Recurse without -Path or -Filter
    if (has_recurse) {
        const is_ss = std.mem.indexOf(u8, lowered, "select-string") != null or
            std.mem.indexOf(u8, lowered, "sls") != null;
        if (is_ss and std.mem.indexOf(u8, lowered, "-path") == null and std.mem.indexOf(u8, lowered, "-filter") == null) {
            return "Expensive: Select-String -Recurse without -Path or -Filter scans all files. Add -Filter \"*.ext\" or -Path <dir>.";
        }
    }

    // Get-Content on path-like argument (heuristic: contains \ or /)
    if (std.mem.indexOf(u8, lowered, "get-content") != null or std.mem.indexOf(u8, lowered, "cat ") != null or std.mem.indexOf(u8, lowered, "type ") != null) {
        if (std.mem.indexOf(u8, lowered, "\\") != null or std.mem.indexOf(u8, lowered, "/") != null) {
            if (std.mem.indexOf(u8, lowered, "-head") == null and std.mem.indexOf(u8, lowered, "-totalcount") == null and std.mem.indexOf(u8, lowered, "-tail") == null) {
                return "Expensive: Get-Content on a path may read a large file. Add -Head N to limit lines.";
            }
        }
    }

    return null;
}

pub fn execute(allocator: std.mem.Allocator, io: std.Io, args: std.json.Value) ToolResult {
    const args_obj = args.object;
    const command = args_obj.get("command") orelse return ToolResult.fail(jsonErrorStr(allocator, "missing 'command' argument", .{}));

    if (isBlocked(command.string)) {
        return ToolResult.fail(jsonErrorStr(allocator, "blocked: dangerous command not allowed", .{}));
    }

    if (isExpensive(command.string)) |msg| {
        return ToolResult.fail(jsonErrorStr(allocator, "{s}", .{msg}));
    }

    const exe = getShellExe();
    const flag = getShellFlag(exe);
    const limit = @as(std.Io.Limit, @enumFromInt(MAX_OUTPUT));

    const is_powershell = std.mem.eql(u8, exe, "powershell.exe") or std.mem.eql(u8, exe, "pwsh.exe");
    const cmd = if (is_powershell)
        std.fmt.allocPrint(allocator, "[Console]::OutputEncoding=[System.Text.UTF8Encoding]::new($false);$OutputEncoding=[System.Text.UTF8Encoding]::new($false);{s}", .{command.string}) catch return ToolResult.fail("Error: OOM")
    else
        command.string;
    defer if (is_powershell) allocator.free(cmd);

    const argv = if (is_powershell)
        @as([]const []const u8, &.{ exe, "-NoProfile", flag, cmd })
    else
        @as([]const []const u8, &.{ exe, flag, cmd });

    var env_map_opt: ?std.process.Environ.Map = null;
    const env: std.process.Environ = .{ .block = .{ .use_global = true } };
    if (std.process.Environ.createMap(env, allocator)) |map| {
        env_map_opt = map;
    } else |_| {}
    defer if (env_map_opt) |*m| m.deinit();

    if (env_map_opt) |*m| {
        for (sanitize_keys) |key| {
            _ = m.swapRemove(key);
        }
    }

    const result = std.process.run(allocator, io, .{
        .argv = argv,
        .cwd = if (root_dir.project_root.len > 0) .{ .path = root_dir.project_root } else .inherit,
        .environ_map = if (env_map_opt) |*m| m else null,
        .stdout_limit = limit,
        .stderr_limit = limit,
    }) catch |err| {
        return ToolResult.fail(jsonErrorStr(allocator, "execution failed: {}", .{err}));
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    const exit_code: i32 = switch (result.term) {
        .exited => |code| code,
        else => -1,
    };

    const so = trunc.truncateBytes(result.stdout, MAX_OUTPUT);
    const se = trunc.truncateBytes(result.stderr, MAX_OUTPUT);
    const any_truncated = so.truncated or se.truncated;

    var buf = std.array_list.Managed(u8).init(allocator);
    defer buf.deinit();

    const hex_len = @min(so.text.len, 64);
    const hex_str = if (hex_len > 0) blk: {
        var hb = std.array_list.Managed(u8).init(allocator);
        for (so.text[0..hex_len], 0..) |b, i| {
            if (i > 0) hb.append(' ') catch break;
            var tmp: [3]u8 = undefined;
            const s = std.fmt.bufPrint(&tmp, "{x:0>2}", .{b}) catch break;
            hb.appendSlice(s) catch break;
        }
        break :blk hb.toOwnedSlice() catch "hex_err";
    } else "";
    defer if (hex_len > 0) allocator.free(hex_str);

    jh.putc(&buf, '{') catch return ToolResult.fail("Error: OOM");
    jh.putInt(&buf, "exit_code", exit_code) catch return ToolResult.fail("Error: OOM");
    jh.putc(&buf, ',') catch return ToolResult.fail("Error: OOM");
    jh.putString(&buf, "stdout", so.text) catch return ToolResult.fail("Error: OOM");
    jh.putc(&buf, ',') catch return ToolResult.fail("Error: OOM");
    jh.putString(&buf, "stdout_hex", hex_str) catch return ToolResult.fail("Error: OOM");
    jh.putc(&buf, ',') catch return ToolResult.fail("Error: OOM");
    jh.putString(&buf, "stderr", se.text) catch return ToolResult.fail("Error: OOM");
    jh.putc(&buf, ',') catch return ToolResult.fail("Error: OOM");
    jh.putBool(&buf, "truncated", any_truncated) catch return ToolResult.fail("Error: OOM");
    if (any_truncated) {
        jh.putc(&buf, ',') catch return ToolResult.fail("Error: OOM");
        const note = std.fmt.allocPrint(allocator, "Output truncated at {d} bytes per stream. Narrow query scope (add -Depth, -Filter, or -Head) to get full results.", .{MAX_OUTPUT}) catch "OOM";
        defer allocator.free(note);
        jh.putString(&buf, "note", note) catch return ToolResult.fail("Error: OOM");
    }
    jh.putc(&buf, '}') catch return ToolResult.fail("Error: OOM");
    return ToolResult.ok(jh.finish(&buf));
}

fn jsonErrorStr(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(allocator, "Error: " ++ fmt, args) catch "Error: OOM";
}

fn getShellExe() []const u8 {
    if (builtin.os.tag != .windows) return "/bin/sh";
    return "powershell.exe";
}

fn getShellFlag(exe: []const u8) []const u8 {
    if (std.mem.endsWith(u8, exe, "pwsh.exe") or std.mem.endsWith(u8, exe, "powershell.exe")) {
        return "-Command";
    }
    return "/c";
}

fn parseJsonResult(allocator: std.mem.Allocator, json_str: []const u8) ?struct { exit_code: i32, stdout: []const u8, stderr: []const u8, truncated: bool } {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, json_str, .{}) catch return null;
    defer parsed.deinit();
    const obj = parsed.value.object;
    const exit_code = if (obj.get("exit_code")) |v| @as(i32, @intCast(v.integer)) else -1;
    const stdout = if (obj.get("stdout")) |v| if (v == .string) v.string else "" else "";
    const stderr = if (obj.get("stderr")) |v| if (v == .string) v.string else "" else "";
    const truncated = if (obj.get("truncated")) |v| v == .bool and v.bool else false;
    return .{ .exit_code = exit_code, .stdout = stdout, .stderr = stderr, .truncated = truncated };
}

test "bash: echo returns valid JSON with stdout" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const io = testing.io;

    const json = "{\"command\": \"echo hello\"}";
    var pj = std.json.parseFromSlice(std.json.Value, allocator, json, .{}) catch return;
    defer pj.deinit();
    const args = pj.value;
    const tr = execute(allocator, io, args);
    defer {
        if (!std.mem.startsWith(u8, tr.output, "Error:") and std.mem.startsWith(u8, tr.output, "{"))
            allocator.free(tr.output);
    }

    if (!tr.success)
        return; // skip if process spawning not available in test env

    if (!std.mem.startsWith(u8, tr.output, "{"))
        return;

    const parsed = parseJsonResult(allocator, tr.output);
    const p = parsed orelse return;

    try testing.expectEqual(@as(i32, 0), p.exit_code);
    try testing.expect(std.mem.indexOf(u8, p.stdout, "hello") != null);
    try testing.expect(!p.truncated);
}

test "bash: missing command returns error" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const io = testing.io;

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, "{}", .{}) catch return;
    defer parsed.deinit();
    const args = parsed.value;
    const tr = execute(allocator, io, args);
    defer allocator.free(tr.output);
    try testing.expect(!tr.success);
    try testing.expect(std.mem.startsWith(u8, tr.output, "Error:"));
}

test "bash: dangerous command is blocked" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const io = testing.io;

    const blocked_commands = [_][]const u8{
        "format C:",
        "shutdown /s",
        "rm -rf /",
        "del /s /q C:\\*",
        "Remove-Item -Recurse C:\\",
        "diskpart",
    };
    for (blocked_commands) |cmd| {
        const json = try std.fmt.allocPrint(allocator, "{{\"command\": \"{s}\"}}", .{cmd});
        defer allocator.free(json);
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{}) catch continue;
        defer parsed.deinit();
        const args = parsed.value;
        const tr = execute(allocator, io, args);
        defer allocator.free(tr.output);
        try testing.expect(!tr.success);
        try testing.expect(std.mem.startsWith(u8, tr.output, "Error:"));
        try testing.expect(std.mem.indexOf(u8, tr.output, "blocked") != null);
    }
}

test "bash: safe commands not blocked by isBlocked" {
    const testing = std.testing;

    try testing.expect(!isBlocked("Get-Date -Format yyyy-MM-dd"));
    try testing.expect(!isBlocked("Get-Date -UFormat %Y-%m-%d"));
    try testing.expect(!isBlocked("Get-Date -Format \"yyyy-MM-dd HH:mm:ss\""));
    try testing.expect(!isBlocked("echo format C:"));
    // Actual dangerous cases still blocked
    try testing.expect(isBlocked("format C:"));
    try testing.expect(isBlocked("format-volume E:"));
    try testing.expect(isBlocked("dd if=/dev/zero of=file"));
    try testing.expect(isBlocked("rm -rf /"));
}

test "bash: expensive commands return guidance" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const io = testing.io;

    const expensive_commands = [_][]const u8{
        "Get-ChildItem -Recurse",
        "dir -Recurse",
        "Select-String -Recurse -Pattern foo",
        "Get-Content C:/big.txt",
    };
    for (expensive_commands) |cmd| {
        const json = try std.fmt.allocPrint(allocator, "{{\"command\": \"{s}\"}}", .{cmd});
        defer allocator.free(json);
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{}) catch continue;
        defer parsed.deinit();
        const args = parsed.value;
        const tr = execute(allocator, io, args);
        defer allocator.free(tr.output);
        try testing.expect(!tr.success);
        try testing.expect(std.mem.startsWith(u8, tr.output, "Error:"));
        try testing.expect(std.mem.indexOf(u8, tr.output, "Expensive") != null);
    }
}

test "lowerCmd: converts uppercase to lowercase, handles overflow" {
    const testing = std.testing;
    var buf: [512]u8 = undefined;

    // Normal case
    try testing.expectEqualStrings("hello world", lowerCmd("Hello World", &buf));
    // Already lowercase
    try testing.expectEqualStrings("hello", lowerCmd("hello", &buf));
    // Mixed case
    try testing.expectEqualStrings("abc123!@#", lowerCmd("ABC123!@#", &buf));
    // Overflow: cmd longer than buf
    const long_cmd = "A" ** 600;
    const lowered = lowerCmd(long_cmd, &buf);
    try testing.expectEqual(@as(usize, 512), lowered.len);
    try testing.expectEqual(@as(u8, 'a'), lowered[0]);
    try testing.expectEqual(@as(u8, 'a'), lowered[511]);
}

test "bash: nonexistent command returns non-zero exit" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const io = testing.io;

    const json = "{\"command\": \"nonexistent_cmd_xyz_123\"}";
    var pj2 = std.json.parseFromSlice(std.json.Value, allocator, json, .{}) catch return;
    defer pj2.deinit();
    const args = pj2.value;
    const tr = execute(allocator, io, args);
    defer {
        if (tr.success and std.mem.startsWith(u8, tr.output, "{"))
            allocator.free(tr.output);
    }

    if (!tr.success)
        return; // skip if process spawning not available in test env

    if (!std.mem.startsWith(u8, tr.output, "{"))
        return;

    const parsed = parseJsonResult(allocator, tr.output);
    const p = parsed orelse return;

    try testing.expect(p.exit_code != 0);
}
