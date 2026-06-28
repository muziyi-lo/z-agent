const std = @import("std");
const types = @import("types.zig");

/// A permission rule matching by tool name + optional subject glob.
pub const Rule = struct {
    tool: []const u8,
    subject: ?[]const u8 = null,
    action: types.PermissionAction,
};

/// Permission config from TOML: mode + rules array.
pub const PermissionConfig = struct {
    mode: types.PermissionAction = .confirm,
    rules: []const Rule = &.{},
};

/// Engine evaluates a (tool, subject) pair against rules.
/// Uses deny > ask > confirm > allow priority: first match wins.
pub const Engine = struct {
    mode: types.PermissionAction,
    rules: []const Rule,

    pub fn evaluate(self: *const Engine, tool_name: []const u8, subject: ?[]const u8) types.PermissionAction {
        for (self.rules) |rule| {
            if (matchRule(rule, tool_name, subject)) {
                return rule.action;
            }
        }
        return self.mode;
    }
};

/// Permission manager with learned decisions cache.
pub const Permission = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    config: PermissionConfig,
    engine: Engine,
    learned: std.StringHashMap(types.PermissionAction),

    pub fn init(allocator: std.mem.Allocator, io: std.Io, config: PermissionConfig) Permission {
        return Permission{
            .allocator = allocator,
            .io = io,
            .config = config,
            .engine = Engine{ .mode = config.mode, .rules = config.rules },
            .learned = std.StringHashMap(types.PermissionAction).init(allocator),
        };
    }

    /// Check permission for a tool call. Backward-compatible signature:
    /// `tool_path` and `command` are merged into a single subject (first non-null wins).
    pub fn check(
        self: *Permission,
        tool: []const u8,
        tool_path: ?[]const u8,
        command: ?[]const u8,
        trust: bool,
    ) types.PermissionAction {
        if (trust) return .allow;

        // Merge path/command into subject (path first, then command)
        const subject = tool_path orelse command;

        // Check learned table first
        if (subject) |s| {
            if (self.checkLearnedKey(tool, s)) |action| return action;
        } else {
            if (self.checkLearnedKey(tool, "")) |action| return action;
        }

        // Check rules via engine
        return self.engine.evaluate(tool, subject);
    }

    fn checkLearnedKey(self: *const Permission, tool: []const u8, suffix: []const u8) ?types.PermissionAction {
        var buf: [2048]u8 = undefined;
        const key = if (suffix.len == 0)
            std.fmt.bufPrint(&buf, "{s}:", .{tool}) catch return null
        else
            std.fmt.bufPrint(&buf, "{s}:{s}", .{ tool, suffix }) catch return null;
        return self.learned.get(key);
    }

    pub fn learn(self: *Permission, tool: []const u8, path: ?[]const u8, action: types.PermissionAction) void {
        const key = if (path) |p|
            std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ tool, p }) catch return
        else
            std.fmt.allocPrint(self.allocator, "{s}:", .{tool}) catch return;
        self.learned.put(key, action) catch {
            self.allocator.free(key);
        };
    }

    pub fn deinit(self: *Permission) void {
        var it = self.learned.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.learned.deinit();
    }
};

/// Match a single rule against (tool_name, subject).
fn matchRule(rule: Rule, tool_name: []const u8, subject: ?[]const u8) bool {
    // Tool matching: support "*" for wildcard
    if (!std.mem.eql(u8, rule.tool, "*")) {
        if (!std.mem.eql(u8, rule.tool, tool_name)) return false;
    }

    // Subject matching: if rule has a subject, the actual subject must exist and match
    if (rule.subject) |rule_subject| {
        const actual_subject = subject orelse return false;
        return matchGlob(rule_subject, actual_subject);
    }

    // Tool-only rule: matches by tool name only
    return true;
}

/// Simple glob matching: supports `*` (any chars except separator) and `**` (any chars including separator).
fn matchGlob(pattern: []const u8, subject: []const u8) bool {
    if (std.mem.eql(u8, pattern, "**")) return true;

    var pi: usize = 0;
    var si: usize = 0;

    while (pi < pattern.len) {
        if (si >= subject.len) {
            return allStarPattern(pattern[pi..]);
        }

        const pc = pattern[pi];
        const sc = subject[si];

        if (pc == '*') {
            pi += 1;
            if (pi == pattern.len) {
                // Trailing '*' matches anything
                return true;
            }
            // Try to match the rest of the pattern at various positions
            while (si < subject.len) {
                if (matchGlob(pattern[pi..], subject[si..])) return true;
                si += 1;
            }
            return false;
        }

        if (pc != sc) return false;
        pi += 1;
        si += 1;
    }

    return si == subject.len;
}

fn allStarPattern(pattern: []const u8) bool {
    for (pattern) |c| {
        if (c != '*') return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "permission: allow rule matches" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const io = testing.io;

    const rules = [_]Rule{
        .{ .tool = "write_file", .action = .allow },
    };
    const config = PermissionConfig{
        .mode = .deny,
        .rules = &rules,
    };
    var perm = Permission.init(allocator, io, config);
    defer perm.deinit();

    const action = perm.check("write_file", "foo.txt", null, false);
    try testing.expect(action == .allow);
}

test "permission: deny rule matches" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const io = testing.io;

    const rules = [_]Rule{
        .{ .tool = "bash", .action = .deny },
    };
    const config = PermissionConfig{
        .mode = .allow,
        .rules = &rules,
    };
    var perm = Permission.init(allocator, io, config);
    defer perm.deinit();

    const action = perm.check("bash", null, "echo hi", false);
    try testing.expect(action == .deny);
}

