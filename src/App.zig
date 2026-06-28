const std = @import("std");
const types = @import("types.zig");
const ansi = @import("ansi.zig");
const provider = @import("provider.zig");
const config_mod = @import("config.zig");
const registry = @import("tool/registry.zig");
const tool_read = @import("tool/read.zig");
const tool_write = @import("tool/write.zig");
const tool_edit = @import("tool/edit.zig");
const tool_bash = @import("tool/bash.zig");
const tool_glob = @import("tool/glob.zig");
const tool_grep = @import("tool/grep.zig");
const tool_ask_user = @import("tool/ask_user.zig");
const tool_json = @import("tool/json.zig");
const tool_root_dir = @import("tool/root_dir.zig");
const tool_skill = @import("tool/skill.zig");
const tool_task = @import("tool/task.zig");
const tool_memory = @import("tool/memory.zig");
const skill = @import("skill.zig");
const token = @import("tool/token.zig");
const session = @import("session.zig");
const system = @import("system.zig");
const Cli = @import("Cli.zig");
const Command = @import("Command.zig");
const signal = @import("signal.zig");
const hook = @import("hook.zig");
const compact = @import("compact.zig");
    const permission = @import("permission.zig");
    const ToolResult = registry.ToolResult;

const default_handlers = &.{
    registry.buildHandler(tool_read),
    registry.buildHandler(tool_write),
    registry.buildHandler(tool_edit),
    registry.buildHandler(tool_bash),
    registry.buildHandler(tool_glob),
    registry.buildHandler(tool_grep),
    registry.buildHandler(tool_ask_user),
    registry.buildHandler(tool_skill),
    registry.buildHandler(tool_task),
    registry.buildHandler(tool_memory),
};

