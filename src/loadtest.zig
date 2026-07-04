//! Load/soak harness. Drives the real Tailer -> Spool -> Exporter pipeline (plus
//! the Sampler) at high volume against an in-process loopback HTTP sink, sampling
//! RSS, open fds, spool size, and the loss counters once per second. The point is
//! evidence that memory, fds, and the spool stay bounded under sustained load.
//!
//!   zig build load -- [seconds]     (default 10)

const std = @import("std");
const net = std.Io.net;

const Tailer = @import("producer/Tailer.zig");
const Sampler = @import("producer/Sampler.zig");
const Exporter = @import("consumer/Exporter.zig");
const RingBuffer = @import("core/RingBuffer.zig");
const Counters = @import("core/Counters.zig");
const Spool = @import("core/Spool.zig");

const workdir = "zig-cache/loadtest";

// --- thread bodies (real production entry points) ---

fn runTailer(t: *Tailer, w: *std.Io.Writer, running: *const std.atomic.Value(bool)) void {
    t.follow(w, running) catch |e| std.log.err("tailer: {t}", .{e});
}
fn runSampler(s: *Sampler, running: *const std.atomic.Value(bool)) void {
    s.run(running) catch |e| std.log.err("sampler: {t}", .{e});
}
fn runExporter(e: *Exporter, counters: *Counters, running: *const std.atomic.Value(bool)) void {
    e.run(counters, running) catch |err| std.log.err("exporter: {t}", .{err});
}

/// Appends batches of log lines to app.log for the run, modelling a busy service.
fn runWriter(io: std.Io, dir: std.Io.Dir, running: *const std.atomic.Value(bool), lines: *std.atomic.Value(u64)) void {
    var file = dir.openFile(io, "app.log", .{ .mode = .write_only }) catch |e| {
        std.log.err("writer open: {t}", .{e});
        return;
    };
    defer file.close(io);

    var off: u64 = 0;
    var seq: u64 = 0;
    var buf: [8192]u8 = undefined;
    // ~2000 lines/s: a sustained rate the fsync-per-record spool keeps pace with,
    // so we observe healthy steady state rather than an unbounded backlog. (The
    // spool being fsync-bound is the real ceiling; flooding past it just grows the
    // tailer's read backlog.)
    while (running.load(.monotonic)) {
        var w: usize = 0;
        var n: u64 = 0;
        while (n < 5) : (n += 1) {
            const s = std.fmt.bufPrint(buf[w..], "2026-07-04T00:00:00Z INFO req seq={d} lat_ms=12 path=/api/v1/things status=200\n", .{seq}) catch break;
            w += s.len;
            seq += 1;
        }
        file.writePositionalAll(io, buf[0..w], off) catch break;
        off += w;
        _ = lines.fetchAdd(n, .monotonic);
        io.sleep(.fromMilliseconds(10), .awake) catch break;
    }
}

/// Minimal HTTP sink: answers every request 200 until the socket is shut down.
fn runSink(server: *net.Server, io: std.Io, received: *std.atomic.Value(usize)) void {
    while (true) {
        const stream = server.accept(io) catch return;
        var read_buf: [8192]u8 = undefined;
        var write_buf: [8192]u8 = undefined;
        var sr = stream.reader(io, &read_buf);
        var sw = stream.writer(io, &write_buf);
        var http = std.http.Server.init(&sr.interface, &sw.interface);
        while (true) {
            var req = http.receiveHead() catch break;
            req.respond("", .{}) catch break;
            _ = received.fetchAdd(1, .monotonic);
        }
        stream.close(io);
    }
}

// --- /proc/self probes ---

fn readRssKib(io: std.Io) u64 {
    var f = std.Io.Dir.cwd().openFile(io, "/proc/self/status", .{ .mode = .read_only }) catch return 0;
    defer f.close(io);
    var buf: [8192]u8 = undefined;
    const n = f.readPositionalAll(io, &buf, 0) catch return 0;
    var lines = std.mem.splitScalar(u8, buf[0..n], '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "VmRSS:")) {
            var toks = std.mem.tokenizeAny(u8, line["VmRSS:".len..], " \t");
            const num = toks.next() orelse return 0;
            return std.fmt.parseInt(u64, num, 10) catch 0;
        }
    }
    return 0;
}

fn countFds(io: std.Io) usize {
    var d = std.Io.Dir.cwd().openDir(io, "/proc/self/fd", .{ .iterate = true }) catch return 0;
    defer d.close(io);
    var it = d.iterate();
    var c: usize = 0;
    while (it.next(io) catch null) |_| c += 1;
    return c;
}

fn spoolSize(io: std.Io, dir: std.Io.Dir) u64 {
    const st = dir.statFile(io, "spool/data", .{}) catch return 0;
    return st.size;
}

