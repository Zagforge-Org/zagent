const std = @import("std");
const flate = std.compress.flate;
const RingBuffer = @import("RingBuffer.zig");
const Record = RingBuffer.Record;

/// The unit under test. Imported as `Self` to match the method-call style used
/// in the test bodies (`Self.init`, the `encodeNdjsonGzip` method, etc.).
const Self = @import("Exporter.zig");

const testing = std.testing;

/// Inflates a gzip stream into a freshly allocated buffer the caller owns. Used
/// by the encode tests to assert on the decompressed payload.
fn gunzip(allocator: std.mem.Allocator, compressed: []const u8) ![]u8 {
    var in: std.Io.Reader = .fixed(compressed);
    var window: [flate.max_window_len]u8 = undefined;
    var decompress: flate.Decompress = .init(&in, .gzip, &window);
    return decompress.reader.allocRemaining(allocator, .unlimited);
}

/// Builds an Exporter wired to the testing allocator/io and a throwaway ring.
/// `encodeNdjsonGzip` only touches the allocator, so the ring and client are
/// inert here; the caller must `deinit` the returned value.
fn testExporter(ring: *RingBuffer) Self {
    return Self.init(testing.allocator, testing.io, ring, "http://localhost/ingest");
}

test "encodeNdjsonGzip serializes records into gzipped NDJSON" {
    var ring = try RingBuffer.init(testing.allocator, testing.io, 1);
    defer ring.deinit();

    var exporter = testExporter(&ring);
    defer exporter.deinit();

    const records = [_]Record{
        .{ .timestamp = .{ .nanoseconds = 1 }, .content = "alpha", .kind = .log },
        .{ .timestamp = .{ .nanoseconds = 2 }, .content = "beta", .kind = .metric },
    };

    const gz = try exporter.encodeNdjsonGzip(&records);
    defer testing.allocator.free(gz);

    const plain = try gunzip(testing.allocator, gz);
    defer testing.allocator.free(plain);

    // One minified object per line, each newline-terminated (including the last).
    const expected =
        "{\"ts\":1,\"kind\":\"log\",\"msg\":\"alpha\"}\n" ++
        "{\"ts\":2,\"kind\":\"metric\",\"msg\":\"beta\"}\n";
    try testing.expectEqualStrings(expected, plain);
}

test "encodeNdjsonGzip produces a valid empty stream for no records" {
    var ring = try RingBuffer.init(testing.allocator, testing.io, 1);
    defer ring.deinit();

    var exporter = testExporter(&ring);
    defer exporter.deinit();

    const records = [_]Record{};
    const gz = try exporter.encodeNdjsonGzip(&records);
    defer testing.allocator.free(gz);

    // Still a well-formed gzip member, just with an empty payload.
    const plain = try gunzip(testing.allocator, gz);
    defer testing.allocator.free(plain);
    try testing.expectEqualStrings("", plain);
}

test "encodeNdjsonGzip JSON-escapes content" {
    var ring = try RingBuffer.init(testing.allocator, testing.io, 1);
    defer ring.deinit();

    var exporter = testExporter(&ring);
    defer exporter.deinit();

    // Quotes, backslashes and newlines in the log line must be escaped so each
    // record stays on exactly one NDJSON line.
    const records = [_]Record{
        .{ .timestamp = .{ .nanoseconds = 7 }, .content = "say \"hi\"\n\\done", .kind = .log },
    };

    const gz = try exporter.encodeNdjsonGzip(&records);
    defer testing.allocator.free(gz);

    const plain = try gunzip(testing.allocator, gz);
    defer testing.allocator.free(plain);

    const expected = "{\"ts\":7,\"kind\":\"log\",\"msg\":\"say \\\"hi\\\"\\n\\\\done\"}\n";
    try testing.expectEqualStrings(expected, plain);
}

