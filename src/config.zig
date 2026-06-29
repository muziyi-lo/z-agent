const std = @import("std");
const Io = std.Io;
const toml = @import("toml.zig");
const types = @import("types.zig");
const permission = @import("permission.zig");

/// Provider configuration from TOML
pub const ProviderEntry = struct {
    name: []const u8,
    kind: []const u8,
    base_url: []const u8,
    models: []const []const u8,
    default_model: []const u8,
    api_key_env: []const u8,
    api_key: []const u8,
    context_limit: u32,
    max_tokens: u32,
    vision: bool,
    effort: []const u8,
};

/// Application configuration loaded from .zagent/config.toml
pub const Config = struct {
    default_model: []const u8,
    max_tokens: u32,
    providers: []const ProviderEntry,
    permissions: permission.PermissionConfig,
    proxy: types.ProxyConfig,

    pub const LoadResult = struct {
        config: Config,
        api_keys: []const []const u8,
    };

    pub fn load(allocator: std.mem.Allocator, project_root: []const u8, io: std.Io) !LoadResult {
    const path = try std.fs.path.join(allocator, &.{ project_root, ".zagent", "config.toml" });
    defer allocator.free(path);

    const content = readFile(allocator, path, io) catch |err| switch (err) {
        error.FileNotFound => {
            try writeDefaultConfig(allocator, project_root, io);
            // Retry reading the freshly written default config
            const retry_content = try readFile(allocator, path, io);
            errdefer allocator.free(retry_content);
            return parseConfigContent(allocator, retry_content, project_root, io);
        },
        else => return err,
    };
    defer allocator.free(content);

    // Non-Windows: check file permissions for security-sensitive files
    warnIfNotOwnerOnly(path, io);
    {
        const env_path_res = std.fs.path.join(allocator, &.{ project_root, ".zagent", ".env" }) catch null;
        if (env_path_res) |env_path| {
            defer allocator.free(env_path);
            warnIfNotOwnerOnly(env_path, io);
        }
    }

    return parseConfigContent(allocator, content, project_root, io);
}
};

const ConfigToml = std.StringArrayHashMapUnmanaged(toml.Value);

/// Find the project root by walking up from CWD looking for `.zagent/config.toml`.
pub fn findZagentRoot(allocator: std.mem.Allocator, io: std.Io) ?[]const u8 {
    var buf: [4096]u8 = undefined;
    const len = Io.Dir.cwd().realPath(io, &buf) catch return null;
    const start_path = allocator.dupe(u8, buf[0..len]) catch return null;
    defer allocator.free(start_path);
    var current: []const u8 = start_path;

    while (true) {
        const cfg_path = std.fs.path.join(allocator, &.{ current, ".zagent", "config.toml" }) catch return null;
        defer allocator.free(cfg_path);

        if (std.Io.Dir.cwd().openFile(io, cfg_path, .{ .mode = .read_only })) |_| {
            return allocator.dupe(u8, current) catch return null;
        } else |_| {}

        const parent = std.fs.path.dirname(current) orelse return null;
        if (std.mem.eql(u8, parent, current)) return null;
        current = parent;
    }
}

