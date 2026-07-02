# z-agent 重试改进计划

> 对比 pi-repos、nullclaw 后的改进方案
> 日期：2026-06-30

---

## 定位说明

z-agent 是 CLI coding agent，用户主动选择 provider。**不实施自动故障切换**——用户选 DeepSeek 就是 DeepSeek，不会悄无声息切到其他 provider。

改进范围限定在：**更聪明的重试 + 更好的错误提示**。

---

## 问题现状

当前重试逻辑位于 `agent.zig:249-273`（`callWithRetry`），SSE 流式处理在 `openai_compat.zig`，信号处理在 `signal.zig`：

```
agent.zig:callWithRetry()
  ├─ 3次重试，退避 1s→2s→4s
  ├─ error.ApiError → 不重试（checkSseExit 返回的）
  ├─ error.Interrupted → 不重试
  └─ 其他（CurlFailed/ReadFailed）→ 重试
```

缺陷：
- **不区分错误类型** — `checkSseExit` 把 401/403/500 都归为 `error.ApiError`，无法区分
- **退避固定** — 1s/2s/4s，不尊重服务器 `Retry-After` 头
- **不可中断** — 用户不能取消等待（`signal.zig` 已有 `isInterrupted()`/`reset()` 基础设施，但未接入重试等待）
- **耗尽后只丢 `CurlFailed`** — 用户不知道具体原因

---

## 改动范围

### P0 — 错误分类 + Retry-After 头

| 改动 | 文件 | 说明 |
|------|------|------|
| 新增 `RetryPolicy` 模块 | `src/provider/retry.zig` | 错误分类、退避计算 |
| 分类逻辑 | 同上 | `isRetryable(error, status_code, body)` |
| Retry-After 解析 | 同上 | 优先 `retry-after-ms` → 其次 `retry-after`（整数秒）→ 回退全抖动。不支持 HTTP-date 格式 |
| 退避计算 | 同上 | 无 `Retry-After` 时用全抖动算法 |
| SSE 边界策略 | 同上 | 只重试连接阶段错误，已收首条数据后断流不重试 |
| 重构 `callWithRetry` | `agent.zig` | 集成新模块，改指数退避 |
| 重构 `checkSseExit` | `openai_compat.zig` | 区分 HTTP 状态码和错误类型 |
| 复用信号基础设施 | `signal.zig` | `isInterrupted()`/`reset()` 已有，无需新增 |

#### 错误分类规则

| 条件 | 是否重试 |
|------|---------|
| HTTP 400/401/403/404 | ❌ 不重试 |
| HTTP 408 | ✅ 重试 |
| HTTP 429（配额耗尽，如 `insufficient_quota`） | ❌ 不重试 |
| HTTP 429（普通限速） | ✅ 重试，用 Retry-After |
| HTTP 5xx | ✅ 重试 |
| 网络错误（连接拒绝/超时/DNS 失败） | ✅ 重试，但仅限连接阶段 |
| SSE 已收到首条有效数据后断流 | ❌ 不重试，报"流传输中断" |
| curl 未找到等本地错误 | ❌ 不重试 |

#### 退避算法

全抖动（Full Jitter）：

```
base_ms = 1000
attempt = 0..max_retries
sleep_ms = random_between(base_ms * 2^attempt, base_ms * 2^(attempt+1))
```

有 `Retry-After` 头时按以下优先级处理：

1. `retry-after-ms`（自定义头，OpenAI 等使用）→ 尝试解析为整数毫秒。非数字或负数 → 回退到下一步
2. `retry-after`（标准头）→ 尝试解析为整数秒（去除首尾空白和引号）。非数字或负数 → 回退到下一步
3. HTTP-date 格式（如 `Wed, 21 Oct 2026 07:28:00 GMT`）→ **不支持，回退全抖动**。纯 Zig 解析 RFC 1123 日期无标准库辅助，实现成本过高（至少上百行），且生产环境中极少有服务返回此格式的 `Retry-After`（OpenAI、DeepSeek 均返回整数秒）
4. 全部解析失败 → 回退全抖动算法

服务器返回的 `Retry-After` **不设硬上限**。仅当值超过 300s（5 分钟）时截断——这不是为了节约等待时间，而是防止客户端因网络问题卡死过久。一般 API 也不会要求客户端等超过 5 分钟。

#### SSE 重试边界：阶段状态机

