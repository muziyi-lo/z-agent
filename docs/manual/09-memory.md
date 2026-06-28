# Memory

The memory system lets the LLM persist structured learnings across sessions. Data is stored in a single `.zagent/memory.md` file.

## Memory Tool

```json
{
  "name": "memory",
  "arguments": {
    "command": "add",
    "content": "Zig 0.16.0 ArrayList uses Managed/Unmanaged split",
    "source": "用户",
    "patternKey": "zig-arraylist-managed-split",
    "title": "ArrayList Managed vs Unmanaged"
  }
}
```

### Commands

| Command | Required Args | Description |
|---------|--------------|-------------|
| `add` | `command` + `content` | Save a new learning. Optional: `source` (default `自动`), `pattern-key`, `title` |
| `recall` | `command` + `query` | Search existing learnings by keyword |
| `delete` | `command` + `id` | Remove a learning by ID (e.g. `MEM-20260628-001`) |

## Admission Gate

Entries MUST satisfy at least one of four anchors, otherwise rejected:

| Anchor | Description |
|--------|-------------|
| `source` | Origin label (`conversation`, `error`, `user_feedback`, `analysis`, `learning`) |
| `patternKey` | Normalized reusable identifier |
| `keywords` | Search terms in the entry |
| File path | Related file paths |

## Deduplication

If a new entry has the same `patternKey` as an existing entry, `Recurrence-Count` is incremented — no duplicate created.

## Recall Scoring

Results are scored and sorted (first match wins, no stacking):

| Match Type | Weight |
|------------|--------|
| `patternKey` exact | 0.8 |
| `patternKey` substring | 0.6 |
| `source` match | 0.4 |
| Body substring | 0.2 |
| CJK bigram overlap | +0.1 × (hits / total bigrams) bonus |

## Template Commands

```bash
/learn <topic>       # Template: guides agent to extract and save knowledge
/recall <query>      # Template: guides agent to search memory
/summary <focus>    # Template: guides agent to summarize session
```

These expand into step-by-step instructions for the agent to use the `memory` tool correctly.