/// Load environment variables from .zagent/.env file (KEY=VALUE lines).
/// Supports quoted values ("value"), inline comments (# outside quotes), and empty values.
pub fn loadDotEnv(allocator: std.mem.Allocator, project_root: []const u8, io: std.Io) !std.StringArrayHashMapUnmanaged([]const u8) {
    var map = std.StringArrayHashMapUnmanaged([]const u8){};
    errdefer {
        var it = map.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        map.deinit(allocator);
    }

    const env_path = std.fs.path.join(allocator, &.{ project_root, ".zagent", ".env" }) catch return map;
    defer allocator.free(env_path);

    const content = readFile(allocator, env_path, io) catch return map;
    defer allocator.free(content);

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        if (key.len == 0) continue;

        var value_raw = line[eq + 1 ..];

        // Handle inline # comments: find # outside quotes
        var comment_pos: ?usize = null;
        var in_quotes = false;
        for (value_raw, 0..) |c, i| {
            if (c == '"') {
                in_quotes = !in_quotes;
            } else if (c == '#' and !in_quotes) {
                comment_pos = i;
                break;
            }
        }

        const value_before_comment = if (comment_pos) |pos| value_raw[0..pos] else value_raw;
        const value_trimmed = std.mem.trim(u8, value_before_comment, " \t");

        // Strip surrounding quotes
        const value = if (value_trimmed.len >= 2 and value_trimmed[0] == '"' and value_trimmed[value_trimmed.len - 1] == '"')
            value_trimmed[1 .. value_trimmed.len - 1]
        else
            value_trimmed;

        const k_dup = try allocator.dupe(u8, key);
        errdefer allocator.free(k_dup);
        const v_dup = try allocator.dupe(u8, value);
        errdefer allocator.free(v_dup);
        try map.put(allocator, k_dup, v_dup);
    }

    return map;
}

fn parseConfigContent(allocator: std.mem.Allocator, content: []const u8, project_root: []const u8, io: std.Io) !Config.LoadResult {
    const parsed = try toml.parse(allocator, content);
    defer toml.freeTable(allocator, @constCast(&parsed));

    // Parse top-level fields
    const default_model = getTomlString(parsed, "default_model") orelse "";
    const max_tokens = getTomlInteger(parsed, "max_tokens") orelse 4096;

    // Parse providers
    var providers_list = std.array_list.Managed(ProviderEntry).init(allocator);
    defer providers_list.deinit();

    var api_keys_list = std.array_list.Managed([]const u8).init(allocator);
    defer api_keys_list.deinit();

    if (parsed.get("providers")) |providers_val| {
        if (providers_val == .array) {
            for (providers_val.array) |elem| {
                if (elem != .table) continue;
                const t = &elem.table;
                const entry = try parseProviderEntry(allocator, t);
                try providers_list.append(entry);
            }
        }
    }

    // Parse permissions
    const perm_config = if (parsed.get("permissions")) |perm_val| p: {
        if (perm_val != .table) break :p permission.PermissionConfig{};
        break :p try parsePermissions(allocator, &perm_val.table);
    } else permission.PermissionConfig{};

    // Parse proxy
    const proxy_config = if (parsed.get("proxy")) |proxy_val| p: {
        if (proxy_val != .table) break :p types.ProxyConfig{};
        break :p try parseProxyConfig(allocator, &proxy_val.table);
    } else types.ProxyConfig{};

    // Resolve API keys: inline > .env > env var
    var dotenv = try loadDotEnv(allocator, project_root, io);
    defer {
        var it = dotenv.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        dotenv.deinit(allocator);
    }

    // Create process env map
    const process_env = std.process.Environ{ .block = .{ .use_global = true } };
    var environ_map = std.process.Environ.createMap(process_env, allocator) catch |err| {
        return err;
    };
    defer {
        var it = environ_map.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        environ_map.deinit();
    }

    for (providers_list.items) |*entry| {
        const resolved_key = if (entry.api_key.len > 0) key: {
            break :key try allocator.dupe(u8, entry.api_key);
        } else if (dotenv.get(entry.api_key_env)) |env_val| key: {
            break :key try allocator.dupe(u8, env_val);
        } else if (environ_map.get(entry.api_key_env)) |env_val| key: {
            break :key try allocator.dupe(u8, env_val);
        } else if (entry.api_key_env.len > 0) key: {
            // env var name set but empty - that's ok for local providers
            break :key try allocator.dupe(u8, "");
        } else key: {
            break :key try allocator.dupe(u8, "");
        };
        // Free the old api_key (from TOML) and replace
        if (entry.api_key.len > 0) allocator.free(entry.api_key);
        entry.api_key = resolved_key;

        try api_keys_list.append(try allocator.dupe(u8, resolved_key));
    }

    const providers = try providers_list.toOwnedSlice();
    const api_keys = try api_keys_list.toOwnedSlice();

    return .{
        .config = Config{
            .default_model = try allocator.dupe(u8, default_model),
            .max_tokens = @intCast(@min(@max(max_tokens, 0), std.math.maxInt(u32))),
            .providers = providers,
            .permissions = perm_config,
            .proxy = proxy_config,
        },
        .api_keys = api_keys,
    };
}

