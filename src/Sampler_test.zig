const std = @import("std");
const testing = std.testing;

const Sampler = @import("Sampler.zig");
const RingBuffer = @import("RingBuffer.zig");
const linux = @import("linux.zig");
const json = @import("json.zig");

const CpuTimes = linux.CpuTimes;
const Sample = Sampler.Sample;

// ── cpuUtil ─────────────────────────────────────────────────────────────────
// Pure delta math: no I/O, exact assertions. A CpuTimes left as `.{}` is the
// all-zero baseline (total == 0).

test "cpuUtil returns null on the first sample (no previous baseline)" {
    const cur: CpuTimes = .{ .user = 10, .idle = 90 };
    try testing.expectEqual(@as(?f64, null), Sampler.cpuUtil(null, cur));
}

test "cpuUtil returns null when no time elapsed (dt == 0)" {
    // Identical snapshots: total delta is zero, so utilization is undefined
    // rather than a divide-by-zero.
    const snap: CpuTimes = .{ .user = 10, .idle = 90 };
    try testing.expectEqual(@as(?f64, null), Sampler.cpuUtil(snap, snap));
}

test "cpuUtil computes busy fraction from the delta" {
    // From an all-zero baseline: 25 busy + 75 idle ticks => 25% utilization.
    const prev: CpuTimes = .{};
    const cur: CpuTimes = .{ .user = 25, .idle = 75 };
    const util = Sampler.cpuUtil(prev, cur) orelse return error.UnexpectedNull;
    try testing.expectApproxEqAbs(@as(f64, 0.25), util, 1e-9);
}

test "cpuUtil counts iowait as idle" {
    // 50 user (busy) + 50 iowait (idle via idleAll) => exactly half busy.
    const cur: CpuTimes = .{ .user = 50, .iowait = 50 };
    const util = Sampler.cpuUtil(.{}, cur) orelse return error.UnexpectedNull;
    try testing.expectApproxEqAbs(@as(f64, 0.5), util, 1e-9);
}

test "cpuUtil measures only the interval between two non-trivial snapshots" {
    // Window = cur - prev: busy goes 100->150 (+50), idle 100->100 (+0).
    // dt = 50, di = 0  => fully busy over this interval, regardless of history.
    const prev: CpuTimes = .{ .user = 100, .idle = 100 };
    const cur: CpuTimes = .{ .user = 150, .idle = 100 };
    const util = Sampler.cpuUtil(prev, cur) orelse return error.UnexpectedNull;
    try testing.expectApproxEqAbs(@as(f64, 1.0), util, 1e-9);
}

// ── tick (integration against the host's live /proc + statfs) ───────────────

test "tick pushes one parseable .metric record into the ring" {
    var ring = try RingBuffer.init(testing.allocator, 4);
    defer ring.deinit();

    var sampler = Sampler.init(testing.allocator, testing.io, &ring, 1000, "/");
    try sampler.tick();

    const rec = ring.pop() orelse return error.NoRecordPushed;
    defer testing.allocator.free(rec.content);

    try testing.expect(rec.kind == .metric);
    try testing.expect(rec.timestamp.nanoseconds > 0);

    // Content is the JSON-serialized Sample; it must round-trip and carry the
    // live gauges read from this host.
    const parsed = try json.Deserialize(testing.allocator, Sample, rec.content);
    defer parsed.deinit();

    try testing.expect(parsed.value.mem.total > 0);
    try testing.expect(parsed.value.disk.total > 0);
    try testing.expect(parsed.value.uptime_s > 0);
}

test "tick leaves cpu_util null on the first sample, populated on the second" {
    var ring = try RingBuffer.init(testing.allocator, 4);
    defer ring.deinit();

    var sampler = Sampler.init(testing.allocator, testing.io, &ring, 1000, "/");

    // First tick: no baseline yet, so cpu_util is null and prev_cpu gets set.
    try testing.expectEqual(@as(?linux.CpuTimes, null), sampler.prev_cpu);
    try sampler.tick();
    try testing.expect(sampler.prev_cpu != null);

    const first = ring.pop() orelse return error.NoRecordPushed;
    defer testing.allocator.free(first.content);
    const p1 = try json.Deserialize(testing.allocator, Sample, first.content);
    defer p1.deinit();
    try testing.expectEqual(@as(?f64, null), p1.value.cpu_util);

    // Second tick now has a baseline. cpu_util is present unless the two reads
    // landed in the same jiffy (dt == 0); if present it must be a fraction.
    try sampler.tick();
    const second = ring.pop() orelse return error.NoRecordPushed;
    defer testing.allocator.free(second.content);
    const p2 = try json.Deserialize(testing.allocator, Sample, second.content);
    defer p2.deinit();
    if (p2.value.cpu_util) |util| {
        try testing.expect(util >= 0.0 and util <= 1.0);
    }
}
