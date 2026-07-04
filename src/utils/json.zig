//! json.zig is a small helper library abstracting the built-in JSON support
//! Zig provides out of the box.
//! It tries to abstract low-level handles with Serialization and Deserialization.

const std = @import("std");

/// Serialize serializes incoming object types
/// and returns a u8 slice representation of the data passed in.
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

/// Deserialize deserializes the passed in JSON u8 slice
/// and returns a compile-time known struct wrapped inside `std.json.Parsed`.
pub fn Deserialize(allocator: std.mem.Allocator, comptime T: type, json_str: []const u8) !std.json.Parsed(T) {
    // `.alloc_always` copies every parsed string into the returned arena, so the
    // result does not alias `json_str` and stays valid after the caller frees it.
    const parsed = try std.json.parseFromSlice(T, allocator, json_str, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    return parsed;
}
