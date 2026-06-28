const std = @import("std");
const types = @import("types.zig");

pub fn buildSystemPrompt(allocator: std.mem.Allocator, cwd: []const u8, provider_name: []const u8, model_name: []const u8, io: std.Io, agents_md: ?[]const u8, available_skills: []const types.SkillMeta) ![]const u8 {
    var buf = std.array_list.Managed(u8).init(allocator);
    defer buf.deinit();

    try buf.appendSlice("You are z-agent, an interactive CLI tool that helps users with software engineering tasks. You are powered by ");
    try buf.appendSlice(model_name);
    try buf.appendSlice(" via ");
    try buf.appendSlice(provider_name);
    try buf.appendSlice(".");
    try buf.appendSlice("\nz-agent v");
    try buf.appendSlice(types.VERSION);
    try buf.appendSlice(" (build by Zig 0.16.0)");
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

    try buf.appendSlice(
        \\<env>
        \\  Platform: win32
        \\  Shell: PowerShell
        \\
    );
    try buf.appendSlice("  Working directory: ");
    try buf.appendSlice(cwd);
    try buf.appendSlice(
        \\
        \\</env>
        \\
        \\Available tools:
        \\- read_file: Read a file from the filesystem. For images (png/jpg/gif/webp/bmp), read_file automatically encodes to base64 for vision analysis. Use read_file (not bash) to open images.
        \\- write_file: Write content to a file
        \\- edit_file: Edit a file by replacing exact text
        \\- bash: Execute a shell command
        \\  Current shell is PowerShell. Use PowerShell syntax:
        \\  · List files: Get-ChildItem
        \\  · Read file: Get-Content <path>  (use -Head N for large files)
        \\  · Search text: Select-String -Pattern "text" <path>
        \\  · Recursive: Get-ChildItem -Recurse -Depth 2 -Filter "*.ext"
        \\  ⚠ Recursive scans without -Depth N scan entire tree (expensive)
        \\  ⚠ Select-String -Recurse without -Path or -Filter scans all files
        \\- glob: Find files matching a glob pattern
        \\- grep: Search for a text pattern in files
        \\- ask_user: Ask the user a question
        \\- skill: Load skill instructions
        \\- task <agent> <task>: Delegate to a sub-agent (see <available_agents>)
        \\
    );

    return try buf.toOwnedSlice();
}

test "buildSystemPrompt contains identity" {
    const testing = std.testing;
    const prompt = try buildSystemPrompt(testing.allocator, "/test", "deepseek", "deepseek-v4-pro", testing.io, null, &.{});
    defer testing.allocator.free(prompt);

    try testing.expect(std.mem.indexOf(u8, prompt, "z-agent") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "deepseek-v4-pro") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "deepseek") != null);
}

test "buildSystemPrompt contains platform info" {
    const testing = std.testing;
    const prompt = try buildSystemPrompt(testing.allocator, "/test", "openai", "gpt-4o", testing.io, null, &.{});
    defer testing.allocator.free(prompt);

    try testing.expect(std.mem.indexOf(u8, prompt, "Platform: win32") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "Shell: PowerShell") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "/test") != null);
}

test "buildSystemPrompt contains date" {
    const testing = std.testing;
    const prompt = try buildSystemPrompt(testing.allocator, ".", "test", "test-model", testing.io, null, &.{});
    defer testing.allocator.free(prompt);

    try testing.expect(std.mem.indexOf(u8, prompt, "Today's date:") != null);
}

test "buildSystemPrompt contains tool list" {
    const testing = std.testing;
    const prompt = try buildSystemPrompt(testing.allocator, ".", "test", "test-model", testing.io, null, &.{});
    defer testing.allocator.free(prompt);

    try testing.expect(std.mem.indexOf(u8, prompt, "read_file") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "bash") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "ask_user") != null);
}

test "buildSystemPrompt contains PowerShell hints" {
    const testing = std.testing;
    const prompt = try buildSystemPrompt(testing.allocator, ".", "test", "test-model", testing.io, null, &.{});
    defer testing.allocator.free(prompt);

    try testing.expect(std.mem.indexOf(u8, prompt, "Get-ChildItem") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "Select-String") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "-Depth") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "expensive") != null);
}

test "buildSystemPrompt injects AGENTS.md when provided" {
    const testing = std.testing;
    const prompt = try buildSystemPrompt(testing.allocator, ".", "test", "test", testing.io, "custom rules here", &.{});
    defer testing.allocator.free(prompt);

    try testing.expect(std.mem.indexOf(u8, prompt, "<project_context>") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "custom rules here") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "</project_context>") != null);
}

test "buildSystemPrompt skips project_context when null" {
    const testing = std.testing;
    const prompt = try buildSystemPrompt(testing.allocator, ".", "test", "test", testing.io, null, &.{});
    defer testing.allocator.free(prompt);

    try testing.expect(std.mem.indexOf(u8, prompt, "<project_context>") == null);
}

test "buildSystemPrompt injects available_skills when provided" {
    const testing = std.testing;
    var buf: [256]u8 = undefined;
    const name = try std.fmt.bufPrint(&buf, "code-review", .{});
    const desc = try std.fmt.bufPrint(buf[12..], "Zig code review skill", .{});
    const skills = [_]types.SkillMeta{.{ .name = name, .slug = "code-review", .description = desc, .path = "/test/path" }};
    const prompt = try buildSystemPrompt(testing.allocator, ".", "test", "test", testing.io, null, &skills);
    defer testing.allocator.free(prompt);

    try testing.expect(std.mem.indexOf(u8, prompt, "<available_skills>") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "<name>code-review</name>") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "<description>Zig code review skill</description>") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "</available_skills>") != null);
}

test "buildSystemPrompt skips available_skills when null" {
    const testing = std.testing;
    const prompt = try buildSystemPrompt(testing.allocator, ".", "test", "test", testing.io, null, &.{});
    defer testing.allocator.free(prompt);

    try testing.expect(std.mem.indexOf(u8, prompt, "<available_skills>") == null);
}
