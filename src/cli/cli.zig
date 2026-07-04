//! Command-line parsing for zagent: turns the process arguments into a single
//! `Command` for `main` to dispatch on.
//!
//! Usage:
//!   zagent [-c PATH]           run the pipeline (the default when no mode flag)
//!   zagent --init              write a default config file
//!   zagent --check [-c PATH]   validate the config and exit
//!   zagent --version, -V       print the version
//!   zagent --help,    -h       print usage
//!
//! Options:
//!   --config, -c PATH    config file to use (default: "zagent.config.json")
//!
//! Rules:
//!   - At most one mode flag may be given.
//!   - `--config`/`-c` requires a following value, else `error.MissingConfigPath`.
//!   - Any unrecognized argument is `error.UnknownArgument`.
//!   - With no mode flag, the command defaults to `.run`.

const std = @import("std");

const setMode = @import("mode.zig").setMode;

/// Config path used when `--config` is not given.
const default_config_path = "zagent.config.json";

/// The selected subcommand, produced by `parse` for `main` to act on.
pub const Command = union(enum) {
    /// Run the pipeline using the config at `config_path`.
    run: struct { config_path: []const u8 },

    /// Validate the config at `config_path` and exit.
    check: struct { config_path: []const u8 },

    /// Write a default config file.
    init,

    /// Print the version.
    version,

    /// Print usage.
    help,
};

/// Reasons `parse` can reject the argument list.
pub const Error = error{
    /// More than one mode flag was given (e.g. `--check --version`).
    MultipleModes,

    /// `--config`/`-c` was given without a following path value.
    MissingConfigPath,

    /// An argument matched no known flag.
    UnknownArgument,
};

/// Single source of truth for the set of modes: the `Command` tag.
const Mode = std.meta.Tag(Command);

inline fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// Parse the process `args` (argv[0] is skipped) into a `Command`. Returns an
/// `Error` for conflicting mode flags, a `--config` with no value, or an
/// unrecognized argument.
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
