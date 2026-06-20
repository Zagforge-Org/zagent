const std = @import("std");

/// Records selected CLI mode into `mode` rejecting a second selection.
pub fn setMode(comptime Mode: type, mode: *?Mode, new: Mode) error{MultipleModes}!void {
    if (mode.* != null) return error.MultipleModes;
    mode.* = new;
}
