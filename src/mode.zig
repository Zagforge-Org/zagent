const std = @import("std");

const Mode = enum { run, version, help, init, check };

pub fn setMode(mode: *Mode, set: *bool, new: Mode) !void {
    if (set.*) return error.MultipleNodes;
    mode.* = new;
    set.* = true;
}
