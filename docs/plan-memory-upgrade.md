# 记忆系统升级计划 — memory 重构

> 对标 opencode-self-improve v3.8.x，全量升级 z-agent 记忆系统。
> 依赖文件：`src/tool/json.zig`（已有）、`src/tool/root_dir.zig`（已有）

---

## 架构决策

### BM25 替换手工召回打分

`src/retrieval.zig` 已有生产级 BM25 引擎（CJK/Latin 分词，k1=1.2/b=0.75，`compact.zig` 在用）。`cmdRecall` 当前的手工打分（0.8/0.6/0.4/0.2）+ 有内存泄漏的 `cjkBigrams`（内层 bigram 字符串通过 `allocator.dupe` 分配后从未释放）应替换为 BM25：

```
cmdRecall 流程变更（Phase 1 同时实施）:

query 进入
  ├── pattern-key exact match → 返回 1.0 分（零开销短路）
  └── 无 exact match → retrieval.search(query, docs, top_k=10)
```

收益：
- 修复 `cjkBigrams` 内存泄漏（LRN-20260628-047）——内层 bigram 字符串泄漏，外层 `free` 仅释放切片数组
- 删除 90 行脆弱代码（`cjkBigrams` + 手工打分 + `indexOfIgnoreCase`）
- 召回质量从 4 级离散分升级为 BM25 连续分
- 自带 snippet 提取（`extractSnippet`）

### 文本截断统一化：`truncate.zig` 增强

当前代码库存在多个文本截断实现，其中 UTF-8 不安全：

| 位置 | 函数 | UTF-8 安全 | 问题 |
|------|------|-----------|------|
| `tool/truncate.zig:9` | `truncateBytes()` | ❌ | 字节截断可能切中多字节字符 |
| `tool/truncate.zig:16` | `truncateLines()` | ✅ | 按行截断 |
| `tool/read.zig:486` | 私有 `truncateBytes()` | ❌ | 重复实现 |
| `tool/edit.zig:251` | 私有 `truncateToCodepoints()` | ✅ | 只被 edit.zig 自己用 |
| `tool/memory.zig:180,295` | `@min(end, N)` | ❌ | 多处散落 |
| `tool/retrieval.zig:186,205` | `@min(content.len, 200)` | ❌ | 散落 |

**统一方案**：增强 `truncate.zig`，新增 UTF-8 安全的字节截断 + 迁移所有调用点：

```zig
// tool/truncate.zig 新增

/// Truncate at the largest valid UTF-8 boundary ≤ max_bytes.
/// Assumes valid UTF-8 input. If input has illegal byte sequences,
/// each malformed byte is treated as a 1-byte unit (catch 1 fallback),
/// and the truncated output remains otherwise valid from the start.
/// Input from trusted sources (memory.md, session messages pre-validated
/// by std.json parser) is guaranteed valid UTF-8.
pub fn truncateUtf8(text: []const u8, max_bytes: usize) TruncatedText {
    if (text.len <= max_bytes) return .{ .text = text, .truncated = false, .original_len = text.len };
    if (max_bytes == 0) return .{ .text = "", .truncated = true, .original_len = text.len };
    var i: usize = 0;
    while (i < max_bytes) {
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        if (i + len > max_bytes) break;  // 下一个字符超出限制，在此安全截断
        i += len;
    }
    return .{ .text = text[0..i], .truncated = true, .original_len = text.len };
}

/// Count codepoints up to max (moved from edit.zig, made public)
pub fn truncateCodepoints(text: []const u8, max_codepoints: usize) TruncatedText {
    var count: usize = 0;
    var i: usize = 0;
    while (i < text.len and count < max_codepoints) {
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch break;
        i += len;
        count += 1;
    }
    return .{ .text = text[0..i], .truncated = i < text.len, .original_len = text.len };
}
```

迁移计划：

