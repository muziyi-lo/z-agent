# z-agent

Zig LLM Agent Runtime — A minimal, embeddable coding agent.

## Platform

Developed on **Windows only**. Not tested on Linux or macOS. Patches welcome.

## Author's Note

This is a humble CLI agent, born from a simple thought: *could someone who doesn't know how to code build a project using just AI?* So I set out to use an AI agent to build an AI agent — using OpenCode + DeepSeek v4, written in a language I had zero prior experience with: **Zig**. It took about a week. It's rough, the UX is far from polished, but it runs. And the compiled binary is only 3 MB.

To be honest, I thought it was already usable — but after actually using it, I found way more bugs than I expected. The truth is, vibe coding gets you to "it compiles" fast, but the gap between "compiles" and "works reliably" is bigger than I imagined. There's still a lot to fix.

— *A user who can't code, but wants to.*

## Build

```bash
zig build
zig build test        # unit tests
zig build test-real   # real IO integration tests
```

## Usage

```bash
z-agent                         # interactive REPL
z-agent "write a unit test"     # single-turn mode
z-agent --trust "deploy code"   # skip permission confirmations
z-agent --help                  # full usage
```

## Configuration

Auto-creates `.zagent/config.toml` on first run. Supported providers:
- `deepseek` (default, env: `DEEPSEEK_API_KEY`)
- `openai` (env: `OPENAI_API_KEY`)
- `local` (Ollama, no key required)

## Features

- File tools: read, write, edit, glob, grep
- Shell execution with dangerous-command protection
- Configurable permission system (allow/confirm/deny per tool)
- Memory system: save/recall knowledge across sessions
- Lifecycle hooks: `.zagent/hooks/pre_tool_use.ps1`, etc.
- Session management with context compaction
- Sub-agent delegation

## Project Status

Active development. 143+ tests, single statically-linked 3 MB executable.