const std = @import("std");
const builtin = @import("builtin");
const types = @import("../types.zig");
const ansi = @import("../ansi.zig");
const streamfmt = @import("../stream.zig");
const sse = @import("../sse.zig");
const common = @import("common.zig");
const registry = @import("registry.zig");
const signal = @import("../signal.zig");
const retry = @import("retry.zig");
const root_dir = @import("../tool/root_dir.zig");
const md2ansi = @import("md2ansi");

// ---------------------------------------------------------------------------
// Vendor detection
// ---------------------------------------------------------------------------

pub const Vendor = enum {
    deepseek,
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

        const connect_timeout = self.config.connect_timeout_secs orelse 15;
        const max_timeout = self.config.max_timeout_secs orelse 60;
        var connect_buf: [16]u8 = undefined;
        var max_buf: [16]u8 = undefined;
        const connect_str = try std.fmt.bufPrint(&connect_buf, "{d}", .{connect_timeout});
        const max_str = try std.fmt.bufPrint(&max_buf, "{d}", .{max_timeout});
        try argv_builder.appendSlice(&.{ "curl.exe", "-sN", "--fail-with-body", "--connect-timeout", connect_str, "--max-time", max_str });
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

        // 段落级覆盖渲染状态
        var paragraph_start: usize = 0;
        var last_was_newline = false;
        var scratch_buf: [16384]u8 = undefined;

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

        // Inline SSE reading with error body capture.
        // We read the pipe directly to capture non-SSE error response bodies
        // (e.g., JSON error responses from --fail-with-body) for error classification.
        const sse_read_buf = try allocator.alloc(u8, 4096);
        defer allocator.free(sse_read_buf);
        var sse_file_reader = stdout_file.readerStreaming(io, sse_read_buf);
        const sse_reader = &sse_file_reader.interface;
        var error_body_buf = std.array_list.Managed(u8).init(allocator);
        defer error_body_buf.deinit();

        var seen_first_data = false;

        while (true) {
            if (signal.isCancelled()) {
                child_finished = true;
                if (builtin.os.tag != .windows) {
                    child.kill(io);
                }
                return error.Interrupted;
            }

            const line_opt = sse_reader.takeDelimiter('\n') catch |err| switch (err) {
                error.ReadFailed => return error.ReadFailed,
                error.StreamTooLong => return error.StreamTooLong,
            };
            const raw_line = line_opt orelse break;
            const line = std.mem.trimEnd(u8, raw_line, "\r");

            if (!std.mem.startsWith(u8, line, "data: ")) {
                // Capture non-SSE lines as potential error body.
                // Only accumulate before first SSE data is seen.
                if (!seen_first_data) {
                    error_body_buf.appendSlice(raw_line) catch {};
                }
                continue;
            }

            if (!seen_first_data) {
                seen_first_data = true;
            }

            const payload = line[6..];

            if (std.mem.eql(u8, payload, "[DONE]")) break;

            // Debug log raw payload
            if (dbg) |f| {
                _ = f.writeStreamingAll(io, "\n[RAW]") catch {};
                _ = f.writeStreamingAll(io, payload) catch {};
                _ = f.writeStreamingAll(io, "\n") catch {};
            }

            var parsed = std.json.parseFromSlice(std.json.Value, allocator, payload, .{}) catch continue;
            defer parsed.deinit();

            if (parsed.value.object.get("error")) |err_val| {
                const msg = if (err_val.object.get("message")) |m| m.string else "unknown error";
                try out_writer.print("\n{s}[API 错误]{s} {s}\n", .{ ansi.C.red, ansi.C.reset, msg });
                try out_writer.flush();
                // Store error body for retry classification
                retry.last_error_body = msg;
                return error.ApiError;
            }

            const choices = parsed.value.object.get("choices") orelse continue;
            if (choices.array.items.len == 0) {
                if (parsed.value.object.get("usage")) |usage_val| {
                    if (usage_val != .null) {
                        usage = common.parseUsage(usage_val) catch null;
                    }
                }
                continue;
            }
            const choice = choices.array.items[0].object;
            const finish_reason = choice.get("finish_reason");
            const delta = choice.get("delta") orelse continue;

            // Reasoning_content (vendor-independent: DeepSeek + OpenAI o-series)
            if (delta.object.get("reasoning_content")) |r_val| {
                if (r_val != .null) {
                    const r = r_val.string;
                    // 同一推理阶段合并 header：仅在首次进入时输出 header
                    if (phase == .idle or phase == .thinking) {
                        try streamfmt.formatReasoningHeader(out_writer);
                        try out_writer.flush();
                        phase = .reasoning;
                    }
                    try reasoning_buf.appendSlice(r);
                    try streamfmt.formatReasoningText(out_writer, r);
                    try out_writer.flush();
                }
            }

            // Content (shared by all vendors)
            if (delta.object.get("content")) |c_val| {
                if (c_val != .null) {
                    const c = c_val.string;
                    if (phase == .reasoning) {
                        try streamfmt.formatContentTransition(out_writer);
                        try out_writer.flush();
                    }
                    phase = .content;
                    try content_buf.appendSlice(c);
                    if (ansi.shouldColorize()) {
                        try processContentChunk(out_writer, &content_buf, c, &paragraph_start, &last_was_newline, &scratch_buf);
                    } else {
                        try out_writer.print("{s}", .{c});
                        try out_writer.flush();
                    }
                }
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

        // Store error body for retry classification before checkSseExit may error
        if (error_body_buf.items.len > 0) {
            retry.last_error_body = error_body_buf.items;
        }

        // If no SSE data was received, the response was not valid SSE.
        // Return ApiError so callWithRetry won't retry auth/permission errors.
        try checkSseExit(term);

        // Force overlay remaining content on stream end (仅 TTY 时)
        if (phase == .content and paragraph_start < content_buf.items.len and ansi.shouldColorize()) {
            const pending = content_buf.items[paragraph_start..];
            if (pending.len > 0) {
                overlayParagraph(out_writer, pending, &scratch_buf) catch {};
            }
        }

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
            .reasoning = if (self.vendor == .deepseek and reasoning_buf.items.len > 0)
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
fn checkSseExit(term: std.process.Child.Term) !void {
    switch (term) {
        .exited => |code| if (code != 0) return error.ApiError,
        else => return error.ApiError,
    }
}

// ---------------------------------------------------------------------------
// 段落级覆盖渲染
// ---------------------------------------------------------------------------

/// Scan chunk for paragraph boundaries (blank line = \n\n). When a complete
/// paragraph is detected, overlay it with ANSI-colored rendering via md2ansi.
fn processContentChunk(
    writer: anytype,
    content_buf: *std.array_list.Managed(u8),
    chunk: []const u8,
    paragraph_start: *usize,
    last_was_newline: *bool,
    scratch_buf_ptr: *[16384]u8,
) !void {
    const old_len = content_buf.items.len - chunk.len;

    // Print chunk raw for real-time feedback
    try writer.print("{s}", .{chunk});
    try writer.flush();

    // Check for \n\n boundary (scans cross-chunk boundary too)
    var boundary_found = false;
    var prev = last_was_newline.*;
    for (chunk) |byte| {
        if (byte == '\n') {
            if (prev) {
                boundary_found = true;
                break;
            }
            prev = true;
        } else {
            prev = false;
        }
    }
    last_was_newline.* = chunk.len > 0 and chunk[chunk.len - 1] == '\n';

    if (boundary_found) {
        const cursor_pos = old_len + chunk.len;
        const raw_text = content_buf.items[paragraph_start.* .. cursor_pos];
        if (raw_text.len > 0) {
            // Overlay failure (buffer overflow, etc.) is non-fatal:
            // fall back to raw text that was already printed.
            overlayParagraph(writer, raw_text, scratch_buf_ptr) catch {};
        }
        paragraph_start.* = cursor_pos;
    }
}

/// Move cursor up by number of newlines in text, clear below, render markdown
/// to ANSI, and output colored version. Removes trailing \n from rendered
/// output so line count matches the raw text.
fn overlayParagraph(
    writer: anytype,
    text: []const u8,
    scratch_buf_ptr: *[16384]u8,
) !void {
    if (text.len == 0) return;

    var line_count: usize = 0;
    for (text) |byte| {
        if (byte == '\n') line_count += 1;
    }

    // Column 0, cursor up to paragraph start, clear from there.
    // line_count covers ALL content since paragraph_start, so \x1b[0J
    // clears exactly the content area — preserving the separator above.
    try writer.print("\x1b[0G\x1b[{d}A\x1b[0J", .{line_count});
    try writer.flush();

    var w: std.Io.Writer = .fixed(scratch_buf_ptr);
    try md2ansi.render(&w, text);
    var rendered = w.buffered();
    // Remove trailing \n: md2ansi.render always adds one extra \n at the end
    // (from the last line's renderParagraph). Without removal, the rendered
    // output would be 1 line taller than the raw text it replaces.
    if (rendered.len > 0 and rendered[rendered.len - 1] == '\n') {
        rendered = rendered[0 .. rendered.len - 1];
    }
    try writer.writeAll(rendered);
    try writer.flush();
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
    const content_parts = try allocContent(allocator, "hello");
    defer allocator.free(content_parts);
    const messages = [_]types.Message{
        .{ .role = .user, .content = content_parts },
    };
    const body = try client.buildJsonBody(allocator, &messages, false);
    defer allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "thinking") != null);
    try testing.expect(std.mem.indexOf(u8, body, "reasoning_effort") != null);
    try testing.expect(std.mem.indexOf(u8, body, "enabled") != null);
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
    const content_parts = try allocContent(allocator, "hello");
    defer allocator.free(content_parts);
    const messages = [_]types.Message{
        .{ .role = .user, .content = content_parts },
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
    const content_parts = try allocContent(allocator, "hello");
    defer allocator.free(content_parts);
    const messages = [_]types.Message{
        .{ .role = .user, .content = content_parts },
    };
    const body = try client.buildJsonBody(allocator, &messages, true);
    defer allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "stream") != null);
    try testing.expect(std.mem.indexOf(u8, body, "include_usage") != null);
}

