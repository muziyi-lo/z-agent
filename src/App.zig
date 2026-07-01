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
const agent = @import("agent.zig");
const permission = @import("permission.zig");
const picker = @import("picker.zig");
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
    agent_prompt: ?[]const u8 = null,
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
        
        const agents_md = readAgentsMd(arena, project_root, io);
        var agent_prompt: ?[]const u8 = null;
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
            .connect_timeout_secs = prov_entry.connect_timeout_secs,
            .max_timeout_secs = prov_entry.max_timeout_secs,
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
                    agent_prompt = readAgentFile(arena, io, agent_file);
                    continue;
                }
                if (std.mem.eql(u8, arg, "--agent-prompt")) {
                    i += 1;
                    if (i >= args.len) {
                        try stdout.print("Error: --agent-prompt requires a content argument\n", .{});
                        try stdout.flush();
                        return error.MissingAgentPromptArg;
                    }
                    is_agent = true;
                    agent_prompt = try arena.dupe(u8, args[i]);
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
                if (std.mem.eql(u8, arg, "--readonly")) {
                    perm_ptr.readonly = true;
                    continue;
                }
                if (std.mem.eql(u8, arg, "--model")) {
                    i += 1;
                    if (i >= args.len) {
                        try stdout.print("Error: --model requires an argument (e.g. deepseek/deepseek-v4-flash)\n", .{});
                        try stdout.flush();
                        return error.MissingModelArg;
                    }
                    cfg.default_model = try arena.dupe(u8, args[i]);
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

        if (perm_ptr.readonly) {
            try stdout.print("{s}[只读模式]{s} 写操作（write/edit/bash/task/ask_user/memory）已被禁止\n", .{ ansi.C.yellow, ansi.C.reset });
            try stdout.flush();
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
            .agent_prompt = agent_prompt,
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
                        .connect_timeout_secs = pe.connect_timeout_secs,
                        .max_timeout_secs = pe.max_timeout_secs,
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

        const sys_text = try system.buildSystemPrompt(self.allocator, self.project_root, self.project_root, self.api, self.model, self.io, self.agents_md, self.available_skills, system.detectModelFamily(self.model), self.agent_prompt);
        try msg_buf.insert(0, types.Message{ .role = .system, .content = try allocContent(self.allocator, sys_text) });
        try msg_buf.append(types.Message{ .role = .user, .content = try allocContent(self.allocator, prompt) });
        try agent.agentLoop(
            self.allocator,
            self.io,
            self.stdout,
            self.prov,
            self.reg,
            self.perm,
            sm,
            &msg_buf,
            self.context_limit,
            self.cfg.max_tokens,
            self.agent_mode,
            self.result_marker,
            self.trust,
            self.debug_logging,
            self.project_root,
        );
    }

    fn repl(self: *App, sm: *session.SessionManager) !void {
        var msg_buf = std.array_list.Managed(types.Message).init(self.allocator);
        defer msg_buf.deinit();
        if (sm.flushed) {
            const ctx = try sm.buildContext();
            for (ctx) |msg| try msg_buf.append(msg);
            try self.stdout.print("\n(会话已恢复: {d} 条消息)\n", .{ctx.len});
        }

        const sys_text = try system.buildSystemPrompt(self.allocator, self.project_root, self.project_root, self.api, self.model, self.io, self.agents_md, self.available_skills, system.detectModelFamily(self.model), self.agent_prompt);
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

            if (std.fmt.allocPrint(self.allocator, "{{\"text\":\"{s}\"}}", .{line})) |submit_payload| {
                defer self.allocator.free(submit_payload);
                hook.run(self.allocator, self.io, self.project_root, "user_prompt_submit", submit_payload, self.stdout);
            } else |_| {}

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
                        const fresh_sys = try system.buildSystemPrompt(self.allocator, self.project_root, self.project_root, self.api, self.model, self.io, self.agents_md, self.available_skills, system.detectModelFamily(self.model), self.agent_prompt);
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
                        const fresh_sys = try system.buildSystemPrompt(self.allocator, self.project_root, self.project_root, self.api, self.model, self.io, self.agents_md, self.available_skills, system.detectModelFamily(self.model), self.agent_prompt);
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
                            try self.stdout.print("  超出 {d} tokens，消息将被截断\n", .{est -| threshold});
                            try self.stdout.flush();
                            const choice = picker.select(self.allocator, self.io, self.stdout, "  继续?", &.{"继续", "取消"}, 1) catch null;
                            if (choice == null or choice.? == 1) {
                                self.model = old_model;
                                self.prov.setModel(old_model);
                                try self.stdout.print("已取消。\n", .{});
                                try self.stdout.flush();
                                continue;
                            }
                        }

                        try sm.updateHeader(self.model, self.api);

                        const fresh_sys = try system.buildSystemPrompt(self.allocator, self.project_root, self.project_root, self.api, self.model, self.io, self.agents_md, self.available_skills, system.detectModelFamily(self.model), self.agent_prompt);
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
                        try agent.agentLoop(
                            self.allocator,
                            self.io,
                            self.stdout,
                            self.prov,
                            self.reg,
                            self.perm,
                            sm,
                            &msg_buf,
                            self.context_limit,
                            self.cfg.max_tokens,
                            self.agent_mode,
                            self.result_marker,
                            self.trust,
                            self.debug_logging,
                            self.project_root,
                        );
                        continue;
                    },
                }
            }

            const user_content = try self.allocator.dupe(u8, line);
            errdefer self.allocator.free(user_content);
            const user_msg = types.Message{ .role = .user, .content = try allocContent(self.allocator, user_content) };
            try msg_buf.append(user_msg);
            try sm.appendMessage(msg_buf.items[msg_buf.items.len - 1]);

            try agent.agentLoop(
                self.allocator,
                self.io,
                self.stdout,
                self.prov,
                self.reg,
                self.perm,
                sm,
                &msg_buf,
                self.context_limit,
                self.cfg.max_tokens,
                self.agent_mode,
                self.result_marker,
                self.trust,
                self.debug_logging,
                self.project_root,
            );
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



