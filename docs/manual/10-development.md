# Development

## Build

```bash
# Debug build
zig build

# Release build
zig build -Doptimize=ReleaseSafe

# Cross-compile for Windows
zig build -Dtarget=x86_64-windows
```

## Test

```bash
# Unit tests (no subprocess)
zig build test

# Integration tests (real I/O subprocess)
zig build test-real

# Quick test (alternative)
zig test src/test.zig --cache-dir .zig-cache
```

## Project Structure

```
src/
├── main.zig                 # Entry point
├── App.zig                  # App lifecycle, REPL, agent loop
├── Cli.zig                  # CLI flags, help, session listing
├── ansi.zig                 # ANSI color support
├── signal.zig               # Ctrl+C / ESC interrupt handling
├── config.zig               # TOML config loading
├── toml.zig                 # Lightweight TOML parser
├── types.zig                # Shared types
├── system.zig               # System prompt builder
├── session.zig              # Session manager
├── skill.zig                # Skill loading
├── Command.zig              # REPL command registry
├── compact.zig              # Context compaction
├── permission.zig           # Permission engine
├── hook.zig                 # Lifecycle hooks
├── provider.zig             # Provider registry
├── provider/
│   ├── openai_compat.zig    # OpenAI-compatible provider
│   ├── registry.zig         # Provider/ModelSpec registry
│   └── common.zig           # Shared provider utilities
├── tool/
│   ├── registry.zig         # Tool handler registry
│   ├── read.zig / write.zig / edit.zig
│   ├── bash.zig / glob.zig / grep.zig
│   ├── ask_user.zig / skill.zig / task.zig
│   └── memory.zig           # Memory tool
├── sse.zig                  # SSE streaming parser
├── retrieval.zig            # BM25 search
├── json.zig                 # JSON pretty-print
├── token.zig                # Token estimation
├── root_dir.zig             # Global project root
├── console.zig              # Console I/O handling
├── search.zig               # File search utility
└── truncate.zig             # Output truncation
```

## Dependencies

Zero external dependencies. Pure Zig standard library.

## Key Design Decisions

- **Single binary**: everything compiled in, no runtime files required
- **curl for HTTP**: avoids std.http.Client which has Windows AFD driver issues
- **Arena allocator**: process-level arena, freed on exit — no per-request cleanup needed
- **SSE streaming**: line-by-line parsing with interrupt support
- **TOML config**: human-readable, supports multi-provider and nested sections
