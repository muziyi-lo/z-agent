# edit_file 工具设计

> 设计：2026-07-01 | 实现：`src/tool/edit.zig` | 状态：已提交

---

## 1. 架构

```
execute(allocator, io, args)
  ├─ 解析 path/oldString/newString/replaceAll
  ├─ 验证 oldString != newString, oldString 非空
  ├─ root_dir.resolvePath
  ├─ openFile → read → alloc(file_size)
  ├─ BOM 检测 → 剥离/保留
  ├─ 行尾检测 → old/new 字符串适配行尾
  ├─ countOccurrences
  │     ├─ 0 → Error "could not find oldString"
  │     └─ >1 && !replaceAll → Error "found N matches, set replaceAll"
  ├─ replace（精确匹配）
  ├─ 重组 BOM → createFile 覆写
  └─ JSON: {path, replacements}
```

## 2. 现状问题

| # | 问题 | 根因 | 后果 |
|---|------|------|------|
| ① | **仅精确匹配** | `replaceOne`/`replaceAll` 硬匹配 | LLM 生成 oldString 和实际内容差一个空格就失败，被迫改用 write_file 覆写全文件 |
| ② | **无 stale-content 检查** | 读→编辑→覆写，不验证中间是否被改 | 文件在工具调用期间被其他进程修改时静默覆盖。**注**：z-agent 是单用户 CLI，读→改→写发生在毫秒级同步调用内，不存在并发写入场景。该问题虽列出但不需要解决。 |
| ③ | **无 renderResult** | 无 `renderResult` 导出 | 用户看到裸 JSON 输出 |
| ④ | **全量读取无上限** | `alloc(u8, stat.size)` | 大文件 OOM 风险 |

## 3. 改动方案

### A: 模糊匹配回退链

在当前精确匹配前，插入 2 层模糊匹配作为回退：

```
匹配引擎按序尝试 3 层，每层独立搜索全文并返回匹配数：
  若某层返回 0 匹配 → 进入下一层
  若某层返回 1 匹配 → 使用该层结果，停止（无论后面还有多少层）
  若所有层均返回 0 匹配 → 报错

多候选处理：
  第 1 层 >1 候选且 !replaceAll → 报错 "found N exact matches, set replaceAll"
  第 1 层 >1 候选且 replaceAll → 执行全部替换
  第 2/3 层 >1 候选 → 不继续尝试后续层，报错 "found N approximate matches, provide more context"
```

各层策略：

```
1. 精确匹配（当前逻辑，无变化）
   全文逐字节比较，非重叠扫描（pos + pattern.len 跳过）
   例如 "aaa" 中找 "aa" → 1 次匹配（非 2 次）

2. 行去空白匹配（按行操作）
   将 oldString 和文件内容各自按 \n 拆分为行数组
   每行去掉首尾空白后逐行比较，行数必须一致
   适用于: LLM 保留了缩进但复制时多/少了尾部空格

3. 空白正规化匹配（按全文操作）
   将 oldString 和文件内容各自视为连续字符串
   将所有连续空白符（空格/tab/\n/\r）压缩为单空格后比较
   适用于: LLM 把 \t 写成空格、缩进级别变化、换行数不同
```

各层使用零分配迭代器（`std.mem.splitScalar`）处理行拆分，避免额外内存分配。

策略只决定**在哪里切**，`newString` 原样插入，不做任何空白正规化。

### B: 读上限

采用与 read_file 一致的 MAX_READ = 100KB 上限。超过时返回错误 `"file too large to edit ({size} bytes, max {MAX_READ})"`。

编辑超过 100KB 的文件应该用 `write_file` 覆写或逐段编辑。

### C: 输出展示

**原则**：输出操作（write_file / edit_file）展示实际变更内容，与 `read_file` 只显示摘要不同。

**edit_file 展示 diff**：

JSON 新增 `old_preview`/`new_preview` 字段，渲染时用 ANSI 红绿色标记：

