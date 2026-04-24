const std = @import("std");
const Allocator = std.mem.Allocator;
const protocol = @import("protocol.zig");
const config_mod = @import("config.zig");
const ClusterConfig = config_mod.ClusterConfig;
const ClusterNode = config_mod.ClusterNode;

/// Leader-side replication: accepts follower connections and streams mutations.
/// Callback type for executing a forwarded write command on the leader.
/// Returns the RESP response bytes (caller must free).
pub const ExecuteWriteFn = *const fn (allocator: Allocator, args: []const []const u8) ?[]u8;

pub const HEARTBEAT_INTERVAL_MS: i64 = 5000; // 5 seconds

pub const ReplicationLeader = struct {
    allocator: Allocator,
    config: *const ClusterConfig,
    listen_port: u16,
    follower_fds: std.array_list.Managed(i32),
    mutex: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER,
    running: std.atomic.Value(bool),
    listener_thread: ?std.Thread,
    heartbeat_thread: ?std.Thread,
    execute_fn: ?ExecuteWriteFn,
    /// Current mutation sequence (set by main, read by heartbeat)
    mutation_seq: std.atomic.Value(u64),
    /// Connected follower count (for INFO)
    follower_count: std.atomic.Value(u32),

    pub fn init(allocator: Allocator, conf: *const ClusterConfig, base_port: u16) ReplicationLeader {
        return .{
            .allocator = allocator,
            .config = conf,
            .listen_port = base_port + 10000,
            .follower_fds = std.array_list.Managed(i32).init(allocator),
            .running = std.atomic.Value(bool).init(false),
            .listener_thread = null,
            .heartbeat_thread = null,
            .execute_fn = null,
            .mutation_seq = std.atomic.Value(u64).init(0),
            .follower_count = std.atomic.Value(u32).init(0),
        };
    }

    pub fn deinit(self: *ReplicationLeader) void {
        self.stop();
        // Close follower connections
        _ = std.c.pthread_mutex_lock(&self.mutex);
        for (self.follower_fds.items) |fd| {
            _ = std.c.close(fd);
        }
        _ = std.c.pthread_mutex_unlock(&self.mutex);
        self.follower_fds.deinit();
    }

    pub fn start(self: *ReplicationLeader) !void {
        self.running.store(true, .release);
        self.listener_thread = try std.Thread.spawn(.{}, listenerLoop, .{self});
        self.heartbeat_thread = try std.Thread.spawn(.{}, heartbeatLoop, .{self});
    }

    pub fn stop(self: *ReplicationLeader) void {
        self.running.store(false, .release);
        if (self.listener_thread) |t| {
            t.join();
            self.listener_thread = null;
        }
        if (self.heartbeat_thread) |t| {
            t.join();
            self.heartbeat_thread = null;
        }
    }

    /// Broadcast an AOF record to all connected followers.
    /// Called by the leader after executing a write command.
    pub fn broadcastMutation(self: *ReplicationLeader, aof_record: []const u8) void {
        _ = self.mutation_seq.fetchAdd(1, .monotonic);
        _ = std.c.pthread_mutex_lock(&self.mutex);
        defer _ = std.c.pthread_mutex_unlock(&self.mutex);

        var i: usize = 0;
        while (i < self.follower_fds.items.len) {
            const fd = self.follower_fds.items[i];
            std.debug.print("[repl-leader] broadcasting to fd={d} len={d}\n", .{ fd, aof_record.len });
            protocol.writeFrame(fd, .repl_data, aof_record) catch {
                std.debug.print("[repl-leader] broadcast to fd={d} failed\n", .{fd});
                _ = std.c.close(fd);
                _ = self.follower_fds.swapRemove(i);
                continue;
            };
            i += 1;
        }
    }

    fn listenerLoop(self: *ReplicationLeader) void {
        // Create TCP listener on replication port
        const sock = std.c.socket(std.c.AF.INET, std.c.SOCK.STREAM, 0);
        if (sock < 0) return;
        defer _ = std.c.close(sock);

        // SO_REUSEADDR
        const yes: c_int = 1;
        _ = std.c.setsockopt(sock, std.c.SOL.SOCKET, std.c.SO.REUSEADDR, @ptrCast(&yes), @sizeOf(c_int));

        // Bind
        var addr: std.c.sockaddr.in = .{
            .family = std.c.AF.INET,
            .port = std.mem.nativeToBig(u16, self.listen_port),
            .addr = 0, // INADDR_ANY
        };
        if (std.c.bind(sock, @ptrCast(&addr), @sizeOf(std.c.sockaddr.in)) < 0) return;
        if (std.c.listen(sock, 16) < 0) return;

        std.debug.print("[repl-leader] listening on :{d}\n", .{self.listen_port});

        while (self.running.load(.acquire)) {
            // Non-blocking accept with timeout (poll)
            var pfd = [1]std.c.pollfd{.{
                .fd = sock,
                .events = std.c.POLL.IN,
                .revents = 0,
            }};
            const poll_rc = std.c.poll(&pfd, 1, 500); // 500ms timeout
            if (poll_rc <= 0) continue;

            var client_addr: std.c.sockaddr.in = undefined;
            var addr_len: std.c.socklen_t = @sizeOf(std.c.sockaddr.in);
            const client_fd = std.c.accept(sock, @ptrCast(&client_addr), &addr_len);
            if (client_fd < 0) continue;

            std.debug.print("[repl-leader] connection accepted (fd={d})\n", .{client_fd});

            // DON'T add to follower_fds yet — wait until we know this is a repl_stream
            // connection (identified by repl_request frame). Forward connections send
            // write_forward frames and should NOT receive broadcasts.

            // Spawn handler thread for this connection
            const ctx = self.allocator.create(FollowerHandlerCtx) catch continue;
            ctx.* = .{ .leader = self, .fd = client_fd };
            const t = std.Thread.spawn(.{}, followerHandler, .{ctx}) catch {
                self.allocator.destroy(ctx);
                continue;
            };
            t.detach();
        }
    }

    fn heartbeatLoop(self: *ReplicationLeader) void {
        while (self.running.load(.acquire)) {
            // Sleep ~5 seconds (poll with timeout on a dummy)
            var i: u32 = 0;
            while (i < 50 and self.running.load(.acquire)) : (i += 1) {
                std.Thread.yield() catch {};
                var dummy_pfd = [1]std.c.pollfd{.{ .fd = -1, .events = 0, .revents = 0 }};
                _ = std.c.poll(&dummy_pfd, 0, 100); // 100ms sleep
            }
            if (!self.running.load(.acquire)) break;

            // Get current timestamp
            var ts: std.c.timespec = undefined;
            _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
            const now_ms: i64 = @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.nsec)), 1_000_000);

            const hb = protocol.encodeHeartbeat(self.mutation_seq.load(.monotonic), now_ms);

            _ = std.c.pthread_mutex_lock(&self.mutex);
            var j: usize = 0;
            while (j < self.follower_fds.items.len) {
                const fd = self.follower_fds.items[j];
                protocol.writeFrame(fd, .heartbeat, &hb) catch {
                    _ = std.c.close(fd);
                    _ = self.follower_fds.swapRemove(j);
                    _ = self.follower_count.fetchSub(1, .monotonic);
                    continue;
                };
                j += 1;
            }
            _ = std.c.pthread_mutex_unlock(&self.mutex);
        }
    }

    const FollowerHandlerCtx = struct {
        leader: *ReplicationLeader,
        fd: i32,
    };

    fn followerHandler(ctx: *FollowerHandlerCtx) void {
        const self = ctx.leader;
        const fd = ctx.fd;
        defer self.allocator.destroy(ctx);

        while (self.running.load(.acquire)) {
            var pfd = [1]std.c.pollfd{.{
                .fd = fd,
                .events = std.c.POLL.IN,
                .revents = 0,
            }};
            const poll_rc = std.c.poll(&pfd, 1, 500);
            if (poll_rc <= 0) continue;

            const frame = protocol.readFrame(fd, self.allocator) catch |err| {
                std.debug.print("[repl-leader] follower fd={d} read error: {s}\n", .{ fd, @errorName(err) });
                break;
            };

            switch (frame.frame_type) {
                .write_forward => {
                    // Decode command args from payload
                    // NOTE: args are slices into frame.payload — must NOT free payload until done
                    const args = protocol.decodeWriteForward(self.allocator, frame.payload) catch {
                        if (frame.payload.len > 0) self.allocator.free(@constCast(frame.payload));
                        protocol.writeFrame(fd, .write_forward_response, "-ERR decode failed\r\n") catch break;
                        continue;
                    };
                    defer self.allocator.free(args);
                    defer if (frame.payload.len > 0) self.allocator.free(@constCast(frame.payload));

                    // Execute via callback
                    if (self.execute_fn) |exec| {
                        if (exec(self.allocator, args)) |resp_bytes| {
                            defer self.allocator.free(resp_bytes);
                            protocol.writeFrame(fd, .write_forward_response, resp_bytes) catch break;
                        } else {
                            protocol.writeFrame(fd, .write_forward_response, "-ERR execution failed\r\n") catch break;
                        }
                    } else {
                        protocol.writeFrame(fd, .write_forward_response, "-ERR no handler\r\n") catch break;
                    }
                },
                .repl_request => {
                    if (frame.payload.len > 0) self.allocator.free(@constCast(frame.payload));
                    // This connection is a repl_stream — add to broadcast list
                    _ = std.c.pthread_mutex_lock(&self.mutex);
                    self.follower_fds.append(fd) catch {};
                    _ = std.c.pthread_mutex_unlock(&self.mutex);
                    _ = self.follower_count.fetchAdd(1, .monotonic);
                    std.debug.print("[repl-leader] follower fd={d} registered for replication stream\n", .{fd});
                },
                .heartbeat => {
                    if (frame.payload.len > 0) self.allocator.free(@constCast(frame.payload));
                },
                else => {
                    if (frame.payload.len > 0) self.allocator.free(@constCast(frame.payload));
                },
            }
        }
    }
};

