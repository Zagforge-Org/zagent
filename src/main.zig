const std = @import("std");
const Tailer = @import("Tailer.zig");
const RingBuffer = @import("RingBuffer.zig");

test {
    _ = @import("Tailer.zig");
    _ = @import("Reader.zig");
    _ = @import("RingBuffer_test.zig");
}

pub fn main(init: std.process.Init) !void {
    var write_buffer: [1024]u8 = undefined;
    var file_writer = std.Io.File.stdout().writer(init.io, &write_buffer);

    var ring = try RingBuffer.init(init.gpa, 1024);
    defer ring.deinit();

    var t = try Tailer.open(init.gpa, init.io, std.Io.Dir.cwd(), "logs/app.log");
    defer t.deinit();

    t.follow(&file_writer.interface, &ring) catch {
        std.process.exit(1);
    };
}