1. `read.zig:486` 的私有 `truncateBytes` → 全部调用点改用 `truncate.truncateUtf8`
2. `edit.zig:251` 的 `truncateToCodepoints` → 改为调用 `truncate.truncateCodepoints`
3. `memory.zig:extractTitle()` 中的 `@min(end, 60)` → 先用 `truncateUtf8(content[0..end], 60)` 再用 `trim`
4. `memory.zig:180` 预览的 `@min(end - body_start, 200)` → `truncateUtf8(content[body_start..], 200)`
5. `retrieval.zig:186,205` 的 `@min(content.len, 200)` → `truncateUtf8(content, 200)`

这是 Phase 1 前的**前置重构**，不改变行为仅保证 UTF-8 安全。

### JSON 处理：分层序列化策略

| 层级 | 用途 | 方法 |
|------|------|------|
| **工具输出** | cmdAdd/Recall/Delete/Archive 返回值 | 流式构建器（现有 `json.zig`），扁平 JSON |
| **持久状态** | `session-state.json`, `changesets/*.json`, `skill-bank.json` | 每个结构体定义显式 `serialize()` / `deserialize()` 函数 |
| **读入参数** | tool 输入 args | 现有 `std.json.parseFromSlice → ObjectMap.get()` |

复杂 JSON 采用**显式序列化函数**（复用 `src/tool/json.zig` + `common.appendEscapedJsonString`）：

```zig
// memory/session.zig 示例
const SessionState = struct {
    last_topic: []const u8,
    hard_case_buffer: []HardCase,
    skill_metrics: SkillMetrics,
    operation_log: []OperationLogEntry,
    
    pub fn serialize(self: *const SessionState, allocator: std.mem.Allocator) ![]u8 {
        var buf = std.array_list.Managed(u8).init(allocator);
        try buf.appendSlice("{\"lastTopic\":\"");
        try json.escapeJson(&buf, self.last_topic);
        try buf.appendSlice("\",\"hardCaseBuffer\":[");
        // for each HC → {"id":"...","symptom":"...","context":"...","timestamp":"..."}
        // ...
        try buf.appendSlice("],\"operationLog\":[");
        // ...
        try buf.appendSlice("]}");
        return json.finish(&buf);
    }
    
    pub fn deserialize(allocator: std.mem.Allocator, raw: []const u8) !SessionState {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
        defer parsed.deinit();
        const root = parsed.value.object;
        return SessionState{
            .last_topic = root.get("lastTopic").?.string,
            .hard_case_buffer = parseHardCases(allocator, root.get("hardCaseBuffer").?.array),
            // ...
        };
    }
};
```

这种方式：
- **零依赖**：只用 `std.json.parseFromSlice` 解析 + `json.zig` 构建
- **显式可控**：字段顺序、可选 null、格式完全在代码中
- **与 session 模块一致**：`session/serialize.zig` 已是同一模式
- **不依赖 `std.json.stringify`**：Zig 0.16.0 中 `stringify` 行为未验证

### 拆分策略：`tool/memory/` 子模块

单文件预计 3000+ 行 → 拆为模块，`App.zig` 导入无需变更：

```zig
// App.zig — 导入方式不变
const tool_memory = @import("tool/memory.zig");
```

```zig
// tool/memory.zig — 转发层（~50 行）
const crud = @import("memory/crud.zig");
const designer = @import("memory/designer.zig");
// ...
pub const tool_name = crud.tool_name;
pub const tool_description = crud.tool_description;
pub const tool_params = crud.tool_params;
pub fn execute(allocator, io, args) ToolResult { ... }  // 路由到子模块
```