test "permission: no matching rule falls back to mode" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const io = testing.io;

    const config = PermissionConfig{
        .mode = .confirm,
        .rules = &.{},
    };
    var perm = Permission.init(allocator, io, config);
    defer perm.deinit();

    const action = perm.check("write_file", "test.txt", null, false);
    try testing.expect(action == .confirm);
}

test "permission: trust=true skips all rules" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const io = testing.io;

    const rules = [_]Rule{
        .{ .tool = "*", .action = .deny },
    };
    const config = PermissionConfig{
        .mode = .deny,
        .rules = &rules,
    };
    var perm = Permission.init(allocator, io, config);
    defer perm.deinit();

    const action = perm.check("write_file", "test.txt", null, true);
    try testing.expect(action == .allow);
}

test "permission: subject glob matching" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const io = testing.io;

    const rules = [_]Rule{
        .{ .tool = "bash", .subject = "rm -rf *", .action = .deny },
        .{ .tool = "bash", .subject = "git *", .action = .allow },
    };
    const config = PermissionConfig{
        .mode = .confirm,
        .rules = &rules,
    };
    var perm = Permission.init(allocator, io, config);
    defer perm.deinit();

    try testing.expect(perm.check("bash", null, "rm -rf /tmp", false) == .deny);
    try testing.expect(perm.check("bash", null, "git status", false) == .allow);
    try testing.expect(perm.check("bash", null, "echo hi", false) == .confirm);
}

test "permission: learned table takes priority" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const io = testing.io;

    const rules = [_]Rule{
        .{ .tool = "write_file", .action = .deny },
    };
    const config = PermissionConfig{
        .mode = .deny,
        .rules = &rules,
    };
    var perm = Permission.init(allocator, io, config);
    defer perm.deinit();

    // Learn an allow for this specific path
    perm.learn("write_file", "safe.txt", .allow);

    const action = perm.check("write_file", "safe.txt", null, false);
    try testing.expect(action == .allow);
}

test "permission: wildcard tool matches all" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const io = testing.io;

    const rules = [_]Rule{
        .{ .tool = "*", .action = .deny },
    };
    const config = PermissionConfig{
        .mode = .allow,
        .rules = &rules,
    };
    var perm = Permission.init(allocator, io, config);
    defer perm.deinit();

    try testing.expect(perm.check("bash", null, "echo hi", false) == .deny);
    try testing.expect(perm.check("write_file", "a.txt", null, false) == .deny);
    try testing.expect(perm.check("task", null, null, false) == .deny);
}

test "permission: tool-only rule (no subject) matches by tool name" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const io = testing.io;

    const rules = [_]Rule{
        .{ .tool = "task", .action = .deny },
    };
    const config = PermissionConfig{
        .mode = .allow,
        .rules = &rules,
    };
    var perm = Permission.init(allocator, io, config);
    defer perm.deinit();

    try testing.expect(perm.check("task", null, null, false) == .deny);
    try testing.expect(perm.check("bash", null, "echo hi", false) == .allow);
}

test "permission: subject with path (file tool)" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const io = testing.io;

    const rules = [_]Rule{
        .{ .tool = "write_file", .subject = "src/**", .action = .allow },
        .{ .tool = "write_file", .subject = "*.txt", .action = .deny },
    };
    const config = PermissionConfig{
        .mode = .confirm,
        .rules = &rules,
    };
    var perm = Permission.init(allocator, io, config);
    defer perm.deinit();

    try testing.expect(perm.check("write_file", "src/main.zig", null, false) == .allow);
    try testing.expect(perm.check("write_file", "test.txt", null, false) == .deny);
    try testing.expect(perm.check("write_file", "unknown.json", null, false) == .confirm);
}

test "permission: rule with subject but no actual subject doesn't match" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const io = testing.io;

    const rules = [_]Rule{
        .{ .tool = "bash", .subject = "rm *", .action = .deny },
    };
    const config = PermissionConfig{
        .mode = .allow,
        .rules = &rules,
    };
    var perm = Permission.init(allocator, io, config);
    defer perm.deinit();

    // No subject (null) should not match a rule with a subject
    try testing.expect(perm.check("task", null, null, false) == .allow);
}

test "permission: engine evaluate prioritizes deny over ask" {
    const testing = std.testing;

    const rules = [_]Rule{
        .{ .tool = "bash", .subject = "rm *", .action = .deny },
        .{ .tool = "bash", .subject = "rm *", .action = .allow },
    };
    var engine = Engine{ .mode = .confirm, .rules = &rules };
    try testing.expect(engine.evaluate("bash", "rm -rf /") == .deny);
}

test "permission: engine evaluate with subject matching" {
    const testing = std.testing;

    const rules = [_]Rule{
        .{ .tool = "grep", .subject = "*.zig", .action = .allow },
        .{ .tool = "grep", .action = .confirm },
    };
    var engine = Engine{ .mode = .deny, .rules = &rules };
    try testing.expect(engine.evaluate("grep", "main.zig") == .allow);
    try testing.expect(engine.evaluate("grep", "*.toml") == .confirm);
}

test "permission: matchGlob basic" {
    const testing = std.testing;
    try testing.expect(matchGlob("**", "any/path/file.txt"));
    try testing.expect(matchGlob("*.txt", "file.txt"));
    try testing.expect(!matchGlob("*.txt", "file.md"));
    try testing.expect(matchGlob("rm *", "rm -rf /test"));
    try testing.expect(!matchGlob("rm *", "echo rm"));
}
