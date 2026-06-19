const std = @import("std");

path: []const u8,
file: std.Io.File,

skipping: bool,

inode: std.posix.ino_t,

offset: u64,
io: std.Io,

pending: std.ArrayList(u8),
allocator: std.mem.Allocator,

const Self = @This();

const MAX_LINE: u32 = 64 * 1024;

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
        .io = io,
        .pending = .empty,
    };
}

pub fn deinit(self: *Self) void {
    self.pending.deinit(self.allocator);
    self.file.close(self.io);
}

// Keep inclusive since we already have this pattern going on Reader.zig
// pending growth should be limited with 64kb limit.
pub fn readNew(self: *Self, writer: *std.Io.Writer) !void {
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
        try writer.writeAll(self.pending.items[start .. newline + 1]);
        start = newline + 1;
    }

    if (start > 0) {
        const rest = self.pending.items.len - start;
        @memmove(self.pending.items[0..rest], self.pending.items[start..]);
        self.pending.shrinkRetainingCapacity(rest);
    }
}

test "readNew emits whole lines and follows appends" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const filename = "tail.log";
    try tmp.dir.writeFile(io, .{ .sub_path = filename, .data = "alpha\nbeta\n" });

    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();

    var t = try Self.open(std.testing.allocator, io, tmp.dir, filename);
    defer t.deinit();

    // first poll: both complete lines come out
    try t.readNew(&aw.writer);
    try std.testing.expectEqualStrings("alpha\nbeta\n", aw.writer.buffered());

    // append a third line to the same file (same inode), at the current end
    var wf = try tmp.dir.openFile(io, filename, .{ .mode = .write_only });
    defer wf.close(io);
    try wf.writePositionalAll(io, "gamma\n", "alpha\nbeta\n".len);

    // second poll: only the newly appended line is emitted, numbering/offset continues
    try t.readNew(&aw.writer);
    try std.testing.expectEqualStrings("alpha\nbeta\ngamma\n", aw.writer.buffered());
}

pub fn hasRotated(self: *Self, emit: anytype) !void {
    _ = self;
    _ = emit;
}

pub fn wasTruncated(self: *Self) !bool {
    _ = self;
}

pub fn reopen(self: *Self) !void {
    _ = self;
}

pub fn rewind(self: *Self) !void {
    _ = self;
}