| 文件 | 用途 | 预估行数 |
|------|------|---------|
| `tool/memory.zig` | 转发层 + execute 路由 | ~50 |
| `tool/memory/types.zig` | Entry / ScoredEntry / SessionState / ChangeSet 等类型 | ~120 |
| `tool/memory/parse.zig` | parseEntries / serializeEntry / ID 生成 / 锚点检查 | ~250 |
| `tool/memory/crud.zig` | cmdAdd / cmdRecall / cmdDelete | ~350 |
| `tool/memory/archive.zig` | cmdArchive / cmdPromote / cmdStat | ~200 |
| `tool/memory/session.zig` | session-state.json 读写 + metrics | ~250 |
| `tool/memory/designer.zig` | designer 子命令集（7+ 操作） | ~700 |
| `tool/memory/self_improve.zig` | 中断自省 / bash 失败自动记录 | ~200 |
| `tool/memory/skill_bank.zig` | skill-bank 追踪 | ~100 |
| **合计** | | **~2200** |

### 并发防护与原子写入

写操作使用 write-tmp-rename 原子模式，含**错误恢复**：

```
fn atomicWrite(io, path, content):
  1. 写入 `<path>.tmp`
  2. 调用 `std.Io.Dir.renameAbsolute(tmp, path, io)`
     成功 → 返回 ok
     失败（EACCES/EDISK/EIO）→
       删除 .tmp 文件（忽略错误）
       返回结构化错误："Error: atomic_write_failed <path>: <reason>"
```

所有写操作遵循此模式：
- `memory.md` write: tmp + rename
- `session-state.json` update: tmp + rename
- changeset 文件创建: tmp + rename
- `memory-archive.md` append: tmp + rename

外部编辑器修改：不防护（约定 AI 唯一写入者），但检测文件 mtime 做**失效标记**，下次操作时重解析。

### 可观测性

所有写操作通过 `io` 输出结构化通知（JSON 行），同时记录到 session-state.operationLog：

```json
// stdout 输出格式（AI 可见）：
{"memory_event":"auto_approve","changeset_id":"CS-20260702-001","entry_id":"MEM-...","reason":"confidence=0.92 > 0.85"}
{"memory_event":"atomic_write_failed","path":".zagent/memory.md","reason":"EACCES"}
{"memory_event":"apply_conflict","changeset_id":"CS-...","expected_mtime":12345,"actual_mtime":67890}

// session-state.json 内记录：
"operationLog": [
  {"ts":"...","event":"auto_approve","changeset_id":"CS-...","entry_id":"MEM-..."},
  {"ts":"...","event":"apply","changeset_id":"CS-...","status":"ok"}
]
```

operationLog 修剪策略（两级独立容量，互不冲突）：

| 层级 | 容量 | 修剪规则 |
|------|------|---------|
| **关键事件**（auto_approve/apply/rollback） | 最多 500 条 | 超过时最旧的移至 `.zagent/audit-log-archive.jsonl` |
| **归档日志**（audit-log-archive.jsonl） | 最多 5000 条 | 超过时删除最旧的归档条目（滚动窗口） |
| **常规事件**（其余） | 最多 200 条 | 超过时直接删除最旧的 |

---

## Phase 1 — 存储格式升级 + 归档晋升

### 增强条目格式（向后兼容）

```markdown
## [MEM-YYYYMMDD-NNN] 标题
**source**: 用户|自动
**pattern-key**: xxx
**priority**: low|medium|high|critical
**scope**: project-specific|cross-project|opencode-self
**status**: new|fixed|wontfix|duplicate
**handled**: pending|covered
**recurrence-count**: 1
**archived**: false
**related-files**: path/to/file.zig, path/to/other.md
**logged**: YYYY-MM-DD

内容...
```

解析规则：缺失字段 → 默认值（scope=project-specific, status=new, handled=pending, recurrence-count=1, archived=false）。

### 新命令

| 命令 | 参数 | 说明 |
|------|------|------|
| `archive` | `--id` / `--older-than <days>` / `--all` | 原子移动条目到 `.zagent/memory-archive.md` |
| `promote` | `--id <ID>` `--priority <new>` | 修改条目优先级（tmp+rename 更新原文件） |
| `stat` | (无) | 输出记忆系统统计（总数/优先级分布/scope分布/status分布） |

