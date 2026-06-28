# Tools

z-agent exposes filesystem and shell capabilities as LLM-callable tools.

## Available Tools

| Tool | Description |
|------|-------------|
| `read_file` | Read a file; auto-encodes images as base64 for vision models |
| `write_file` | Create or overwrite a file |
| `edit_file` | Edit a file by exact string replacement |
| `bash` | Execute a shell command (PowerShell on Windows) |
| `glob` | Find files matching a glob pattern |
| `grep` | Search for a text pattern in files |
| `ask_user` | Ask the user a question |
| `skill` | Load skill instructions |
| `task` | Delegate to a sub-agent |
| `memory` | Manage learnings (add/recall/delete) |

## Tool Result Format

All tools return structured `ToolResult`:

```json
{
  "success": true,
  "output": "..."
}
```

The `success` boolean lets the LLM immediately know if a call succeeded, without parsing error strings. Errors have `success: false` and descriptive `output`.

## Bash Safety

- **Blocked**: destructive commands (format, rm -rf, diskpart, shutdown)
- **Warned**: expensive ops (recursive glob without `-Depth`, unconstrained `Select-String`)
- **API keys**: auto-redacted from output and debug logs via `SanitizeKeys`
- **CWD**: always set to project root

## Tool Metadata

Each tool module exports three constants:

| Export | Description |
|--------|-------------|
| `tool_name` | Tool identifier used in API calls |
| `tool_description` | Description shown to LLM |
| `tool_params` | JSON Schema for tool arguments |
