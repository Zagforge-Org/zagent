//! Exporter — the consumer. Each pass it drains the in-memory `RingBuffer` onto
//! the durable `Spool`, then ships a batch from the spool to an HTTP ingest
//! endpoint as gzipped NDJSON. The spool cursor is committed (`ack`) only after
//! a 2xx; a permanent failure `rewind`s so the batch is retried and survives a
//! crash/outage. At-least-once delivery; downstream must tolerate duplicates.

const std = @import("std");
const flate = std.compress.flate;
const RingBuffer = @import("../core/RingBuffer.zig");
const Spool = @import("../Spool.zig");
const Counters = @import("../Counters.zig");
const Record = RingBuffer.Record;
const json = @import("../utils/json.zig");
const toJsonLine = @import("../wire.zig").toJsonLine;

const serializeJson = json.Serialize;

const Self = @This();

allocator: std.mem.Allocator,
io: std.Io,

/// In-memory queue the producers fill.
buffer: *RingBuffer,

/// Durable on-disk queue records pass through before shipping.
spool: *Spool,

/// HTTP client for sending requests.
client: std.http.Client,

/// POST endpoint for metrics/logs.
endpoint: []const u8,

/// Optional Authorization header value.
auth_header: ?[]const u8,

/// Maximum records shipped per request.
batch_max: usize,

/// Maximum send retries before dropping a batch attempt.
max_retries: u32,

/// Minimum time between the start of consecutive sends.
min_send_interval_ms: u64,

/// awake (monotonic) timestamp of the last send start.
last_send: std.Io.Timestamp,

pub fn init(allocator: std.mem.Allocator, io: std.Io, buffer: *RingBuffer, spool: *Spool, endpoint: []const u8) Self {
    return .{
        .allocator = allocator,
        .io = io,
        .buffer = buffer,
        .spool = spool,
        .endpoint = endpoint,
        .auth_header = null,
        .batch_max = 100,
        .min_send_interval_ms = 200,
        .last_send = .zero,
        .max_retries = 5,
        .client = std.http.Client{ .allocator = allocator, .io = io },
    };
}

pub fn deinit(self: *Self) void {
    self.client.deinit();
}

pub fn run(self: *Self, counters: *Counters, running: *const std.atomic.Value(bool)) !void {
    // Wake any producer blocked on a full ring in `.block` mode when we leave.
    defer self.buffer.close();

    while (running.load(.monotonic)) {
        self.drainRing(counters);

        // Build a batch of NDJSON from the spool.
        var raw: std.ArrayList(u8) = .empty;
        defer raw.deinit(self.allocator);
        var count: usize = 0;
        while (count < self.batch_max) {
            const line = (self.spool.next(self.allocator) catch |err| {
                std.log.err("spool read: {t}", .{err});
                break;
            }) orelse break;
            defer self.allocator.free(line);
            try raw.appendSlice(self.allocator, line);
            try raw.append(self.allocator, '\n');
            count += 1;
        }

        if (count == 0) {
            try self.io.sleep(.fromMilliseconds(50), .awake); // nothing pending
            continue;
        }

        // Rate limit so a backlog can't hammer a healthy server.
        const now = std.Io.Timestamp.now(self.io, .awake);
        const elapsed_ms = self.last_send.durationTo(now).toMilliseconds();
        const interval_ms: i64 = @intCast(self.min_send_interval_ms);
        if (elapsed_ms < interval_ms) {
            try self.io.sleep(.fromMilliseconds(interval_ms - elapsed_ms), .awake);
        }
        self.last_send = std.Io.Timestamp.now(self.io, .awake);

        // Commit the cursor on success.
        // on permanent failure rewind so the batch stays
        // durably spooled and is retried on the next pass.
        self.shipBatch(raw.items) catch |err| {
            std.log.err("batch failed permanently: {t}", .{err});
            counters.incrementSendFailure();
            self.spool.rewind();
            continue;
        };
        try self.spool.ack();
        counters.incrementShipped();
    }

    // Shutdown drain: flush records pushed since the last iteration to the
    // durable spool. No ship - the spool replays on next start.
    self.drainRing(counters);

    const s = counters.snapshot();
    std.log.info("exporter stopped: shipped={d} spool_dropped={d} send_failures={d}", .{ s.batches_shipped, s.spool_dropped, s.send_failures });
}

/// Drain the ring onto the durable spool, freeing each record after handoff.
pub fn drainRing(self: *Self, counters: *Counters) void {
    while (self.buffer.pop()) |rec| {
        self.spoolRecord(rec, counters) catch |err| std.log.err("spool append: {t}", .{err});
        self.allocator.free(rec.content);
    }
}

/// Format one record as a minified `{ts,kind,msg}` JSON object and append it
/// durably to the spool.
pub fn spoolRecord(self: *Self, rec: Record, counters: *Counters) !void {
    const line = try toJsonLine(rec, self.allocator);
    defer self.allocator.free(line);

    if (!try self.spool.append(line)) {
        counters.incrementDropped();
        std.log.warn("spool full; dropping record", .{});
    }
}

/// Gzip + POST the NDJSON `body` with retry and exponential backoff.
fn shipBatch(self: *Self, body_ndjson: []const u8) !void {
    const body = try self.gzip(body_ndjson);
    defer self.allocator.free(body);

    var attempt: usize = 0;
    while (true) : (attempt += 1) {
        if (self.postOnce(body)) |status| {
            if (status >= 200 and status < 300) return;
            std.log.warn("server returned {d}", .{status});
        } else |err| {
            std.log.warn("post error: {s}", .{@errorName(err)});
        }

        if (attempt >= self.max_retries) return error.MaxRetriesExceeded;

        const backoff_ms = @min(@as(u64, 200) << @intCast(attempt), 30_000);
        try self.io.sleep(.fromMilliseconds(@intCast(backoff_ms)), .awake);
    }
}

/// Send a `POST` to the ingest endpoint.
/// Returns the HTTP status code.
fn postOnce(self: *Self, body: ?[]const u8) !u16 {
    var headers: [3]std.http.Header = .{
        .{ .name = "content-type", .value = "application/x-ndjson" },
        .{ .name = "content-encoding", .value = "gzip" },
        undefined,
    };
    var n: usize = 2;
    if (self.auth_header) |auth| {
        headers[n] = .{ .name = "authorization", .value = auth };
        n += 1;
    }

    const result = try self.client.fetch(.{
        .method = .POST,
        .location = .{ .url = self.endpoint },
        .payload = body,
        .extra_headers = headers[0..n],
    });

    return @intFromEnum(result.status);
}

/// Gzip-compress `raw` bytes.
pub fn gzip(self: *Self, raw: []const u8) ![]u8 {
    // heap it to keep it off the worker-thread stack.
    const window = try self.allocator.alloc(u8, flate.max_window_len);
    defer self.allocator.free(window);

    var out: std.Io.Writer.Allocating = try .initCapacity(self.allocator, 4096);
    defer out.deinit();

    var compress = try flate.Compress.init(&out.writer, window, .gzip, .default);
    try compress.writer.writeAll(raw);
    try compress.finish();

    return out.toOwnedSlice();
}
