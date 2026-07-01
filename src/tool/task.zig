const std = @import("std");
const config_mod = @import("../config.zig");
const root_dir = @import("root_dir.zig");
const ToolResult = @import("registry.zig").ToolResult;

pub const tool_name = "task";
pub const tool_description = "Delegate a task to a sub-agent. The sub-agent runs in an isolated process with its own system prompt. Use `files` to pass file contents as context without reading them yourself first. Sub-agents run in read-only mode by default; set `trust` to true to allow write operations. Use for code review, analysis, research tasks that need focused attention.";
pub const tool_params = "{\"type\":\"object\",\"properties\":{\"agent\":{\"type\":\"string\",\"description\":\"Name of the agent (e.g. 'worker', 'critic'). Must match a file in .opencode/agents/\"},\"task\":{\"type\":\"string\",\"description\":\"Detailed description of the task to delegate\"},\"files\":{\"type\":\"array\",\"items\":{\"type\":\"string\"},\"description\":\"File paths to read and include as context for the sub-agent\"},\"trust\":{\"type\":\"boolean\",\"description\":\"If true, sub-agent runs with full permissions (write allowed). Default: false (read-only)\"}},\"required\":[\"agent\",\"task\"]}";

const embedded_explore =
    \\---
    \\description: 文件搜索专家，擅长在代码库中快速定位和分析文件
    \\---
    \\You are a file search specialist. You excel at thoroughly navigating and exploring codebases.
    \\
    \\Your strengths:
    \\- Rapidly finding files using glob patterns
    \\- Searching code and text with powerful regex patterns
    \\- Reading and analyzing file contents
    \\
    \\Guidelines:
    \\- Use glob for broad file pattern matching
    \\- Use grep for searching file contents with regex
    \\- Use read_file when you know the specific file path you need to read
    \\- Use bash for file operations like listing directory contents
    \\- Return file paths as absolute paths in your final response
    \\- For clear communication, avoid using emojis
    \\- Do not create any files, or run bash commands that modify the system state in any way
    \\
    \\Complete the user's search request efficiently and report your findings clearly.
;

var exe_path: []const u8 = &.{};

pub fn setExePath(path: []const u8) void {
    exe_path = path;
}

fn loadAgentContent(allocator: std.mem.Allocator, io: std.Io, file_path: []const u8, name: []const u8) ?[]const u8 {
    if (std.Io.Dir.cwd().openFile(io, file_path, .{ .mode = .read_only })) |file| {
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
    } else |_| {
        if (std.mem.eql(u8, name, "explore")) {
            return allocator.dupe(u8, embedded_explore) catch null;
        }
        return null;
    }
}

