//! Crash-safe filesystem primitives.
//!
//! Every durable write in vex goes through this module so the pattern is
//! consistent: write to a tmp file, fsync the data, rename atomically,
//! then fsync the parent directory so the rename itself is durable.
//!
//! On macOS, plain fsync() only flushes to the drive's internal cache —
//! F_FULLFSYNC is the only call that pushes through to the platter.
//! Linux fsync() is sufficient.

const std = @import("std");
const c = std.c;
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const is_darwin = builtin.os.tag == .macos or builtin.os.tag == .ios or
    builtin.os.tag == .tvos or builtin.os.tag == .watchos or builtin.os.tag == .visionos;

pub const Error = error{
    OpenFailed,
    WriteFailed,
    ShortWrite,
    FsyncFailed,
    CloseFailed,
    RenameFailed,
    AllocFailed,
};

/// fsync a file descriptor for true durability. On macOS uses F_FULLFSYNC,
/// which is the only call that pushes through the drive's write cache. On
/// Linux uses fsync(2).
pub fn fsyncFile(fd: c_int) Error!void {
    if (is_darwin) {
        const rc = c.fcntl(fd, c.F.FULLFSYNC, @as(c_int, 0));
        if (rc < 0) {
            // F_FULLFSYNC unsupported (rare — older filesystems). Fall back to
            // plain fsync; data still hits the drive cache, just not the platter.
            if (c.fsync(fd) < 0) return Error.FsyncFailed;
        }
    } else {
        if (c.fsync(fd) < 0) return Error.FsyncFailed;
    }
}

/// fsync the parent directory of `path`. Required after rename for the
/// rename to be durable across power loss — without this, the file may
/// exist at the new name in memory but the directory entry hasn't hit
/// disk, and a crash can leave the rename lost.
pub fn fsyncDir(allocator: Allocator, path: []const u8) Error!void {
    const dir_path = std.fs.path.dirname(path) orelse ".";
    const dir_z = allocator.dupeSentinel(u8, dir_path, 0) catch return Error.AllocFailed;
    defer allocator.free(dir_z);

    const dir_fd = c.open(dir_z.ptr, .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, @as(c.mode_t, 0));
    if (dir_fd < 0) return Error.OpenFailed;
    defer _ = c.close(dir_fd);

    try fsyncFile(dir_fd);
}

/// Atomically write `data` to `path`:
///   1. Write to `<path>.tmp.<pid>`.
///   2. fsync the tmp file.
///   3. Rename tmp → path (atomic on POSIX).
///   4. fsync the parent directory.
///
/// After a crash at any point: `path` contains either the previous version
/// or the new one, never partial. The tmp file may be left behind on crash
/// — startup-time cleanup is the operator's responsibility (typically
/// nothing else opens these paths so it's harmless).
pub fn atomicWrite(allocator: Allocator, path: []const u8, data: []const u8) Error!void {
    const pid = c.getpid();
    const tmp_path = std.fmt.allocPrint(allocator, "{s}.tmp.{d}", .{ path, pid }) catch return Error.AllocFailed;
    defer allocator.free(tmp_path);
    const tmp_z = allocator.dupeSentinel(u8, tmp_path, 0) catch return Error.AllocFailed;
    defer allocator.free(tmp_z);
    const path_z = allocator.dupeSentinel(u8, path, 0) catch return Error.AllocFailed;
    defer allocator.free(path_z);

    const fd = c.open(
        tmp_z.ptr,
        .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true },
        @as(c.mode_t, 0o644),
    );
    if (fd < 0) return Error.OpenFailed;

    // From here, errors must unlink the tmp file before returning so we don't
    // leave junk behind. Wrap the body so we can clean up uniformly.
    writeFsyncRename(fd, tmp_z, path_z, data) catch |err| {
        _ = c.close(fd);
        _ = c.unlink(tmp_z.ptr);
        return err;
    };

    try fsyncDir(allocator, path);
}

fn writeFsyncRename(fd: c_int, tmp_z: [:0]const u8, path_z: [:0]const u8, data: []const u8) Error!void {
    // Write the full payload.
    var written: usize = 0;
    while (written < data.len) {
        const n = c.write(fd, data.ptr + written, data.len - written);
        if (n <= 0) return Error.WriteFailed;
        written += @intCast(n);
    }
    if (written != data.len) return Error.ShortWrite;

    // fsync before rename — otherwise the new name may resolve to an empty file
    // if the directory entry hits disk before the data does.
    try fsyncFile(fd);
    if (c.close(fd) < 0) return Error.CloseFailed;

    if (c.rename(tmp_z.ptr, path_z.ptr) < 0) return Error.RenameFailed;
}

// ── Tests ───────────────────────────────────────────────────────────