pub const App = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    stdout: *std.Io.Writer,
    reg: registry.Registry,
    prov: provider.Provider,
    cfg: config_mod.Config,
    api: []const u8,
    model: []const u8,
    base_url: []const u8,
    context_limit: u32,
    provider_entries: []const provider.ProviderEntry,
    tools: []const types.Tool,
    debug_logging: bool,
    project_root: []const u8,
    session_dir: []const u8,
    _prompt: ?[]const u8,
    _session_arg: ?[]const u8,
    commands: Command.Commands,
    agents_md: ?[]const u8,
    available_skills: []const types.SkillMeta,
    agent_mode: bool = false,
    result_marker: ?[]const u8 = null,
    perm: *permission.Permission,
    trust: bool = false,
    dotenv: std.StringArrayHashMapUnmanaged([]const u8),

    pub fn init(process: std.process.Init, stdout: *std.Io.Writer) !App {
        if (@import("builtin").os.tag == .windows) {
            Cli.setConsoleUtf8();
        }
        const io = process.io;
        const arena = process.arena.allocator();

        const launch_s = @divFloor(std.Io.Clock.Timestamp.now(io, .real).raw.nanoseconds, 1_000_000_000);
        try stdout.print("z-agent v{s} (build {d})\n", .{ types.VERSION, launch_s });
        try stdout.flush();

        const args = try process.minimal.args.toSlice(arena);

        const project_root = config_mod.findZagentRoot(arena, io) orelse blk: {
            var buf: [4096]u8 = undefined;
            if (std.Io.Dir.cwd().realPath(io, &buf)) |len| {
                break :blk (arena.dupe(u8, buf[0..len]) catch ".");
            } else |_| {
                break :blk ".";
            }
        };
        tool_root_dir.init(project_root);
        const loaded = try config_mod.Config.load(arena, project_root, io);
        var cfg = loaded.config;
        const api_keys = loaded.api_keys;
        const perm_ptr = try arena.create(permission.Permission);
        perm_ptr.* = permission.Permission.init(arena, io, cfg.permissions);
        
        // Resolve default_model: "provider/model" → find provider + model
        var resolved_api: []const u8 = undefined;
        var resolved_model: []const u8 = undefined;
        var resolved_base_url: []const u8 = undefined;
        var resolved_context_limit: u32 = 0;
        {
            // If default_model is empty, fall back to first provider's default_model or first model
            var effective_default = cfg.default_model;
            if (effective_default.len == 0) {
                if (cfg.providers.len > 0) {
                    if (cfg.providers[0].default_model.len > 0) {
                        effective_default = cfg.providers[0].default_model;
                    } else if (cfg.providers[0].models.len > 0) {
                        effective_default = cfg.providers[0].models[0];
                    }
                }
            }
            if (effective_default.len == 0) {
                try stdout.print("Error: no default_model configured and no providers found\n", .{});
                try stdout.flush();
                return error.NoDefaultModel;
            }

            const slash_idx = std.mem.indexOfScalar(u8, effective_default, '/');
            const prov_name = if (slash_idx) |idx| effective_default[0..idx] else "";
            const model_name = if (slash_idx) |idx| effective_default[idx+1..] else effective_default;
            for (cfg.providers) |p| {
                if (prov_name.len > 0 and !std.mem.eql(u8, p.name, prov_name)) continue;
                resolved_api = if (prov_name.len > 0) prov_name else p.name;
                resolved_model = model_name;
                resolved_base_url = p.base_url;
                if (p.context_limit > 0) resolved_context_limit = p.context_limit;
                break;
            }
        }
        
        var agents_md = readAgentsMd(arena, project_root, io);
        const skills_root = try std.fs.path.join(arena, &.{ project_root, ".zagent", "skills" });
        const fs_skills = try skill.loadAvailable(arena, io, skills_root);
        const builtin_skills = try skill.getBuiltinSkills(arena);
        var skills_list = std.array_list.Managed(types.SkillMeta).init(arena);
        for (builtin_skills) |s| try skills_list.append(s);
        for (fs_skills) |s| {
            var replaced = false;
            for (skills_list.items, 0..) |_, i| {
                if (std.mem.eql(u8, skills_list.items[i].slug, s.slug)) {
                    skills_list.items[i] = s;
                    replaced = true;
                    break;
                }
            }
            if (!replaced) try skills_list.append(s);
        }
        const available_skills = try skills_list.toOwnedSlice();

        const provider_entries = try provider.buildProviderEntries(arena, cfg.providers);

        const prov_entry = blk: {
            if (provider.registry.findByApi(provider_entries, resolved_api)) |entry| break :blk entry;
            for (cfg.providers) |p| {
                if (std.mem.eql(u8, p.name, resolved_api)) {
                    if (provider.registry.findByApi(provider_entries, p.kind)) |entry| break :blk entry;
                }
            }
            try stdout.print("Error: unknown provider '{s}'\n", .{resolved_api});
            try stdout.flush();
            return error.UnknownProvider;
        };

        var effective_context_limit = if (resolved_context_limit > 0) resolved_context_limit else prov_entry.default_context_limit;
        if (provider.modelSpecFor(provider_entries, resolved_api, resolved_model)) |spec| {
            effective_context_limit = spec.context_limit;
            if (cfg.max_tokens > spec.max_output) cfg.max_tokens = spec.max_output;
        }

        // Try resolved api_keys from config.load first, then env vars
        const env_key = prov_entry.env_key;
        const api_key = if (env_key.len > 0) blk: {
            // Match API key by env_key name (supports multi-provider configs)
            for (api_keys, cfg.providers) |k, p| {
                if (std.mem.eql(u8, p.api_key_env, env_key)) break :blk k;
            }
            break :blk process.environ_map.get(env_key) orelse {
                try stdout.print("Error: {s} not set\n", .{env_key});
                try stdout.flush();
                return error.MissingApiKey;
            };
        } else "";

        {
            var key_list: std.ArrayListUnmanaged([]const u8) = .{ .items = &.{}, .capacity = 0 };
            defer key_list.deinit(arena);
            if (env_key.len > 0) try key_list.append(arena, env_key);
            for (api_keys) |k| try key_list.append(arena, k);
            tool_bash.setSanitizeKeys(try key_list.toOwnedSlice(arena));
        }

        const reg = registry.Registry{
            .handlers = default_handlers,
        };

        const debug_logging = process.environ_map.get("ZAGENT_DEBUG") != null;
        const tools_slice = try reg.toTools(arena);

        const model_config = types.ModelConfig{
            .api = resolved_api,
            .model = resolved_model,
            .base_url = resolved_base_url,
            .api_key = api_key,
            .max_tokens = cfg.max_tokens,
            .proxy = cfg.proxy,
        };
        const prov = prov_entry.create(model_config, tools_slice, debug_logging, arena);

        const session_dir_rel = try std.fs.path.join(arena, &.{ project_root, ".zagent", "sessions" });
        const session_dir = try std.fs.path.resolve(arena, &.{session_dir_rel});

        var session_arg: ?[]const u8 = null;
        var prompt: ?[]const u8 = null;
        var is_agent: bool = false;
        var trust: bool = false;
        var result_marker: ?[]const u8 = null;
        {
            var i: usize = 1;
            while (i < args.len) : (i += 1) {
                const arg = args[i];
                if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
                    try Cli.printHelp(stdout);
                    return error.HelpShown;
                }
                if (std.mem.eql(u8, arg, "-l") or std.mem.eql(u8, arg, "--list")) {
                    try Cli.printSessionList(arena, io, stdout, session_dir);
                    return error.ListShown;
                }
                if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--session")) {
                    i += 1;
                    if (i >= args.len) {
                        try stdout.print("Error: --session requires an argument\n", .{});
                        try stdout.flush();
                        return error.MissingSessionArg;
                    }
                    session_arg = args[i];
                    continue;
                }
                if (std.mem.eql(u8, arg, "--agent")) {
                    i += 1;
                    if (i >= args.len) {
                        try stdout.print("Error: --agent requires a path argument\n", .{});
                        try stdout.flush();
                        return error.MissingAgentArg;
                    }
                    is_agent = true;
                    const agent_file = args[i];
                    const agent_content = readAgentFile(arena, io, agent_file);
                    agents_md = if (agents_md != null) agents_md else agent_content;
                    continue;
                }
                if (std.mem.eql(u8, arg, "--agent-content")) {
                    i += 1;
                    if (i >= args.len) {
                        try stdout.print("Error: --agent-content requires a content argument\n", .{});
                        try stdout.flush();
                        return error.MissingAgentArg;
                    }
                    is_agent = true;
                    agents_md = try arena.dupe(u8, args[i]);
                    continue;
                }
                if (std.mem.startsWith(u8, arg, "--result-marker=")) {
                    result_marker = arg["--result-marker=".len..];
                    continue;
                }
                if (std.mem.eql(u8, arg, "--trust")) {
                    trust = true;
                    continue;
                }
                if (std.mem.startsWith(u8, arg, "-")) {
                    try stdout.print("Error: unknown flag {s}\n", .{arg});
                    try stdout.flush();
                    return error.UnknownFlag;
                }
                prompt = arg;
                break;
            }
        }

        const commands = try Command.Commands.init(arena, io);
        tool_task.setExePath(args[0]);

        // provider_entries is already arena-allocated from buildProviderEntries
        const provider_entries_slice = provider_entries;

        // Load .env for use in setModel runtime switching
        const dotenv = config_mod.loadDotEnv(arena, project_root, io) catch std.StringArrayHashMapUnmanaged([]const u8){};

        return App{
            .allocator = arena,
            .io = io,
            .stdout = stdout,
            .reg = reg,
            .prov = prov,
            .cfg = cfg,
            .api = resolved_api,
            .model = resolved_model,
            .base_url = resolved_base_url,
            .context_limit = effective_context_limit,
            .provider_entries = provider_entries_slice,
            .tools = tools_slice,
            .debug_logging = debug_logging,
            .project_root = project_root,
            .session_dir = session_dir,
            ._prompt = prompt,
            ._session_arg = session_arg,
            .commands = commands,
            .agents_md = agents_md,
            .available_skills = available_skills,
            .agent_mode = is_agent,
            .result_marker = result_marker,
            .perm = perm_ptr,
            .trust = trust,
            .dotenv = dotenv,
        };
    }

    pub fn run(self: *App) !void {
        var sm = if (self._session_arg) |arg| blk: {
            const index = std.fmt.parseInt(usize, arg, 10) catch {
                break :blk try session.continueById(self.allocator, self.io, self.session_dir, arg);
            };
            break :blk try session.continueByIndex(self.allocator, self.io, self.session_dir, if (index > 0) index - 1 else 0);
        } else try session.SessionManager.create(self.allocator, self.io, self.session_dir, self.model, self.api);

        hook.run(self.allocator, self.io, self.project_root, "session_start", "{}", self.stdout);

        if (self._prompt) |p| {
            try self.stdout.print("Model: {s}\n", .{self.model});
            try self.stdout.flush();
            try self.singleTurn(p, &sm);
        } else {
            try self.repl(&sm);
        }
    }

    fn setModel(self: *App, alias: []const u8) !void {
        // Parse "provider/model" or bare model name
        const slash_idx = std.mem.indexOfScalar(u8, alias, '/');
        if (slash_idx) |idx| {
            const new_api = alias[0..idx];
            const new_model = alias[idx+1..];

            // Find provider entry in cfg.providers
            var found_provider: ?config_mod.ProviderEntry = null;
            for (self.cfg.providers) |p| {
                if (std.mem.eql(u8, p.name, new_api)) { found_provider = p; break; }
            }

            if (found_provider) |prov_cfg| {
                const prov_entry = if (std.mem.eql(u8, new_api, self.api))
                    null
                else
                    provider.registry.findByApi(self.provider_entries, new_api);

                if (prov_entry) |pe| {
                    var env_map = std.process.Environ.createMap(.{ .block = .{ .use_global = true } }, self.allocator) catch {
                        try self.stdout.print("Error: cannot read environment\n", .{});
                        return error.EnvFailed;
                    };
                    defer env_map.deinit();
                    const api_key = if (prov_cfg.api_key.len > 0) prov_cfg.api_key else
                        self.dotenv.get(prov_cfg.api_key_env) orelse
                        env_map.get(prov_cfg.api_key_env) orelse
                    {
                        try self.stdout.print("Error: {s} not set\n", .{prov_cfg.api_key_env});
                        return error.MissingApiKey;
                    };
                    const model_dup = try self.allocator.dupe(u8, new_model);
                    const new_config = types.ModelConfig{
                        .api = new_api, .model = model_dup, .base_url = prov_cfg.base_url,
                        .api_key = api_key, .max_tokens = self.cfg.max_tokens,
                        .proxy = self.cfg.proxy,
                    };
                    self.prov = pe.create(new_config, self.tools, self.debug_logging, self.allocator);
                } else {
                    const model_dup = try self.allocator.dupe(u8, new_model);
                    self.prov.setModel(model_dup);
                }

                self.api = try self.allocator.dupe(u8, new_api);
                self.model = try self.allocator.dupe(u8, alias);
                self.base_url = prov_cfg.base_url;
                self.context_limit = prov_cfg.context_limit;
            } else {
                // Unknown provider, just set model name directly
                self.model = try self.allocator.dupe(u8, alias);
                const model_dup = try self.allocator.dupe(u8, alias);
                self.prov.setModel(model_dup);
            }
        } else {
            // Bare model name: try to match within current provider's models list
            self.model = try self.allocator.dupe(u8, alias);
            const model_dup = try self.allocator.dupe(u8, alias);
            self.prov.setModel(model_dup);
            if (provider.modelSpecFor(self.provider_entries, self.api, alias)) |spec| {
                self.context_limit = spec.context_limit;
                if (self.cfg.max_tokens > spec.max_output) self.cfg.max_tokens = spec.max_output;
            }
        }

        try self.stdout.print("\n{s}{s}模型已切换: {s}{s}\n", .{ ansi.C.bold, ansi.C.green, alias, ansi.C.reset });
        try self.stdout.flush();
    }

    fn singleTurn(self: *App, prompt: []const u8, sm: *session.SessionManager) !void {
        var msg_buf = std.array_list.Managed(types.Message).init(self.allocator);
        defer msg_buf.deinit();
        if (sm.flushed) {
            const ctx = try sm.buildContext();
            for (ctx) |msg| try msg_buf.append(msg);
        }

        const sys_text = try system.buildSystemPrompt(self.allocator, self.project_root, self.api, self.model, self.io, self.agents_md, self.available_skills);
        try msg_buf.insert(0, types.Message{ .role = .system, .content = try allocContent(self.allocator, sys_text) });
        try msg_buf.append(types.Message{ .role = .user, .content = try allocContent(self.allocator, prompt) });
        try self.agentLoop(&msg_buf, sm);
    }

    fn repl(self: *App, sm: *session.SessionManager) !void {
        var msg_buf = std.array_list.Managed(types.Message).init(self.allocator);
        defer msg_buf.deinit();
        if (sm.flushed) {
            const ctx = try sm.buildContext();
            for (ctx) |msg| try msg_buf.append(msg);
            try self.stdout.print("\n(会话已恢复: {d} 条消息)\n", .{ctx.len});
        }

        const sys_text = try system.buildSystemPrompt(self.allocator, self.project_root, self.api, self.model, self.io, self.agents_md, self.available_skills);
        try msg_buf.insert(0, types.Message{ .role = .system, .content = try allocContent(self.allocator, sys_text) });

        try self.stdout.print("\nEntering interactive mode. Type /help for commands.\n\n", .{});
        try self.stdout.flush();

        while (true) {
            if (signal.isInterrupted()) {
                signal.reset();
                hook.run(self.allocator, self.io, self.project_root, "session_end", "{}", self.stdout);
                try self.stdout.print("\nBye!\n", .{});
                try self.stdout.flush();
                return;
            }
        try self.stdout.print("{s}>>>{s} ", .{ ansi.C.cyan, ansi.C.reset });
        try self.stdout.flush();

            const line = try readLine(self.allocator, self.io);
            defer self.allocator.free(line);
            if (line.len == 0) continue;

            const submit_payload = std.fmt.allocPrint(self.allocator, "{{\"text\":\"{s}\"}}", .{line}) catch "{}";
            defer self.allocator.free(submit_payload);
            hook.run(self.allocator, self.io, self.project_root, "user_prompt_submit", submit_payload, self.stdout);

            if (std.mem.eql(u8, line, "/exit") or std.mem.eql(u8, line, "/quit")) {
                hook.run(self.allocator, self.io, self.project_root, "session_end", "{}", self.stdout);
                try self.stdout.print("Bye!\n", .{});
                try self.stdout.flush();
                return;
            }

            if (self.commands.match(self.allocator, line)) |result| {
                switch (result) {
                    .help => {
                        const text = try self.commands.helpText(self.allocator);
                        defer self.allocator.free(text);
                        try self.stdout.print("{s}", .{text});
                        try self.stdout.flush();
                        continue;
                    },
                    .new_session => {
                        if (!sm.flushed and sm.entries.items.len > 0) try sm.flushFile();
                        const sd = try self.allocator.dupe(u8, sm.session_dir);
                        sm.deinit();
                        sm.* = try session.SessionManager.create(self.allocator, self.io, sd, self.model, self.api);
                        msg_buf.clearAndFree();
                        msg_buf = std.array_list.Managed(types.Message).init(self.allocator);
                        const fresh_sys = try system.buildSystemPrompt(self.allocator, self.project_root, self.api, self.model, self.io, self.agents_md, self.available_skills);
                        try msg_buf.insert(0, types.Message{ .role = .system, .content = try allocContent(self.allocator, fresh_sys) });
                        try self.stdout.print("\n新会话已创建。\n\n", .{});
                        try self.stdout.flush();
                        continue;
                    },
                    .list => {
                        Cli.printSessionList(self.allocator, self.io, self.stdout, self.session_dir) catch {};
                        continue;
                    },
                    .switch_session => |arg| {
                        defer self.allocator.free(arg);
                        if (!sm.flushed and sm.entries.items.len > 0) try sm.flushFile();
                        const new_sm = if (std.fmt.parseInt(usize, arg, 10)) |idx|
                            try session.continueByIndex(self.allocator, self.io, self.session_dir, if (idx > 0) idx - 1 else 0)
                        else |_|
                            try session.continueById(self.allocator, self.io, self.session_dir, arg);
                        sm.deinit();
                        sm.* = new_sm;
                        msg_buf.clearAndFree();
                        msg_buf = std.array_list.Managed(types.Message).init(self.allocator);
                        var restored: usize = 0;
                        if (sm.flushed) {
                            const ctx = try sm.buildContext();
                            restored = ctx.len;
                            for (ctx) |msg| try msg_buf.append(msg);
                        }
                        const fresh_sys = try system.buildSystemPrompt(self.allocator, self.project_root, self.api, self.model, self.io, self.agents_md, self.available_skills);
                        try msg_buf.insert(0, types.Message{ .role = .system, .content = try allocContent(self.allocator, fresh_sys) });
                        try self.stdout.print("\n已切换到会话 ({d} 条消息):\n", .{restored});
                        for (msg_buf.items[1..]) |msg| {
                            if (msg.role == .system) continue;
                            const role_str = @tagName(msg.role);
                            if (msg.content) |parts| {
                                if (parts.len > 0 and parts[0] == .text) {
                                    const preview = if (parts[0].text.len > 80) parts[0].text[0..80] else parts[0].text;
                                    try self.stdout.print("  {s}: {s}\n", .{ role_str, preview });
                                }
                            }
                        }
                        try self.stdout.print("\n", .{});
                        try self.stdout.flush();
                        continue;
                    },
                    .name => |n| {
                        defer self.allocator.free(n);
                        try sm.rename(n);
                        try self.stdout.print("\n会话已命名: {s}\n", .{n});
                        try self.stdout.flush();
                        continue;
                    },
                    .list_models => {
                        try self.stdout.print("\n当前: {s} ({s})", .{ self.model, self.api });
                        try self.stdout.print("\n可用:\n", .{});
                        var has_models = false;
                        for (self.cfg.providers) |p| {
                            for (p.models) |m| {
                                const full_name = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ p.name, m });
                                defer self.allocator.free(full_name);
                                const marker = if (std.mem.eql(u8, full_name, self.model)) "*" else " ";
                                try self.stdout.print("  {s} {s}\n", .{ marker, full_name });
                                has_models = true;
                            }
                        }
                        if (!has_models) try self.stdout.print("  (无预设模型，使用 /model <名称> 直接切换)\n", .{});
                        try self.stdout.flush();
                        continue;
                    },
                    .model => |m| {
                        defer self.allocator.free(m);
                        if (!sm.flushed and sm.entries.items.len > 0) try sm.flushFile();
                        const old_model = self.model;
                        try self.setModel(m);

                        var est: usize = 0;
                        for (msg_buf.items) |msg| {
                            if (msg.content) |parts| {
                                for (parts) |p| {
                                    if (p == .text) est += token.estimate(p.text);
                                }
                            }
                        }
                        const input_budget = if (self.context_limit > self.cfg.max_tokens)
                            self.context_limit - self.cfg.max_tokens
                        else
                            self.context_limit;
                        const threshold: usize = @intCast(@as(u64, input_budget) * 85 / 100);

                        if (est > threshold) {
                            try self.stdout.print("\n⚠ 上下文溢出预警:\n", .{});
                            try self.stdout.print("  当前消息: {d} 条 / 约 {d} tokens\n", .{ msg_buf.items.len, est });
                            try self.stdout.print("  新模型窗口: {d} tokens (阈值 {d})\n", .{ self.context_limit, threshold });
                            try self.stdout.print("  超出 {d} tokens，消息将被截断。继续? [y/N] ", .{est -| threshold});
                            try self.stdout.flush();
                            const answer = readlineConfirm(self) catch |err| {
                                self.model = old_model;
                                self.prov.setModel(old_model);
                                return err;
                            };
                            if (answer.len == 0 or (answer[0] != 'y' and answer[0] != 'Y')) {
                                self.model = old_model;
                                self.prov.setModel(old_model);
                                try self.stdout.print("已取消。\n", .{});
                                try self.stdout.flush();
                                continue;
                            }
                        }

                        try sm.updateHeader(self.model, self.api);

                        const fresh_sys = try system.buildSystemPrompt(self.allocator, self.project_root, self.api, self.model, self.io, self.agents_md, self.available_skills);
                        msg_buf.clearRetainingCapacity();
                        try msg_buf.insert(0, types.Message{ .role = .system, .content = try allocContent(self.allocator, fresh_sys) });
                        continue;
                    },
                    .template => |prompt| {
                        defer self.allocator.free(prompt);
                        const user_content = try self.allocator.dupe(u8, prompt);
                        errdefer self.allocator.free(user_content);
                        const user_msg = types.Message{ .role = .user, .content = try allocContent(self.allocator, user_content) };
                        try msg_buf.append(user_msg);
                        try sm.appendMessage(msg_buf.items[msg_buf.items.len - 1]);
                        try self.agentLoop(&msg_buf, sm);
                        continue;
                    },
                }
            }

            const user_content = try self.allocator.dupe(u8, line);
            errdefer self.allocator.free(user_content);
            const user_msg = types.Message{ .role = .user, .content = try allocContent(self.allocator, user_content) };
            try msg_buf.append(user_msg);
            try sm.appendMessage(msg_buf.items[msg_buf.items.len - 1]);

            try self.agentLoop(&msg_buf, sm);
        }
    }

    fn agentLoop(self: *App, messages: *std.array_list.Managed(types.Message), sm: *session.SessionManager) !void {
        var tool_rounds: u32 = 0;
        var actual_total_tokens: ?u32 = null;
        while (tool_rounds < 10) : (tool_rounds += 1) {
            const compact_result = try compact.compact(self.allocator, self.io, self.prov, messages, self.context_limit, self.cfg.max_tokens, self.stdout);
            if (compact_result) |info| {
                try self.stdout.print("\n{s}[压缩]{s} 保留 {d} 条消息, 生成摘要 ({d} 条丢弃)\n", .{ ansi.C.cyan, ansi.C.reset, info.keep_count, info.dropped_count });
                try self.stdout.flush();
                try sm.appendCompaction(info.summary, info.keep_count, info.tokens_before);
                try sm.flushFile();
            }

            const response = callWithRetry(self.prov, self.allocator, self.io, messages.items, self.stdout) catch |err| {
                    if (err == error.Interrupted) {
                        try self.stdout.print("\n{s}[中断]{s} 操作被用户取消\n", .{ ansi.C.yellow, ansi.C.reset });
                    try self.stdout.flush();
                    signal.reset();
                    return;
                }
                try self.stdout.print("\n{s}[错误]{s} API 调用失败: {}，已重试 3 次\n", .{ ansi.C.red, ansi.C.reset, err });
                try self.stdout.flush();
                return;
            };
            if (response.usage) |u| actual_total_tokens = u.total_tokens;
            try self.stdout.print("\n", .{});
            try self.stdout.flush();

            if (response.tool_calls) |tcs| {
                const now_ns = std.Io.Clock.Timestamp.now(self.io, .real).raw.nanoseconds;
                const assistant_msg = types.Message{
                    .role = .assistant, .content = null, .tool_calls = tcs,
                    .reasoning = response.reasoning, .timestamp_ns = now_ns,
                };
                try messages.append(assistant_msg);
                try sm.appendMessage(messages.items[messages.items.len - 1]);
                if (!sm.flushed) try sm.flushFile();

                for (tcs) |tc| {
                    try printToolCall(self.stdout, self.allocator, tc.name, tc.arguments);
                    try self.stdout.flush();
                    if (std.mem.eql(u8, tc.name, "task")) {
                        if (std.json.parseFromSlice(std.json.Value, self.allocator, tc.arguments, .{})) |parsed_val| {
                            defer parsed_val.deinit();
                            const parsed = parsed_val.value;
                            if (parsed.object.get("agent")) |a| {
                                try self.stdout.print("  {s}[{s}]{s} 正在执行任务...\n", .{ ansi.C.cyan, a.string, ansi.C.reset });
                                try self.stdout.flush();
                            }
                        } else |_| {}
                    }
                    const start_ns = std.Io.Clock.Timestamp.now(self.io, .real).raw.nanoseconds;
                    var result: []const u8 = undefined;
                    var skip_result: ?[]const u8 = null;
                    var is_error: bool = false;

                    const is_modify = std.mem.eql(u8, tc.name, "write_file") or std.mem.eql(u8, tc.name, "edit_file") or std.mem.eql(u8, tc.name, "bash") or std.mem.eql(u8, tc.name, "task");
                    if (is_modify) {
                        const hook_payload = std.fmt.allocPrint(self.allocator, "{{\"tool\":\"{s}\",\"args\":{s}}}", .{ tc.name, tc.arguments }) catch "{}";
                        defer self.allocator.free(hook_payload);
                        if (!hook.runIntercept(self.allocator, self.io, self.project_root, "pre_tool_use", hook_payload, self.stdout)) {
                            skip_result = std.fmt.allocPrint(self.allocator, "Error: hook blocked {s}", .{tc.name}) catch "Error: blocked";
                            result = skip_result.?;
                            is_error = true;
                            const end_ns = std.Io.Clock.Timestamp.now(self.io, .real).raw.nanoseconds;
                            const duration_ms = @as(u32, @intCast(@divFloor(end_ns - start_ns, 1_000_000)));
                            const tool_content = try allocContentTool(self.allocator, result, tc.id, tc.name, duration_ms, is_error);
                            const tool_msg = types.Message{ .role = .tool, .tool_call_id = tc.id, .content = tool_content, .timestamp_ns = end_ns };
                            try messages.append(tool_msg);
                            try sm.appendMessage(messages.items[messages.items.len - 1]);
                            continue;
                        }
                    }
                    if (std.mem.eql(u8, tc.name, "write_file") or std.mem.eql(u8, tc.name, "edit_file")) {
                        const parsed = if (std.json.parseFromSlice(std.json.Value, self.allocator, tc.arguments, .{})) |v| v else |_| null: {
                            break :null null;
                        };
                        defer if (parsed) |p| p.deinit();
                        const tool_path = if (parsed) |p| blk: {
                            break :blk if (p.value.object.get("path")) |path_val| if (path_val == .string) path_val.string else "" else "";
                        } else "";
                        const path_dup = try self.allocator.dupe(u8, tool_path);
                        defer self.allocator.free(path_dup);
                        const action = self.perm.check(tc.name, path_dup, null, self.trust);
                        switch (action) {
                            .deny => {
                                skip_result = std.fmt.allocPrint(self.allocator, "Error: permission denied for {s} on '{s}'", .{ tc.name, path_dup }) catch "Error: denied";
                                result = skip_result.?;
                                is_error = true;
                            },
                            .allow => {
                                const tool_result = self.reg.execute(self.allocator, self.io, tc);
                                result = tool_result.output;
                                is_error = !tool_result.success;
                            },
                            .confirm => {
                                try self.stdout.print("  {s}[确认]{s} {s} → 即将执行。继续? [y/N] ", .{ ansi.C.yellow, ansi.C.reset, path_dup });
                                try self.stdout.flush();
                                const answer = readlineConfirm(self) catch "";
                                if (answer.len == 0 or (answer[0] != 'y' and answer[0] != 'Y')) {
                                    skip_result = std.fmt.allocPrint(self.allocator, "Error: user declined {s} on '{s}'", .{ tc.name, path_dup }) catch "Error: user declined";
                                    result = skip_result.?;
                                    is_error = true;
                                } else {
                                    const tool_result = self.reg.execute(self.allocator, self.io, tc);
                                    result = tool_result.output;
                                    is_error = !tool_result.success;
                                }
                            },
                        }
                    } else if (std.mem.eql(u8, tc.name, "bash")) {
                        const action = if (std.json.parseFromSlice(std.json.Value, self.allocator, tc.arguments, .{})) |parsed_val| blk: {
                            defer parsed_val.deinit();
                            const cmd = if (parsed_val.value.object.get("command")) |c| if (c == .string) c.string else "" else "";
                            break :blk self.perm.check(tc.name, null, cmd, self.trust);
                        } else |_|
                            self.perm.check(tc.name, null, null, self.trust)
                        ;
                        switch (action) {
                            .deny => {
                                skip_result = "Error: permission denied for bash";
                                result = skip_result.?;
                                is_error = true;
                            },
                            .allow, .confirm => {
                                const tool_result = self.reg.execute(self.allocator, self.io, tc);
                                result = tool_result.output;
                                is_error = !tool_result.success;
                            },
                        }
                    } else if (std.mem.eql(u8, tc.name, "task")) {
                        const action = self.perm.check(tc.name, null, null, self.trust);
                        switch (action) {
                            .deny => {
                                skip_result = "Error: permission denied for task";
                                result = skip_result.?;
                                is_error = true;
                            },
                            .allow, .confirm => {
                                const tool_result = self.reg.execute(self.allocator, self.io, tc);
                                result = tool_result.output;
                                is_error = !tool_result.success;
                            },
                        }
                    } else {
                        const tool_result = self.reg.execute(self.allocator, self.io, tc);
                        result = tool_result.output;
                        is_error = !tool_result.success;
                    }
                    const end_ns = std.Io.Clock.Timestamp.now(self.io, .real).raw.nanoseconds;
                    const duration_ms = @as(u32, @intCast(@divFloor(end_ns - start_ns, 1_000_000)));
                    if (is_error) {
                        try self.stdout.print("  {s}→ {s}{s}\n", .{ ansi.C.red, result, ansi.C.reset });
                    } else if (self.reg.findHandler(tc.name)) |h| {
                        if (h.renderResult) |rr| {
                            rr(self.allocator, self.stdout, result) catch {};
                        } else {
                            printToolResult(self.allocator, self.stdout, tc.name, result) catch {};
                        }
                    } else {
                        printToolResult(self.allocator, self.stdout, tc.name, result) catch {};
                    }
                    try self.stdout.flush();
                    const tool_content = try allocContentTool(self.allocator, result, tc.id, tc.name, duration_ms, is_error);
                    const tool_msg = types.Message{
                        .role = .tool, .tool_call_id = tc.id, .content = tool_content, .timestamp_ns = end_ns,
                    };
                    try messages.append(tool_msg);
                    try sm.appendMessage(messages.items[messages.items.len - 1]);

                    if (std.mem.eql(u8, tc.name, "read_file")) {
                        if (std.json.parseFromSlice(std.json.Value, self.allocator, result, .{})) |parsed_val| {
                            defer parsed_val.deinit();
                            const parsed = parsed_val.value;
                            if (parsed.object.get("image")) |img_val| {
                                if (img_val != .null) {
                                    const uri = try self.allocator.dupe(u8, img_val.string);
                                    const img_part = types.ContentPart{ .image_url = .{ .url = uri } };
                                    const img_parts = try self.allocator.alloc(types.ContentPart, 1);
                                    img_parts[0] = img_part;
                                    const img_msg = types.Message{
                                        .role = .user, .content = img_parts, .timestamp_ns = end_ns,
                                    };
                                    try messages.append(img_msg);
                                    try sm.appendMessage(messages.items[messages.items.len - 1]);
                                }
                            }
                        } else |_| {}
                    }
                    const hook_payload = std.fmt.allocPrint(self.allocator, "{{\"tool\":\"{s}\",\"duration_ms\":{d}}}", .{ tc.name, duration_ms }) catch "{}";
                    defer self.allocator.free(hook_payload);
                    hook.run(self.allocator, self.io, self.project_root, "post_tool_use", hook_payload, self.stdout);
                }
                continue;
            }

            if (response.content) |content| {
                if (self.agent_mode) {
                    if (self.result_marker) |mk| {
                        try self.stdout.print("\n[ZAGENT_RESULT:{s}]{s}[ZAGENT_END:{s}]\n", .{ mk, content, mk });
                    } else {
                        try self.stdout.print("\n[ZAGENT_RESULT]{s}[ZAGENT_END]\n", .{content});
                    }
                }
                const assistant_content = try self.allocator.dupe(u8, content);
                errdefer self.allocator.free(assistant_content);
                const reply_msg = types.Message{
                    .role = .assistant, .content = try allocContent(self.allocator, assistant_content),
                    .reasoning = response.reasoning,
                    .timestamp_ns = std.Io.Clock.Timestamp.now(self.io, .real).raw.nanoseconds,
                };
                try messages.append(reply_msg);
                try sm.appendMessage(messages.items[messages.items.len - 1]);
                if (!sm.flushed) try sm.flushFile();
            }
            return;
        }
    }
};

