const std = @import("std");

/// Records the selected CLI mode into `mode`, rejecting a second selection.
/// Generic over the caller's mode enum so there is a single source of truth
/// (the `Command` tag) rather than a duplicate enum. The optional itself is the
/// "already chosen?" flag — no separate bool needed.
pub fn setMode(comptime Mode: type, mode: *?Mode, new: Mode) error{MultipleModes}!void {
    if (mode.* != null) return error.MultipleModes;
    mode.* = new;
}
