const std = @import("std");
const testing = std.testing;

const RingBuffer = @import("RingBuffer.zig");
const Record = RingBuffer.Record;

// The buffer owns `content`: `push` copies the caller's bytes and `pop`
// transfers ownership of that copy back to us, so every popped record's content
// must be freed or `testing.allocator` reports a leak. `deinit` frees whatever
// is still live (un-popped). `timestamp` is irrelevant to ordering/overflow, so
// it's left undefined — no test reads it.
fn rec(content: []const u8) Record {
    return .{
        .timestamp = undefined,
        .content = content,
        .kind = .log,
    };
}

// Pop one record, assert its content, and free it.
fn expectPop(rb: *RingBuffer, want: []const u8) !void {
    const got = rb.pop() orelse return error.UnexpectedEmpty;
    defer testing.allocator.free(got.content);
    try testing.expectEqualStrings(want, got.content);
}

fn expectEmpty(rb: *RingBuffer) !void {
    try testing.expectEqual(@as(?Record, null), rb.pop());
}

// Pop everything and assert it comes out as `expected` in FIFO order, then that
// the buffer is empty.
fn expectDrain(rb: *RingBuffer, expected: []const []const u8) !void {
    for (expected) |want| try expectPop(rb, want);
    try expectEmpty(rb);
}

test "push then pop round-trips a single record" {
    var rb = try RingBuffer.init(testing.allocator, 4);
    defer rb.deinit();

    try rb.push(rec("a"));
    try expectPop(&rb, "a");
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

    try expectEmpty(&rb);

    try rb.push(rec("a"));
    try expectPop(&rb, "a");
    try expectEmpty(&rb);
}

test "cursors wrap without overflow" {
    var rb = try RingBuffer.init(testing.allocator, 3);
    defer rb.deinit();

    // Fill, drain part, refill so head/tail cross the modulo boundary.
    try rb.push(rec("a"));
    try rb.push(rec("b"));
    try rb.push(rec("c")); // full
    try expectPop(&rb, "a");
    try expectPop(&rb, "b");
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
    var bufs: [total][12]u8 = undefined;
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
        var expbuf: [12]u8 = undefined;
        const exp = try std.fmt.bufPrint(&expbuf, "{d}", .{i});
        try expectPop(&rb, exp);
    }
    try expectEmpty(&rb);
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

test "deinit frees live (un-popped) records" {
    // No explicit frees here: deinit must release the content of records left
    // in the buffer, or testing.allocator fails the test.
    var rb = try RingBuffer.init(testing.allocator, 3);
    defer rb.deinit();

    try rb.push(rec("a"));
    try rb.push(rec("b"));
    try rb.push(rec("c"));
    try rb.push(rec("d")); // evicts "a"; "b","c","d" remain live for deinit
}

test "interleaved push/pop stays consistent" {
    var rb = try RingBuffer.init(testing.allocator, 3);
    defer rb.deinit();

    try rb.push(rec("a"));
    try rb.push(rec("b"));
    try expectPop(&rb, "a"); // [b]
    try rb.push(rec("c")); // [b, c]
    try rb.push(rec("d")); // [b, c, d] full
    try testing.expectEqual(@as(usize, 3), rb.count);
    try expectPop(&rb, "b"); // [c, d]
    try rb.push(rec("e")); // [c, d, e] full
    try rb.push(rec("f")); // evict c -> [d, e, f]

    try testing.expectEqual(@as(u64, 1), rb.dropped);
    try expectDrain(&rb, &.{ "d", "e", "f" });
}