fn mb(kib: u64) f64 {
    return @as(f64, @floatFromInt(kib)) / 1024.0;
}

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;

    // Use a Threaded io (real OS threads, blocking syscalls) instead of the
    // runtime's event-loop io. This harness runs the pipeline on std.Thread and
    // joins them; an event-loop io that must be driven by io calls would stall
    // once main blocks in a raw join.
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const seconds: u64 = blk: {
        var it = init.minimal.args.iterate();
        _ = it.skip();
        if (it.next()) |a| break :blk std.fmt.parseInt(u64, a, 10) catch 10;
        break :blk 10;
    };

    // Fresh scratch dir for the log file + spool so each run starts clean.
    var cwd = std.Io.Dir.cwd();
    cwd.deleteTree(io, workdir) catch {};
    var dir = try cwd.createDirPathOpen(io, workdir, .{});
    defer dir.close(io);
    defer cwd.deleteTree(io, workdir) catch {};

    {
        var f = try dir.createFile(io, "app.log", .{ .truncate = true });
        f.close(io);
    }

    // Loopback sink on an OS-assigned port.
    const addr = try net.IpAddress.parseIp4("127.0.0.1", 0);
    var server = try addr.listen(io, .{});
    const port = server.socket.address.getPort();
    var received = std.atomic.Value(usize).init(0);
    const sink = try std.Thread.spawn(.{}, runSink, .{ &server, io, &received });

    // Real pipeline.
    var ring = try RingBuffer.init(alloc, io, 10_000);
    defer ring.deinit();
    var spool = try Spool.open(io, dir, 64 * 1024 * 1024);
    defer spool.deinit();

    var tailer = try Tailer.open(alloc, io, dir, "app.log", &spool, dir);
    defer tailer.deinit();

    var discard_buf: [4096]u8 = undefined;
    var discard: std.Io.Writer.Discarding = .init(&discard_buf);

    var counters: Counters = .{};
    var sampler = Sampler.init(alloc, io, &ring, &counters, 200, "/");

    var endpoint_buf: [64]u8 = undefined;
    const endpoint = try std.fmt.bufPrint(&endpoint_buf, "http://127.0.0.1:{d}/ingest", .{port});
    var exporter = Exporter.init(alloc, io, &ring, &spool, endpoint);
    exporter.min_send_interval_ms = 0;

    var running = std.atomic.Value(bool).init(true);
    var lines = std.atomic.Value(u64).init(0);

    const tw = try std.Thread.spawn(.{}, runWriter, .{ io, dir, &running, &lines });
    const t1 = try std.Thread.spawn(.{}, runTailer, .{ &tailer, &discard.writer, &running });
    const t2 = try std.Thread.spawn(.{}, runSampler, .{ &sampler, &running });
    const t3 = try std.Thread.spawn(.{}, runExporter, .{ &exporter, &counters, &running });

    // Monitor: one line per second.
    const start = std.Io.Timestamp.now(io, .awake);
    const rss0 = readRssKib(io);
    const fd0 = countFds(io);
    var rss_peak = rss0;
    var fd_peak = fd0;
    var spool_peak: u64 = 0;

    std.debug.print("\n t  rss_mb  fds  spool_kb   shipped  dropped  sendfail  received\n", .{});
    while (true) {
        const elapsed_ms = start.durationTo(std.Io.Timestamp.now(io, .awake)).toMilliseconds();
        if (elapsed_ms >= @as(i64, @intCast(seconds * 1000))) break;

        const rss = readRssKib(io);
        const fds = countFds(io);
        const sp = spoolSize(io, dir);
        rss_peak = @max(rss_peak, rss);
        fd_peak = @max(fd_peak, fds);
        spool_peak = @max(spool_peak, sp);
        const c = counters.snapshot();
        std.debug.print("{d:>2}  {d:>6.1}  {d:>3}  {d:>8}  {d:>8}  {d:>7}  {d:>8}  {d:>8}\n", .{
            @divTrunc(elapsed_ms, 1000), mb(rss), fds, sp / 1024,
            c.batches_shipped, c.spool_dropped, c.send_failures, received.load(.monotonic),
        });
        io.sleep(.fromMilliseconds(1000), .awake) catch break;
    }

    // Shutdown and join everything.
    running.store(false, .monotonic);
    tw.join();
    t1.join();
    t2.join();
    t3.join();

    // Close exporter connections before shutting the sink so its accept loop exits.
    exporter.deinit();
    const listen_stream: net.Stream = .{ .socket = server.socket };
    listen_stream.shutdown(io, .both) catch {};
    sink.join();
    server.socket.close(io);

    // Residual after everything drained and quiesced.
    const rss1 = readRssKib(io);
    const fd1 = countFds(io);
    const c = counters.snapshot();

    std.debug.print("\n=== load/soak report ({d}s) ===\n", .{seconds});
    std.debug.print("lines written  : {d}\n", .{lines.load(.monotonic)});
    std.debug.print("batches shipped: {d}\n", .{c.batches_shipped});
    std.debug.print("sink received  : {d}\n", .{received.load(.monotonic)});
    std.debug.print("spool_dropped  : {d}\n", .{c.spool_dropped});
    std.debug.print("send_failures  : {d}\n", .{c.send_failures});
    std.debug.print("RSS  MB start/peak/end: {d:.1} / {d:.1} / {d:.1}\n", .{ mb(rss0), mb(rss_peak), mb(rss1) });
    std.debug.print("fds  start/peak/end   : {d} / {d} / {d}\n", .{ fd0, fd_peak, fd1 });
    std.debug.print("spool peak KB         : {d}\n", .{spool_peak / 1024});

    // Residual growth after a full drain is the leak signal.
    const rss_growth = if (rss1 > rss0) rss1 - rss0 else 0;
    const fd_growth = if (fd1 > fd0) fd1 - fd0 else 0;
    const suspect = rss_growth > 20 * 1024 or fd_growth > 2;
    if (suspect) {
        std.debug.print("VERDICT: SUSPECT (rss +{d} KB, fds +{d})\n", .{ rss_growth, fd_growth });
        std.process.exit(1);
    }
    std.debug.print("VERDICT: OK (memory and fds bounded)\n", .{});
}
