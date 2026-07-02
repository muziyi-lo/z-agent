const std = @import("std");

/// Memory entry with fields borrowed from parsed content. All fields are slices
/// into the original content buffer (zero-copy), callers must keep buffer alive.
pub const Entry = struct {
    id: []const u8,
    title: []const u8,
    source: []const u8,
    pattern_key: []const u8,
    priority: []const u8,
    scope: []const u8,
    status: []const u8,
    handled: []const u8,
    recurrence_count: usize,
    archived: bool,
    related_files: []const u8,
    logged: []const u8,
    /// Full raw text of the entry (includes header, metadata, content)
    raw: []const u8,
    /// First 200 chars of content body (for preview)
    preview: []const u8,
};