```
  ✓ src/main.zig  (1 replacement, exact)
  ─ fn foo(x: i32) {
  ─   bar();
  + fn foo(x: i64) {
  +   bar();

  ✓ src/main.zig  (3 replacements, replaceAll)

  ✗ src/main.zig  (could not find oldString)
  ✗ src/main.zig  (found 2 matches, use replaceAll or more context)
```

- `replacements == 1` 时显示 diff 预览（不论是否 `replaceAll`）
- `replacements > 1` 时不显示（内容过多）
- 预览取匹配块上下文：匹配块**首行前 2 行** + 匹配块全部内容 + **末行后 2 行**。若文件行数不足则取到文件头/尾。单行匹配时取该行前后各 2 行。`old_preview`/`new_preview` 各截断 240 **Unicode 码点**（非字节），使用 `std.unicode.utf8ByteSequenceLength` 按码点边界截断，避免切碎多字节字符。超出则截断 + 追加 `...(truncated)`
- 内容原样展示，不走 md2ansi 渲染
- `-` 行用红色 ANSI，`+` 行用绿色 ANSI

### E: 原子写入

当前 `createFile` 直接覆写原文件，写入中途失败（磁盘满、权限撤销）会导致文件损坏。

改为先写 `.tmp` 文件再 `renameAbsolute` 覆盖（与 `session.zig` flushFile 一致的模式）：

```
write_content → createFile(path.tmp) → writeStreamingAll → close
→ renameAbsolute(path.tmp, path) → 完成
```

`renameAbsolute` 在 Windows 和 POSIX 上均为原子操作（同一文件系统内）。

匹配失败时，报告哪个层次的策略找到了内容但不满足唯一性：

```
Error: could not find oldString in 'src/main.zig'
  -- closest match via line_trimmed (2 approximate matches found, provide more context)

Error: could not find oldString in 'src/main.zig'
  -- no match via any strategy (exact / line_trimmed / whitespace_normalized)
```

不报告字符级差异（不引入编辑距离计算）。第 2/3 层找到内容时，仅输出策略名和候选数。

## 4. JSON 输出

```json
// 成功（单次替换，显示 diff）
{"path":"src/main.zig","replacements":1,"strategy":"exact","old_preview":"  ctx.selectedIndex = 0;","new_preview":"  ctx.selectedIndex = -1;"}

// 成功（模糊匹配）
{"path":"src/main.zig","replacements":1,"strategy":"whitespace_normalized","old_preview":"fn foo(x: i32)","new_preview":"fn foo(x: i64)"}

// 成功（replaceAll，不显示 diff）
{"path":"src/main.zig","replacements":3,"strategy":"exact"}

// 失败
Error: could not find oldString in 'src/main.zig'
```

## 5. 不改的

- `tool_name`、`tool_description`、`tool_params` 不变
- `ToolResult` 接口不变
- `root_dir.resolvePath` 不变
- BOM 处理不变
- 行尾处理不变
- `replaceAll` 语义不变
- `stale-content` 检查不适用（单用户 CLI，无并发写入场景）
- 非重叠匹配语义不变（"aaa" 找 "aa" → 1 次）

## 6. 文件范围

| 文件 | 改动量 | 说明 |
|------|--------|------|
| `src/tool/edit.zig` | ~150 行新增 | 模糊匹配 3 层 + renderResult + 原子写入 .tmp rename |
| `src/tool/edit.zig` 测试 | 增补 | 覆盖 3 层模糊匹配路径 |

## 7. 测试

| 测试 | 覆盖 |
|------|------|
| fuzzy exact first | 第 1 层精确匹配成功时不进模糊层 |
| line trimmed match | 尾部多空格匹配 |
| whitespace normalized match | tab→空格 匹配 |
| layer 2-3 multi candidate | 模糊多候选报错 |
| replaceAll with fuzzy | 模糊+全量替换 |
| no match after all layers | 全部失败报错 |
| overlapping match non-overlap | "aaa" 中 "aa" → 1 次 |
| atomic write | .tmp 文件 + rename 写入 |
| renderResult format | diff 显示格式 |