/// Execute the task tool. Required args: `agent` (string), `task` (string).
/// Optional: `files` (array of strings) — file paths to read and include as
/// inline context prepended to the task prompt. File reading is best-effort:
/// missing/binary/OOM errors are annotated inline without blocking the task.
pub fn execute(allocator: std.mem.Allocator, io: std.Io, args: std.json.Value) ToolResult {
    const args_obj = args.object;
    const agent_val = args_obj.get("agent") orelse return ToolResult.fail(std.fmt.allocPrint(allocator, "Error: missing 'agent' argument", .{}) catch "Error: OOM");
    const task_val = args_obj.get("task") orelse return ToolResult.fail(std.fmt.allocPrint(allocator, "Error: missing 'task' argument", .{}) catch "Error: OOM");
    const agent = agent_val.string;
    const task = task_val.string;

    const trust_val = args_obj.get("trust");
    const is_trust = if (trust_val) |tv| tv == .bool and tv.bool else false;
    const perm_flag = if (is_trust) "--trust" else "--readonly";

    // Files inclusion: read referenced files and prepend as context.
    // All `catch {}` below are best-effort annotation: if OOM prevents us
    // from noting a file error, the file is silently skipped. The next file
    // still gets a chance. This is acceptable because file content inclusion
    // is a convenience, not a correctness requirement.
    var owned_merged: ?[]const u8 = null;
    defer if (owned_merged) |m| allocator.free(m);
    const effective_task = if (args_obj.get("files")) |fv| blk: {
        if (fv != .array or fv.array.items.len == 0) break :blk task;
        var buf = std.array_list.Managed(u8).init(allocator);
        defer buf.deinit();
        buf.appendSlice("Referenced files:\n") catch break :blk task;
        for (fv.array.items) |file_val| {
            if (file_val != .string) continue;
            const raw_path = file_val.string;
            const resolved = if (std.fs.path.isAbsolute(raw_path))
                raw_path
            else if (root_dir.project_root.len > 0)
                (std.fs.path.join(allocator, &.{ root_dir.project_root, raw_path }) catch blk2: {
                    buf.appendSlice("--- ") catch {};
                    buf.appendSlice(raw_path) catch {};
                    buf.appendSlice(" ---\n(error: path join OOM, using raw path)\n---\n") catch {};
                    break :blk2 raw_path;
                })
            else
                raw_path;
            const need_free = resolved.ptr != raw_path.ptr;
            defer if (need_free) allocator.free(resolved);
            const file = std.Io.Dir.cwd().openFile(io, resolved, .{ .mode = .read_only }) catch |err| {
                buf.appendSlice("--- ") catch {};
                buf.appendSlice(raw_path) catch {};
                buf.appendSlice(" ---\n(error: can't open: ") catch {};
                const err_str = std.fmt.allocPrint(allocator, "{}", .{err}) catch continue;
                defer allocator.free(err_str);
                buf.appendSlice(err_str) catch {};
                buf.appendSlice(")\n---\n") catch {};
                continue;
            };
            defer file.close(io);
            const stat = file.stat(io) catch {
                buf.appendSlice("--- ") catch {};
                buf.appendSlice(raw_path) catch {};
                buf.appendSlice(" ---\n(error: stat failed)\n---\n") catch {};
                continue;
            };
            const size: usize = @intCast(stat.size);
            const max_bytes: usize = 50 * 1024;
            const read_size = @min(size, max_bytes);
            const content = allocator.alloc(u8, read_size) catch {
                buf.appendSlice("--- ") catch {};
                buf.appendSlice(raw_path) catch {};
                buf.appendSlice(" ---\n(error: OOM)\n---\n") catch {};
                continue;
            };
            defer allocator.free(content);
            const n = file.readPositionalAll(io, content, 0) catch {
                buf.appendSlice("--- ") catch {};
                buf.appendSlice(raw_path) catch {};
                buf.appendSlice(" ---\n(error: read failed)\n---\n") catch {};
                continue;
            };
            if (std.mem.indexOfScalar(u8, content[0..n], 0) != null) {
                buf.appendSlice("--- ") catch {};
                buf.appendSlice(raw_path) catch {};
                buf.appendSlice(" ---\n(skipped: binary)\n---\n") catch {};
                continue;
            }
            buf.appendSlice("--- ") catch {};
            buf.appendSlice(raw_path) catch {};
            buf.appendSlice(" ---\n") catch {};
            buf.appendSlice(content[0..n]) catch {};
            if (size > max_bytes) buf.appendSlice("\n...(truncated)") catch {};
            buf.appendSlice("\n---\n") catch {};
        }
        buf.appendSlice("\n") catch {};
        buf.appendSlice(task) catch {};
        owned_merged = buf.toOwnedSlice() catch break :blk task;
        break :blk owned_merged.?;
    } else task;

    const using_fallback_root = root_dir.project_root.len == 0;
    const zagent_root = if (!using_fallback_root) root_dir.project_root else
        (config_mod.findZagentRoot(allocator, io) orelse return ToolResult.fail(std.fmt.allocPrint(allocator, "Error: cannot find .zagent directory", .{}) catch "Error: OOM"));
    defer if (using_fallback_root) allocator.free(zagent_root);

    const agent_path = std.fs.path.join(allocator, &.{ zagent_root, ".zagent", "agents", agent }) catch return ToolResult.fail("Error: OOM");
    defer allocator.free(agent_path);

    if (exe_path.len == 0) return ToolResult.fail(std.fmt.allocPrint(allocator, "Error: exe_path not set", .{}) catch "Error: OOM");

    const resolved = loadAgentContent(allocator, io, agent_path, agent);
    defer if (resolved) |r| allocator.free(r);

    var nonce_buf: [32]u8 = undefined;
    const nonce = blk: {
        const seed = @as(u64, @intCast(std.Io.Clock.Timestamp.now(io, .real).raw.nanoseconds));
        const s = std.fmt.bufPrint(&nonce_buf, "{x}", .{seed}) catch return ToolResult.fail("Error: OOM");
        break :blk allocator.dupe(u8, s) catch return ToolResult.fail("Error: OOM");
    };
    defer allocator.free(nonce);
    const marker_arg = std.fmt.allocPrint(allocator, "--result-marker={s}", .{nonce}) catch return ToolResult.fail("Error: OOM");
    defer allocator.free(marker_arg);

    const result = if (resolved) |content|
        std.process.run(allocator, io, .{
            .argv = &.{ exe_path, "--agent-prompt", content, marker_arg, perm_flag, effective_task },
            .stdout_limit = .unlimited,
            .stderr_limit = .unlimited,
        }) catch |err| {
        return ToolResult.fail(std.fmt.allocPrint(allocator, "Error: cannot spawn sub-agent: {}", .{err}) catch "Error: OOM");
    }
    else
        std.process.run(allocator, io, .{
            .argv = &.{ exe_path, "--agent", agent_path, marker_arg, perm_flag, effective_task },
            .stdout_limit = .unlimited,
            .stderr_limit = .unlimited,
        }) catch |err| {
        return ToolResult.fail(std.fmt.allocPrint(allocator, "Error: cannot spawn sub-agent: {}", .{err}) catch "Error: OOM");
    };
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    if (result.term != .exited or result.term.exited != 0) {
        const exit_info = if (result.term == .exited)
            std.fmt.allocPrint(allocator, "code {d}", .{result.term.exited}) catch "?"
        else if (result.term == .signal)
            std.fmt.allocPrint(allocator, "signal {d}", .{result.term.signal}) catch "?"
        else
            allocator.dupe(u8, "unknown") catch "?";
        defer allocator.free(exit_info);
        return ToolResult.fail(std.fmt.allocPrint(allocator, "Error: sub-agent failed with {s}", .{exit_info}) catch "Error: OOM");
    }

    const marker_start = std.fmt.allocPrint(allocator, "[ZAGENT_RESULT:{s}]", .{nonce}) catch return ToolResult.fail("Error: OOM");
    defer allocator.free(marker_start);
    const marker_end = std.fmt.allocPrint(allocator, "[ZAGENT_END:{s}]", .{nonce}) catch return ToolResult.fail("Error: OOM");
    defer allocator.free(marker_end);

    const start_pos = std.mem.indexOf(u8, result.stdout, marker_start);
    const end_pos = std.mem.indexOf(u8, result.stdout, marker_end);
    const content = if (start_pos) |s| blk: {
        const cs = s + marker_start.len;
        const ce = if (end_pos) |e| e else result.stdout.len;
        break :blk if (cs >= ce) "" else result.stdout[cs..ce];
    } else result.stdout;

    var buf = std.array_list.Managed(u8).init(allocator);
    defer buf.deinit();
    buf.appendSlice("{\"content\":\"") catch return ToolResult.fail("Error: OOM");
    escapeTaskString(&buf, content) catch return ToolResult.fail("Error: OOM");
    buf.appendSlice("\",\"agent\":\"") catch return ToolResult.fail("Error: OOM");
    escapeTaskString(&buf, agent) catch return ToolResult.fail("Error: OOM");
    buf.appendSlice("\"}") catch return ToolResult.fail("Error: OOM");
    return ToolResult.ok(buf.toOwnedSlice() catch "Error: OOM");
}

