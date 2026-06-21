//! Follows a growing file (`tail -F`): emits newly appended lines, survives log
//! rotation by tracking the file's inode, and recovers from in-place truncation.
//! Partial lines are buffered until their terminating newline arrives, so a line
//! split across reads is never emitted half-written.

const std = @import("std");
const state = @import("../utils/state.zig");
const Spool = @import("../Spool.zig");
const wire = @import("../wire.zig");

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

/// Durable queue complete lines are appended to. Coupling the offset checkpoint
/// to a successful.
spool: *Spool,

/// Directory holding "tailer.offset" and is rewritten as lines are spooled.
/// Typically $HOME/.zagent.
state_dir: std.Io.Dir,

io: std.Io,

allocator: std.mem.Allocator,

/// Maximum length of a single line; longer lines are dropped. Defaults to
/// 64 KiB.
max_line: usize = 64 * 1024,

const Self = @This();

/// Opens `path` under `dir` and returns a `Tailer` positioned at the start of
/// the file. Records the file's inode for later rotation detection. The caller
/// owns the result and must call `deinit`.
pub fn open(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8, spool: *Spool, state_dir: std.Io.Dir) !Self {
    const file = try dir.openFile(io, path, .{ .mode = .read_only });
    const stat = try file.stat(io);

    var offset: u64 = 0;
    var buf: [48]u8 = undefined;

    if (try state.readState(io, state_dir, "tailer.offset", &buf)) |raw| {
        var it = std.mem.tokenizeScalar(u8, raw, ' ');
        const inode_str = it.next() orelse return error.BadCheckpoint;
        const offset_str = it.next() orelse return error.BadCheckpoint;

        const saved_inode = try std.fmt.parseInt(std.posix.ino_t, inode_str, 10);
        const saved_offset = try std.fmt.parseInt(u64, offset_str, 10);

        if (saved_inode == stat.inode) {
            offset = saved_offset;
        }
    }

    return .{
        .allocator = allocator,
        .path = path,
        .inode = stat.inode,
        .file = file,
        .skipping = false,
        .offset = offset,
        .dir = dir,
        .spool = spool,
        .state_dir = state_dir,
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
/// in `pending` for the next call. A line longer than `max_line` is dropped and
/// the reader enters `skipping` mode until the next newline.
fn readNew(self: *Self, writer: *std.Io.Writer) !void {
    if (self.pending.items.len > self.max_line) {
        std.log.warn("line exceeded {d} bytes; skipping.", .{self.max_line});
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

    var consumed: usize = 0; // bytes of pending durably in the spool

    while (std.mem.indexOfScalarPos(u8, self.pending.items, consumed, '\n')) |newline| {
        const line = self.pending.items[consumed .. newline + 1];
        if (line.len > self.max_line) {
            // over-cap line arrived as a whole in this read
            std.log.warn("line exceeded {d} bytes; skipping.", .{self.max_line});
        } else {
            try writer.writeAll(line); // fan-out
            const json_line = try wire.toJsonLine(.{
                .timestamp = std.Io.Timestamp.now(self.io, .real),
                .content = line,
                .kind = .log,
            }, self.allocator);

            defer self.allocator.free(json_line);
            if (!try self.spool.append(json_line)) {
                // spool full: this line is not durable
                break;
            }
        }
        consumed = newline + 1;
    }

    // Compact consumed prefix out of pending leaving partial tail.
    if (consumed > 0) {
        const rest = self.pending.items.len - consumed;
        @memmove(self.pending.items[0..rest], self.pending.items[consumed..]);
        self.pending.shrinkRetainingCapacity(rest);

        const checkpoint = self.offset - rest;
        var buf: [48]u8 = undefined;
        const text = try std.fmt.bufPrint(&buf, "{d} {d}", .{ self.inode, checkpoint });
        try state.writeAtomic(self.io, self.state_dir, "tailer.offset", text);
    }
}

/// Reads the next spooled record and asserts its JSON line contains `want`
/// (the record is the `{ts,kind,msg}` line, not the raw content). Frees it.
fn expectSpooled(spool: *Spool, want: []const u8) !void {
    const rec = (try spool.next(std.testing.allocator)) orelse return error.UnexpectedEmpty;
    defer std.testing.allocator.free(rec);
    try std.testing.expect(std.mem.indexOf(u8, rec, want) != null);
}

test "readNew spools whole lines and follows appends" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const filename = "tail.log";
    try tmp.dir.writeFile(io, .{ .sub_path = filename, .data = "alpha\nbeta\n" });

    var spool = try Spool.open(io, tmp.dir, 64 * 1024 * 1024);
    defer spool.deinit();

    var t = try Self.open(std.testing.allocator, io, tmp.dir, filename, &spool, tmp.dir);
    defer t.deinit();

    var discard_buf: [64]u8 = undefined;
    var discard: std.Io.Writer.Discarding = .init(&discard_buf);

    // first poll: both complete lines are spooled, in order
    try t.readNew(&discard.writer);
    try expectSpooled(&spool, "alpha");
    try expectSpooled(&spool, "beta");
    try std.testing.expectEqual(@as(?[]u8, null), try spool.next(std.testing.allocator));

    // append a third line to the same file (same inode), at the current end
    var wf = try tmp.dir.openFile(io, filename, .{ .mode = .write_only });
    defer wf.close(io);
    try wf.writePositionalAll(io, "gamma\n", "alpha\nbeta\n".len);

    // second poll: only the newly appended line is spooled, offset continues
    try t.readNew(&discard.writer);
    try expectSpooled(&spool, "gamma");
    try std.testing.expectEqual(@as(?[]u8, null), try spool.next(std.testing.allocator));
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
pub fn follow(self: *Self, writer: *std.Io.Writer, running: *const std.atomic.Value(bool)) !void {
    while (running.load(.monotonic)) {
        try self.readNew(writer);
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
