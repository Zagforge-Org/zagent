//! A record is a structure with a timestamp, content, and a kind.

const std = @import("std");

/// Kind represents the type of `Record`.
const Kind = enum {
    log,
    metric,
};

timestamp: std.Io.Timestamp,
content: []const u8,
kind: Kind,
