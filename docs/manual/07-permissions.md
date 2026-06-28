# Permissions

The permission system controls which tools the LLM can use and on which files/commands.

## Configuration

```toml
[permissions]
mode = "confirm"           # allow | confirm | deny

allow = [
  "Read",                  # allow all reads
  "Glob",
  "Grep",
  "Bash(echo *)",          # allow only safe echos
]

ask = [
  "Bash",                  # ask before any bash not in allow/deny
  "Write",
]

deny = [
  "Bash(rm -rf *)",        # block destructive commands
]
```

## Rule Format

```
ToolName(subject)
```

- `ToolName` — matches any call to that tool
- `(subject)` — optional, restricts to specific path/command (glob-matched)
- No parentheses — matches all calls to that tool

### Rule Evaluation Order

1. `allow` rules matched first — match → allowed automatically
2. `ask` rules matched next — match → prompt user for confirmation
3. `deny` rules matched last — match → blocked immediately
4. No match → falls back to `mode`

## In-Memory Learning Table

When a user confirms or denies a tool call, the decision is cached in memory for the session duration. Repeated calls to the same tool with the same subject will use the cached decision.

## --trust Flag

`--trust` bypasses all permission checks entirely. Intended for automated/agent use.
