const std = @import("std");
const testing = std.testing;

const linux = @import("linux.zig");
const MemInfo = linux.MemInfo;
const CpuTimes = linux.CpuTimes;

// ── MemInfo.parse ──────────────────────────────────────────────────────────
// Pure parsing: feed /proc/meminfo-shaped text and assert the kB→bytes
// conversion and key mapping. No I/O, no allocator.

test "MemInfo.parse maps known keys and converts kB to bytes" {
    const data =
        \\MemTotal:        8095824 kB
        \\MemFree:         6645348 kB
        \\MemAvailable:    7153076 kB
        \\Buffers:           14824 kB
        \\Cached:           619528 kB
        \\SwapTotal:       2097148 kB
        \\SwapFree:        2097148 kB
        \\
    ;
    const m = try MemInfo.parse(data);

    try testing.expectEqual(@as(u64, 8095824 * 1024), m.total);
    try testing.expectEqual(@as(u64, 6645348 * 1024), m.free);
    try testing.expectEqual(@as(?u64, 7153076 * 1024), m.available);
    try testing.expectEqual(@as(u64, 14824 * 1024), m.buffers);
    try testing.expectEqual(@as(u64, 619528 * 1024), m.cached);
    try testing.expectEqual(@as(u64, 2097148 * 1024), m.swap_total);
    try testing.expectEqual(@as(u64, 2097148 * 1024), m.swap_free);
}

test "MemInfo.parse leaves available null when MemAvailable is absent (old kernels)" {
    const data =
        \\MemTotal:        8095824 kB
        \\MemFree:         6645348 kB
        \\
    ;
    const m = try MemInfo.parse(data);

    try testing.expectEqual(@as(?u64, null), m.available);
    try testing.expectEqual(@as(u64, 8095824 * 1024), m.total);
}

test "MemInfo.parse ignores unknown keys and unparseable values" {
    const data =
        \\MemTotal:        8095824 kB
        \\HugePages_Total:       0
        \\DirectMap4k:      garbage kB
        \\MemFree:         6645348 kB
        \\
    ;
    // HugePages_Total isn't in the map (skipped); DirectMap4k has a non-numeric
    // value (parseInt fails, `catch continue`). Neither should abort parsing.
    const m = try MemInfo.parse(data);

    try testing.expectEqual(@as(u64, 8095824 * 1024), m.total);
    try testing.expectEqual(@as(u64, 6645348 * 1024), m.free);
}

test "MemInfo.parse on empty input yields zeroed gauges and null available" {
    const m = try MemInfo.parse("");

    try testing.expectEqual(@as(u64, 0), m.total);
    try testing.expectEqual(@as(u64, 0), m.free);
    try testing.expectEqual(@as(?u64, null), m.available);
}

// ── CpuTimes.parse ─────────────────────────────────────────────────────────

test "CpuTimes.parse reads every field of the aggregate cpu line" {
    // Note the double space after `cpu` — tokenizeScalar skips the empty token.
    const c = try CpuTimes.parse("cpu  16854 42 19856 10420753 4762 0 2356 0 0 0\n");

    try testing.expectEqual(@as(u64, 16854), c.user);
    try testing.expectEqual(@as(u64, 42), c.nice);
    try testing.expectEqual(@as(u64, 19856), c.system);
    try testing.expectEqual(@as(u64, 10420753), c.idle);
    try testing.expectEqual(@as(u64, 4762), c.iowait);
    try testing.expectEqual(@as(u64, 0), c.irq);
    try testing.expectEqual(@as(u64, 2356), c.softirq);
    try testing.expectEqual(@as(u64, 0), c.steal);
    try testing.expectEqual(@as(u64, 0), c.guest);
    try testing.expectEqual(@as(u64, 0), c.guest_nice);
}

test "CpuTimes.total and idleAll derive from the parsed fields" {
    const c = try CpuTimes.parse("cpu 10 20 30 40 50 0 0 0 0 0\n");

    try testing.expectEqual(@as(u64, 10 + 20 + 30 + 40 + 50), c.total());
    try testing.expectEqual(@as(u64, 40 + 50), c.idleAll());
}

test "CpuTimes.parse tolerates a short line (pre-2.6.33 kernels): trailing fields stay 0" {
    // Only through `steal`; guest/guest_nice are absent and must default to 0.
    const c = try CpuTimes.parse("cpu 10 20 30 40 50 60 70 80\n");

    try testing.expectEqual(@as(u64, 80), c.steal);
    try testing.expectEqual(@as(u64, 0), c.guest);
    try testing.expectEqual(@as(u64, 0), c.guest_nice);
}

test "CpuTimes.parse rejects a first line that is not the aggregate cpu line" {
    // The per-core label `cpu0` is not equal to `cpu`.
    try testing.expectError(error.MalformedStat, CpuTimes.parse("cpu0 1 2 3 4 5 6 7 8 9 10\n"));
    try testing.expectError(error.MalformedStat, CpuTimes.parse("intr 12345 0 0\n"));
    try testing.expectError(error.MalformedStat, CpuTimes.parse(""));
}

// ── Readers (integration against the host's real /proc and statfs) ──────────
// These run on the test machine's live kernel, so they assert invariants that
// hold for any healthy Linux box rather than exact values.

test "readMemory returns sane totals from /proc/meminfo" {
    const m = try linux.readMemory(testing.io);

    try testing.expect(m.total > 0);
    try testing.expect(m.free <= m.total);
    if (m.available) |avail| try testing.expect(avail <= m.total);
}

test "readUptime returns a positive number of seconds" {
    const up = try linux.readUptime(testing.io);
    try testing.expect(up > 0);
}

test "readCpuTimes returns a non-zero, advancing counter snapshot" {
    const a = try linux.readCpuTimes(testing.io);
    try testing.expect(a.total() > 0);

    // Counters are monotonic since boot; a later read never goes backwards.
    const b = try linux.readCpuTimes(testing.io);
    try testing.expect(b.total() >= a.total());
}

test "readDiskUsage reports capacity for the root filesystem" {
    const du = try linux.readDiskUsage("/");

    try testing.expect(du.total > 0);
    try testing.expect(du.available <= du.total);
    try testing.expect(du.free <= du.total);
}

test "readDiskUsage surfaces a typed error for a missing path" {
    try testing.expectError(error.PathNotFound, linux.readDiskUsage("/no/such/path/zagent"));
}