/// Follower-side replication: connects to leader, receives mutation stream.
pub const ReplicationFollower = struct {
    allocator: Allocator,
    config: *const ClusterConfig,
    leader_fd: i32, // replication stream (receiver thread reads from this)
    forward_fd: i32, // write forwarding (worker threads write/read from this, mutex-protected)
    forward_mutex: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER,
    running: std.atomic.Value(bool),
    receiver_thread: ?std.Thread,
    replay_fn: ?*const fn (data: []const u8) void,
    local_port: u16,
    /// Replication state — updated by heartbeat
    leader_seq: std.atomic.Value(u64),
    local_seq: std.atomic.Value(u64),
    last_heartbeat_ms: std.atomic.Value(i64),
    replayed_count: std.atomic.Value(u64),

    pub fn init(allocator: Allocator, conf: *const ClusterConfig, local_port: u16) ReplicationFollower {
        return .{
            .allocator = allocator,
            .config = conf,
            .leader_fd = -1,
            .forward_fd = -1,
            .running = std.atomic.Value(bool).init(false),
            .receiver_thread = null,
            .replay_fn = null,
            .local_port = local_port,
            .leader_seq = std.atomic.Value(u64).init(0),
            .local_seq = std.atomic.Value(u64).init(0),
            .last_heartbeat_ms = std.atomic.Value(i64).init(0),
            .replayed_count = std.atomic.Value(u64).init(0),
        };
    }

    pub fn deinit(self: *ReplicationFollower) void {
        self.stop();
        if (self.leader_fd >= 0) {
            _ = std.c.close(self.leader_fd);
            self.leader_fd = -1;
        }
        if (self.forward_fd >= 0) {
            _ = std.c.close(self.forward_fd);
            self.forward_fd = -1;
        }
    }

    /// Connect to the leader's replication port.
    pub fn connectToLeader(self: *ReplicationFollower) !void {
        const leader = self.config.getLeader() orelse return error.NoLeader;
        const repl_port = leader.port + 10000;

        const sock = std.c.socket(std.c.AF.INET, std.c.SOCK.STREAM, 0);
        if (sock < 0) return error.SocketFailed;

        // Resolve leader address (simple IPv4 for now)
        var addr: std.c.sockaddr.in = .{
            .family = std.c.AF.INET,
            .port = std.mem.nativeToBig(u16, repl_port),
            .addr = 0,
        };

        // Resolve hostname → IPv4 (supports both IP addresses and DNS names)
        addr.addr = resolveHost(self.allocator, leader.host) orelse return error.InvalidAddress;

        if (std.c.connect(sock, @ptrCast(&addr), @sizeOf(std.c.sockaddr.in)) < 0) {
            _ = std.c.close(sock);
            return error.ConnectFailed;
        }

        self.leader_fd = sock;

        // Open a second connection for write forwarding (separate from repl stream)
        const fwd_sock = std.c.socket(std.c.AF.INET, std.c.SOCK.STREAM, 0);
        if (fwd_sock >= 0) {
            if (std.c.connect(fwd_sock, @ptrCast(&addr), @sizeOf(std.c.sockaddr.in)) >= 0) {
                self.forward_fd = fwd_sock;
            } else {
                _ = std.c.close(fwd_sock);
            }
        }

        std.debug.print("[repl-follower] connected to leader {s}:{d}\n", .{ leader.host, repl_port });
    }

    pub fn start(self: *ReplicationFollower) !void {
        self.running.store(true, .release);
        self.receiver_thread = try std.Thread.spawn(.{}, receiverLoop, .{self});
    }

    pub fn stop(self: *ReplicationFollower) void {
        self.running.store(false, .release);
        if (self.receiver_thread) |t| {
            t.join();
            self.receiver_thread = null;
        }
    }

    /// Forward a write command to the leader and get the response.
    /// Returns the RESP response bytes to send back to the client.
    pub fn forwardWrite(self: *ReplicationFollower, args: []const []const u8) ![]u8 {
        if (self.forward_fd < 0) return error.NotConnected;

        // Mutex: multiple worker threads may call forwardWrite concurrently
        _ = std.c.pthread_mutex_lock(&self.forward_mutex);
        defer _ = std.c.pthread_mutex_unlock(&self.forward_mutex);

        // Encode and send
        const payload = try protocol.encodeWriteForward(self.allocator, args);
        defer self.allocator.free(payload);
        try protocol.writeFrame(self.forward_fd, .write_forward, payload);

        // Read response from the dedicated forward connection
        const frame = try protocol.readFrame(self.forward_fd, self.allocator);
        if (frame.frame_type != .write_forward_response) {
            if (frame.payload.len > 0) self.allocator.free(@constCast(frame.payload));
            return error.UnexpectedFrame;
        }

        return @constCast(frame.payload);
    }

    fn replayViaLoopback(self: *ReplicationFollower, args_in: []const []const u8) void {
        // Prepend "_REPL" marker so the worker knows this is a replayed command
        // and doesn't forward it back to the leader (which would cause an infinite loop)
        var args_buf: [16][]const u8 = undefined;
        if (args_in.len + 1 > args_buf.len) return;
        args_buf[0] = "_REPL";
        for (args_in, 0..) |a, i| args_buf[i + 1] = a;
        const args = args_buf[0 .. args_in.len + 1];
        // Connect to own RESP port and send the command
        const sock = std.c.socket(std.c.AF.INET, std.c.SOCK.STREAM, 0);
        if (sock < 0) return;
        defer _ = std.c.close(sock);

        var addr: std.c.sockaddr.in = .{
            .family = std.c.AF.INET,
            .port = std.mem.nativeToBig(u16, self.local_port),
            .addr = 0x0100007f, // 127.0.0.1
        };
        if (std.c.connect(sock, @ptrCast(&addr), @sizeOf(std.c.sockaddr.in)) < 0) return;

        // Build RESP command
        var buf = std.array_list.Managed(u8).init(self.allocator);
        defer buf.deinit();
        var hdr: [32]u8 = undefined;
        const h = std.fmt.bufPrint(&hdr, "*{d}\r\n", .{args.len}) catch return;
        buf.appendSlice(h) catch return;
        for (args) |arg| {
            const ah = std.fmt.bufPrint(&hdr, "${d}\r\n", .{arg.len}) catch return;
            buf.appendSlice(ah) catch return;
            buf.appendSlice(arg) catch return;
            buf.appendSlice("\r\n") catch return;
        }

        // Send
        var sent: usize = 0;
        while (sent < buf.items.len) {
            const rc = std.c.write(sock, buf.items[sent..].ptr, buf.items.len - sent);
            if (rc <= 0) return;
            sent += @intCast(rc);
        }

        // Read response (discard — we don't need it)
        var discard: [4096]u8 = undefined;
        _ = std.c.read(sock, &discard, discard.len);
    }

    fn receiverLoop(self: *ReplicationFollower) void {
        // Send initial repl_request with seq=0
        const req = protocol.encodeReplRequest(0);
        protocol.writeFrame(self.leader_fd, .repl_request, &req) catch return;

        while (self.running.load(.acquire)) {
            // Poll for data with timeout
            var pfd = [1]std.c.pollfd{.{
                .fd = self.leader_fd,
                .events = std.c.POLL.IN,
                .revents = 0,
            }};
            const poll_rc = std.c.poll(&pfd, 1, 500);
            if (poll_rc <= 0) continue;

            const frame = protocol.readFrame(self.leader_fd, self.allocator) catch |err| {
                std.debug.print("[repl-follower] read error: {s}\n", .{@errorName(err)});
                break;
            };
            std.debug.print("[repl-follower] received frame type={d}\n", .{@intFromEnum(frame.frame_type)});

            switch (frame.frame_type) {
                .repl_data => {
                    const args = protocol.decodeWriteForward(self.allocator, frame.payload) catch {
                        if (frame.payload.len > 0) self.allocator.free(@constCast(frame.payload));
                        continue;
                    };
                    defer self.allocator.free(args);
                    defer if (frame.payload.len > 0) self.allocator.free(@constCast(frame.payload));

                    self.replayViaLoopback(args);
                    _ = self.local_seq.fetchAdd(1, .monotonic);
                    _ = self.replayed_count.fetchAdd(1, .monotonic);
                },
                .heartbeat => {
                    if (frame.payload.len >= 16) {
                        if (protocol.decodeHeartbeat(frame.payload)) |hb| {
                            self.leader_seq.store(hb.mutation_seq, .release);
                            self.last_heartbeat_ms.store(hb.timestamp_ms, .release);
                        } else |_| {}
                    }
                    if (frame.payload.len > 0) self.allocator.free(@constCast(frame.payload));
                },
                else => {
                    if (frame.payload.len > 0) self.allocator.free(@constCast(frame.payload));
                },
            }
        }
    }
};

