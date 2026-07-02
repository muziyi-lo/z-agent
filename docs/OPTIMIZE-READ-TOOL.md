# read_file 工具优化方案

## 现状分析

`src/tool/read.zig` (152行) 核心流程：

```
args → 打开 → stat → alloc(file_size) → 读全部 → 判断类型 → 处理 → JSON
```

### 五点自洽问题

| # | 问题 | 根因 | 后果 |
|---|------|------|------|
| ① | **无条件全量读取** | `alloc(u8, file_size)` 无上限 | 大文件直接 OOM；offset=50 limit=10 也读全文件 |
| ② | **先读后判** | 读完全文后才判断文本/二进制 | 二进制文件先吃内存再报错，JSON 污染风险 |
| ③ | **无文本校验** | 读入后直接当 UTF-8 处理 | 非法 UTF-8 字节进入 JSON → 模型收到乱码 |
| ④ | **截断提示固化** | note 始终写 `offset=50`，不反映实际 offset | offset 模式下 note 错误引导 |
| ⑤ | **目录=报错** | `openFile` 遇目录返回 `cannot open file` | AI 被迫用 `Get-ChildItem -Recurse` 浏览目录，触发 bash 昂贵命令守卫 |

## 改动方案

### A: 按需读取 + 读上限安全网 (核心改动)

**原则**：只在必要时读必要的数据。常量定义：
- `MAX_BYTES = 50KB` — 文本内容输出上限
- `MAX_READ = 100KB` — 单次工具调用入内存总量上限（`MAX_BYTES × 2`）

```
头部读取方案 (offset=0, limit=0):
  1. 读头部 MAX_READ（100KB）用于检测
  2. 判断二进制 → 直接返回错误
  3. 判断文本 → truncateBytes 截断至 MAX_BYTES

行范围读取方案 (offset>0 或 limit>0):
  1. 读头部 4KB 检测二进制
  2. 从文件头开始逐 chunk 扫描，累计到目标 offset 后开始输出
  3. 累计入内存超过 MAX_READ 时截断
```

`offset` 较大时（如 100000）仍需从头扫描——行是变长记录，无行索引。读上限安全网兜底：扫描到 MAX_READ 还没到目标 offset 则报错截断。

### B: 预读二进制检测

读取文件头部 4096 字节后，在全文读取前执行两级检测：

1. **扩展名黑名单** — `.exe .dll .so .dylib .zip .tar .gz .7z .rar .bin .dat .wasm .pyc .pyo .class .jar .war .o .a .lib .obj .doc .docx .xls .xlsx .ppt .pptx .pdf`

2. **内容启发式** — 头部 4KB 检测：
   - 含 null 字节 (`\0`) → 二进制
   - 不可打印字符占比 >30% → 二进制（允许常见控制字符 `\t \n \r`）

命中任一级 → 返回 `"Error: cannot read binary file '{path}'"`

### C: UTF-8 校验

内容处理前调用 `std.unicode.utf8ValidateSlice(content)`。

校验失败 → 返回 `"Error: file is not valid UTF-8 at {path}"`

### D: 单行长度截断

行提取循环中追加判断：

```
if (line.len > 2000)
    → 截断为 line[0..2000] + " ... [truncated N chars]"
```

offset/limit 模式下也生效。

### E: offset 越界检测

读取前扫描文件统计总行数：

```
if (offset > total_lines)
    → 返回 "Error: offset {offset} is out of range (file has {total_lines} lines)"
```

### F: 截断提示修正

根据调用模式生成不同 note：

| 模式 | note |
|------|------|
| 无 offset/limit | `Output truncated at {N} bytes. Use read_file with offset={N} limit=2000 to continue.` |
| 仅 limit | `Output truncated at line {included}. Use read_file with offset={included+1} limit=2000 to continue.` |
| offset+limit | `Showing lines {offset}-{offset+limit-1}. Use read_file with offset={offset+limit} limit=2000 to continue.` |

### G: 目录浏览

**动机**：AI 常需浏览目录结构，但 `Get-ChildItem -Recurse` 被 bash 昂贵命令守卫拦截。与其让 AI 绕过守卫，不如让 `read_file` 直接支持目录。

**流程**：

```
args → 解析 → openFile 失败 → 尝试 openDir → 成功 → 列目录
                               └─ 失败 → 原报错路径
```

**列目录逻辑**：
- 支持 offset/limit 分页
- 排序：子目录在前，文件在后，各按名称字典序
- 不递归（只列一层），深度浏览靠多步调用
- 符号链接调用 `stat` 判断目标类型；`stat` 失败（损坏链接/权限不足）→ 标记为 `type: "unknown"`，不阻塞其他条目
- 不加 `total` 字段，AI 通过 `entries.len < limit` 判断是否到底，避免全目录遍历

**JSON 输出结构变更**：

```json
// 目录模式
{
  "path": ".opencode/loggers",
  "type": "directory",
  "entries": [
    {"name": "subdir", "type": "directory"},
    {"name": "access.zig", "type": "file"},
    {"name": "error.zig", "type": "file"}
  ],
  "offset": 0,
  "limit": 0
}

// 文件模式（不变）
{
  "path": "main.zig",
  "type": "file",
  "content": "const std = @import(\"std\");\n...",
  "offset": 0,
  "limit": 0,
  "truncated": false
}
```

**入口 dispatch**：`read_file` 先尝试 `openFile`，path 是目录时返回 `error.IsDir`（Windows）或 `error.AccessDenied`，此时降级为 `openDir` + 列目录。

**`tool_description` 更新**：

```
Read a file or list a directory from the filesystem. For text files, returns content
with optional offset/limit. For directories, lists entries with pagination.
For images (png/jpg/gif/webp/bmp), automatically encodes as base64 data URI.
```

**`tool_params` 不变**（path/offset/limit 参数对文件和目录都适用）。

### H: 空文件/空目录退化

| 场景 | 处理 |
|------|------|
| 空文件（size=0） | 跳过二进制检测和 UTF-8 校验，直接返回 `{"content": ""}` |
| 空目录 | 返回 `{"type": "directory", "entries": [], "offset": 0, "limit": 0}` |

### I: 用户显示简化

**现状**：`agent.zig:178-192` 硬编码 `read_file` 的显示逻辑，逐行输出文件内容给用户。

**改为**：在 `read.zig` 导出 `renderResult`，只显示摘要信息，不输出文件正文。

```
  ✓ src/main.zig                    (1.2 KB)
  ✓ src/main.zig  lines 50-100      (1.2 KB)
  ✓ .opencode/loggers/              (5 entries)
  ✓ logo.png                        (image, 18 KB)
  ✓ empty.md                        (0 bytes)
  ✗ app.exe                         (binary file)
  ✓ big.log  truncated.             Use offset=102400 limit=2000 to continue.
```

移入 `renderResult` 后删除 `agent.zig:178-192` 的 `read_file` 特殊分支。`buildHandler` 自动发现 `read.zig` 的 `renderResult` 声明，与 `skill`/`task` 一致的调用链。

## 文件范围

| 文件 | 改动量 | 说明 |
|------|--------|------|
| `src/tool/read.zig` | ~200行重写 | 新增目录分支 + A-F 优化 |
| `src/tool/truncate.zig` | 0行 | 不动 |
| `src/tool/read.zig` 测试 | 增补 | 覆盖目录/二进制/UTF-8/越界/行长截断 |

## 不改的

- `tool_name` 不变（仍为 `read_file`）
- `ToolResult` 接口不变
- `root_dir.resolvePath` 路径解析不变
- 图片处理逻辑不变
- 文本处理路径不变
