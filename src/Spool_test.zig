const std = @import("std");
const testing = std.testing;

const Spool = @import("Spool.zig");

/// Reads the next record and asserts it equals `want`, freeing it.
fn expectNext(spool: *Spool, want: []const u8) !void {
    const rec = (try spool.next(testing.allocator)) orelse return error.UnexpectedEmpty;
    defer testing.allocator.free(rec);
    try testing.expectEqualStrings(want, rec);
}

test "append then drain in FIFO order" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var spool = try Spool.open(io, tmp.dir, 1 << 20);
    defer spool.deinit();

    try testing.expect(try spool.append("alpha"));
    try testing.expect(try spool.append("beta"));

    try expectNext(&spool, "alpha");
    try expectNext(&spool, "beta");
    try testing.expectEqual(@as(?[]u8, null), try spool.next(testing.allocator));
}

test "append returns false when a record won't fit under max_bytes" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Room for exactly one 8-byte-framed 4-byte record (12 bytes total).
    var spool = try Spool.open(io, tmp.dir, 12);
    defer spool.deinit();

    try testing.expect(try spool.append("abcd")); // 8 + 4 == 12, fits
    try testing.expect(!try spool.append("e")); // would exceed max_bytes
}

test "rewind re-reads an un-acked batch" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var spool = try Spool.open(io, tmp.dir, 1 << 20);
    defer spool.deinit();

    try testing.expect(try spool.append("one"));
    try testing.expect(try spool.append("two"));

    try expectNext(&spool, "one");
    try expectNext(&spool, "two");

    // No ack: a failed send rolls the cursor back to the last committed position.
    spool.rewind();
    try expectNext(&spool, "one");
    try expectNext(&spool, "two");
}

test "ack persists the cursor so a reopen resumes after shipped records" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        var spool = try Spool.open(io, tmp.dir, 1 << 20);
        defer spool.deinit();
        try testing.expect(try spool.append("shipped"));
        try testing.expect(try spool.append("pending"));
        try expectNext(&spool, "shipped");
        try spool.ack(); // commit consumption of "shipped" only
    }

    // Reopen: "shipped" was acked, "pending" was not, so we resume at "pending".
    var spool = try Spool.open(io, tmp.dir, 1 << 20);
    defer spool.deinit();
    try expectNext(&spool, "pending");
    try testing.expectEqual(@as(?[]u8, null), try spool.next(testing.allocator));
}

test "recoverTail drops a record whose payload CRC is corrupt" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        var spool = try Spool.open(io, tmp.dir, 1 << 20);
        defer spool.deinit();
        try testing.expect(try spool.append("good"));
        try testing.expect(try spool.append("torn"));
    }

    // Corrupt the second record's payload on disk. Layout: [4 len][4 crc][payload].
    // First frame is 8 + 4 = 12 bytes; the second payload begins at 12 + 8 = 20.
    var data = try tmp.dir.openFile(io, "spool/data", .{ .mode = .read_write });
    defer data.close(io);
    var b: [1]u8 = undefined;
    _ = try data.readPositionalAll(io, &b, 20);
    b[0] +%= 1; // flip a payload byte so the stored CRC no longer matches
    try data.writePositionalAll(io, &b, 20);

    // Reopen: recovery validates CRCs, treats the corrupt record as a torn tail,
    // and truncates it — leaving only the intact "good" record.
    var spool = try Spool.open(io, tmp.dir, 1 << 20);
    defer spool.deinit();
    try expectNext(&spool, "good");
    try testing.expectEqual(@as(?[]u8, null), try spool.next(testing.allocator));
}
