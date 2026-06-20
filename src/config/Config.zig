//! The configuration specifications for zagent.
//! Each specification can be configurable,
//! with some configuration variables providing default values.

const std = @import("std");
const json = @import("../utils/json.zig");

const configName = "zagent.config.json";

pub const Backpressure = enum {
    drop_oldest,
    drop_newest,
    block,
};

pub const Config = struct {
    // file the tailer follows
    log_paths: []const u8 = "",
    max_line_bytes: usize = 65536, // default max-line cap

    metric_interval_ms: u64 = 10_000, // sampler tick
    disk_path: []const u8 = "/", // mount to report usage

    buffer_capacity: usize = 10_000, // ring buffer size (records)
    backpressure: Backpressure = .drop_oldest,

    endpoint: []const u8 = "",
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

/// Initialize a default zagent.config.json
pub fn default(allocator: std.mem.Allocator, io: std.Io) !void {
    const file = std.Io.Dir.cwd().createFile(io, configName, .{ .exclusive = true }) catch |err| switch (err) {
        error.PathAlreadyExists => {
            std.debug.print("{s} already exists.\n", .{configName});
            return;
        },
        else => return err,
    };
    defer file.close(io);

    var buf: [2048]u8 = undefined;
    var writer = file.writer(io, &buf);

    const defaultConfig = Config{};
    const serialized = try json.Serialize(allocator, defaultConfig, .{
        .whitespace = .indent_2,
    });
    defer allocator.free(serialized);

    try writer.interface.writeAll(serialized);
    try writer.interface.flush();
}
