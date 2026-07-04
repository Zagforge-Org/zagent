const std = @import("std");
const flate = std.compress.flate;
const RingBuffer = @import("../core/RingBuffer.zig");
const Spool = @import("../Spool.zig");
const Counters = @import("../Counters.zig");

/// The unit under test.
const Self = @import("Exporter.zig");

const testing = std.testing;

/// Inflate a gzip stream into a fresh buffer the caller owns.
fn gunzip(allocator: std.mem.Allocator, compressed: []const u8) ![]u8 {
    var in: std.Io.Reader = .fixed(compressed);
    var window: [flate.max_window_len]u8 = undefined;
    var decompress: flate.Decompress = .init(&in, .gzip, &window);
    return decompress.reader.allocRemaining(allocator, .unlimited);
}

test "gzip round-trips NDJSON" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var ring = try RingBuffer.init(testing.allocator, testing.io, 1);
    defer ring.deinit();
    var spool = try Spool.open(testing.io, tmp.dir, 1 << 20);
    defer spool.deinit();

    var exporter = Self.init(testing.allocator, testing.io, &ring, &spool, "http://localhost/ingest");
    defer exporter.deinit();

    const ndjson =
        "{\"ts\":1,\"kind\":\"log\",\"msg\":\"alpha\"}\n" ++
        "{\"ts\":2,\"kind\":\"metric\",\"msg\":\"beta\"}\n";

    const gz = try exporter.gzip(ndjson);
    defer testing.allocator.free(gz);

    const plain = try gunzip(testing.allocator, gz);
    defer testing.allocator.free(plain);

    try testing.expectEqualStrings(ndjson, plain);
}

test "gzip produces a valid empty stream for empty input" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var ring = try RingBuffer.init(testing.allocator, testing.io, 1);
    defer ring.deinit();
    var spool = try Spool.open(testing.io, tmp.dir, 1 << 20);
    defer spool.deinit();

    var exporter = Self.init(testing.allocator, testing.io, &ring, &spool, "http://localhost/ingest");
    defer exporter.deinit();

    const gz = try exporter.gzip("");
    defer testing.allocator.free(gz);

    const plain = try gunzip(testing.allocator, gz);
    defer testing.allocator.free(plain);
    try testing.expectEqualStrings("", plain);
}

test "drainRing flushes ring records to the durable spool in FIFO order" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var ring = try RingBuffer.init(testing.allocator, testing.io, 4);
    defer ring.deinit();
    var spool = try Spool.open(testing.io, tmp.dir, 1 << 20);
    defer spool.deinit();

    var counters: Counters = .{};
    var exporter = Self.init(testing.allocator, testing.io, &ring, &spool, "http://localhost/ingest");
    defer exporter.deinit();

    // Two records sit in the volatile ring, unshipped.
    try ring.push(.{ .kind = .metric, .timestamp = .zero, .content = "alpha" });
    try ring.push(.{ .kind = .metric, .timestamp = .zero, .content = "beta" });

    // The shutdown drain must move both onto the durable spool, in order.
    exporter.drainRing(&counters);

    const first = (try spool.next(testing.allocator)) orelse return error.NothingSpooled;
    defer testing.allocator.free(first);
    try testing.expect(std.mem.indexOf(u8, first, "\"msg\":\"alpha\"") != null);

    const second = (try spool.next(testing.allocator)) orelse return error.NothingSpooled;
    defer testing.allocator.free(second);
    try testing.expect(std.mem.indexOf(u8, second, "\"msg\":\"beta\"") != null);

    try testing.expectEqual(@as(?[]u8, null), try spool.next(testing.allocator));
    // A successful drain is not loss.
    try testing.expectEqual(@as(u64, 0), counters.snapshot().spool_dropped);
}

test "spoolRecord counts a drop when the spool is full" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var ring = try RingBuffer.init(testing.allocator, testing.io, 1);
    defer ring.deinit();
    // max_bytes 1 is smaller than any framed record, so every append is rejected.
    var spool = try Spool.open(testing.io, tmp.dir, 1);
    defer spool.deinit();

    var counters: Counters = .{};
    var exporter = Self.init(testing.allocator, testing.io, &ring, &spool, "http://localhost/ingest");
    defer exporter.deinit();

    try exporter.spoolRecord(.{ .kind = .metric, .timestamp = .zero, .content = "x" }, &counters);
    try exporter.spoolRecord(.{ .kind = .metric, .timestamp = .zero, .content = "y" }, &counters);

    // Both records were popped, rejected by the full spool, and lost - and the
    // loss counter proves it's observable rather than silent.
    try testing.expectEqual(@as(u64, 2), counters.snapshot().spool_dropped);
}
