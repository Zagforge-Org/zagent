const std = @import("std");
const Tailer = @import("producer/Tailer.zig");
const RingBuffer = @import("core/RingBuffer.zig");
const Exporter = @import("consumer/Exporter.zig");
const Sampler = @import("producer/Sampler.zig");
const Spool = @import("Spool.zig");
const Writer = @import("utils/writer.zig").Writer;
const Counters = @import("Counters.zig");
const config = @import("config/config.zig");
const state = @import("utils/state.zig");

const linux = @import("platform/linux.zig");
const cli = @import("cli.zig");

// TODO:
// Clarify counter semantics
// Fix one-sample shutdown race
// Spool cursor isn't power-loss durable
// Load/soak evidence
// Ops basics

/// zagent's semantic version. Keep in sync with `build.zig.zon`.
const version = "0.0.4";
comptime {
    // Fail the build if `version` isn't a valid semver.
    _ = std.SemanticVersion.parse(version) catch @compileError("`version` must be a valid semantic version");
}

test {
    _ = @import("producer/Tailer_test.zig");
    _ = @import("Spool_test.zig");
    _ = @import("core/RingBuffer_test.zig");
    _ = @import("consumer/Exporter_test.zig");
    _ = @import("platform/linux_test.zig");
    _ = @import("producer/Sampler_test.zig");
    _ = @import("tests/integration_test.zig");
    _ = @import("config/validation_test.zig");
    _ = @import("utils/state_test.zig");
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

// TODO: tailer offset checkpointing (disk-spooling is wired via Spool)

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
            defer parsed.deinit(); // the pipeline borrows cfg's strings; keep it alive
            const cfg = parsed.value;

            // `run` needs a concrete file to tail and an endpoint to ship to;
            // validation permits these to be null, so require them here.
            const log_path = cfg.log_paths orelse {
                std.debug.print("config: `log_paths` is required to run\n", .{});
                std.process.exit(1);
            };
            const ship_endpoint = cfg.endpoint orelse {
                std.debug.print("config: `endpoint` is required to run\n", .{});
                std.process.exit(1);
            };

            var write_buffer: [1024]u8 = undefined;
            var file_writer = std.Io.File.stdout().writer(init.io, &write_buffer);

            var ring = try RingBuffer.init(init.gpa, init.io, cfg.buffer_capacity);
            ring.backpressure = cfg.backpressure;
            defer ring.deinit();

            // Durable tier behind the ring: $HOME/.zagent/spool/. Records pass
            // through here before shipping, so a crash/outage replays them.
            var state_dir = try state.openStateDir(init.io, init.environ_map);
            defer state_dir.close(init.io);

            var spool = try Spool.open(init.io, state_dir, cfg.spool_max_bytes);
            defer spool.deinit();

            var t = Tailer.open(init.gpa, init.io, std.Io.Dir.cwd(), log_path, &spool, state_dir) catch |err| {
                std.debug.print("cannot open log file '{s}': {t}\n", .{ log_path, err });
                std.process.exit(1);
            };
            t.max_line = cfg.max_line_bytes;
            defer t.deinit();

            // Shared loss/throughput tallies: written by the exporter, read by
            // the sampler to fold into telemetry. Lives for the whole run scope.
            var counters: Counters = .{};

            // Consumer: drain the ring and ship batches on its own task.
            var exporter = Exporter.init(init.gpa, init.io, &ring, &spool, ship_endpoint);
            exporter.batch_max = cfg.batch_max;
            exporter.max_retries = cfg.max_retries;
            exporter.auth_header = cfg.auth_header;
            defer exporter.deinit();

            var running = std.atomic.Value(bool).init(true);
            linux.installSignalHandlers(&running);
            defer linux.clearSignalHandlers();
            var export_future = try init.io.concurrent(Exporter.run, .{ &exporter, &counters, &running });

            // Second producer: sample system metrics on an interval into the ring.
            var sampler = Sampler.init(init.gpa, init.io, &ring, &counters, cfg.metric_interval_ms, cfg.disk_path);
            var sample_future = try init.io.concurrent(Sampler.run, .{ &sampler, &running });

            // Producer: follow the log file forever on this task; returns only on
            // a fatal I/O error.
            t.follow(&file_writer.interface, &running) catch {
                running.store(false, .monotonic);
                sample_future.cancel(init.io) catch {};
                export_future.cancel(init.io) catch {};
                std.process.exit(1);
            };

            // Stop the metric producer (interrupting its sleep), then let the
            // Exporter drain what remains before returning.
            running.store(false, .monotonic);
            sample_future.cancel(init.io) catch {};
            export_future.await(init.io) catch {};
        },
    }
}