fn readAgentsMd(allocator: std.mem.Allocator, project_root: []const u8, io: std.Io) ?[]const u8 {
    const candidates = [_][]const u8{ "AGENTS.md", "CLAUDE.md" };
    for (candidates) |name| {
        const path = std.fs.path.join(allocator, &.{ project_root, name }) catch continue;
        defer allocator.free(path);
        const file = std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only }) catch continue;
        defer file.close(io);
        const stat = file.stat(io) catch continue;
        const size: usize = @intCast(stat.size);
        if (size == 0) continue;
        const content = allocator.alloc(u8, size) catch continue;
        _ = file.readPositionalAll(io, content, 0) catch {
            allocator.free(content);
            continue;
        };
        return content;
    }
    return null;
}

fn readAgentFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ?[]const u8 {
    const file = std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only }) catch return null;
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

fn allocContent(allocator: std.mem.Allocator, text: []const u8) ![]const types.ContentPart {
    const arr = try allocator.alloc(types.ContentPart, 1);
    arr[0] = .{ .text = text };
    return arr;
}

fn allocContentTool(allocator: std.mem.Allocator, text: []const u8, id: []const u8, name: []const u8, duration_ms: u32, is_error: bool) ![]const types.ContentPart {
    const arr = try allocator.alloc(types.ContentPart, 1);
    arr[0] = .{ .tool_result = .{
        .id = id, .content = text,
        .is_error = is_error,
        .name = name, .duration_ms = duration_ms,
    } };
    return arr;
}



