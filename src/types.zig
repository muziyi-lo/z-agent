const std = @import("std");

pub const VERSION: []const u8 = "0.3.0";

pub const Role = enum {
    system,
    user,
    assistant,
    tool,
};

pub const ContentPart = union(enum) {
    text: []const u8,
    tool_call: ToolCall,
    tool_result: ToolResult,
    image_url: ImageUrl,
};

pub const ImageUrl = struct {
    url: []const u8,
};

pub const Message = struct {
    role: Role,
    content: ?[]const ContentPart = null,
    tool_calls: ?[]const ToolCall = null,
    tool_call_id: ?[]const u8 = null,
    reasoning: ?[]const u8 = null,
    timestamp_ns: ?i96 = null,
};

pub const ToolCall = struct {
    id: []const u8,
    name: []const u8,
    arguments: []const u8,
};

pub const ToolResult = struct {
    id: []const u8,
    content: []const u8,
    is_error: bool = false,
    name: ?[]const u8 = null,
    duration_ms: ?u32 = null,
};

pub const Tool = struct {
    name: []const u8,
    description: []const u8,
    parameters: []const u8,
};

/// HTTP proxy configuration for API calls.
pub const ProxyConfig = struct {
    mode: []const u8 = "auto",
    url: []const u8 = "",
    no_proxy: []const []const u8 = &.{},
};

pub const ModelConfig = struct {
    api: []const u8,
    model: []const u8,
    base_url: []const u8,
    api_key: []const u8,
    max_tokens: ?u32 = null,
    proxy: ProxyConfig = .{},
    /// TCP+TLS connect timeout (null = use default 15s)
    connect_timeout_secs: ?u32 = null,
    /// total request timeout (null = use default 60s)
    max_timeout_secs: ?u32 = null,
};

pub const ModelSpec = struct {
    context_limit: u32,
    max_output: u32,
};

pub const Usage = struct {
    completion_tokens: u32 = 0,
    prompt_tokens: u32 = 0,
    total_tokens: u32 = 0,
    reasoning_tokens: u32 = 0,
};

pub const ChatResponse = struct {
    content: ?[]const u8 = null,
    reasoning: ?[]const u8 = null,
    tool_calls: ?[]const ToolCall = null,
    usage: ?Usage = null,
};

pub const SkillMeta = struct {
    name: []const u8,
    slug: []const u8,
    description: []const u8,
    path: []const u8,
};

pub const PermissionAction = enum {
    allow,
    confirm,
    deny,
};

pub const PermissionRule = struct {
    tool: []const u8,
    subject: ?[]const u8 = null,
    action: PermissionAction,
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "ModelConfig: timeout fields default to null" {
    const testing = std.testing;
    const cfg = ModelConfig{
        .api = "test",
        .model = "test-model",
        .base_url = "https://test.com",
        .api_key = "sk-test",
    };
    try testing.expect(cfg.connect_timeout_secs == null);
    try testing.expect(cfg.max_timeout_secs == null);
}
