const std = @import("std");
const types = @import("types.zig");
const ansi = @import("ansi.zig");
const compact = @import("compact.zig");
const session = @import("session.zig");
const hook = @import("hook.zig");
const signal = @import("signal.zig");
const Cli = @import("Cli.zig");
const tool_json = @import("tool/json.zig");
const registry = @import("tool/registry.zig");
const permission = @import("permission.zig");
const provider = @import("provider.zig");
const retry = @import("provider/retry.zig");
const picker = @import("picker.zig");

/// Allocate a 1-element ContentPart array wrapping text content.
/// Caller owns returned slice, must free.
fn allocContent(allocator: std.mem.Allocator, text: []const u8) ![]const types.ContentPart {
    const arr = try allocator.alloc(types.ContentPart, 1);
    arr[0] = .{ .text = text };
    return arr;
}

/// Allocate a 1-element ContentPart array wrapping a tool_result.
/// Caller owns returned slice, must free.
fn allocContentTool(allocator: std.mem.Allocator, text: []const u8, id: []const u8, name: []const u8, duration_ms: u32, is_error: bool) ![]const types.ContentPart {
    const arr = try allocator.alloc(types.ContentPart, 1);
    arr[0] = .{ .tool_result = .{
        .id = id, .content = text,
        .is_error = is_error,
        .name = name, .duration_ms = duration_ms,
    } };
    return arr;
}

/// Print a tool call invocation line and its arguments in a structured format.
fn printToolCall(stdout: *std.Io.Writer, allocator: std.mem.Allocator, name: []const u8, args_json: []const u8) !void {
    try stdout.print("{s}[工具]{s} {s}\n", .{ ansi.C.yellow, ansi.C.reset, name });

    if (std.mem.eql(u8, name, "write_file")) {
        var parsed_val = std.json.parseFromSlice(std.json.Value, allocator, args_json, .{}) catch {
            try stdout.print("  {s}\n", .{args_json});
            return;
        };
        defer parsed_val.deinit();
        const parsed = parsed_val.value;
        const obj = parsed.object;
        if (obj.get("path")) |p| {
            try stdout.writeAll("  path: ");
            try tool_json.prettyPrint(stdout, p, 4);
            try stdout.writeByte('\n');
        }
        if (obj.get("content")) |c| {
            if (c == .string) {
                try stdout.writeAll("  content:\n");
                var lines = std.mem.splitScalar(u8, c.string, '\n');
                while (lines.next()) |ln| {
                    try stdout.print("  | {s}\n", .{std.mem.trimEnd(u8, ln, "\r")});
                }
            }
        }
        return;
    }

    if (std.mem.eql(u8, name, "task")) {
        var parsed_val = std.json.parseFromSlice(std.json.Value, allocator, args_json, .{}) catch {
            try stdout.print("  {s}\n", .{args_json});
            return;
        };
        defer parsed_val.deinit();
        const parsed = parsed_val.value;
        const obj = parsed.object;
        if (obj.get("agent")) |a| {
            try stdout.writeAll("  agent: ");
            try tool_json.prettyPrint(stdout, a, 4);
            try stdout.writeByte('\n');
        }
        if (obj.get("task")) |t| {
            if (t == .string) {
                try stdout.writeAll("  task: ");
                try stdout.print("{s}\n", .{t.string});
            }
        }
        return;
    }

    if (std.mem.eql(u8, name, "ask_user")) {
        var parsed_val = std.json.parseFromSlice(std.json.Value, allocator, args_json, .{}) catch {
            try stdout.print("  {s}\n", .{args_json});
            return;
        };
        defer parsed_val.deinit();
        const parsed = parsed_val.value;
        if (parsed.object.get("question")) |q| {
            if (q == .string) {
                try stdout.print("  question: {s}\n", .{q.string});
            }
        }
        return;
    }

    var parsed_val = std.json.parseFromSlice(std.json.Value, allocator, args_json, .{}) catch {
        try stdout.print("  {s}\n", .{args_json});
        return;
    };
    defer parsed_val.deinit();
    const parsed = parsed_val.value;
    if (parsed == .object) {
        var it = parsed.object.iterator();
        while (it.next()) |entry| {
            try stdout.print("  {s}: ", .{entry.key_ptr.*});
            try tool_json.prettyPrint(stdout, entry.value_ptr.*, 4);
            try stdout.print("\n", .{});
        }
    } else {
        try stdout.writeAll("  ");
        try tool_json.prettyPrint(stdout, parsed, 2);
        try stdout.writeByte('\n');
    }
}

