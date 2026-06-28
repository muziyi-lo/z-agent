---
description: Review the current conversation and save notable knowledge to memory
args: (optional) focus area
---

Review the current conversation (both sent and received messages) and extract knowledge worth keeping long-term.

Focus on:
- Mistakes the user corrected
- Architecture design decisions made
- Recurring pitfalls or patterns
- Project conventions and rules

Save to memory using: memory(command="add", content="<distilled content>", source="auto")
Check for duplicates first with memory(command="recall", query="<keyword>") before adding.

${args}