fn callWithRetry(prov: provider.Provider, allocator: std.mem.Allocator, io: std.Io, messages: []const types.Message, stdout: *std.Io.Writer) !types.ChatResponse {
    const max_retries: u32 = 3;
    var last_err: ?anyerror = null;
    var delay_ns: u64 = 1_000_000_000;

    for (0..max_retries) |i| {
        if (i > 0) {
            try stdout.print("\n{s}[重试]{s} 第 {d}/{d} 次，等待 {d}s...\n", .{ ansi.C.yellow, ansi.C.reset, i + 1, max_retries, delay_ns / 1_000_000_000 });
            try stdout.flush();
            Cli.sleepMs(delay_ns / 1_000_000);
            delay_ns *= 2;
        }
        const response = prov.chatCompletionStreaming(allocator, io, messages, stdout) catch |err| {
            if (err == error.Interrupted) return error.Interrupted;
            if (err == error.ApiError) return error.ApiError;
            last_err = err;
            continue;
        };
        return response;
    }
    return last_err.?;
}

fn readLine(allocator: std.mem.Allocator, io: std.Io) ![]const u8 {
    var buf: [4096]u8 = undefined;
    const stdin_file = std.Io.File.stdin();
    var total: usize = 0;
    while (total < buf.len) {
        const n = try stdin_file.readStreaming(io, &.{buf[total..]});
        if (n == 0) break;
        total += n;
        for (buf[total - n .. total]) |c| {
            if (c == '\n') {
                const trimmed = std.mem.trim(u8, buf[0 .. total - 1], "\r");
                return allocator.dupe(u8, trimmed);
            }
        }
    }
    return error.EndOfStream;
}

