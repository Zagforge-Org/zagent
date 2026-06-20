//! The configuration specifications for zagent.
//! Each specification can be configurable,
//! with some configuration variables providing default values.

const std = @import("std");

pub const Backpressure = enum {
    drop_oldest,
    drop_newest,
    block,
};

pub const Config = struct {
    // file the tailer follows
    log_paths: []const u8,
    max_line_bytes: usize = 65536, // default max-line cap

    metric_interval_ms: u64 = 10_000, // sampler tick
    disk_path: []const u8 = "/", // mount to report usage

    buffer_capacity: usize = 10_000, // ring buffer size (records)
    backpressure: Backpressure = .drop_oldest,

    endpoint: []const u8,
    auth_header: ?[]const u8 = null, // optional ("Bearer", etc.)
    batch_max: usize = 100, // flush at this many records
    batch_ms: u64 = 2_000, // flush this often, whichever first (batch_max or this)
    max_retries: u32 = 5,

    /// Load and parse config from a JSON file path.
    pub fn loadFromFile(
        allocator: std.mem.Allocator,
        io: std.Io,
        path: []const u8,
    ) !std.json.Parsed(Config) {
        const data = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, 1 << 20);
        defer allocator.free(data);

        return std.json.parseFromSlice(
            Config,
            allocator,
            data,
            .{
                .allocate = .alloc_always,
                .ignore_unknown_fields = true,
            },
        );
    }
};
