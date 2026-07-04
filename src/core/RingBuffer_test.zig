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
    var rb = try RingBuffer.init(testing.allocator, testing.io, 4);
    defer rb.deinit();

    try rb.push(rec("a"));
    try expectPop(&rb, "a");
}

test "pop returns records in FIFO order (not LIFO)" {
    var rb = try RingBuffer.init(testing.allocator, testing.io, 4);
    defer rb.deinit();

    try rb.push(rec("a"));
    try rb.push(rec("b"));
    try rb.push(rec("c"));
    try expectDrain(&rb, &.{ "a", "b", "c" });
}

test "pop on empty buffer returns null (fresh and after drain)" {
    var rb = try RingBuffer.init(testing.allocator, testing.io, 4);
    defer rb.deinit();

    try expectEmpty(&rb);

    try rb.push(rec("a"));
    try expectPop(&rb, "a");
    try expectEmpty(&rb);
}

test "cursors wrap without overflow" {
    var rb = try RingBuffer.init(testing.allocator, testing.io, 3);
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
    var rb = try RingBuffer.init(testing.allocator, testing.io, 3);
    defer rb.deinit();

    try rb.push(rec("a"));
    try rb.push(rec("b"));
    try rb.push(rec("c"));

    try testing.expectEqual(@as(usize, 3), rb.count);
    try testing.expectEqual(@as(u64, 0), rb.dropped);
    try expectDrain(&rb, &.{ "a", "b", "c" });
}

test "overflow by one drops the oldest record" {
    var rb = try RingBuffer.init(testing.allocator, testing.io, 3);
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
    var rb = try RingBuffer.init(testing.allocator, testing.io, cap);
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
    var rb = try RingBuffer.init(testing.allocator, testing.io, 1);
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
    var rb = try RingBuffer.init(testing.allocator, testing.io, 3);
    defer rb.deinit();

    try rb.push(rec("a"));
    try rb.push(rec("b"));
    try rb.push(rec("c"));
    try rb.push(rec("d")); // evicts "a"; "b","c","d" remain live for deinit
}

test "interleaved push/pop stays consistent" {
    var rb = try RingBuffer.init(testing.allocator, testing.io, 3);
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

// ── Concurrency: real OS threads exercising the mutex ───────────────────────
// Multiple producer threads and one consumer thread race on the ring under the
// std.Io.Threaded runtime. The invariant that proves nothing is lost or
// double-counted: every one of the `total` pushed records ends up either popped
// by the consumer (received) or evicted on overflow (dropped), so
// `received + dropped == total`. A broken lock would tear the cursors/counters
// and break that equality (or double-free and crash).

const Producer = struct {
    fn run(ring: *RingBuffer, id: usize, n: usize) void {
        var buf: [32]u8 = undefined;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            // push dupes the content, so reusing `buf` each iteration is fine.
            const s = std.fmt.bufPrint(&buf, "{d}:{d}", .{ id, i }) catch unreachable;
            ring.push(.{ .timestamp = undefined, .content = s, .kind = .metric }) catch unreachable;
        }
    }
};

const Consumer = struct {
    fn run(ring: *RingBuffer, alloc: std.mem.Allocator, done: *std.atomic.Value(bool), received: *usize) void {
        while (true) {
            if (ring.pop()) |record| {
                alloc.free(record.content);
                received.* += 1;
            } else if (done.load(.acquire)) {
                // Producers have joined and the ring drained empty: no more
                // pushes can arrive, so it is safe to stop.
                break;
            }
        }
    }
};

test "concurrent producers + consumer: received + dropped == produced" {
    // `testing.allocator` is hit from every thread; it is thread-safe in a
    // multi-threaded test build (DebugAllocator.thread_safe defaults on), which
    // this test requires anyway since it spawns OS threads.
    const alloc = testing.allocator;

    const producer_count = 4;
    const per_producer = 2000;
    const total = producer_count * per_producer;

    // Small capacity relative to `total` so overflow/eviction happens often —
    // that exercises the most write-heavy branch of `push` under contention.
    var ring = try RingBuffer.init(alloc, testing.io, 64);
    defer ring.deinit();

    var done = std.atomic.Value(bool).init(false);
    var received: usize = 0;

    const consumer = try std.Thread.spawn(.{}, Consumer.run, .{ &ring, alloc, &done, &received });

    var producers: [producer_count]std.Thread = undefined;
    for (&producers, 0..) |*t, id| t.* = try std.Thread.spawn(.{}, Producer.run, .{ &ring, id, per_producer });
    for (&producers) |t| t.join();

    done.store(true, .release);
    consumer.join();

    const dropped = ring.stats().dropped;
    try testing.expectEqual(@as(usize, total), received + @as(usize, @intCast(dropped)));
}

// ── Backpressure policies ───────────────────────────────────────────────────

test "backpressure.drop_newest keeps the oldest and rejects new records" {
    var rb = try RingBuffer.init(testing.allocator, testing.io, 3);
    rb.backpressure = .drop_newest;
    defer rb.deinit();

    try rb.push(rec("a"));
    try rb.push(rec("b"));
    try rb.push(rec("c")); // full
    try rb.push(rec("d")); // rejected
    try rb.push(rec("e")); // rejected

    try testing.expectEqual(@as(usize, 3), rb.count);
    try testing.expectEqual(@as(u64, 2), rb.dropped);
    try expectDrain(&rb, &.{ "a", "b", "c" }); // oldest survive, in order
}

test "backpressure.block never drops: received == produced, dropped == 0" {
    const alloc = testing.allocator;
    const producer_count = 4;
    const per_producer = 2000;
    const total = producer_count * per_producer;

    // Tiny capacity vs. `total`, so producers must repeatedly block on the
    // condition until the consumer frees slots. The proof of correctness:
    // nothing is dropped and every record is received.
    var ring = try RingBuffer.init(alloc, testing.io, 64);
    ring.backpressure = .block;
    defer ring.deinit();

    var done = std.atomic.Value(bool).init(false);
    var received: usize = 0;

    const consumer = try std.Thread.spawn(.{}, Consumer.run, .{ &ring, alloc, &done, &received });

    var producers: [producer_count]std.Thread = undefined;
    for (&producers, 0..) |*t, id| t.* = try std.Thread.spawn(.{}, Producer.run, .{ &ring, id, per_producer });
    for (&producers) |t| t.join();

    done.store(true, .release);
    consumer.join();

    try testing.expectEqual(@as(u64, 0), ring.stats().dropped);
    try testing.expectEqual(@as(usize, total), received);
}

const Blocker = struct {
    fn run(r: *RingBuffer) void {
        r.push(rec("b")) catch unreachable; // blocks on a full ring until close()
    }
};

test "backpressure.block: close() releases a producer blocked on a full ring" {
    var rb = try RingBuffer.init(testing.allocator, testing.io, 1);
    rb.backpressure = .block;
    defer rb.deinit();

    try rb.push(rec("a")); // capacity 1 -> full

    // Spawn a producer that blocks on a second push (no consumer ever pops).
    const th = try std.Thread.spawn(.{}, Blocker.run, .{&rb});

    // Without close() this would hang forever; close() must release it. The
    // outcome is race-free: whether the producer parked first or saw `closed`
    // immediately, it drops "b" (ring still full) and returns.
    rb.close();
    th.join();

    try testing.expectEqual(@as(u64, 1), rb.dropped); // "b" dropped on close
    try expectPop(&rb, "a"); // "a" survived
}