/// Print a tool result in a structured format, handling known tool types with special formatting.
fn printToolResult(allocator: std.mem.Allocator, stdout: *std.Io.Writer, tool_name: []const u8, json_str: []const u8) !void {
    if (!std.mem.startsWith(u8, json_str, "{")) {
        try stdout.print("  {s}→{s} {s}\n", .{ ansi.C.green, ansi.C.reset, json_str });
        return;
    }
    var parsed_val = std.json.parseFromSlice(std.json.Value, allocator, json_str, .{}) catch {
        try stdout.print("  {s}→{s} {s}\n", .{ ansi.C.green, ansi.C.reset, json_str });
        return;
    };
    defer parsed_val.deinit();
    const parsed = parsed_val.value;
    const obj = parsed.object;

    if (std.mem.eql(u8, tool_name, "bash")) {
        const exit_code = if (obj.get("exit_code")) |v| @as(i32, @intCast(v.integer)) else -1;
        const so = if (obj.get("stdout")) |v| if (v == .string) v.string else "" else "";
        const se = if (obj.get("stderr")) |v| if (v == .string) v.string else "" else "";
        const icon = if (exit_code == 0) "✓" else "✗";
        try stdout.print("  {s}{s}{s} exit:{d}\n", .{ if (exit_code == 0) ansi.C.green else ansi.C.red, icon, ansi.C.reset, exit_code });
        if (so.len > 0) {
            var lines = std.mem.splitScalar(u8, so, '\n');
            while (lines.next()) |ln| {
                const trimmed = std.mem.trim(u8, ln, "\r");
                if (trimmed.len > 0) try stdout.print("  | {s}\n", .{trimmed});
            }
        }
        if (se.len > 0) {
            try stdout.print("  stderr:\n", .{});
            var lines = std.mem.splitScalar(u8, se, '\n');
            while (lines.next()) |ln| {
                try stdout.print("  | {s}\n", .{std.mem.trimEnd(u8, ln, "\r")});
            }
        }
        return;
    }
    if (std.mem.eql(u8, tool_name, "write_file")) {
        const path = if (obj.get("path")) |v| if (v == .string) v.string else "" else "";
        const bytes = if (obj.get("bytes")) |v| @as(u64, @intCast(@max(v.integer, 0))) else 0;
        const preview = if (obj.get("content_preview")) |v| if (v == .string) v.string else "" else "";
        try stdout.print("  ✓ {d} bytes → {s}\n", .{ bytes, path });
        if (preview.len > 0) {
            var lines = std.mem.splitScalar(u8, preview, '\n');
            while (lines.next()) |ln| {
                try stdout.print("  | {s}\n", .{std.mem.trimEnd(u8, ln, "\r")});
            }
        }
        return;
    }
    if (std.mem.eql(u8, tool_name, "edit_file")) {
        const path = if (obj.get("path")) |v| if (v == .string) v.string else "" else "";
        const replacements = if (obj.get("replacements")) |v| @as(u64, @intCast(@max(v.integer, 0))) else 0;
        try stdout.print("  ✓ {d} 处替换 → {s}\n", .{ replacements, path });
        return;
    }
    if (std.mem.eql(u8, tool_name, "glob")) {
        const pat = if (obj.get("pattern")) |v| if (v == .string) v.string else "" else "";
        const count = if (obj.get("count")) |v| @as(u64, @intCast(@max(v.integer, 0))) else 0;
        try stdout.print("  ✓ {d} matches for '{s}'\n", .{ count, pat });
        if (obj.get("matches")) |m| {
            if (m == .array) {
                for (m.array.items) |match| {
                    if (match == .string) try stdout.print("    {s}\n", .{match.string});
                }
            }
        }
        return;
    }
    if (std.mem.eql(u8, tool_name, "grep")) {
        const pat = if (obj.get("pattern")) |v| if (v == .string) v.string else "" else "";
        const count = if (obj.get("count")) |v| @as(u64, @intCast(@max(v.integer, 0))) else 0;
        try stdout.print("  ✓ {d} matches for '{s}'\n", .{ count, pat });
        if (obj.get("matches")) |m| {
            if (m == .array) {
                for (m.array.items) |match| {
                    if (match == .string) try stdout.print("    {s}\n", .{match.string});
                }
            }
        }
        return;
    }
    if (std.mem.eql(u8, tool_name, "ask_user")) {
        const q = if (obj.get("question")) |v| if (v == .string) v.string else "" else "";
        const a = if (obj.get("answer")) |v| if (v == .string) v.string else "" else "";
        try stdout.print("  Q: {s}\n  A: {s}\n", .{ q, a });
        return;
    }

    try stdout.writeAll("  ");
    try tool_json.prettyPrint(stdout, parsed, 2);
    try stdout.writeByte('\n');
}

