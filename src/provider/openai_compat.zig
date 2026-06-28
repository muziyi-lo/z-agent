const std = @import("std");
const builtin = @import("builtin");
const types = @import("../types.zig");
const ansi = @import("../ansi.zig");
const sse = @import("../sse.zig");
const common = @import("common.zig");
const registry = @import("registry.zig");
const signal = @import("../signal.zig");
const root_dir = @import("../tool/root_dir.zig");

// ---------------------------------------------------------------------------
// Vendor detection
// ---------------------------------------------------------------------------

pub const Vendor = enum {
    deepseek,
    minimax,
    standard,
};

/// Extract hostname from a base_url string and compare with given host.
/// Supports: https://host, http://host, host, host:port, host/path
fn matchesHost(base_url: []const u8, host: []const u8) bool {
    var url = base_url;
    // Strip protocol prefix
    if (std.mem.startsWith(u8, url, "https://")) {
        url = url["https://".len..];
    } else if (std.mem.startsWith(u8, url, "http://")) {
        url = url["http://".len..];
    }

    // Extract hostname (before first '/', ':', or end)
    const hostname = if (std.mem.indexOfAny(u8, url, "/:")) |pos|
        url[0..pos]
    else
        url;

    return std.mem.eql(u8, hostname, host);
}

pub fn detectVendor(base_url: []const u8) Vendor {
    if (matchesHost(base_url, "api.deepseek.com")) return .deepseek;
    if (matchesHost(base_url, "api.minimaxi.com")) return .minimax;
    return .standard;
}

// ---------------------------------------------------------------------------
// Model spec (combined from deepseek.zig and openai.zig)
// ---------------------------------------------------------------------------

pub fn modelSpec(name: []const u8) ?types.ModelSpec {
    const known = comptime [_]struct { name_or_prefix: []const u8, spec: types.ModelSpec, exact: bool }{
        // DeepSeek models (exact match)
        .{ .name_or_prefix = "deepseek-v4-flash", .spec = .{ .context_limit = 1048576, .max_output = 393216 }, .exact = true },
        .{ .name_or_prefix = "deepseek-v4-pro", .spec = .{ .context_limit = 1048576, .max_output = 393216 }, .exact = true },
        // Open-source / local models (prefix match)
        .{ .name_or_prefix = "llama3.1", .spec = .{ .context_limit = 131072, .max_output = 131072 }, .exact = false },
        .{ .name_or_prefix = "llama3", .spec = .{ .context_limit = 131072, .max_output = 131072 }, .exact = false },
        .{ .name_or_prefix = "qwen2.5", .spec = .{ .context_limit = 131072, .max_output = 131072 }, .exact = false },
        .{ .name_or_prefix = "qwen2", .spec = .{ .context_limit = 131072, .max_output = 131072 }, .exact = false },
        .{ .name_or_prefix = "mistral", .spec = .{ .context_limit = 32768, .max_output = 32768 }, .exact = false },
        .{ .name_or_prefix = "mixtral", .spec = .{ .context_limit = 32768, .max_output = 32768 }, .exact = false },
        .{ .name_or_prefix = "gemma2", .spec = .{ .context_limit = 8192, .max_output = 8192 }, .exact = false },
        .{ .name_or_prefix = "gemma", .spec = .{ .context_limit = 8192, .max_output = 8192 }, .exact = false },
        .{ .name_or_prefix = "codellama", .spec = .{ .context_limit = 16384, .max_output = 16384 }, .exact = false },
        .{ .name_or_prefix = "deepseek-coder", .spec = .{ .context_limit = 16384, .max_output = 16384 }, .exact = false },
        .{ .name_or_prefix = "phi3", .spec = .{ .context_limit = 4096, .max_output = 4096 }, .exact = false },
        .{ .name_or_prefix = "phi4", .spec = .{ .context_limit = 16384, .max_output = 16384 }, .exact = false },
    };
    inline for (known) |entry| {
        if (entry.exact) {
            if (std.mem.eql(u8, name, entry.name_or_prefix)) return entry.spec;
        } else {
            if (std.mem.startsWith(u8, name, entry.name_or_prefix)) return entry.spec;
        }
    }
    return null;
}

// ---------------------------------------------------------------------------
// Provider interface
// ---------------------------------------------------------------------------

