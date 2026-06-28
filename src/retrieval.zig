const std = @import("std");

pub const Document = struct {
    id: []const u8,
    content: []const u8,
};

pub const ScoredDoc = struct {
    id: []const u8,
    score: f64,
    snippet: []const u8,
};

const BM25_K1: f64 = 1.2;
const BM25_B: f64 = 0.75;
const RELATIVE_FLOOR: f64 = 0.15;

fn isLatin(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_';
}

fn isCJK(cp: u21) bool {
    return (cp >= 0x4E00 and cp <= 0x9FFF) or
        (cp >= 0x3400 and cp <= 0x4DBF) or
        (cp >= 0x20000 and cp <= 0x2A6DF) or
        (cp >= 0xF900 and cp <= 0xFAFF) or
        (cp >= 0x3040 and cp <= 0x309F) or
        (cp >= 0x30A0 and cp <= 0x30FF) or
        (cp >= 0xAC00 and cp <= 0xD7AF);
}

fn toLower(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

const Token = struct {
    start: usize,
    end: usize,
};

pub fn tokenize(allocator: std.mem.Allocator, text: []const u8) ![]Token {
    var list = std.array_list.Managed(Token).init(allocator);
    defer list.deinit();

    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        if (isLatin(c)) {
            const start = i;
            while (i < text.len and isLatin(text[i])) : (i += 1) {}
            const end = i;
            // Lowercase the token in-place (we'll dup it later)
            try list.append(.{ .start = start, .end = end });
        } else {
            const cp_len = std.unicode.utf8ByteSequenceLength(c) catch 1;
            const cl: usize = @intCast(cp_len);
            if (cl > 0 and i + cl <= text.len) {
                const cp = std.unicode.utf8Decode(text[i .. i + cl]) catch 0;
                if (isCJK(cp)) {
                    try list.append(.{ .start = i, .end = i + cl });
                    i += cl;
                    continue;
                }
            }
            i += 1;
        }
    }

    return list.toOwnedSlice();
}

fn tokenText(text: []const u8, tok: Token) []const u8 {
    const raw = text[tok.start..tok.end];
    return raw;
}

pub fn search(allocator: std.mem.Allocator, query: []const u8, docs: []const Document, top_k: usize) ![]ScoredDoc {
    if (docs.len == 0 or query.len == 0) return &[_]ScoredDoc{};

    const q_tokens = try tokenize(allocator, query);
    defer allocator.free(q_tokens);

    var doc_tokens = try allocator.alloc([]Token, docs.len);
    defer allocator.free(doc_tokens);
    var doc_lens = try allocator.alloc(f64, docs.len);
    defer allocator.free(doc_lens);

    var total_len: f64 = 0;
    for (docs, 0..) |doc, idx| {
        doc_tokens[idx] = try tokenize(allocator, doc.content);
        doc_lens[idx] = @floatFromInt(doc_tokens[idx].len);
        total_len += doc_lens[idx];
    }
    defer for (doc_tokens) |t| allocator.free(t);

    const avgdl = if (docs.len > 0) total_len / @as(f64, @floatFromInt(docs.len)) else 1.0;

    var idf_map = std.StringHashMapUnmanaged(f64){};
    defer {
        var it = idf_map.keyIterator();
        while (it.next()) |key| allocator.free(key.*);
        idf_map.deinit(allocator);
    }
    for (q_tokens) |qt| {
        const term = tokenText(query, qt);
        if (idf_map.contains(term)) continue;
        var df: usize = 0;
        for (doc_tokens, 0..) |dt, doc_idx| {
            for (dt) |tok| {
                const doc_term = tokenText(docs[doc_idx].content, tok);
                if (tokenEq(term, doc_term, docs[doc_idx].content, tok)) {
                    df += 1;
                    break;
                }
            }
        }
        const n = @as(f64, @floatFromInt(docs.len));
        const df_f = @as(f64, @floatFromInt(df));
        const idf = @max(0.0, @log((n - df_f + 0.5) / (df_f + 0.5) + 1.0));
        const key = try allocator.dupe(u8, term);
        try idf_map.put(allocator, key, idf);
    }

    const k1 = BM25_K1;
    const b = BM25_B;

    var scores = try allocator.alloc(ScoredDoc, docs.len);
    defer allocator.free(scores);
    for (docs, 0..) |doc, idx| {
        var score: f64 = 0;
        const tokens = doc_tokens[idx];
        for (q_tokens) |qt| {
            const term = tokenText(query, qt);
            const idf = idf_map.get(term) orelse continue;
            var tf: usize = 0;
            for (tokens) |tok| {
                const doc_term = tokenText(doc.content, tok);
                if (tokenEq(term, doc_term, doc.content, tok)) tf += 1;
            }
            if (tf == 0) continue;
            const tf_f = @as(f64, @floatFromInt(tf));
            const len = doc_lens[idx];
            score += idf * (tf_f * (k1 + 1)) / (tf_f + k1 * (1 - b + b * len / avgdl));
        }
        scores[idx] = .{ .id = doc.id, .score = score, .snippet = extractSnippet(allocator, doc.content, q_tokens, query) catch allocator.dupe(u8, "") catch "" };
    }

    std.sort.insertion(ScoredDoc, scores, {}, lessThan);

    const max_score = if (scores.len > 0) scores[0].score else 0;
    const threshold = max_score * RELATIVE_FLOOR;
    var count: usize = 0;
    for (scores) |s| {
        if (s.score < threshold or count >= top_k) break;
        count += 1;
    }

    const result = try allocator.alloc(ScoredDoc, count);
    @memcpy(result, scores[0..count]);
    for (scores[count..]) |s| allocator.free(s.snippet);
    return result;
}

