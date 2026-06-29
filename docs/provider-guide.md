# 模型连接配置指南

## 配置位置

`.zagent/config.toml`（首次运行自动生成）

## 快速开始

```toml
default_model = "deepseek/deepseek-v4-flash"
max_tokens = 4096

[[providers]]
name = "deepseek"
kind = "openai"
base_url = "https://api.deepseek.com"
models = ["deepseek-v4-flash"]
default = "deepseek-v4-flash"
api_key_env = "DEEPSEEK_API_KEY"
context_limit = 1048576
```

## Provider 字段说明

| 字段 | 必填 | 说明 |
|------|------|------|
| `name` | 是 | 标识名，模型引用用 `name/model` |
| `kind` | 是 | 协议类型，当前仅 `openai` |
| `base_url` | 是 | API 端点 |
| `models` | 是 | 可用模型列表 |
| `default` | 否 | 默认模型（从 models 列表中选） |
| `api_key_env` | 否 | 环境变量名，如 `DEEPSEEK_API_KEY` |
| `api_key` | 否 | 内联 Key（仅本地测试，不安全） |
| `context_limit` | 否 | 上下文窗口大小 |
| `vision` | 否 | 是否支持图片输入 |
| `effort` | 否 | reasoning 力度：low / medium / high |

## API Key 解析顺序

```
内联 api_key（config.toml）> .zagent/.env > 环境变量
```

**推荐做法** — 在 `.zagent/.env` 中写 Key（记得加 `.gitignore`）：

```env
DEEPSEEK_API_KEY=sk-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
OPENAI_API_KEY=sk-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

## 多 Provider 示例

```toml
[[providers]]
name = "deepseek"
kind = "openai"
base_url = "https://api.deepseek.com"
models = ["deepseek-v4-flash", "deepseek-v4-pro"]
default = "deepseek-v4-flash"
api_key_env = "DEEPSEEK_API_KEY"
context_limit = 1048576

[[providers]]
name = "openai"
kind = "openai"
base_url = "https://api.openai.com"
models = ["gpt-4o"]
api_key_env = "OPENAI_API_KEY"
context_limit = 128000

[[providers]]
name = "local"
kind = "openai"
base_url = "http://localhost:11434/v1"
models = ["llama3.1", "qwen2.5"]
default = "llama3.1"
context_limit = 8192
```

## 模型切换命令

在 REPL 中用 `/model` 切换：

```
/model deepseek/deepseek-v4-flash   # 指定 provider + 模型
/model gpt-4o                        # 仅改模型名（保持当前 provider）
```

## 供应商自动检测

`kind = "openai"` 时根据 `base_url` 主机名自动调整请求格式：

| 主机 | 自动行为 |
|------|----------|
| `api.deepseek.com` | 启用 DeepSeek thinking（`reasoning_content` 字段） |
| `api.minimaxi.com` | 启用 MiniMax thinking（binary thinking） |
| 其他 | 标准 reasoning_effort |

## 代理配置

```toml
[proxy]
mode = "auto"       # auto | env | custom | off
url = ""            # custom 模式时填写：http://127.0.0.1:7890
```

| mode | 行为 |
|------|------|
| `auto` | 自动检测系统代理 + 环境变量（默认） |
| `env` | 只读 `HTTP_PROXY` / `HTTPS_PROXY` |
| `custom` | 使用配置的 `url` 字段 |
| `off` | 直连，忽略所有代理 |

## 重试机制

API 调用自动重试：
- 可重试：408 / 429 / 5xx / 连接重置 / 超时
- 不可重试：400 / 401 / 403 / 404 / 422
- 策略：指数退避 + 随机抖动，最多 4 次
- 首次失败会打印 `[重试第 N 次]` 提示

## 权限配置

```toml
[permissions]
mode = "confirm"           # allow | confirm | deny
allow = ["Read", "Glob"]   # 免确认
ask   = ["Bash(go test *)"] # 需确认
deny  = ["Bash(rm -rf *)"]  # 永远阻止
```

规则格式：`ToolName(subject_glob)` 或 `ToolName`。