### 文件

- `tool/memory/types.zig`: Entry 结构体扩充
- `tool/memory/parse.zig`: parseEntries 增强 + serializeEntry
- `tool/memory/crud.zig`: cmdAdd 写入新字段
- `tool/memory/archive.zig`: 新文件，含 archive/promote/stat

### 性能

`parseEntries()` 每次调用全量扫描。引入**写后失效缓存**：

- `entry_cache: ?[]Entry = null`
- `cache_mtime: u64` 记录上次解析时的文件 mtime
- 每次**读操作**（recall/stat）前检查文件 mtime，未变则复用缓存
- 每次**写操作**（add/archive/delete/promote/designer apply）后立即将 `entry_cache = null` 置空
- 写操作是 `write-tmp-rename` 原子模式，mtime 在 rename 完成后由 OS 更新，不存在 TOCTOU 窗口——因为写后立刻失效的是我们自己的缓存，外部修改在下一个读操作时通过 mtime 检测自然发现

⚠️ **Entry 字段生命周期**：`parseEntries()` 返回的 `Entry` 字段（id, title, pattern_key 等）是零拷贝切片指向输入 `content` 缓冲区。缓存设计必须二选一：
  - **方案 A**（推荐）：缓存整个文件内容 `cache_content: ?[]u8` + `entry_cache: ?[]Entry`，确保字段切片始终有效
  - **方案 B**：缓存时对每个字段 `allocator.dupe`，`free` 旧缓存时先释放字段再释放 entry 数组。更安全但增加了 `parseEntries` 约 10% 分配开销

### parseEntries 错误恢复

> **前置重构**：当前 `parseEntries` 内联了所有字段提取逻辑。需先将单条条目解析提取为 `parseSingleEntry(content, start, end) !Entry`，使上层容错循环可独立跳过损坏区域。

解析器对格式损坏有容错策略，不因单条坏数据导致全量崩溃：

```zig
// parseEntries 伪逻辑
while (findNextHeader(content, scan_pos)) |header_start| {
    // 找到条目区域：从 header_start 到下一个 "\n## [" 或 EOF
    const region_end = findNextHeader(content, header_start + 1) orelse content.len;
    const entry_raw = content[header_start..region_end];
    
    // 尝试解析，失败则跳过整个区域（不是逐字节，避免 O(n²)）
    const entry = parseSingleEntry(content, header_start, region_end) catch {
        scan_pos = region_end;
        continue;
    };
    try entries.append(entry);
    scan_pos = region_end;
}
```

---

## Phase 2 — session-state.json 追踪

### 文件格式

`.zagent/session-state.json`：

```json
{
  "lastTopic": "",
  "lastUpdate": "ISO8601",
  "pendingDecisions": [],
  "activeLearnings": ["MEM-20260701-001"],
  "hardCaseBuffer": [],
  "skillMetrics": {
    "recall": { "calls": 10, "failures": 1, "avgScore": 0.65 },
    "add": { "calls": 5, "anchorsRejected": 1 }
  },
  "designerRuns": [],
  "taskCalls": [],
  "operationLog": [
    {"ts":"2026-07-02T01:00:00Z","event":"auto_approve","changeset_id":"CS-...","entry_id":"MEM-..."},
    {"ts":"2026-07-02T01:01:00Z","event":"atomic_write_failed","path":".zagent/memory.md","reason":"EACCES"}
  ],
  "unfinishedTasks": [],
  "lastSessionEnd": null
}
```

operationLog 保留最近 30 天常规事件 + 永久保留关键事件（auto_approve/apply/rollback），详见可观测性章节。

### HardCaseBuffer 修剪策略

| 条件 | 行为 |
|------|------|
| 总条数 > 50 | 删除最旧的 20 条 |
| 单条年龄 > 30 天 | 自动删除 |
| `collect` 已消费的 HC | 标记 `consumed: true`，30 天后清理 |

