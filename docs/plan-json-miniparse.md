# P3 — `json_miniparse` 零分配字段提取

## 1. 现状分析

当前工具参数解析流程：

```
tc.arguments (JSON string)
    → registry.execute() parseFromSliceLeaky → std.json.Value tree (一次分配)
    → 各工具 execute()  args.object.get("field") → 导航已有 Value 树（O(1) 查表）
```

`parseFromSliceLeaky` 是一次性分配整个 JSON AST。后续 `object.get()` 走哈希表 O(1) 查找，不追加分配。

**实际开销**：
- 工具参数通常 1-3 个简单字段（path/pattern/content），JSON 字符串 50-200 字节
- 分配成本：Value tree 约 200-800 字节（小对象）
- 遍历回收由 `testing.allocator` 或 arena 统一处理

**结论**：当前方案对工具参数场景影响极小，P3 的边际收益有限。

## 2. 何时有用

以下场景从零分配解析获益更大：

- bash 工具返回大批量 JSON（`parseFromSlice` 多次解析测试中的大 JSON）
- 对大 JSON 只需提取单字段（如从 500KB 响应中取 `stdout` 字段）
- 内存受限环境（WASI、嵌入式）

以上场景当前不构成瓶颈。

## 3. API 设计（如实施）

```zig
// src/tool/json_miniparse.zig

/// 从 JSON 字符串按 key 读取字符串字段值（零分配，返回原串切片）
/// 注意：返回的 slice 指向原 json 参数，调用方不可 free
pub fn parseStringField(json: []const u8, key: []const u8) ?[]const u8;

/// 同上，读取整数字段
pub fn parseIntField(json: []const u8, key: []const u8) ?i64;

/// 同上，读取布尔字段
pub fn parseBoolField(json: []const u8, key: []const u8) ?bool;
```

实现策略：手动扫描 JSON 字符串查找 `"key":` 模式，跳过字符串转义，直接提取值切片。不建 AST，不分配内存。

```zig
fn parseStringField(json: []const u8, key: []const u8) ?[]const u8 {
    const key_pattern = try std.fmt.bufPrint(&buf, "\"{s}\"", .{key});
    const pos = std.mem.indexOf(u8, json, key_pattern) orelse return null;
    // 跳过 key_pattern + ":" + 空白 + "\""
    var idx = pos + key_pattern.len;
    idx = skipWhitespace(json, idx);
    if (json[idx] != ':') return null;
    idx += 1;
    idx = skipWhitespace(json, idx);
    if (json[idx] != '"') return null;
    idx += 1;
    const start = idx;
    // 扫描到闭合引号，处理转义
    while (idx < json.len) {
        if (json[idx] == '\\') { idx += 2; continue; }
        if (json[idx] == '"') break;
        idx += 1;
    }
    return json[start..idx];
}
```

## 4. 决策

**暂不实施**。理由：

- 当前工具参数 JSON 小于 200 字节，`parseFromSliceLeaky` 分配可忽略
- `std.json.Value.object.get()` 已是 O(1) 无额外分配
- 零分配解析对正确性要求高（转义、嵌套、Unicode），实现成本 vs 收益不成比例

**保留为未来选项**：当出现以下信号时重新评估：
- 工具开始处理 >100KB 的 JSON 输入
- 内存 profile 显示 JSON 解析占可观测比例
- 需要 WASI/嵌入式部署

## 5. 替代方案

如需在当前场景优化 JSON 解析，更直接的方案是**减少 parseFromSliceLeaky 调用次数**而非替代它。当前 `registry.execute()` 已只在 dispatch 时解析一次 args；工具内的 `parseFromSlice` 调基本只出现在测试代码中。
