const std = @import("std");

path: []const u8,
file: std.Io.File,

inode: std.posix.ino_t,
dev: std.posix.dev_t,

offset: u64,
io: std.Io,

pending: std.ArrayList(u8),
allocator: std.mem.Allocator,

const Self = @This();

pub fn open(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Self {
    const file = try std.Io.Dir.openFile(path, .{ .mode = .read_only });
    const stat = try file.stat(io);

    return .{
        .allocator = allocator,
        .path = path,
        .inode = stat.inode,
        .dev = stat.inode,
        .file = file,
        .offset = 0,
        .io = io,
        .pending = .empty,
    };
}

pub fn deinit(self: *Self) void {
    for (self.pending.items) |item| {
        self.allocator.destroy(item);
    }
    self.pending.deinit(self.allocator);

    self.file.close(self.io);
}

pub fn readNew(self: *Self, emit: anytype) !void {
    _ = self;
    _ = emit;
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
