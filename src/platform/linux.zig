//! linux.zig is a small helper library for working with the Linux kernel.
//! It provides helpful abstractions for reading system resources and statistical data.

const std = @import("std");

/// Global shared atomic variable depicting the state of the program.
var g_running: ?*std.atomic.Value(bool) = null;

/// Mirrors the kernel's `struct statfs`. std provides no statfs type, so the
/// layout is hand-rolled and assumes the 64-bit ABI (`__fsword_t` == i64); it is
/// correct on x86-64/aarch64 but not on 32-bit targets.
const Statfs = extern struct {
    type: i64,
    bsize: i64, // block size that f_blocks/f_bfree/f_bavail are counted in
    blocks: u64,
    bfree: u64,
    bavail: u64,
    files: u64,
    ffree: u64,
    fsid: [2]i32,
    namelen: i64,
    frsize: i64,
    flags: i64,
    spare: [4]i64,
};

/// CpuTimes represents the amount of time the processor spends running the application.
pub const CpuTimes = struct {
    /// Time spent executing normal user-space programs.
    user: u64 = 0,

    /// Time spent executing user-space tasks with a deliberately lower priority.
    nice: u64 = 0,

    /// Time spent executing kernel-level code and handling system calls.
    system: u64 = 0,

    /// CPU idle time.
    idle: u64 = 0,

    /// Time spent on I/O operations
    iowait: u64 = 0,

    /// Time spent servicing hardware interrupts.
    irq: u64 = 0,

    /// Time spent servicing software interrupts
    softirq: u64 = 0,

    /// Time virtual CPU was forced to wait while underlying hypervisor gave cycles to
    /// another virtual machine.
    steal: u64 = 0,

    /// Time spent running virtual CPU for a guest OS.
    guest: u64 = 0,

    /// Time spent running a niced virtual CPU for guest OS.
    guest_nice: u64 = 0,

    pub fn total(self: CpuTimes) u64 {
        var sum: u64 = 0;
        inline for (std.meta.fields(CpuTimes)) |f| sum += @field(self, f.name);
        return sum;
    }

    pub fn idleAll(self: CpuTimes) u64 {
        return self.idle + self.iowait;
    }

    pub fn parse(data: []const u8) !CpuTimes {
        var c: CpuTimes = .{};
        const nl = std.mem.indexOfScalar(u8, data, '\n') orelse data.len;
        var toks = std.mem.tokenizeScalar(u8, data[0..nl], ' ');
        const label = toks.next() orelse return error.MalformedStat;
        if (!std.mem.eql(u8, label, "cpu")) return error.MalformedStat;
        inline for (std.meta.fields(CpuTimes)) |f| {
            const t = toks.next() orelse break; // old kernels lack trailing fields
            @field(c, f.name) = try std.fmt.parseInt(u64, t, 10);
        }
        return c;
    }
};

/// DiskUsage represents disk attributes
/// (total, free, available), which delegate resource specifications.
pub const DiskUsage = struct {
    /// Total disk space available.
    total: u64,

    /// Total free unused disk space available.
    free: u64,

    /// Total available disk space.
    available: u64,
};

/// MemInfo represents the `proc/meminfo` memory layout representation.
pub const MemInfo = struct {
    /// MemTotal: physical RAM.
    total: u64,

    /// MemFree: completely unused.
    free: u64,

    /// MemAvailable: usable without swapping.
    /// This is absent on old kernels (pre 3.14) and might not be available.
    available: ?u64,

    buffers: u64,
    cached: u64,
    swap_total: u64,
    swap_free: u64,

    /// Available fields enum used to map to a `std.StaticStringMap`.
    const Field = enum { total, free, available, buffers, cached, swap_total, swap_free };

    /// Map fields to a map for switch statement avoiding repeatitive else if statements.
    const field_map = std.StaticStringMap(Field).initComptime(.{
        .{ "MemTotal", .total },
        .{ "MemFree", .free },
        .{ "MemAvailable", .available },
        .{ "Buffers", .buffers },
        .{ "Cached", .cached },
        .{ "SwapTotal", .swap_total },
        .{ "SwapFree", .swap_free },
    });

    /// Parses an array of slices into a `MemInfo` struct representation.
    pub fn parse(data: []const u8) !MemInfo {
        var m: MemInfo = .{
            .total = 0,
            .free = 0,
            .available = null,
            .buffers = 0,
            .cached = 0,
            .swap_total = 0,
            .swap_free = 0,
        };

        var lines = std.mem.splitScalar(u8, data, '\n');

        while (lines.next()) |line| {
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            const key = line[0..colon];
            var toks = std.mem.tokenizeScalar(u8, line[colon + 1 ..], ' ');
            const num_str = toks.next() orelse continue;
            const kb = std.fmt.parseInt(u64, num_str, 10) catch continue;
            const field = field_map.get(key) orelse continue;

            switch (field) {
                .total => m.total = kb * 1024,
                .free => m.free = kb * 1024,
                .available => m.available = kb * 1024,
                .buffers => m.buffers = kb * 1024,
                .cached => m.cached = kb * 1024,
                .swap_total => m.swap_total = kb * 1024,
                .swap_free => m.swap_free = kb * 1024,
            }
        }
        return m;
    }
};

