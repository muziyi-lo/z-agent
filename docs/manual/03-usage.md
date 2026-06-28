# Usage

## CLI Flags

| Flag | Description |
|------|-------------|
| `-h`, `--help` | Show help message |
| `-l`, `--list` | List sessions |
| `-s`, `--session <index\|id>` | Resume a specific session |
| `--agent <path>` | Load agent definition from file, inject as AGENTS.md context |
| `--agent-content <inline>` | Same as `--agent` but inline string instead of file |
| `--result-marker=<name>` | Wrap agent output in `[ZAGENT_RESULT:<name>]...[ZAGENT_END:<name>]` |
| `--trust` | Skip all permission confirmations |

If `<prompt>` is provided, runs in single-turn mode. Otherwise starts interactive REPL.

## REPL Commands

### Built-in

| Command | Description |
|---------|-------------|
| `/help` | Show all commands |
| `/exit`, `/quit` | Exit REPL |
| `/new` | Create a new session |
| `/list` | List all sessions |
| `/session <n>` | Switch to session by index or ID |
| `/name <name>` | Rename current session |
| `/model <name>` | Switch model at runtime (bare `/model` lists available) |

### Templates

Templates are embedded instructions that expand into step-by-step guidance for the agent:

| Command | Description |
|---------|-------------|
| `/init <hint>` | Analyze project and write AGENTS.md |
| `/learn <topic>` | Review conversation and save knowledge to memory |
| `/recall <query>` | Search existing memory entries |
| `/summary <focus>` | Summarize session discussions and decisions |

Templates live in `.zagent/commands/*.md` and can be customized per-project.

## Examples

```bash
# Single-turn
z-agent "list all .zig files"

# Pipe input
echo "count lines" | z-agent

# Resume session #2
z-agent -s 2

# Sub-agent
z-agent --agent agent.md "review src/main.zig"

# Interactive
z-agent
```

```bash
# Inside REPL:
>>> /model openai/gpt-4o
>>> /list
>>> /session 2
```
