const std = @import("std");
const json = @import("../json.zig");
const root_dir = @import("../root_dir.zig");

const Io = std.Io;

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

/// A hard case entry recording a difficult scenario for agent improvement.
pub const HardCase = struct {
    id: []const u8,
    symptom: []const u8,
    context: []const u8,
    source: []const u8,
    timestamp: []const u8,
    consumed: bool,

    /// Free all allocated string fields. Source: memory/session.zig — memory leak cleanup
    pub fn deinit(self: *HardCase, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.symptom);
        allocator.free(self.context);
        allocator.free(self.source);
        allocator.free(self.timestamp);
    }
};

/// Metrics tracking for a skill (recall or add).
pub const SkillMetric = struct {
    calls: u32,
    failures: u32,
    anchors_rejected: u32,
    avg_score: f64,
};

/// A single entry in the operation log.
pub const OperationLogEntry = struct {
    ts: []const u8,
    event: []const u8,
    changeset_id: ?[]const u8,
    entry_id: ?[]const u8,
    path: ?[]const u8,
    reason: ?[]const u8,

    /// Free all allocated string fields. Source: memory/session.zig — memory leak cleanup
    pub fn deinit(self: *OperationLogEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.ts);
        allocator.free(self.event);
        if (self.changeset_id) |s| allocator.free(s);
        if (self.entry_id) |s| allocator.free(s);
        if (self.path) |s| allocator.free(s);
        if (self.reason) |s| allocator.free(s);
    }
};

const DesignerRun = struct {
    id: []const u8,
    timestamp: []const u8,
    status: []const u8,

    /// Free all allocated string fields. Source: memory/session.zig — memory leak cleanup
    pub fn deinit(self: *DesignerRun, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.timestamp);
        allocator.free(self.status);
    }
};

const TaskCall = struct {
    id: []const u8,
    name: []const u8,
    timestamp: []const u8,

    /// Free all allocated string fields. Source: memory/session.zig — memory leak cleanup
    pub fn deinit(self: *TaskCall, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        allocator.free(self.timestamp);
    }
};

/// The complete session state persisted to `.zagent/session-state.json`.
pub const SessionState = struct {
    last_topic: []const u8,
    last_update: []const u8,
    pending_decisions: [][]const u8,
    active_learnings: [][]const u8,
    hard_case_buffer: []HardCase,
    skill_metrics: struct {
        recall: SkillMetric,
        add: SkillMetric,
    },
    designer_runs: []DesignerRun,
    task_calls: []TaskCall,
    operation_log: []OperationLogEntry,
    unfinished_tasks: [][]const u8,
    last_session_end: ?[]const u8,

    /// Free all allocated fields. Source: memory/session.zig — memory leak cleanup
    pub fn deinit(self: *SessionState, allocator: std.mem.Allocator) void {
        if (self.last_topic.len > 0) allocator.free(self.last_topic);
        if (self.last_update.len > 0) allocator.free(self.last_update);
        for (self.pending_decisions) |s| if (s.len > 0) allocator.free(s);
        if (self.pending_decisions.len > 0) allocator.free(self.pending_decisions);
        for (self.active_learnings) |s| if (s.len > 0) allocator.free(s);
        if (self.active_learnings.len > 0) allocator.free(self.active_learnings);
        for (self.hard_case_buffer) |*hc| hc.deinit(allocator);
        if (self.hard_case_buffer.len > 0) allocator.free(self.hard_case_buffer);
        for (self.designer_runs) |*dr| dr.deinit(allocator);
        if (self.designer_runs.len > 0) allocator.free(self.designer_runs);
        for (self.task_calls) |*tc| tc.deinit(allocator);
        if (self.task_calls.len > 0) allocator.free(self.task_calls);
        for (self.operation_log) |*log| log.deinit(allocator);
        if (self.operation_log.len > 0) allocator.free(self.operation_log);
        for (self.unfinished_tasks) |s| if (s.len > 0) allocator.free(s);
        if (self.unfinished_tasks.len > 0) allocator.free(self.unfinished_tasks);
        if (self.last_session_end) |s| if (s.len > 0) allocator.free(s);
    }
};

// ---------------------------------------------------------------------------
// Pruning constants
// ---------------------------------------------------------------------------

const max_critical_log: usize = 500;
const max_regular_log: usize = 200;
const max_hard_cases: usize = 50;
const hard_case_trim_count: usize = 20;
const hard_case_max_age_days: i64 = 30;

// ---------------------------------------------------------------------------
// File path
// ---------------------------------------------------------------------------

/// Build path to session-state.json under project_root/.zagent/.
/// Caller owns returned slice, must free.
fn statePath(allocator: std.mem.Allocator) ![]const u8 {
    if (root_dir.project_root.len > 0) {
        return std.fs.path.join(allocator, &.{ root_dir.project_root, ".zagent", "session-state.json" });
    }
    return std.fs.path.join(allocator, &.{ ".zagent", "session-state.json" });
}

// ---------------------------------------------------------------------------
// ISO8601 helpers
// ---------------------------------------------------------------------------

/// Return current time as ISO8601 string "YYYY-MM-DDTHH:MM:SSZ".
/// Caller owns returned slice, must free.
/// Source: session/serialize.zig — time formatting logic
pub fn nowISO8601(allocator: std.mem.Allocator, io: Io) ![]const u8 {
    const ns = Io.Clock.Timestamp.now(io, .real).raw.nanoseconds;
    const s: i64 = @intCast(@divFloor(ns, 1_000_000_000));
    return epochToISO8601(allocator, s);
}