pub fn create(config: types.ModelConfig, tools: ?[]const types.Tool, debug_logging: bool, arena: std.mem.Allocator) registry.Provider {
    const vendor = detectVendor(config.base_url);
    // Arena is process-level; OOM here is unrecoverable
    const client = arena.create(OpenAICompatClient) catch @panic("OOM");
    client.* = .{
        .config = config,
        .allocator = arena,
        .tools = tools,
        .debug_logging = debug_logging,
        .vendor = vendor,
    };
    return registry.Provider{ .ptr = client, .vtable = &vtable };
}

const vtable = registry.Provider.VTable{
    .chatCompletionStreaming = streamingImpl,
    .setModel = setModelImpl,
};

fn streamingImpl(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, messages: []const types.Message, out_writer: *std.Io.Writer) anyerror!types.ChatResponse {
    const self: *OpenAICompatClient = @ptrCast(@alignCast(ptr));
    return self.chatCompletionStreaming(allocator, io, messages, out_writer);
}

fn setModelImpl(ptr: *anyopaque, model: []const u8) void {
    const self: *OpenAICompatClient = @ptrCast(@alignCast(ptr));
    self.config.model = self.allocator.dupe(u8, model) catch return;
}

// ---------------------------------------------------------------------------
// Client implementation
// ---------------------------------------------------------------------------

