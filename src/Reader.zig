//! Reads a file line by line and writes each line to a writer.
//! Lines may exceed internal read buffer since content is streamed
//! through to the writer rather than buffered.

const std = @import("std");
const Self = @This();

io: std.Io,

/// Destination for output. Points to a stdout, an
/// in-memory buffer, etc.
writer: *std.Io.Writer,

/// Creates a `Reader` bound to `io` and `writer`. Does not touch the
/// filesystem; files are opened lazily in `read`.
pub fn init(io: std.Io, writer: *std.Io.Writer) Self {
    return .{
        .io = io,
        .writer = writer,
    };
}

/// Opens `path` under `dir` and writes each line to `self.writer`, prefixed
/// with its 1-based line number.
///
/// Parameters:
/// - `dir`:  directory `path` is resolved against (e.g. `std.Io.Dir.cwd()`).
/// - `path`: file path relative to `dir`.
///
/// Returns an error if the file cannot be opened or a read fails. A final line
/// without a trailing newline is still emitted with one.
pub fn read(
    self: *const Self,
    dir: std.Io.Dir,
    path: []const u8,
) !void {
    var read_buffer: [256]u8 = undefined;
    var file = dir.openFile(self.io, path, .{ .mode = .read_only }) catch |err| {
        switch (err) {
            error.FileNotFound => std.log.err("File not found: {s}", .{path}),
            error.AccessDenied => std.log.err("Access denied: {s}", .{path}),
            else => std.log.err("Failed to open {s}: {s}", .{ path, @errorName(err) }),
        }
        return err;
    };

    defer file.close(self.io);

    var file_reader = file.reader(self.io, &read_buffer);
    var reader = &file_reader.interface;

    var line_num: u32 = 0;

    while (true) {
        _ = reader.peekByte() catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };

        line_num += 1;

        try self.writer.print("Current line: {d}: ", .{line_num});

        _ = reader.streamDelimiter(self.writer, '\n') catch |err| {
            switch (err) {
                error.EndOfStream => {
                    try self.writer.writeByte('\n');
                    break;
                },
                error.ReadFailed => {
                    std.log.err("Failed to read bytes stream: {s}", .{path});
                    return err;
                },
                else => {
                    std.log.err("Failed to stream bytes: {s} : {s}", .{ path, @errorName(err) });
                    return err;
                },
            }
        };

        try self.writer.writeByte('\n');

        // discard '\n' advancing to the next line
        reader.toss(1);
    }

    try self.writer.flush();
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
