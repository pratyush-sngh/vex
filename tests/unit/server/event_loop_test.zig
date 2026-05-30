// Migrated unit tests for src/server/event_loop.zig.

const std = @import("std");
const EventLoop = @import("../../../src/server/event_loop.zig").EventLoop;

test "pipe read triggers readable event" {
    var el = try EventLoop.init();
    defer el.deinit();

    var pipe_fds: [2]std.c.fd_t = undefined;
    const pipe_rc = std.c.pipe(&pipe_fds);
    if (pipe_rc != 0) return error.PipeFailed;
    defer {
        _ = std.c.close(pipe_fds[0]);
        _ = std.c.close(pipe_fds[1]);
    }

    const read_fd = pipe_fds[0];
    const write_fd = pipe_fds[1];

    try el.addFd(read_fd, @intCast(read_fd));

    const byte = [1]u8{'x'};
    const wrc = std.c.write(write_fd, &byte, 1);
    try std.testing.expect(wrc == 1);

    var events: [16]EventLoop.Event = undefined;
    const ready = try el.poll(&events, 100);

    try std.testing.expect(ready.len >= 1);

    var found = false;
    for (ready) |ev| {
        if (ev.fd == read_fd) {
            try std.testing.expect(ev.readable);
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "notify wakes poll" {
    var el = try EventLoop.init();
    defer el.deinit();

    el.notify();

    var events: [16]EventLoop.Event = undefined;
    const ready = try el.poll(&events, 100);

    try std.testing.expect(ready.len >= 1);

    var found = false;
    for (ready) |ev| {
        if (el.isNotifyFd(ev.fd)) {
            try std.testing.expect(ev.readable);
            found = true;
            break;
        }
    }
    try std.testing.expect(found);

    el.drainNotify();
}
