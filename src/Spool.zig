//! On disk durable queue is the persistence tier behind the
//! in-memory `RingBuffer`.
//! Producers append framed records to `spool/data`.
//! The consumer then reads, forwards, and advances `spool/cursor` only after a record is delivered.
//! A crash between send and cursor-commit re-sends the
//! last batch so downstream must tolerate duplicates.

const std = @import("std");
const state = @import("utils/state.zig");

const Self = @This();
const data_name = "data";
const cursor_name = "cursor";

io: std.Io,
dir: std.Io.Dir,
data: std.Io.File,
write_off: u64,
read_off: u64,
acked_off: u64, // last durably-committed read position (for rewind on failure)
max_bytes: u64,
mutex: std.Io.Mutex = .init,

/// Open the spool under `parent`.
/// Recover any torn tail from a previous crash and load the read cursor.
pub fn open(io: std.Io, parent: std.Io.Dir, max_bytes: u64) !Self {
    var dir = try parent.createDirPathOpen(io, "spool", .{});
    errdefer dir.close(io);

    const data = try dir.createFile(io, data_name, .{ .read = true, .truncate = false });
    errdefer data.close(io);

    const write_off = try recoverTail(io, data);
    try data.setLength(io, write_off); // drop a torn tail left by a previous crash

    var cbuf: [32]u8 = undefined;

    const read_off = if (try state.readState(io, dir, cursor_name, &cbuf)) |raw|
        try std.fmt.parseInt(u64, std.mem.trim(u8, raw, " \n"), 10)
    else
        0;

    return .{
        .io = io,
        .dir = dir,
        .data = data,
        .write_off = write_off,
        .read_off = read_off,
        .acked_off = read_off, // cursor on disk == last committed position
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

/// Append `payload` as a framed record and fsync it.
/// Returns `false` if it won't fit under `max_bytes`
pub fn append(self: *Self, payload: []const u8) !bool {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    const len: u32 = @intCast(payload.len);
    const frame_len: u64 = 8 + @as(u64, len);

    if (self.write_off + frame_len > self.max_bytes) return false;

    var hdr: [8]u8 = undefined;
    std.mem.writeInt(u32, hdr[0..4], len, .little);
    std.mem.writeInt(u32, hdr[4..8], std.hash.crc.Crc32.hash(payload), .little);

    try self.data.writePositionalAll(self.io, &hdr, self.write_off);
    try self.data.writePositionalAll(self.io, payload, self.write_off + 8);
    try self.data.sync(self.io);

    self.write_off += frame_len;
    return true;
}

/// Read record at the read cursor into `buf` and advance cursor.
/// Returns `null` when caught up and errors if the record
/// exceeds `buf`.
pub fn next(self: *Self, buf: []u8) !?[]u8 {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    if (self.read_off >= self.write_off) return null; // caught up

    var hdr: [8]u8 = undefined;
    if (try self.data.readPositionalAll(self.io, &hdr, self.read_off) != hdr.len)
        return error.ShortRead;

    const len = std.mem.readInt(u32, hdr[0..4], .little);
    const crc = std.mem.readInt(u32, hdr[4..8], .little);

    if (len > buf.len) return error.BufferTooSmall;

    const payload = buf[0..len];
    if (try self.data.readPositionalAll(self.io, payload, self.read_off + 8) != payload.len)
        return error.ShortRead;

    if (std.hash.crc.Crc32.hash(payload) != crc) return error.CorruptRecord;

    self.read_off += 8 + @as(u64, len);

    return payload;
}

/// Durably commit consumption progress by persisting in-memory read
/// cursor so a restart resumes after records already shipped.
/// Call once after successful send.
pub fn ack(self: *Self) !void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    if (self.read_off == self.write_off) {
        try self.data.setLength(self.io, 0);
        self.read_off = 0;
        self.write_off = 0;
    }

    var buf: [20]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, "{d}", .{self.read_off});
    try state.writeAtomic(self.io, self.dir, cursor_name, text);

    self.acked_off = self.read_off; // now durably committed
}

/// Roll the in-memory read cursor back to the last acked position, so a batch
/// that failed to ship is re-read on the next pass instead of skipped. Call on
/// a permanent send failure (the records stay durably in the spool).
pub fn rewind(self: *Self) void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    self.read_off = self.acked_off;
}

pub fn deinit(self: *Self) void {
    self.data.close(self.io);
    self.dir.close(self.io);
}