fn readlineConfirm(self: *App) ![]const u8 {
    var buf: [128]u8 = undefined;
    const stdin_file = std.Io.File.stdin();
    var total: usize = 0;
    while (total < buf.len) {
        const n = try stdin_file.readStreaming(self.io, &.{buf[total..]});
        if (n == 0) break;
        total += n;
        for (buf[total - n .. total]) |c| {
            if (c == '\n') {
                const trimmed = std.mem.trim(u8, buf[0 .. total - 1], "\r");
                return self.allocator.dupe(u8, trimmed);
            }
        }
    }
    return error.EndOfStream;
}

fn printToolCall(stdout: *std.Io.Writer, allocator: std.mem.Allocator, name: []const u8, args_json: []const u8) !void {
    try stdout.print("{s}[工具]{s} {s}\n", .{ ansi.C.yellow, ansi.C.reset, name });

    if (std.mem.eql(u8, name, "write_file")) {
        var parsed_val = std.json.parseFromSlice(std.json.Value, allocator, args_json, .{}) catch {
            try stdout.print("  {s}\n", .{args_json});
            return;
        };
        defer parsed_val.deinit();
        const parsed = parsed_val.value;
        const obj = parsed.object;
        if (obj.get("path")) |p| {
            try stdout.writeAll("  path: ");
            try tool_json.prettyPrint(stdout, p, 4);
            try stdout.writeByte('\n');
        }
        if (obj.get("content")) |c| {
            if (c == .string) {
                try stdout.writeAll("  content:\n");
                var lines = std.mem.splitScalar(u8, c.string, '\n');
                while (lines.next()) |ln| {
                    try stdout.print("  | {s}\n", .{std.mem.trimEnd(u8, ln, "\r")});
                }
            }
        }
        return;
    }

    if (std.mem.eql(u8, name, "task")) {
        var parsed_val = std.json.parseFromSlice(std.json.Value, allocator, args_json, .{}) catch {
            try stdout.print("  {s}\n", .{args_json});
            return;
        };
        defer parsed_val.deinit();
        const parsed = parsed_val.value;
        const obj = parsed.object;
        if (obj.get("agent")) |a| {
            try stdout.writeAll("  agent: ");
            try tool_json.prettyPrint(stdout, a, 4);
            try stdout.writeByte('\n');
        }
        if (obj.get("task")) |t| {
            if (t == .string) {
                try stdout.writeAll("  task: ");
                try stdout.print("{s}\n", .{t.string});
            }
        }
        return;
    }

    if (std.mem.eql(u8, name, "ask_user")) {
        var parsed_val = std.json.parseFromSlice(std.json.Value, allocator, args_json, .{}) catch {
            try stdout.print("  {s}\n", .{args_json});
            return;
        };
        defer parsed_val.deinit();
        const parsed = parsed_val.value;
        if (parsed.object.get("question")) |q| {
            if (q == .string) {
                try stdout.print("  question: {s}\n", .{q.string});
            }
        }
        return;
    }

    var parsed_val = std.json.parseFromSlice(std.json.Value, allocator, args_json, .{}) catch {
        try stdout.print("  {s}\n", .{args_json});
        return;
    };
    defer parsed_val.deinit();
    const parsed = parsed_val.value;
    if (parsed == .object) {
        var it = parsed.object.iterator();
        while (it.next()) |entry| {
            try stdout.print("  {s}: ", .{entry.key_ptr.*});
            try tool_json.prettyPrint(stdout, entry.value_ptr.*, 4);
            try stdout.print("\n", .{});
        }
    } else {
        try stdout.writeAll("  ");
        try tool_json.prettyPrint(stdout, parsed, 2);
        try stdout.writeByte('\n');
    }
}

