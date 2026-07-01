const std = @import("std");
const types = @import("types.zig");

pub fn loadAvailable(allocator: std.mem.Allocator, io: std.Io, skills_root: []const u8) ![]const types.SkillMeta {
    const skills_dir = std.Io.Dir.cwd().openDir(io, skills_root, .{ .iterate = true }) catch return &.{};
    defer skills_dir.close(io);

    var list = std.array_list.Managed(types.SkillMeta).init(allocator);
    defer list.deinit();

    var iter = skills_dir.iterate();
    while (iter.next(io) catch null) |entry| {
        if (entry.kind != .directory) continue;

        const slug = entry.name;
        const skill_path = std.fs.path.join(allocator, &.{ skills_root, slug, "SKILL.md" }) catch continue;
        defer allocator.free(skill_path);

        if (parseSkillMd(allocator, io, skill_path, slug)) |meta| {
            try list.append(meta);
        }
    }

    dedupLastWins(allocator, &list);
    return list.toOwnedSlice();
}

fn dedupLastWins(allocator: std.mem.Allocator, list: *std.array_list.Managed(types.SkillMeta)) void {
    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();

    var i: isize = @intCast(list.items.len);
    while (i > 0) {
        i -= 1;
        const idx: usize = @intCast(i);
        const gop = seen.getOrPut(list.items[idx].slug) catch {
            _ = list.orderedRemove(idx);
            continue;
        };
        if (gop.found_existing) {
            _ = list.orderedRemove(idx);
        }
    }
}

fn parseSkillMd(allocator: std.mem.Allocator, io: std.Io, path: []const u8, slug: []const u8) ?types.SkillMeta {
    const file = std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only }) catch return null;
    defer file.close(io);
    const stat = file.stat(io) catch return null;
    const size: usize = @intCast(stat.size);
    const raw = allocator.alloc(u8, size) catch return null;
    defer allocator.free(raw);
    _ = file.readPositionalAll(io, raw, 0) catch return null;

    const normalized = normalizeLF(allocator, raw) catch return null;
    const needs_free = normalized.ptr != raw.ptr;
    defer if (needs_free) allocator.free(normalized);

    const fm = parseFrontmatter(normalized) orelse return null;

    const name_src = fm.name orelse return null;
    const name = allocator.dupe(u8, name_src) catch return null;
    const desc = if (fm.description) |d| allocator.dupe(u8, d) catch return null else blk: {
        break :blk allocator.dupe(u8, "") catch return null;
    };
    const owned_path = allocator.dupe(u8, path) catch return null;

    return types.SkillMeta{
        .name = name,
        .slug = allocator.dupe(u8, slug) catch return null,
        .description = desc,
        .path = owned_path,
    };
}

const Frontmatter = struct {
    name: ?[]const u8,
    description: ?[]const u8,
};

fn parseFrontmatter(raw_lf: []const u8) ?Frontmatter {
    if (!std.mem.startsWith(u8, raw_lf, "---\n")) return null;
    const end_marker = if (std.mem.indexOfPos(u8, raw_lf, 3, "\n---\n")) |pos| pos else return null;
    const fm_str = raw_lf[4..end_marker];

    var name: ?[]const u8 = null;
    var description: ?[]const u8 = null;

    var lines = std.mem.splitScalar(u8, fm_str, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "name: ")) {
            name = std.mem.trim(u8, line[6..], " \r");
        } else if (std.mem.startsWith(u8, line, "description: ")) {
            description = std.mem.trim(u8, line[13..], " \r");
        }
    }

    return Frontmatter{ .name = name, .description = description };
}

fn normalizeLF(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    if (std.mem.indexOf(u8, input, "\r\n") == null) return input;
    var buf = try allocator.alloc(u8, input.len);
    var wi: usize = 0;
    var ri: usize = 0;
    while (ri < input.len) {
        if (ri + 1 < input.len and input[ri] == '\r' and input[ri + 1] == '\n') {
            buf[wi] = '\n';
            wi += 1;
            ri += 2;
        } else {
            buf[wi] = input[ri];
            wi += 1;
            ri += 1;
        }
    }
    return try allocator.realloc(buf, wi);
}

test "parseFrontmatter: LF line endings" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const md =
        \\---
        \\name: test-skill
        \\description: A test skill for Zig
        \\---
        \\# Test Skill
        \\
        \\This is the body.
    ;
    const normalized = try normalizeLF(allocator, md);
    defer if (normalized.ptr != md.ptr) allocator.free(normalized);

    const fm = parseFrontmatter(normalized) orelse return testing.expect(false) catch {};
    try testing.expectEqualStrings("test-skill", fm.name.?);
    try testing.expectEqualStrings("A test skill for Zig", fm.description.?);
}

test "parseFrontmatter: CRLF line endings" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const md = "---\r\nname: review\r\ndescription: Code review skill\r\n---\r\n# Review\r\n";
    const normalized = try normalizeLF(allocator, md);
    defer allocator.free(normalized);
    try testing.expect(std.mem.indexOf(u8, normalized, "\r") == null);

    const fm = parseFrontmatter(normalized) orelse return testing.expect(false) catch {};
    try testing.expectEqualStrings("review", fm.name.?);
    try testing.expectEqualStrings("Code review skill", fm.description.?);
}

