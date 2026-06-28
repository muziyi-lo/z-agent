# Sessions

Sessions persist conversation history to `.zagent/sessions/<timestamp_ns>.jsonl`.

## File Format

JSONL — one JSON object per line.

### Session Header (first line)

```json
{
  "type": "session",
  "id": "",
  "timestamp": 1782645366549044400,
  "cwd": "/path/to/project",
  "version": 1,
  "model": "deepseek-v4-flash",
  "provider": "deepseek"
}
```

### Message Lines

```json
{"type":"message","role":"user","content":[{"text":"hello"}]}
{"type":"message","role":"assistant","content":[{"text":"Hi!"}]}
```

### Compaction Lines

```json
{"type":"compaction","summary":"...","first_kept_index":3,"tokens_before":1500}
```

### Model Switching

When `/model` switches provider, a new session header is appended. On restore, the last header wins — the correct model/provider are loaded.

## Commands

```bash
z-agent -l                       # List sessions (CLI)
z-agent -s 2                     # Resume by index
z-agent -s abc123                # Resume by ID prefix
```

```bash
/list                            # List sessions (REPL)
/session 2                       # Switch to session #2
/session abc123                  # Switch to session by ID
/name my-analysis                # Name current session
/new                             # Create fresh session
```

## Listing Format

```
#  session_id           time                 msgs  model
1  abc123               2026-06-28 10:30       7  deepseek-v4-flash
2  def456               2026-06-27 09:15       3  gpt-4o
```

## Context Compaction

When estimated tokens exceed 85% of `(context_limit - max_tokens)`, auto-triggered:

1. BM25 retrieval selects important messages to keep
2. Discarded messages summarized by LLM
3. Summary injected as system message with `[压缩摘要]` prefix
4. Max 10 tool rounds per turn (hard limit in agent loop)