pub const OpenAICompatClient = struct {
    config: types.ModelConfig,
    allocator: std.mem.Allocator,
    tools: ?[]const types.Tool = null,
    debug_logging: bool = false,
    vendor: Vendor = .standard,

    pub fn chatCompletionStreaming(
        self: *OpenAICompatClient,
        allocator: std.mem.Allocator,
        io: std.Io,
        messages: []const types.Message,
        out_writer: *std.Io.Writer,
    ) !types.ChatResponse {
        const url = if (std.mem.endsWith(u8, self.config.base_url, "/chat/completions"))
            try allocator.dupe(u8, self.config.base_url)
        else
            try std.fmt.allocPrint(allocator, "{s}/chat/completions", .{self.config.base_url});
        defer allocator.free(url);

        const body_str = try self.buildJsonBody(allocator, messages, true);
        defer allocator.free(body_str);

        // Debug logging: write z-request.log
        if (self.debug_logging and root_dir.project_root.len > 0) {
            if (std.fs.path.join(allocator, &.{ root_dir.project_root, ".zagent", "logs" })) |log_dir| {
                defer allocator.free(log_dir);
                std.Io.Dir.cwd().createDirPath(io, log_dir) catch {};
                if (std.fs.path.join(allocator, &.{ log_dir, "z-request.log" })) |log_path| {
                    defer allocator.free(log_path);
                    if (std.Io.Dir.cwd().createFile(io, log_path, .{})) |reqlog| {
                        defer reqlog.close(io);
                        const redacted = self.redactApiKey(allocator, body_str);
                        defer if (redacted.len > 0) allocator.free(redacted);
                        if (redacted.len > 0) {
                            _ = reqlog.writeStreamingAll(io, redacted) catch {};
                        } else {
                            _ = reqlog.writeStreamingAll(io, body_str) catch {};
                        }
                    } else |_| {}
                } else |_| {}
            } else |_| {}
        }

        // Build curl args
        const has_auth = self.config.api_key.len > 0;
        const auth = if (has_auth) try std.fmt.allocPrint(allocator, "Authorization: Bearer {s}", .{self.config.api_key}) else "";
        defer if (has_auth) allocator.free(auth);

        // Build argv dynamically to support optional proxy args
        var argv_builder = std.array_list.Managed([]const u8).init(allocator);
        defer argv_builder.deinit();

        try argv_builder.appendSlice(&.{ "curl.exe", "-sN", "--fail-with-body", "--max-time", "30" });
        try argv_builder.appendSlice(&.{ "-X", "POST", url });
        try argv_builder.appendSlice(&.{ "-H", "Content-Type: application/json" });
        try argv_builder.appendSlice(&.{ "-H", "Accept: application/json" });

        if (has_auth) {
            try argv_builder.appendSlice(&.{ "-H", auth });
        }

        // Apply proxy configuration
        {
            const proxy = &self.config.proxy;
            if (std.mem.eql(u8, proxy.mode, "custom") and proxy.url.len > 0) {
                try argv_builder.appendSlice(&.{ "-x", proxy.url });
            } else if (std.mem.eql(u8, proxy.mode, "off")) {
                try argv_builder.appendSlice(&.{ "--noproxy", "*" });
            }
            // "auto" and "env": curl respects HTTP_PROXY/HTTPS_PROXY env vars, no flags needed
        }

        try argv_builder.appendSlice(&.{ "-d", "@-" });

        var child = try std.process.spawn(io, .{
            .argv = argv_builder.items,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .inherit,
        });
        var child_finished = false;
        defer {
            if (!child_finished) {
                _ = child.wait(io) catch {};
            }
        }

        // Write body to stdin
        {
            const stdin_file = child.stdin orelse return error.NoStdin;
            try stdin_file.writeStreamingAll(io, body_str);
            stdin_file.close(io);
        }

        const stdout_file = child.stdout orelse return error.NoStdout;

        // State for reasoning parsing
        const ReasoningPhase = enum { idle, thinking, reasoning, content, tool_calls };
        var phase: ReasoningPhase = .idle;

        var content_buf = std.array_list.Managed(u8).init(allocator);
        defer content_buf.deinit();
        var reasoning_buf = std.array_list.Managed(u8).init(allocator);
        defer reasoning_buf.deinit();
        var thinking_buf = std.array_list.Managed(u8).init(allocator);
        defer thinking_buf.deinit();

        var tool_calls_buf = std.array_list.Managed(types.ToolCall).init(allocator);
        defer tool_calls_buf.deinit();

        var usage: ?types.Usage = null;

        // Debug output log
        const dbg = if (self.debug_logging and root_dir.project_root.len > 0) blk: {
            const log_dir = std.fs.path.join(allocator, &.{ root_dir.project_root, ".zagent", "logs" }) catch break :blk null;
            defer allocator.free(log_dir);
            std.Io.Dir.cwd().createDirPath(io, log_dir) catch break :blk null;
            const log_path = std.fs.path.join(allocator, &.{ log_dir, "z-debug.log" }) catch break :blk null;
            defer allocator.free(log_path);
            break :blk std.Io.Dir.cwd().createFile(io, log_path, .{}) catch null;
        } else null;
        defer if (dbg) |f| f.close(io);

        // SSE streaming via SseStream
        var stream = sse.SseStream.init(stdout_file, io, allocator);
        defer stream.deinit();

        var seen_first_data = false;

        while (true) {
            if (signal.isCancelled()) {
                child_finished = true;
                if (builtin.os.tag != .windows) {
                    child.kill(io);
                }
                return error.Interrupted;
            }

            const payload = stream.next() catch {
                return error.ReadFailed;
            } orelse break;

            if (!seen_first_data) {
                seen_first_data = true;
            }

            // Debug log raw payload
            if (dbg) |f| {
                _ = f.writeStreamingAll(io, "\n[RAW]") catch {};
                _ = f.writeStreamingAll(io, payload) catch {};
                _ = f.writeStreamingAll(io, "\n") catch {};
            }

            const parsed = std.json.parseFromSliceLeaky(std.json.Value, allocator, payload, .{}) catch continue;

            if (parsed.object.get("error")) |err_val| {
                const msg = if (err_val.object.get("message")) |m| m.string else "unknown error";
                try out_writer.print("\n{s}[API 错误]{s} {s}\n", .{ ansi.C.red, ansi.C.reset, msg });
                try out_writer.flush();
                return error.ApiError;
            }

            const choices = parsed.object.get("choices") orelse continue;
            if (choices.array.items.len == 0) {
                if (parsed.object.get("usage")) |usage_val| {
                    if (usage_val != .null) {
                        usage = common.parseUsage(usage_val) catch null;
                    }
                }
                continue;
            }
            const choice = choices.array.items[0].object;
            const finish_reason = choice.get("finish_reason");
            const delta = choice.get("delta") orelse continue;

            // Vendor-specific reasoning handling
            switch (self.vendor) {
                .deepseek => {
                    // DeepSeek: reasoning_content field in delta
                    if (delta.object.get("reasoning_content")) |r_val| {
                        if (r_val != .null) {
                            const r = r_val.string;
                            if (phase == .idle or phase == .thinking) {
                                try out_writer.print("{s}[思考过程]{s}\n", .{ ansi.C.dim, ansi.C.reset });
                                try out_writer.flush();
                                phase = .reasoning;
                            }
                            try reasoning_buf.appendSlice(r);
                            try out_writer.print("{s}", .{r});
                            try out_writer.flush();
                        }
                    }
                    if (delta.object.get("content")) |c_val| {
                        if (c_val != .null) {
                            const c = c_val.string;
                            if (phase == .reasoning) {
                                try out_writer.print("\n\n", .{});
                                try out_writer.flush();
                            }
                            phase = .content;
                            try content_buf.appendSlice(c);
                            try out_writer.print("{s}", .{c});
                            try out_writer.flush();
                        }
                    }
                },
                .minimax => {
                    // MiniMax: thinking in content via <think> blocks
                    if (delta.object.get("content")) |c_val| {
                        if (c_val != .null) {
                            const c = c_val.string;
                            var remaining = c;
                            while (remaining.len > 0) {
                                if (phase == .idle or phase == .thinking) {
                                    if (std.mem.indexOf(u8, remaining, "<think>")) |think_start| {
                                        // Output any text before <think> as content
                                        if (think_start > 0) {
                                            const before = remaining[0..think_start];
                                            try content_buf.appendSlice(before);
                                            try out_writer.print("{s}", .{before});
                                            try out_writer.flush();
                                        }
                                        remaining = remaining[think_start + "<think>".len..];
                                        if (phase == .idle) {
                                            try out_writer.print("{s}[思考过程]{s}\n", .{ ansi.C.dim, ansi.C.reset });
                                            try out_writer.flush();
                                        }
                                        phase = .thinking;
                                    } else {
                                        // No <think> tag, all content
                                        try content_buf.appendSlice(remaining);
                                        try out_writer.print("{s}", .{remaining});
                                        try out_writer.flush();
                                        phase = .content;
                                        break;
                                    }
                                } else if (phase == .thinking) {
                                    if (std.mem.indexOf(u8, remaining, "</think>")) |think_end| {
                                        const think_text = remaining[0..think_end];
                                        try reasoning_buf.appendSlice(think_text);
                                        try out_writer.print("{s}", .{think_text});
                                        try out_writer.flush();
                                        remaining = remaining[think_end + "</think>".len..];
                                        try out_writer.print("\n\n", .{});
                                        try out_writer.flush();
                                        phase = .content;
                                    } else {
                                        try reasoning_buf.appendSlice(remaining);
                                        try out_writer.print("{s}", .{remaining});
                                        try out_writer.flush();
                                        break;
                                    }
                                } else {
                                    // content phase - just append
                                    try content_buf.appendSlice(remaining);
                                    try out_writer.print("{s}", .{remaining});
                                    try out_writer.flush();
                                    break;
                                }
                            }
                        }
                    }
                },
                .standard => {
                    // Standard OpenAI: simple content, no reasoning
                    if (delta.object.get("content")) |c_val| {
                        if (c_val != .null) {
                            const c = c_val.string;
                            phase = .content;
                            try content_buf.appendSlice(c);
                            try out_writer.print("{s}", .{c});
                            try out_writer.flush();
                        }
                    }
                },
            }

            // Tool calls (same for all vendors)
            if (delta.object.get("tool_calls")) |tc_array| {
                if (phase == .reasoning or phase == .thinking) try out_writer.print("\n\n", .{});
                phase = .tool_calls;
                for (tc_array.array.items) |tc_item| {
                    const tc_obj = tc_item.object;
                    const index_val = tc_obj.get("index").?.integer;
                    if (index_val < 0 or index_val > std.math.maxInt(usize)) continue;
                    const index = @as(usize, @intCast(index_val));
                    while (tool_calls_buf.items.len <= index) {
                        try tool_calls_buf.append(.{
                            .id = try allocator.dupe(u8, ""),
                            .name = try allocator.dupe(u8, ""),
                            .arguments = try allocator.dupe(u8, ""),
                        });
                    }
                    if (tc_obj.get("id")) |id_val| {
                        if (id_val != .null) {
                            allocator.free(tool_calls_buf.items[index].id);
                            tool_calls_buf.items[index].id = try allocator.dupe(u8, id_val.string);
                        }
                    }
                    if (tc_obj.get("function")) |func_val| {
                        const func_obj = func_val.object;
                        if (func_obj.get("name")) |n_val| {
                            if (n_val != .null) {
                                allocator.free(tool_calls_buf.items[index].name);
                                tool_calls_buf.items[index].name = try allocator.dupe(u8, n_val.string);
                            }
                        }
                        if (func_obj.get("arguments")) |a_val| {
                            if (a_val != .null) {
                                const prev = tool_calls_buf.items[index].arguments;
                                tool_calls_buf.items[index].arguments = try std.fmt.allocPrint(allocator, "{s}{s}", .{ prev, a_val.string });
                                allocator.free(prev);
                            }
                        }
                    }
                }
            }

            // Check for finish reason with truncation notice
            if (finish_reason) |fr| {
                if (fr != .null) {
                    if (std.mem.eql(u8, fr.string, "length")) {
                        try out_writer.print("\n{s}[截断]{s} 输出达到上下文/长度上限\n", .{ ansi.C.yellow, ansi.C.reset });
                    }
                }
            }
        }

        child.stdin = null;
        const term = try child.wait(io);
        child_finished = true;

        // If no SSE data was received, the response was not valid SSE.
        // Return ApiError so callWithRetry won't retry auth/permission errors.
        try checkSseExit(seen_first_data, term);

        // Build response
        if (tool_calls_buf.items.len > 0) {
            return types.ChatResponse{
                .content = null,
                .reasoning = if (reasoning_buf.items.len > 0) try reasoning_buf.toOwnedSlice() else null,
                .tool_calls = try tool_calls_buf.toOwnedSlice(),
                .usage = usage,
            };
        }

        return types.ChatResponse{
            .content = try content_buf.toOwnedSlice(),
            .reasoning = if (self.vendor == .minimax and reasoning_buf.items.len > 0)
                try reasoning_buf.toOwnedSlice()
            else if (self.vendor == .deepseek and reasoning_buf.items.len > 0)
                try reasoning_buf.toOwnedSlice()
            else
                null,
            .usage = usage,
        };
    }

    /// Build JSON request body with vendor-specific fields
    fn buildJsonBody(self: *const OpenAICompatClient, allocator: std.mem.Allocator, messages: []const types.Message, stream: bool) ![]u8 {
        var buf = std.array_list.Managed(u8).init(allocator);
        defer buf.deinit();

        try buf.appendSlice("{\"model\":\"");
        try buf.appendSlice(self.config.model);
        try buf.appendSlice("\",\"messages\":[");

        for (messages, 0..) |msg, i| {
            if (i > 0) try buf.appendSlice(",");
            try buf.appendSlice("{\"role\":\"");
            try buf.appendSlice(@tagName(msg.role));
            try buf.appendSlice("\"");

            if (msg.tool_call_id) |id| {
                try buf.appendSlice(",\"tool_call_id\":\"");
                try common.appendEscapedJsonString(&buf, id);
                try buf.appendSlice("\"");
            }

            if (msg.tool_calls) |tcs| {
                try buf.appendSlice(",\"content\":null,\"tool_calls\":[");
                for (tcs, 0..) |tc, j| {
                    if (j > 0) try buf.appendSlice(",");
                    try buf.appendSlice("{\"id\":\"");
                    try common.appendEscapedJsonString(&buf, tc.id);
                    try buf.appendSlice("\",\"type\":\"function\",\"function\":{\"name\":\"");
                    try common.appendEscapedJsonString(&buf, tc.name);
                    try buf.appendSlice("\",\"arguments\":\"");
                    try common.appendEscapedJsonString(&buf, tc.arguments);
                    try buf.appendSlice("\"}}");
                }
                try buf.appendSlice("]");
            } else {
                try buf.appendSlice(",\"content\":");
                if (msg.content) |content| {
                    if (content.len == 1 and content[0] == .text) {
                        try buf.appendSlice("\"");
                        try common.appendEscapedJsonString(&buf, content[0].text);
                        try buf.appendSlice("\"");
                    } else if (content.len == 1 and content[0] == .tool_result) {
                        try buf.appendSlice("\"");
                        try common.appendEscapedJsonString(&buf, content[0].tool_result.content);
                        try buf.appendSlice("\"");
                    } else if (content.len == 1 and content[0] == .image_url) {
                        try buf.appendSlice("[{\"type\":\"image_url\",\"image_url\":{\"url\":\"");
                        try common.appendEscapedJsonString(&buf, content[0].image_url.url);
                        try buf.appendSlice("\"}}]");
                    } else {
                        try serializeMultiPart(&buf, content);
                    }
                } else {
                    try buf.appendSlice("null");
                }
            }

            // DeepSeek-specific: assistant messages include reasoning_content
            if (self.vendor == .deepseek and msg.role == .assistant) {
                try buf.appendSlice(",\"reasoning_content\":\"");
                if (msg.reasoning) |r| try common.appendEscapedJsonString(&buf, r);
                try buf.appendSlice("\"");
            }

            try buf.appendSlice("}");
        }
        try buf.appendSlice("]");

        // Tools
        if (self.tools) |tools| {
            try buf.appendSlice(",\"tools\":[");
            for (tools, 0..) |tool, i| {
                if (i > 0) try buf.appendSlice(",");
                try buf.appendSlice("{\"type\":\"function\",\"function\":{\"name\":\"");
                try common.appendEscapedJsonString(&buf, tool.name);
                try buf.appendSlice("\",\"description\":\"");
                try common.appendEscapedJsonString(&buf, tool.description);
                try buf.appendSlice("\",\"parameters\":");
                try buf.appendSlice(tool.parameters);
                try buf.appendSlice("}}");
            }
            try buf.appendSlice("]");
        }

        // Vendor-specific thinking/reasoning fields
        switch (self.vendor) {
            .deepseek => {
                try buf.appendSlice(",\"thinking\":{\"type\":\"enabled\"}");
                try buf.appendSlice(",\"reasoning_effort\":\"high\"");
            },
            .minimax => {
                try buf.appendSlice(",\"thinking\":{\"type\":\"adaptive\"}");
            },
            .standard => {
                try buf.appendSlice(",\"reasoning_effort\":\"high\"");
            },
        }

        // Max tokens
        try buf.appendSlice(",\"max_tokens\":");
        {
            var num_buf: [16]u8 = undefined;
            const num_str = try std.fmt.bufPrint(&num_buf, "{d}", .{self.config.max_tokens orelse 4096});
            try buf.appendSlice(num_str);
        }

        if (stream) {
            try buf.appendSlice(",\"stream\":true");
            try buf.appendSlice(",\"stream_options\":{\"include_usage\":true}");
        }

        try buf.appendSlice("}");
        return buf.toOwnedSlice();
    }

    /// Redact API key occurrences in a string for safe logging.
    /// Returns an allocated string with key redacted, or empty if no key found / OOM.
    fn redactApiKey(self: *const OpenAICompatClient, allocator: std.mem.Allocator, text: []const u8) []const u8 {
        const key = self.config.api_key;
        if (key.len == 0) return "";
        if (std.mem.indexOf(u8, text, key)) |_| {
            const last4 = if (key.len > 4) key[key.len - 4 ..] else key;
            const replacement = std.fmt.allocPrint(allocator, "sk-...redacted...{s}", .{last4}) catch return "";
            defer allocator.free(replacement);
            var result = std.array_list.Managed(u8).init(allocator);
            defer result.deinit();
            var pos: usize = 0;
            while (std.mem.indexOf(u8, text[pos..], key)) |found| {
                result.appendSlice(text[pos..][0..found]) catch return "";
                result.appendSlice(replacement) catch return "";
                pos += found + key.len;
            }
            result.appendSlice(text[pos..]) catch return "";
            return result.toOwnedSlice() catch "";
        }
        return "";
    }
};