整个请求分为 5 个阶段，只有阶段 A-C 可重试，阶段 D-E 不重试：

```
A. DNS 解析 → B. TCP 连接 → C. TLS 握手 + HTTP 首部 → D. 收到 200 + 首条 data → E. 后续 data 流
```

| 阶段 | 失败场景 | 是否重试 | 说明 |
|------|---------|---------|------|
| A | DNS 解析失败 | ✅ | 网络问题，可等网络恢复 |
| B | TCP 连接超时/拒绝 | ✅ | 同上 |
| C | TLS 握手失败 / HTTP 非 200 / 首部超时 | ✅ | 服务器暂不可用 |
| D | 收到 200 但首条 `data:` 超时未到 | ❌ | 服务器已接受了请求，不应重试 |
| E | 中途断流 | ❌ | 已输出部分 token，重试导致重复/跳跃 |

阶段 D 的判断需要**超时阈值**，避免慢模型推理（如 DeepSeek 可能 10s+ 才出首 token）被误判为断流：

```
首条 data 等待超时 = max(30s, 模型首次响应预期时间)
```

首次响应预期时间目前取固定值 30s（覆盖绝大多数模型）。阶段 D 超时后报错：

```
服务器响应超时（超过 30s 未收到首条数据），请稍后重试。
```

阶段 E 中途断流报错：

```
流传输中断，请重新发起对话。
```

### P0.5 — 可配置超时

| 改动 | 文件 | 说明 |
|------|------|------|
| 新增 `connect_timeout_secs` 字段 | `src/types.zig` | `ModelConfig` 可选字段，TCP+TLS 连接超时 |
| 新增 `max_timeout_secs` 字段 | `src/types.zig` | `ModelConfig` 可选字段，总请求超时 |
| TOML 解析 | `src/config.zig` | `[[providers]]` 段解析 `connect_timeout_secs` 和 `max_timeout_secs` |
| 字段传递 | `src/provider/registry.zig` | `ProviderEntry` 新增两个可选字段 |
| 字段传递 | `src/provider.zig` | `buildProviderEntries` 透传字段 |
| 字段传递 | `src/App.zig` | 构造 `ModelConfig` 时传入字段 |
| 使用字段 | `src/provider/openai_compat.zig` | 替换硬编码 `--max-time 30` 为可配置值 |
| 默认值 | `openai_compat.zig` | `connect_timeout` 默认 15s，`max_timeout` 默认 60s |

#### TOML 配置示例

```toml
[[providers]]
name = "deepseek"
# ... other fields ...
connect_timeout_secs = 30    # TCP+TLS 连接超时（秒），缺省 15
max_timeout_secs = 120       # 总请求超时（秒），缺省 60
```

#### 实现说明

- `connect_timeout_secs` 对应 curl 的 `--connect-timeout`（TCP+TLS 握手阶段超时）
- `max_timeout_secs` 对应 curl 的 `--max-time`（整个请求完成超时，含传输）
- 两项均为可选，TOML 中不配置则沿用代码默认值
- 使用局部栈上 buffer（`bufPrint`）避免 allocPrint 的内存管理开销

---

### P1 — 重试可中断 + 用户透明

| 改动 | 文件 | 说明 |
|------|------|------|
| `interruptibleSleep(ms)` 函数 | `agent.zig` 或 `Cli` 模块 | 100ms 切片轮询，检查 `signal.isInterrupted()`。`signal.zig` 已有 `reset()` 基础设施 |
| 中断机制 | `signal.zig` | 复用已有 `isCancelled()`，重试前后调 `reset()` |
| 消耗计数 | `agent.zig` | 显示 "正在重试 (2/3)，等待 4s..." |
| 错误聚合策略 | `agent.zig` + `retry.zig` | 优先报首次 4xx，否则按类别聚合 |
| 常见错误码映射 | `retry.zig` | 400/401/429 映射可操作建议 |

#### 中断实现

不依赖信号处理器。用 `interruptibleSleep(ms, flag)` 实现轮询睡眠：

```
fn interruptibleSleep(ms: u64, flag: *std.atomic(bool)) void {
    const slice_ms: u64 = 100;
    var elapsed: u64 = 0;
    while (elapsed < ms) {
        if (flag.*.load(.acquire)) return;
        std.time.sleep(slice_ms * std.time.ns_per_ms);
        elapsed += slice_ms;
    }
}
```

