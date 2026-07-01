const std = @import("std");
const Io = std.Io;

const embedded_init =
    \\---
    \\description: Analyze project and write a concise AGENTS.md
    \\args: (optional extra instructions)
    \\---
    \\## How to investigate
    \\
    \\Read the highest-value sources first:
    \\- README, build config, lockfiles
    \\- CI workflows and task runner config
    \\- existing instruction files (AGENTS.md, CLAUDE.md)
    \\- representative code files for architecture
    \\
    \\Prefer executable sources of truth over prose.
    \\
    \\Avoid reading generated or dependency directories (zig-cache, node_modules, .git, target, dist, build, .next). Use glob with -Depth N or grep with -Path/-Filter to keep searches bounded.
    \\
    \\## What to extract
    \\
    \\Look for high-signal facts an agent would miss:
    \\- exact developer commands, especially non-obvious ones
    \\- how to run a single test
    \\- monorepo boundaries and entrypoints
    \\- framework or toolchain quirks
    \\- testing quirks: fixtures, integration prerequisites
    \\- repo-specific conventions that differ from defaults
    \\
    \\Good AGENTS.md content is hard-earned context that took multiple files to infer.
    \\
    \\## Writing rules
    \\
    \\Every line must answer: "Would an agent miss this without help?" If no, delete it.
    \\Only project-specific rules. Skip generic language advice.
    \\NO directory trees or file catalogs.
    \\If existing AGENTS.md exists, improve it in place, don't replace blindly.
    \\
    \\## Questions
    \\
    \\Only ask the user if the repo cannot answer something important.
    \\Use the question tool for at most one short batch.
    \\
    \\${args}
;

const embedded_learn =
    \\---
    \\description: Review the current conversation and save notable knowledge to memory
    \\args: (optional) focus area
    \\---
    \\
    \\Review the current conversation (both sent and received messages) and extract knowledge worth keeping long-term.
    \\
    \\Focus on:
    \\- Mistakes the user corrected
    \\- Architecture design decisions made
    \\- Recurring pitfalls or patterns
    \\- Project conventions and rules
    \\
    \\Save to memory using: memory(command="add", content="<distilled content>", source="auto")
    \\Check for duplicates first with memory(command="recall", query="<keyword>") before adding.
    \\
    \\${args}
;

const embedded_recall =
    \\---
    \\description: Search existing memory entries relevant to the current task
    \\args: search keywords
    \\---
    \\
    \\Search memory with: memory(command="recall", query="<keywords>")
    \\Present the results to the user and explain how they relate to the current task.
;

const embedded_summary =
    \\---
    \\description: Summarize key discussions, findings, and decisions from this session
    \\args: (optional) focus area
    \\---
    \\
    \\Review the full session message history and generate a structured summary:
    \\
    \\- Problems solved / bugs fixed
    \\- Design decisions confirmed
    \\- Features added / files modified
    \\- Action items
    \\
    \\For knowledge worth keeping long-term, save each point to memory using:
    \\memory(command="add", content="<知识点>", source="自动")
;

pub const MatchResult = union(enum) {
    help,
    list,
    name: []const u8,
    template: []const u8,
    new_session,
    switch_session: []const u8,
    model: []const u8,
    list_models,
};

