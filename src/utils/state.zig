//! Persistent on-disk state for zagent (e.g. the tailer read offset and, later,
//! the spool cursor), kept under `$HOME/.zagent`.

const std = @import("std");
const Map = std.process.Environ.Map;

/// State directory name, created under the user's home directory.
const state_dir_name = ".zagent";

/// Ensure the state directory exists and return it open for use. The caller owns
/// the returned `Dir` and must `close` it.
///
/// `environ` is the process environment, read for `$HOME` and *borrowed* — it is
/// not freed here. Falls back to the current directory if `$HOME` is unset.
pub fn openStateDir(io: std.Io, environ: *const Map) !std.Io.Dir {
    const home = environ.get("HOME") orelse ".";

    var home_dir = try std.Io.Dir.cwd().openDir(io, home, .{});
    defer home_dir.close(io);

    // createDirPathOpen == mkdir -p + openDir: no error if it already exists,
    // and it returns the open handle in one step.
    return home_dir.createDirPathOpen(io, state_dir_name, .{});
}

/// Read `name` from `dir` into `buf`, returning the bytes read — or `null` if
/// the file doesn't exist yet. The empty/first-run
/// case is `null`, not an error; any other I/O failure propagates.
pub fn readState(io: std.Io, dir: std.Io.Dir, name: []const u8, buf: []u8) !?[]u8 {
    var file = dir.openFile(io, name, .{ .mode = .read_only }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close(io);
    const n = try file.readPositionalAll(io, buf, 0);
    return buf[0..n];
}

/// Atomically and durably replace `name` in `dir` with `bytes`: the data is
/// written to a temp file, fsync'd, renamed over `name`, then the directory is
/// fsync'd. The rename is the only change to `name`, so a reader never sees a
/// half-written file, only the complete old or complete new contents.
///
/// Power-loss durable: fsyncing the directory persists the rename itself, so a
/// power cut after this returns leaves the new contents, not the old. Without
/// that final fsync the directory entry could be lost and `name` revert.
pub fn writeAtomic(io: std.Io, dir: std.Io.Dir, name: []const u8, bytes: []const u8) !void {
    var tmp_buf: [256]u8 = undefined;
    const tmp = try std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{name});

    {
        var file = try dir.createFile(io, tmp, .{ .truncate = true });
        defer file.close(io);
        try file.writePositionalAll(io, bytes, 0);
        try file.sync(io); // fsync bytes to disk BEFORE rename
    }

    try dir.rename(tmp, dir, name, io); // swap atomically into place

    // Persist the rename by fsyncing the directory. The borrowed `dir` handle is
    // opened O_PATH, which can't be fsync'd, so open a fresh iterable handle to
    // fsync and close it.
    var sync_dir = try dir.openDir(io, ".", .{ .iterate = true });
    defer sync_dir.close(io);
    const dir_file: std.Io.File = .{ .handle = sync_dir.handle, .flags = .{ .nonblocking = false } };
    try dir_file.sync(io);
}
