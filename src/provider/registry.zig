const std = @import("std");
const types = @import("../types.zig");

pub const Provider = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        chatCompletionStreaming: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, messages: []const types.Message, out_writer: *std.Io.Writer) anyerror!types.ChatResponse,
        setModel: *const fn (ptr: *anyopaque, model: []const u8) void,
    };

    pub fn chatCompletionStreaming(
        self: Provider,
        allocator: std.mem.Allocator,
        io: std.Io,
        messages: []const types.Message,
        out_writer: *std.Io.Writer,
    ) !types.ChatResponse {
        return self.vtable.chatCompletionStreaming(self.ptr, allocator, io, messages, out_writer);
    }

    pub fn setModel(self: Provider, model: []const u8) void {
        self.vtable.setModel(self.ptr, model);
    }
};

pub const ProviderEntry = struct {
    name: []const u8,
    kind: []const u8 = "openai",
    env_key: []const u8,
    default_context_limit: u32,
    default_max_tokens: u32,
    default_base_url: []const u8,
    /// TCP+TLS connect timeout per provider
    connect_timeout_secs: ?u32 = null,
    /// total request timeout per provider
    max_timeout_secs: ?u32 = null,
    create: *const fn (config: types.ModelConfig, tools: ?[]const types.Tool, debug_logging: bool, arena: std.mem.Allocator) Provider,
    modelSpec: *const fn (model: []const u8) ?types.ModelSpec,
};

pub fn findByApi(entries: []const ProviderEntry, api: []const u8) ?ProviderEntry {
    // Try exact name match first
    for (entries) |e| {
        if (std.mem.eql(u8, e.name, api)) return e;
    }
    // Fallback: try kind match (all entries with same kind share create/modelSpec)
    for (entries) |e| {
        if (std.mem.eql(u8, e.kind, api)) return e;
    }
    return null;
}

