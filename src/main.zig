const std = @import("std");
const Tailer = @import("Tailer.zig");

test {
    _ = @import("Tailer.zig");
    _ = @import("Reader.zig");
}

pub fn main(init: std.process.Init) !void {
    var write_buffer: [1024]u8 = undefined;
    var file_writer = std.Io.File.stdout().writer(init.io, &write_buffer);

    var t = try Tailer.open(init.gpa, init.io, std.Io.Dir.cwd(), "logs/sample.log");
    defer t.deinit();

    t.follow(&file_writer.interface) catch {
        std.process.exit(1);
    };
}
