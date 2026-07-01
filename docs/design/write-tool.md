# write_file 工具设计

> 设计：2026-07-01 | 实现：`src/tool/write.zig` | 状态：已提交

---

## 1. 架构

```
execute(allocator, io, args)
  ├─ 解析 path/content
  ├─ 验证 path/content 非空
  ├─ root_dir.resolvePath
  ├─ createDirPath（自动创建父目录）
  ├─ createFile → writeStreamingAll → close
  └─ JSON: {path, bytes, content_preview}

printToolResult 显示:
  ✓ N bytes → path
  | content_preview（前 200 行预览）
```

## 2. 常量

| 常量 | 值 | 用途 |
|------|-----|------|
| `PREVIEW_BYTES` | 200 | content_preview 前 N 字节 |

## 3. 现状

| # | 特性 | 说明 |
|---|------|------|
| ① | 父目录自动创建 | `createDirPath` 递归创建缺失的父目录 |
| ② | content_preview | 返回内容前 200 字节用于用户预览 |
| ③ | 参数验证 | 缺失 path/content 时返回错误 |
| ④ | OOM 保护 | 所有 `catch` 路径返回友好错误 |

## 4. 未实现 / 改进空间

### A: 内容大小上限

当前无内容大小限制。LLM 可能一次写入数 MB 内容，导致：
- 工具执行缓慢
- OOM 风险
- 用户无感知大文件写入

建议：设置 `MAX_WRITE = 512 KB`，超限时返回错误，提示分块写入或二进制文件。

### B: 二进制内容检测

当前工具参数中 content 为 string 类型，二进制字节可能被 JSON 解析破坏（null 字节、无效 UTF-8 序列）。两种方案：

| 方案 | 描述 |
|------|------|
| 保持现状 | string 类型限制写入文本内容，二进制用其他工具处理 |
| 支持 base64 | 增加 `binary_base64` 参数，LLM 传 base64，工具解码后写入 |

建议：保持现状（`content` 为 string），如需写二进制文件使用外部工具。

### C: 原子写入

当前 `createFile` 直接覆写目标文件。与 edit_file 相同的改进方案：

```
write_content → createFile(path.tmp) → writeStreamingAll → close
→ renameAbsolute(path.tmp, path) → 完成
```

### D: renderResult

当前 `write_file` 无 `renderResult`，使用 `printToolResult` 通用渲染。可提取独立 renderResult 获得更灵活的展示控制（如颜色、格式）。

### E: content_preview 按码点截断

当前 `content_preview` 取前 200 **字节**，可能切碎多字节 UTF-8 字符（如中文 3 字节）。应改为按 Unicode 码点截断（与 read_file 一致）：

```zig
const preview_len = std.unicode.utf8ByteSequenceLengthSequence(content.string, 200) catch 200;
```

### F: 覆盖确认

write_file 覆盖已存在文件时不告警。对于关键文件（如 `.zagent/config.toml`、`src/*.zig`），建议在权限系统或工具层增加确认机制。

| 场景 | 当前行为 | 建议 |
|------|---------|------|
| 新文件 | 写入 | 保持 |
| 覆盖已存在 | 静默覆盖 | 通过权限系统 `ask` 规则确认 |

### G: 行结尾自动化

与 edit_file 一致，检测目标文件已有行结尾（LF/CRLF），新写入内容的换行符自动适配。但 write_file 是创建或全量覆写，行结尾应由 LLM 控制，不宜自动转换。**决定：不自动转换。**

## 5. JSON 输出

```json
// 成功
{"path":"src/main.zig","bytes":1234,"content_preview":"const std = @import(\"std\");\n\npub fn main() !void {\n    _ = std.io.getStdOut().writer().print(\"hello\\n\", .{});\n}\n"}

// 成功（无 preview）
{"path":"src/main.zig","bytes":0}

// 失败
Error: cannot write file 'src/main.zig': AccessDenied
```

## 6. 不改的

- `tool_name`、`tool_description`、`tool_params` 不变
- `ToolResult` 接口不变
- `root_dir.resolvePath` 不变
- 行结尾不自动转换（§G）

## 7. 测试

| 测试 | 覆盖 |
|------|------|
| 基本写入 | 创建文件，验证 JSON 含 path/bytes/content_preview |
| 缺失 path | 返回 Error |
| 缺失 content | 返回 Error |
| 大文件超限 | (实施 A 后) 超 MAX_WRITE 返回 Error |
| 父目录自动创建 | 写入深层路径，验证目录被创建 |
| content_preview 空 | 空内容写入，验证 bytes=0 |