fn serializeMultiPart(buf: *std.array_list.Managed(u8), parts: []const types.ContentPart) !void {
    try buf.appendSlice("[");
    for (parts, 0..) |part, j| {
        if (j > 0) try buf.appendSlice(",");
        switch (part) {
            .text => |t| {
                try buf.appendSlice("{\"type\":\"text\",\"text\":\"");
                try common.appendEscapedJsonString(buf, t);
                try buf.appendSlice("\"}");
            },
            .tool_call => |tc| {
                try buf.appendSlice("{\"type\":\"tool_call\",\"id\":\"");
                try common.appendEscapedJsonString(buf, tc.id);
                try buf.appendSlice("\",\"function\":{\"name\":\"");
                try common.appendEscapedJsonString(buf, tc.name);
                try buf.appendSlice("\",\"arguments\":\"");
                try common.appendEscapedJsonString(buf, tc.arguments);
                try buf.appendSlice("\"}}");
            },
            .tool_result => |tr| {
                try buf.appendSlice("{\"type\":\"tool_result\",\"tool_call_id\":\"");
                try common.appendEscapedJsonString(buf, tr.id);
                try buf.appendSlice("\",\"content\":\"");
                try common.appendEscapedJsonString(buf, tr.content);
                try buf.appendSlice("\"}");
            },
            .image_url => |img| {
                try buf.appendSlice("{\"type\":\"image_url\",\"image_url\":{\"url\":\"");
                try common.appendEscapedJsonString(buf, img.url);
                try buf.appendSlice("\"}}");
            },
        }
    }
    try buf.appendSlice("]");
}

