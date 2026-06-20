const std = @import("std");

const setMode = @import("mode.zig").setMode;

/// Config path used when `--config` is not given.
const default_config_path = "zagent.config.json";

pub const Command = union(enum) {
    run: struct { config_path: []const u8 },
    check: struct { config_path: []const u8 },
    init,
    version,
    help,
};

pub const Error = error{
    MultipleModes,
    MissingConfigPath,
    UnknownArgument,
};

/// Single source of truth for the set of modes: the `Command` tag.
const Mode = std.meta.Tag(Command);

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

pub fn parse(args: std.process.Args) Error!Command {
    var mode: ?Mode = null;
    var config_path: ?[]const u8 = null;

    var iter = args.iterate();
    _ = iter.skip(); // argv[0]

    while (iter.next()) |arg| {
        if (eq(arg, "--version") or eq(arg, "-V")) {
            try setMode(Mode, &mode, .version);
        } else if (eq(arg, "--help") or eq(arg, "-h")) {
            try setMode(Mode, &mode, .help);
        } else if (eq(arg, "--init")) {
            try setMode(Mode, &mode, .init);
        } else if (eq(arg, "--check")) {
            try setMode(Mode, &mode, .check);
        } else if (eq(arg, "--config") or eq(arg, "-c")) {
            config_path = iter.next() orelse return error.MissingConfigPath;
        } else {
            return error.UnknownArgument;
        }
    }

    const path = config_path orelse default_config_path;

    return switch (mode orelse .run) {
        .version => .version,
        .help => .help,
        .init => .init,
        .check => .{ .check = .{ .config_path = path } },
        .run => .{ .run = .{ .config_path = path } },
    };
}
