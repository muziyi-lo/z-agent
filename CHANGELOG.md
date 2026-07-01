# Changelog

## [0.3.0] - 2026-07-01

### Added
- `src/picker.zig` — 交互式方向键选择器：↑↓ 导航、Enter 确认、Esc 取消、VT100 重绘（`src/picker.zig`）
- `src/tool/edit.zig` — 模糊匹配 3 层（exact/line_trimmed/whitespace_normalized）、100KB 大小限制、原子写入（.tmp + rename）、renderResult diff 展示、MatchRange 结构体（`src/tool/edit.zig`）
- `src/tool/write.zig` — 内容大小上限 MAX_WRITE=512KB、原子写入（.tmp + rename）、renderResult 彩色展示、content_preview 按 Unicode 码点截断（`src/tool/write.zig`）
- `docs/design/edit-tool.md` — edit_file 设计文档（`src/tool/edit.zig`）
- `docs/design/write-tool.md` — write_file 设计文档（`src/tool/write.zig`）
- `projects/z-agent/AGENTS.md` — Build & test 区新增构建约定（优化选项注释、Binary freshness 规则）（`projects/z-agent/AGENTS.md`）

### Changed
- `src/agent.zig` — 权限确认 `[y/N]` 改为交互式 picker；`printToolCall` 新增 skill/ask_user 专用分支隐藏 JSON 源码；删除废弃 `readlineConfirm`（`src/agent.zig`）
- `src/App.zig` — 模型切换确认 `[y/N]` 改为交互式 picker；删除废弃 `readlineConfirm`（`src/App.zig`）
- `src/ansi.zig` — `init()` 增加输入句柄 `ENABLE_VIRTUAL_TERMINAL_INPUT` 支持方向键输入（`src/ansi.zig`）
- `src/tool/bash.zig` — 解禁 `Remove-Item`，允许 AI 删除文件（`src/tool/bash.zig`）
- `src/tool/skill.zig` — `renderResult` 仅显示技能名称，不再输出 SKILL.md 全文（`src/tool/skill.zig`）
- `src/tool/write.zig` — 重构设计文档格式对齐 read/edit 标准（`src/tool/write.zig`、`docs/design/write-tool.md`）
- `src/tool/read.zig` — 修复 `formatSize` 和 `generateNote` 测试双 free（var 复用 + multi-defer）（`src/tool/read.zig`）
- `docs/` — 删除 10 个过期计划文档（`docs/*plan*`、`docs/development-plan.md`）

### Tests
- `src/picker.zig` — 新增 2 个测试：Key 枚举映射、空选项错误路径（`src/picker.zig`）
- `src/tool/edit.zig` — 新增 13 个测试：模糊匹配 3 层路径、大小超限、原子写入、多候选报错（`src/tool/edit.zig`）
- `src/tool/write.zig` — 新增 3 个测试：内容大小超限、码点预览、原子写入清理验证（`src/tool/write.zig`）

## [Unreleased]

### Changed
- `src/system.zig` — 移除 `Available tools` 段（工具描述由 API `tools` 参数唯一提供）；PowerShell 开销警告移入 `<env>` 块（`src/system.zig`）
- `src/agent.zig` — 移除 `read_file` 用户显示硬编码分支（由 `read.zig` 的 `renderResult` 替代）（`src/agent.zig`）
- `docs/design/agent-system.md` — 同步 system prompt 组装层数（移除了第 9 层工具列表）和一致性检查项（`docs/design/agent-system.md`）
- `src/system.zig` — 新增 `ModelFamily` 枚举和 `detectModelFamily()` 函数，支持按模型族输出定向优化的系统提示；DeepSeek V4 分支：1M 上下文窗口引导、中英双语指令、推理阶段利用、工具使用偏好（`src/system.zig`）
- `src/system.zig` — 环境块 `<env>` 扩充：新增 `Workspace root folder` 和 `Is directory a git repo` 字段，对齐 OpenCode 的环境上下文设计（`src/system.zig`）
- `src/system.zig` — 新增 4 个测试：detectModelFamily 两条路径、DeepSeek 特有引导内容、generic 不包含 DeepSeek 引导; 更新 8 个现有测试适配新签名（`src/system.zig`）
- `src/system.zig` — 新增 3 个通用行为段落：`# Tone and style`（简洁/直接/markdown/无emoji）、`# Security`（不猜测URL、不暴露密钥）、`# Task workflow`（先读后改、最小变更优先、改后验证、不主动提交）；新增 3 个测试验证各段落存在（`src/system.zig`）
- `src/Command.zig` — 重写 `/init` 模板：从 18 行纯规则列表扩展为 ~50 行三章结构（调研方法论→提取指南→写入规则），新增排除目录指引（zig-cache/node_modules 等）和交互策略（最多问一轮）；新增 1 个测试验证各章节关键词（`src/Command.zig`）