pub fn modelSpecFor(entries: []const ProviderEntry, api: []const u8, model: []const u8) ?types.ModelSpec {
    for (entries) |e| {
        if (std.mem.eql(u8, e.name, api)) {
            // 1. Get built-in spec from the provider's modelSpec function
            const spec = e.modelSpec(model);

            // 2. Apply TOML overrides (context_limit and max_tokens from [[providers]])
            if (e.default_context_limit > 0 or e.default_max_tokens > 0) {
                var overridden = spec orelse types.ModelSpec{
                    .context_limit = 0,
                    .max_output = 0,
                };
                if (e.default_context_limit > 0) overridden.context_limit = e.default_context_limit;
                if (e.default_max_tokens > 0) overridden.max_output = e.default_max_tokens;
                // Unknown model but TOML provides context_limit → return spec with TOML values
                if (overridden.context_limit > 0) return overridden;
            }

            return spec;
        }
    }
    return null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn stubModelSpec(model: []const u8) ?types.ModelSpec {
    if (std.mem.eql(u8, model, "known-model")) {
        return types.ModelSpec{ .context_limit = 100000, .max_output = 50000 };
    }
    return null;
}

test "modelSpecFor: returns built-in spec for known model without TOML overrides" {
    const testing = std.testing;
    const entries = [_]ProviderEntry{
        .{
            .name = "test",
            .kind = "openai",
            .env_key = "TEST_KEY",
            .default_context_limit = 0,
            .default_max_tokens = 0,
            .default_base_url = "https://test.com",
            .create = undefined, // not used in this test
            .modelSpec = stubModelSpec,
        },
    };
    const spec = modelSpecFor(&entries, "test", "known-model");
    try testing.expect(spec != null);
    try testing.expectEqual(@as(u32, 100000), spec.?.context_limit);
    try testing.expectEqual(@as(u32, 50000), spec.?.max_output);
}

test "modelSpecFor: TOML context_limit overrides built-in spec" {
    const testing = std.testing;
    const entries = [_]ProviderEntry{
        .{
            .name = "test",
            .kind = "openai",
            .env_key = "TEST_KEY",
            .default_context_limit = 2048,
            .default_max_tokens = 0,
            .default_base_url = "https://test.com",
            .create = undefined,
            .modelSpec = stubModelSpec,
        },
    };
    const spec = modelSpecFor(&entries, "test", "known-model");
    try testing.expect(spec != null);
    // context_limit should be overridden to TOML value (2048), max_output should stay from built-in
    try testing.expectEqual(@as(u32, 2048), spec.?.context_limit);
    try testing.expectEqual(@as(u32, 50000), spec.?.max_output);
}

test "modelSpecFor: TOML max_tokens overrides built-in max_output" {
    const testing = std.testing;
    const entries = [_]ProviderEntry{
        .{
            .name = "test",
            .kind = "openai",
            .env_key = "TEST_KEY",
            .default_context_limit = 0,
            .default_max_tokens = 4096,
            .default_base_url = "https://test.com",
            .create = undefined,
            .modelSpec = stubModelSpec,
        },
    };
    const spec = modelSpecFor(&entries, "test", "known-model");
    try testing.expect(spec != null);
    // context_limit should stay from built-in, max_output should be overridden
    try testing.expectEqual(@as(u32, 100000), spec.?.context_limit);
    try testing.expectEqual(@as(u32, 4096), spec.?.max_output);
}

test "modelSpecFor: both TOML context_limit and max_tokens override built-in" {
    const testing = std.testing;
    const entries = [_]ProviderEntry{
        .{
            .name = "test",
            .kind = "openai",
            .env_key = "TEST_KEY",
            .default_context_limit = 8192,
            .default_max_tokens = 2048,
            .default_base_url = "https://test.com",
            .create = undefined,
            .modelSpec = stubModelSpec,
        },
    };
    const spec = modelSpecFor(&entries, "test", "known-model");
    try testing.expect(spec != null);
    try testing.expectEqual(@as(u32, 8192), spec.?.context_limit);
    try testing.expectEqual(@as(u32, 2048), spec.?.max_output);
}

test "modelSpecFor: unknown model with TOML values returns spec from TOML (error path)" {
    const testing = std.testing;
    const entries = [_]ProviderEntry{
        .{
            .name = "test",
            .kind = "openai",
            .env_key = "TEST_KEY",
            .default_context_limit = 4096,
            .default_max_tokens = 2048,
            .default_base_url = "https://test.com",
            .create = undefined,
            .modelSpec = stubModelSpec,
        },
    };
    // "unknown-model" is not in stubModelSpec, but TOML provides values
    const spec = modelSpecFor(&entries, "test", "unknown-model");
    try testing.expect(spec != null);
    try testing.expectEqual(@as(u32, 4096), spec.?.context_limit);
    try testing.expectEqual(@as(u32, 2048), spec.?.max_output);
}

test "modelSpecFor: unknown model without TOML values returns null (error path)" {
    const testing = std.testing;
    const entries = [_]ProviderEntry{
        .{
            .name = "test",
            .kind = "openai",
            .env_key = "TEST_KEY",
            .default_context_limit = 0,
            .default_max_tokens = 0,
            .default_base_url = "https://test.com",
            .create = undefined,
            .modelSpec = stubModelSpec,
        },
    };
    // "unknown-model" is not in stubModelSpec and no TOML overrides
    const spec = modelSpecFor(&entries, "test", "unknown-model");
    try testing.expect(spec == null);
}

test "modelSpecFor: unknown API name returns null (error path)" {
    const testing = std.testing;
    const entries = [_]ProviderEntry{
        .{
            .name = "test",
            .kind = "openai",
            .env_key = "TEST_KEY",
            .default_context_limit = 0,
            .default_max_tokens = 0,
            .default_base_url = "https://test.com",
            .create = undefined,
            .modelSpec = stubModelSpec,
        },
    };
    const spec = modelSpecFor(&entries, "nonexistent-api", "known-model");
    try testing.expect(spec == null);
}