pub const Commands = struct {
    builtins: []const Builtin,
    templates: []const Template,

    pub const Builtin = struct {
        name: []const u8, // "/list", "/name", "/new"
        takes_args: bool,
    };

    pub const Template = struct {
        name: []const u8,
        description: []const u8,
        args_hint: []const u8,
        content: []const u8,
    };

    pub fn init(allocator: std.mem.Allocator, io: Io) !Commands {
        const builtins = [_]Builtin{
            .{ .name = "/new", .takes_args = false },
            .{ .name = "/list", .takes_args = false },
            .{ .name = "/name", .takes_args = true },
            .{ .name = "/session", .takes_args = true },
            .{ .name = "/model", .takes_args = true },
            .{ .name = "/exit", .takes_args = false },
            .{ .name = "/quit", .takes_args = false },
            .{ .name = "/help", .takes_args = false },
        };

        var templates = std.array_list.Managed(Template).init(allocator);

        const init_t = try parseTemplateRaw(allocator, "init", embedded_init);
        try templates.append(init_t);
        const learn_t = try parseTemplateRaw(allocator, "learn", embedded_learn);
        try templates.append(learn_t);
        const recall_t = try parseTemplateRaw(allocator, "recall", embedded_recall);
        try templates.append(recall_t);
        const summary_t = try parseTemplateRaw(allocator, "summary", embedded_summary);
        try templates.append(summary_t);

        if (loadTemplates(allocator, io)) |file_templates| {
            for (file_templates) |t| {
                var replaced = false;
                for (templates.items, 0..) |_, i| {
                    if (std.mem.eql(u8, templates.items[i].name, t.name)) {
                        templates.items[i] = t;
                        replaced = true;
                        break;
                    }
                }
                if (!replaced) try templates.append(t);
            }
        } else |_| {}

        return Commands{ .builtins = &builtins, .templates = try templates.toOwnedSlice() };
    }

    pub fn deinit(self: *Commands, allocator: std.mem.Allocator) void {
        for (self.templates) |t| {
            allocator.free(t.name);
            if (t.description.len > 0) allocator.free(t.description);
            if (t.args_hint.len > 0) allocator.free(t.args_hint);
        }
        allocator.free(self.templates);
    }

    pub fn helpText(self: Commands, allocator: std.mem.Allocator) ![]const u8 {
        var buf = std.array_list.Managed(u8).init(allocator);
        try buf.appendSlice("/exit, /quit  Exit\n/new         Start new session\n/list        List all sessions\n/session <n> Switch to session\n/name <name> Name current session\n/model <n>   Switch model\n/help        Show this help");
        if (self.templates.len > 0) {
            try buf.appendSlice("\n\n模板命令:");
        for (self.templates) |t| {
                try buf.appendSlice("\n  ");
                try buf.appendSlice(t.name);
                if (t.args_hint.len > 0) {
                    try buf.appendSlice(" <");
                    try buf.appendSlice(t.args_hint);
                    try buf.appendSlice(">");
                }
                if (t.description.len > 0) {
                    try buf.appendSlice(" — ");
                    try buf.appendSlice(t.description);
                }
            }
        }
        try buf.append('\n');
        return buf.toOwnedSlice();
    }

    pub fn match(self: Commands, allocator: std.mem.Allocator, line: []const u8) ?MatchResult {
        var parts = std.mem.splitScalar(u8, line, ' ');
        const cmd = parts.first();

        if (std.mem.eql(u8, cmd, "/exit") or std.mem.eql(u8, cmd, "/quit")) {
            // handled by caller via return
            return null;
        }
        if (std.mem.eql(u8, cmd, "/help")) return MatchResult.help;
        if (std.mem.eql(u8, cmd, "/new")) return MatchResult.new_session;
        if (std.mem.eql(u8, cmd, "/list")) return MatchResult.list;

        if (std.mem.startsWith(u8, line, "/session ")) {
            const arg = std.mem.trim(u8, line[9..], " ");
            if (arg.len == 0) return null;
            return MatchResult{ .switch_session = arg };
        }

        if (std.mem.eql(u8, cmd, "/name")) {
            const arg = line[5..];
            const name = std.mem.trim(u8, arg, " ");
            if (name.len == 0) return null;
            const dupe = allocator.dupe(u8, name) catch return null;
            return MatchResult{ .name = dupe };
        }

        if (std.mem.eql(u8, cmd, "/model")) {
            const arg = line[6..];
            const model = std.mem.trim(u8, arg, " ");
            if (model.len == 0) return MatchResult.list_models;
            const dupe = allocator.dupe(u8, model) catch return null;
            return MatchResult{ .model = dupe };
        }

        for (self.templates) |t| {
            if (std.mem.eql(u8, cmd, t.name)) {
                const arg = if (line.len > t.name.len + 1) std.mem.trim(u8, line[t.name.len + 1 ..], " ") else "";
                const prompt = buildTemplate(allocator, t.content, arg) catch return null;
                return MatchResult{ .template = prompt };
            }
        }

        return null;
    }
};

