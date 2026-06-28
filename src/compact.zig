const std = @import("std");
const types = @import("types.zig");
const token = @import("tool/token.zig");
const retrieval = @import("retrieval.zig");
const provider = @import("provider.zig");

pub const CompactionResult = struct {
    summary: []const u8,
    keep_count: usize,
    dropped_count: usize,
    tokens_before: u32,
};

pub fn compact(
    allocator: std.mem.Allocator,
    io: std.Io,
    prov: provider.Provider,
    messages: *std.array_list.Managed(types.Message),
    context_limit: u32,
    max_tokens: u32,
    stdout: *std.Io.Writer,
) !?CompactionResult {
    const input_budget = if (context_limit > max_tokens) context_limit - max_tokens else context_limit;
    const threshold: usize = @intCast(@as(u64, input_budget) * 85 / 100);

    var total_est: usize = 0;
    for (messages.items) |*msg| total_est += estimateMsg(msg);
    if (total_est < threshold) return null;

    const keep_min: usize = 2;
    if (messages.items.len <= keep_min) return null;

    const compact_budget: usize = @intCast(@as(u64, input_budget) * 25 / 100);
    if (compact_budget < 500) return null;
    const has_system = messages.items.len > 0 and messages.items[0].role == .system;
    const sys_offset: usize = if (has_system) @as(usize, 1) else 0;

    // Build BM25 index
    var doc_contents = try allocator.alloc([]const u8, messages.items.len);
    var doc_count: usize = 0;
    defer {
        for (doc_contents[0..doc_count]) |d| allocator.free(d);
        allocator.free(doc_contents);
    }
    var docs = try allocator.alloc(retrieval.Document, messages.items.len - sys_offset);
    defer {
        for (docs) |d| allocator.free(d.id);
        allocator.free(docs);
    }
    for (messages.items[sys_offset..], 0..) |*msg, i| {
        var buf = std.array_list.Managed(u8).init(allocator);
        if (msg.content) |parts| for (parts) |p| if (p == .text) buf.appendSlice(p.text) catch {};
        const content = try buf.toOwnedSlice();
        doc_contents[i] = content;
        doc_count = i + 1;
        docs[i] = .{ .id = try std.fmt.allocPrint(allocator, "{d}", .{i + sys_offset}), .content = content };
    }

    // Build query from last 5 user/assistant
    var query_buf = std.array_list.Managed(u8).init(allocator);
    defer query_buf.deinit();
    var qc: usize = 0;
    var ri: usize = messages.items.len;
    while (qc < 5 and ri > 0) {
        ri -= 1;
        const msg = messages.items[ri];
        if (msg.role == .system or msg.role == .tool) continue;
        if (msg.content) |parts| for (parts) |p| if (p == .text) {
            query_buf.appendSlice(p.text) catch {};
            query_buf.append(' ') catch {};
            qc += 1;
            break;
        };
    }

    const scores = retrieval.search(allocator, query_buf.items, docs, docs.len) catch return null;
    defer {
        for (scores) |s| allocator.free(s.snippet);
        allocator.free(scores);
    }

    var score_map = std.AutoHashMap(usize, f64).init(allocator);
    defer score_map.deinit();
    for (scores) |s| {
        const idx = std.fmt.parseInt(usize, s.id, 10) catch continue;
        score_map.put(idx, s.score) catch {};
    }

    var keep = std.AutoHashMap(usize, void).init(allocator);
    defer keep.deinit();

    // Step 1: keep system message
    if (has_system) keep.put(0, {}) catch {};

    // Step 2: keep recent messages (walk backwards, 60% of compact_budget)
    const recent_budget: usize = compact_budget * 60 / 100;
    var recent_tokens: usize = 0;
    ri = messages.items.len;
    while (ri > sys_offset) {
        ri -= 1;
        if (keep.contains(ri)) continue;
        const m = &messages.items[ri];
        var pair_est: ?usize = null;
        if (m.role == .tool and ri > 0 and messages.items[ri - 1].tool_calls != null) {
            if (!keep.contains(ri - 1)) {
                pair_est = estimateMsg(m) + estimateMsg(&messages.items[ri - 1]);
            }
        }
        const est = pair_est orelse estimateMsg(m);
        if (recent_tokens + est > recent_budget) break;
        if (pair_est != null) keep.put(ri - 1, {}) catch {};
        keep.put(ri, {}) catch {};
        recent_tokens += est;
    }

    // Step 3: BM25 top picks — sort remaining by score, fill 30% of compact_budget
    const bm25_budget: usize = compact_budget * 30 / 100;
    var bm25_tokens: usize = 0;
    var sorted: []usize = try allocator.alloc(usize, messages.items.len);
    defer allocator.free(sorted);
    for (0..messages.items.len) |i| sorted[i] = i;
    const SC = struct {
        fn lt(map: *const std.AutoHashMap(usize, f64), a: usize, b: usize) bool {
            return (map.get(a) orelse 0.0) > (map.get(b) orelse 0.0);
        }
    };
    std.sort.insertion(usize, sorted, &score_map, SC.lt);

    for (sorted) |idx| {
        if (keep.contains(idx)) continue;
        if (bm25_tokens >= bm25_budget) break;
        const score = score_map.get(idx) orelse 0.0;
        if (score == 0.0) break;
        const est = estimateMsg(&messages.items[idx]);
        if (bm25_tokens + est > bm25_budget) break;
        keep.put(idx, {}) catch {};
        bm25_tokens += est;
    }

    // Step 4: extract user questions from discarded
    var questions_buf = std.array_list.Managed(u8).init(allocator);
    defer questions_buf.deinit();
    for (messages.items, 0..) |*msg, i| {
        if (keep.contains(i)) continue;
        if (msg.role != .user) continue;
        if (msg.content) |parts| for (parts) |p| if (p == .text) {
            if (p.text.len > 3 and questions_buf.items.len < 2000) {
                questions_buf.appendSlice(p.text) catch {};
                questions_buf.append('\n') catch {};
            }
        };
    }

    // Step 5: LLM summary of discarded
    var summary_input = std.array_list.Managed(u8).init(allocator);
    defer summary_input.deinit();
    summary_input.appendSlice("Summarize the following in 200 words or fewer. Include: key decisions made, bugs found and fixed, important context.\n\n") catch {};
    if (questions_buf.items.len > 0) {
        summary_input.appendSlice("Past user questions:\n") catch {};
        summary_input.appendSlice(questions_buf.items) catch {};
        summary_input.append('\n') catch {};
    }
    var dropped: usize = 0;
    for (messages.items, 0..) |*msg, i| {
        if (keep.contains(i)) continue;
        if (msg.role == .system) continue;
        if (msg.content) |parts| for (parts) |p| if (p == .text) {
            if (summary_input.items.len + p.text.len < 5000) {
                summary_input.appendSlice(@tagName(msg.role)) catch {};
                summary_input.appendSlice(": ") catch {};
                summary_input.appendSlice(p.text) catch {};
                summary_input.append('\n') catch {};
            }
            dropped += 1;
        };
    }

    const summary = blk: {
        if (summary_input.items.len < 60) break :blk try allocator.dupe(u8, "");
        const parts = try allocator.alloc(types.ContentPart, 1);
        parts[0] = .{ .text = summary_input.items };
        const msgs = try allocator.alloc(types.Message, 1);
        msgs[0] = .{ .role = .user, .content = parts };
        defer allocator.free(msgs);
        defer allocator.free(parts);
        const resp = prov.chatCompletionStreaming(allocator, io, msgs, stdout) catch |err| {
            try stdout.print("\n[压缩] 摘要生成失败: {}，跳过压缩\n", .{err});
            try stdout.flush();
            return null;
        };
        if (resp.content) |c| {
            break :blk try allocator.dupe(u8, c);
        } else {
            break :blk try allocator.dupe(u8, "");
        }
    };

    // Rebuild messages array
    var builder = std.array_list.Managed(types.Message).init(allocator);
    if (has_system) try builder.append(messages.items[0]);
    if (summary.len > 0) {
        const label = try std.fmt.allocPrint(allocator, "[压缩摘要] {s}", .{summary});
        defer allocator.free(label);
        const label_parts = try allocator.alloc(types.ContentPart, 1);
        label_parts[0] = .{ .text = label };
        try builder.append(.{ .role = .system, .content = label_parts });
    }
    for (messages.items, 0..) |*msg, i| {
        if (i < sys_offset) continue;
        if (keep.contains(i)) try builder.append(msg.*);
    }

    messages.clearAndFree();
    for (builder.items) |m| try messages.append(m);

    return CompactionResult{
        .summary = summary,
        .keep_count = keep.count(),
        .dropped_count = dropped,
        .tokens_before = @intCast(@min(total_est, std.math.maxInt(u32))),
    };
}

fn estimateMsg(msg: *const types.Message) usize {
    var est: usize = 50;
    if (msg.content) |parts| {
        for (parts) |p| {
            if (p == .text) est += token.estimate(p.text);
        }
    }
    if (msg.tool_calls) |tcs| {
        for (tcs) |tc| {
            est += token.estimate(tc.name) + token.estimate(tc.arguments);
        }
    }
    if (msg.tool_call_id) |id| est += token.estimate(id);
    return est;
}
