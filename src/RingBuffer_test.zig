const std = @import("std");
const testing = std.testing;

const RingBuffer = @import("RingBuffer.zig");
const Record = RingBuffer.Record;

// Build a *borrowed* Record from a long-lived string. We chose borrow
// semantics, so the buffer never copies `content` — the bytes just have to
// outlive the record, which string literals / test-scope buffers do.
//
// `timestamp` is irrelevant to ordering and overflow, so it's left undefined:
// no test reads it, and that sidesteps the open `std.Io.Clock` question.
fn rec(content: []const u8) Record {
    return .{
        .timestamp = undefined,
        .content = content,
        .kind = .log,
    };
}

// Pop everything and assert it comes out as `expected` in FIFO order, then
// that the buffer is empty.
fn expectDrain(rb: *RingBuffer, expected: []const []const u8) !void {
    for (expected) |want| {
        const got = rb.pop() orelse return error.UnexpectedEmpty;
        try testing.expectEqualStrings(want, got.content);
    }
    try testing.expectEqual(@as(?Record, null), rb.pop());
}

test "push then pop round-trips a single record" {
    var rb = try RingBuffer.init(testing.allocator, 4);
    defer rb.deinit();

    try rb.push(rec("a"));
    const got = rb.pop() orelse return error.UnexpectedEmpty;
    try testing.expectEqualStrings("a", got.content);
}

test "pop returns records in FIFO order (not LIFO)" {
    var rb = try RingBuffer.init(testing.allocator, 4);
    defer rb.deinit();

    try rb.push(rec("a"));
    try rb.push(rec("b"));
    try rb.push(rec("c"));
    try expectDrain(&rb, &.{ "a", "b", "c" });
}

test "pop on empty buffer returns null (fresh and after drain)" {
    var rb = try RingBuffer.init(testing.allocator, 4);
    defer rb.deinit();

    try testing.expectEqual(@as(?Record, null), rb.pop());

    try rb.push(rec("a"));
    _ = rb.pop();
    try testing.expectEqual(@as(?Record, null), rb.pop());
}

test "cursors wrap without overflow" {
    var rb = try RingBuffer.init(testing.allocator, 3);
    defer rb.deinit();

    // Fill, drain part, refill so head/tail cross the modulo boundary.
    try rb.push(rec("a"));
    try rb.push(rec("b"));
    try rb.push(rec("c")); // full
    try testing.expectEqualStrings("a", (rb.pop().?).content);
    try testing.expectEqualStrings("b", (rb.pop().?).content);
    try rb.push(rec("d"));
    try rb.push(rec("e")); // wraps

    try testing.expectEqual(@as(u64, 0), rb.dropped);
    try expectDrain(&rb, &.{ "c", "d", "e" });
}

test "exactly full: no drops, count == capacity" {
    var rb = try RingBuffer.init(testing.allocator, 3);
    defer rb.deinit();

    try rb.push(rec("a"));
    try rb.push(rec("b"));
    try rb.push(rec("c"));

    try testing.expectEqual(@as(usize, 3), rb.count);
    try testing.expectEqual(@as(u64, 0), rb.dropped);
    try expectDrain(&rb, &.{ "a", "b", "c" });
}

test "overflow by one drops the oldest record" {
    var rb = try RingBuffer.init(testing.allocator, 3);
    defer rb.deinit();

    try rb.push(rec("a")); // evicted
    try rb.push(rec("b"));
    try rb.push(rec("c"));
    try rb.push(rec("d")); // overflow

    try testing.expectEqual(@as(usize, 3), rb.count);
    try testing.expectEqual(@as(u64, 1), rb.dropped);
    try expectDrain(&rb, &.{ "b", "c", "d" });
}

test "overflow by many keeps only the last `capacity` records, in order" {
    const cap = 4;
    var rb = try RingBuffer.init(testing.allocator, cap);
    defer rb.deinit();

    const total = 2 * cap + 3; // 11
    var bufs: [total][12]u8 = undefined; // backing bytes outlive the records
    var i: usize = 0;
    while (i < total) : (i += 1) {
        const s = try std.fmt.bufPrint(&bufs[i], "{d}", .{i});
        try rb.push(rec(s));
    }

    try testing.expectEqual(@as(usize, cap), rb.count);
    try testing.expectEqual(@as(u64, total - cap), rb.dropped);

    // Survivors are the last `cap` pushed: 7, 8, 9, 10.
    i = total - cap;
    while (i < total) : (i += 1) {
        const got = rb.pop() orelse return error.UnexpectedEmpty;
        var expbuf: [12]u8 = undefined;
        const exp = try std.fmt.bufPrint(&expbuf, "{d}", .{i});
        try testing.expectEqualStrings(exp, got.content);
    }
    try testing.expectEqual(@as(?Record, null), rb.pop());
}

test "capacity 1: every push past the first evicts" {
    var rb = try RingBuffer.init(testing.allocator, 1);
    defer rb.deinit();

    try rb.push(rec("a"));
    try rb.push(rec("b"));
    try rb.push(rec("c"));

    try testing.expectEqual(@as(usize, 1), rb.count);
    try testing.expectEqual(@as(u64, 2), rb.dropped);
    try expectDrain(&rb, &.{"c"});
}

test "interleaved push/pop stays consistent" {
    var rb = try RingBuffer.init(testing.allocator, 3);
    defer rb.deinit();

    try rb.push(rec("a"));
    try rb.push(rec("b"));
    try testing.expectEqualStrings("a", (rb.pop().?).content); // [b]
    try rb.push(rec("c")); // [b, c]
    try rb.push(rec("d")); // [b, c, d] full
    try testing.expectEqual(@as(usize, 3), rb.count);
    try testing.expectEqualStrings("b", (rb.pop().?).content); // [c, d]
    try rb.push(rec("e")); // [c, d, e] full
    try rb.push(rec("f")); // evict c -> [d, e, f]

    try testing.expectEqual(@as(u64, 1), rb.dropped);
    try expectDrain(&rb, &.{ "d", "e", "f" });
}
