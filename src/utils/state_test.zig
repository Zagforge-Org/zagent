const std = @import("std");
const testing = std.testing;

const state = @import("state.zig");

test "readState returns null when the file does not exist (first run)" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [64]u8 = undefined;
    try testing.expectEqual(@as(?[]u8, null), try state.readState(testing.io, tmp.dir, "offset", &buf));
}

test "writeAtomic then readState round-trips the bytes" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try state.writeAtomic(testing.io, tmp.dir, "offset", "hello world");

    var buf: [64]u8 = undefined;
    const got = (try state.readState(testing.io, tmp.dir, "offset", &buf)) orelse return error.MissingState;
    try testing.expectEqualStrings("hello world", got);
}

test "writeAtomic overwrites cleanly with a shorter value (no stale tail)" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try state.writeAtomic(testing.io, tmp.dir, "offset", "first-long-value");
    try state.writeAtomic(testing.io, tmp.dir, "offset", "v2"); // shorter

    var buf: [64]u8 = undefined;
    const got = (try state.readState(testing.io, tmp.dir, "offset", &buf)) orelse return error.MissingState;
    // If the write didn't truncate, we'd see "v2rst-long-value".
    try testing.expectEqualStrings("v2", got);
}

test "writeAtomic leaves no temp file behind" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try state.writeAtomic(testing.io, tmp.dir, "offset", "x");

    // The temp must have been renamed away, not left dangling.
    try testing.expectError(error.FileNotFound, tmp.dir.openFile(testing.io, "offset.tmp", .{ .mode = .read_only }));
}

test "writeAtomic recovers from a leftover temp from a crashed run" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Simulate a previous crash that left a partial temp file.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "offset.tmp", .data = "garbage-partial-write" });

    // A fresh write must still succeed and produce the correct contents
    // (createFile truncates the stale temp).
    try state.writeAtomic(testing.io, tmp.dir, "offset", "clean");

    var buf: [64]u8 = undefined;
    const got = (try state.readState(testing.io, tmp.dir, "offset", &buf)) orelse return error.MissingState;
    try testing.expectEqualStrings("clean", got);
}
