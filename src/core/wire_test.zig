const std = @import("std");
const testing = std.testing;

const wire = @import("wire.zig");
const Record = @import("Record.zig");

test "toJsonLine emits msg as a JSON string for valid content" {
    const line = try wire.toJsonLine(.{
        .kind = .log,
        .timestamp = .zero,
        .content = "hello",
    }, testing.allocator);
    defer testing.allocator.free(line);

    try testing.expect(std.mem.indexOf(u8, line, "\"msg\":\"hello\"") != null);
}

test "toJsonLine sanitizes invalid UTF-8 into a string, not an array" {
    // A lone 0xFF is not valid UTF-8. Without sanitizing, std.json serializes
    // the []const u8 as an array of byte integers, silently changing msg's type.
    const line = try wire.toJsonLine(.{
        .kind = .log,
        .timestamp = .zero,
        .content = "a\xffb",
    }, testing.allocator);
    defer testing.allocator.free(line);

    // msg must stay a string, with the bad byte replaced by U+FFFD.
    try testing.expect(std.mem.indexOf(u8, line, "\"msg\":\"a\u{FFFD}b\"") != null);
    // and must never degrade into the array form.
    try testing.expect(std.mem.indexOf(u8, line, "\"msg\":[") == null);
}
