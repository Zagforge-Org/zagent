//! Shared atomic counters, bumped by the producer/consumer threads and read by
//! the Sampler. Increments use `fetchAdd` so they're race-free
//! ordering is enough since they guard no other memory.

const std = @import("std");

const Self = @This();

/// Records dropped by a full spool. Real loss.
spool_dropped: std.atomic.Value(u64) = .init(0),
/// Batches shipped and acked.
batches_shipped: std.atomic.Value(u64) = .init(0),
/// Batches given up on after retries.
batches_failed: std.atomic.Value(u64) = .init(0),

/// Point-in-time read of all counters.
pub const Snapshot = struct {
    spool_dropped: u64,
    batches_shipped: u64,
    batches_failed: u64,
};

pub fn incrementDropped(self: *Self) void {
    _ = self.spool_dropped.fetchAdd(1, .monotonic);
}

pub fn incrementShipped(self: *Self) void {
    _ = self.batches_shipped.fetchAdd(1, .monotonic);
}

pub fn incrementFailed(self: *Self) void {
    _ = self.batches_failed.fetchAdd(1, .monotonic);
}

pub fn snapshot(self: *const Self) Snapshot {
    return .{
        .spool_dropped = self.spool_dropped.load(.monotonic),
        .batches_shipped = self.batches_shipped.load(.monotonic),
        .batches_failed = self.batches_failed.load(.monotonic),
    };
}
