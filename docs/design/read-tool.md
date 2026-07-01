# read_file 工具设计

> 设计：2026-07-01 | 实现：`src/tool/read.zig` | 状态：已提交

---

## 1. 架构

```
execute(allocator, io, args)
  ├─ 解析 path/offset/limit
  ├─ root_dir.resolvePath
  ├─ [目录] openDir → listDir
  │     ├─ 遍历条目 → DirEntry[] → 排序 → offset/limit 分页
  │     └─ 返回 {path, type:"directory", entries, offset, limit}
  ├─ [文件] openFile → stat
  │     ├─ size==0 → {content:"", type:"file"}
  │     ├─ isImage → readPositionalAll → base64 → {image: data:uri}
  │     ├─ isBinary(extension + content heuristic) → Error
  │     ├─ offset==0 && limit==0 → 读头部 MAX_READ → UTF-8 check → truncate
  │     ├─ offset>0 || limit>0 → 逐 chunk 扫描行范围 → UTF-8 check
  │     └─ okJson → {path, type:"file", content, offset, limit, truncated, note?}
  └─ ToolResult.ok/fail

renderResult(allocator, stdout, json_str)
  └─ 用户显示摘要（不展示文件内容）
```

## 2. 常量

| 常量 | 值 | 用途 |
|------|-----|------|
| `MAX_BYTES` | 50 KB | 文本内容输出上限 |
| `MAX_READ` | 100 KB | 单次工具调用读入内存上限 |
| `MAX_LINE_LEN` | 2000 字符 | 单行截断 |
| `BINARY_CHECK_SIZE` | 4096 字节 | 二进制检测头 |
| `MAX_IMAGE_BYTES` | 20 MB | 图片大小上限 |
| `MAX_DIR_FILES` | 100 | 单次目录返回条目上限 |
| `READ_CHUNK` | 8 KB | 行扫描读取块大小 |

## 3. 特性

### A: 按需读取 + 读上限安全网

大文件只读头部 MAX_READ，不分配 `file_size`。offset 模式逐 chunk 扫描，累计超 MAX_READ 截断。

### B: 二进制检测

两级检测（扩展名优先，内容启发式兜底）：

1. **扩展名黑名单** — 30 个已知二进制扩展名（`.exe .dll .zip .tar .gz .7z .rar .bin .dat .wasm .pyc .pyo .class .jar .war .o .a .lib .obj .doc .docx .xls .xlsx .ppt .pptx .pdf .so .dylib`）
2. **内容启发式** — 头部 4096 字节：
   - null 字节 → 二进制
   - 不可打印字符（排除 `\t \n \r`）占比 >30% → 二进制

### C: UTF-8 校验

内容处理前调用 `std.unicode.utf8ValidateSlice`，失败返回错误。

### D: 单行长截断

行提取循环中每行超过 2000 字符时截断，追加 `... [truncated N chars]`。

### E: offset 越界检测

统计文件总行数，offset 超出时返回 `"offset X out of range (file has Y lines)"`。

### F: 截断提示上下文自适应

| 调用模式 | note |
|----------|------|
| 无 offset/limit | `Output truncated at 51200 bytes. Use read_file with offset=51200 limit=2000 to continue.` |
| 仅 limit | `Output truncated at line {N}. Use read_file with offset={N+1} limit=2000 to continue.` |
| offset+limit | `Showing lines {A}-{B}. Use read_file with offset={B+1} limit=2000 to continue.` |

### G: 目录浏览

**动机**：AI 用 `Get-ChildItem -Recurse` 浏览目录被 bash 昂贵命令守卫拦截。

**入口 dispatch**：先尝试 `openDir`，失败后 `openFile`。

**列目录逻辑**：
- 子目录在前，文件在后，各按名称字典序
- offset/limit 分页，不加 total 字段（AI 通过 `entries.len < limit` 判断）
- 不递归，深度浏览靠多次调用
- 符号链接：`openDir` 判断类型，失败标记 `type: "unknown"`
- 空目录返回 `{entries: []}`

### H: 空文件/空目录

空文件跳过二进制检测和 UTF-8 校验，直接 `{content: ""}`。空目录返回 `{entries: []}`。

### I: 用户显示

`renderResult` 只展示摘要，不输出文件正文：

```
  ✓ src/main.zig                    (1.2 KB)
  ✓ src/main.zig  lines 50-100      (1.2 KB)
  ✓ .opencode/loggers/              (5 entries)
  ✓ logo.png                        (image)
  ✓ empty.md                        (0 bytes)
  ✗ app.exe                         (binary file)
  ✓ big.log  truncated.             Use offset=102400 limit=2000 to continue.
```

## 4. JSON 输出

```json
// 文件模式
{"path":"src/main.zig","type":"file","content":"fn main...","offset":0,"limit":0,"truncated":false}

// 目录模式
{"path":"src/","type":"directory","entries":[{"name":"subdir","type":"directory"},{"name":"main.zig","type":"file"}],"offset":0,"limit":0}

// 图片模式
{"path":"logo.png","type":"file","image":"data:image/png;base64,..."}
```

## 5. 测试

| 测试 | 覆盖 |
|------|------|
| nonexistent file | 错误路径 — 文件不存在 |
| binary detection extension | 4 个已知二进制扩展名 |
| binary detection null byte | null 字节内容检测 |
| binary detection text pass | 纯文本不误判 |
| isImage | 6 个图片扩展名 / 非图片 |
| formatSize | 0 B / KB 格式 |
| escapeJson | 特殊字符转义 |
| generateNote | 3 种模式的 note 格式 |
