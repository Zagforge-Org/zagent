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
        .storage = try allocator.alloc([]Record, capacity),
    };
}

pub fn push(self: *Self, record: Record) !void {
    if (self.isFull()) {
        self.tail(self.tail + 1) % self.capacity;
        self.dropped += 1;
    } else {
        self.count += 1;
    }
    self.storage[self.head] = record;
    self.head = (self.head + 1) % self.capacity;
}

pub fn pop(self: *Self) ?Record {
    if (self.isEmpty()) return null;
    const record = self.storage[self.tail];
    self.tail = (self.tail + 1) % self.capacity;
    self.count -= 1;
    return record;
}

fn isEmpty(self: *Self) bool {
    return self.count == 0;
}

fn isFull(self: *Self) bool {
    return self.count == self.capacity;
}

pub fn deinit(self: *Self) void {
    self.allocator.free(self.storage);
}
