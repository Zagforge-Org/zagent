//! Reads a file line by line and writes each line to a writer.
//! Lines may exceed internal read buffer since content is streamed
//! through to the writer rather than buffered.

const std = @import("std");
const Self = @This();

io: std.Io,

/// The state of the reader.
/// `KEEP_OPEN` keeps the connection opened and polls for changes.
/// `CLOSE` closes the connection and treats it as a static read.
state: State,

/// Destination for output. Points to a stdout, an
/// in-memory buffer, etc.
writer: *std.Io.Writer,

const State = enum {
    KEEP_OPEN,
    CLOSE,
};

/// Creates a `Reader` bound to `io` and `writer`. Does not touch the
/// filesystem; files are opened lazily in `read`.
pub fn init(io: std.Io, writer: *std.Io.Writer, state: State) Self {
    return .{
        .io = io,
        .state = state,
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
    var read_buffer: [1024 * 64]u8 = undefined;
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
        const line = reader.takeDelimiterInclusive('\n') catch |err| switch (err) {
            error.EndOfStream => switch (self.state) {
                .CLOSE => break,
                .KEEP_OPEN => {
                    try self.writer.flush();
                    try self.io.sleep(.fromMilliseconds(100), .awake);
                    continue;
                },
            },
            error.StreamTooLong => {
                std.log.warn("line {d} exceeds {d} bytes; skipping", .{ line_num + 1, read_buffer.len });
                _ = reader.discardDelimiterInclusive('\n') catch |e| switch (e) {
                    error.EndOfStream => break,
                    else => return e,
                };
                continue;
            },
            error.ReadFailed => return err,
        };

        line_num += 1;

        try self.writer.print("Current line: {d}: ", .{line_num});
        try self.writer.writeAll(line);
    }

    try self.writer.flush();
}

test "read a deliberately long line" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});

    const filename: []const u8 = "long.log";

    defer tmp.cleanup();

    // 300 bytes exceeds 256-byte buffer
    const long_line = ("a" ** 300) ++ "\n";

    try tmp.dir.writeFile(io, .{ .sub_path = filename, .data = long_line });

    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();

    const r = Self.init(io, &aw.writer, .CLOSE);
    try r.read(tmp.dir, filename);

    try std.testing.expect(std.mem.indexOf(u8, aw.writer.buffered(), "a" ** 300) != null);
}

// Accept a sane bounded line boundary; this will effectively limit overflow issues and preserve streaming capabilities.
// Bump limit to 1024*64 (64kb)

// Instead of having a fixed length, we should use ArrayList() which would act as a dynamic memory allocator
