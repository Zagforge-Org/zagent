const std = @import("std");
const Tailer = @import("Tailer.zig");
const RingBuffer = @import("RingBuffer.zig");
const Exporter = @import("Exporter.zig");

const linux = @import("linux.zig");

/// Where the Exporter ships batches. TODO: make configurable (env/flag).
const endpoint = "http://localhost:8080/ingest";

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

    var ring = try RingBuffer.init(init.gpa, 1024);
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

    // Producer side: follow the file forever, fanning each line out to stdout and
    // the ring. Only returns on a fatal I/O error.
    t.follow(&file_writer.interface, &ring) catch {
        running = false;
        export_future.cancel(init.io) catch {};
        std.process.exit(1);
    };

    running = false;
    export_future.await(init.io) catch {};
}