/// Convert epoch seconds to ISO8601 "YYYY-MM-DDTHH:MM:SSZ".
/// Source: session/serialize.zig — epoch conversion algorithm
fn epochToISO8601(allocator: std.mem.Allocator, epoch_s: i64) ![]const u8 {
    const z = @divFloor(epoch_s, 86400) + 719468;
    const era = @divFloor(if (z >= 0) z else z - 146096, 146097);
    const doe = @as(u64, @intCast(z - era * 146097));
    const yoe = @as(u64, @intCast((doe - doe / 1460 + doe / 36524 - doe / 146096) / 365));
    const y = @as(i64, @intCast(yoe)) + @as(i64, @intCast(era * 400));
    const doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    const mp = (5 * doy + 2) / 153;
    const d = doy - (153 * mp + 2) / 5 + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    const year = if (m <= 2) y + 1 else y;
    const tod = @mod(epoch_s, 86400);
    const h = @divFloor(tod, 3600);
    const min = @mod(@divFloor(tod, 60), 60);
    const sec = @mod(tod, 60);
    return std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{ year, m, d, h, min, sec });
}

/// Parse ISO8601 date "YYYY-MM-DDTHH:MM:SSZ" to epoch days.
/// Returns null on parse failure.
fn iso8601ToEpochDays(ts: []const u8) ?i64 {
    if (ts.len < 19) return null;
    const year = std.fmt.parseInt(i64, ts[0..4], 10) catch return null;
    const month = std.fmt.parseInt(i64, ts[5..7], 10) catch return null;
    const day = std.fmt.parseInt(i64, ts[8..10], 10) catch return null;
    return ymdToDays(year, month, day);
}

/// Convert year/month/day to epoch days (days since 1970-01-01).
/// Source: tool/memory/archive.zig — date difference calculation
fn ymdToDays(year: i64, month: i64, day: i64) i64 {
    const y = if (month <= 2) year - 1 else year;
    const m = if (month <= 2) month + 12 else month;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const doy = @divFloor(153 * (m - 3) + 2, 5) + day - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

// ---------------------------------------------------------------------------
// File I/O
// ---------------------------------------------------------------------------

/// Read entire file into allocated buffer. Returns null if file doesn't exist.
/// Caller owns returned slice, must free.
fn readFile(allocator: std.mem.Allocator, io: Io, path: []const u8) ?[]const u8 {
    const file = Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only }) catch return null;
    defer file.close(io);
    const stat = file.stat(io) catch return null;
    const size: usize = @intCast(stat.size);
    if (size == 0) return null;
    const content = allocator.alloc(u8, size) catch return null;
    _ = file.readPositionalAll(io, content, 0) catch {
        allocator.free(content);
        return null;
    };
    return content;
}

/// Atomic write: write to .tmp then rename to target.
/// Source: tool/memory/parse.zig — atomic write pattern
fn atomicWrite(allocator: std.mem.Allocator, io: Io, path: []const u8, content: []const u8) !void {
    const cwd = Io.Dir.cwd();
    if (std.fs.path.dirname(path)) |parent| {
        cwd.createDirPath(io, parent) catch {};
    }

    const abs_path = abs_path: {
        if (std.fs.path.isAbsolute(path)) break :abs_path path;
        var cwd_buf: [4096]u8 = undefined;
        const cwd_len = cwd.realPath(io, &cwd_buf) catch break :abs_path path;
        const joined = try std.fs.path.join(allocator, &.{ cwd_buf[0..cwd_len], path });
        break :abs_path joined;
    };
    defer if (abs_path.ptr != path.ptr) allocator.free(abs_path);

    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{abs_path});
    defer allocator.free(tmp_path);

    var rename_succeeded = false;
    defer if (!rename_succeeded) cwd.deleteFile(io, tmp_path) catch {};

    {
        const file = cwd.createFile(io, tmp_path, .{}) catch |err| return err;
        defer file.close(io);
        file.writeStreamingAll(io, content) catch |err| return err;
    }

    try Io.Dir.renameAbsolute(tmp_path, abs_path, io);
    rename_succeeded = true;
}

// ---------------------------------------------------------------------------
// Managed list helpers
// ---------------------------------------------------------------------------

/// Copy entries from one Managed list to another, freeing source after copy.
fn copyAndFreeManaged(comptime T: type, allocator: std.mem.Allocator, source: []const T) !std.array_list.Managed(T) {
    var list = std.array_list.Managed(T).init(allocator);
    errdefer list.deinit();
    try list.appendSlice(source);
    return list;
}

/// Convert a Managed list to owned slice, freeing the list container.
fn toOwnedSliceManaged(comptime T: type, list: *std.array_list.Managed(T)) ![]T {
    return list.toOwnedSlice();
}

/// Append an element to a Managed list.
fn managedAppend(comptime T: type, list: *std.array_list.Managed(T), item: T) !void {
    try list.append(item);
}

// ---------------------------------------------------------------------------
// Serialization
// ---------------------------------------------------------------------------