容量上限 50 条，不会无限膨胀。

### 原子写入

所有 session-state.json 写入使用 tmp + rename 模式。

---

## Phase 3 — Designer 流水线

### 自治瘫痪防护：置信度自动批准阈值

```
confidence > 0.85  → 自动批准 + 直接 apply（走 apply 完整冲突检测，失败则降级为 review）
0.60 ≤ confidence ≤ 0.85  → 创建 changeset + 暂停等待 review
confidence < 0.60  → 创建 changeset + 标记为 draft（不阻塞流水线）
```

置信度计算（不依赖 CJK 语义匹配，避免工程陷阱）：

| 规则 | 分值 | 说明 |
|------|------|------|
| pattern-key 已存在 | +0.0 | 去重命中，不新增 |
置信度使用**双通道文本相似度**（拉丁 + CJK 独立计算后合并），CJK 通道使用 bigram 匹配 + 停用词过滤，避免高频虚词假阳性：

```python
# 伪逻辑：双通道合并
def confidence(pattern_key, symptom):
    score = 0
    
    # 通道 A：拉丁文本相似度
    latin_pattern = extract_latin_tokens(pattern_key)
    latin_symptom = extract_latin_tokens(symptom)
    overlap_latin = count_common(latin_pattern, latin_symptom)
    if overlap_latin > 0 and max(len(latin_pattern), len(latin_symptom)) > 0:
        score += min(overlap_latin / max(len(latin_pattern), len(latin_symptom)), 1.0) * 0.25
    
    # 通道 B：CJK bigram 相似度（过滤停用词）
    cjk_pattern = extract_cjk_bigrams(pattern_key, STOP_WORDS)
    cjk_symptom = extract_cjk_bigrams(symptom, STOP_WORDS)
    overlap_cjk = count_common_bigrams(cjk_pattern, cjk_symptom)
    if overlap_cjk > 0 and max(len(cjk_pattern), len(cjk_symptom)) > 0:
        score += min(overlap_cjk / max(len(cjk_pattern), len(cjk_symptom)), 1.0) * 0.25
    # bigram 比单字符匹配更鲁棒：避免"的/了"等高频单字命中，同时保留语义
    
    # 通道 C：关键词表
    score += keyword_match(pattern_key, symptom) * 0.15
    
    # 通道 D：文件引用
    score += file_ref_match() * 0.15
    
    # 通道 E：严重度对齐
    score += severity_align() * 0.1
    
    # 通道 F：无冲突
    score += no_conflict() * 0.1
    
    return min(score, 1.0)
```

CJK 停用词表（过滤后不参与 bigram 生成）：

```
的 了 是 在 有 不 我 这 那 也 和 就 都 而 及 与 着 或 一个
没有 我们 他们 你们 它们 自己 什么 怎么 如何 因为 所以
如果 虽然 但是 而且 然后 之后 之前 对于 关于 通过
```

| 通道 | 分值上限 | 说明 |
|------|---------|------|
| A: 拉丁 token 重叠率 | 0.25 | 按空格/下划线拆分的单词重叠（case-insensitive） |
| B: CJK bigram 重叠率 | 0.25 | 过滤停用词后生成 CJK bigram（两两相邻字符），重叠率 = 公共 bigram ÷ 最大 bigram 数 |
| C: 关键词表 | 0.15 | 拉丁关键词 + CJK 关键词双语言表 |
| D: 文件引用 | 0.15 | 提案文件路径存在于 `related-files` 或 `.zagent/` |
| E: 严重度对齐 | 0.10 | critical=panic/崩溃, high=error/错误, medium=warn/警告 |
| F: 无冲突 | 0.10 | pattern-key 不与任何现有条目重复 |
| **合计** | **1.0** | 封顶 1.0 |

**HC symptom 语义提取来源定义**：