fn parseProviderEntry(allocator: std.mem.Allocator, t: *const std.StringArrayHashMapUnmanaged(toml.Value)) !ProviderEntry {
    const name = getTomlString(t.*, "name") orelse "";
    const kind = getTomlString(t.*, "kind") orelse "openai";
    const base_url = getTomlString(t.*, "base_url") orelse "";
    const default_model = getTomlString(t.*, "default_model") orelse "";
    const api_key_env = getTomlString(t.*, "api_key_env") orelse "";
    const api_key = getTomlString(t.*, "api_key") orelse "";
    const effort = getTomlString(t.*, "effort") orelse "";
    const raw_cl = getTomlInteger(t.*, "context_limit") orelse 0;
    const context_limit: u32 = @intCast(@min(@max(raw_cl, 0), std.math.maxInt(u32)));
    const raw_mt = getTomlInteger(t.*, "max_tokens") orelse 0;
    const mt: u32 = @intCast(@min(@max(raw_mt, 0), std.math.maxInt(u32)));
    const vision = getTomlBoolean(t.*, "vision") orelse false;

    // Parse models array
    var models_list = std.array_list.Managed([]const u8).init(allocator);
    errdefer {
        for (models_list.items) |m| allocator.free(m);
        models_list.deinit();
    }

    if (t.get("models")) |models_val| {
        if (models_val == .array) {
            for (models_val.array) |m| {
                if (m == .string) {
                    try models_list.append(try allocator.dupe(u8, m.string));
                }
            }
        }
    }

    const models = try models_list.toOwnedSlice();

    return ProviderEntry{
        .name = try allocator.dupe(u8, name),
        .kind = try allocator.dupe(u8, kind),
        .base_url = try allocator.dupe(u8, base_url),
        .models = models,
        .default_model = if (default_model.len > 0) try allocator.dupe(u8, default_model) else try allocator.dupe(u8, ""),
        .api_key_env = try allocator.dupe(u8, api_key_env),
        .api_key = try allocator.dupe(u8, api_key),
        .context_limit = context_limit,
        .max_tokens = mt,
        .vision = vision,
        .effort = if (effort.len > 0) try allocator.dupe(u8, effort) else try allocator.dupe(u8, ""),
    };
}

fn parsePermissions(allocator: std.mem.Allocator, t: *const std.StringArrayHashMapUnmanaged(toml.Value)) !permission.PermissionConfig {
    const mode_str = getTomlString(t.*, "mode") orelse "confirm";
    const mode: types.PermissionAction = if (std.mem.eql(u8, mode_str, "allow"))
        .allow
    else if (std.mem.eql(u8, mode_str, "deny"))
        .deny
    else
        .confirm;

    var rules_list = std.array_list.Managed(permission.Rule).init(allocator);
    errdefer {
        for (rules_list.items) |r| {
            allocator.free(r.tool);
            if (r.subject) |s| allocator.free(s);
        }
        rules_list.deinit();
    }

    // Parse allow rules
    if (t.get("allow")) |allow_val| {
        if (allow_val == .array) {
            for (allow_val.array) |item| {
                if (item == .string) {
                    const rule = try parseRuleString(allocator, item.string, .allow);
                    try rules_list.append(rule);
                }
            }
        }
    }

    // Parse ask rules
    if (t.get("ask")) |ask_val| {
        if (ask_val == .array) {
            for (ask_val.array) |item| {
                if (item == .string) {
                    const rule = try parseRuleString(allocator, item.string, .confirm);
                    try rules_list.append(rule);
                }
            }
        }
    }

    // Parse deny rules
    if (t.get("deny")) |deny_val| {
        if (deny_val == .array) {
            for (deny_val.array) |item| {
                if (item == .string) {
                    const rule = try parseRuleString(allocator, item.string, .deny);
                    try rules_list.append(rule);
                }
            }
        }
    }

    return permission.PermissionConfig{
        .mode = mode,
        .rules = try rules_list.toOwnedSlice(),
    };
}

