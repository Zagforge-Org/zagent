const std = @import("std");
const flate = std.compress.flate;
const RingBuffer = @import("../core/RingBuffer.zig");
const Spool = @import("../Spool.zig");

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
