const std = @import("std");
const Reader = @import("Reader.zig");

test {
    _ = @import("Reader.zig");
}

pub fn main(init: std.process.Init) !void {
    var write_buffer: [1024]u8 = undefined;
    var file_writer = std.Io.File.stdout().writer(init.io, &write_buffer);

    var read_buffer: [64 * 1024]u8 = undefined;
    const r = Reader.init(init.io, &file_writer.interface, .KEEP_OPEN);

    r.read(std.Io.Dir.cwd(), "logs/sample.log", &read_buffer) catch {
        std.process.exit(1);
    };
}
