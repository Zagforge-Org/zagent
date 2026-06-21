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

mutex: std.Io.Mutex = .init,

dir: std.Io.Dir,

data: std.Io.File,

/// Represents EOF (end of file) where the next append writes.
/// Everything before it is real records and anything after is empty space.
write_off: u64,

/// Represents consumer's read head where `next()` reads the next record.
/// Each `next()` adnvaces it past one frame.
read_off: u64,

/// Represents dead, shipped and confirmed data.
/// Anything inside of this block is waste and reclaimed.
acked_off: u64,

/// Represents the maximum amount of storage
/// before we start reclaiming space.
max_bytes: u64,

/// Represents the trigger point for compaction.
/// Once the threshold is met, we start compacting.
reclaim_threshold: u64,

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
        .reclaim_threshold = max_bytes / 2,
        .acked_off = read_off, // cursor on disk == last committed position
        .max_bytes = max_bytes,
    };
}

/// Walk records from 0 and return the offset at the end of the last fully
/// intact record. "Intact" means both the framing fits within the file and
/// the payload matches its stored CRC.
fn recoverTail(io: std.Io, data: std.Io.File) !u64 {
    const size = (try data.stat(io)).size;
    var off: u64 = 0;
    var hdr: [8]u8 = undefined;

    while (off + 8 <= size) {
        if (try data.readPositionalAll(io, &hdr, off) != 8) break;
        const len = std.mem.readInt(u32, hdr[0..4], .little);
        const crc = std.mem.readInt(u32, hdr[4..8], .little);
        const end = off + 8 + len;
        if (end > size) break; // payload runs past EOF: torn tail

        // Stream the payload through the CRC in chunks so we never allocate.
        var hasher = std.hash.crc.Crc32.init();
        var pos = off + 8;
        var buf: [4096]u8 = undefined;
        while (pos < end) {
            const want: usize = @intCast(@min(@as(u64, buf.len), end - pos));
            if (try data.readPositionalAll(io, buf[0..want], pos) != want) break;
            hasher.update(buf[0..want]);
            pos += want;
        }
        if (pos != end or hasher.final() != crc) break; // short read or bad CRC: torn tail

        off = end;
    }
    return off;
}

/// Reclaim the dead prefix `[0, acked_off)` by sliding the live range down to
/// offset 0 and shrinking the file. Cursor-first ordering: a crash after the cursor write
/// but before the rename re-ships the dead prefix once.
/// Not power-loss durable.
fn compact(self: *Self) !void {
    const delta = self.read_off;

    if (delta == 0) return;

    // Commit the new read position (0) before touching the data file.
    try state.writeAtomic(self.io, self.dir, cursor_name, "0");

    var tmp = try self.dir.createFile(self.io, "data.tmp", .{ .read = true, .truncate = true });
    defer tmp.close(self.io);

    var copied: u64 = 0;
    const live = self.write_off - delta;
    var buf: [32 * 1024]u8 = undefined;
    while (copied < live) {
        const want: usize = @intCast(@min(buf.len, live - copied));
        if (try self.data.readPositionalAll(self.io, buf[0..want], delta + copied) != want) {
            return error.ShortRead;
        }
        try tmp.writePositionalAll(self.io, buf[0..want], copied);
        copied += want;
    }
    try tmp.sync(self.io); // fsync temp contents before the rename

    try self.dir.rename("data.tmp", self.dir, data_name, self.io); // atomic swap

    // The old handle points at the now-unlinked inode; reopen the new file.
    self.data.close(self.io);
    self.data = try self.dir.createFile(self.io, data_name, .{ .read = true, .truncate = false });

    // Everything shifted down by `delta`.
    self.write_off -= delta;
    self.read_off = 0;
    self.acked_off = 0;
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

/// Read the record at the read cursor, allocate it, and advance the cursor in
/// memory (call `ack` to persist, `rewind` to roll back). Returns `null` when
/// caught up. Caller owns the returned slice and must free it.
pub fn next(self: *Self, allocator: std.mem.Allocator) !?[]u8 {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    if (self.read_off >= self.write_off) return null; // caught up

    var hdr: [8]u8 = undefined;
    if (try self.data.readPositionalAll(self.io, &hdr, self.read_off) != hdr.len)
        return error.ShortRead;

    const len = std.mem.readInt(u32, hdr[0..4], .little);
    const crc = std.mem.readInt(u32, hdr[4..8], .little);

    const payload = try allocator.alloc(u8, len);
    errdefer allocator.free(payload);
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
        // Fully drained: truncate to empty and reset — the cheap fast path.
        try self.data.setLength(self.io, 0);
        self.read_off = 0;
        self.write_off = 0;
        try state.writeAtomic(self.io, self.dir, cursor_name, "0");
        self.acked_off = 0;
    } else if (self.read_off >= self.reclaim_threshold) {
        // Enough dead prefix accumulated to be worth reclaiming.
        self.acked_off = self.read_off; // satisfy compact's precondition
        try self.compact();
    } else {
        var buf: [20]u8 = undefined;
        const text = try std.fmt.bufPrint(&buf, "{d}", .{self.read_off});
        try state.writeAtomic(self.io, self.dir, cursor_name, text);
        self.acked_off = self.read_off; // now durably committed
    }
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
