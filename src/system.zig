const std = @import("std");
const types = @import("types.zig");

pub const ModelFamily = enum {
    deepseek_v4,
    generic,
};

pub fn detectModelFamily(model_name: []const u8) ModelFamily {
    if (std.mem.startsWith(u8, model_name, "deepseek-v4")) return .deepseek_v4;
    return .generic;
}

fn modelGuidance(family: ModelFamily) []const u8 {
    return switch (family) {
        .deepseek_v4 =>
        \\You are powered by DeepSeek V4 — 1M context window, 393K max output tokens, bilingual.
        \\Large context window: retain all relevant history. Do not summarize unless compaction is forced.
        \\User communicates in Chinese or English; respond in the same language. Tool arguments and error messages remain in English.
        \\Use reasoning step for analysis before tool calls; output final answer in content.
        \\Prefer `task` tool for multi-step work (delegates sub-agents). `bash` for single commands.
        \\
        ,
        .generic => "",
    };
}

pub fn buildSystemPrompt(allocator: std.mem.Allocator, cwd: []const u8, project_root: []const u8, provider_name: []const u8, model_name: []const u8, io: std.Io, agents_md: ?[]const u8, available_skills: []const types.SkillMeta, model_family: ModelFamily, agent_prompt: ?[]const u8) ![]const u8 {
    var buf = std.array_list.Managed(u8).init(allocator);
    defer buf.deinit();

    if (agent_prompt) |prompt| {
        try buf.appendSlice(prompt);
    } else {
        try buf.appendSlice("You are z-agent, an interactive CLI tool that helps users with software engineering tasks. ");
        try buf.appendSlice(model_name);
        try buf.appendSlice(" via ");
        try buf.appendSlice(provider_name);
        try buf.appendSlice(".");
        try buf.appendSlice("\nz-agent v");
        try buf.appendSlice(types.VERSION);
        try buf.appendSlice(" (build by Zig 0.16.0)");
    }
    try buf.appendSlice("\nToday's date: ");

    const now_ns = std.Io.Clock.Timestamp.now(io, .real).raw.nanoseconds;
    const now_s: u64 = @intCast(@divFloor(now_ns, 1_000_000_000));
    const epoch_sec = std.time.epoch.EpochSeconds{ .secs = now_s };
    const epoch_day = epoch_sec.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const weekday_idx = @as(usize, @intCast((epoch_day.day + 4) % 7));
    const weekday_names = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
    const month_names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    var date_buf: [64]u8 = undefined;
    const date_str = try std.fmt.bufPrint(&date_buf, "{s} {s} {d:0>2} {d:0>4}", .{
        weekday_names[weekday_idx],
        month_names[@as(usize, @intCast(@intFromEnum(month_day.month) - 1))],
        month_day.day_index + 1,
        year_day.year,
    });
    try buf.appendSlice(date_str);
    try buf.appendSlice("\n\n");

    try buf.appendSlice(
        \\# Tone and style
        \\Be concise, direct, and to the point. Use GitHub-flavored Markdown for formatting (rendered in monospace).
        \\Use tools for actions; output text only to communicate with the user. Never use tools like bash or code comments to communicate.
        \\Do not add preamble/postamble explanations. Answer directly. Only use emojis if explicitly asked.
        \\If you cannot help, state briefly (1-2 sentences) and offer alternatives. Do not explain why.
        \\
        \\# Security
        \\Never generate or guess URLs. Use only URLs provided by the user, verified project paths, or local files.
        \\Never introduce code that exposes, logs, or commits secrets or API keys.
        \\
        \\# Task workflow
        \\Read existing code first to understand context and conventions. Then implement.
        \\Prefer minimal, correct changes over large refactors. Prefer editing existing files over creating new ones.
        \\After changes, verify with the project's build and test commands (check README or package.json for the correct commands).
        \\Call multiple independent tools in parallel when possible.
        \\
        \\IMPORTANT: Never commit changes unless the user explicitly asks you to.
        \\
        );
    if (agents_md) |content| {
        try buf.appendSlice("<project_context>\n");
        try buf.appendSlice("Instructions from AGENTS.md:\n\n");
        try buf.appendSlice(content);
        try buf.appendSlice("\n</project_context>\n\n");
    }

    if (available_skills.len > 0) {
        try buf.appendSlice("<available_skills>\n");
        for (available_skills) |sk| {
            try buf.appendSlice("  <skill>\n");
            try buf.appendSlice("    <name>");
            try buf.appendSlice(sk.name);
            try buf.appendSlice("</name>\n");
            try buf.appendSlice("    <description>");
            try buf.appendSlice(sk.description);
            try buf.appendSlice("</description>\n");
            try buf.appendSlice("    <location>file:///");
            try buf.appendSlice(sk.path);
            try buf.appendSlice("</location>\n");
            try buf.appendSlice("  </skill>\n");
        }
        try buf.appendSlice("</available_skills>\n\n");
    }

    try buf.appendSlice(
        \\<available_agents>
        \\  <agent>
        \\    <name>explore</name>
        \\    <description>文件搜索专家，擅长在代码库中快速定位和分析文件</description>
        \\  </agent>
        \\</available_agents>
        \\
    );

    const is_git_repo = blk: {
        if (std.Io.Dir.cwd().openDir(io, cwd, .{})) |dir| {
            defer dir.close(io);
            if (dir.openDir(io, ".git", .{})) |_| {
                break :blk "yes";
            } else |_| {
                break :blk "no";
            }
        } else |_| {
            break :blk "unknown";
        }
    };

    try buf.appendSlice("<env>\n");
    try buf.appendSlice("  Working directory: ");
    try buf.appendSlice(cwd);
    try buf.appendSlice("\n");
    try buf.appendSlice("  Workspace root folder: ");
    try buf.appendSlice(project_root);
    try buf.appendSlice("\n");
    try buf.appendSlice("  Is directory a git repo: ");
    try buf.appendSlice(is_git_repo);
    try buf.appendSlice("\n");
    try buf.appendSlice("  Platform: win32\n");
    try buf.appendSlice("  Shell: PowerShell\n");
    try buf.appendSlice("  ⚠ Get-ChildItem -Recurse without -Depth N is expensive (scans entire tree)\n");
    try buf.appendSlice("  ⚠ Select-String -Recurse without -Path/-Filter scans all files\n");
    try buf.appendSlice("</env>\n\n");

    const guidance = modelGuidance(model_family);
    if (guidance.len > 0) {
        try buf.appendSlice(guidance);
    }

    return try buf.toOwnedSlice();
}