pub fn renderResult(allocator: std.mem.Allocator, stdout: *std.Io.Writer, json_str: []const u8) !void {
    if (!std.mem.startsWith(u8, json_str, "{")) return stdout.print("  → {s}\n", .{json_str});
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, json_str, .{}) catch {
        return stdout.print("  → {s}\n", .{json_str});
    };
    defer parsed.deinit();
    const obj = parsed.value.object;
    const agent = if (obj.get("agent")) |v| if (v == .string) v.string else "" else "";
    const content = if (obj.get("content")) |v| if (v == .string) v.string else "" else "";
    if (agent.len > 0) try stdout.print("  [{s}]\n", .{agent});
    if (content.len > 0) {
        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |ln| {
            try stdout.print("  | {s}\n", .{std.mem.trimEnd(u8, ln, "\r")});
        }
    }
}

fn escapeTaskString(buf: *std.array_list.Managed(u8), s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice("\\\""),
            '\\' => try buf.appendSlice("\\\\"),
            '\n' => try buf.appendSlice("\\n"),
            '\r' => try buf.appendSlice("\\r"),
            '\t' => try buf.appendSlice("\\t"),
            0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f => {
                var hex_buf: [6]u8 = undefined;
                const hex = try std.fmt.bufPrint(&hex_buf, "\\u00{x:0>2}", .{@as(u8, c)});
                try buf.appendSlice(hex);
            },
            else => try buf.append(c),
        }
    }
}

test "task execute: missing agent returns error" {
    const testing = std.testing;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{}", .{});
    defer parsed.deinit();
    const tr = execute(testing.allocator, testing.io, parsed.value);
    defer testing.allocator.free(tr.output);
    try testing.expect(!tr.success);
    try testing.expect(std.mem.startsWith(u8, tr.output, "Error:"));
}

test "task execute: empty files array does not crash" {
    const testing = std.testing;
    const json_str = "{\"agent\":\"explore\",\"task\":\"test\",\"files\":[]}";
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json_str, .{});
    defer parsed.deinit();
    const tr = execute(testing.allocator, testing.io, parsed.value);
    defer testing.allocator.free(tr.output);
    try testing.expect(!tr.success);
}

test "task execute: nonexistent file in files is handled gracefully" {
    const testing = std.testing;
    const a = testing.allocator;
    const json_str = try std.fmt.allocPrint(a, "{{\"agent\":\"explore\",\"task\":\"test\",\"files\":[\"{s}\"]}}", .{"nonexistent-task-file-xyz"});
    defer a.free(json_str);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, json_str, .{});
    defer parsed.deinit();
    const tr = execute(a, testing.io, parsed.value);
    defer a.free(tr.output);
    try testing.expect(!tr.success);
}

test "task execute: missing task returns error" {
    const testing = std.testing;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{\"agent\": \"worker\"}", .{});
    defer parsed.deinit();
    const tr = execute(testing.allocator, testing.io, parsed.value);
    defer testing.allocator.free(tr.output);
    try testing.expect(!tr.success);
    try testing.expect(std.mem.startsWith(u8, tr.output, "Error:"));
}