/// readMemory reads from `/proc/meminfo` and returns `MemInfo` struct.
/// Each field converted from kB and represented in bytes.
pub fn readMemory(io: std.Io) !MemInfo {
    const file = try std.Io.Dir.cwd().openFile(io, "/proc/meminfo", .{ .mode = .read_only });
    defer file.close(io);
    var buf: [16 * 1024]u8 = undefined;
    const n = try file.readPositionalAll(io, &buf, 0);
    return try MemInfo.parse(buf[0..n]);
}

/// readUptime reads from `proc/uptime` and returns a float value representing
/// the system uptime.
pub fn readUptime(io: std.Io) !f64 {
    const file = try std.Io.Dir.cwd().openFile(io, "/proc/uptime", .{ .mode = .read_only });
    defer file.close(io);

    var buf: [64]u8 = undefined;
    const n = try file.readPositionalAll(io, &buf, 0);
    var toks = std.mem.tokenizeScalar(u8, buf[0..n], ' ');
    const secs = toks.next() orelse return error.MalformedUptime;
    return std.fmt.parseFloat(f64, secs);
}

/// readDiskUsage obtains statistical data from
/// statsfs RAM-based file system for the Linux kernel statistics and
/// returns `DiskUsage` struct.
pub fn readDiskUsage(path: []const u8) !DiskUsage {
    const path_z = try std.posix.toPosixPath(path); // [PATH_MAX-1:0]u8
    var sfs: Statfs = undefined;

    const rc = std.os.linux.syscall2(.statfs, @intFromPtr(&path_z), @intFromPtr(&sfs));
    switch (std.os.linux.errno(rc)) {
        .SUCCESS => {},
        .NOENT => return error.PathNotFound,
        .ACCES => return error.PermissionDenied,
        else => |e| return std.posix.unexpectedErrno(e),
    }

    const bs: u64 = @intCast(sfs.bsize);
    return .{
        .total = sfs.blocks * bs,
        .free = sfs.bfree * bs,
        .available = sfs.bavail * bs,
    };
}

/// readCpuTimes reads the aggregate `cpu` line from `/proc/stat` and returns a
/// `CpuTimes` struct.
pub fn readCpuTimes(io: std.Io) !CpuTimes {
    const file = try std.Io.Dir.cwd().openFile(io, "/proc/stat", .{ .mode = .read_only });
    defer file.close(io);

    var buf: [4096]u8 = undefined;
    const n = try file.readPositionalAll(io, &buf, 0);
    return try CpuTimes.parse(buf[0..n]);
}

pub fn onSignal(_: std.posix.SIG) callconv(.c) void {
    if (g_running) |r| r.store(false, .monotonic);
}

pub fn installSignalHandlers(running: *std.atomic.Value(bool)) void {
    g_running = running;
    const act = std.posix.Sigaction{
        .handler = .{ .handler = onSignal },
        .mask = std.posix.sigemptyset(),
        .flags = std.posix.SA.RESTART,
    };
    std.posix.sigaction(std.posix.SIG.INT, &act, null);
    std.posix.sigaction(std.posix.SIG.TERM, &act, null);
}

/// Clears the registered flag so a late signal can't store into a dead pointer
/// after the owning `running` goes out of scope.
pub fn clearSignalHandlers() void {
    g_running = null;
}