### Changed
- `src/provider/retry.zig` — 新增重试策略模块：ErrorKind 分类（auth/rate-limit/context/server/network/sse）、isRetryable 决策表、parseRetryAfterMs 解析、全抖动退避算法、friendlyMessage 友好提示；16 测试（`src/provider/retry.zig`）
- `src/agent.zig` — `callWithRetry` 集成 retry.zig 分类逻辑：先 classify 再 isRetryable 决定是否重试，不可重试时输出 friendlyMessage；新增 interruptibleSleep 轮询中断（`src/agent.zig`）
- `src/provider/openai_compat.zig` — `checkSseExit` 统一返回 ApiError（不再重试 SSE 中途断流）；SSE 错误体捕获用于分类；增加 `retry` 模块引用（`src/provider/openai_compat.zig`）
- `src/provider/common.zig` — `parseResponse` 改用 `parseFromSlice` + `defer` 修复内存泄漏（`src/provider/common.zig`）
- `src/provider/openai_compat.zig` — 所有 `parseFromSliceLeaky` 改为 `parseFromSlice` + `defer`（`src/provider/openai_compat.zig`）
- `src/session/serialize.zig` — `readSessionHeaderFromContent`/`loadEntries` 改用 `parseFromSlice` + `defer`（`src/session/serialize.zig`）
- `src/tool/registry.zig`、`src/tool/task.zig`、`src/tool/skill.zig`、`src/tool/search.zig` — 所有 `parseFromSliceLeaky` 改为 `parseFromSlice` + `defer`（`src/tool/*.zig`）
- `src/ansi.zig` — 重构色彩模块：新增 `shouldColorize()` 函数（四级检测链：NO_COLOR/TERM=dumb/非TTY/Windows VT），`Color` 改用默认值替代运行时初始化，`C` 全局变量保留向后兼容（`src/ansi.zig`）

### Changed
- `src/provider/openai_compat.zig` — `reasoning_content` 处理从 vendor switch 内提升为共享逻辑，Standard 供应商（OpenAI o-series）也可正确显示推理过程（`src/provider/openai_compat.zig`）
- `src/config.zig` — 默认模板精简：仅保留 deepseek（已测试），openai/local 供应商示例改为单条注释模板（`src/config.zig`）

### Removed
- `src/provider/openai_compat.zig` — 移除 `minimax` 供应商特化代码（无 API 无测试），`Vendor` 缩减为 `deepseek`/`standard` 二值；删除 `<think>` 标签解析、`thinking: adaptive` 请求字段、相关测试共 ~90 行

### Added
- `src/stream.zig` — 新增流式输出格式化模块：`formatReasoningHeader()` 推理阶段入口 header、`formatReasoningLine()` 逐行 `│ ` 前缀渲染、`formatContentTransition()` 推理→内容分隔线；颜色/无颜色双路径，通过 `shouldColorize()` 四级检测链自动选择（`src/stream.zig`）

### Changed
- `src/provider/openai_compat.zig` — 推理内容渲染从 `ansi.C.dim` 手动包裹改为调用 `streamfmt.formatReasoningHeader/Line/ContentTransition`，视觉分层提升：dim header + `│` 前缀 + `───` 分隔线；同一推理阶段连续 chunk 合并 header 只输出一次（`src/provider/openai_compat.zig`）

### Tests
- `src/ansi.zig` — 新增 4 个测试：Color 默认值验证、init/supportsColor 兼容性、NO_COLOR/TTY 检测（libc 条件跳过）
- `src/stream.zig` — 新增 5 个测试：header 输出、no-color 降级、单行 prefix、空文本 prefix、分隔线（`src/stream.zig`, `src/test.zig`）

### Added
- `src/tool/task.zig` — task 工具新增 `files` 可选参数：接受文件路径数组，自动读入文件内容并拼接到子 agent 的 task prompt 前（`--- <path> ---\n<content>\n---` 格式）；支持错误标注（文件不存在/二进制/OOM/50KB 截断）不阻塞 task 执行（`src/tool/task.zig`）
- `src/system.zig` — task 工具描述更新：添加 `files` 参数说明和用法提示（`src/system.zig`）
- `src/App.zig` — CLI 新增 `--model` 参数，覆盖 `config.toml` 的 `default_model`，支持在启动时指定 provider/model（`src/App.zig`）
- `src/Cli.zig` — help 文本添加 `--model` 参数说明（`src/Cli.zig`）

### Changed
- `src/tool/task.zig` — `execute()` 参数提取后增加 files 处理块，子进程 argv 改用 `effective_task`（含文件内容时替换原始 task 参数）；父 agent 不再需要先 `read_file` 再 inline 内容，省一轮工具调用和一次上下文重复占用（`src/tool/task.zig`）
- `src/agent.zig` — 工具调用达到 10 轮上限后注入 CRITICAL 提示消息，触发最后一轮纯文本输出并显示告警，替代之前的静默返回（`src/agent.zig`）
- `src/permission.zig` — `Permission` 新增 `readonly` 字段 + `isWriteTool()` 函数；`check()` 中 readonly 模式下写操作直接返回 deny，不进入规则匹配（`src/permission.zig`）
- `src/tool/task.zig` — 子进程 argv 新增 `perm_flag`：默认传 `--readonly`（只读），`trust: true` 时传 `--trust`，解决子进程 confirm 死锁（`src/tool/task.zig`）
- `src/App.zig` — CLI 新增 `--readonly` 参数，设置 `perm.readonly`；子进程模式自动输出只读提示（`src/App.zig`）
- `src/Cli.zig` — help 文本添加 `--readonly` 参数说明（`src/Cli.zig`）
- `src/system.zig` — task 工具描述更新：添加 `trust` 参数说明和 readonly 默认行为（`src/system.zig`）

### Tests
- `src/tool/task.zig` — 新增 2 个测试：空 files 数组不崩溃、不存在文件路径优雅降级（`src/tool/task.zig`）
- `src/permission.zig` — 新增 3 个测试：readonly 模式拒绝写操作、readonly 尊重 trust flag、isWriteTool 工具分类正确（`src/permission.zig`）

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