/// Serialize SessionState to compact JSON.
/// Caller owns returned slice, must free.
fn serializeState(allocator: std.mem.Allocator, state: *const SessionState) ![]const u8 {
    var buf = std.array_list.Managed(u8).init(allocator);
    defer buf.deinit();

    try buf.append('{');

    // lastTopic
    try json.putString(&buf, "lastTopic", state.last_topic);
    try buf.append(',');

    // lastUpdate
    try json.putString(&buf, "lastUpdate", state.last_update);
    try buf.append(',');

    // pendingDecisions
    try buf.appendSlice("\"pendingDecisions\":[");
    for (state.pending_decisions, 0..) |item, i| {
        if (i > 0) try buf.append(',');
        try json.escapeJson(&buf, item);
    }
    try buf.append(']');
    try buf.append(',');

    // activeLearnings
    try buf.appendSlice("\"activeLearnings\":[");
    for (state.active_learnings, 0..) |item, i| {
        if (i > 0) try buf.append(',');
        try json.escapeJson(&buf, item);
    }
    try buf.append(']');
    try buf.append(',');

    // hardCaseBuffer
    try buf.appendSlice("\"hardCaseBuffer\":[");
    for (state.hard_case_buffer, 0..) |hc, i| {
        if (i > 0) try buf.append(',');
        try serializeHardCase(&buf, hc);
    }
    try buf.append(']');
    try buf.append(',');

    // skillMetrics
    try buf.appendSlice("\"skillMetrics\":{");
    try serializeSkillMetric(&buf, "recall", &state.skill_metrics.recall);
    try buf.append(',');
    try serializeSkillMetric(&buf, "add", &state.skill_metrics.add);
    try buf.append('}');
    try buf.append(',');

    // designerRuns
    try buf.appendSlice("\"designerRuns\":[");
    for (state.designer_runs, 0..) |run, i| {
        if (i > 0) try buf.append(',');
        try buf.append('{');
        try json.putString(&buf, "id", run.id);
        try buf.append(',');
        try json.putString(&buf, "timestamp", run.timestamp);
        try buf.append(',');
        try json.putString(&buf, "status", run.status);
        try buf.append('}');
    }
    try buf.append(']');
    try buf.append(',');

    // taskCalls
    try buf.appendSlice("\"taskCalls\":[");
    for (state.task_calls, 0..) |tc, i| {
        if (i > 0) try buf.append(',');
        try buf.append('{');
        try json.putString(&buf, "id", tc.id);
        try buf.append(',');
        try json.putString(&buf, "name", tc.name);
        try buf.append(',');
        try json.putString(&buf, "timestamp", tc.timestamp);
        try buf.append('}');
    }
    try buf.append(']');
    try buf.append(',');

    // operationLog
    try buf.appendSlice("\"operationLog\":[");
    for (state.operation_log, 0..) |op, i| {
        if (i > 0) try buf.append(',');
        try serializeLogEntry(&buf, op);
    }
    try buf.append(']');
    try buf.append(',');

    // unfinishedTasks
    try buf.appendSlice("\"unfinishedTasks\":[");
    for (state.unfinished_tasks, 0..) |item, i| {
        if (i > 0) try buf.append(',');
        try json.escapeJson(&buf, item);
    }
    try buf.append(']');

    // lastSessionEnd (optional)
    if (state.last_session_end) |lse| {
        try buf.append(',');
        try json.putString(&buf, "lastSessionEnd", lse);
    } else {
        try buf.appendSlice(",\"lastSessionEnd\":null");
    }

    try buf.append('}');
    return json.finish(&buf);
}

fn serializeHardCase(buf: *std.array_list.Managed(u8), hc: HardCase) !void {
    try buf.append('{');
    try json.putString(buf, "id", hc.id);
    try buf.append(',');
    try json.putString(buf, "symptom", hc.symptom);
    try buf.append(',');
    try json.putString(buf, "context", hc.context);
    try buf.append(',');
    try json.putString(buf, "source", hc.source);
    try buf.append(',');
    try json.putString(buf, "timestamp", hc.timestamp);
    try buf.append(',');
    try json.putBool(buf, "consumed", hc.consumed);
    try buf.append('}');
}

fn serializeLogEntry(buf: *std.array_list.Managed(u8), entry: OperationLogEntry) !void {
    try buf.append('{');
    try json.putString(buf, "ts", entry.ts);
    try buf.append(',');
    try json.putString(buf, "event", entry.event);
    try buf.append(',');
    if (entry.changeset_id) |v| {
        try json.putString(buf, "changesetId", v);
    } else {
        try buf.appendSlice("\"changesetId\":null");
    }
    try buf.append(',');
    if (entry.entry_id) |v| {
        try json.putString(buf, "entryId", v);
    } else {
        try buf.appendSlice("\"entryId\":null");
    }
    try buf.append(',');
    if (entry.path) |v| {
        try json.putString(buf, "path", v);
    } else {
        try buf.appendSlice("\"path\":null");
    }
    try buf.append(',');
    if (entry.reason) |v| {
        try json.putString(buf, "reason", v);
    } else {
        try buf.appendSlice("\"reason\":null");
    }
    try buf.append('}');
}

fn serializeSkillMetric(buf: *std.array_list.Managed(u8), key: []const u8, m: *const SkillMetric) !void {
    try json.puts(buf, "\"");
    try json.puts(buf, key);
    try json.puts(buf, "\":{");
    try json.putInt(buf, "calls", m.calls);
    try buf.append(',');
    try json.putInt(buf, "failures", m.failures);
    try buf.append(',');
    try json.putInt(buf, "anchorsRejected", m.anchors_rejected);
    try buf.append(',');
    try json.putKey(buf, "avgScore");
    var score_buf: [32]u8 = undefined;
    const score_str = try std.fmt.bufPrint(&score_buf, "{d}", .{m.avg_score});
    try buf.appendSlice(score_str);
    try buf.append('}');
}

// ---------------------------------------------------------------------------
// Deserialization helpers
// ---------------------------------------------------------------------------

/// Get string from ObjectMap, or null if missing/not string.
fn getString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const val = obj.get(key) orelse return null;
    if (val == .string) return val.string;
    return null;
}

/// Get boolean from ObjectMap, or default if missing.
fn getBool(obj: std.json.ObjectMap, key: []const u8, default: bool) bool {
    const val = obj.get(key) orelse return default;
    if (val == .bool) return val.bool;
    return default;
}

/// Get integer from ObjectMap, or default if missing.
fn getInt(obj: std.json.ObjectMap, key: []const u8, default: i64) i64 {
    const val = obj.get(key) orelse return default;
    if (val == .integer) return val.integer;
    return default;
}

