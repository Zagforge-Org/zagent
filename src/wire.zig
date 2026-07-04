const std = @import("std");
const json = @import("utils/json.zig");
const Record = @import("core/Record.zig");

/// U+FFFD REPLACEMENT CHARACTER, substituted for invalid UTF-8 bytes.
const replacement = "\u{FFFD}";

pub fn toJsonLine(rec: Record, allocator: std.mem.Allocator) ![]u8 {
    // std.json serializes a []const u8 as a JSON string only when it is valid
    // UTF-8; otherwise it degrades to an array of byte integers, silently
    // changing msg's type.
    if (std.unicode.utf8ValidateSlice(rec.content))
        return serialize(rec, rec.content, allocator);

    const safe = try sanitizeUtf8(allocator, rec.content);
    defer allocator.free(safe);
    return serialize(rec, safe, allocator);
}

fn serialize(rec: Record, msg: []const u8, allocator: std.mem.Allocator) ![]u8 {
    return json.Serialize(allocator, .{ .ts = rec.timestamp.nanoseconds, .kind = @tagName(rec.kind), .msg = msg }, .{ .whitespace = .minified });
}

/// Copy `input`, replacing every invalid UTF-8 byte with U+FFFD so the result
/// is always valid UTF-8. Caller owns the returned slice.
fn sanitizeUtf8(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < input.len) {
        const len = std.unicode.utf8ByteSequenceLength(input[i]) catch {
            try out.appendSlice(allocator, replacement); // invalid leading byte
            i += 1;
            continue;
        };
        if (i + len <= input.len and std.unicode.utf8ValidateSlice(input[i .. i + len])) {
            try out.appendSlice(allocator, input[i .. i + len]); // valid sequence
            i += len;
        } else {
            try out.appendSlice(allocator, replacement); // truncated or bad continuation
            i += 1;
        }
    }

    return out.toOwnedSlice(allocator);
}