fn printToolResult(allocator: std.mem.Allocator, stdout: *std.Io.Writer, tool_name: []const u8, json_str: []const u8) !void {
    if (!std.mem.startsWith(u8, json_str, "{")) {
        try stdout.print("  {s}→{s} {s}\n", .{ ansi.C.green, ansi.C.reset, json_str });
        return;
    }
    var parsed_val = std.json.parseFromSlice(std.json.Value, allocator, json_str, .{}) catch {
        try stdout.print("  {s}→{s} {s}\n", .{ ansi.C.green, ansi.C.reset, json_str });
        return;
    };
    defer parsed_val.deinit();
    const parsed = parsed_val.value;
    const obj = parsed.object;

    if (std.mem.eql(u8, tool_name, "bash")) {
        const exit_code = if (obj.get("exit_code")) |v| @as(i32, @intCast(v.integer)) else -1;
        const so = if (obj.get("stdout")) |v| if (v == .string) v.string else "" else "";
        const se = if (obj.get("stderr")) |v| if (v == .string) v.string else "" else "";
        const icon = if (exit_code == 0) "✓" else "✗";
        try stdout.print("  {s}{s}{s} exit:{d}\n", .{ if (exit_code == 0) ansi.C.green else ansi.C.red, icon, ansi.C.reset, exit_code });
        if (so.len > 0) {
            var lines = std.mem.splitScalar(u8, so, '\n');
            while (lines.next()) |ln| {
                const trimmed = std.mem.trim(u8, ln, "\r");
                if (trimmed.len > 0) try stdout.print("  | {s}\n", .{trimmed});
            }
        }
        if (se.len > 0) {
            try stdout.print("  stderr:\n", .{});
            var lines = std.mem.splitScalar(u8, se, '\n');
            while (lines.next()) |ln| {
                try stdout.print("  | {s}\n", .{std.mem.trimEnd(u8, ln, "\r")});
            }
        }
        return;
    }
    if (std.mem.eql(u8, tool_name, "read_file")) {
        const path = if (obj.get("path")) |v| if (v == .string) v.string else "" else "";
        const content = if (obj.get("content")) |v| if (v == .string) v.string else "" else "";
        const offset = if (obj.get("offset")) |v| if (v != .null) @as(u64, @intCast(@max(v.integer, 0))) else 0 else 0;
        try stdout.print("  {s}", .{path});
        if (offset > 0) try stdout.print("  offset:{d}", .{offset});
        try stdout.print("\n", .{});
        if (content.len > 0) {
            var lines = std.mem.splitScalar(u8, content, '\n');
            while (lines.next()) |ln| {
                try stdout.print("  | {s}\n", .{std.mem.trimEnd(u8, ln, "\r")});
            }
        }
        return;
    }
    if (std.mem.eql(u8, tool_name, "write_file")) {
        const path = if (obj.get("path")) |v| if (v == .string) v.string else "" else "";
        const bytes = if (obj.get("bytes")) |v| @as(u64, @intCast(@max(v.integer, 0))) else 0;
        const preview = if (obj.get("content_preview")) |v| if (v == .string) v.string else "" else "";
        try stdout.print("  ✓ 写入 {d} bytes → {s}\n", .{ bytes, path });
        if (preview.len > 0) {
            var lines = std.mem.splitScalar(u8, preview, '\n');
            while (lines.next()) |ln| {
                try stdout.print("  | {s}\n", .{std.mem.trimEnd(u8, ln, "\r")});
            }
        }
        return;
    }
    if (std.mem.eql(u8, tool_name, "edit_file")) {
        const path = if (obj.get("path")) |v| if (v == .string) v.string else "" else "";
        const replacements = if (obj.get("replacements")) |v| @as(u64, @intCast(@max(v.integer, 0))) else 0;
        try stdout.print("  ✓ 替换 {d} 处 → {s}\n", .{ replacements, path });
        return;
    }
    if (std.mem.eql(u8, tool_name, "glob")) {
        const pat = if (obj.get("pattern")) |v| if (v == .string) v.string else "" else "";
        const count = if (obj.get("count")) |v| @as(u64, @intCast(@max(v.integer, 0))) else 0;
        try stdout.print("  ✓ {d} matches for '{s}'\n", .{ count, pat });
        if (obj.get("matches")) |m| {
            if (m == .array) {
                for (m.array.items) |match| {
                    if (match == .string) try stdout.print("    {s}\n", .{match.string});
                }
            }
        }
        return;
    }
    if (std.mem.eql(u8, tool_name, "grep")) {
        const pat = if (obj.get("pattern")) |v| if (v == .string) v.string else "" else "";
        const count = if (obj.get("count")) |v| @as(u64, @intCast(@max(v.integer, 0))) else 0;
        try stdout.print("  ✓ {d} matches for '{s}'\n", .{ count, pat });
        if (obj.get("matches")) |m| {
            if (m == .array) {
                for (m.array.items) |match| {
                    if (match == .string) try stdout.print("    {s}\n", .{match.string});
                }
            }
        }
        return;
    }
    if (std.mem.eql(u8, tool_name, "ask_user")) {
        const q = if (obj.get("question")) |v| if (v == .string) v.string else "" else "";
        const a = if (obj.get("answer")) |v| if (v == .string) v.string else "" else "";
        try stdout.print("  问: {s}\n  答: {s}\n", .{ q, a });
        return;
    }

    try stdout.writeAll("  ");
    try tool_json.prettyPrint(stdout, parsed, 2);
    try stdout.writeByte('\n');
}