| HC 来源 | symptom 取值 |
|---------|------------|
| 用户手动记录 `memory add` | content 的 `extractTitle()` 结果 |
| 召回失败（recall 返回空或 top 分数 < 0.3） | recall query |
| Bash 错误（exit code ≠ 0） | 失败命令的前 120 字符 |
| Esc 中断 | 最后用户消息的 `extractTitle()` 结果 |

降级：若 symptom 为空或仅含空白字符，`confidence = 0.5`（进入 review）。

### 流程

```
collect → propose ──→ confidence ≥ 0.85 ──→ conflict check → 通过 → auto-apply（记录 operationLog）
                    │                           ↕ 失败
                    │                           → 降级为 review
                    ↘  confidence < 0.85 ──→ review → approve/rollback
```

### apply 冲突检测

apply 前必须校验：

```
1. 读取当前 memory.md 的 mtime + file_size
2. 与 changeset 生成时记录的 snapshot {mtime, size, hash} 比对
3. 一致 → 执行 apply（tmp+rename）
4. 不一致 → 按模式决定：
   - 正常模式：拒绝 apply，输出结构化错误（含期望/实际 mtime 差异）+ 建议重新 propose
   - `--force` 模式：跳过校验直接 apply（适用于用户手动修正错别字、空行等无害变更）
```

snapshot 哈希：对 memory.md **全文**计算 `std.hash.Crc32`（轻量级，~1 μs/KB）。不用部分哈希——部分 CRC32 在内容变更但前 1024 字节不变时不敏感。mtime + size + 全文 CRC32 三重校验充分冗余。

### 新命令

| 子命令 | 参数 | 说明 |
|--------|------|------|
| `collect` | `--limit <N>` | 从 hardCaseBuffer 取最多 N 条未消费 HC |
| `propose` | `--id <HC-ID>` | 生成 changeset（含 old/new/confidence） |
| `list` | `--status <s>` | 按状态列出 changeset |
| `review` | `--id <CS-ID>` | 显示 changeset 的 old/new diff |
| `approve` | `--id <CS-ID>` | 标记 approved（等待 apply） |
| `apply` | `--id <CS-ID>` `[--force]` | 先校验 snapshot mtime/size/crc32，一致则应用（tmp+rename）；不一致时报错（除非 `--force`） |
| `rollback` | `--id <CS-ID>` | 还原应用（保存备份） |
| `verify` | (无) | 检查所有 applied changeset 完整性 |
| `report` | (无) | Designer 状态总览 |

### 目录结构

`.zagent/changesets/<CS-ID>.json`

```zig
const Snapshot = struct {
    mtime: u64,
    size: u64,
    crc32: u32,  // memory.md 全文 CRC32
};

const ChangeSet = struct {
    id: []const u8,
    hard_case_id: []const u8,
    title: []const u8,
    summary: []const u8,
    old_entry: ?[]const u8,
    new_entry: []const u8,
    status: enum { draft, proposed, approved, applied, rejected, rolled_back },
    created: []const u8,
    applied: ?[]const u8,
    confidence: f64,
    // 生成时的文件快照（apply 时校验冲突）
    snapshot: ?Snapshot,
};
```

---

## Phase 4 — Esc 中断自省

### extractTitle 算法定义

直接复用 `memory.zig` 已有实现（`src/tool/memory.zig:293-297`）：

`extractTitle` 复用 `truncateUtf8`（下文定义），避免手写逆向步进的越界风险：

```zig
fn extractTitle(content: []const u8) []const u8 {
    const end = std.mem.indexOfAny(u8, content, "\n。") orelse content.len;
    const limited = truncateUtf8(content[0..end], 60);
    return std.mem.trim(u8, limited.text, " \r\n\t");
}
```

