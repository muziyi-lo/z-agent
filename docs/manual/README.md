# z-agent Manual

z-agent is a Zig LLM Agent Runtime — a single-binary CLI tool that connects LLMs to your filesystem and shell.

## Table of Contents

| Section | Description |
|---------|-------------|
| [01 — Getting Started](01-getting-started.md) | Installation, first run, quick start |
| [02 — Configuration](02-configuration.md) | TOML config, providers, models, proxy |
| [03 — Usage](03-usage.md) | REPL commands, single-turn mode, flags |
| [04 — Tools](04-tools.md) | Available tools and their usage |
| [05 — Sub-Agents](05-sub-agents.md) | Task delegation, agent system |
| [06 — Sessions](06-sessions.md) | Session create, list, switch, continue |
| [07 — Permissions](07-permissions.md) | Allow/confirm/deny rules, --trust |
| [08 — Hooks](08-hooks.md) | Lifecycle hooks and events |
| [09 — Memory](09-memory.md) | Memory tool, learn/recall/summary |
| [10 — Development](10-development.md) | Build, test, project structure |

## Quick Reference

```bash
# Start interactive REPL
z-agent

# Single-turn prompt
z-agent "list all .zig files"

# Resume session by index
z-agent -s 1

# List sessions
z-agent -l

# Skip permissions
z-agent --trust
```
