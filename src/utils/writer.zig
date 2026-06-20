const std = @import("std");

/// Writer is an abstraction over Zig's explicit writer interface.
pub fn Writer(io: std.Io, comptime buf_size: usize, content: []const u8) !void {
    var buf: [buf_size]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buf);
    try stdout.interface.writeAll(content);
    try stdout.interface.flush();
}