// ---------------------------------------------------------------------------
// Post-SSE exit handling
// ---------------------------------------------------------------------------

/// Check child process exit after SSE streaming.
/// If no SSE data was received (seen_first_data=false) and exit code is non-zero,
/// return ApiError (non-retryable) instead of CurlFailed (which gets retried).
fn checkSseExit(seen_first_data: bool, term: std.process.Child.Term) !void {
    if (!seen_first_data) {
        switch (term) {
            .exited => |code| if (code != 0) return error.ApiError,
            else => return error.ApiError,
        }
    }
    switch (term) {
        .exited => |code| if (code != 0) return error.CurlFailed,
        else => return error.CurlFailed,
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "matchesHost: exact match" {
    const testing = std.testing;
    try testing.expect(matchesHost("https://api.deepseek.com", "api.deepseek.com"));
    try testing.expect(matchesHost("http://api.deepseek.com", "api.deepseek.com"));
    try testing.expect(!matchesHost("https://api.openai.com", "api.deepseek.com"));
}

test "matchesHost: no protocol" {
    const testing = std.testing;
    try testing.expect(matchesHost("api.deepseek.com", "api.deepseek.com"));
    try testing.expect(matchesHost("api.deepseek.com:443", "api.deepseek.com"));
}

test "matchesHost: with path" {
    const testing = std.testing;
    try testing.expect(matchesHost("https://api.deepseek.com/v1", "api.deepseek.com"));
    try testing.expect(matchesHost("https://api.openai.com/v1/chat", "api.openai.com"));
}

test "detectVendor: deepseek" {
    const testing = std.testing;
    try testing.expect(detectVendor("https://api.deepseek.com") == .deepseek);
    try testing.expect(detectVendor("api.deepseek.com") == .deepseek);
}

test "detectVendor: standard for others" {
    const testing = std.testing;
    try testing.expect(detectVendor("https://api.openai.com") == .standard);
    try testing.expect(detectVendor("http://localhost:11434/v1") == .standard);
    try testing.expect(detectVendor("https://api.minimaxi.com") == .minimax);
}

test "modelSpec: known models" {
    const testing = std.testing;
    const s1 = modelSpec("deepseek-v4-flash");
    try testing.expect(s1 != null);
    try testing.expectEqual(@as(u32, 1048576), s1.?.context_limit);
    try testing.expectEqual(@as(u32, 393216), s1.?.max_output);

    const s2 = modelSpec("llama3.1-8b");
    try testing.expect(s2 != null);
    try testing.expect(s2.?.context_limit > 0);
}

test "modelSpec: unknown model returns null" {
    const testing = std.testing;
    try testing.expect(modelSpec("nonexistent-model-v99") == null);
}

test "buildJsonBody: includes vendor thinking fields for deepseek" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const config = types.ModelConfig{
        .api = "deepseek",
        .model = "deepseek-v4-flash",
        .base_url = "https://api.deepseek.com",
        .api_key = "test-key",
    };
    var client = OpenAICompatClient{
        .config = config,
        .allocator = testing.allocator,
        .vendor = .deepseek,
    };
    const messages = [_]types.Message{
        .{ .role = .user, .content = try allocContent(allocator, "hello") },
    };
    const body = try client.buildJsonBody(allocator, &messages, false);
    defer allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "thinking") != null);
    try testing.expect(std.mem.indexOf(u8, body, "reasoning_effort") != null);
    try testing.expect(std.mem.indexOf(u8, body, "enabled") != null);
}

