# P2 — 兼容 Provider 表

## 约束

仅持有 DeepSeek API Key。无法测试其他供应商端点，预置数据表不可行（无法验证 URL 正确性、模型名有效性、定价/速率限制）。

## 修订方案

**不做编译进二进制的数据表**。改为改善 config.toml 默认模板，将已验证的供应商示例以注释形式写入，用户按需取消注释。

### 模板改进

```toml
# z-agent 配置

default_model = "deepseek-v4-flash"
max_tokens = 4096

[[providers]]
name = "deepseek"
kind = "openai"
base_url = "https://api.deepseek.com"
models = ["deepseek-v4-flash", "deepseek-v4-pro"]
default_model = "deepseek-v4-flash"
api_key_env = "DEEPSEEK_API_KEY"
context_limit = 1048576
max_tokens = 393216

# 其他兼容供应商（取消注释并填入 API Key 后可用）：
#
# [[providers]]
# name = "openai"
# kind = "openai"
# base_url = "https://api.openai.com/v1"
# models = ["gpt-4o", "gpt-4-turbo"]
# api_key_env = "OPENAI_API_KEY"
# context_limit = 131072
# max_tokens = 4096
#
# [[providers]]
# name = "ollama"
# kind = "openai"
# base_url = "http://localhost:11434/v1"
# models = ["llama3.1", "qwen2.5"]
# api_key_env = "OLLAMA_API_KEY"
# # 本地部署通常无需 API Key
# context_limit = 131072
# max_tokens = 4096

[permissions]
mode = "confirm"
```

### 改动

| 文件 | 操作 | 行数 |
|------|------|------|
| `src/config.zig` — 默认模板 | 扩展注释示例 | ~15 行 |

### 收益

- 用户打开 config.toml 直接看到配置格式和供应商示例
- 不引入无法测试的硬编码数据
- 保持二进制零膨胀

## 决策

P2 以此方案执行，替代原"预置数据表"。原方案等有多供应商 API 权限后重新评估。
