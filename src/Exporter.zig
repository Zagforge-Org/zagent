const std = @import("std");
const flate = std.compress.flate;
const RingBuffer = @import("RingBuffer.zig");
const Record = RingBuffer.Record;
const json = @import("json.zig");

const serializeJson = json.Serialize;

const Self = @This();

allocator: std.mem.Allocator,
io: std.Io,
buffer: *RingBuffer,
client: std.http.Client,

endpoint: []const u8,
auth_header: ?[]const u8,

batch_max: usize,
batch_ms: u64,
max_retries: u32,

pub fn init(allocator: std.mem.Allocator, io: std.Io, buffer: *RingBuffer, endpoint: []const u8) Self {
    return .{
        .allocator = allocator,
        .io = io,
        .buffer = buffer,
        .endpoint = endpoint,
        .auth_header = null,
        .batch_max = 100,
        .batch_ms = 2000,
        .max_retries = 5,
        .client = std.http.Client{ .allocator = allocator, .io = io },
    };
}

pub fn deinit(self: *Self) void {
    self.client.deinit();
}

pub fn run(self: *Self, running: *const bool) !void {
    var batch: std.ArrayList(Record) = .empty;
    defer batch.deinit(self.allocator);

    while (running.*) {
        const deadline = std.Io.Timestamp.now(self.io, .awake)
            .addDuration(.fromMilliseconds(@intCast(self.batch_ms)));

        // Accumulate until size threshold or time deadline.
        while (batch.items.len < self.batch_max and
            std.Io.Timestamp.now(self.io, .awake).nanoseconds < deadline.nanoseconds)
        {
            if (self.buffer.pop()) |rec| {
                try batch.append(self.allocator, rec);
            } else {
                try self.io.sleep(.fromMilliseconds(50), .awake); // buffer empty, wait
            }
        }

        if (batch.items.len == 0) continue;

        // Serialize -> gzip -> POST (with retry). On permanent failure we
        // log and drop THIS batch; everything else keeps buffering upstream.
        self.shipBatch(batch.items) catch |err| {
            std.log.err("batch failed permanently: {s}", .{@errorName(err)});
        };

        // Free each record's owned content, then reset for the next batch.
        for (batch.items) |rec| self.allocator.free(rec.content);
        batch.clearRetainingCapacity();
    }
}

fn shipBatch(self: *Self, records: []const Record) !void {
    const body = try self.encodeNdjsonGzip(records);
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

        // Exponential backoff
        const backoff_ms = @min(@as(u64, 200) << @intCast(attempt), 30_000);
        try self.io.sleep(.fromMilliseconds(@intCast(backoff_ms)), .awake);
    }
}

fn postOnce(self: *Self, body: []const u8) !u16 {
    const result = try self.client.fetch(.{
        .method = .POST,
        .location = .{ .url = self.endpoint },
        .payload = body,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/x-ndjson" },
            .{ .name = "content-encoding", .value = "gzip" },
        },
    });

    return @intFromEnum(result.status);
}

fn encodeNdjsonGzip(self: *Self, records: []const Record) ![]u8 {
    // Build the newline-delimited JSON payload: one minified object per line.
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(self.allocator);

    for (records) |record| {
        const line = try serializeJson(self.allocator, .{
            .ts = record.timestamp.nanoseconds,
            .kind = @tagName(record.kind),
            .msg = record.content,
        }, .{ .whitespace = .minified });
        defer self.allocator.free(line);

        try raw.appendSlice(self.allocator, line);
        try raw.append(self.allocator, '\n');
    }

    // Gzip-compress the payload. `window` is the deflate sliding window and
    // must be at least `flate.max_window_len`; it is heap-allocated to keep it
    // off the (potentially small) worker-thread stack.
    const window = try self.allocator.alloc(u8, flate.max_window_len);
    defer self.allocator.free(window);

    var out: std.Io.Writer.Allocating = try .initCapacity(self.allocator, 4096);
    defer out.deinit();

    var compress = try flate.Compress.init(&out.writer, window, .gzip, .default);
    try compress.writer.writeAll(raw.items);
    try compress.finish();

    return out.toOwnedSlice();
}
