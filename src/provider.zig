const std = @import("std");
const types = @import("types.zig");
pub const openai_compat = @import("provider/openai_compat.zig");
pub const registry = @import("provider/registry.zig");
const config_mod = @import("config.zig");

pub const common = @import("provider/common.zig");

pub const Provider = registry.Provider;
pub const ProviderEntry = registry.ProviderEntry;
pub const modelSpecFor = registry.modelSpecFor;

const ProviderImpl = struct {
    create: *const fn (config: types.ModelConfig, tools: ?[]const types.Tool, debug_logging: bool, arena: std.mem.Allocator) Provider,
    modelSpec: *const fn (model: []const u8) ?types.ModelSpec,
};

fn findProviderImpl(kind: []const u8) ?ProviderImpl {
    if (std.mem.eql(u8, kind, "openai")) {
        return ProviderImpl{
            .create = openai_compat.create,
            .modelSpec = openai_compat.modelSpec,
        };
    }
    return null;
}

/// Convert TOML [[providers]] entries to runtime ProviderEntry array.
/// Allocates from the provided arena allocator.
pub fn buildProviderEntries(arena: std.mem.Allocator, cfg_providers: []const config_mod.ProviderEntry) ![]ProviderEntry {
    var list = std.array_list.Managed(ProviderEntry).init(arena);
    for (cfg_providers) |p| {
        const impl = findProviderImpl(p.kind) orelse continue;
        try list.append(.{
            .name = p.name,
            .kind = p.kind,
            .env_key = p.api_key_env,
            .default_context_limit = p.context_limit,
            .default_max_tokens = p.max_tokens,
            .default_base_url = p.base_url,
            .create = impl.create,
            .modelSpec = impl.modelSpec,
        });
    }
    return list.toOwnedSlice();
}

test "buildProviderEntries: converts TOML entries to provider entries" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const cfg_entries = [_]config_mod.ProviderEntry{
        .{
            .name = "test-provider",
            .kind = "openai",
            .base_url = "https://api.test.com",
            .models = &.{},
            .default_model = "",
            .api_key_env = "TEST_KEY",
            .api_key = "",
            .context_limit = 65536,
            .max_tokens = 4096,
            .vision = false,
            .effort = "",
        },
    };

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const result = try buildProviderEntries(arena.allocator(), &cfg_entries);
    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expect(std.mem.eql(u8, result[0].name, "test-provider"));
    try testing.expect(std.mem.eql(u8, result[0].kind, "openai"));
    try testing.expect(std.mem.eql(u8, result[0].env_key, "TEST_KEY"));
    try testing.expectEqual(@as(u32, 65536), result[0].default_context_limit);
    try testing.expectEqual(@as(u32, 4096), result[0].default_max_tokens);
    try testing.expect(std.mem.eql(u8, result[0].default_base_url, "https://api.test.com"));
}

test "buildProviderEntries: skips unknown kind (error path)" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const cfg_entries = [_]config_mod.ProviderEntry{
        .{
            .name = "good",
            .kind = "openai",
            .base_url = "https://api.test.com",
            .models = &.{},
            .default_model = "",
            .api_key_env = "TEST_KEY",
            .api_key = "",
            .context_limit = 65536,
            .max_tokens = 4096,
            .vision = false,
            .effort = "",
        },
        .{
            .name = "bad",
            .kind = "anthropic", // unknown kind, should be skipped
            .base_url = "https://api.anthropic.com",
            .models = &.{},
            .default_model = "",
            .api_key_env = "ANTHROPIC_KEY",
            .api_key = "",
            .context_limit = 200000,
            .max_tokens = 4096,
            .vision = false,
            .effort = "",
        },
    };

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const result = try buildProviderEntries(arena.allocator(), &cfg_entries);
    // Only the openai kind entry should be included
    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expect(std.mem.eql(u8, result[0].name, "good"));
    try testing.expect(std.mem.eql(u8, result[0].kind, "openai"));
}
