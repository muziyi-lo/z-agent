const std = @import("std");
const builtin = @import("builtin");

fn getShell() []const u8 {
    if (builtin.os.tag == .windows) return "powershell.exe";
    return "/bin/sh";
}

fn getShellFlag(exe: []const u8) []const u8 {
    if (std.mem.eql(u8, exe, "powershell.exe") or std.mem.eql(u8, exe, "pwsh.exe")) return "-Command";
    return "/c";
}

fn resolve(allocator: std.mem.Allocator, io: std.Io, project_root: []const u8, event: []const u8) ?struct { cmd: []const u8, exe: []const u8, flag: []const u8 } {
    const hook_path = std.fs.path.join(allocator, &.{ project_root, ".zagent", "hooks", event }) catch return null;
    defer allocator.free(hook_path);

    const file = std.Io.Dir.cwd().openFile(io, hook_path, .{ .mode = .read_only }) catch return null;
    file.close(io);

    const exe = getShell();
    const flag = getShellFlag(exe);
    const cmd = if (std.mem.eql(u8, exe, "powershell.exe"))
        std.fmt.allocPrint(allocator, "& '{s}'", .{hook_path}) catch return null
    else
        std.fmt.allocPrint(allocator, "'{s}'", .{hook_path}) catch return null;
    return .{ .cmd = cmd, .exe = exe, .flag = flag };
}

pub fn run(allocator: std.mem.Allocator, io: std.Io, project_root: []const u8, event: []const u8, payload_json: []const u8, stdout: *std.Io.Writer) void {
    const info = resolve(allocator, io, project_root, event) orelse return;
    defer allocator.free(info.cmd);
    _ = runHook(allocator, io, info.exe, info.flag, info.cmd, payload_json, stdout, event) catch {};
}

pub fn runIntercept(allocator: std.mem.Allocator, io: std.Io, project_root: []const u8, event: []const u8, payload_json: []const u8, stdout: *std.Io.Writer) bool {
    const info = resolve(allocator, io, project_root, event) orelse return true;
    defer allocator.free(info.cmd);
    const ok = runHook(allocator, io, info.exe, info.flag, info.cmd, payload_json, stdout, event) catch return false;
    if (!ok) {
        stdout.writeAll("[hook:") catch {};
        stdout.writeAll(event) catch {};
        stdout.writeAll("] 已拦截\n") catch {};
    }
    return ok;
}

fn runHook(allocator: std.mem.Allocator, io: std.Io, exe: []const u8, flag: []const u8, cmd: []const u8, payload_json: []const u8, stdout: *std.Io.Writer, event: []const u8) !bool {
    const limit = @as(std.Io.Limit, @enumFromInt(10 * 1024));
    const result = std.process.run(allocator, io, .{
        .argv = &.{ exe, flag, cmd, payload_json },
        .stdout_limit = limit,
        .stderr_limit = limit,
    }) catch return error.SpawnFailed;
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    if (result.stdout.len > 0) {
        stdout.writeAll("[hook:") catch {};
        stdout.writeAll(event) catch {};
        stdout.writeAll("] ") catch {};
        stdout.writeAll(result.stdout) catch {};
    }

    return switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
}
