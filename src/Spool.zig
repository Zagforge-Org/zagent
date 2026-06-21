//! On disk durable queue is the persistence tier behind the
//! in-memory `RingBuffer`.
//! Producers append framed records to `spool/data`.
//! The consumer then reads, forwards, and advances `spool/cursor` only after a record is delivered.
//! A crash between send and cursor-commit re-sends the
//! last batch so downstream must tolerate duplicates.

const std = @import("std");
const state = @import("utils/state.zig");

const Self = @This();
const date_name = "data";
const cursor_name = "cursor";

allocator: std.mem.Allocator,
io: std.Io,
dir: std.Io.Dir,
data: std.Io.File,
write_off: u64,
read_off: u64,
max_bytes: u64,
mutex: std.Io.Mutex,

/// Open the spool under `parent`.
/// Recover any torn tail from a previous crash and load the read cursor.
pub fn open(allocator: std.mem.Allocator, io: std.Io, parent: std.Io.Dir, max_bytes: u64) !Self {
    var dir = try parent.createDirPathOpen(io, "spool", .{});
    errdefer dir.close(io);

    const data = try dir.createFile(io, date_name, .{ .read = true, .truncate = false });
    errdefer data.close(io);

    const write_off = try recoverTail(io, data);

    var cbuf: [32]u8 = undefined;

    const read_off = if (try state.readState(io, dir, cursor_name, &cbuf)) |raw|
        try std.fmt.parseInt(u64, std.mem.trim(u8, raw, " \n"), 10)
    else
        0;

    return .{
        .allocator = allocator,
        .io = io,
        .dir = dir,
        .data = data,
        .write_off = write_off,
        .read_off = read_off,
        .max_bytes = max_bytes,
    };
}

/// Walk records from 0 and return the offset at the end of
/// the last fully intact record.
fn recoverTail(io: std.Io, data: std.Io.File) !u64 {
    const size = (try data.stat(io)).size;
    var off: u64 = 0;
    var hdr: [8]u8 = undefined;

    while (off + 8 <= size) {
        if (try data.readPositionalAll(io, &hdr, off) != 8) break;
        const len = std.mem.readInt(u32, hdr[0..4], .little);
        const end = off + 8 + len;
        if (end > size) break;
        off = end;
    }
    return off;
}