test "detectModelFamily: deepseek-v4 matches" {
    const testing = std.testing;
    try testing.expectEqual(ModelFamily.deepseek_v4, detectModelFamily("deepseek-v4-flash"));
    try testing.expectEqual(ModelFamily.deepseek_v4, detectModelFamily("deepseek-v4-pro"));
}

test "detectModelFamily: unknown model returns generic" {
    const testing = std.testing;
    try testing.expectEqual(ModelFamily.generic, detectModelFamily("gpt-4o"));
    try testing.expectEqual(ModelFamily.generic, detectModelFamily("claude-3-opus"));
    try testing.expectEqual(ModelFamily.generic, detectModelFamily(""));
}

test "buildSystemPrompt contains identity" {
    const testing = std.testing;
    const prompt = try buildSystemPrompt(testing.allocator, "/test", "/root", "deepseek", "deepseek-v4-pro", testing.io, null, &.{}, .deepseek_v4, null);
    defer testing.allocator.free(prompt);

    try testing.expect(std.mem.indexOf(u8, prompt, "z-agent") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "deepseek-v4-pro") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "deepseek") != null);
}

test "buildSystemPrompt contains env block" {
    const testing = std.testing;
    const prompt = try buildSystemPrompt(testing.allocator, "/test", "/root", "openai", "gpt-4o", testing.io, null, &.{}, .generic, null);
    defer testing.allocator.free(prompt);

    try testing.expect(std.mem.indexOf(u8, prompt, "Platform: win32") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "Shell: PowerShell") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "/test") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "Workspace root folder: /root") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "Is directory a git repo:") != null);
}

test "buildSystemPrompt contains date" {
    const testing = std.testing;
    const prompt = try buildSystemPrompt(testing.allocator, ".", ".", "test", "test-model", testing.io, null, &.{}, .generic, null);
    defer testing.allocator.free(prompt);

    try testing.expect(std.mem.indexOf(u8, prompt, "Today's date:") != null);
}

test "buildSystemPrompt contains PowerShell warnings in env" {
    const testing = std.testing;
    const prompt = try buildSystemPrompt(testing.allocator, ".", ".", "test", "test-model", testing.io, null, &.{}, .generic, null);
    defer testing.allocator.free(prompt);

    try testing.expect(std.mem.indexOf(u8, prompt, "<env>") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "Get-ChildItem -Recurse") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "Select-String -Recurse") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "expensive") != null);
}

