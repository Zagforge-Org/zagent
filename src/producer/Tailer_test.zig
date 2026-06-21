const std = @import("std");
const testing = std.testing;

const Tailer = @import("Tailer.zig");
const Spool = @import("../Spool.zig");

/// Reads the next spooled record and asserts its JSON line contains `want`
/// (the record is the `{ts,kind,msg}` line, not the raw content). Frees it.
fn expectSpooled(spool: *Spool, want: []const u8) !void {
    const rec = (try spool.next(testing.allocator)) orelse return error.UnexpectedEmpty;
    defer testing.allocator.free(rec);
    try testing.expect(std.mem.indexOf(u8, rec, want) != null);
}

test "readNew spools whole lines and follows appends" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const filename = "tail.log";
    try tmp.dir.writeFile(io, .{ .sub_path = filename, .data = "alpha\nbeta\n" });

    var spool = try Spool.open(io, tmp.dir, 64 * 1024 * 1024);
    defer spool.deinit();

    var t = try Tailer.open(testing.allocator, io, tmp.dir, filename, &spool, tmp.dir);
    defer t.deinit();

    var discard_buf: [64]u8 = undefined;
    var discard: std.Io.Writer.Discarding = .init(&discard_buf);

    // first poll: both complete lines are spooled, in order
    try t.readNew(&discard.writer);
    try expectSpooled(&spool, "alpha");
    try expectSpooled(&spool, "beta");
    try testing.expectEqual(@as(?[]u8, null), try spool.next(testing.allocator));

    // append a third line to the same file (same inode), at the current end
    var wf = try tmp.dir.openFile(io, filename, .{ .mode = .write_only });
    defer wf.close(io);
    try wf.writePositionalAll(io, "gamma\n", "alpha\nbeta\n".len);

    // second poll: only the newly appended line is spooled, offset continues
    try t.readNew(&discard.writer);
    try expectSpooled(&spool, "gamma");
    try testing.expectEqual(@as(?[]u8, null), try spool.next(testing.allocator));
}

test "open resumes from the persisted checkpoint after restart" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const filename = "tail.log";
    try tmp.dir.writeFile(io, .{ .sub_path = filename, .data = "alpha\nbeta\n" });

    var spool = try Spool.open(io, tmp.dir, 64 * 1024 * 1024);
    defer spool.deinit();

    var discard_buf: [64]u8 = undefined;
    var discard: std.Io.Writer.Discarding = .init(&discard_buf);

    // first run: spool both lines, which writes `tailer.offset` to state_dir
    {
        var t = try Tailer.open(testing.allocator, io, tmp.dir, filename, &spool, tmp.dir);
        defer t.deinit();
        try t.readNew(&discard.writer);
        try expectSpooled(&spool, "alpha");
        try expectSpooled(&spool, "beta");
    }

    // append while "down", then restart against the same file + state_dir
    var wf = try tmp.dir.openFile(io, filename, .{ .mode = .write_only });
    defer wf.close(io);
    try wf.writePositionalAll(io, "gamma\n", "alpha\nbeta\n".len);

    var t2 = try Tailer.open(testing.allocator, io, tmp.dir, filename, &spool, tmp.dir);
    defer t2.deinit();

    // the checkpoint was loaded: resume at the end of beta, not byte 0
    try testing.expectEqual(@as(u64, "alpha\nbeta\n".len), t2.offset);

    // so only the new line is spooled; alpha/beta are not re-shipped
    try t2.readNew(&discard.writer);
    try expectSpooled(&spool, "gamma");
    try testing.expectEqual(@as(?[]u8, null), try spool.next(testing.allocator));
}
