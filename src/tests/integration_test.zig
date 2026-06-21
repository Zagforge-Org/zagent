//! E2E concurrency test. 2 producers and consumer run on real OS threads against one shared,
//! mutex guarded `RingBuffer`, shipping to a real HTTP sink.
//! Reaching asserts without deadlock, crash, or allocator leak. The sink receiving batches proves E2e delivery.

const std = @import("std");
const testing = std.testing;
const net = std.Io.net;

const Tailer = @import("../producer/Tailer.zig");
const Sampler = @import("../producer/Sampler.zig");
const Exporter = @import("../consumer/Exporter.zig");
const RingBuffer = @import("../core/RingBuffer.zig");
const Spool = @import("../Spool.zig");

fn runTailer(t: *Tailer, w: *std.Io.Writer, ring: *RingBuffer, running: *const std.atomic.Value(bool)) void {
    t.follow(w, ring, running) catch |e| std.log.err("tailer: {t}", .{e});
}
fn runSampler(s: *Sampler, running: *const std.atomic.Value(bool)) void {
    s.run(running) catch |e| std.log.err("sampler: {t}", .{e});
}
fn runExporter(e: *Exporter, running: *const std.atomic.Value(bool)) void {
    e.run(running) catch |err| std.log.err("exporter: {t}", .{err});
}

/// runSink is a minimal HTTP sink that accepts connections and answers every request 200.
/// `respond` discards reqeust body, so keep-alive connections just work.
/// Stops when the listening socket is closed.
fn runSink(server: *net.Server, io: std.Io, received: *std.atomic.Value(usize)) void {
    while (true) {
        const stream = server.accept(io) catch return;

        var read_buf: [8192]u8 = undefined;
        var write_buf: [8192]u8 = undefined;

        var sr = stream.reader(io, &read_buf);
        var sw = stream.writer(io, &write_buf);
        var http = std.http.Server.init(&sr.interface, &sw.interface);

        while (true) {
            var req = http.receiveHead() catch break; // peer closed
            req.respond("", .{}) catch break;
            _ = received.fetchAdd(1, .monotonic);
        }
        stream.close(io);
    }
}

test "integration: tailer + sampler + exporter deliver to a sink and shut down cleanly" {
    const io = testing.io;
    const alloc = testing.allocator;

    // Real in-process HTTP sink on a fixed loopback port.
    const port = 39517;
    const addr = try net.IpAddress.parseIp4("127.0.0.1", port);
    var server = try addr.listen(io, .{});
    var received = std.atomic.Value(usize).init(0);
    const sink = try std.Thread.spawn(.{}, runSink, .{ &server, io, &received });

    // A log file for the Tailer to follow.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const log_data = "one\ntwo\nthree\nfour\nfive\n";
    try tmp.dir.writeFile(io, .{ .sub_path = "app.log", .data = log_data });

    var ring = try RingBuffer.init(alloc, io, 256);
    defer ring.deinit();

    var tailer = try Tailer.open(alloc, io, tmp.dir, "app.log");
    defer tailer.deinit();

    var discard_buf: [256]u8 = undefined;
    var discard: std.Io.Writer.Discarding = .init(&discard_buf);

    var sampler = Sampler.init(alloc, io, &ring, 50, "/"); // ticks several times

    var spool = try Spool.open(io, tmp.dir, 1 << 20); // durable tier under the temp dir
    defer spool.deinit();

    var exporter = Exporter.init(alloc, io, &ring, &spool, "http://127.0.0.1:39517/ingest");
    exporter.batch_ms = 50; // ship frequently within the run window
    exporter.min_send_interval_ms = 0;

    var running = std.atomic.Value(bool).init(true);
    const t1 = try std.Thread.spawn(.{}, runTailer, .{ &tailer, &discard.writer, &ring, &running });
    const t2 = try std.Thread.spawn(.{}, runSampler, .{ &sampler, &running });
    const t3 = try std.Thread.spawn(.{}, runExporter, .{ &exporter, &running });

    // Let all three work against the shared ring, then signal shutdown.
    try io.sleep(.fromMilliseconds(500), .awake);
    running.store(false, .monotonic);
    t1.join();
    t2.join();
    t3.join();

    // Tear down consumer connections then `shutdown` the listening socket.
    exporter.deinit();
    const listen_stream: net.Stream = .{ .socket = server.socket };
    listen_stream.shutdown(io, .both) catch {};
    sink.join();
    server.socket.close(io);

    // Both producers did real work...
    try testing.expectEqual(@as(u64, log_data.len), tailer.offset); // tailer read the whole file
    try testing.expect(sampler.prev_cpu != null); // sampler ticked at least once
    // ...and the pipeline actually delivered to the sink.
    try testing.expect(received.load(.monotonic) > 0);
}