/// Sleep for up to `ms` milliseconds, checking for Ctrl+C every 100ms slice.
/// Returns early if signal.isCancelled() becomes true.
/// Source: docs/PLAN-RETRY.md — interruptible sleep with 100ms polling slices.
fn interruptibleSleep(ms: u64) void {
    const slice_ms: u64 = 100;
    var elapsed: u64 = 0;
    while (elapsed < ms) {
        if (signal.isCancelled()) return;
        const remaining = ms - elapsed;
        const sleep_ms = @min(remaining, slice_ms);
        Cli.sleepMs(@as(u64, @intCast(sleep_ms)));
        elapsed += sleep_ms;
    }
}

/// Call provider.chatCompletionStreaming with up to 3 retries on transient errors.
/// Returns on success or error.Interrupted/error.ApiError immediately.
/// Uses retry.zig for backoff computation and error classification.
/// Does not allocate beyond provider internals.
pub fn callWithRetry(prov: provider.Provider, allocator: std.mem.Allocator, io: std.Io, messages: []const types.Message, stdout: *std.Io.Writer) !types.ChatResponse {
    const max_retries: u32 = 3;
    var last_err: ?anyerror = null;

    // Reset signal flag before starting retry loop
    signal.reset();

    for (0..max_retries) |i| {
        if (i > 0) {
            // Check if Ctrl+C was pressed before waiting
            if (signal.isCancelled()) return error.Interrupted;

            const delay_ms = retry.computeBackoff(@as(u32, @intCast(i - 1)), null);
            try stdout.print("\n{s}[重试]{s} 第 {d}/{d} 次，等待 {d}s...\n", .{
                ansi.C.yellow, ansi.C.reset, i + 1, max_retries, delay_ms / 1000,
            });
            try stdout.flush();

            // Interruptible sleep: 100ms slices, checking signal
            interruptibleSleep(delay_ms);

            // If cancelled during sleep, don't proceed with retry
            if (signal.isCancelled()) return error.Interrupted;
        }

        const response = prov.chatCompletionStreaming(allocator, io, messages, stdout) catch |err| {
            if (err == error.Interrupted) return error.Interrupted;

            // Classify the error from stored details
            const kind = retry.classify(retry.last_status_code, retry.last_error_body);
            retry.last_status_code = 0;
            retry.last_error_body = "";

            if (!retry.isRetryable(kind)) {
                try stdout.print("\n{s}[错误]{s} {s}\n", .{
                    ansi.C.red, ansi.C.reset,
                    retry.friendlyMessage(kind, "current model"),
                });
                try stdout.flush();
                return error.ApiError;
            }

            last_err = err;
            continue;
        };
        return response;
    }
    return last_err.?;
}

