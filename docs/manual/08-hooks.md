# Hooks

Lifecycle hooks are executable scripts triggered at specific events. Hooks live at `.zagent/hooks/<event>`.

## Events

| Event | Trigger | Intercept? |
|-------|---------|------------|
| `session_start` | REPL or single-turn starts | No |
| `session_end` | REPL or single-turn ends | No |
| `user_prompt_submit` | User submits a prompt | No |
| `pre_tool_use` | Before a modify tool executes | **Yes** — non-zero exit blocks the call |
| `post_tool_use` | After a tool completes | No |

## Intercept Behavior

`pre_tool_use` is the only intercept event. The script receives a JSON payload on stdin:

```json
{
  "tool": "bash",
  "args": {"command": "rm -rf /"}
}
```

- **Exit 0**: tool call proceeds
- **Exit non-zero**: tool call is rejected, user sees "hook blocked"

## Payload Handling

Events receive a JSON payload via stdin. For `user_prompt_submit`:

```json
{"text": "user's message"}
```

For `post_tool_use`:

```json
{"tool": "bash", "duration_ms": 320}
```

## Shell

On Windows hooks run via `powershell.exe -Command "& 'path\to\hook'"`. On POSIX via `/bin/sh -c '/path/to/hook'`.
