const std = @import("std");

/// Kind represents the type of `Record`.
const Kind = enum {
    log,
    metric,
};

/// A record is a structure with a timestamp, content, and a kind.
pub const Record = struct {
    timestamp: std.Io.Timestamp,
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

/// Mutex for thread-safety.
mutex: std.Io.Mutex = .init,

allocator: std.mem.Allocator,

io: std.Io,

pub fn init(allocator: std.mem.Allocator, io: std.Io, capacity: usize) !Self {
    return .{
        .allocator = allocator,
        .io = io,
        .capacity = capacity,
        .storage = try allocator.alloc(Record, capacity),
        .head = 0,
        .tail = 0,
        .dropped = 0,
        .count = 0,
    };
}

pub fn push(self: *Self, record: Record) !void {
    const owned = try self.allocator.dupe(u8, record.content);

    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    if (self.isFull()) {
        self.allocator.free(self.storage[self.tail].content); // free the evicted line
        self.tail = (self.tail + 1) % self.capacity;
        self.dropped += 1;
    } else {
        self.count += 1;
    }
    self.storage[self.head] = .{ .timestamp = record.timestamp, .content = owned, .kind = record.kind };
    self.head = (self.head + 1) % self.capacity;
}

/// Removes and returns the oldest record, or null if empty. Ownership of the
/// returned `content` transfers to the caller, who must free it with the same
/// allocator the buffer was initialized with.
pub fn pop(self: *Self) ?Record {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

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

pub fn stats(self: *Self) struct { count: usize, dropped: u64 } {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    return .{ .count = self.count, .dropped = self.dropped };
}

/// Frees the backing array and the owned `content` of every record still live
/// in the buffer.
pub fn deinit(self: *Self) void {
    var idx = self.tail;
    var i: usize = 0;
    while (i < self.count) : (i += 1) {
        self.allocator.free(self.storage[idx].content);
        idx = (idx + 1) % self.capacity;
    }
    self.allocator.free(self.storage);
}
