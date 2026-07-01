const std = @import("std");

/// Counter for seeding the PRNG, incremented on each computeBackoff call.
/// Used to produce varied jitter values without an external entropy source.
var rng_counter: u64 = 0;

/// Classifies API error responses into actionable categories.
/// Used by callWithRetry to decide retry policy and generate user-facing messages.
pub const ErrorKind = enum {
    auth_failed, // 401/403 - API key invalid
    rate_limited, // 429 with quota message - insufficient_quota
    rate_limited_retry, // 429 without quota - retry with Retry-After
    context_exceeded, // 400 with context_length_exceeded
    server_error, // 5xx
    network_error, // connection timeout/refused/DNS
    sse_interrupted, // SSE stream broke mid-data
    unknown, // other errors
};

/// Classify API error from status code and response body.
/// body may be empty if not captured. Checks body keywords first, then status code.
/// Source: docs/PLAN-RETRY.md — P0 error classification rules.
pub fn classify(status_code: u16, body: []const u8) ErrorKind {
    // Check body keywords first for specific error types
    if (std.mem.indexOf(u8, body, "insufficient_quota") != null or
        std.mem.indexOf(u8, body, "quota exceeded") != null or
        std.mem.indexOf(u8, body, "billing") != null)
    {
        return .rate_limited;
    }
    if (std.mem.indexOf(u8, body, "context_length_exceeded") != null or
        std.mem.indexOf(u8, body, "maximum context length") != null)
    {
        return .context_exceeded;
    }
    if (std.mem.indexOf(u8, body, "invalid_api_key") != null or
        std.mem.indexOf(u8, body, "authentication") != null or
        std.mem.indexOf(u8, body, "permission") != null)
    {
        return .auth_failed;
    }
    // Classify by status code
    if (status_code == 401 or status_code == 403) return .auth_failed;
    if (status_code == 429) return .rate_limited_retry;
    if (status_code >= 500 and status_code < 600) return .server_error;
    if (status_code == 400 or status_code == 404) return .auth_failed;
    return .unknown;
}

/// Thread-local storage for last error details from the most recent API call.
/// Set by provider code before returning an error; read by callWithRetry for classification.
pub var last_status_code: u16 = 0;
pub var last_error_body: []const u8 = "";

/// Returns true if the error kind warrants a retry.
/// Source: docs/PLAN-RETRY.md — retry decision table.
pub fn isRetryable(kind: ErrorKind) bool {
    return switch (kind) {
        .auth_failed, .rate_limited, .context_exceeded, .sse_interrupted => false,
        .rate_limited_retry, .server_error, .network_error, .unknown => true,
    };
}

/// Parse Retry-After header value and return milliseconds.
/// Supports: retry-after (int seconds with optional quotes).
/// Returns null on parse failure (caller falls back to jitter).
/// HTTP-date format (RFC 1123) is not supported — returns null.
/// Source: docs/PLAN-RETRY.md — Retry-After parsing priority.
pub fn parseRetryAfterMs(header_value: []const u8) ?u64 {
    var trimmed = std.mem.trim(u8, header_value, " \t\r\n");
    if (trimmed.len == 0) return null;

    // Strip optional surrounding quotes
    if (trimmed.len >= 2 and trimmed[0] == '"' and trimmed[trimmed.len - 1] == '"') {
        trimmed = trimmed[1 .. trimmed.len - 1];
    }

    // Parse as integer (seconds per HTTP spec), convert to ms
    const seconds = std.fmt.parseInt(u64, trimmed, 10) catch return null;
    return seconds * 1000;
}

/// Compute backoff with full jitter.
/// base_ms = 1000. attempt = 0-indexed.
/// If retry_after_ms is provided, use it directly (capped at 300000 = 5min).
/// Otherwise: sleep_ms = random_between(base_ms * 2^attempt, base_ms * 2^(attempt+1))
/// Source: docs/PLAN-RETRY.md — full jitter backoff algorithm.
pub fn computeBackoff(attempt: u32, retry_after_ms: ?u64) u64 {
    if (retry_after_ms) |ra| {
        return @min(ra, 300_000);
    }

    const base: u64 = 1000;
    const min_sleep = base << @as(u6, @intCast(attempt));
    const max_sleep = base << @as(u6, @intCast(attempt + 1));

    // Full jitter: random between min and max
    if (max_sleep <= min_sleep) return min_sleep;
    const range = max_sleep - min_sleep;
    rng_counter +%= 1;
    var prng = std.Random.DefaultPrng.init(rng_counter +% attempt);
    const r = prng.random().int(u64);
    return min_sleep + (r % (range + 1));
}

