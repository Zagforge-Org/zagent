//! Follows a growing file (`tail -F`): emits newly appended lines, survives log
//! rotation by tracking the file's inode, and recovers from in-place truncation.
//! Partial lines are buffered until their terminating newline arrives, so a line
//! split across reads is never emitted half-written.

const std = @import("std");
const RingBuffer = @import("RingBuffer.zig");

/// Path of the file being followed.
path: []const u8,

/// Open handle to the file currently being read. Survives renames, so it keeps
/// pointing at the original inode until `reopen` swaps it.
file: std.Io.File,

/// Directory `path` resolves against.
dir: std.Io.Dir,

/// Whether we are mid-discard of an over-long line, dropping bytes until the
/// next newline. Spans polls because the rest of the line may not have arrived.
skipping: bool,

/// Inode of the file we opened.
inode: std.posix.ino_t,

/// Byte position consumed so far.
offset: u64,

/// Buffer holding the trailing partial line carried between reads.
pending: std.ArrayList(u8),

io: std.Io,

allocator: std.mem.Allocator,

const Self = @This();

/// Maximum length of a single line.
const MAX_LINE: u32 = 64 * 1024;

/// Opens `path` under `dir` and returns a `Tailer` positioned at the start of
/// the file. Records the file's inode for later rotation detection. The caller
/// owns the result and must call `deinit`.
pub fn open(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8) !Self {
    const file = try dir.openFile(io, path, .{ .mode = .read_only });
    const stat = try file.stat(io);

    return .{
        .allocator = allocator,
        .path = path,
        .inode = stat.inode,
        .file = file,
        .skipping = false,
        .offset = 0,
        .dir = dir,
        .io = io,
        .pending = .empty,
    };
}

/// Frees the pending buffer and closes the open file handle.
pub fn deinit(self: *Self) void {
    self.pending.deinit(self.allocator);
    self.file.close(self.io);
}

/// Reads all bytes available since the last call and, for every now-complete
/// line, echoes it to `writer` (local stdout fan-out) and pushes it into `ring`
/// as a `log` record for the Exporter to ship. The trailing partial line is kept
/// in `pending` for the next call. A line longer than `MAX_LINE` is dropped and
/// the reader enters `skipping` mode until the next newline.
fn readNew(self: *Self, writer: *std.Io.Writer, ring: *RingBuffer) !void {
    if (self.pending.items.len > MAX_LINE) {
        std.log.warn("line exceeded {d} bytes; skipping.", .{MAX_LINE});
        self.pending.clearRetainingCapacity(); // clear out pending cache
        self.skipping = true;
    }

    while (self.skipping) {
        var buf: [4096]u8 = undefined;
        const n = try self.file.readPositionalAll(self.io, &buf, self.offset);
        if (n == 0) return;
        if (std.mem.indexOfScalar(u8, buf[0..n], '\n')) |i| {
            self.offset += i + 1;
            self.skipping = false; // stop skipping; found \n
        } else {
            self.offset += n; // go to the next chunk
        }
    }

    while (true) {
        var buf: [4096]u8 = undefined;
        const n = try self.file.readPositionalAll(self.io, &buf, self.offset);
        if (n == 0) break;
        self.offset += n;
        try self.pending.appendSlice(self.allocator, buf[0..n]);
    }

    var start: usize = 0;

    while (std.mem.indexOfScalarPos(u8, self.pending.items, start, '\n')) |newline| {
        const line = self.pending.items[start .. newline + 1];
        try writer.writeAll(line); // fan-out: local echo
        try ring.push(.{
            .timestamp = std.Io.Timestamp.now(self.io, .real),
            .content = line, // push dupes; the Exporter is the ring's sole consumer
            .kind = .log,
        });
        start = newline + 1;
    }

    if (start > 0) {
        const rest = self.pending.items.len - start;
        @memmove(self.pending.items[0..rest], self.pending.items[start..]);
        self.pending.shrinkRetainingCapacity(rest);
    }
}

