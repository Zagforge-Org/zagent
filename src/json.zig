const std = @import("std");

pub fn Serialize(allocator: std.mem.Allocator, any: anytype, options: std.json.Stringify.Options) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    var write_stream: std.json.Stringify = .{
        .writer = &out.writer,
        .options = options,
    };

    try write_stream.write(any);

    return out.toOwnedSlice();
}

pub fn Deserialize(allocator: std.mem.Allocator, comptime T: type, json_str: []const u8) !std.json.Parsed(T) {
    const parsed = try std.json.parseFromSlice(T, allocator, json_str, .{ .ignore_unknown_fields = true });
    return parsed;
}
