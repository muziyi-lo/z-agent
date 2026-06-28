# Changelog

## [0.2.0] - 2026-06-28

### Added
- 配置格式从 JSON 迁移至 TOML，支持 `[[providers]]` 多供应商定义、`[permissions]` 三列表规则、`[proxy]` 代理配置（`src/toml.zig`, `src/config.zig`）
- HTTP 重试层：指数退避 + 随机抖动，支持 408/429/5xx 自动重试和连接重置恢复；新增 15+ 测试（`src/provider/retry.zig`）
- 主机自动检测：根据 `base_url` 自动切换 DeepSeek/MiniMax/Standard 协议；支持 reasoning_content / `<think>` 块 / 标准 reasoning_effort（`src/provider/openai_compat.zig`）
- `.env` 凭据存储：项目级 `.zagent/.env`，支持引号值剥离、行内注释截断、空值允许；`ensureDotEnvGitIgnore` 自动创建 `.gitignore`；`warnIfNotOwnerOnly` 非 Windows 权限检查；`loadDotEnv` 提升为 `pub`（`src/config.zig`）
- HTTP 代理支持：`config.toml` 新增可选 `[proxy]` 配置段（mode=auto/env/custom/off），curl 子进程自动注入 `-x`/`--noproxy`；新增 3 个测试（`src/types.zig`, `src/config.zig`, `src/provider/openai_compat.zig`）
- `src/App.zig` — 新增 `dotenv: StringArrayHashMapUnmanaged` 字段，`init()` 中加载 `.env` 并存储；新增 2 个 loadDotEnv 测试
- `src/provider.zig` — `buildProviderEntries` 从 TOML `[[providers]]` 动态生成 `ProviderEntry` 数组；新增 2 个测试
- `src/tool/memory.zig` — 四锚点准入（source/pattern-key/关键词/路径），pattern-key 去重，加权排序召回（exact→0.8/substring→0.6/source→0.4/body→0.2），CJK bigram 加分，依据 ID 删除条目块
- `src/session.zig` — `SessionManager.updateHeader(model, provider)` 方法：更新内存字段 + flush 后在 session 文件尾部追加新 header
- 新增测试 7 个：memory 准入检查/pattern-key 去重/加权排序验证/单文件追加验证 + updateHeader 内存更新/loadEntries 多 header/单 header 兼容
- `src/ansi.zig` — ANSI 色彩模块，Windows VT 处理启用，全局 Color 结构体
- `src/signal.zig` — `isEscPressed()`/`isCancelled()` ESC 打断检测
- 色彩应用 11 处：提示符(青)/[工具](黄)/错误(红)/模型切换(绿)/[思考过程](dim)/[截断](黄)/工具→(绿) 等
- `/list` 会话列表表头加色(粗青)、行加 dim

### Changed
- 合并 `deepseek.zig` + `openai.zig` → 单一 `openai_compat.zig`，删除重复代码约 800 行
- 轻量 TOML 解析器替代 JSON 解析，含 12 个测试用例（`src/toml.zig`）
- 权限规则从 `rules[]` 数组改为 `allow`/`ask`/`deny` 三列表，使用 `ToolName(subject)` 字符串格式；`Permission.check` 保持向后兼容签名（`src/permission.zig`, `src/config.zig`）
- API Key 解析链：内联 > `.env` > 环境变量，5 层防护（注册到 SanitizeKeys / 调试日志 redact / Session 净化 / 模板引导 / 文件权限警告）
- 模型引用改为 `provider/model` 格式（如 `deepseek/deepseek-v4-flash`）
- 所有工具返回类型从 `[]const u8` 改为 `ToolResult` 结构化类型，Handler/Registry 签名同步更新
- `src/config.zig` — 移除 `default_model` 硬编码后备，改为空字符串由 App.zig 从第一个 provider 解析
- `src/App.zig` — 移除 `resolved_api`/`resolved_model`/`resolved_base_url` 硬编码 DeepSeek 后备，合并 `effective_context_limit` 初始化
- `src/provider/registry.zig` — `modelSpecFor` 优先使用 TOML 值覆盖编译期规格；`ProviderEntry` 新增 `kind`/`default_max_tokens`；`findByApi` 先 name 后 kind 回退
- `src/App.zig` — `setModel` 按 `new_api` 查找条目而非 `prov_cfg.kind`；检查内联 `api_key`；`self.api` 改为 `dupe` 修复悬空指针
- `src/config.zig` — `api_keys` 与 `cfg.providers` 数组对齐修复（空 key 也 append）
- `src/App.zig` — handlers 数组从栈上 `&.{...}` 提到模块级 `const`，修复工具调用 unknown tool 崩溃
- `src/provider/openai_compat.zig` — `isCancelled()` 替代 `isInterrupted()`，Windows 上跳过 `child.kill` 避免 INVALID_HANDLE panic

### Tests
- `src/config.zig` — 新增测试 3 个：`getTomlString` 对缺失键返回 null、`parseProviderEntry` 处理缺失字段、含全部字段
- `src/provider/registry.zig` — 新增 7 个 `modelSpecFor` 测试（含 4 条错误路径）；`findByApi` kind 回退测试
- `src/App.zig` — `buildProviderEntries` 动态生成替代硬编码，移除重复分配

### Removed
- `src/provider/deepseek.zig`（功能合并至 openai_compat）
- `src/provider/openai.zig`（功能合并至 openai_compat）
- `src/provider.zig` — `pub const retry = @import("provider/retry.zig")` 死导出（无人引用）

## [0.1.0] - 2026-06-28

### Added
- Initial release: Zig LLM Agent Runtime
- REPL with agent loop, single-turn mode, sub-agent delegation
- 17 tools: read/write/edit/bash/glob/grep/ask_user/skill/task/memory + internal
- DeepSeek, OpenAI, and local (Ollama) provider support
- Session management: create, list, switch, continue, compact
- Permission system: configurable allow/confirm/deny rules, --trust flag
- Memory system: memory tool + /learn /recall /summary + z-improve skill
- Lifecycle hooks: pre/post_tool_use, session_start/end, user_prompt_submit
- Path system: findZagentRoot walk-up with CWD auto-init fallback
- Single-exe bootstrap: AGENTS.md, commands, skills, agents compiled in
- CRLF normalization for Windows, blocklist with startsWith matching
- 143+ unit tests, 8 real-IO integration tests
- 工具元数据导出：每个工具文件导出 `tool_name`/`tool_description`/`tool_params` 常量（`src/tool/read.zig` 等 10 个文件）
- `registry.buildHandler()` 函数从工具类型自动构建 Handler（`src/tool/registry.zig`）

### Changed
- Tool dispatch: hook → permission → execute pipeline
- Error handling: ApiError early return with child_finished guards
- Simplified: lowerCmd shared fn, resolvePath conditional free, indexOfIgnoreCase
- `App.zig` 工具注册改为 `registry.buildHandler(tool_xxx)`，消除硬编码 JSON 字符串（`src/App.zig`）
- `provider/common.zig` 中 `parseResponse` 标为未使用注释

### Fixed
- INVALID_HANDLE panic on Windows (child.wait on exited process)
- isBlocked false positives (-Format flags, -UFormat, dd in date strings)
- .zagent directory CWD leaks (session/logs written to wrong location)
- loadTemplates CRLF frontmatter parsing
- findZagentRoot "." fallback causing relative path crash
- Test JSON construction with unescaped inner quotes

### Removed
- 删除未使用的 `src/provider/retry.zig`（308 行，`callWithRetry` 在 `App.zig` 中实现）