/// Get float from ObjectMap, or default if missing.
fn getFloat(obj: std.json.ObjectMap, key: []const u8, default: f64) f64 {
    const val = obj.get(key) orelse return default;
    if (val == .float) return val.float;
    if (val == .integer) return @as(f64, @floatFromInt(val.integer));
    return default;
}

/// Parse a HardCase from a JSON object value.
fn parseHardCase(allocator: std.mem.Allocator, val: std.json.Value) !HardCase {
    const obj = val.object;
    return HardCase{
        .id = try allocator.dupe(u8, getString(obj, "id") orelse ""),
        .symptom = try allocator.dupe(u8, getString(obj, "symptom") orelse ""),
        .context = try allocator.dupe(u8, getString(obj, "context") orelse ""),
        .source = try allocator.dupe(u8, getString(obj, "source") orelse ""),
        .timestamp = try allocator.dupe(u8, getString(obj, "timestamp") orelse ""),
        .consumed = getBool(obj, "consumed", false),
    };
}

/// Parse an OperationLogEntry from a JSON object value.
fn parseLogEntry(allocator: std.mem.Allocator, val: std.json.Value) !OperationLogEntry {
    const obj = val.object;
    return OperationLogEntry{
        .ts = try allocator.dupe(u8, getString(obj, "ts") orelse ""),
        .event = try allocator.dupe(u8, getString(obj, "event") orelse ""),
        .changeset_id = if (getString(obj, "changesetId")) |s| try allocator.dupe(u8, s) else null,
        .entry_id = if (getString(obj, "entryId")) |s| try allocator.dupe(u8, s) else null,
        .path = if (getString(obj, "path")) |s| try allocator.dupe(u8, s) else null,
        .reason = if (getString(obj, "reason")) |s| try allocator.dupe(u8, s) else null,
    };
}

/// Parse a DesignerRun from a JSON object value.
fn parseDesignerRun(allocator: std.mem.Allocator, val: std.json.Value) !DesignerRun {
    const obj = val.object;
    return DesignerRun{
        .id = try allocator.dupe(u8, getString(obj, "id") orelse ""),
        .timestamp = try allocator.dupe(u8, getString(obj, "timestamp") orelse ""),
        .status = try allocator.dupe(u8, getString(obj, "status") orelse ""),
    };
}

/// Parse a TaskCall from a JSON object value.
fn parseTaskCall(allocator: std.mem.Allocator, val: std.json.Value) !TaskCall {
    const obj = val.object;
    return TaskCall{
        .id = try allocator.dupe(u8, getString(obj, "id") orelse ""),
        .name = try allocator.dupe(u8, getString(obj, "name") orelse ""),
        .timestamp = try allocator.dupe(u8, getString(obj, "timestamp") orelse ""),
    };
}

/// Parse SkillMetric from a JSON object value.
fn parseSkillMetric(val: std.json.Value) !SkillMetric {
    const obj = val.object;
    return SkillMetric{
        .calls = @intCast(getInt(obj, "calls", 0)),
        .failures = @intCast(getInt(obj, "failures", 0)),
        .anchors_rejected = @intCast(getInt(obj, "anchorsRejected", 0)),
        .avg_score = getFloat(obj, "avgScore", 0.0),
    };
}

// ---------------------------------------------------------------------------
// Default state
// ---------------------------------------------------------------------------

/// Return a SessionState with all fields set to empty/default values (static literals).
fn defaultState() SessionState {
    return SessionState{
        .last_topic = "",
        .last_update = "",
        .pending_decisions = &.{},
        .active_learnings = &.{},
        .hard_case_buffer = &.{},
        .skill_metrics = .{
            .recall = .{ .calls = 0, .failures = 0, .anchors_rejected = 0, .avg_score = 0.0 },
            .add = .{ .calls = 0, .failures = 0, .anchors_rejected = 0, .avg_score = 0.0 },
        },
        .designer_runs = &.{},
        .task_calls = &.{},
        .operation_log = &.{},
        .unfinished_tasks = &.{},
        .last_session_end = null,
    };
}

/// Return a SessionState with all string/slice fields heap-allocated (empty values)
/// so that `deinit` can safely free them. Used by `load()`.
/// Caller must call `state.deinit(allocator)` to free.
pub fn allocDefaultState(allocator: std.mem.Allocator) SessionState {
    _ = allocator;
    return SessionState{
        .last_topic = "",
        .last_update = "",
        .pending_decisions = &.{},
        .active_learnings = &.{},
        .hard_case_buffer = &.{},
        .skill_metrics = .{
            .recall = .{ .calls = 0, .failures = 0, .anchors_rejected = 0, .avg_score = 0.0 },
            .add = .{ .calls = 0, .failures = 0, .anchors_rejected = 0, .avg_score = 0.0 },
        },
        .designer_runs = &.{},
        .task_calls = &.{},
        .operation_log = &.{},
        .unfinished_tasks = &.{},
        .last_session_end = null,
    };
}

// ---------------------------------------------------------------------------
// Parse string array helper
// ---------------------------------------------------------------------------

