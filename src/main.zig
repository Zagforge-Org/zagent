const std = @import("std");
const Io = std.Io;
const Reader = @import("Reader.zig");

test {
    _ = @import("Reader.zig");
}

pub fn main(init: std.process.Init) !void {
    var write_buffer: [256]u8 = undefined;
    var file_writer = std.Io.File.stdout().writer(init.io, &write_buffer);

    const r = Reader.init("logs/sample.log");

    r.read(init.io, std.Io.Dir.cwd(), &file_writer.interface) catch {
        std.process.exit(1);
    };
}
