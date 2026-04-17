const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;

const is_linux = builtin.os.tag == .linux;
const is_darwin = builtin.os.tag == .macos or builtin.os.tag == .ios or
    builtin.os.tag == .tvos or builtin.os.tag == .watchos or
    builtin.os.tag == .visionos;

const MAX_EVENTS = 256;
const FD_TABLE_SIZE = 4096;

pub const EventLoop = struct {
    pub const Event = struct {
        fd: i32,
        data: usize,
        readable: bool,
        writable: bool,
        err: bool,
        hup: bool,
    };

    // --- Backend handle ---
    // macOS: kqueue fd
    // Linux: io_uring instance (stored separately) or epoll fd
    kq_or_epfd: i32,

    // --- io_uring (Linux only) ---
    ring: if (is_linux) linux.IoUring else void,

    // --- Notify mechanism ---
    notify_read_fd: i32,
    notify_write_fd: i32,

    // --- macOS event buffer ---
    events_buf: if (is_darwin) [MAX_EVENTS]std.c.Kevent else void,

    // --- Linux: fd -> user data + tracking which fds have active polls ---
    fd_data: if (is_linux) [FD_TABLE_SIZE]usize else void,
    fd_active: if (is_linux) [FD_TABLE_SIZE]bool else void,
    fd_want_write: if (is_linux) [FD_TABLE_SIZE]bool else void,

    /// use_uring is set at init time; if io_uring fails we fall back to epoll.
    use_uring: if (is_linux) bool else void,
    epoll_events_buf: if (is_linux) [MAX_EVENTS]linux.epoll_event else void,

    pub fn init() !EventLoop {
        if (is_linux) {
            return initLinux();
        } else if (is_darwin) {
            return initDarwin();
        } else {
            @compileError("Unsupported OS");
        }
    }

    fn initLinux() !EventLoop {
        // Try io_uring first; fall back to epoll if unavailable (Docker, old kernels).
        if (linux.IoUring.init(512, 0)) |ring_val| {
            var ring = ring_val;
            const efd_raw = linux.eventfd(0, linux.EFD.NONBLOCK);
            if (efd_raw > std.math.maxInt(usize) / 2) {
                ring.deinit();
                return initLinuxEpoll();
            }
            const efd: i32 = @intCast(efd_raw);

            var self = EventLoop{
                .kq_or_epfd = 0,
                .ring = ring,
                .use_uring = true,
                .epoll_events_buf = undefined,
                .notify_read_fd = efd,
                .notify_write_fd = efd,
                .events_buf = {},
                .fd_data = [_]usize{0} ** FD_TABLE_SIZE,
                .fd_active = [_]bool{false} ** FD_TABLE_SIZE,
                .fd_want_write = [_]bool{false} ** FD_TABLE_SIZE,
            };

            self.submitPollAdd(efd, @as(u32, linux.POLL.IN)) catch {
                ring.deinit();
                _ = std.c.close(efd);
                return initLinuxEpoll();
            };

            return self;
        } else |_| {
            return initLinuxEpoll();
        }
    }

    fn initLinuxEpoll() !EventLoop {
        const epfd_raw = linux.epoll_create1(0);
        if (epfd_raw > std.math.maxInt(usize) / 2) return error.EpollCreateFailed;
        const epfd: i32 = @intCast(epfd_raw);

        const efd_raw = linux.eventfd(0, linux.EFD.NONBLOCK);
        if (efd_raw > std.math.maxInt(usize) / 2) {
            _ = std.c.close(epfd);
            return error.EventFdFailed;
        }
        const efd: i32 = @intCast(efd_raw);

        var ev = linux.epoll_event{ .events = linux.EPOLL.IN | linux.EPOLL.ET, .data = .{ .fd = efd } };
        const ctl_rc = linux.epoll_ctl(epfd, linux.EPOLL.CTL_ADD, efd, &ev);
        if (ctl_rc > std.math.maxInt(usize) / 2) {
            _ = std.c.close(efd);
            _ = std.c.close(epfd);
            return error.EpollCtlFailed;
        }

        return .{
            .kq_or_epfd = epfd,
            .ring = undefined,
            .use_uring = false,
            .epoll_events_buf = undefined,
            .notify_read_fd = efd,
            .notify_write_fd = efd,
            .events_buf = {},
            .fd_data = [_]usize{0} ** FD_TABLE_SIZE,
            .fd_active = [_]bool{false} ** FD_TABLE_SIZE,
            .fd_want_write = [_]bool{false} ** FD_TABLE_SIZE,
        };
    }

    fn initDarwin() !EventLoop {
        const kq = std.c.kqueue();
        if (kq < 0) return error.KqueueFailed;

        var pipe_fds: [2]std.c.fd_t = undefined;
        if (std.c.pipe(&pipe_fds) != 0) {
            _ = std.c.close(kq);
            return error.PipeFailed;
        }

        setNonBlocking(pipe_fds[0]);
        setNonBlocking(pipe_fds[1]);

        var changelist = [1]std.c.Kevent{.{
            .ident = @intCast(pipe_fds[0]),
            .filter = std.c.EVFILT.READ,
            .flags = std.c.EV.ADD | std.c.EV.CLEAR,
            .fflags = 0,
            .data = 0,
            .udata = 0,
        }};
        const rc = std.c.kevent(kq, &changelist, 1, @ptrCast(&changelist), 0, null);
        if (rc < 0) {
            _ = std.c.close(pipe_fds[0]);
            _ = std.c.close(pipe_fds[1]);
            _ = std.c.close(kq);
            return error.KeventFailed;
        }

        return .{
            .kq_or_epfd = kq,
            .ring = {},
            .notify_read_fd = pipe_fds[0],
            .notify_write_fd = pipe_fds[1],
            .events_buf = undefined,
            .fd_data = {},
            .fd_active = {},
            .fd_want_write = {},
            .use_uring = {},
            .epoll_events_buf = {},
        };
    }

    pub fn deinit(self: *EventLoop) void {
        if (is_linux) {
            if (self.use_uring) {
                self.ring.deinit();
            } else {
                _ = std.c.close(self.kq_or_epfd);
            }
            _ = std.c.close(self.notify_read_fd);
        } else {
            _ = std.c.close(self.notify_read_fd);
            _ = std.c.close(self.notify_write_fd);
            _ = std.c.close(self.kq_or_epfd);
        }
    }

    pub fn addFd(self: *EventLoop, fd: i32, data: usize) !void {
        setNonBlocking(fd);

        if (is_linux) {
            const idx = fdIdx(fd) orelse return error.FdOutOfRange;
            self.fd_data[idx] = data;
            self.fd_active[idx] = true;
            self.fd_want_write[idx] = false;
            if (self.use_uring) {
                try self.submitPollAdd(fd, @as(u32, linux.POLL.IN));
            } else {
                var ev = linux.epoll_event{ .events = linux.EPOLL.IN | linux.EPOLL.ET, .data = .{ .fd = fd } };
                const rc = linux.epoll_ctl(self.kq_or_epfd, linux.EPOLL.CTL_ADD, fd, &ev);
                if (rc > std.math.maxInt(usize) / 2) return error.EpollCtlFailed;
            }
        } else {
            var changelist = [1]std.c.Kevent{.{
                .ident = @intCast(fd),
                .filter = std.c.EVFILT.READ,
                .flags = std.c.EV.ADD | std.c.EV.CLEAR,
                .fflags = 0,
                .data = 0,
                .udata = data,
            }};
            const rc = std.c.kevent(self.kq_or_epfd, &changelist, 1, @ptrCast(&changelist), 0, null);
            if (rc < 0) return error.KeventFailed;
        }
    }

    pub fn removeFd(self: *EventLoop, fd: i32) void {
        if (is_linux) {
            if (fdIdx(fd)) |idx| {
                self.fd_active[idx] = false;
                self.fd_data[idx] = 0;
                self.fd_want_write[idx] = false;
            }
            if (!self.use_uring) {
                _ = linux.epoll_ctl(self.kq_or_epfd, linux.EPOLL.CTL_DEL, fd, null);
            }
        } else {
            var changelist = [2]std.c.Kevent{
                .{ .ident = @intCast(fd), .filter = std.c.EVFILT.READ, .flags = std.c.EV.DELETE, .fflags = 0, .data = 0, .udata = 0 },
                .{ .ident = @intCast(fd), .filter = std.c.EVFILT.WRITE, .flags = std.c.EV.DELETE, .fflags = 0, .data = 0, .udata = 0 },
            };
            _ = std.c.kevent(self.kq_or_epfd, &changelist, 2, @ptrCast(&changelist), 0, null);
        }
    }

    pub fn enableWrite(self: *EventLoop, fd: i32, data: usize) !void {
        if (is_linux) {
            if (fdIdx(fd)) |idx| {
                self.fd_data[idx] = data;
                self.fd_want_write[idx] = true;
            }
            if (!self.use_uring) {
                var ev = linux.epoll_event{ .events = linux.EPOLL.IN | linux.EPOLL.OUT | linux.EPOLL.ET, .data = .{ .fd = fd } };
                _ = linux.epoll_ctl(self.kq_or_epfd, linux.EPOLL.CTL_MOD, fd, &ev);
            }
        } else {
            var changelist = [1]std.c.Kevent{.{
                .ident = @intCast(fd),
                .filter = std.c.EVFILT.WRITE,
                .flags = std.c.EV.ADD | std.c.EV.CLEAR,
                .fflags = 0,
                .data = 0,
                .udata = data,
            }};
            const rc = std.c.kevent(self.kq_or_epfd, &changelist, 1, @ptrCast(&changelist), 0, null);
            if (rc < 0) return error.KeventFailed;
        }
    }

    pub fn disableWrite(self: *EventLoop, fd: i32, data: usize) !void {
        if (is_linux) {
            if (fdIdx(fd)) |idx| {
                self.fd_data[idx] = data;
                self.fd_want_write[idx] = false;
            }
            if (!self.use_uring) {
                var ev = linux.epoll_event{ .events = linux.EPOLL.IN | linux.EPOLL.ET, .data = .{ .fd = fd } };
                _ = linux.epoll_ctl(self.kq_or_epfd, linux.EPOLL.CTL_MOD, fd, &ev);
            }
        } else {
            var changelist = [1]std.c.Kevent{.{
                .ident = @intCast(fd),
                .filter = std.c.EVFILT.WRITE,
                .flags = std.c.EV.DELETE,
                .fflags = 0,
                .data = 0,
                .udata = data,
            }};
            const rc = std.c.kevent(self.kq_or_epfd, &changelist, 1, @ptrCast(&changelist), 0, null);
            if (rc < 0) return error.KeventFailed;
        }
    }

    pub fn poll(self: *EventLoop, out: []Event, timeout_ms: i32) ![]Event {
        if (is_linux) {
            if (self.use_uring) {
                return self.pollIoUring(out, timeout_ms);
            } else {
                return self.pollEpoll(out, timeout_ms);
            }
        } else {
            return self.pollKqueue(out, timeout_ms);
        }
    }

    fn pollIoUring(self: *EventLoop, out: []Event, timeout_ms: i32) ![]Event {
        _ = timeout_ms; // io_uring submit_and_wait with wait_nr=1 blocks until at least 1 completion

        // Submit any pending SQEs and wait for at least 1 completion
        _ = self.ring.submit_and_wait(1) catch return error.IoUringSubmitFailed;

        // Harvest completions
        var cqes: [MAX_EVENTS]linux.io_uring_cqe = undefined;
        const max_cqes: u32 = @intCast(@min(out.len, MAX_EVENTS));
        const n = self.ring.copy_cqes(&cqes, 0) catch return error.IoUringCqeFailed;

        var out_idx: usize = 0;
        for (cqes[0..n]) |cqe| {
            const fd: i32 = @intCast(cqe.user_data & 0xFFFFFFFF);
            const res = cqe.res;

            if (out_idx >= max_cqes) break;

            if (fd == self.notify_read_fd) {
                // Notify event — report as readable, re-arm
                out[out_idx] = .{ .fd = fd, .data = 0, .readable = true, .writable = false, .err = false, .hup = false };
                out_idx += 1;
                self.submitPollAdd(fd, linux.POLL.IN) catch {};
                continue;
            }

            const idx = fdIdx(fd) orelse continue;
            if (!self.fd_active[idx]) continue;

            if (res < 0) {
                // Error on the poll
                out[out_idx] = .{ .fd = fd, .data = self.fd_data[idx], .readable = false, .writable = false, .err = true, .hup = false };
                out_idx += 1;
                continue;
            }

            const revents: u32 = @intCast(res);
            out[out_idx] = .{
                .fd = fd,
                .data = self.fd_data[idx],
                .readable = (revents & linux.POLL.IN) != 0,
                .writable = (revents & linux.POLL.OUT) != 0,
                .err = (revents & linux.POLL.ERR) != 0,
                .hup = (revents & linux.POLL.HUP) != 0,
            };
            out_idx += 1;

            // Re-arm the poll for this fd (io_uring poll_add is one-shot)
            if (self.fd_active[idx]) {
                const poll_in: u32 = linux.POLL.IN;
                const poll_out: u32 = linux.POLL.OUT;
                const poll_mask: u32 = if (self.fd_want_write[idx]) poll_in | poll_out else poll_in;
                self.submitPollAdd(fd, poll_mask) catch {};
            }
        }

        // Flush any re-arm SQEs we just queued (non-blocking submit)
        _ = self.ring.submit() catch {};

        return out[0..out_idx];
    }

    fn pollEpoll(self: *EventLoop, out: []Event, timeout_ms: i32) ![]Event {
        const max: u32 = @intCast(@min(out.len, MAX_EVENTS));
        const rc = linux.epoll_wait(self.kq_or_epfd, &self.epoll_events_buf, max, timeout_ms);
        if (rc > std.math.maxInt(usize) / 2) return error.EpollWaitFailed;
        const n: usize = rc;
        for (0..n) |i| {
            const ev = self.epoll_events_buf[i];
            const fd = ev.data.fd;
            const idx = fdIdx(fd);
            const udata: usize = if (idx) |j| self.fd_data[j] else 0;
            out[i] = .{
                .fd = fd,
                .data = udata,
                .readable = (ev.events & linux.EPOLL.IN) != 0,
                .writable = (ev.events & linux.EPOLL.OUT) != 0,
                .err = (ev.events & linux.EPOLL.ERR) != 0,
                .hup = (ev.events & linux.EPOLL.HUP) != 0,
            };
        }
        return out[0..n];
    }

    fn pollKqueue(self: *EventLoop, out: []Event, timeout_ms: i32) ![]Event {
        const max: u32 = @intCast(@min(out.len, MAX_EVENTS));
        var ts: std.c.timespec = undefined;
        var ts_ptr: ?*const std.c.timespec = null;
        if (timeout_ms >= 0) {
            ts = .{
                .sec = @intCast(@divTrunc(timeout_ms, 1000)),
                .nsec = @intCast(@rem(timeout_ms, 1000) * 1_000_000),
            };
            ts_ptr = &ts;
        }
        const changelist_ptr: [*]const std.c.Kevent = @ptrCast(&self.events_buf);
        const eventlist_ptr: [*]std.c.Kevent = @ptrCast(&self.events_buf);
        const rc = std.c.kevent(self.kq_or_epfd, changelist_ptr, 0, eventlist_ptr, @intCast(max), ts_ptr);
        if (rc < 0) return error.KeventFailed;
        const n: usize = @intCast(rc);
        for (0..n) |i| {
            const ev = self.events_buf[i];
            out[i] = .{
                .fd = @intCast(ev.ident),
                .data = ev.udata,
                .readable = ev.filter == std.c.EVFILT.READ,
                .writable = ev.filter == std.c.EVFILT.WRITE,
                .err = (ev.flags & std.c.EV.ERROR) != 0,
                .hup = (ev.flags & std.c.EV.EOF) != 0,
            };
        }
        return out[0..n];
    }

    pub fn notify(self: *EventLoop) void {
        if (is_linux) {
            const val: u64 = 1;
            const buf: *const [8]u8 = @ptrCast(&val);
            _ = linux.write(@intCast(self.notify_write_fd), buf, 8);
        } else {
            const byte = [1]u8{1};
            _ = std.c.write(self.notify_write_fd, &byte, 1);
        }
    }

    pub fn isNotifyFd(self: *EventLoop, fd: i32) bool {
        return fd == self.notify_read_fd;
    }

    pub fn drainNotify(self: *EventLoop) void {
        if (is_linux) {
            var buf: [8]u8 = undefined;
            _ = linux.read(@intCast(self.notify_read_fd), &buf, 8);
        } else {
            var buf: [64]u8 = undefined;
            while (true) {
                const rc = std.c.read(self.notify_read_fd, &buf, buf.len);
                if (rc <= 0) break;
            }
        }
    }

    // --- io_uring helpers ---

    fn submitPollAdd(self: *EventLoop, fd: i32, poll_mask: u32) !void {
        if (!is_linux) unreachable;
        _ = try self.ring.poll_add(@intCast(fd), fd, poll_mask);
    }

    fn fdIdx(fd: i32) ?usize {
        if (fd >= 0 and @as(usize, @intCast(fd)) < FD_TABLE_SIZE) {
            return @intCast(fd);
        }
        return null;
    }
};

fn setNonBlocking(fd: i32) void {
    const flags = std.c.fcntl(fd, std.c.F.GETFL);
    if (flags < 0) return;
    const o_nonblock: c_int = if (is_linux) 0o4000 else 0x0004;
    _ = std.c.fcntl(fd, std.c.F.SETFL, @as(c_int, flags) | o_nonblock);
}

// c_int is a builtin type, no need to redefine

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

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
