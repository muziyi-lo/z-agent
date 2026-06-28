# z-agent — AGENTS.md

Auto-injected into system prompt (see `src/system.zig`). Every line here must answer: "Would an agent miss this without help?" If no, delete it.

## Structure

Tools register as `.handlers = &.{` in `src/App.zig`, each importing `execute` from `src/tool/<name>.zig`. Providers register as `provider_entries` array in the same file, referencing `src/provider/<name>.zig`. Entry point: `src/main.zig`.

## Build & test

```
zig build
zig build -Dtarget=x86_64-windows
zig build test
zig build test-real
zig build run
```

## Constraints

| Area | Rule |
|---|---|
| **Config** | `.zagent/config.toml` (auto-created). Fields: `default_model`, `max_tokens`, `[[providers]]` array with name/kind/base_url/models/api_key_env/context_limit. `permissions` table with `mode` + `allow`/`ask`/`deny` arrays. |
| **API keys** | Each provider declares its env var via `ProviderEntry.env_key` (`DEEPSEEK_API_KEY`, `OPENAI_API_KEY`). `local` provider requires none. `ZAGENT_DEBUG=1` enables debug logs to `.zagent/logs/`. |
| **Sessions** | `.zagent/sessions/<timestamp>.jsonl`. Header JSONL line includes `id`, `model`, `provider`. REPL: `/new`, `/list`, `/session <index\|id>`, `/name <name>`, `/model <name>`, `/exit`, `/quit`. |
| **Command templates** | `.zagent/commands/*.md` with `${args}` placeholder for arguments. Built-in `/init` template compiled into binary (multiline string). Filesystem versions override built-ins. |
| **Task confirmation** | System never confirms task completion — agent must call `ask_user`. |
| **bash limits** | Output truncated at 50 KiB per stream. Truncation appends guidance note. **Blocks** destructive commands (format, Remove-Item, rm -rf, diskpart, shutdown, etc.). **Warns** on expensive: `Get-ChildItem -Recurse` without `-Depth N`, `Select-String -Recurse` without `-Path`/`-Filter`, `Get-Content` without `-Head`. |
| **Changelog** | See `CHANGELOG.md`. Unreleased under `## [Unreleased]` with `### Added` / `### Changed` / `### Tests` sections. Each entry references source files and is written in Chinese. |
| **Hooks** | `.zagent/hooks/<event>` scripts (exit code 0 = allow). Events: `session_start`, `session_end`, `user_prompt_submit`, `pre_tool_use` (intercept — non-zero blocks), `post_tool_use`. |
| **Permission system** | `config.toml` `[permissions]` table with `mode` (allow/confirm/deny, default confirm) + `allow`/`ask`/`deny` arrays. Rules format: `ToolName(subject)`. Learned table caches user decisions in-memory. `--trust` flag bypasses all checks. |
| **Path unification** | All paths from `config.findZagentRoot()` walk-up (finds `.zagent/config.toml` upward from CWD). Config, sessions, skills, AGENTS.md all use this root. Tool `execute()` uses `root_dir.resolvePath()` (global anchor in `src/tool/root_dir.zig`), not App context. `root_dir.init(project_root)` called in `App.init()`. |
| **AGENTS.md loading** | Both `AGENTS.md` and `CLAUDE.md` filenames are checked in `project_root` (CLAUDE.md for Cursor compatibility). First found wins. Content injected as `<project_context>` in system prompt. |
| **Single-exe bootstrap** | Statically linked single exe. AGENTS.md content and `/init` template compiled into binary (multiline string, not `@embedFile`). Filesystem versions (`./AGENTS.md`, `.zagent/commands/*.md`) override built-in ones on startup. |
| **Skills** | `.zagent/skills/<name>/SKILL.md`. Frontmatter uses LF-normalized parsing (`name`, `description` fields). Use `openDir(path, .{ .iterate = true })` for scanning. `dedupLastWins()` ensures last skill slug wins (filesystem overrides built-in). |
| **Dangling pointer** | After `normalizeLF()`, buffer slices become invalid after `defer allocator.free(normalized)`. Always `dupe` name/description/fields from frontmatter before the buffer is freed. Then `realloc(buf, actual_len)` before returning (see `skill.zig:normalizeLF`). |
| **Tool returns** | Always allocated with `allocPrint`/`alloc`. Never static string literals — `testing.allocator.free()` on a static literal segfaults. Use `catch "Error: OOM"` fallback (shorter than `catch "Error: internal (OOM)"`). |
| **Io.Writer API** | Only `print(fmt_with_{}, args)`, `writeAll(bytes)`, `writeByte(byte)`. No `writeByteNTimes` — use `for` loop. `print` format string must contain `{}` (even if args empty: `print("text\n", .{})`). |
| **Agent mode** | `--agent <file>` or `--agent-content <inline>` flags set `agent_mode=true`. When active, assistant content is wrapped as `[ZAGENT_RESULT]...content...[ZAGENT_END]`. Optional `--result-marker=<name>` adds scoped markers: `[ZAGENT_RESULT:<name>]...[ZAGENT_END:<name>]`. |
| **Compaction** | Auto-triggered when estimated tokens exceed 85% of `context_limit - max_tokens`. BM25 retrieval selects important messages to keep; discarded messages summarized by LLM. Summary injected as system message with `[压缩摘要]` prefix. Max 10 tool rounds per turn. |
| **Retry** | API calls retry up to 3 times with exponential backoff (1s, 2s, 4s) on non-`Interrupted`/non-`ApiError` errors. |
