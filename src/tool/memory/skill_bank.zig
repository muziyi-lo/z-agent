const std = @import("std");
const json = @import("../json.zig");
const root_dir = @import("../root_dir.zig");
const parse = @import("parse.zig");

const Io = std.Io;

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

/// A skill version evolution entry recording when a change happened.
const EvolutionEntry = struct {
    version: u32,
    date: []const u8,
    change: []const u8,
};

/// A skill entry in the skill bank tracking version history.
const SkillEntry = struct {
    slug: []const u8,
    name: []const u8,
    version: u32,
    evolution: []EvolutionEntry,
};

/// The complete skill bank, persisted to `.zagent/skill-bank.json`.
const SkillBank = struct {
    skills: []SkillEntry,
};

// ---------------------------------------------------------------------------
// File path
// ---------------------------------------------------------------------------

/// Build path to skill-bank.json under project_root/.zagent/.
/// Caller owns returned slice, must free.
fn bankPath(allocator: std.mem.Allocator) ![]const u8 {
    if (root_dir.project_root.len > 0) {
        return std.fs.path.join(allocator, &.{ root_dir.project_root, ".zagent", "skill-bank.json" });
    }
    return std.fs.path.join(allocator, &.{ ".zagent", "skill-bank.json" });
}

// ---------------------------------------------------------------------------
// File I/O
// ---------------------------------------------------------------------------

/// Read entire file into allocated buffer. Returns null if file doesn't exist.
/// Caller owns returned slice, must free.
fn readFile(allocator: std.mem.Allocator, io: Io, path: []const u8) ?[]const u8 {
    const file = Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only }) catch return null;
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
}

/// Atomic write: write to .tmp then rename to target.
/// Source: tool/memory/parse.zig — atomic write pattern
fn atomicWrite(allocator: std.mem.Allocator, io: Io, path: []const u8, content: []const u8) !void {
    const cwd = Io.Dir.cwd();
    if (std.fs.path.dirname(path)) |parent| {
        cwd.createDirPath(io, parent) catch {};
    }

    const abs_path = abs_path: {
        if (std.fs.path.isAbsolute(path)) break :abs_path path;
        var cwd_buf: [4096]u8 = undefined;
        const cwd_len = cwd.realPath(io, &cwd_buf) catch break :abs_path path;
        const joined = try std.fs.path.join(allocator, &.{ cwd_buf[0..cwd_len], path });
        break :abs_path joined;
    };
    defer if (abs_path.ptr != path.ptr) allocator.free(abs_path);

    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{abs_path});
    defer allocator.free(tmp_path);

    var rename_succeeded = false;
    defer if (!rename_succeeded) cwd.deleteFile(io, tmp_path) catch {};

    {
        const file = cwd.createFile(io, tmp_path, .{}) catch |err| return err;
        defer file.close(io);
        file.writeStreamingAll(io, content) catch |err| return err;
    }

    try Io.Dir.renameAbsolute(tmp_path, abs_path, io);
    rename_succeeded = true;
}

// ---------------------------------------------------------------------------
// JSON deserialization helpers
// ---------------------------------------------------------------------------

/// Get string from ObjectMap, or null if missing/not string.
fn getString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const val = obj.get(key) orelse return null;
    if (val == .string) return val.string;
    return null;
}

/// Get integer from ObjectMap, or default if missing.
fn getInt(obj: std.json.ObjectMap, key: []const u8, default: u32) u32 {
    const val = obj.get(key) orelse return default;
    if (val == .integer) return @as(u32, @intCast(val.integer));
    return default;
}

/// Parse an EvolutionEntry from a JSON object.
fn parseEvolutionEntry(allocator: std.mem.Allocator, val: std.json.Value) !EvolutionEntry {
    const obj = val.object;
    return EvolutionEntry{
        .version = getInt(obj, "version", 0),
        .date = try allocator.dupe(u8, getString(obj, "date") orelse ""),
        .change = try allocator.dupe(u8, getString(obj, "change") orelse ""),
    };
}