/// Parse a rule string like "Read" or "Bash(rm -rf *)" into a permission.Rule.
fn parseRuleString(allocator: std.mem.Allocator, input: []const u8, action: types.PermissionAction) !permission.Rule {
    const trimmed = std.mem.trim(u8, input, " \t");
    if (std.mem.lastIndexOfScalar(u8, trimmed, '(')) |open_paren| {
        if (trimmed[trimmed.len - 1] == ')') {
            const tool = std.mem.trim(u8, trimmed[0..open_paren], " \t");
            const subject = std.mem.trim(u8, trimmed[open_paren + 1 .. trimmed.len - 1], " \t");
            return permission.Rule{
                .tool = try allocator.dupe(u8, tool),
                .subject = if (subject.len > 0) try allocator.dupe(u8, subject) else null,
                .action = action,
            };
        }
    }
    // No parentheses → tool-only rule
    return permission.Rule{
        .tool = try allocator.dupe(u8, trimmed),
        .subject = null,
        .action = action,
    };
}

fn parseProxyConfig(allocator: std.mem.Allocator, t: *const std.StringArrayHashMapUnmanaged(toml.Value)) !types.ProxyConfig {
    const mode = getTomlString(t.*, "mode") orelse "auto";
    const url = getTomlString(t.*, "url") orelse "";

    var no_proxy_list = std.array_list.Managed([]const u8).init(allocator);
    errdefer {
        for (no_proxy_list.items) |item| allocator.free(item);
        no_proxy_list.deinit();
    }

    if (t.get("no_proxy")) |np_val| {
        if (np_val == .array) {
            for (np_val.array) |item| {
                if (item == .string) {
                    try no_proxy_list.append(try allocator.dupe(u8, item.string));
                }
            }
        }
    }

    const no_proxy = try no_proxy_list.toOwnedSlice();

    return types.ProxyConfig{
        .mode = try allocator.dupe(u8, mode),
        .url = try allocator.dupe(u8, url),
        .no_proxy = no_proxy,
    };
}

// ---------------------------------------------------------------------------
// TOML value extractors
// ---------------------------------------------------------------------------

fn getTomlString(t: ConfigToml, key: []const u8) ?[]const u8 {
    const val = t.get(key) orelse return null;
    if (val != .string) return null;
    return val.string;
}

fn getTomlInteger(t: ConfigToml, key: []const u8) ?i64 {
    const val = t.get(key) orelse return null;
    if (val != .integer) return null;
    return val.integer;
}

fn getTomlBoolean(t: ConfigToml, key: []const u8) ?bool {
    const val = t.get(key) orelse return null;
    if (val != .boolean) return null;
    return val.boolean;
}

// ---------------------------------------------------------------------------
// File I/O
// ---------------------------------------------------------------------------

fn readFile(allocator: std.mem.Allocator, path: []const u8, io: std.Io) ![]u8 {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only });
    defer file.close(io);

    const size = (try file.stat(io)).size;
    var buf = try allocator.alloc(u8, @intCast(size));
    errdefer allocator.free(buf);

    const n = try file.readPositionalAll(io, buf, 0);
    return buf[0..n];
}

// ---------------------------------------------------------------------------
// Default config generation
// ---------------------------------------------------------------------------

