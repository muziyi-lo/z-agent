# z-agent

Zig LLM Agent Runtime — A minimal, embeddable coding agent.

## Platform

Developed on **Windows only**. Not tested on Linux or macOS. Patches welcome.

## Author's Note

This is a humble CLI agent, born from a simple thought: *could someone who doesn't know how to code build a project using just AI?* So I set out to use an AI agent to build an AI agent — using OpenCode + DeepSeek v4, written in a language I had zero prior experience with: **Zig**. It took about a week. It's rough, the UX is far from polished, but it runs. And the compiled binary is only 3 MB.

— *A user who can't code, but wants to.*

## Build

```bash
zig build                          # debug
zig build -Doptimize=ReleaseFast   # production binary
zig build test                     # unit tests
zig build test-real                # real IO integration tests
```

## Usage

```bash
z-agent                              # interactive REPL
z-agent "write a unit test"          # single-turn mode
z-agent --model deepseek/deepseek-v4-flash "summarize this file"
z-agent --agent agent.md             # sub-agent mode
z-agent --trust "deploy code"        # skip permission confirmations
z-agent -s <session-id>              # resume session
z-agent --help                       # full usage
```

### REPL Commands

| Command | Description |
|---------|-------------|
| `/new` | Start a new session |
| `/list` | List all sessions |
| `/session <index\|id>` | Switch to a session |
| `/name <name>` | Name current session |
| `/model <provider/model>` | Switch model |
| `/exit` or `/quit` | Exit |

## Configuration

Auto-creates `.zagent/config.toml` on first run with sensible defaults. Fields:

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `default_model` | string | `deepseek/deepseek-v4-flash` | Provider/model pair |
| `max_tokens` | int | `4096` | Max output tokens |
| `[[providers]]` | array | — | Provider entries (name, kind, base_url, models, api_key_env, context_limit, max_tokens, timeouts) |
| `[permissions]` | table | `mode = "confirm"` | allow/confirm/deny per tool with rule syntax |
| `[proxy]` | table | `mode = "auto"` | HTTP proxy configuration |

### Supported Providers

| Provider | Kind | Env Variable | Notes |
|----------|------|-------------|-------|
| DeepSeek | openai | `DEEPSEEK_API_KEY` | Default, 1M context |
| Ollama | openai | — | Local, no API key needed |

## Features

- File tools: **read** (offset/limit, directory browsing, image detection), **write** (atomic, 512KB max, parent dir auto-create), **edit** (fuzzy matching 3 layers, atomic write, diff preview)
- Shell execution with dangerous-command protection and expense warnings
- **Interactive picker**: arrow-key selection for permission confirmations (↑↓ navigate, Enter confirm, Esc cancel)
- Configurable permission system (allow/confirm/deny per tool, glob-based path matching)
- Memory system: save/recall knowledge across sessions with pattern-key dedup and weighted ranking
- **Skill system**: load specialized instructions from `.zagent/skills/<name>/SKILL.md`
- **Sub-agent delegation**: `--agent` / `--agent-prompt` for task-specific agents, subprocess isolation
- Lifecycle hooks: `.zagent/hooks/<event>` scripts (session start/end, prompt submit, tool use)
- Session management with JSONL persistence, context compaction (BM25 + LLM summary)
- Agent mode: `--agent`, `--readonly`, `--trust`, `--result-marker=<name>`
- Model switching at runtime: `/model <provider/model>`
- `.env` file support for API keys (ignored by git)

## Project Status

**v0.3.0** — Active development. 261+ tests, single statically-linked ~3 MB executable.
