const std = @import("std");
const json = @import("utils/json.zig");
const Record = @import("core/Record.zig");

pub fn toJsonLine(rec: Record, allocator: std.mem.Allocator) ![]u8 {
    return json.Serialize(allocator, .{ .ts = rec.timestamp.nanoseconds, .kind = @tagName(rec.kind), .msg = rec.content }, .{ .whitespace = .minified });
}