fn writeDefaultConfig(allocator: std.mem.Allocator, project_root: []const u8, io: std.Io) !void {
    const dir_path = try std.fs.path.join(allocator, &.{ project_root, ".zagent" });
    defer allocator.free(dir_path);
    std.Io.Dir.cwd().createDirPath(io, dir_path) catch {};

    const path = try std.fs.path.join(allocator, &.{ dir_path, "config.toml" });
    defer allocator.free(path);

    const default_content =
        \\# z-agent configuration
        \\# 首次运行自动生成，按需修改
        \\
        \\default_model = "deepseek/deepseek-v4-flash"
        \\max_tokens = 4096
        \\
        \\[[providers]]
        \\name = "deepseek"
        \\kind = "openai"
        \\base_url = "https://api.deepseek.com"
        \\models = ["deepseek-v4-flash", "deepseek-v4-pro"]
        \\default_model = "deepseek-v4-flash"
        \\api_key_env = "DEEPSEEK_API_KEY"
        \\context_limit = 1048576
        \\max_tokens = 8192
        \\vision = true
        \\effort = "high"
        \\
        \\# 完整 [[providers]] 示例（取消注释即可使用）：
        \\# [[providers]]
        \\# name = "openai"
        \\# kind = "openai"
        \\# base_url = "https://api.openai.com"
        \\# models = ["gpt-4o"]
        \\# api_key_env = "OPENAI_API_KEY"
        \\# context_limit = 128000
        \\
        \\[permissions]
        \\mode = "confirm"
        \\allow = []
        \\ask = []
        \\deny = ["Bash(rm -rf *)"]
        \\
        \\# [proxy]
        \\# mode = "auto"     # auto | env | custom | off
        \\# url = "http://127.0.0.1:7890"   # custom mode 时必填
        \\# no_proxy = ["localhost", "127.0.0.1"]
        \\
        \\# API Key 优先级: 内联 api_key > .zagent/.env > 环境变量
        \\# 安全建议: 使用 .zagent/.env 文件（已 gitignored），不要直接写入 config.toml
    ;

    const file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, default_content);
}

// ---------------------------------------------------------------------------
// Permission warning (non-Windows only)
// ---------------------------------------------------------------------------

/// Check file permissions and warn if not owner-only (non-Windows).
fn warnIfNotOwnerOnly(file_path: []const u8, io: std.Io) void {
    if (@import("builtin").os.tag == .windows) return;

    // Only check on POSIX systems
    const file = std.fs.cwd().openFile(file_path, .{ .mode = .read_only }) catch return;
    defer file.close();

    const stat = std.posix.fstat(file.handle) catch return;
    const mode: u32 = @intCast(stat.mode & 0o777);
    // Warn if file is readable/writable by group or others
    if (mode & 0o077 != 0) {
        if (io.out) |writer| {
            writer.print("Warning: {s} has permissions {o:0>3}, recommended 600\n", .{ file_path, mode }) catch {};
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "config: parse rule string no subject" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const rule = try parseRuleString(allocator, "Read", .allow);
    defer {
        allocator.free(rule.tool);
        if (rule.subject) |s| allocator.free(s);
    }

    try testing.expect(std.mem.eql(u8, rule.tool, "Read"));
    try testing.expect(rule.subject == null);
    try testing.expect(rule.action == .allow);
}

test "config: parse rule string with subject" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const rule = try parseRuleString(allocator, "Bash(rm -rf *)", .deny);
    defer {
        allocator.free(rule.tool);
        if (rule.subject) |s| allocator.free(s);
    }

    try testing.expect(std.mem.eql(u8, rule.tool, "Bash"));
    try testing.expect(rule.subject != null);
    try testing.expect(std.mem.eql(u8, rule.subject.?, "rm -rf *"));
    try testing.expect(rule.action == .deny);
}

test "config: parse rule string multiple parts" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const rule = try parseRuleString(allocator, "Bash(sudo rm -rf /)", .confirm);
    defer {
        allocator.free(rule.tool);
        if (rule.subject) |s| allocator.free(s);
    }

    try testing.expect(std.mem.eql(u8, rule.tool, "Bash"));
    try testing.expect(std.mem.eql(u8, rule.subject.?, "sudo rm -rf /"));
    try testing.expect(rule.action == .confirm);
}

