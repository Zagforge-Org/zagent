//! Shared atomic counters, bumped by the producer/consumer threads and read by
//! the Sampler. Increments use `fetchAdd` so they're race-free; `.monotonic`
//! ordering is enough since they guard no other memory.

const std = @import("std");

const Self = @This();

/// Records dropped by a full spool. Real loss.
spool_dropped: std.atomic.Value(u64) = .init(0),
/// Batches shipped and acked.
batches_shipped: std.atomic.Value(u64) = .init(0),
/// Send attempts that exhausted retries. Data is rewound and retained, not lost.
send_failures: std.atomic.Value(u64) = .init(0),

/// Point-in-time read of all counters.
pub const Snapshot = struct {
    spool_dropped: u64,
    batches_shipped: u64,
    send_failures: u64,
};

pub fn incrementDropped(self: *Self) void {
    _ = self.spool_dropped.fetchAdd(1, .monotonic);
}

pub fn incrementShipped(self: *Self) void {
    _ = self.batches_shipped.fetchAdd(1, .monotonic);
}

pub fn incrementSendFailure(self: *Self) void {
    _ = self.send_failures.fetchAdd(1, .monotonic);
}

pub fn snapshot(self: *const Self) Snapshot {
    return .{
        .spool_dropped = self.spool_dropped.load(.monotonic),
        .batches_shipped = self.batches_shipped.load(.monotonic),
        .send_failures = self.send_failures.load(.monotonic),
    };
}