/// Determine if a RESP command is a write (mutation) command.
/// Write commands need to be forwarded to the leader on followers.
pub fn isWriteCommand(args: []const []const u8) bool {
    if (args.len == 0) return false;
    const cmd = args[0];
    if (cmd.len == 0) return false;

    // Use a simple approach: check against known write commands
    var upper_buf: [32]u8 = undefined;
    if (cmd.len > upper_buf.len) return false;
    for (cmd, 0..) |c, i| upper_buf[i] = std.ascii.toUpper(c);
    const upper = upper_buf[0..cmd.len];

    if (std.mem.eql(u8, upper, "SET")) return true;
    if (std.mem.eql(u8, upper, "DEL")) return true;
    if (std.mem.eql(u8, upper, "MSET")) return true;
    if (std.mem.eql(u8, upper, "MOVE")) return true;
    if (std.mem.eql(u8, upper, "INCR")) return true;
    if (std.mem.eql(u8, upper, "DECR")) return true;
    if (std.mem.eql(u8, upper, "INCRBY")) return true;
    if (std.mem.eql(u8, upper, "DECRBY")) return true;
    if (std.mem.eql(u8, upper, "APPEND")) return true;
    if (std.mem.eql(u8, upper, "EXPIRE")) return true;
    if (std.mem.eql(u8, upper, "PERSIST")) return true;
    if (std.mem.eql(u8, upper, "FLUSHDB")) return true;
    if (std.mem.eql(u8, upper, "FLUSHALL")) return true;
    // Graph write commands
    if (upper.len >= 12 and std.mem.eql(u8, upper[0..6], "GRAPH.")) {
        if (std.mem.eql(u8, upper[6..], "ADDNODE")) return true;
        if (std.mem.eql(u8, upper[6..], "DELNODE")) return true;
        if (std.mem.eql(u8, upper[6..], "SETPROP")) return true;
        if (std.mem.eql(u8, upper[6..], "ADDEDGE")) return true;
        if (std.mem.eql(u8, upper[6..], "DELEDGE")) return true;
    }
    return false;
}