test "checkSseExit: non-SSE with non-zero exit returns ApiError" {
    const testing = std.testing;
    // Simulate HTTP 401/403/500: no SSE data, curl exit code 22
    try testing.expectError(error.ApiError, checkSseExit(.{ .exited = 22 }));
    try testing.expectError(error.ApiError, checkSseExit(.{ .exited = 1 }));
}

test "checkSseExit: zero exit passes" {
    try checkSseExit(.{ .exited = 0 });
}

test "checkSseExit: non-zero exit returns ApiError regardless of SSE data" {
    const testing = std.testing;
    try testing.expectError(error.ApiError, checkSseExit(.{ .exited = 22 }));
    try testing.expectError(error.ApiError, checkSseExit(.{ .exited = 1 }));
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
    const cp1 = try allocContent(allocator, "hello");
    defer allocator.free(cp1);
    const messages = [_]types.Message{
        .{ .role = .user, .content = cp1 },
    };

    const json1 = try client.buildJsonBody(allocator, &messages, true);
    defer allocator.free(json1);

    const json2 = try client.buildJsonBody(allocator, &messages, true);
    defer allocator.free(json2);

    try testing.expectEqualStrings(json1, json2);

    // Free the first dupe'd model before second setModel
    allocator.free(client.config.model);
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

    // Free the second dupe'd model from setModel
    allocator.free(client.config.model);
}