/// Pops one record and asserts its content, then frees it (`pop` transfers
/// ownership of the bytes to us).
fn expectPop(ring: *RingBuffer, want: []const u8) !void {
    const rec = ring.pop() orelse return error.UnexpectedEmpty;
    defer std.testing.allocator.free(rec.content);
    try std.testing.expectEqualStrings(want, rec.content);
}

test "readNew buffers whole lines and follows appends" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const filename = "tail.log";
    try tmp.dir.writeFile(io, .{ .sub_path = filename, .data = "alpha\nbeta\n" });

    var ring = try RingBuffer.init(std.testing.allocator, io, 8);
    defer ring.deinit();

    var t = try Self.open(std.testing.allocator, io, tmp.dir, filename);
    defer t.deinit();

    var discard_buf: [64]u8 = undefined;
    var discard: std.Io.Writer.Discarding = .init(&discard_buf);

    // first poll: both complete lines are buffered as records
    try t.readNew(&discard.writer, &ring);
    try expectPop(&ring, "alpha\n");
    try expectPop(&ring, "beta\n");
    try std.testing.expectEqual(@as(?RingBuffer.Record, null), ring.pop());

    // append a third line to the same file (same inode), at the current end
    var wf = try tmp.dir.openFile(io, filename, .{ .mode = .write_only });
    defer wf.close(io);
    try wf.writePositionalAll(io, "gamma\n", "alpha\nbeta\n".len);

    // second poll: only the newly appended line is buffered, offset continues
    try t.readNew(&discard.writer, &ring);
    try expectPop(&ring, "gamma\n");
    try std.testing.expectEqual(@as(?RingBuffer.Record, null), ring.pop());
}

/// Returns whether `path` now resolves to a different file than the one we hold
/// (i.e. it was rotated). Stats the path, not the handle, since our handle
/// follows renames. May return `error.FileNotFound` during the brief window
/// between a rename and the new file being created.
fn hasRotated(self: *Self) !bool {
    const stat = try self.dir.statFile(self.io, self.path, .{});
    return stat.inode != self.inode;
}

/// Returns whether the file shrank below our read position, i.e. it was
/// truncated in place. Stats the handle, since truncation keeps the same inode.
fn wasTruncated(self: *Self) !bool {
    const stat = try self.file.stat(self.io);
    return stat.size < self.offset;
}

/// Switches to the new file at `path` after a rotation: closes the stale handle,
/// reopens the path, records the new inode, and resets position and buffer.
fn reopen(self: *Self) !void {
    self.file.close(self.io);
    self.file = try self.dir.openFile(self.io, self.path, .{ .mode = .read_only });
    const stat = try self.file.stat(self.io);
    self.inode = stat.inode;
    self.offset = 0;
    self.pending.clearRetainingCapacity();
}

/// Resets to the start of the same file after truncation: position to 0 and the
/// stale partial line dropped. Unlike `reopen`, the file handle is unchanged.
fn rewind(self: *Self) !void {
    self.offset = 0;
    self.pending.clearRetainingCapacity();
}

/// Follows the file indefinitely: reads new lines (echoing each to `writer` and
/// enqueuing it on `ring` for the Exporter), flushes the echo, rewinds on
/// truncation, reopens on rotation (treating a missing path as a transient
/// mid-rotation gap), and polls every 500 ms when caught up. Does not return
/// under normal operation; only propagates fatal I/O errors.
pub fn follow(self: *Self, writer: *std.Io.Writer, ring: *RingBuffer, running: *const bool) !void {
    while (running.*) {
        try self.readNew(writer, ring);
        try writer.flush();

        if (try self.wasTruncated()) {
            try self.rewind();
            continue;
        }

        const rotated = self.hasRotated() catch |err| switch (err) {
            error.FileNotFound => false,
            else => return err,
        };
        if (rotated) {
            try self.reopen();
            continue;
        }

        try self.io.sleep(.fromMilliseconds(500), .awake);
    }
}