test "buildJsonBody: includes thinking for minimax" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const config = types.ModelConfig{
        .api = "minimax",
        .model = "minimax-model",
        .base_url = "https://api.minimaxi.com",
        .api_key = "test-key",
    };
    var client = OpenAICompatClient{
        .config = config,
        .allocator = testing.allocator,
        .vendor = .minimax,
    };
    const messages = [_]types.Message{
        .{ .role = .user, .content = try allocContent(allocator, "hello") },
    };
    const body = try client.buildJsonBody(allocator, &messages, false);
    defer allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "thinking") != null);
    try testing.expect(std.mem.indexOf(u8, body, "adaptive") != null);
    // Minimax should NOT have reasoning_effort
    try testing.expect(std.mem.indexOf(u8, body, "reasoning_effort") == null);
}

test "buildJsonBody: standard has reasoning_effort but no thinking" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const config = types.ModelConfig{
        .api = "openai",
        .model = "gpt-4o",
        .base_url = "https://api.openai.com",
        .api_key = "test-key",
    };
    var client = OpenAICompatClient{
        .config = config,
        .allocator = testing.allocator,
        .vendor = .standard,
    };
    const messages = [_]types.Message{
        .{ .role = .user, .content = try allocContent(allocator, "hello") },
    };
    const body = try client.buildJsonBody(allocator, &messages, false);
    defer allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "thinking") == null);
    try testing.expect(std.mem.indexOf(u8, body, "reasoning_effort") != null);
}

