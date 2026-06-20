const std = @import("std");
const Tailer = @import("producer/Tailer.zig");
const RingBuffer = @import("core/RingBuffer.zig");
const Exporter = @import("consumer/Exporter.zig");
const Sampler = @import("producer/Sampler.zig");
const Writer = @import("utils/writer.zig").Writer;
const config = @import("config/config.zig");

const linux = @import("platform/linux.zig");
const cli = @import("cli.zig");

/// Where the Exporter ships batches. TODO: make configurable (env/flag).
const endpoint = "http://localhost:8080/ingest";

/// How often the Sampler snapshots system metrics. TODO: make configurable.
const metric_interval_ms = 5000;

/// Filesystem the Sampler reports disk usage for. TODO: make configurable.
const metric_disk_path = "/";

/// zagent's semantic version. Keep in sync with `build.zig.zon`.
const version = "0.0.0";
comptime {
    // Fail the build if `version` isn't a valid semver.
    _ = std.SemanticVersion.parse(version) catch @compileError("`version` must be a valid semantic version");
}

test {
    _ = @import("producer/Tailer.zig");
    _ = @import("producer/Reader.zig");
    _ = @import("core/RingBuffer_test.zig");
    _ = @import("consumer/Exporter_test.zig");
    _ = @import("platform/linux_test.zig");
    _ = @import("producer/Sampler_test.zig");
    _ = @import("tests/integration_test.zig");
    _ = @import("config/validation_test.zig");
}

const banner =
    \\
    \\                                                888
    \\                                                888
    \\                                                888
    \\   88888888  8888b.   .d88b.   .d88b.  88888b.  888888
    \\      d88P      "88b d88P"88b d8P  Y8b 888 "88b 888
    \\     d88P   .d888888 888  888 88888888 888  888 888
    \\    d88P    888  888 Y88b 888 Y8b.     888  888 Y88b.
    \\   88888888 "Y888888  "Y88888  "Y8888  888  888  "Y888
    \\                          888
    \\                     Y8b d88P
    \\                      "Y88P"
    \\
;

const help_text =
    \\zagent — log + metric shipper
    \\
    \\usage:
    \\  zagent [-c PATH]           run the pipeline (default)
    \\  zagent --init             write a default zagent.config.json
    \\  zagent --check [-c PATH]  validate the config and exit
    \\  zagent --version          print the version
    \\  zagent --help             print this help
    \\
    \\options:
    \\  -c, --config PATH         config file (default: zagent.config.json)
    \\  -V, --version
    \\  -h, --help
    \\
;

/// Print a user-facing message for a config load/validation failure, then exit.
fn report(path: []const u8, err: anyerror) noreturn {
    switch (err) {
        error.FileNotFound => std.debug.print("config '{s}' not found\n", .{path}),
        error.AccessDenied => std.debug.print("config '{s}': permission denied\n", .{path}),
        error.OutOfMemory => std.debug.print("out of memory loading '{s}'\n", .{path}),
        else => std.debug.print("invalid config '{s}': {t}\n", .{ path, err }),
    }
    std.process.exit(1);
}

pub fn main(init: std.process.Init) !void {
    const args = init.minimal.args;

    // No arguments: show the banner and exit.
    if (args.vector.len == 1) {
        try Writer(init.io, 2048, banner);
        return;
    }

    const cmd = cli.parse(args) catch |err| {
        std.debug.print("zagent: {t}\n", .{err});
        std.process.exit(2);
    };

    switch (cmd) {
        .version => try Writer(init.io, 64, "zagent " ++ version ++ "\n"),
        .help => try Writer(init.io, 1024, help_text),
        .init => try config.default(init.gpa, init.io),
        .check => |c| {
            const parsed = config.Config.loadValidated(init.gpa, init.io, c.config_path) catch |err| report(c.config_path, err);
            parsed.deinit();
            try Writer(init.io, 32, "config OK\n");
        },
        .run => |c| {
            const parsed = config.Config.loadValidated(init.gpa, init.io, c.config_path) catch |err| report(c.config_path, err);
            defer parsed.deinit(); // kept alive for the whole run
            // TODO: start the pipeline (the commented block below) from parsed.value.
        },
    }
}

// pub fn main(init: std.process.Init) !void {
//     var write_buffer: [1024]u8 = undefined;
//     var file_writer = std.Io.File.stdout().writer(init.io, &write_buffer);

//     var ring = try RingBuffer.init(init.gpa, init.io, 1024);
//     defer ring.deinit();

//     var t = try Tailer.open(init.gpa, init.io, std.Io.Dir.cwd(), "logs/app.log");
//     defer t.deinit();

//     // Consumer side: the Exporter drains the ring and ships batches. It runs on
//     // its own concurrent task so it makes progress while `follow` blocks polling
//     // the file. `running` is the stop flag; clearing it lets `run` return.
//     var exporter = Exporter.init(init.gpa, init.io, &ring, endpoint);
//     defer exporter.deinit();

//     var running = std.atomic.Value(bool).init(true);
//     var export_future = try init.io.concurrent(Exporter.run, .{ &exporter, &running });

//     // Second producer: snapshot system metrics on an interval into the same
//     // ring. Like the Exporter it runs on its own concurrent task; `run` parks
//     // in `io.sleep` between samples, so shutdown must `cancel` it (not `await`)
//     // to interrupt that sleep instead of waiting out the interval.
//     var sampler = Sampler.init(init.gpa, init.io, &ring, metric_interval_ms, metric_disk_path);
//     var sample_future = try init.io.concurrent(Sampler.run, .{ &sampler, &running });

//     // Producer side: follow the file forever, fanning each line out to stdout and
//     // the ring. Only returns on a fatal I/O error.
//     t.follow(&file_writer.interface, &ring, &running) catch {
//         running.store(false, .monotonic);
//         sample_future.cancel(init.io) catch {};
//         export_future.cancel(init.io) catch {};
//         std.process.exit(1);
//     };

//     // Stop the metric producer first (interrupting its sleep), then let the
//     // Exporter drain whatever is left in the ring before it returns.
//     running.store(false, .monotonic);
//     sample_future.cancel(init.io) catch {};
//     export_future.await(init.io) catch {};
// }
