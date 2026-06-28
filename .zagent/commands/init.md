---
description: Analyze project and write a concise AGENTS.md
args: (optional extra instructions)
---
Write AGENTS.md following these rules strictly:

- Every line must answer: "Would an agent miss this without help?" If no, delete it.
- Use markdown sections (## Constraint, ## Build, etc.) with tables and bullet lists — structured but concise.
- NO directory trees, file tables, or file-name catalogs. Structure section: a single sentence naming ONLY registration points (where agents add tools/providers).
- Only project-specific rules. Skip generic language advice (naming, error handling, imports, memory patterns).
- Build & test: exact commands copied from build files, no explanations.
- If an existing AGENTS.md exists, read it first. Improve it, don't replace blindly.
- If you can't verify a constraint from the codebase, omit it.
${args}