test "buildJsonBody: includes stream_options" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const config = types.ModelConfig{
        .api = "openai",
        .model = "gpt-4o",
        .base_url = "https://api.openai.com",
        .api_key = "test-key",
    };
    var client = OpenAICompatClient{
        .config = config,
        .allocator = testing.allocator,
        .vendor = .standard,
    };
    const messages = [_]types.Message{
        .{ .role = .user, .content = try allocContent(allocator, "hello") },
    };
    const body = try client.buildJsonBody(allocator, &messages, true);
    defer allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "stream") != null);
    try testing.expect(std.mem.indexOf(u8, body, "include_usage") != null);
}

test "checkSseExit: non-SSE with non-zero exit returns ApiError" {
    const testing = std.testing;
    // Simulate HTTP 401/403/500: no SSE data, curl exit code 22
    try testing.expectError(error.ApiError, checkSseExit(false, .{ .exited = 22 }));
    try testing.expectError(error.ApiError, checkSseExit(false, .{ .exited = 1 }));
}

test "checkSseExit: non-SSE with zero exit passes" {
    // No SSE data but exit code 0 (unusual but not an error)
    try checkSseExit(false, .{ .exited = 0 });
}

test "checkSseExit: SSE with non-zero exit returns CurlFailed" {
    const testing = std.testing;
    // Had SSE data but process failed (e.g. curl network error mid-stream)
    try testing.expectError(error.CurlFailed, checkSseExit(true, .{ .exited = 22 }));
    try testing.expectError(error.CurlFailed, checkSseExit(true, .{ .exited = 1 }));
}