fn parseTemplateRaw(allocator: std.mem.Allocator, name: []const u8, raw: []const u8) !Commands.Template {
    const cmd_name = try std.fmt.allocPrint(allocator, "/{s}", .{name});
    var description: []const u8 = "";
    var args_hint: []const u8 = "";
    var content_start: usize = 0;

    if (std.mem.startsWith(u8, raw, "---\n")) {
        if (std.mem.indexOfPos(u8, raw, 3, "\n---\n")) |end| {
            const frontmatter = raw[4 .. end + 1];
            content_start = end + 5;
            var flines = std.mem.splitScalar(u8, frontmatter, '\n');
            while (flines.next()) |fl| {
                const fline = std.mem.trim(u8, fl, " \r");
                if (std.mem.startsWith(u8, fline, "description: ")) {
                    description = try allocator.dupe(u8, std.mem.trim(u8, fline[13..], " "));
                } else if (std.mem.startsWith(u8, fline, "args: ")) {
                    args_hint = try allocator.dupe(u8, std.mem.trim(u8, fline[6..], " "));
                }
            }
        }
    }

    return Commands.Template{
        .name = cmd_name,
        .description = description,
        .args_hint = args_hint,
        .content = if (content_start > 0) raw[content_start..] else raw,
    };
}

fn loadTemplates(allocator: std.mem.Allocator, io: Io) ![]Commands.Template {
    const root_dir = @import("tool/root_dir.zig");
    const cmds_dir = try std.fs.path.join(allocator, &.{ root_dir.project_root, ".zagent", "commands" });
    defer allocator.free(cmds_dir);
    const dir = Io.Dir.cwd().openDir(io, cmds_dir, .{ .iterate = true }) catch return error.DirNotFound;
    defer dir.close(io);

    var list = std.array_list.Managed(Commands.Template).init(allocator);

    var iter = dir.iterate();
    while (true) {
        const entry = iter.next(io) catch break orelse break;
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".md")) continue;

        const full_path = try std.fs.path.join(allocator, &.{ cmds_dir, entry.name });
        defer allocator.free(full_path);

        const file = try Io.Dir.cwd().openFile(io, full_path, .{ .mode = .read_only });
        defer file.close(io);

        const stat = try file.stat(io);
        const size: usize = @intCast(stat.size);
        if (size == 0) continue;

        const raw = try allocator.alloc(u8, size);
        _ = try file.readPositionalAll(io, raw, 0);

        const normalized = try normalizeLF(allocator, raw);
        const needs_free = normalized.ptr != raw.ptr;
        if (needs_free) allocator.free(raw);

        const cmd_name = entry.name[0 .. entry.name.len - 3]; // strip ".md"
        const name = try std.fmt.allocPrint(allocator, "/{s}", .{cmd_name});
        errdefer allocator.free(name);

        var description: []const u8 = "";
        var args_hint: []const u8 = "";
        var content_start: usize = 0;

        if (std.mem.startsWith(u8, normalized, "---\n")) {
            if (std.mem.indexOfPos(u8, normalized, 3, "\n---\n")) |end| {
                const frontmatter = normalized[4 .. end + 1];
                content_start = end + 5;
                var flines = std.mem.splitScalar(u8, frontmatter, '\n');
                while (flines.next()) |fl| {
                    const fline = std.mem.trim(u8, fl, " \r");
                    if (std.mem.startsWith(u8, fline, "description: ")) {
                        description = try allocator.dupe(u8, std.mem.trim(u8, fline[13..], " "));
                        errdefer allocator.free(description);
                    } else if (std.mem.startsWith(u8, fline, "args: ")) {
                        args_hint = try allocator.dupe(u8, std.mem.trim(u8, fline[6..], " "));
                        errdefer allocator.free(args_hint);
                    }
                }
            }
        }

        const content = if (content_start > 0) normalized[content_start..] else normalized;

        try list.append(.{
            .name = name,
            .description = description,
            .args_hint = args_hint,
            .content = content,
        });
    }

    return list.toOwnedSlice();
}