test "config: parsePermissions from toml table" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Parse a TOML snippet to get a permissions table
    const toml_src =
        \\[permissions]
        \\mode = "deny"
        \\allow = ["Read", "Glob"]
        \\deny = ["Bash(rm -rf *)"]
    ;

    var parsed = try toml.parse(allocator, toml_src);
    defer toml.freeTable(allocator, &parsed);

    const perm_val = parsed.get("permissions").?;
    try testing.expect(perm_val == .table);

    const perm_config = try parsePermissions(allocator, &perm_val.table);
    defer {
        for (perm_config.rules) |r| {
            allocator.free(r.tool);
            if (r.subject) |s| allocator.free(s);
        }
        allocator.free(perm_config.rules);
    }

    try testing.expect(perm_config.mode == .deny);
    try testing.expect(perm_config.rules.len == 3);

    try testing.expect(std.mem.eql(u8, perm_config.rules[0].tool, "Read"));
    try testing.expect(perm_config.rules[0].subject == null);
    try testing.expect(perm_config.rules[0].action == .allow);

    try testing.expect(std.mem.eql(u8, perm_config.rules[1].tool, "Glob"));
    try testing.expect(perm_config.rules[1].action == .allow);

    try testing.expect(std.mem.eql(u8, perm_config.rules[2].tool, "Bash"));
    try testing.expect(std.mem.eql(u8, perm_config.rules[2].subject.?, "rm -rf *"));
    try testing.expect(perm_config.rules[2].action == .deny);
}

test "config: findZagentRoot walks up to .zagent" {
    // We can't easily test findZagentRoot without a real filesystem,
    // but we can verify it compiles and has the right signature.
    _ = findZagentRoot;
    _ = Config.load;
}

test "config: loadDotEnv handles missing file" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const io = testing.io;

    // Non-existent dir should return empty map
    var env_map = try loadDotEnv(allocator, "/nonexistent/path", io);
    defer {
        var it = env_map.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        env_map.deinit(allocator);
    }

    try testing.expect(env_map.count() == 0);
}

test "config: loadDotEnv strips quotes, handles inline comments, empty values" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const io = testing.io;

    const test_root = ".zig-test-config-env-quotes";
    const test_dir = try std.fs.path.join(allocator, &.{ test_root });
    defer {
        Io.Dir.cwd().deleteTree(io, test_dir) catch {};
        allocator.free(test_dir);
    }
    try Io.Dir.cwd().createDirPath(io, test_dir);

    // loadDotEnv looks for {project_root}/.zagent/.env
    const zagent_dir = try std.fs.path.join(allocator, &.{ test_dir, ".zagent" });
    defer allocator.free(zagent_dir);
    try Io.Dir.cwd().createDirPath(io, zagent_dir);

    const env_path = try std.fs.path.join(allocator, &.{ zagent_dir, ".env" });
    defer allocator.free(env_path);

    const content =
        \\KEY1="value1"
        \\KEY2='plain'
        \\KEY3=noquote
        \\KEY4="with#inside"#comment
        \\KEY5=value#outside
        \\KEY6=
        \\
    ;
    const file = try Io.Dir.cwd().createFile(io, env_path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, content);

    var env_map = try loadDotEnv(allocator, test_dir, io);
    defer {
        var it = env_map.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        env_map.deinit(allocator);
    }

    try testing.expectEqual(@as(usize, 6), env_map.count());
    try testing.expect(std.mem.eql(u8, env_map.get("KEY1").?, "value1"));
    try testing.expect(std.mem.eql(u8, env_map.get("KEY2").?, "'plain'"));
    try testing.expect(std.mem.eql(u8, env_map.get("KEY3").?, "noquote"));
    try testing.expect(std.mem.eql(u8, env_map.get("KEY4").?, "with#inside"));
    try testing.expect(std.mem.eql(u8, env_map.get("KEY5").?, "value"));
    try testing.expect(std.mem.eql(u8, env_map.get("KEY6").?, ""));
}