test "checkSseExit: SSE with zero exit passes" {
    // Normal case: SSE data received, process exited OK
    try checkSseExit(true, .{ .exited = 0 });
}

test "setModel preserves client state" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const config = types.ModelConfig{
        .api = "deepseek",
        .model = "deepseek-v4-flash",
        .base_url = "https://api.deepseek.com",
        .api_key = "sk-test-key",
        .max_tokens = 4096,
    };

    var client = OpenAICompatClient{
        .config = config,
        .allocator = testing.allocator,
        .vendor = .deepseek,
    };

    // Verify initial state
    try testing.expectEqualStrings("deepseek-v4-flash", client.config.model);

    // Set same model via Provider interface (the /model scenario)
    var prov = registry.Provider{ .ptr = &client, .vtable = &vtable };
    prov.setModel("deepseek-v4-flash");

    // Verify model unchanged
    try testing.expectEqualStrings("deepseek-v4-flash", client.config.model);

    // Verify other fields unchanged
    try testing.expectEqualStrings("https://api.deepseek.com", client.config.base_url);
    try testing.expectEqualStrings("sk-test-key", client.config.api_key);
    try testing.expect(client.vendor == .deepseek);

    // Build JSON body before and after - should be identical when model name is same
    const messages = [_]types.Message{
        .{ .role = .user, .content = try allocContent(allocator, "hello") },
    };

    const json1 = try client.buildJsonBody(allocator, &messages, true);
    defer allocator.free(json1);

    const json2 = try client.buildJsonBody(allocator, &messages, true);
    defer allocator.free(json2);

    try testing.expectEqualStrings(json1, json2);

    // Set a different model and verify JSON body changes accordingly
    prov.setModel("gpt-4o");
    try testing.expectEqualStrings("gpt-4o", client.config.model);

    // base_url and api_key should still be unchanged after second setModel
    try testing.expectEqualStrings("https://api.deepseek.com", client.config.base_url);
    try testing.expectEqualStrings("sk-test-key", client.config.api_key);

    const json3 = try client.buildJsonBody(allocator, &messages, true);
    defer allocator.free(json3);

    // JSON should now contain the new model name
    try testing.expect(std.mem.indexOf(u8, json3, "gpt-4o") != null);
    // JSON should differ from json1 (different model name)
    try testing.expect(!std.mem.eql(u8, json1, json3));
}

fn allocContent(allocator: std.mem.Allocator, text: []const u8) ![]const types.ContentPart {
    const arr = try allocator.alloc(types.ContentPart, 1);
    arr[0] = .{ .text = text };
    return arr;
}
