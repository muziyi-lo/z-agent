# Configuration

Configuration lives in `.zagent/config.toml` (auto-created on first run, located by walking up from CWD).

## Default Model

```toml
default_model = "deepseek/deepseek-v4-flash"
max_tokens = 4096
```

Format: `provider_name/model_name`. If `default_model` is empty, the first provider's first model is used.

## Providers

Multiple providers can be defined under `[[providers]]`:

```toml
[[providers]]
name = "deepseek"
kind = "openai"
base_url = "https://api.deepseek.com"
models = ["deepseek-v4-flash", "deepseek-v4-pro"]
default_model = "deepseek-v4-flash"
api_key_env = "DEEPSEEK_API_KEY"
context_limit = 1048576
max_tokens = 8192
vision = true

[[providers]]
name = "local"
kind = "openai"
base_url = "http://localhost:11434/v1"
models = ["llama3.1", "qwen2.5"]
context_limit = 8192
```

### Provider fields

| Field | Required | Description |
|-------|----------|-------------|
| `name` | yes | Unique identifier used in `provider/model` references |
| `kind` | no | Provider implementation (`"openai"` is the only supported kind) |
| `base_url` | yes | API endpoint |
| `models` | yes | List of available models |
| `default_model` | no | Default model for this provider |
| `api_key_env` | no | Environment variable name holding the API key |
| `api_key` | no | Inline API key (less secure, prefer `.env` or env vars) |
| `context_limit` | no | Context window size in tokens |
| `max_tokens` | no | Max output tokens limit |
| `vision` | no | Whether the provider supports vision (unused currently) |
| `effort` | no | Reasoning effort level (unused currently) |

### Vendor auto-detection

The `base_url` hostname is used to auto-detect wire protocol:

| Host | Vendor | Features |
|------|--------|----------|
| `api.deepseek.com` | deepseek | `reasoning_content` field, thinking mode |
| `api.minimaxi.com` | minimax | `<think>` block parsing |
| anything else | standard | Standard OpenAI-compatible |

## API Key Resolution

Priority: **inline > .env file > environment variable**

```toml
# config.toml
[[providers]]
name = "my-provider"
api_key_env = "MY_API_KEY"
api_key = "sk-..."        # inline (highest priority)
```

```bash
# .zagent/.env (second priority)
MY_API_KEY=sk-...
```

```bash
# Environment variable (third priority)
set MY_API_KEY=sk-...
```

## Proxy

```toml
[proxy]
mode = "auto"              # auto | env | custom | off
url = "http://127.0.0.1:7890"  # required for custom mode
no_proxy = ["localhost", "127.0.0.1"]
```

| Mode | Behavior |
|------|----------|
| `auto` | curl reads `HTTP_PROXY`/`HTTPS_PROXY` env vars |
| `env` | Same as auto |
| `custom` | Uses `url` field as proxy |
| `off` | `--noproxy *` disables all proxy |

## Permissions

See [Permissions](07-permissions.md).