test "config: loadDotEnv handles inline comments and quoted values" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const io = testing.io;

    const test_root = ".zig-test-config-env-comments";
    const test_dir = try std.fs.path.join(allocator, &.{ test_root });
    defer {
        Io.Dir.cwd().deleteTree(io, test_dir) catch {};
        allocator.free(test_dir);
    }
    try Io.Dir.cwd().createDirPath(io, test_dir);

    // loadDotEnv looks for {project_root}/.zagent/.env
    const zagent_dir = try std.fs.path.join(allocator, &.{ test_dir, ".zagent" });
    defer allocator.free(zagent_dir);
    try Io.Dir.cwd().createDirPath(io, zagent_dir);

    const env_path = try std.fs.path.join(allocator, &.{ zagent_dir, ".env" });
    defer allocator.free(env_path);

    const content =
        \\# This is a comment
        \\API_KEY="sk-abc123"
        \\DB_URL="postgres://localhost:5432/db" # trailing comment
        \\EMPTY=
        \\QUOTED_EMPTY=""
        \\MIXED=abc#def#ghi
        \\HASH_IN_QUOTES="value#hash"
        \\
    ;
    const file = try Io.Dir.cwd().createFile(io, env_path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, content);

    var env_map = try loadDotEnv(allocator, test_dir, io);
    defer {
        var it = env_map.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        env_map.deinit(allocator);
    }

    try testing.expectEqual(@as(usize, 6), env_map.count());
    try testing.expect(std.mem.eql(u8, env_map.get("API_KEY").?, "sk-abc123"));
    try testing.expect(std.mem.eql(u8, env_map.get("DB_URL").?, "postgres://localhost:5432/db"));
    try testing.expect(std.mem.eql(u8, env_map.get("EMPTY").?, ""));
    try testing.expect(std.mem.eql(u8, env_map.get("QUOTED_EMPTY").?, ""));
    try testing.expect(std.mem.eql(u8, env_map.get("MIXED").?, "abc"));
    try testing.expect(std.mem.eql(u8, env_map.get("HASH_IN_QUOTES").?, "value#hash"));
}

test "config: parseProxyConfig custom mode" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const toml_src =
        \\[proxy]
        \\mode = "custom"
        \\url = "http://127.0.0.1:7890"
        \\no_proxy = ["localhost", "127.0.0.1"]
        \\
    ;

    var parsed = try toml.parse(allocator, toml_src);
    defer toml.freeTable(allocator, &parsed);

    const proxy_val = parsed.get("proxy").?;
    try testing.expect(proxy_val == .table);

    const proxy_cfg = try parseProxyConfig(allocator, &proxy_val.table);
    defer {
        allocator.free(proxy_cfg.mode);
        allocator.free(proxy_cfg.url);
        for (proxy_cfg.no_proxy) |item| allocator.free(item);
        allocator.free(proxy_cfg.no_proxy);
    }

    try testing.expect(std.mem.eql(u8, proxy_cfg.mode, "custom"));
    try testing.expect(std.mem.eql(u8, proxy_cfg.url, "http://127.0.0.1:7890"));
    try testing.expectEqual(@as(usize, 2), proxy_cfg.no_proxy.len);
    try testing.expect(std.mem.eql(u8, proxy_cfg.no_proxy[0], "localhost"));
    try testing.expect(std.mem.eql(u8, proxy_cfg.no_proxy[1], "127.0.0.1"));
}

test "config: parseProxyConfig defaults when missing" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const toml_src =
        \\[proxy]
        \\
    ;

    var parsed = try toml.parse(allocator, toml_src);
    defer toml.freeTable(allocator, &parsed);

    const proxy_val = parsed.get("proxy").?;
    try testing.expect(proxy_val == .table);

    const proxy_cfg = try parseProxyConfig(allocator, &proxy_val.table);
    defer {
        allocator.free(proxy_cfg.mode);
        allocator.free(proxy_cfg.url);
        allocator.free(proxy_cfg.no_proxy);
    }

    try testing.expect(std.mem.eql(u8, proxy_cfg.mode, "auto"));
    try testing.expect(proxy_cfg.url.len == 0);
    try testing.expect(proxy_cfg.no_proxy.len == 0);
}

