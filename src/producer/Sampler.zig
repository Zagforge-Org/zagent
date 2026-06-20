//! Sampler is a data source which provides health metrics,
//! statistics, and kernel-level information.

const std = @import("std");
const RingBuffer = @import("../core/RingBuffer.zig");
const linux = @import("../platform/linux.zig");
const json = @import("../utils/json.zig");

allocator: std.mem.Allocator,
io: std.Io,
buffer: *RingBuffer,
interval_ms: u64,
disk_path: []const u8,

/// State carried by the sampler for previous /proc/stat reading.
/// `null` on the very first tick.
prev_cpu: ?linux.CpuTimes = null,

/// Sample represents a struct with kernel-level information.
pub const Sample = struct {
    uptime_s: f64,
    mem: linux.MemInfo,
    cpu_util: ?f64,
    disk: linux.DiskUsage,
};

const Self = @This();

pub fn init(
    allocator: std.mem.Allocator,
    io: std.Io,
    buffer: *RingBuffer,
    interval_ms: u64,
    disk_path: []const u8,
) Self {
    return .{
        .allocator = allocator,
        .io = io,
        .buffer = buffer,
        .interval_ms = interval_ms,
        .disk_path = disk_path,
    };
}

/// cpuUtil calculates utilization fraction.
/// It compares the current CPU cycle wit hthe previous one.
pub fn cpuUtil(prev: ?linux.CpuTimes, cur: linux.CpuTimes) ?f64 {
    const p = prev orelse return null;
    const dt = cur.total() - p.total();
    const di = cur.idleAll() - p.idleAll();
    if (dt == 0) return null;
    return 1.0 - @as(f64, @floatFromInt(di)) / @as(f64, @floatFromInt(dt));
}

/// tick samples the current cycle
/// and pushes the content to the `RingBuffer`.
pub fn tick(self: *Self) !void {
    const cur = try linux.readCpuTimes(self.io);
    const util = cpuUtil(self.prev_cpu, cur);
    self.prev_cpu = cur;

    const sample: Sample = .{
        .uptime_s = try linux.readUptime(self.io),
        .mem = try linux.readMemory(self.io),
        .cpu_util = util,
        .disk = try linux.readDiskUsage(self.disk_path),
    };

    // Serialize opaque content bytes where the ring dupes it and free our copy.
    const content = try json.Serialize(self.allocator, sample, .{ .whitespace = .minified });
    defer self.allocator.free(content);

    try self.buffer.push(.{
        .kind = .metric,
        .timestamp = std.Io.Timestamp.now(self.io, .real),
        .content = content,
    });
}

pub fn run(self: *Self, running: *const std.atomic.Value(bool)) !void {
    while (running.load(.monotonic)) {
        const start = std.Io.Timestamp.now(self.io, .awake);

        self.tick() catch |err| std.log.warn("sample failed: {t}", .{err});

        // Drift-corrected sleep: subtract the work done this tick from the
        // interval. Done in i64 (durations are signed) and clamped at 0 so a
        // tick that overran the interval just samples again immediately.
        const elapsed_ms = start.durationTo(std.Io.Timestamp.now(self.io, .awake)).toMilliseconds();
        const sleep_ms = @max(0, @as(i64, @intCast(self.interval_ms)) - elapsed_ms);
        try self.io.sleep(.fromMilliseconds(sleep_ms), .awake);
    }
}
