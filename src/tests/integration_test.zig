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
const Counters = @import("../core/Counters.zig");
const Spool = @import("../core/Spool.zig");

fn runTailer(t: *Tailer, w: *std.Io.Writer, running: *const std.atomic.Value(bool)) void {
    t.follow(w, running) catch |e| std.log.err("tailer: {t}", .{e});
}
fn runSampler(s: *Sampler, running: *const std.atomic.Value(bool)) void {
    s.run(running) catch |e| std.log.err("sampler: {t}", .{e});
}
fn runExporter(e: *Exporter, counters: *Counters, running: *const std.atomic.Value(bool)) void {
    e.run(counters, running) catch |err| std.log.err("exporter: {t}", .{err});
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

    // Real in-process HTTP sink on an OS-assigned loopback port. Binding to
    // port 0 and reading the resolved port back avoids a hardcoded port that
    // could collide or linger in TIME_WAIT across runs.
    const addr = try net.IpAddress.parseIp4("127.0.0.1", 0);
    var server = try addr.listen(io, .{});
    const port = server.socket.address.getPort();
    var received = std.atomic.Value(usize).init(0);
    const sink = try std.Thread.spawn(.{}, runSink, .{ &server, io, &received });

    // A log file for the Tailer to follow.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const log_data = "one\ntwo\nthree\nfour\nfive\n";
    try tmp.dir.writeFile(io, .{ .sub_path = "app.log", .data = log_data });

    var ring = try RingBuffer.init(alloc, io, 256);
    defer ring.deinit();

    var spool = try Spool.open(io, tmp.dir, 1 << 20); // durable tier under the temp dir
    defer spool.deinit();

    var tailer = try Tailer.open(alloc, io, tmp.dir, "app.log", &spool, tmp.dir);
    defer tailer.deinit();

    var discard_buf: [256]u8 = undefined;
    var discard: std.Io.Writer.Discarding = .init(&discard_buf);

    var counters: Counters = .{};
    var sampler = Sampler.init(alloc, io, &ring, &counters, 50, "/"); // ticks several times

    var endpoint_buf: [64]u8 = undefined;
    const endpoint = try std.fmt.bufPrint(&endpoint_buf, "http://127.0.0.1:{d}/ingest", .{port});
    var exporter = Exporter.init(alloc, io, &ring, &spool, endpoint);
    exporter.min_send_interval_ms = 0;

    var running = std.atomic.Value(bool).init(true);
    const t1 = try std.Thread.spawn(.{}, runTailer, .{ &tailer, &discard.writer, &running });
    const t2 = try std.Thread.spawn(.{}, runSampler, .{ &sampler, &running });
    const t3 = try std.Thread.spawn(.{}, runExporter, .{ &exporter, &counters, &running });

    // Wait until the pipeline actually delivers a batch to the sink, polling
    // instead of sleeping a fixed 500ms: exits as soon as delivery is proven
    // (fast on quick machines) but tolerates a slow/loaded CI up to the bound.
    const deadline_ms: usize = 5000;
    var waited: usize = 0;
    while (received.load(.monotonic) == 0 and waited < deadline_ms) : (waited += 10) {
        try io.sleep(.fromMilliseconds(10), .awake);
    }
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