#### 中断标志传递架构

`atomic(bool)` 标志由 **`App` 的顶层 REPL 循环持有**，通过以下路径传递：

```
App 顶层 (拥有者)
  └─ callWithRetry(..., &interrupt_flag)
       └─ interruptibleSleep(ms, interrupt_flag)
```

在 z-agent 的单线程异步模型中，所有网络操作在同一个线程上运行，不存在跨线程悬挂指针问题。Ctrl+C 时 signal handler 设置该标志位即可。

```
// 全局或 App 字段
interrupt_flag: std.atomic(bool) = std.atomic(bool).init(false);

// Ctrl+C 回调
fn handleInterrupt() void {
    interrupt_flag.store(true, .release);
}
```

#### 错误聚合

在 `callWithRetry` 中维护**首次不可恢复错误**和**最后一次错误类别**：

```
如果重试过程中出现了 4xx 认证/权限错 →
  忽略后续所有错误，最终报该 4xx（决定性的不可恢复错误）

否则 →
  按类别聚合，优先级从高到低：
    1. 有 5xx → 归类为"服务器暂时不可用"
    2. 有 408/超时 → 归类为"请求超时"
    3. 有连接拒绝/DNS 失败 → 归类为"网络连接异常"
  最高优先级类别胜出，不拼接。
  最终输出："DeepSeek API 暂时不可用（服务器错误），请稍后重试"
```

**类别冲突规则**：优先级从高到低 —— 5xx > 超时 > 网络错误。高优先级覆盖低优先级，不拼接类别名。

#### 中断标志生命周期

```
调用 callWithRetry 前:
  interrupt_flag = false

调用 CallWithRetry 中:
  Ctrl+C → signal handler → interrupt_flag = true
  interruptibleSleep() 每次切片检查 flag
  如果为 true → 提前返回，最终报"请求已取消"

调用 callWithRetry 后:
  interrupt_flag = false  // 无论成功还是失败，必须重置
```

**不重置的后果**：下一次正常 API 调用进入 `interruptibleSleep` 时会立刻读到 `true` 而误退出。

#### 常见错误码映射

解析响应体中的 `error.code` 或 `error.message`，映射为可操作建议：

| 识别条件 | 提示 |
|----------|------|
| `context_length_exceeded` / `maximum context length` | 上下文超出模型处理上限，建议 `/clear` |
| `invalid_api_key` / `authentication` | API Key 认证失败，请检查环境变量 |
| `insufficient_quota` / `quota exceeded` | API 配额已耗尽 |
| 其他 4xx | API 返回错误 (HTTP {code}) |
| 重试耗尽 + 5xx/网络错 | 遭遇 {code1}, {code2}，请稍后重试或检查网络 |

---

## 参考实现

pi-repos `packages/ai/src/providers/openai-codex-responses.ts` 的错误分类：

```typescript
function isRetryableError(status: number, errorText: string): boolean {
    if (status === 429 && isTerminalRateLimitError(errorText)) return false;
    if (status === 429 || status >= 500) return true;
    return /rate.?limit|overloaded|service.?unavailable|connection.?refused/i.test(errorText);
}
```

nullclaw `src/providers/reliable.zig` 的退避和 Retry-After 解析：

```zig
pub fn computeBackoff(base: u64, err_msg: []const u8) u64 {
    if (parseRetryAfterMs(err_msg)) |retry_after| {
        return @max(@min(retry_after, 30_000), base);
    }
    return base;
}
```

---

## 预期效果

| 场景 | 当前行为 | 改后行为 |
|------|---------|---------|
| API Key 错误 | 重试 3 次后 `CurlFailed` | 立即报"API Key 认证失败" |
| 上下文超长 | 重试 3 次后 `CurlFailed` | 立即报"上下文超出上限，建议 /clear" |
| 服务器 503 | 重试 1s/2s/4s | 按 Retry-After 等待，显示进度 |
| 网络超时 | 重试 1s/2s/4s 后 `CurlFailed` | 指数退避 + 全抖动，显示倒计时 |
| SSE 中途断流 | 可能隐式重试 | 立即报"流传输中断" |
| 所有重试耗尽 | `CurlFailed` | 显示具体原因 + 可操作建议 |
| 用户不想等了 | 只能 Ctrl+C 强杀 | Ctrl+C 100ms 内响应中断 |