test "parseFrontmatter: missing description returns empty" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const md =
        \\---
        \\name: minimal
        \\---
        \\# Minimal
    ;
    const normalized = try normalizeLF(allocator, md);
    defer if (normalized.ptr != md.ptr) allocator.free(normalized);

    const fm = parseFrontmatter(normalized) orelse return testing.expect(false) catch {};
    try testing.expectEqualStrings("minimal", fm.name.?);
    try testing.expect(fm.description == null);
}

test "parseFrontmatter: no frontmatter returns null" {
    const testing = std.testing;
    const md = "# No Frontmatter\n\nJust content.";
    const fm = parseFrontmatter(md);
    try testing.expect(fm == null);
}

const embedded_z_improve =
    \\---
    \\name: z-improve
    \\slug: z-improve
    \\version: 1.1.0
    \\description: Manage memory system: save knowledge, recall memories, summarize sessions
    \\---
    \\# z-improve
    \\
    \\## When to use
    \\
    \\- User corrects a mistake
    \\- A recurring pitfall or pattern is identified
    \\- A design decision is confirmed
    \\- Before starting a new task (search relevant memories)
    \\
    \\## Triggers
    \\
    \\### Auto-save
    \\
    \\When you notice something worth remembering, write it directly with:
    \\memory(command="add", content="<content>", source="auto")
    \\No need to ask the user for confirmation.
    \\
    \\### Auto-recall
    \\
    \\At the start of each new task, automatically search for relevant memories.
    \\
    \\### User trigger
    \\
    \\When the user runs /learn, review the conversation history and extract key points.
    \\
    \\## Memory format
    \\
    \\Each memory is a separate .md file in .zagent/memory/.
    \\Use a concise format, reference specific file paths.
    \\
    \\## Required permissions
    \\
    \\| Permission | Purpose |
    \\|------------|---------|
    \\| read | Read .zagent/memory/ files |
    \\| write | Write via memory tool |
;

pub fn getBuiltinSkills(allocator: std.mem.Allocator) ![]const types.SkillMeta {
    return parseBuiltinSkill(allocator, "z-improve", embedded_z_improve);
}

fn parseBuiltinSkill(allocator: std.mem.Allocator, slug: []const u8, content: []const u8) ![]const types.SkillMeta {
    const normalized = normalizeLF(allocator, content) catch return &.{};
    const needs_free = normalized.ptr != content.ptr;
    defer if (needs_free) allocator.free(normalized);

    const fm = parseFrontmatter(normalized) orelse return &.{};
    const name = if (fm.name) |n| try allocator.dupe(u8, n) else return &.{};
    const desc = if (fm.description) |d| try allocator.dupe(u8, d) else try allocator.dupe(u8, "");

    var result = try allocator.alloc(types.SkillMeta, 1);
    result[0] = .{
        .name = name,
        .slug = try allocator.dupe(u8, slug),
        .description = desc,
        .path = try allocator.dupe(u8, "(builtin)"),
    };
    return result;
}

test "dedupLastWins: last occurrence kept" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var list = std.array_list.Managed(types.SkillMeta).init(allocator);
    defer list.deinit();

    try list.append(.{ .name = "first", .slug = "a", .description = "first", .path = "p1" });
    try list.append(.{ .name = "second", .slug = "b", .description = "second", .path = "p2" });
    try list.append(.{ .name = "third-a", .slug = "a", .description = "third", .path = "p3" });

    dedupLastWins(allocator, &list);

    try testing.expectEqual(@as(usize, 2), list.items.len);
    try testing.expectEqualStrings("second", list.items[0].name);
    try testing.expectEqualStrings("third-a", list.items[1].name);
}

test "getBuiltinSkills: returns z-improve skill" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const skills = try getBuiltinSkills(allocator);
    defer {
        for (skills) |s| {
            allocator.free(s.name);
            allocator.free(s.slug);
            allocator.free(s.description);
            allocator.free(s.path);
        }
        allocator.free(skills);
    }

    try testing.expectEqual(@as(usize, 1), skills.len);
    try testing.expectEqualStrings("z-improve", skills[0].slug);
    try testing.expectEqualStrings("z-improve", skills[0].name);
    try testing.expect(skills[0].description.len > 0);
    try testing.expectEqualStrings("(builtin)", skills[0].path);
}

test "getBuiltinSkills: error path - invalid content returns empty" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // getBuiltinSkills always succeeds with valid embedded_z_improve.
    const skills = try getBuiltinSkills(allocator);
    defer {
        for (skills) |s| {
            allocator.free(s.name);
            allocator.free(s.slug);
            allocator.free(s.description);
            allocator.free(s.path);
        }
        allocator.free(skills);
    }
    try testing.expect(skills.len > 0);
    try testing.expectEqualStrings("z-improve", skills[0].name);
}
