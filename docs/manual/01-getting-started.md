# Getting Started

## Installation

z-agent is a single static binary. No runtime dependencies.

### Build from source

```bash
zig build
cp zig-out/bin/z-agent /usr/local/bin/  # or any $PATH directory
```

### Windows

```bash
zig build
copy zig-out\bin\z-agent.exe C:\path\to\deploy
```

## First Run

```bash
z-agent
```

On first run, z-agent creates `.zagent/config.toml` with default settings:

- Provider: DeepSeek (api.deepseek.com)
- Model: deepseek-v4-flash
- Includes OpenAI and local (Ollama) stubs

Set your API key:

```bash
# Option 1: Environment variable
set DEEPSEEK_API_KEY=sk-your-key-here

# Option 2: .env file (project-scoped, gitignored)
echo DEEPSEEK_API_KEY=sk-your-key-here > .zagent/.env
```

## Quick Start

```bash
# Interactive mode
z-agent

# Ask a question
z-agent "what files are in the current directory?"

# Switch model in REPL
# (start REPL then: /model openai/gpt-4o)
```