test "config: parseProxyConfig off mode" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const toml_src =
        \\[proxy]
        \\mode = "off"
        \\
    ;

    var parsed = try toml.parse(allocator, toml_src);
    defer toml.freeTable(allocator, &parsed);

    const proxy_val = parsed.get("proxy").?;
    try testing.expect(proxy_val == .table);

    const proxy_cfg = try parseProxyConfig(allocator, &proxy_val.table);
    defer {
        allocator.free(proxy_cfg.mode);
        allocator.free(proxy_cfg.url);
        allocator.free(proxy_cfg.no_proxy);
    }

    try testing.expect(std.mem.eql(u8, proxy_cfg.mode, "off"));
    try testing.expect(proxy_cfg.url.len == 0);
    try testing.expect(proxy_cfg.no_proxy.len == 0);
}

test "config: getTomlString returns null for missing key" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const toml_src = "max_tokens = 4096\n";
    var parsed = try toml.parse(allocator, toml_src);
    defer toml.freeTable(allocator, &parsed);

    // default_model is not in the TOML
    const result = getTomlString(parsed, "default_model");
    try testing.expect(result == null);
}

test "config: parseProviderEntry handles missing fields (error path)" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Parse a minimal provider TOML to get a table
    const toml_src =
        \\[[providers]]
        \\name = "minimal"
        \\
    ;
    var parsed = try toml.parse(allocator, toml_src);
    defer toml.freeTable(allocator, &parsed);

    const providers_val = parsed.get("providers").?;
    const elem = providers_val.array[0];
    try testing.expect(elem == .table);

    const entry = try parseProviderEntry(allocator, &elem.table);
    defer {
        allocator.free(entry.name);
        allocator.free(entry.kind);
        allocator.free(entry.base_url);
        allocator.free(entry.default_model);
        allocator.free(entry.api_key_env);
        allocator.free(entry.api_key);
        allocator.free(entry.effort);
        for (entry.models) |m| allocator.free(m);
        allocator.free(entry.models);
    }

    try testing.expectEqualStrings("minimal", entry.name);
    try testing.expectEqualStrings("openai", entry.kind);  // default kind
    try testing.expect(entry.default_model.len == 0);  // empty when missing
    try testing.expectEqual(@as(u32, 0), entry.context_limit);  // default 0
}

test "config: parseProviderEntry with all fields" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const toml_src =
        \\[[providers]]
        \\name = "full"
        \\kind = "openai"
        \\base_url = "https://api.test.com"
        \\models = ["model-1", "model-2"]
        \\default_model = "model-1"
        \\api_key_env = "TEST_KEY"
        \\context_limit = 65536
        \\
    ;
    var parsed = try toml.parse(allocator, toml_src);
    defer toml.freeTable(allocator, &parsed);

    const providers_val = parsed.get("providers").?;
    const elem = providers_val.array[0];
    try testing.expect(elem == .table);

    const entry = try parseProviderEntry(allocator, &elem.table);
    defer {
        allocator.free(entry.name);
        allocator.free(entry.kind);
        allocator.free(entry.base_url);
        allocator.free(entry.default_model);
        allocator.free(entry.api_key_env);
        allocator.free(entry.api_key);
        allocator.free(entry.effort);
        for (entry.models) |m| allocator.free(m);
        allocator.free(entry.models);
    }

    try testing.expectEqualStrings("full", entry.name);
    try testing.expectEqualStrings("model-1", entry.default_model);
    try testing.expectEqual(@as(u32, 65536), entry.context_limit);
    try testing.expectEqual(@as(usize, 2), entry.models.len);
    try testing.expectEqualStrings("model-1", entry.models[0]);
    try testing.expectEqualStrings("model-2", entry.models[1]);
}
