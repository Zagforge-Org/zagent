const std = @import("std");
const Tailer = @import("Tailer.zig");
const RingBuffer = @import("RingBuffer.zig");
const Exporter = @import("Exporter.zig");
const Sampler = @import("Sampler.zig");

const linux = @import("linux.zig");

/// Where the Exporter ships batches. TODO: make configurable (env/flag).
const endpoint = "http://localhost:8080/ingest";

/// How often the Sampler snapshots system metrics. TODO: make configurable.
const metric_interval_ms = 5000;

/// Filesystem the Sampler reports disk usage for. TODO: make configurable.
const metric_disk_path = "/";

test {
    _ = @import("Tailer.zig");
    _ = @import("Reader.zig");
    _ = @import("RingBuffer_test.zig");
    _ = @import("Exporter_test.zig");
    _ = @import("linux_test.zig");
    _ = @import("Sampler_test.zig");
}

pub fn main(init: std.process.Init) !void {
    var write_buffer: [1024]u8 = undefined;
    var file_writer = std.Io.File.stdout().writer(init.io, &write_buffer);

    var ring = try RingBuffer.init(init.gpa, init.io, 1024);
    defer ring.deinit();

    var t = try Tailer.open(init.gpa, init.io, std.Io.Dir.cwd(), "logs/app.log");
    defer t.deinit();

    // Consumer side: the Exporter drains the ring and ships batches. It runs on
    // its own concurrent task so it makes progress while `follow` blocks polling
    // the file. `running` is the stop flag; clearing it lets `run` return.
    var exporter = Exporter.init(init.gpa, init.io, &ring, endpoint);
    defer exporter.deinit();

    var running = true;
    var export_future = try init.io.concurrent(Exporter.run, .{ &exporter, &running });

    // Second producer: snapshot system metrics on an interval into the same
    // ring. Like the Exporter it runs on its own concurrent task; `run` parks
    // in `io.sleep` between samples, so shutdown must `cancel` it (not `await`)
    // to interrupt that sleep instead of waiting out the interval.
    var sampler = Sampler.init(init.gpa, init.io, &ring, metric_interval_ms, metric_disk_path);
    var sample_future = try init.io.concurrent(Sampler.run, .{ &sampler, &running });

    // Producer side: follow the file forever, fanning each line out to stdout and
    // the ring. Only returns on a fatal I/O error.
    t.follow(&file_writer.interface, &ring, &running) catch {
        running = false;
        sample_future.cancel(init.io) catch {};
        export_future.cancel(init.io) catch {};
        std.process.exit(1);
    };

    // Stop the metric producer first (interrupting its sleep), then let the
    // Exporter drain whatever is left in the ring before it returns.
    running = false;
    sample_future.cancel(init.io) catch {};
    export_future.await(init.io) catch {};
}