test "buildSystemPrompt injects AGENTS.md when provided" {
    const testing = std.testing;
    const prompt = try buildSystemPrompt(testing.allocator, ".", ".", "test", "test", testing.io, "custom rules here", &.{}, .generic, null);
    defer testing.allocator.free(prompt);

    try testing.expect(std.mem.indexOf(u8, prompt, "<project_context>") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "custom rules here") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "</project_context>") != null);
}

test "buildSystemPrompt skips project_context when null" {
    const testing = std.testing;
    const prompt = try buildSystemPrompt(testing.allocator, ".", ".", "test", "test", testing.io, null, &.{}, .generic, null);
    defer testing.allocator.free(prompt);

    try testing.expect(std.mem.indexOf(u8, prompt, "<project_context>") == null);
}

test "buildSystemPrompt injects available_skills when provided" {
    const testing = std.testing;
    const skills = [_]types.SkillMeta{.{ .name = "code-review", .slug = "code-review", .description = "Zig code review skill", .path = "/test/path" }};
    const prompt = try buildSystemPrompt(testing.allocator, ".", ".", "test", "test", testing.io, null, &skills, .generic, null);
    defer testing.allocator.free(prompt);

    try testing.expect(std.mem.indexOf(u8, prompt, "<available_skills>") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "<name>code-review</name>") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "<description>Zig code review skill</description>") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "</available_skills>") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "<location>file:////test/path</location>") != null);
}

test "buildSystemPrompt skips available_skills when null" {
    const testing = std.testing;
    const prompt = try buildSystemPrompt(testing.allocator, ".", ".", "test", "test", testing.io, null, &.{}, .generic, null);
    defer testing.allocator.free(prompt);

    try testing.expect(std.mem.indexOf(u8, prompt, "<available_skills>") == null);
}

test "buildSystemPrompt deepseek_v4 contains model-specific guidance" {
    const testing = std.testing;
    const prompt = try buildSystemPrompt(testing.allocator, ".", ".", "deepseek", "deepseek-v4-flash", testing.io, null, &.{}, .deepseek_v4, null);
    defer testing.allocator.free(prompt);

    try testing.expect(std.mem.indexOf(u8, prompt, "1M context window") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "bilingual") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "same language") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "reasoning step") != null);
}

test "buildSystemPrompt agent_prompt replaces default identity" {
    const testing = std.testing;
    const custom = "You are a Python specialist, focused on data pipelines";
    const prompt = try buildSystemPrompt(testing.allocator, ".", ".", "test", "test-model", testing.io, null, &.{}, .generic, custom);
    defer testing.allocator.free(prompt);

    try testing.expect(std.mem.indexOf(u8, prompt, custom) != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "You are z-agent") == null);
    try testing.expect(std.mem.indexOf(u8, prompt, "# Tone and style") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "# Security") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "# Task workflow") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "Today's date:") != null);
}

test "buildSystemPrompt generic does not contain deepseek guidance" {
    const testing = std.testing;
    const prompt = try buildSystemPrompt(testing.allocator, ".", ".", "openai", "gpt-4o", testing.io, null, &.{}, .generic, null);
    defer testing.allocator.free(prompt);

    try testing.expect(std.mem.indexOf(u8, prompt, "1M context window") == null);
    try testing.expect(std.mem.indexOf(u8, prompt, "bilingual") == null);
}

test "buildSystemPrompt contains tone and style section" {
    const testing = std.testing;
    const prompt = try buildSystemPrompt(testing.allocator, ".", ".", "test", "test-model", testing.io, null, &.{}, .generic, null);
    defer testing.allocator.free(prompt);

    try testing.expect(std.mem.indexOf(u8, prompt, "# Tone and style") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "GitHub-flavored Markdown") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "preamble/postamble") != null);
}

test "buildSystemPrompt contains security section" {
    const testing = std.testing;
    const prompt = try buildSystemPrompt(testing.allocator, ".", ".", "test", "test-model", testing.io, null, &.{}, .generic, null);
    defer testing.allocator.free(prompt);

    try testing.expect(std.mem.indexOf(u8, prompt, "# Security") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "Never generate or guess URLs") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "Never introduce code") != null);
}

test "buildSystemPrompt contains task workflow section" {
    const testing = std.testing;
    const prompt = try buildSystemPrompt(testing.allocator, ".", ".", "test", "test-model", testing.io, null, &.{}, .generic, null);
    defer testing.allocator.free(prompt);

    try testing.expect(std.mem.indexOf(u8, prompt, "# Task workflow") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "Never commit changes") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "minimal, correct changes") != null);
}
