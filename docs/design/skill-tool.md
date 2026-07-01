# skill 工具设计

> 设计：2026-07-01 | 实现：`src/tool/skill.zig` + `src/skill.zig` + `src/system.zig` | 状态：已提交

---

## 1. 架构

### 1.1 整体流程

```
system prompt ──→ <available_skills>  (仅 name + description + location)
                         │
                  LLM 判断需要技能
                         │
                  调用 skill({"name":"zig-dev"})
                         │
               ┌─────────┴─────────┐
               ▼                   ▼
       src/tool/skill.zig     src/skill.zig
       (读取 SKILL.md         (技能发现 + 解析
        + 目录扫描)            + dedupLastWins)
               │
               ▼
       JSON 返回给 LLM:
       {name, content, files: [{path, content}]}
```

### 1.2 模块职责

| 模块 | 职责 | 关键函数 |
|------|------|----------|
| `src/skill.zig` | 技能发现、解析、内置技能 | `loadAvailable`, `parseSkillMd`, `dedupLastWins`, `getBuiltinSkills` |
| `src/tool/skill.zig` | LLM 工具接口 | `execute`, `renderResult` |
| `src/system.zig` | system prompt 中渲染技能列表 | `<available_skills>` 块 |
| `src/App.zig` | 启动时加载技能列表 | `available_skills` 字段 |

## 2. 技能发现 (`src/skill.zig`)

### 2.1 发现路径

```
启动时:
  fs_skills = loadAvailable(".zagent/skills/")
    └─ 遍历一级子目录，每个目录找 SKILL.md
    └─ 解析 frontmatter (name + description)
    └─ dedupLastWins → 同名后者覆盖前者

  builtin_skills = getBuiltinSkills()
    └─ 编译时嵌入的 z-improve 技能

  合并: builtin 先入 → fs_skills 覆盖（同名时后胜）
```

### 2.2 路径解析

```
.zagent/skills/<slug>/SKILL.md

slug = 目录名（每个技能一个目录）
SKILL.md 必须含 frontmatter: name + description
```

### 2.3 dedupLastWins

遍历 skill 列表（逆序），同名 slug 保留最后出现的、删除前面的。用于 filesystem 覆盖 built-in。

## 3. 工具执行 (`src/tool/skill.zig`)

### 3.1 输入

```
skill({"name": "<skill-name>"})
```

参数：`name` — 技能名（对应 `<available_skills>` 中的 name）

### 3.2 输出 JSON

```json
{
  "name": "zig-dev",
  "content": "# Skill: zig-dev\n\n## ...",
  "files": [
    {"path": "references/tool-dev-spec.md", "content": "..."},
    {"path": "references/common-traps.md", "content": "..."}
  ]
}
```

| 字段 | 说明 |
|------|------|
| `name` | 技能名称 |
| `content` | SKILL.md 完整内容（含 frontmatter） |
| `files` | 同目录下最多 5 个相关文件（排除 SKILL.md） |

### 3.3 目录扫描

读取 SKILL.md 后，以 SKILL.md 所在目录为 base 扫描文件：

| 规则 | 说明 |
|------|------|
| 数量上限 | 5 个文件 |
| 排除 | `SKILL.md` 自身 |
| 大小上限 | 16 KB/文件，超过截断 + `truncated: true` |
| 二进制过滤 | 扩展名：`.png .jpg .jpeg .gif .ico .bmp .webp .exe .dll .bin .zip .tar .gz .pdf` |
| 内容过滤 | 含 null 字节或控制字符 → 跳过 |

### 3.4 renderResult

用户显示：打印 skill 名称、SKILL.md 内容、附带文件列表：

```
  [zig-dev]
  | # Skill: zig-dev
  | ...
  references/tool-dev-spec.md
  | # Tool dev spec
  | ...
```

### 3.5 错误处理

| 场景 | 处理 |
|------|------|
| 缺少 name | 返回 Error |
| 技能不存在 | 返回 Error（含路径） |
| 目录扫描失败 | 非致命 — 仍返回 SKILL.md 内容 |

## 4. System Prompt 中的技能列表 (`src/system.zig`)

```xml
<available_skills>
  <skill>
    <name>zig-dev</name>
    <description>Zig 开发编排</description>
    <location>file:///.../.opencode/skills/zig-dev/SKILL.md</location>
  </skill>
  <skill>
    <name>zig-code-review</name>
    <description>Zig 审查清单</description>
    <location>file:///.../.opencode/skills/zig-code-review/SKILL.md</location>
  </skill>
</available_skills>
```

Skills provide specialized instructions and workflows for specific tasks.
Use the skill tool to load a skill when a task matches its description.

**设计要点**：
- 只注入元数据（name + description + location），不注入内容 — 懒加载
- `<location>` 字段于 2026-07-01 加，帮助 LLM 理解技能归属（built-in vs 项目级）
- 工具描述由 API `tools` 参数下发，不与 system prompt 重复

## 5. 与 OpenCode 的对比

| 维度 | z-agent | OpenCode |
|------|---------|----------|
| 发现路径 | `.zagent/skills/<name>/SKILL.md` | `skill{,s}/**/SKILL.md` + `~/.claude/skills/` + 远程 URL |
| 返回内容 | SKILL.md + 最多 5 个目录文件 | SKILL.md + 最多 10 个目录文件 |
| 远程技能 | 不支持 | 支持 `index.json` manifest 下载 |
| 压缩保护 | 不需要（重载成本极低） | `PRUNE_PROTECTED_TOOLS = ["skill"]` |
| system prompt | `<name>+<description>+<location>` XML | `<name>+<description>+<location>` XML |
| 权限 | 无 | 全局 disable + agent permission |

## 6. 测试

| 测试 | 覆盖 |
|------|------|
| missing name | 入参缺少 name → Error |
| unknown skill | 不存在的技能 → Error |
| escapeSkillString | 特殊字符转义 |
| parseFrontmatter | LF/CRLF/缺失字段/无 frontmatter |
| dedupLastWins | 同名 slug 后胜 |
| getBuiltinSkills | z-improve 内建技能加载 |