fn buildTemplate(allocator: std.mem.Allocator, template: []const u8, args: []const u8) ![]const u8 {
    if (args.len == 0) return allocator.dupe(u8, template);

    const placeholder = "${args}";
    if (std.mem.indexOf(u8, template, placeholder)) |idx| {
        const result = try allocator.alloc(u8, template.len - placeholder.len + args.len);
        @memcpy(result[0..idx], template[0..idx]);
        @memcpy(result[idx .. idx + args.len], args);
        @memcpy(result[idx + args.len ..], template[idx + placeholder.len ..]);
        return result;
    }
    return allocator.dupe(u8, template);
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

test "Commands.match: built-in actions" {
    const testing = std.testing;
    const a = testing.allocator;
    var cmds = try Commands.init(a, testing.io);
    defer cmds.deinit(a);

    try testing.expect(cmds.match(a, "/list") != null);
    try testing.expect(cmds.match(a, "/list") != null and cmds.match(a, "/list").? == .list);
    try testing.expect(cmds.match(a, "/new") != null);
    {
        const m = cmds.match(a, "/name foo");
        try testing.expect(m != null);
        if (m) |v| if (v == .name) a.free(v.name);
    }
    try testing.expect(cmds.match(a, "/name") == null);
    try testing.expect(cmds.match(a, "/exit") == null); // handled by caller
}

test "Commands.match: unknown returns null" {
    const testing = std.testing;
    const a = testing.allocator;
    var cmds = try Commands.init(a, testing.io);
    defer cmds.deinit(a);
    try testing.expect(cmds.match(a, "/unknown") == null);
    try testing.expect(cmds.match(a, "hello world") == null);
}

test "Commands.match: exact command only" {
    const testing = std.testing;
    const a = testing.allocator;
    var cmds = try Commands.init(a, testing.io);
    defer cmds.deinit(a);
    try testing.expect(cmds.match(a, "/new-session") == null); // not a fuzzy match
}

test "buildTemplate: replaces placeholder" {
    const testing = std.testing;
    const a = testing.allocator;

    const result = try buildTemplate(a, "审查文件：${args}", "src/main.zig");
    defer a.free(result);
    try testing.expectEqualStrings("审查文件：src/main.zig", result);
}

test "buildTemplate: no placeholder returns original" {
    const testing = std.testing;
    const a = testing.allocator;

    const result = try buildTemplate(a, "hello world", "ignored");
    defer a.free(result);
    try testing.expectEqualStrings("hello world", result);
}

test "Commands.init: /init template contains investigation methodology" {
    const testing = std.testing;
    const a = testing.allocator;
    var cmds = try Commands.init(a, testing.io);
    defer cmds.deinit(a);

    const m = cmds.match(a, "/init");
    try testing.expect(m != null);
    try testing.expect(m.? == .template);
    const prompt = m.?.template;
    defer a.free(prompt);

    try testing.expect(std.mem.indexOf(u8, prompt, "How to investigate") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "What to extract") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "Writing rules") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "Questions") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "zig-cache") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "Would an agent miss") != null);
}

test "Commands.init: embedded learn/recall/summary templates exist" {
    const testing = std.testing;
    const a = testing.allocator;
    var cmds = try Commands.init(a, testing.io);
    defer cmds.deinit(a);

    // /learn template should be present
    {
        const m = cmds.match(a, "/learn");
        try testing.expect(m != null);
        try testing.expect(m.? == .template);
        try testing.expect(m.?.template.len > 0);
        a.free(m.?.template);
    }

    // /recall template
    {
        const m = cmds.match(a, "/recall");
        try testing.expect(m != null);
        try testing.expect(m.? == .template);
        a.free(m.?.template);
    }

    // /summary template
    {
        const m = cmds.match(a, "/summary");
        try testing.expect(m != null);
        try testing.expect(m.? == .template);
        a.free(m.?.template);
    }
}

test "Commands.match: /learn with args replaces placeholder" {
    const testing = std.testing;
    const a = testing.allocator;
    var cmds = try Commands.init(a, testing.io);
    defer cmds.deinit(a);

    const match = cmds.match(a, "/learn 关注性能优化");
    try testing.expect(match != null);
    try testing.expect(match.? == .template);
    const prompt = match.?.template;
    defer a.free(prompt);
    try testing.expect(std.mem.indexOf(u8, prompt, "关注性能优化") != null);
}

test "normalizeLF: CRLF converts to LF" {
    const testing = std.testing;
    const a = testing.allocator;

    const result = try normalizeLF(a, "hello\r\nworld\r\n");
    defer a.free(result);
    try testing.expectEqualStrings("hello\nworld\n", result);
}

test "normalizeLF: LF-only returns same pointer" {
    const testing = std.testing;
    const a = testing.allocator;

    const input = "hello\nworld\n";
    const result = try normalizeLF(a, input);
    try testing.expect(result.ptr == input.ptr);
    try testing.expectEqualStrings(input, result);
}

test "normalizeLF: mixed LF and CRLF" {
    const testing = std.testing;
    const a = testing.allocator;

    const result = try normalizeLF(a, "line1\r\nline2\nline3\r\n");
    defer a.free(result);
    try testing.expectEqualStrings("line1\nline2\nline3\n", result);
}

test "normalizeLF: no CRLF returns same pointer" {
    const testing = std.testing;
    const a = testing.allocator;

    const input = "plain text without newlines";
    const result = try normalizeLF(a, input);
    try testing.expect(result.ptr == input.ptr);
}