fn tokenEq(q_term: []const u8, d_term: []const u8, doc_content: []const u8, tok: Token) bool {
    _ = doc_content;
    _ = tok;
    if (q_term.len != d_term.len) return false;
    if (isLatin(q_term[0])) {
        // Case-insensitive for Latin
        for (q_term, d_term) |qc, dc| {
            if (toLower(qc) != toLower(dc)) return false;
        }
        return true;
    }
    return std.mem.eql(u8, q_term, d_term);
}

fn lessThan(_: void, a: ScoredDoc, b: ScoredDoc) bool {
    return a.score > b.score;
}

fn extractSnippet(allocator: std.mem.Allocator, content: []const u8, q_tokens: []const Token, query: []const u8) ![]const u8 {
    if (q_tokens.len == 0) return content;

    var best_start: usize = 0;
    var best_end: usize = @min(content.len, 200);
    var best_score: usize = 0;

    const window: usize = 200;
    var pos: usize = 0;
    while (pos + 50 < content.len) : (pos += 50) {
        const end = @min(pos + window, content.len);
        var score: usize = 0;
        for (q_tokens) |qt| {
            const term = tokenText(query, qt);
            if (searchText(content[pos..end], term)) score += 1;
        }
        if (score > best_score) {
            best_score = score;
            best_start = pos;
            best_end = end;
        }
    }

    if (best_score == 0) return allocator.dupe(u8, content[0..@min(content.len, 200)]);

    const snippet = content[best_start..best_end];
    return allocator.dupe(u8, snippet);
}

fn searchText(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return false;
    if (!isLatin(needle[0])) {
        return std.mem.indexOf(u8, haystack, needle) != null;
    }
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var match = true;
        for (needle, 0..) |nc, j| {
            if (toLower(haystack[i + j]) != toLower(nc)) {
                match = false;
                break;
            }
        }
        if (match) return true;
    }
    return false;
}

test "tokenize: Latin words" {
    const t = try tokenize(std.testing.allocator, "hello world zig123");
    defer std.testing.allocator.free(t);
    try std.testing.expectEqual(@as(usize, 3), t.len);
}

test "tokenize: CJK chars" {
    const t = try tokenize(std.testing.allocator, "编译错误修复");
    defer std.testing.allocator.free(t);
    try std.testing.expect(t.len >= 4);
}

test "tokenize: mixed Latin and CJK" {
    const t = try tokenize(std.testing.allocator, "Zig 编译 build 错误");
    defer std.testing.allocator.free(t);
    try std.testing.expect(t.len >= 4);
}

test "search: returns scored results" {
    const a = std.testing.allocator;
    const docs = [_]Document{
        .{ .id = "1", .content = "hello world foo bar baz" },
        .{ .id = "2", .content = "hello zig compile error" },
        .{ .id = "3", .content = "unrelated content here" },
    };
    const results = try search(a, "zig error", &docs, 2);
    defer {
        for (results) |r| a.free(r.snippet);
        a.free(results);
    }
    try std.testing.expect(results.len > 0);
    try std.testing.expectEqualStrings("2", results[0].id);
}

test "search: empty query returns empty" {
    const docs = [_]Document{ .{ .id = "1", .content = "hello" } };
    const results = try search(std.testing.allocator, "", &docs, 5);
    defer std.testing.allocator.free(results);
    try std.testing.expectEqual(@as(usize, 0), results.len);
}
