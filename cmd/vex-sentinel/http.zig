//! Tiny HTTP server for client discovery.
//!
//! Surface (v1):
//!   GET /leader      -> 200 {"node_id":N,"addr":"host:port","epoch":E}
//!                       503 if no leader is known yet
//!   GET /healthz     -> 200 "ok"
//!   anything else    -> 404
//!
//! No third-party HTTP library — the surface is two routes and one verb,
//! so a hand-rolled request line parser is the right call here.
//!
//! Scaffold: accept loop is wired but each request returns 503 until
//! `setLeader` has been called by the controller. Real leader-source
//! plumbing (Store + Poller pointers) lands when the controller is built.

const std = @import("std");
const vex_log = @import("vex_log");
const c = std.c;

pub const LeaderInfo = struct {
    node_id: u16,
    host: []const u8,
    port: u16,
    epoch: u64,
};

pub const Server = struct {
    allocator: std.mem.Allocator,
    listen_port: u16,
    listen_fd: c_int = -1,
    /// Latest known leader. Updated by the controller after a successful
    /// election. Read under `mu` because the accept thread reads it.
    leader: ?LeaderInfo = null,
    mu: c.pthread_mutex_t = c.PTHREAD_MUTEX_INITIALIZER,
    stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thread: ?std.Thread = null,

    pub fn init(allocator: std.mem.Allocator, port: u16) Server {
        return .{ .allocator = allocator, .listen_port = port };
    }

    pub fn deinit(self: *Server) void {
        self.stop.store(true, .release);
        if (self.listen_fd >= 0) {
            _ = c.close(self.listen_fd);
            self.listen_fd = -1;
        }
        if (self.thread) |t| t.join();
    }

    pub fn setLeader(self: *Server, info: ?LeaderInfo) void {
        _ = c.pthread_mutex_lock(&self.mu);
        defer _ = c.pthread_mutex_unlock(&self.mu);
        self.leader = info;
    }

    /// Bind, listen, spawn the accept thread.
    pub fn start(self: *Server) !void {
        const fd = c.socket(c.AF.INET, c.SOCK.STREAM, 0);
        if (fd < 0) return error.SocketFailed;

        var yes: c_int = 1;
        _ = c.setsockopt(fd, c.SOL.SOCKET, c.SO.REUSEADDR, &yes, @sizeOf(c_int));

        var addr: c.sockaddr.in = .{
            .family = c.AF.INET,
            .port = std.mem.nativeToBig(u16, self.listen_port),
            .addr = 0, // INADDR_ANY
        };
        if (c.bind(fd, @ptrCast(&addr), @sizeOf(c.sockaddr.in)) < 0) {
            _ = c.close(fd);
            return error.BindFailed;
        }
        if (c.listen(fd, 16) < 0) {
            _ = c.close(fd);
            return error.ListenFailed;
        }
        self.listen_fd = fd;
        self.thread = try std.Thread.spawn(.{}, acceptLoop, .{self});
        vex_log.info("sentinel http: listening on :{d}", .{self.listen_port});
    }

    fn acceptLoop(self: *Server) void {
        while (!self.stop.load(.acquire)) {
            var caddr: c.sockaddr.in = undefined;
            var clen: c.socklen_t = @sizeOf(c.sockaddr.in);
            const conn = c.accept(self.listen_fd, @ptrCast(&caddr), &clen);
            if (conn < 0) {
                // EINTR / EBADF on shutdown — exit cleanly.
                if (self.stop.load(.acquire)) return;
                continue;
            }
            self.handleOne(conn);
            _ = c.close(conn);
        }
    }

    fn handleOne(self: *Server, conn: c_int) void {
        var buf: [1024]u8 = undefined;
        const n = c.read(conn, &buf, buf.len);
        if (n <= 0) return;
        const req = buf[0..@intCast(n)];

        // Parse request line: "GET /path HTTP/1.x\r\n"
        const eol = std.mem.indexOf(u8, req, "\r\n") orelse return;
        const line = req[0..eol];
        var it = std.mem.splitScalar(u8, line, ' ');
        const method = it.next() orelse return;
        const path = it.next() orelse return;

        if (!std.mem.eql(u8, method, "GET")) {
            writeAll(conn, "HTTP/1.1 405 Method Not Allowed\r\nContent-Length: 0\r\n\r\n");
            return;
        }

        if (std.mem.eql(u8, path, "/healthz")) {
            writeAll(conn, "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 2\r\n\r\nok");
            return;
        }

        if (std.mem.eql(u8, path, "/leader")) {
            self.writeLeader(conn);
            return;
        }

        writeAll(conn, "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n");
    }

    fn writeLeader(self: *Server, conn: c_int) void {
        _ = c.pthread_mutex_lock(&self.mu);
        const snapshot_leader = self.leader;
        _ = c.pthread_mutex_unlock(&self.mu);

        const info = snapshot_leader orelse {
            writeAll(conn, "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\n\r\n");
            return;
        };

        var body_buf: [256]u8 = undefined;
        const body = std.fmt.bufPrint(
            &body_buf,
            "{{\"node_id\":{d},\"addr\":\"{s}:{d}\",\"epoch\":{d}}}",
            .{ info.node_id, info.host, info.port, info.epoch },
        ) catch return;

        var hdr_buf: [128]u8 = undefined;
        const hdr = std.fmt.bufPrint(
            &hdr_buf,
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n",
            .{body.len},
        ) catch return;
        writeAll(conn, hdr);
        writeAll(conn, body);
    }
};

fn writeAll(conn: c_int, data: []const u8) void {
    var written: usize = 0;
    while (written < data.len) {
        const n = c.write(conn, data.ptr + written, data.len - written);
        if (n <= 0) return;
        written += @intCast(n);
    }
}