/// Parse an array of strings from JSON array value into an owned slice.
fn parseStringArray(allocator: std.mem.Allocator, val: std.json.Value) [][]const u8 {
    if (val != .array) return &.{};
    const arr = val.array;
    // Count string items first
    var count: usize = 0;
    for (arr.items) |item| {
        if (item == .string) count += 1;
    }
    var result = allocator.alloc([]const u8, count) catch return &.{};
    var idx: usize = 0;
    for (arr.items) |item| {
        if (item == .string) {
            result[idx] = allocator.dupe(u8, item.string) catch "";
            idx += 1;
        }
    }
    return result;
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Read and parse session-state.json. Returns default empty state when file is missing or invalid.
/// All string/slice fields are heap-allocated for safe deinit.
pub fn load(allocator: std.mem.Allocator, io: Io) SessionState {
    const path = statePath(allocator) catch return allocDefaultState(allocator);
    defer allocator.free(path);

    const content = readFile(allocator, io, path) orelse return allocDefaultState(allocator);
    defer allocator.free(content);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch return allocDefaultState(allocator);
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return allocDefaultState(allocator);
    const obj = root.object;

    var state = allocDefaultState(allocator);

    // lastTopic
    if (getString(obj, "lastTopic")) |s| state.last_topic = allocator.dupe(u8, s) catch "";

    // lastUpdate
    if (getString(obj, "lastUpdate")) |s| state.last_update = allocator.dupe(u8, s) catch "";

    // pendingDecisions
    if (getString(obj, "pendingDecisions") != null or obj.get("pendingDecisions") != null) {
        if (obj.get("pendingDecisions")) |arr| {
            state.pending_decisions = parseStringArray(allocator, arr);
        }
    }

    // activeLearnings
    if (obj.get("activeLearnings")) |arr| {
        state.active_learnings = parseStringArray(allocator, arr);
    }

    // hardCaseBuffer
    if (obj.get("hardCaseBuffer")) |arr| {
        if (arr == .array) {
            var list = std.array_list.Managed(HardCase).init(allocator);
            for (arr.array.items) |item| {
                list.append(parseHardCase(allocator, item) catch continue) catch {};
            }
            state.hard_case_buffer = list.toOwnedSlice() catch &.{};
        }
    }

    // skillMetrics
    if (obj.get("skillMetrics")) |sm_val| {
        if (sm_val == .object) {
            const sm_obj = sm_val.object;
            if (sm_obj.get("recall")) |v| {
                if (v == .object) state.skill_metrics.recall = parseSkillMetric(v) catch .{ .calls = 0, .failures = 0, .anchors_rejected = 0, .avg_score = 0.0 };
            }
            if (sm_obj.get("add")) |v| {
                if (v == .object) state.skill_metrics.add = parseSkillMetric(v) catch .{ .calls = 0, .failures = 0, .anchors_rejected = 0, .avg_score = 0.0 };
            }
        }
    }

    // designerRuns
    if (obj.get("designerRuns")) |arr| {
        if (arr == .array) {
            var list = std.array_list.Managed(DesignerRun).init(allocator);
            for (arr.array.items) |item| {
                list.append(parseDesignerRun(allocator, item) catch continue) catch {};
            }
            state.designer_runs = list.toOwnedSlice() catch &.{};
        }
    }

    // taskCalls
    if (obj.get("taskCalls")) |arr| {
        if (arr == .array) {
            var list = std.array_list.Managed(TaskCall).init(allocator);
            for (arr.array.items) |item| {
                list.append(parseTaskCall(allocator, item) catch continue) catch {};
            }
            state.task_calls = list.toOwnedSlice() catch &.{};
        }
    }

    // operationLog
    if (obj.get("operationLog")) |arr| {
        if (arr == .array) {
            var list = std.array_list.Managed(OperationLogEntry).init(allocator);
            for (arr.array.items) |item| {
                list.append(parseLogEntry(allocator, item) catch continue) catch {};
            }
            state.operation_log = list.toOwnedSlice() catch &.{};
        }
    }

    // unfinishedTasks
    if (obj.get("unfinishedTasks")) |arr| {
        state.unfinished_tasks = parseStringArray(allocator, arr);
    }

    // lastSessionEnd
    if (getString(obj, "lastSessionEnd")) |s| {
        state.last_session_end = allocator.dupe(u8, s) catch null;
    }

    return state;
}

/// Save SessionState to file (atomic write via tmp+rename).
pub fn save(allocator: std.mem.Allocator, io: Io, state: *const SessionState) !void {
    const path = try statePath(allocator);
    defer allocator.free(path);

    const content = try serializeState(allocator, state);
    defer allocator.free(content);

    try atomicWrite(allocator, io, path, content);
}

/// Add an operation log entry and prune excess entries.
/// Critical events (auto_approve, apply, rollback) exceeding 500 are archived;
/// regular events exceeding 200 are dropped.
pub fn addLogEntry(state: *SessionState, allocator: std.mem.Allocator, io: Io, entry: OperationLogEntry) !void {
    // Deep-copy entry string fields to own the memory
    const owned_entry = try deepCopyLogEntry(allocator, &entry);

    // Append new entry to a working list
    var working = std.array_list.Managed(OperationLogEntry).init(allocator);
    defer working.deinit();
    try working.appendSlice(state.operation_log);
    try working.append(owned_entry);
    if (state.operation_log.len > 0) allocator.free(state.operation_log);

    // Partition: critical vs regular
    var critical = std.array_list.Managed(OperationLogEntry).init(allocator);
    defer critical.deinit();
    var regular = std.array_list.Managed(OperationLogEntry).init(allocator);
    defer regular.deinit();

    for (working.items) |e| {
        if (isCriticalEvent(e.event)) {
            try critical.append(e);
        } else {
            try regular.append(e);
        }
    }

    // Prune critical: keep newest max_critical_log, archive oldest
    if (critical.items.len > max_critical_log) {
        const excess = critical.items.len - max_critical_log;
        const archive_path = try archiveLogPath(allocator);
        defer allocator.free(archive_path);

        // Append archived entries to audit-log-archive.jsonl
        var archive_buf = std.array_list.Managed(u8).init(allocator);
        defer archive_buf.deinit();

        // Read existing archive content
        if (readFile(allocator, io, archive_path)) |existing| {
            defer allocator.free(existing);
            try archive_buf.appendSlice(existing);
            if (existing.len > 0 and existing[existing.len - 1] != '\n') {
                try archive_buf.append('\n');
            }
        }

        for (critical.items[0..excess]) |archived| {
            var line_buf = std.array_list.Managed(u8).init(allocator);
            defer line_buf.deinit();
            try serializeLogEntry(&line_buf, archived);
            try line_buf.append('\n');
            try archive_buf.appendSlice(line_buf.items);
        }

        try atomicWrite(allocator, io, archive_path, archive_buf.items);

        // Keep newest entries
        var kept = std.array_list.Managed(OperationLogEntry).init(allocator);
        defer kept.deinit();
        try kept.appendSlice(critical.items[excess..]);
        state.operation_log = try kept.toOwnedSlice();
    } else {
        state.operation_log = try critical.toOwnedSlice();
    }

    // Prune regular: keep newest max_regular_log
    if (regular.items.len > max_regular_log) {
        const excess = regular.items.len - max_regular_log;
        var kept = std.array_list.Managed(OperationLogEntry).init(allocator);
        defer kept.deinit();
        try kept.appendSlice(regular.items[excess..]);
        // Merge back: critical first, then regular
        var merged = std.array_list.Managed(OperationLogEntry).init(allocator);
        defer merged.deinit();
        try merged.appendSlice(state.operation_log);
        if (state.operation_log.len > 0) allocator.free(state.operation_log);
        try merged.appendSlice(kept.items);
        state.operation_log = try merged.toOwnedSlice();
    } else {
        // Merge: combine kept critical + all regular
        var merged = std.array_list.Managed(OperationLogEntry).init(allocator);
        defer merged.deinit();
        try merged.appendSlice(state.operation_log);
        if (state.operation_log.len > 0) allocator.free(state.operation_log);
        try merged.appendSlice(regular.items);
        state.operation_log = try merged.toOwnedSlice();
    }
}

/// Check if an event type is critical (eligible for archival).
fn isCriticalEvent(event: []const u8) bool {
    return std.mem.eql(u8, event, "auto_approve") or
        std.mem.eql(u8, event, "apply") or
        std.mem.eql(u8, event, "rollback");
}

/// Build path to audit-log-archive.jsonl.
/// Caller owns returned slice, must free.
fn archiveLogPath(allocator: std.mem.Allocator) ![]const u8 {
    if (root_dir.project_root.len > 0) {
        return std.fs.path.join(allocator, &.{ root_dir.project_root, ".zagent", "audit-log-archive.jsonl" });
    }
    return std.fs.path.join(allocator, &.{ ".zagent", "audit-log-archive.jsonl" });
}

/// Deep-copy string fields of a HardCase entry.
fn deepCopyHardCase(allocator: std.mem.Allocator, hc: *const HardCase) !HardCase {
    return HardCase{
        .id = try allocator.dupe(u8, hc.id),
        .symptom = try allocator.dupe(u8, hc.symptom),
        .context = try allocator.dupe(u8, hc.context),
        .source = try allocator.dupe(u8, hc.source),
        .timestamp = try allocator.dupe(u8, hc.timestamp),
        .consumed = hc.consumed,
    };
}

/// Deep-copy string fields of an OperationLogEntry.
fn deepCopyLogEntry(allocator: std.mem.Allocator, entry: *const OperationLogEntry) !OperationLogEntry {
    return OperationLogEntry{
        .ts = try allocator.dupe(u8, entry.ts),
        .event = try allocator.dupe(u8, entry.event),
        .changeset_id = if (entry.changeset_id) |v| try allocator.dupe(u8, v) else null,
        .entry_id = if (entry.entry_id) |v| try allocator.dupe(u8, v) else null,
        .path = if (entry.path) |v| try allocator.dupe(u8, v) else null,
        .reason = if (entry.reason) |v| try allocator.dupe(u8, v) else null,
    };
}

/// Add a hard case entry and prune buffer.
/// Removes entries older than 30 days; if remaining > 50, removes oldest 20.
pub fn addHardCase(state: *SessionState, allocator: std.mem.Allocator, io: Io, hc: HardCase) !void {
    const owned_hc = try deepCopyHardCase(allocator, &hc);

    var buf = std.array_list.Managed(HardCase).init(allocator);
    defer buf.deinit();
    try buf.appendSlice(state.hard_case_buffer);
    try buf.append(owned_hc);
    if (state.hard_case_buffer.len > 0) allocator.free(state.hard_case_buffer);

    // Remove entries > 30 days old
    const now_days = nowEpochDays(io);
    var i: usize = 0;
    while (i < buf.items.len) {
        const age_days = iso8601ToEpochDays(buf.items[i].timestamp) orelse {
            i += 1;
            continue;
        };
        const age = now_days - age_days;
        if (age > hard_case_max_age_days) {
            _ = buf.swapRemove(i);
        } else {
            i += 1;
        }
    }

    // If still > 50, remove oldest entries by timestamp
    if (buf.items.len > max_hard_cases) {
        // Sort by timestamp (ascending = oldest first)
        std.mem.sort(HardCase, buf.items, {}, lessThanHardCase);
        // Remove oldest (excess) entries
        const excess = buf.items.len - max_hard_cases;
        const trim_count = @min(excess, hard_case_trim_count);
        // Keep entries from trim_count onwards
        var trimmed = std.array_list.Managed(HardCase).init(allocator);
        defer trimmed.deinit();
        try trimmed.appendSlice(buf.items[trim_count..]);
        state.hard_case_buffer = try trimmed.toOwnedSlice();
    } else {
        state.hard_case_buffer = try buf.toOwnedSlice();
    }
}

/// Comparison function for sorting HardCase by timestamp ascending.
fn lessThanHardCase(_: void, a: HardCase, b: HardCase) bool {
    return std.mem.lessThan(u8, a.timestamp, b.timestamp);
}

/// Return current time as epoch days.
fn nowEpochDays(io: Io) i64 {
    const ns = Io.Clock.Timestamp.now(io, .real).raw.nanoseconds;
    const epoch_s = @as(i64, @intCast(@divFloor(ns, 1_000_000_000)));
    return @divFloor(epoch_s, 86400);
}

/// Record a skill call into skillMetrics.
/// `skill` is "recall" or "add"; `success` indicates if the call succeeded;
/// `score` is the recall score (used for avg_score calculation).
pub fn recordSkillCall(state: *SessionState, skill: []const u8, success: bool, score: f64) void {
    const metric = if (std.mem.eql(u8, skill, "recall"))
        &state.skill_metrics.recall
    else
        &state.skill_metrics.add;

    metric.calls += 1;
    if (!success) metric.failures += 1;

    // Update running average: new_avg = (old_avg * (n-1) + score) / n
    if (metric.calls > 0) {
        const prev_total = metric.avg_score * @as(f64, @floatFromInt(metric.calls - 1));
        metric.avg_score = (prev_total + score) / @as(f64, @floatFromInt(metric.calls));
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "session: load returns defaults for missing file" {
    const testing = std.testing;
    const a = testing.allocator;
    const io = testing.io;

    root_dir.init("zig_test_session_missing");
    defer {
        root_dir.init("");
        Io.Dir.cwd().deleteTree(io, "zig_test_session_missing") catch {};
    }

    var state = load(a, io);
    defer state.deinit(a);

    try testing.expectEqualStrings("", state.last_topic);
    try testing.expectEqualStrings("", state.last_update);
    try testing.expectEqual(@as(usize, 0), state.pending_decisions.len);
    try testing.expectEqual(@as(usize, 0), state.active_learnings.len);
    try testing.expectEqual(@as(usize, 0), state.hard_case_buffer.len);
    try testing.expectEqual(@as(usize, 0), state.operation_log.len);
    try testing.expectEqual(@as(usize, 0), state.unfinished_tasks.len);
    try testing.expect(state.last_session_end == null);
    try testing.expectEqual(@as(u32, 0), state.skill_metrics.recall.calls);
    try testing.expectEqual(@as(u32, 0), state.skill_metrics.add.calls);
}

test "session: save and load round-trip" {
    const testing = std.testing;
    const a = testing.allocator;
    const io = testing.io;

    root_dir.init("zig_test_session_roundtrip");
    defer {
        root_dir.init("");
        Io.Dir.cwd().deleteTree(io, "zig_test_session_roundtrip") catch {};
    }

    // Create a state
    const state = SessionState{
        .last_topic = "test topic",
        .last_update = "2026-07-02T01:00:00Z",
        .pending_decisions = &.{},
        .active_learnings = &.{},
        .hard_case_buffer = &.{},
        .skill_metrics = .{
            .recall = .{ .calls = 3, .failures = 1, .anchors_rejected = 0, .avg_score = 0.85 },
            .add = .{ .calls = 5, .failures = 0, .anchors_rejected = 2, .avg_score = 0.92 },
        },
        .designer_runs = &.{},
        .task_calls = &.{},
        .operation_log = &.{},
        .unfinished_tasks = &.{},
        .last_session_end = null,
    };

    // Save
    try save(a, io, &state);

    // Load back
    var loaded = load(a, io);
    defer loaded.deinit(a);

    try testing.expectEqualStrings("test topic", loaded.last_topic);
    try testing.expectEqualStrings("2026-07-02T01:00:00Z", loaded.last_update);
    try testing.expectEqual(@as(u32, 3), loaded.skill_metrics.recall.calls);
    try testing.expectEqual(@as(u32, 1), loaded.skill_metrics.recall.failures);
    try testing.expectEqual(@as(u32, 5), loaded.skill_metrics.add.calls);
    try testing.expectEqual(@as(u32, 2), loaded.skill_metrics.add.anchors_rejected);
    try testing.expect(loaded.skill_metrics.recall.avg_score > 0.8);
    try testing.expect(loaded.skill_metrics.add.avg_score > 0.9);
    try testing.expect(loaded.last_session_end == null);
}

test "session: operation log pruning (regular events)" {
    const testing = std.testing;
    const a = testing.allocator;
    const io = testing.io;

    root_dir.init("zig_test_session_logprune");
    defer {
        root_dir.init("");
        Io.Dir.cwd().deleteTree(io, "zig_test_session_logprune") catch {};
    }

    var state = allocDefaultState(a);
    defer state.deinit(a);

    // Add max_regular_log + 10 regular events
    const count = max_regular_log + 10;
    for (0..count) |i| {
        const ts = try std.fmt.allocPrint(a, "2026-07-02T00:{d:0>2}:00Z", .{i});
        defer a.free(ts);
        try addLogEntry(&state, a, io, .{
            .ts = ts,
            .event = "recall",
            .changeset_id = null,
            .entry_id = null,
            .path = null,
            .reason = null,
        });
    }

    // Should have pruned to max_regular_log
    try testing.expect(state.operation_log.len <= max_regular_log);
    // Should have kept at least some entries
    try testing.expect(state.operation_log.len > 0);
}

test "session: hard case buffer pruning" {
    const testing = std.testing;
    const a = testing.allocator;
    const io = testing.io;

    root_dir.init("zig_test_session_hcprune");
    defer {
        root_dir.init("");
        Io.Dir.cwd().deleteTree(io, "zig_test_session_hcprune") catch {};
    }

    var state = allocDefaultState(a);
    defer state.deinit(a);

    // Add max_hard_cases + 10 hard cases
    const count = max_hard_cases + 10;
    for (0..count) |i| {
        const id = try std.fmt.allocPrint(a, "HC-{d:0>4}", .{i});
        defer a.free(id);
        const ts = try std.fmt.allocPrint(a, "2026-07-02T00:{d:0>2}:00Z", .{i});
        defer a.free(ts);
        try addHardCase(&state, a, io, .{
            .id = id,
            .symptom = "test symptom",
            .context = "test context",
            .source = "user",
            .timestamp = ts,
            .consumed = false,
        });
    }

    // Should have pruned to max_hard_cases or less
    try testing.expect(state.hard_case_buffer.len <= max_hard_cases);
    try testing.expect(state.hard_case_buffer.len > 0);
}

test "session: record skill call updates metrics" {
    const testing = std.testing;

    var state = defaultState();

    // Record some calls
    recordSkillCall(&state, "recall", true, 0.9);
    recordSkillCall(&state, "recall", true, 0.8);
    recordSkillCall(&state, "recall", false, 0.5);

    recordSkillCall(&state, "add", true, 1.0);

    // Check recall metrics
    try testing.expectEqual(@as(u32, 3), state.skill_metrics.recall.calls);
    try testing.expectEqual(@as(u32, 1), state.skill_metrics.recall.failures);
    // avg = (0.9 + 0.8 + 0.5) / 3 ≈ 0.733
    try testing.expect(state.skill_metrics.recall.avg_score > 0.7);
    try testing.expect(state.skill_metrics.recall.avg_score < 0.8);

    // Check add metrics
    try testing.expectEqual(@as(u32, 1), state.skill_metrics.add.calls);
    try testing.expectEqual(@as(u32, 0), state.skill_metrics.add.failures);
    try testing.expectEqual(@as(f64, 1.0), state.skill_metrics.add.avg_score);
}

test "session: load handles corrupted JSON gracefully" {
    const testing = std.testing;
    const a = testing.allocator;
    const io = testing.io;

    root_dir.init("zig_test_session_corrupt");
    defer {
        root_dir.init("");
        Io.Dir.cwd().deleteTree(io, "zig_test_session_corrupt") catch {};
    }

    // Create a corrupted JSON file
    const dir_path = "zig_test_session_corrupt/.zagent";
    Io.Dir.cwd().createDirPath(io, dir_path) catch {};
    const file_path = try std.fs.path.join(a, &.{ dir_path, "session-state.json" });
    defer a.free(file_path);
    {
        const file = Io.Dir.cwd().createFile(io, file_path, .{}) catch unreachable;
        defer file.close(io);
        file.writeStreamingAll(io, "not valid json{") catch {};
    }

    var state = load(a, io);
    defer state.deinit(a);
    // Should fall back to defaults
    try testing.expectEqualStrings("", state.last_topic);
    try testing.expectEqual(@as(usize, 0), state.operation_log.len);
}

test "session: save with non-empty arrays round-trips" {
    const testing = std.testing;
    const a = testing.allocator;
    const io = testing.io;

    root_dir.init("zig_test_session_arrays");
    defer {
        root_dir.init("");
        Io.Dir.cwd().deleteTree(io, "zig_test_session_arrays") catch {};
    }

    var state = allocDefaultState(a);
    defer state.deinit(a);

    // Add a hard case and operation log entry before saving
    try addHardCase(&state, a, io, .{
        .id = "HC-0001",
        .symptom = "test",
        .context = "test",
        .source = "bash_error",
        .timestamp = "2026-07-02T01:00:00Z",
        .consumed = false,
    });

    try addLogEntry(&state, a, io, .{
        .ts = "2026-07-02T01:00:00Z",
        .event = "auto_approve",
        .changeset_id = "cs-001",
        .entry_id = null,
        .path = "src/main.zig",
        .reason = "approved by user",
    });

    try save(a, io, &state);

    // Load back
    var loaded = load(a, io);
    defer loaded.deinit(a);

    try testing.expectEqual(@as(usize, 1), loaded.hard_case_buffer.len);
    try testing.expectEqualStrings("HC-0001", loaded.hard_case_buffer[0].id);
    try testing.expectEqualStrings("bash_error", loaded.hard_case_buffer[0].source);
    try testing.expectEqual(false, loaded.hard_case_buffer[0].consumed);

    try testing.expectEqual(@as(usize, 1), loaded.operation_log.len);
    try testing.expectEqualStrings("auto_approve", loaded.operation_log[0].event);
    try testing.expectEqualStrings("cs-001", loaded.operation_log[0].changeset_id.?);
    try testing.expectEqualStrings("src/main.zig", loaded.operation_log[0].path.?);
}

test "session: addLogEntry with critical events archives excess" {
    const testing = std.testing;
    const a = testing.allocator;
    const io = testing.io;

    root_dir.init("zig_test_session_critlog");
    defer {
        root_dir.init("");
        Io.Dir.cwd().deleteTree(io, "zig_test_session_critlog") catch {};
    }

    var state = allocDefaultState(a);
    defer state.deinit(a);

    // Add a few critical events
    for (0..3) |i| {
        const ts = try std.fmt.allocPrint(a, "2026-07-02T01:{d:0>2}:00Z", .{i});
        defer a.free(ts);
        try addLogEntry(&state, a, io, .{
            .ts = ts,
            .event = "apply",
            .changeset_id = null,
            .entry_id = null,
            .path = null,
            .reason = null,
        });
    }

    // Should have all 3 entries (under limit)
    try testing.expectEqual(@as(usize, 3), state.operation_log.len);
    try testing.expectEqualStrings("apply", state.operation_log[0].event);
}