/// Generate user-facing error message for an error kind.
/// Returns a static string; no allocation needed.
/// Source: docs/PLAN-RETRY.md — common error code mapping.
pub fn friendlyMessage(kind: ErrorKind, model: []const u8) []const u8 {
    _ = model;
    return switch (kind) {
        .auth_failed => "API 认证失败，请检查 API Key 是否正确设置",
        .rate_limited => "API 配额已用尽，请检查账户余额或升级套餐",
        .rate_limited_retry => "API 请求频率过高，正在等待后自动重试...",
        .context_exceeded => "上下文长度超出模型处理上限，建议 /clear 后重试",
        .server_error => "服务端暂时不可用，正在自动重试...",
        .network_error => "网络连接异常，请检查网络后重试",
        .sse_interrupted => "流传输中断，请重新发起对话",
        .unknown => "发生未知错误",
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "classify: body keywords" {
    const testing = std.testing;

    // quota errors
    try testing.expectEqual(ErrorKind.rate_limited, classify(200, "insufficient_quota"));
    try testing.expectEqual(ErrorKind.rate_limited, classify(200, "quota exceeded for today"));
    try testing.expectEqual(ErrorKind.rate_limited, classify(200, "billing issue"));

    // context length errors
    try testing.expectEqual(ErrorKind.context_exceeded, classify(200, "context_length_exceeded"));
    try testing.expectEqual(ErrorKind.context_exceeded, classify(200, "maximum context length is 128k"));

    // auth errors
    try testing.expectEqual(ErrorKind.auth_failed, classify(200, "invalid_api_key"));
    try testing.expectEqual(ErrorKind.auth_failed, classify(200, "authentication failed"));
    try testing.expectEqual(ErrorKind.auth_failed, classify(200, "permission denied"));
}

test "classify: status code fallback" {
    const testing = std.testing;

    try testing.expectEqual(ErrorKind.auth_failed, classify(401, ""));
    try testing.expectEqual(ErrorKind.auth_failed, classify(403, ""));
    try testing.expectEqual(ErrorKind.rate_limited_retry, classify(429, ""));
    try testing.expectEqual(ErrorKind.server_error, classify(500, ""));
    try testing.expectEqual(ErrorKind.server_error, classify(503, ""));
}

test "classify: unknown status code returns unknown" {
    const testing = std.testing;
    try testing.expectEqual(ErrorKind.unknown, classify(418, ""));
    try testing.expectEqual(ErrorKind.unknown, classify(0, ""));
}

test "classify: body keyword takes precedence over status code" {
    const testing = std.testing;
    // Even with 429, if body says quota, it's rate_limited (non-retryable)
    try testing.expectEqual(ErrorKind.rate_limited, classify(429, "insufficient_quota"));
    try testing.expectEqual(ErrorKind.auth_failed, classify(403, "invalid_api_key"));
}

test "isRetryable: non-retryable kinds" {
    const testing = std.testing;
    try testing.expect(!isRetryable(.auth_failed));
    try testing.expect(!isRetryable(.rate_limited));
    try testing.expect(!isRetryable(.context_exceeded));
}

test "isRetryable: retryable kinds" {
    const testing = std.testing;
    try testing.expect(isRetryable(.rate_limited_retry));
    try testing.expect(isRetryable(.server_error));
    try testing.expect(isRetryable(.network_error));
    try testing.expect(!isRetryable(.sse_interrupted));
    try testing.expect(isRetryable(.unknown));
}

test "parseRetryAfterMs: valid integer" {
    const testing = std.testing;
    // Standard Retry-After in seconds
    const result = parseRetryAfterMs("120");
    try testing.expect(result != null);
    try testing.expectEqual(@as(u64, 120_000), result.?);
}

test "parseRetryAfterMs: quoted integer" {
    const testing = std.testing;
    const result = parseRetryAfterMs("\"30\"");
    try testing.expect(result != null);
    try testing.expectEqual(@as(u64, 30_000), result.?);
}

test "parseRetryAfterMs: invalid input returns null" {
    const testing = std.testing;
    try testing.expect(parseRetryAfterMs("") == null);
    try testing.expect(parseRetryAfterMs("abc") == null);
    try testing.expect(parseRetryAfterMs("-1") == null);
}

test "parseRetryAfterMs: HTTP-date format returns null" {
    const testing = std.testing;
    // HTTP-date format not supported, should return null
    try testing.expect(parseRetryAfterMs("Wed, 21 Oct 2026 07:28:00 GMT") == null);
}

test "parseRetryAfterMs: zero returns zero ms" {
    const testing = std.testing;
    const result = parseRetryAfterMs("0");
    try testing.expect(result != null);
    try testing.expectEqual(@as(u64, 0), result.?);
}

test "computeBackoff: with retry_after_ms uses it capped at 5min" {
    const testing = std.testing;
    // Within cap
    try testing.expectEqual(@as(u64, 10_000), computeBackoff(0, 10_000));
    // Exceeds cap
    try testing.expectEqual(@as(u64, 300_000), computeBackoff(0, 600_000));
}

test "computeBackoff: without retry_after_ms uses full jitter" {
    const testing = std.testing;
    // attempt 0: range [1000, 2000]
    const b0 = computeBackoff(0, null);
    try testing.expect(b0 >= 1000 and b0 <= 2000);

    // attempt 1: range [2000, 4000]
    const b1 = computeBackoff(1, null);
    try testing.expect(b1 >= 2000 and b1 <= 4000);

    // attempt 2: range [4000, 8000]
    const b2 = computeBackoff(2, null);
    try testing.expect(b2 >= 4000 and b2 <= 8000);
}

test "computeBackoff: jitter produces varied values" {
    const testing = std.testing;
    // Run multiple times and verify not all results are the same
    var all_same = true;
    const first = computeBackoff(0, null);
    var i: u32 = 0;
    while (i < 20) : (i += 1) {
        if (computeBackoff(0, null) != first) {
            all_same = false;
            break;
        }
    }
    // With 20 samples, nearly impossible for all to be identical
    try testing.expect(!all_same);
}

test "friendlyMessage: returns non-empty strings" {
    const testing = std.testing;
    inline for (std.meta.tags(ErrorKind)) |kind| {
        const msg = friendlyMessage(kind, "test-model");
        try testing.expect(msg.len > 0);
    }
}

test "friendlyMessage: context_exceeded mentions /clear" {
    const testing = std.testing;
    const msg = friendlyMessage(.context_exceeded, "test-model");
    try testing.expect(std.mem.indexOf(u8, msg, "clear") != null);
}