test "overlayParagraph: renders ANSI codes for simple text" {
    var scratch: [16384]u8 = undefined;
    var out_buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&out_buf);
    try overlayParagraph(&w, "hello **world**", &scratch);
    const output = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "\x1b[1m") != null); // bold for **world**
    try std.testing.expect(std.mem.indexOf(u8, output, "\x1b[0m") != null); // reset
    try std.testing.expect(std.mem.indexOf(u8, output, "hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "world") != null);
    // Literal ** markers should NOT appear
    try std.testing.expect(std.mem.indexOf(u8, output, "**") == null);
}

test "overlayParagraph: empty input produces no output" {
    var scratch: [16384]u8 = undefined;
    var out_buf: [4]u8 = undefined;
    var w: std.Io.Writer = .fixed(&out_buf);
    try overlayParagraph(&w, "", &scratch);
    const output = w.buffered();
    try std.testing.expectEqual(@as(usize, 0), output.len);
}

test "overlayParagraph: renders heading with ANSI" {
    var scratch: [16384]u8 = undefined;
    var out_buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&out_buf);
    try overlayParagraph(&w, "# Title", &scratch);
    const output = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "\x1b[1m") != null); // bold
    try std.testing.expect(std.mem.indexOf(u8, output, "\x1b[36m") != null); // cyan
    try std.testing.expect(std.mem.indexOf(u8, output, "Title") != null);
}

test "processContentChunk: detects paragraph boundary and overlays" {
    var scratch: [16384]u8 = undefined;
    var out_buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&out_buf);
    var content = std.array_list.Managed(u8).init(std.testing.allocator);
    defer content.deinit();
    var para_start: usize = 0;
    var last_nl = false;

    // Append first line without newline
    try content.appendSlice("Hello world");
    // Append newline - sets last_was_newline = true
    try content.appendSlice("\n");
    try processContentChunk(&w, &content, "\n", &para_start, &last_nl, &scratch);
    // No boundary detected yet (only one \n)
    try std.testing.expectEqual(@as(usize, 0), para_start);
    try std.testing.expect(last_nl);

    // Append second newline - should trigger boundary
    const output_len_before = w.buffered().len;
    try content.appendSlice("\n");
    try processContentChunk(&w, &content, "\n", &para_start, &last_nl, &scratch);
    const output = w.buffered();
    // Overlay should have written ANSI codes + cursor movement
    try std.testing.expect(output.len > output_len_before);
    try std.testing.expect(std.mem.indexOf(u8, output[output_len_before..], "\x1b[") != null);
    // paragraph_start should advance past the \n\n
    try std.testing.expectEqual(@as(usize, 13), para_start);
}

fn allocContent(allocator: std.mem.Allocator, text: []const u8) ![]const types.ContentPart {
    const arr = try allocator.alloc(types.ContentPart, 1);
    arr[0] = .{ .text = text };
    return arr;
}
