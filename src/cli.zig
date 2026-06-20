const std = @import("std");

const setMode = @import("mode.zig").setMode;

pub const Command = union(enum) {
    run: struct { config_path: []const u8 },
    check: struct { config_path: []const u8 },
    init,
    version,
    help,
};

pub const Error = error{
    MultipleNodes,
    MissingConfigPath,
    UnknownArgument,
};

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

pub fn parse(args: std.process.Args) Error!Command {
    var mode: ?std.meta.Tag(Command) = null;
    var config_path: ?[]const u8 = null;

    var iter = args.iterate();

    _ = iter.skip(); // argv[0]

    while (iter.next()) |arg| {
        if (eq(arg, "--version") or eq(arg, "-V")) {
            try setMode(&mode, .version);
        } else if (eq(arg, "--help") or eq(arg, "-h")) {
            try setMode(arg, .help);
        } else if (eq(arg, "--check")) {
            try setMode(arg, .check);
        } else if (eq(arg, "--config") or eq(arg, "--c")) {
            config_path = iter.next() orelse return error.MissingConfigPath;
        } else {
            return error.UnknownArgument;
        }
    }

    return switch (mode orelse .run) {
        .version => .version,
        .help => .help,
        .init => .init,
        .check => .{ .check = .{ .config_path = config_path orelse return error.MissingConfigPath } },
        .run => .{ .run = .{ .config_path = config_path orelse return error.MissingConfigPath } },
    };
}