/// Get replication lag (leader_seq - local_seq).
pub fn replLag(follower: *const ReplicationFollower) u64 {
    const leader = follower.leader_seq.load(.acquire);
    const local = follower.local_seq.load(.acquire);
    return if (leader > local) leader - local else 0;
}

fn resolveHost(allocator: Allocator, host: []const u8) ?u32 {
    // Try numeric IP first
    if (parseIpv4(host)) |ip| return ip;

    // DNS resolution via getaddrinfo
    const host_z = allocator.dupeZ(u8, host) catch return null;
    defer allocator.free(host_z);

    var hints: std.c.addrinfo = std.mem.zeroes(std.c.addrinfo);
    hints.family = std.c.AF.INET;

    var result: ?*std.c.addrinfo = null;
    const gai_result = std.c.getaddrinfo(host_z, null, &hints, &result);
    if (@intFromEnum(gai_result) != 0) return null;
    defer if (result) |r| std.c.freeaddrinfo(r);

    if (result) |res| {
        const addr: *std.c.sockaddr.in = @ptrCast(@alignCast(res.addr));
        return addr.addr;
    }
    return null;
}

fn parseIpv4(s: []const u8) ?u32 {
    var octets: [4]u8 = undefined;
    var octet_idx: usize = 0;
    var start: usize = 0;
    for (s, 0..) |c, i| {
        if (c == '.') {
            if (octet_idx >= 3) return null;
            octets[octet_idx] = std.fmt.parseInt(u8, s[start..i], 10) catch return null;
            octet_idx += 1;
            start = i + 1;
        }
    }
    if (octet_idx != 3) return null;
    octets[3] = std.fmt.parseInt(u8, s[start..], 10) catch return null;
    return @as(u32, octets[0]) | (@as(u32, octets[1]) << 8) | (@as(u32, octets[2]) << 16) | (@as(u32, octets[3]) << 24);
}

