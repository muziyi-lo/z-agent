# Sub-Agents

z-agent supports recursive delegation: the main session spawns child z-agent processes via the `task` tool or `--agent` CLI flag.

## task Tool

```json
{
  "name": "task",
  "arguments": {
    "agent": "explore",
    "task": "Find all provider registration points"
  }
}
```

Launches `z-agent --agent-content <agent> <task>` as a child process. The child's output is wrapped in result markers and returned as the tool result.

## CLI Flags

```bash
# Agent definition from file
z-agent --agent path/to/agent.md "review the code"

# Inline agent definition
z-agent --agent-content "You are a code reviewer." "review src/main.zig"

# Scoped result markers
z-agent --agent agent.md --result-marker=review "audit security"
```

## --agent Behavior

The file content (or inline string) is injected as AGENTS.md context into the child process. The child's system prompt includes it as `<project_context>`. The parent's existing AGENTS.md is kept — the agent file only fills in if none exists.

## Result Markers

In agent mode, the final response is wrapped:

```
[ZAGENT_RESULT]...content...[ZAGENT_END]
```

With `--result-marker=<name>`:

```
[ZAGENT_RESULT:review]...content...[ZAGENT_END:review]
```

## Available Agents

The `task` tool has a built-in `explore` agent for file search and codebase analysis:

```zig
task(agent="explore", task="Find all provider registration points")
```

Additional agents can be defined in skills. Install via `.zagent/skills/<name>/agents/<name>.md`.
