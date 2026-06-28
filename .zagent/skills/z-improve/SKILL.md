---
name: z-improve
slug: z-improve
version: 1.2.0
description: Manage memory system: save knowledge, recall memories, summarize sessions
---

# z-improve

## When to use

- User corrects a mistake
- A recurring pitfall or pattern is identified
- A design decision is confirmed
- Before starting a new task (search relevant memories)
- At session end (generate summary)

## Triggers

### Auto-save

When you notice something worth remembering, save it directly:
`memory(command="add", content="<distilled point>", source="auto")`
No need to ask the user for confirmation.

### Auto-recall

At the start of each new task, automatically search `.zagent/memory/` for relevant entries.
If results are found, inject them into the system prompt as reference.

### User trigger

| User input | Your action |
|------------|-------------|
| `/learn <content>` | Review conversation, extract key points, save via memory tool |
| `/recall <keyword>` | Search memory and display results |
| `/summary` | Generate structured session summary |
| "remember this", "note that" | Distill and save via memory tool |

## Memory format

Each memory is a separate `.md` file in `.zagent/memory/`:

```
.zagent/memory/MEM-YYYYMMDD-NNN.md

## MEM-20260628-001
**source**: auto

CWD leak: session.zig used Io.Dir.cwd() to create dir but actual write uses project_root
```

**Rules:**
- source field marks origin (`/learn` command or `auto`)
- Concise, one line per point
- Reference specific file paths (e.g., `src/session.zig:163`)
- No speculation, no emotional language

## Session summary

At session end, suggest `/summary` to the user.
Generate a structured summary from session data if they confirm.

## Required permissions

| Permission | Purpose |
|------------|---------|
| `read` | Read `.zagent/memory/` files |
| `write` | Write via memory tool |
| `grep` | Search memory entries |