/// Core agent decision loop: run tool calls up to 10 rounds, handle compaction,
/// permission checks, hooks, and result rendering. Messages/sm are mutated in place.
pub fn agentLoop(
    allocator: std.mem.Allocator,
    io: std.Io,
    stdout: *std.Io.Writer,
    prov: provider.Provider,
    reg: registry.Registry,
    perm: *permission.Permission,
    sm: *session.SessionManager,
    messages: *std.array_list.Managed(types.Message),
    context_limit: u32,
    max_tokens: u32,
    agent_mode: bool,
    result_marker: ?[]const u8,
    trust: bool,
    debug_logging: bool,
    project_root: []const u8,
) !void {
    _ = debug_logging;
    var tool_rounds: u32 = 0;
    var actual_total_tokens: ?u32 = null;
    while (tool_rounds < 10) : (tool_rounds += 1) {
        const compact_result = try compact.compact(allocator, io, prov, messages, context_limit, max_tokens, stdout);
        if (compact_result) |info| {
            try stdout.print("\n{s}[压缩]{s} 保留 {d} 条消息, 生成摘要 ({d} 条丢弃)\n", .{ ansi.C.cyan, ansi.C.reset, info.keep_count, info.dropped_count });
            try stdout.flush();
            try sm.appendCompaction(info.summary, info.keep_count, info.tokens_before);
            try sm.flushFile();
        }

        const response = callWithRetry(prov, allocator, io, messages.items, stdout) catch |err| {
            if (err == error.Interrupted) {
                try stdout.print("\n{s}[中断]{s} 操作被用户取消\n", .{ ansi.C.yellow, ansi.C.reset });
                try stdout.flush();
                signal.reset();
                return;
            }
            try stdout.print("\n{s}[错误]{s} API 调用失败: {}，已重试 3 次\n", .{ ansi.C.red, ansi.C.reset, err });
            try stdout.flush();
            return;
        };
        if (response.usage) |u| actual_total_tokens = u.total_tokens;
        try stdout.print("\n", .{});
        try stdout.flush();

        if (response.tool_calls) |tcs| {
            const now_ns = std.Io.Clock.Timestamp.now(io, .real).raw.nanoseconds;
            const assistant_msg = types.Message{
                .role = .assistant, .content = null, .tool_calls = tcs,
                .reasoning = response.reasoning, .timestamp_ns = now_ns,
            };
            try messages.append(assistant_msg);
            try sm.appendMessage(messages.items[messages.items.len - 1]);
            if (!sm.flushed) try sm.flushFile();

            for (tcs) |tc| {
                try printToolCall(stdout, allocator, tc.name, tc.arguments);
                try stdout.flush();
                if (std.mem.eql(u8, tc.name, "task")) {
                    if (std.json.parseFromSlice(std.json.Value, allocator, tc.arguments, .{})) |parsed_val| {
                        defer parsed_val.deinit();
                        const parsed = parsed_val.value;
                        if (parsed.object.get("agent")) |a| {
                            try stdout.print("  {s}[{s}]{s} 正在执行任务...\n", .{ ansi.C.cyan, a.string, ansi.C.reset });
                            try stdout.flush();
                        }
                    } else |_| {}
                }
                const start_ns = std.Io.Clock.Timestamp.now(io, .real).raw.nanoseconds;
                var result: []const u8 = undefined;
                var skip_result: ?[]const u8 = null;
                var is_error: bool = false;

                const is_modify = std.mem.eql(u8, tc.name, "write_file") or std.mem.eql(u8, tc.name, "edit_file") or std.mem.eql(u8, tc.name, "bash") or std.mem.eql(u8, tc.name, "task");
                if (is_modify) {
                    const hook_payload = std.fmt.allocPrint(allocator, "{{\"tool\":\"{s}\",\"args\":{s}}}", .{ tc.name, tc.arguments }) catch null;
                    if (hook_payload) |payload| {
                        defer allocator.free(payload);
                        if (!hook.runIntercept(allocator, io, project_root, "pre_tool_use", payload, stdout)) {
                            skip_result = std.fmt.allocPrint(allocator, "Error: hook blocked {s}", .{tc.name}) catch "Error: blocked";
                            result = skip_result.?;
                            is_error = true;
                            const end_ns = std.Io.Clock.Timestamp.now(io, .real).raw.nanoseconds;
                            const duration_ms = @as(u32, @intCast(@divFloor(end_ns - start_ns, 1_000_000)));
                            const tool_content = try allocContentTool(allocator, result, tc.id, tc.name, duration_ms, is_error);
                            const tool_msg = types.Message{ .role = .tool, .tool_call_id = tc.id, .content = tool_content, .timestamp_ns = end_ns };
                            try messages.append(tool_msg);
                            try sm.appendMessage(messages.items[messages.items.len - 1]);
                            continue;
                        }
                    }
                }
                if (std.mem.eql(u8, tc.name, "write_file") or std.mem.eql(u8, tc.name, "edit_file")) {
                    const parsed = if (std.json.parseFromSlice(std.json.Value, allocator, tc.arguments, .{})) |v| v else |_| null: {
                        break :null null;
                    };
                    defer if (parsed) |p| p.deinit();
                    const tool_path = if (parsed) |p| blk: {
                        break :blk if (p.value.object.get("path")) |path_val| if (path_val == .string) path_val.string else "" else "";
                    } else "";
                    const path_dup = try allocator.dupe(u8, tool_path);
                    defer allocator.free(path_dup);
                    const action = perm.check(tc.name, path_dup, null, trust);
                    switch (action) {
                        .deny => {
                            skip_result = std.fmt.allocPrint(allocator, "Error: permission denied for {s} on '{s}'", .{ tc.name, path_dup }) catch "Error: denied";
                            result = skip_result.?;
                            is_error = true;
                        },
                        .allow => {
                            const tool_result = reg.execute(allocator, io, tc);
                            result = tool_result.output;
                            is_error = !tool_result.success;
                        },
                        .confirm => {
                            try stdout.print("  {s}[确认]{s} {s}\n", .{ ansi.C.yellow, ansi.C.reset, path_dup });
                            try stdout.flush();
                            const choice = picker.select(allocator, io, stdout, "  执行?", &.{"是(Y)", "否(N)"}, 1) catch null;
                            if (choice == null or choice.? == 1) {
                                skip_result = std.fmt.allocPrint(allocator, "Error: user declined {s} on '{s}'", .{ tc.name, path_dup }) catch "Error: user declined";
                                result = skip_result.?;
                                is_error = true;
                            } else {
                                const tool_result = reg.execute(allocator, io, tc);
                                result = tool_result.output;
                                is_error = !tool_result.success;
                            }
                        },
                    }
                } else if (std.mem.eql(u8, tc.name, "bash")) {
                    const action = if (std.json.parseFromSlice(std.json.Value, allocator, tc.arguments, .{})) |parsed_val| blk: {
                        defer parsed_val.deinit();
                        const cmd = if (parsed_val.value.object.get("command")) |c| if (c == .string) c.string else "" else "";
                        break :blk perm.check(tc.name, null, cmd, trust);
                    } else |_|
                        perm.check(tc.name, null, null, trust)
                    ;
                    switch (action) {
                        .deny => {
                            skip_result = "Error: permission denied for bash";
                            result = skip_result.?;
                            is_error = true;
                        },
                        .allow, .confirm => {
                            const tool_result = reg.execute(allocator, io, tc);
                            result = tool_result.output;
                            is_error = !tool_result.success;
                        },
                    }
                } else if (std.mem.eql(u8, tc.name, "task")) {
                    const action = perm.check(tc.name, null, null, trust);
                    switch (action) {
                        .deny => {
                            skip_result = "Error: permission denied for task";
                            result = skip_result.?;
                            is_error = true;
                        },
                        .allow, .confirm => {
                            const tool_result = reg.execute(allocator, io, tc);
                            result = tool_result.output;
                            is_error = !tool_result.success;
                        },
                    }
                } else {
                    const tool_result = reg.execute(allocator, io, tc);
                    result = tool_result.output;
                    is_error = !tool_result.success;
                }
                const end_ns = std.Io.Clock.Timestamp.now(io, .real).raw.nanoseconds;
                const duration_ms = @as(u32, @intCast(@divFloor(end_ns - start_ns, 1_000_000)));
                if (is_error) {
                    try stdout.print("  {s}→ {s}{s}\n", .{ ansi.C.red, result, ansi.C.reset });
                } else if (reg.findHandler(tc.name)) |h| {
                    if (h.renderResult) |rr| {
                        rr(allocator, stdout, result) catch {};
                    } else {
                        printToolResult(allocator, stdout, tc.name, result) catch {};
                    }
                } else {
                    printToolResult(allocator, stdout, tc.name, result) catch {};
                }
                try stdout.flush();
                const tool_content = try allocContentTool(allocator, result, tc.id, tc.name, duration_ms, is_error);
                const tool_msg = types.Message{
                    .role = .tool, .tool_call_id = tc.id, .content = tool_content, .timestamp_ns = end_ns,
                };
                try messages.append(tool_msg);
                try sm.appendMessage(messages.items[messages.items.len - 1]);

                if (std.mem.eql(u8, tc.name, "read_file")) {
                    if (std.json.parseFromSlice(std.json.Value, allocator, result, .{})) |parsed_val| {
                        defer parsed_val.deinit();
                        const parsed = parsed_val.value;
                        if (parsed.object.get("image")) |img_val| {
                            if (img_val != .null) {
                                const uri = try allocator.dupe(u8, img_val.string);
                                const img_part = types.ContentPart{ .image_url = .{ .url = uri } };
                                const img_parts = try allocator.alloc(types.ContentPart, 1);
                                img_parts[0] = img_part;
                                const img_msg = types.Message{
                                    .role = .user, .content = img_parts, .timestamp_ns = end_ns,
                                };
                                try messages.append(img_msg);
                                try sm.appendMessage(messages.items[messages.items.len - 1]);
                            }
                        }
                    } else |_| {}
                }
                if (std.fmt.allocPrint(allocator, "{{\"tool\":\"{s}\",\"duration_ms\":{d}}}", .{ tc.name, duration_ms })) |hook_payload| {
                    defer allocator.free(hook_payload);
                    hook.run(allocator, io, project_root, "post_tool_use", hook_payload, stdout);
                } else |_| {}
            }
            continue;
        }

        if (response.content) |content| {
            if (agent_mode) {
                if (result_marker) |mk| {
                    try stdout.print("\n[ZAGENT_RESULT:{s}]{s}[ZAGENT_END:{s}]\n", .{ mk, content, mk });
                } else {
                    try stdout.print("\n[ZAGENT_RESULT]{s}[ZAGENT_END]\n", .{content});
                }
            }
            const assistant_content = try allocator.dupe(u8, content);
            errdefer allocator.free(assistant_content);
            const reply_msg = types.Message{
                .role = .assistant, .content = try allocContent(allocator, assistant_content),
                .reasoning = response.reasoning,
                .timestamp_ns = std.Io.Clock.Timestamp.now(io, .real).raw.nanoseconds,
            };
            try messages.append(reply_msg);
            try sm.appendMessage(messages.items[messages.items.len - 1]);
            if (!sm.flushed) try sm.flushFile();
        }
        return;
    }

    // Max tool rounds reached: inject a final message to force a text response
    const max_steps_msg = try allocContent(allocator, "已达工具调用上限（10 轮）。工具已禁用，请等待用户输入后继续。现在必须以纯文本回复：总结已完成的工作、列出未完成的任务、建议下一步操作。");
    const limit_msg = types.Message{ .role = .assistant, .content = max_steps_msg, .timestamp_ns = std.Io.Clock.Timestamp.now(io, .real).raw.nanoseconds };
    try messages.append(limit_msg);
    try sm.appendMessage(messages.items[messages.items.len - 1]);
    if (!sm.flushed) try sm.flushFile();

    const final_response = callWithRetry(prov, allocator, io, messages.items, stdout) catch |err| {
        const tag = if (err == error.Interrupted) "中断" else "错误";
        try stdout.print("\n{s}[{s}]{s} 工具调用次数已达上限，{s}\n", .{ ansi.C.yellow, tag, ansi.C.reset, if (err == error.Interrupted) "用户已取消" else "但无法生成摘要" });
        try stdout.flush();
        return;
    };
    if (final_response.usage) |u| actual_total_tokens = u.total_tokens;

    if (final_response.content) |content| {
        if (agent_mode) {
            if (result_marker) |mk| {
                try stdout.print("\n[ZAGENT_RESULT:{s}]{s}[ZAGENT_END:{s}]\n", .{ mk, content, mk });
            } else {
                try stdout.print("\n[ZAGENT_RESULT]{s}[ZAGENT_END]\n", .{content});
            }
        }
        const assistant_content = try allocator.dupe(u8, content);
        errdefer allocator.free(assistant_content);
        const reply_msg = types.Message{
            .role = .assistant, .content = try allocContent(allocator, assistant_content),
            .reasoning = final_response.reasoning,
            .timestamp_ns = std.Io.Clock.Timestamp.now(io, .real).raw.nanoseconds,
        };
        try messages.append(reply_msg);
        try sm.appendMessage(messages.items[messages.items.len - 1]);
        if (!sm.flushed) try sm.flushFile();
    }

    try stdout.print("\n{s}[告警]{s} 工具调用次数已达上限（{d} 轮），部分工作可能未完成\n", .{ ansi.C.yellow, ansi.C.reset, tool_rounds });
    try stdout.flush();
}