/// Parse a SkillEntry from a JSON object.
fn parseSkillEntry(allocator: std.mem.Allocator, val: std.json.Value) !SkillEntry {
    const obj = val.object;
    var evolution_list = std.array_list.Managed(EvolutionEntry).init(allocator);
    errdefer evolution_list.deinit();

    if (obj.get("evolution")) |ev_arr| {
        if (ev_arr == .array) {
            for (ev_arr.array.items) |item| {
                const ev = parseEvolutionEntry(allocator, item) catch continue;
                try evolution_list.append(ev);
            }
        }
    }

    return SkillEntry{
        .slug = try allocator.dupe(u8, getString(obj, "slug") orelse ""),
        .name = try allocator.dupe(u8, getString(obj, "name") orelse ""),
        .version = getInt(obj, "version", 1),
        .evolution = try evolution_list.toOwnedSlice(),
    };
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Load skill-bank.json, returns empty SkillBank when file is missing or corrupt.
pub fn load(allocator: std.mem.Allocator, io: Io) SkillBank {
    const path = bankPath(allocator) catch return SkillBank{ .skills = &.{} };
    defer allocator.free(path);

    const content = readFile(allocator, io, path) orelse return SkillBank{ .skills = &.{} };
    defer allocator.free(content);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch return SkillBank{ .skills = &.{} };
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return SkillBank{ .skills = &.{} };

    var skill_list = std.array_list.Managed(SkillEntry).init(allocator);
    errdefer {
        for (skill_list.items) |*s| {
            allocator.free(s.slug);
            allocator.free(s.name);
            for (s.evolution) |*ev| {
                allocator.free(ev.date);
                allocator.free(ev.change);
            }
            if (s.evolution.len > 0) allocator.free(s.evolution);
        }
        skill_list.deinit();
    }

    if (root.object.get("skills")) |skills_val| {
        if (skills_val == .array) {
            for (skills_val.array.items) |item| {
                const entry = parseSkillEntry(allocator, item) catch continue;
                skill_list.append(entry) catch {};
            }
        }
    }

    return SkillBank{ .skills = skill_list.toOwnedSlice() catch &.{} };
}

/// Save SkillBank to file (atomic write via tmp+rename).
pub fn save(allocator: std.mem.Allocator, io: Io, bank: *const SkillBank) !void {
    const path = try bankPath(allocator);
    defer allocator.free(path);

    var buf = std.array_list.Managed(u8).init(allocator);
    defer buf.deinit();

    try buf.appendSlice("{\"skills\":[");
    for (bank.skills, 0..) |skill, i| {
        if (i > 0) try buf.append(',');
        try buf.append('{');
        try json.putString(&buf, "slug", skill.slug);
        try buf.append(',');
        try json.putString(&buf, "name", skill.name);
        try buf.append(',');
        try json.putInt(&buf, "version", skill.version);
        try buf.append(',');
        try buf.appendSlice("\"evolution\":[");
        for (skill.evolution, 0..) |ev, j| {
            if (j > 0) try buf.append(',');
            try buf.append('{');
            try json.putInt(&buf, "version", ev.version);
            try buf.append(',');
            try json.putString(&buf, "date", ev.date);
            try buf.append(',');
            try json.putString(&buf, "change", ev.change);
            try buf.append('}');
        }
        try buf.append(']');
        try buf.append('}');
    }
    try buf.appendSlice("]}");

    const content = try buf.toOwnedSlice();
    defer allocator.free(content);

    try atomicWrite(allocator, io, path, content);
}

/// List all skills as a JSON string `{"skills":[...]}`.
/// Caller owns returned slice, must free.
pub fn listSkills(bank: *const SkillBank, allocator: std.mem.Allocator) []const u8 {
    var buf = std.array_list.Managed(u8).init(allocator);
    defer buf.deinit();

    json.puts(&buf, "{\"skills\":[") catch return allocOomError(allocator);
    for (bank.skills, 0..) |skill, i| {
        if (i > 0) json.putc(&buf, ',') catch return allocOomError(allocator);
        json.putc(&buf, '{') catch return allocOomError(allocator);
        json.putString(&buf, "slug", skill.slug) catch return allocOomError(allocator);
        json.putc(&buf, ',') catch return allocOomError(allocator);
        json.putString(&buf, "name", skill.name) catch return allocOomError(allocator);
        json.putc(&buf, ',') catch return allocOomError(allocator);
        json.putInt(&buf, "version", skill.version) catch return allocOomError(allocator);
        json.putc(&buf, ',') catch return allocOomError(allocator);
        json.puts(&buf, "\"evolution\":[") catch return allocOomError(allocator);
        for (skill.evolution, 0..) |ev, j| {
            if (j > 0) json.putc(&buf, ',') catch return allocOomError(allocator);
            json.putc(&buf, '{') catch return allocOomError(allocator);
            json.putInt(&buf, "version", ev.version) catch return allocOomError(allocator);
            json.putc(&buf, ',') catch return allocOomError(allocator);
            json.putString(&buf, "date", ev.date) catch return allocOomError(allocator);
            json.putc(&buf, ',') catch return allocOomError(allocator);
            json.putString(&buf, "change", ev.change) catch return allocOomError(allocator);
            json.putc(&buf, '}') catch return allocOomError(allocator);
        }
        json.puts(&buf, "]") catch return allocOomError(allocator);
        json.putc(&buf, '}') catch return allocOomError(allocator);
    }
    json.puts(&buf, "]}") catch return allocOomError(allocator);
    return json.finish(&buf);
}

/// Update specified skill: increment version, append evolution record.
/// If skill with slug doesn't exist, creates a new one with version 1.
pub fn updateSkill(bank: *SkillBank, allocator: std.mem.Allocator, io: Io, slug: []const u8, change: []const u8) !void {
    const date_str = parse.todayFormattedDate(io);

    // Find existing skill by slug
    for (bank.skills) |*skill| {
        if (std.mem.eql(u8, skill.slug, slug)) {
            // Found: increment version, append evolution
            skill.version += 1;
            var ev_list = std.array_list.Managed(EvolutionEntry).init(allocator);
            defer ev_list.deinit();
            try ev_list.appendSlice(skill.evolution);
            if (skill.evolution.len > 0) allocator.free(skill.evolution);
            try ev_list.append(EvolutionEntry{
                .version = skill.version,
                .date = try allocator.dupe(u8, &date_str),
                .change = try allocator.dupe(u8, change),
            });
            skill.evolution = try ev_list.toOwnedSlice();
            return;
        }
    }

    // Not found: create new skill entry
    var ev_list = std.array_list.Managed(EvolutionEntry).init(allocator);
    defer ev_list.deinit();
    try ev_list.append(EvolutionEntry{
        .version = 1,
        .date = try allocator.dupe(u8, &date_str),
        .change = try allocator.dupe(u8, change),
    });

    const new_entry = SkillEntry{
        .slug = try allocator.dupe(u8, slug),
        .name = try allocator.dupe(u8, slug),
        .version = 1,
        .evolution = try ev_list.toOwnedSlice(),
    };

    var skill_list = std.array_list.Managed(SkillEntry).init(allocator);
    defer skill_list.deinit();
    try skill_list.appendSlice(bank.skills);
    if (bank.skills.len > 0) allocator.free(bank.skills);
    try skill_list.append(new_entry);
    bank.skills = try skill_list.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// cmdSkillBank — top-level dispatcher for skill-bank commands
// ---------------------------------------------------------------------------

/// Execute skill-bank subcommands: list or update. Returns JSON output.
/// Source: tool/memory/skill_bank.zig — skill bank command dispatcher
pub fn cmdSkillBank(allocator: std.mem.Allocator, io: Io, args: std.json.ObjectMap) []const u8 {
    const subcommand_val = args.get("subcommand") orelse
        return allocError(allocator, "missing 'subcommand' for skill-bank");
    const subcommand = if (subcommand_val == .string) subcommand_val.string else
        return allocError(allocator, "'subcommand' must be a string");

    if (std.mem.eql(u8, subcommand, "list")) {
        var bank = load(allocator, io);
        defer {
            for (bank.skills) |*s| {
                allocator.free(s.slug);
                allocator.free(s.name);
                for (s.evolution) |*ev| {
                    allocator.free(ev.date);
                    allocator.free(ev.change);
                }
                if (s.evolution.len > 0) allocator.free(s.evolution);
            }
            if (bank.skills.len > 0) allocator.free(bank.skills);
        }
        return listSkills(&bank, allocator);
    } else if (std.mem.eql(u8, subcommand, "update")) {
        const slug_val = args.get("slug") orelse
            return allocError(allocator, "missing 'slug' for skill-bank update");
        const slug = if (slug_val == .string) slug_val.string else
            return allocError(allocator, "'slug' must be a string");

        const change_val = args.get("change") orelse
            return allocError(allocator, "missing 'change' for skill-bank update");
        const change = if (change_val == .string) change_val.string else
            return allocError(allocator, "'change' must be a string");

        var bank = load(allocator, io);
        defer {
            for (bank.skills) |*s| {
                allocator.free(s.slug);
                allocator.free(s.name);
                for (s.evolution) |*ev| {
                    allocator.free(ev.date);
                    allocator.free(ev.change);
                }
                if (s.evolution.len > 0) allocator.free(s.evolution);
            }
            if (bank.skills.len > 0) allocator.free(bank.skills);
        }

        updateSkill(&bank, allocator, io, slug, change) catch return allocOomError(allocator);
        save(allocator, io, &bank) catch return allocError(allocator, "save skill-bank failed");

        // Find version after update
        var version: u32 = 0;
        for (bank.skills) |s| {
            if (std.mem.eql(u8, s.slug, slug)) {
                version = s.version;
                break;
            }
        }

        var buf = std.array_list.Managed(u8).init(allocator);
        defer buf.deinit();
        json.puts(&buf, "{\"updated\":true,\"slug\":") catch return allocOomError(allocator);
        json.escapeJson(&buf, slug) catch return allocOomError(allocator);
        json.puts(&buf, ",\"version\":") catch return allocOomError(allocator);
        var nb: [32]u8 = undefined;
        const ns = std.fmt.bufPrint(&nb, "{d}", .{version}) catch "0";
        json.puts(&buf, ns) catch return allocOomError(allocator);
        json.puts(&buf, "}") catch return allocOomError(allocator);
        return json.finish(&buf);
    } else {
        return allocError(allocator, "unknown skill-bank subcommand");
    }
}

// ---------------------------------------------------------------------------
// Error helpers
// ---------------------------------------------------------------------------

fn allocError(allocator: std.mem.Allocator, msg: []const u8) []const u8 {
    return std.fmt.allocPrint(allocator, "Error: {s}", .{msg}) catch allocOomError(allocator);
}

fn allocOomError(allocator: std.mem.Allocator) []const u8 {
    return std.fmt.allocPrint(allocator, "Error: OOM", .{}) catch "Error: OOM";
}