`truncateUtf8` 使用正向扫描 + `utf8ByteSequenceLength`，永远不访问 `content[content.len]`，无 OOB 风险。行为：
- 取 `\n` 或 `。` 之前的内容，安全截断到 ≤60 字节
- 截断时不切断 UTF-8 多字节序列（正向扫描逐字符校验）
- 无 `\n`/`。` 时取 `truncateUtf8(content, 60)`
- 用于中断自省时对每条消息的 `content` 独立调用

### 信号安全约束

信号处理器**只设原子标志，不做任何实际工作**。Zig 0.16.0 中 `std.atomic.Value(u1)` 可以无锁设置。

```zig
var interrupt_flag: std.atomic.Value(u1) = .{ .raw = 0 };

// 信号处理器（零分配，零 I/O）
fn handleInterrupt() callconv(.C) void {
    interrupt_flag.store(1, .Monotonic);
}
```

实际工作全部在主循环的安全点执行：

```
主循环（每次 tool call 完成后）:
  1. 检查 interrupt_flag
  2. 若已设，在 main loop 上下文中（非信号栈）执行记录：
     a. 从 msg_buf 取最后 3 条消息内容
     b. 调用 extractTitle() 摘要（在主线程，可安全分配内存）
     c. 调用 cmdAdd（source=自动）
```

### 触发条件

- 仅在会话消息 ≥3 条时触发，避免空会话噪声
- 仅在**非 agent 模式**下触发（agent 模式由调用方管理中断）
- 仅在无正在运行的 tool 调用时触发（tool call 中中断由 tool 自身处理）

### Bash 失败自动记录

1. bash 返回非零 → 获取命令内容 + stderr（截断前 200 字）
2. pattern-key 按失败命令的 `prefix 前 8 字符 + 退出码` 编码
3. source = "自动"

---

## Phase 5 — skill-bank 演化追踪

### 文件

`.zagent/skill-bank.json`：

```json
{
  "skills": [
    {
      "slug": "memory",
      "name": "memory",
      "version": 2,
      "evolution": [
        { "version": 1, "date": "2026-06-20", "change": "初始 CRUD" },
        { "version": 2, "date": "2026-07-02", "change": "新增 Designer/归档/session-state" }
      ]
    }
  ]
}
```

### 命令

| 命令 | 参数 | 说明 |
|------|------|------|
| `skill-bank list` | (无) | 列出所有技能及版本 |
| `skill-bank update` | `--slug <s>` `--change <desc>` | 递增版本 + 记录变更 |

---

## 迁移策略

### 现有数据兼容

- `parseEntries()` 解析缺失字段 → 默认值填充，zero-copy
- 现有 `.zagent/memory.md` 无需修改
- `archive` 首次运行时按需创建 `.zagent/memory-archive.md`

### 测试策略

- 每子模块独立测试文件 `test/<name>.zig`
- 向后兼容：现有测试用例不改动，全部通过
- 新增测试覆盖 > 80%

---

## 文件清单

```
src/
└── tool/
    ├── memory.zig                 # 转发层 + execute 路由
    └── memory/
        ├── types.zig              # 类型定义
        ├── parse.zig              # 解析/序列化/ID 生成/锚点检查
        ├── crud.zig               # add / recall / delete
        ├── archive.zig            # archive / promote / stat
        ├── session.zig            # session-state.json
        ├── designer.zig           # Designer 流水线
        ├── self_improve.zig       # 中断自省 / bash 失败记录
        └── skill_bank.zig         # skill-bank 追踪
```

---

## Phase 依赖关系

```
Phase 1 (types + parse + archive) ──────────────────┐
                                                     ├──→ Phase 3 (designer 依赖 types/parse/session)
Phase 2 (session) ───────────────────────────────────┘
                                                     ├──→ Phase 4 (self_improve 独立)
                                                     └──→ Phase 5 (skill_bank 独立)
```

Phase 1 → Phase 2 → Phase 3 需串行。
Phase 4 和 Phase 5 可并行，但依赖 Phase 1 的类型和 session-state 基础。
