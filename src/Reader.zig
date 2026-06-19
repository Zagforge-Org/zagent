const std = @import("std");
const Self = @This();

path: []const u8,

pub fn init(path: []const u8) Self {
    return .{
        .path = path,
    };
}

pub fn read(self: *const Self, io: std.Io, dir: std.Io.Dir, w: *std.Io.Writer) !void {
    var read_buffer: [256]u8 = undefined;
    var file = dir.openFile(io, self.path, .{ .mode = .read_only }) catch |err| {
        switch (err) {
            error.FileNotFound => std.log.err("File not found: {s}", .{self.path}),
            error.AccessDenied => std.log.err("Access denied: {s}", .{self.path}),
            else => std.log.err("Failed to open {s}: {s}", .{ self.path, @errorName(err) }),
        }
        return err;
    };

    defer file.close(io);

    var file_reader = file.reader(io, &read_buffer);
    var reader = &file_reader.interface;

    var line_num: u32 = 0;

    while (true) {
        _ = reader.peekByte() catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };

        line_num += 1;

        try w.print("Current line: {d}: ", .{line_num});

        _ = reader.streamDelimiter(w, '\n') catch |err| {
            switch (err) {
                error.EndOfStream => {
                    try w.writeByte('\n');
                    break;
                },
                error.ReadFailed => {
                    std.log.err("Failed to read bytes stream: {s}", .{self.path});
                    return err;
                },
                else => {
                    std.log.err("Failed to stream bytes: {s} : {s}", .{ self.path, @errorName(err) });
                    return err;
                },
            }
        };

        try w.writeByte('\n');

        // discard '\n' advancing to the next line
        reader.toss(1);
    }

    try w.flush();
}

test "read a deliberately long line" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // 300 bytes exceeds 256-byte buffer
    const long_line = ("a" ** 300) ++ "\n";

    try tmp.dir.writeFile(io, .{ .sub_path = "long.log", .data = long_line });

    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();

    const r = Self.init("long.log");
    try r.read(io, tmp.dir, &aw.writer);

    try std.testing.expect(std.mem.indexOf(u8, aw.writer.buffered(), "a" ** 300) != null);
}