// ─── Tests ────────────────────────────────────────────────────────────

test "isWriteCommand" {
    try std.testing.expect(isWriteCommand(&[_][]const u8{"SET"}));
    try std.testing.expect(isWriteCommand(&[_][]const u8{"DEL"}));
    try std.testing.expect(isWriteCommand(&[_][]const u8{"MSET"}));
    try std.testing.expect(isWriteCommand(&[_][]const u8{"INCR"}));
    try std.testing.expect(isWriteCommand(&[_][]const u8{"EXPIRE"}));
    try std.testing.expect(isWriteCommand(&[_][]const u8{"FLUSHDB"}));
    try std.testing.expect(isWriteCommand(&[_][]const u8{"GRAPH.ADDNODE"}));
    try std.testing.expect(isWriteCommand(&[_][]const u8{"GRAPH.ADDEDGE"}));
    try std.testing.expect(isWriteCommand(&[_][]const u8{"GRAPH.DELNODE"}));

    try std.testing.expect(!isWriteCommand(&[_][]const u8{"GET"}));
    try std.testing.expect(!isWriteCommand(&[_][]const u8{"EXISTS"}));
    try std.testing.expect(!isWriteCommand(&[_][]const u8{"KEYS"}));
    try std.testing.expect(!isWriteCommand(&[_][]const u8{"PING"}));
    try std.testing.expect(!isWriteCommand(&[_][]const u8{"INFO"}));
    try std.testing.expect(!isWriteCommand(&[_][]const u8{"GRAPH.TRAVERSE"}));
    try std.testing.expect(!isWriteCommand(&[_][]const u8{"GRAPH.PATH"}));
}
