const std = @import("std");

/// Kind represents the type of `Record`.
const Kind = enum {
    log,
    metric,
};

/// A record is a structure with a timestamp represented with a `Clock`,
/// content, and a kind.
pub const Record = struct {
    timestamp: std.Io.Clock,
    content: []const u8,
    kind: Kind,
};

const Self = @This();

/// Fixed backing array, allocated once at startup to `capacity`.
storage: []Record,

/// Fixed size.
capacity: usize,

/// Write cursor.
head: usize,

/// Read cursor.
tail: usize,

/// Total records discarded on overflow.
dropped: u64,

/// Represents how many records are currently alive.
count: usize,

allocator: std.mem.Allocator,

pub fn init(allocator: std.mem.Allocator, capacity: usize) !Self {
    return .{
        .allocator = allocator,
        .capacity = capacity,
    };
}

pub fn push(self: *Self, record: Record) !void {
    _ = self;
    _ = record;
}

pub fn pop(self: *Self) ?Record {
    _ = self;
}

fn isEmpty(self: *Self) bool {
    return self.count == 0;
}

fn isFull(self: *Self) bool {
    return self.count == self.capacity;
}

pub fn deinit() void {}
