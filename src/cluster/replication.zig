const std = @import("std");
const Allocator = std.mem.Allocator;
const protocol = @import("protocol.zig");
const vex_log = @import("../log.zig");
const config_mod = @import("config.zig");
const ClusterConfig = config_mod.ClusterConfig;
const ClusterNode = config_mod.ClusterNode;
const atomic_io = @import("../storage/atomic_io.zig");
const obs_stats = @import("../observability/stats.zig");

fn nowMs() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    return @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.nsec)), 1_000_000);
}

/// Leader-side replication: accepts follower connections and streams mutations.
/// Callback type for executing a forwarded write command on the leader.
/// Returns the RESP response bytes (caller must free).
pub const ExecuteWriteFn = *const fn (allocator: Allocator, args: []const []const u8) ?[]u8;
/// Callback to get a snapshot of the current state (returns snapshot bytes).
pub const GetSnapshotFn = *const fn (allocator: Allocator) ?[]u8;

pub const HEARTBEAT_INTERVAL_MS: i64 = 5000; // 5 seconds
pub const HEARTBEAT_TIMEOUT_MS: i64 = 15000; // 3 missed heartbeats = leader dead

/// Process-wide handles for INFO/observability readers. main.zig publishes
/// these at startup; readers (cmdInfo) load via `@atomicLoad`. Either or
/// both may be null in standalone mode.
pub var current_leader_ptr: std.atomic.Value(?*ReplicationLeader) = std.atomic.Value(?*ReplicationLeader).init(null);
pub var current_follower_ptr: std.atomic.Value(?*ReplicationFollower) = std.atomic.Value(?*ReplicationFollower).init(null);

/// Process-wide cluster epoch. Monotonically increasing across leader
/// promotions. Followers and old leaders use this to reject frames from
/// stale leaders (preventing split-brain writes from being applied).
///
/// Persisted to `<data_dir>/vex.epoch` via atomic_io on every change.
/// Loaded at startup; defaults to 0 when no prior file exists.
pub var current_epoch: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

/// Load `<data_dir>/vex.epoch` into `current_epoch`. Called once at
/// startup from main. Missing file is treated as epoch=0 (fresh cluster).
pub fn loadEpoch(allocator: Allocator, data_dir: []const u8) void {
    const path = std.fmt.allocPrint(allocator, "{s}/vex.epoch", .{data_dir}) catch return;
    defer allocator.free(path);
    const path_z = allocator.dupeSentinel(u8, path, 0) catch return;
    defer allocator.free(path_z);
    const fd = std.c.open(path_z.ptr, .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    if (fd < 0) return; // missing → epoch stays 0
    defer _ = std.c.close(fd);
    var buf: [16]u8 = undefined;
    const n = std.c.read(fd, &buf, buf.len);
    if (n < 8) return;
    const epoch = std.mem.readInt(u64, buf[0..8], .little);
    current_epoch.store(epoch, .release);
    vex_log.info("cluster: loaded epoch {d} from vex.epoch", .{epoch});
}

/// Atomically bump and persist `current_epoch`. The promoter (vex-sentinel
/// via VEX.PROMOTE, or the legacy auto-promote path during failover) calls
/// this before declaring itself leader. Returns the new epoch.
pub fn bumpAndPersistEpoch(allocator: Allocator, data_dir: []const u8, new_epoch: u64) !u64 {
    const current = current_epoch.load(.monotonic);
    if (new_epoch <= current) return error.StaleEpoch;
    const path = try std.fmt.allocPrint(allocator, "{s}/vex.epoch", .{data_dir});
    defer allocator.free(path);
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, new_epoch, .little);
    try atomic_io.atomicWrite(allocator, path, &bytes);
    current_epoch.store(new_epoch, .release);
    vex_log.info("cluster: epoch advanced to {d} (persisted)", .{new_epoch});
    return new_epoch;
}

/// Probe if any other node in the cluster is already acting as leader.
/// Tries connecting to each node's replication port (base_port + 10000).
/// Returns the node that responded, or null if no leader found.
pub fn probeForLeader(allocator: Allocator, config: *const config_mod.ClusterConfig) ?config_mod.ClusterNode {
    for (config.nodes) |node| {
        if (node.id == config.self_id) continue;

        const repl_port = node.port + 10000;
        const sock = std.c.socket(std.c.AF.INET, std.c.SOCK.STREAM, 0);
        if (sock < 0) continue;

        var addr: std.c.sockaddr.in = .{
            .family = std.c.AF.INET,
            .port = std.mem.nativeToBig(u16, repl_port),
            .addr = 0,
        };
        addr.addr = resolveHost(allocator, node.host) orelse {
            _ = std.c.close(sock);
            continue;
        };

        // Set a short connection timeout (2 seconds)
        var tv: std.c.timeval = .{ .sec = 2, .usec = 0 };
        _ = std.c.setsockopt(sock, std.c.SOL.SOCKET, std.c.SO.SNDTIMEO, @ptrCast(&tv), @sizeOf(std.c.timeval));

        if (std.c.connect(sock, @ptrCast(&addr), @sizeOf(std.c.sockaddr.in)) >= 0) {
            _ = std.c.close(sock);
            vex_log.info("failover: found active leader: node {d} at {s}:{d}", .{ node.id, node.host, repl_port });
            return node;
        }
        _ = std.c.close(sock);
    }
    return null;
}

/// Outbox item: a buffered frame waiting to be written by the drain thread.
/// `payload` is an owned slice allocated by the enqueuer; the drain thread
/// frees it after attempting to write.
const OutboxItem = struct {
    frame_type: protocol.FrameType,
    payload: []u8,
};

/// Per-follower state. Owned by the leader; each follower has a dedicated
/// drain thread that pulls from `outbox` and writes to `fd`.
pub const FollowerState = struct {
    fd: i32,
    addr: [47:0]u8, // textual "ip:port" snapshot, NUL-padded
    addr_len: u8,
    connected_ts_ms: i64,
    /// Bounded outbox queue. Each item's `payload` is an owned byte slice.
    outbox: std.array_list.Managed(OutboxItem),
    outbox_mutex: std.c.pthread_mutex_t,
    outbox_cond: std.c.pthread_cond_t,
    outbox_max: u32,
    outbox_dropped: u64,
    /// Set to true while the drain thread is alive. When the drain thread
    /// errors (write failed), it sets this to false and the leader reaps the
    /// follower on the next broadcast/heartbeat pass.
    running: std.atomic.Value(bool),
    drain_thread: ?std.Thread,
    allocator: Allocator,
    /// Last applied_seq reported by this follower via repl_ack. Lag in seq
    /// units is `leader.mutation_seq - last_ack_seq`. Updated by the leader
    /// when it processes an inbound repl_ack frame from this follower.
    last_ack_seq: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    last_ack_ts_ms: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),
    last_ack_epoch: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    pub fn addrSlice(self: *const FollowerState) []const u8 {
        return self.addr[0..self.addr_len];
    }
};

const DEFAULT_OUTBOX_MAX: u32 = 1024;

/// Format an IPv4 sockaddr into "ip:port" text. Returns the byte length.
fn formatAddr(buf: *[47:0]u8, sa: *const std.c.sockaddr.in) u8 {
    const a = std.mem.toBytes(sa.addr); // raw 4 bytes, network order on the wire,
    // but `sa.addr` is host-endian-unsigned holding the network-order pattern
    // exactly as filled by accept(2). We just print the bytes in order.
    const port = std.mem.bigToNative(u16, sa.port);
    const written = std.fmt.bufPrint(buf[0..47], "{d}.{d}.{d}.{d}:{d}", .{
        a[0], a[1], a[2], a[3], port,
    }) catch {
        const fallback = "?:?";
        @memcpy(buf[0..fallback.len], fallback);
        buf[fallback.len] = 0;
        return @intCast(fallback.len);
    };
    buf[written.len] = 0;
    return @intCast(written.len);
}

/// Allocate and initialize a FollowerState. Caller is responsible for
/// starting its drain thread and inserting it into the leader's list.
fn createFollowerState(allocator: Allocator, fd: i32, outbox_max: u32) !*FollowerState {
    const state = try allocator.create(FollowerState);
    var addr_buf: [47:0]u8 = undefined;
    @memset(addr_buf[0..47], 0);
    addr_buf[47] = 0;
    state.* = .{
        .fd = fd,
        .addr = addr_buf,
        .addr_len = 0,
        .connected_ts_ms = nowMs(),
        .outbox = std.array_list.Managed(OutboxItem).init(allocator),
        .outbox_mutex = std.c.PTHREAD_MUTEX_INITIALIZER,
        .outbox_cond = std.c.PTHREAD_COND_INITIALIZER,
        .outbox_max = outbox_max,
        .outbox_dropped = 0,
        .running = std.atomic.Value(bool).init(true),
        .drain_thread = null,
        .allocator = allocator,
    };

    // Capture peer address. Best-effort; failure leaves addr empty.
    var sa: std.c.sockaddr.in = undefined;
    var sa_len: std.c.socklen_t = @sizeOf(std.c.sockaddr.in);
    if (std.c.getpeername(fd, @ptrCast(&sa), &sa_len) == 0) {
        state.addr_len = formatAddr(&state.addr, &sa);
    }

    return state;
}

/// Free a follower state. Caller must ensure the drain thread is joined and
/// the fd is closed before calling.
fn destroyFollowerState(state: *FollowerState) void {
    // Drain any remaining outbox items
    for (state.outbox.items) |item| {
        if (item.payload.len > 0) state.allocator.free(item.payload);
    }
    state.outbox.deinit();
    _ = std.c.pthread_cond_destroy(&state.outbox_cond);
    // pthread_mutex_destroy not strictly needed for static-init mutex on macOS,
    // but kept for hygiene if pthread tracks it.
    _ = std.c.pthread_mutex_destroy(&state.outbox_mutex);
    state.allocator.destroy(state);
}

pub const ReplicationLeader = struct {
    allocator: Allocator,
    config: *const ClusterConfig,
    listen_port: u16,
    /// Connected followers. Each entry is heap-allocated; the leader owns it.
    followers: std.array_list.Managed(*FollowerState),
    mutex: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER,
    running: std.atomic.Value(bool),
    listener_thread: ?std.Thread,
    heartbeat_thread: ?std.Thread,
    execute_fn: ?ExecuteWriteFn,
    snapshot_fn: ?GetSnapshotFn,
    /// Current mutation sequence (set by main, read by heartbeat)
    mutation_seq: std.atomic.Value(u64),
    /// Connected follower count (for INFO)
    follower_count: std.atomic.Value(u32),

    pub fn init(allocator: Allocator, conf: *const ClusterConfig, base_port: u16) ReplicationLeader {
        return .{
            .allocator = allocator,
            .config = conf,
            .listen_port = base_port + 10000,
            .followers = std.array_list.Managed(*FollowerState).init(allocator),
            .running = std.atomic.Value(bool).init(false),
            .listener_thread = null,
            .heartbeat_thread = null,
            .execute_fn = null,
            .snapshot_fn = null,
            .mutation_seq = std.atomic.Value(u64).init(0),
            .follower_count = std.atomic.Value(u32).init(0),
        };
    }

    pub fn deinit(self: *ReplicationLeader) void {
        self.stop();

        // Take ownership of the followers list under the lock so no one else
        // mutates it while we are tearing down.
        _ = std.c.pthread_mutex_lock(&self.mutex);
        const states = self.followers.toOwnedSlice() catch &[_]*FollowerState{};
        _ = std.c.pthread_mutex_unlock(&self.mutex);

        // Signal every drain thread to stop, then join them.
        for (states) |state| {
            state.running.store(false, .release);
            _ = std.c.pthread_mutex_lock(&state.outbox_mutex);
            _ = std.c.pthread_cond_broadcast(&state.outbox_cond);
            _ = std.c.pthread_mutex_unlock(&state.outbox_mutex);
        }
        for (states) |state| {
            if (state.drain_thread) |t| {
                t.join();
                state.drain_thread = null;
            }
            if (state.fd >= 0) {
                _ = std.c.close(state.fd);
                state.fd = -1;
            }
            destroyFollowerState(state);
        }
        if (states.len > 0) self.allocator.free(states);
        self.followers.deinit();
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

    /// Reap any followers whose drain thread has exited (running=false) or
    /// have been explicitly flagged for disconnection. Must be called WITHOUT
    /// holding `self.mutex`; takes the lock internally.
    fn reapDeadFollowers(self: *ReplicationLeader) void {
        var to_destroy = std.array_list.Managed(*FollowerState).init(self.allocator);
        defer to_destroy.deinit();

        _ = std.c.pthread_mutex_lock(&self.mutex);
        var i: usize = 0;
        while (i < self.followers.items.len) {
            const state = self.followers.items[i];
            if (!state.running.load(.acquire)) {
                _ = self.followers.swapRemove(i);
                _ = self.follower_count.fetchSub(1, .monotonic);
                to_destroy.append(state) catch {};
                continue;
            }
            i += 1;
        }
        _ = std.c.pthread_mutex_unlock(&self.mutex);

        for (to_destroy.items) |state| {
            // Ensure drain thread is fully done. It already set running=false,
            // but join to release thread resources.
            _ = std.c.pthread_mutex_lock(&state.outbox_mutex);
            _ = std.c.pthread_cond_broadcast(&state.outbox_cond);
            _ = std.c.pthread_mutex_unlock(&state.outbox_mutex);
            if (state.drain_thread) |t| {
                t.join();
                state.drain_thread = null;
            }
            if (state.fd >= 0) {
                _ = std.c.close(state.fd);
                state.fd = -1;
            }
            vex_log.info("repl-leader: removed follower {s} (drain ended)", .{state.addrSlice()});
            destroyFollowerState(state);
        }
    }

    /// Enqueue a frame to a single follower's outbox. Returns true on success,
    /// false if the outbox is full (caller should disconnect the follower).
    /// Must be called WITHOUT holding `self.mutex`.
    fn enqueueToFollower(
        self: *ReplicationLeader,
        state: *FollowerState,
        frame_type: protocol.FrameType,
        payload: []const u8,
    ) bool {
        _ = self;
        // Dupe the payload first (outside the lock) to keep the critical section short.
        const dup = state.allocator.dupe(u8, payload) catch {
            vex_log.warn("repl-leader: outbox enqueue OOM for follower {s}", .{state.addrSlice()});
            return false;
        };

        _ = std.c.pthread_mutex_lock(&state.outbox_mutex);
        if (state.outbox.items.len >= state.outbox_max) {
            state.outbox_dropped += 1;
            const dropped = state.outbox_dropped;
            _ = std.c.pthread_mutex_unlock(&state.outbox_mutex);
            state.allocator.free(dup);
            vex_log.warn(
                "repl-leader: follower {s} outbox full ({d} items), dropping frame and disconnecting (dropped_total={d})",
                .{ state.addrSlice(), state.outbox_max, dropped },
            );
            return false;
        }
        state.outbox.append(.{ .frame_type = frame_type, .payload = dup }) catch {
            _ = std.c.pthread_mutex_unlock(&state.outbox_mutex);
            state.allocator.free(dup);
            vex_log.warn("repl-leader: outbox append failed for follower {s}", .{state.addrSlice()});
            return false;
        };
        _ = std.c.pthread_cond_signal(&state.outbox_cond);
        _ = std.c.pthread_mutex_unlock(&state.outbox_mutex);
        return true;
    }

    /// Broadcast an AOF record to all connected followers.
    /// Called by the leader after executing a write command.
    /// This is non-blocking: each follower receives a copy of the frame in
    /// its private outbox; a dedicated drain thread per follower performs
    /// the actual socket write.
    pub fn broadcastMutation(self: *ReplicationLeader, aof_record: []const u8) void {
        _ = self.mutation_seq.fetchAdd(1, .monotonic);

        // Snapshot the followers list under the lock, then release immediately.
        _ = std.c.pthread_mutex_lock(&self.mutex);
        const snapshot = self.allocator.alloc(*FollowerState, self.followers.items.len) catch {
            _ = std.c.pthread_mutex_unlock(&self.mutex);
            return;
        };
        @memcpy(snapshot, self.followers.items);
        _ = std.c.pthread_mutex_unlock(&self.mutex);
        defer self.allocator.free(snapshot);

        // Enqueue to each follower; if enqueue fails (outbox full), mark for disconnect.
        for (snapshot) |state| {
            if (!state.running.load(.acquire)) continue;
            vex_log.debug(
                "repl-leader: broadcasting to {s} (fd={d} len={d})",
                .{ state.addrSlice(), state.fd, aof_record.len },
            );
            if (!self.enqueueToFollower(state, .repl_data, aof_record)) {
                // Outbox full or alloc failure — disconnect this follower.
                state.running.store(false, .release);
                _ = std.c.pthread_mutex_lock(&state.outbox_mutex);
                _ = std.c.pthread_cond_broadcast(&state.outbox_cond);
                _ = std.c.pthread_mutex_unlock(&state.outbox_mutex);
            }
        }

        // Clean up any drain threads that exited (either by enqueue overflow
        // above or by a prior write error).
        self.reapDeadFollowers();
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

        vex_log.info("repl-leader: listening on :{d}", .{self.listen_port});

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

            vex_log.info("repl-leader: connection accepted (fd={d})", .{client_fd});

            // DON'T add to followers yet — wait until we know this is a repl_stream
            // connection (identified by repl_request frame). Forward connections send
            // write_forward frames and should NOT receive broadcasts.

            // Spawn handler thread for this connection
            const ctx = self.allocator.create(FollowerHandlerCtx) catch {
                _ = std.c.close(client_fd);
                continue;
            };
            ctx.* = .{ .leader = self, .fd = client_fd };
            const t = std.Thread.spawn(.{}, followerHandler, .{ctx}) catch {
                self.allocator.destroy(ctx);
                _ = std.c.close(client_fd);
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

            const hb = protocol.encodeHeartbeat(current_epoch.load(.monotonic), self.mutation_seq.load(.monotonic), now_ms);

            // Snapshot followers, release the lock, then enqueue.
            _ = std.c.pthread_mutex_lock(&self.mutex);
            const snapshot = self.allocator.alloc(*FollowerState, self.followers.items.len) catch {
                _ = std.c.pthread_mutex_unlock(&self.mutex);
                continue;
            };
            @memcpy(snapshot, self.followers.items);
            _ = std.c.pthread_mutex_unlock(&self.mutex);
            defer self.allocator.free(snapshot);

            for (snapshot) |state| {
                if (!state.running.load(.acquire)) continue;
                if (!self.enqueueToFollower(state, .heartbeat, &hb)) {
                    state.running.store(false, .release);
                    _ = std.c.pthread_mutex_lock(&state.outbox_mutex);
                    _ = std.c.pthread_cond_broadcast(&state.outbox_cond);
                    _ = std.c.pthread_mutex_unlock(&state.outbox_mutex);
                }
            }

            self.reapDeadFollowers();
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

        // `registered` flips to true once this fd has been moved into
        // `self.followers` (i.e. ownership transferred to a FollowerState).
        // While false, this handler still owns `fd` and must close it on exit.
        var registered: bool = false;
        defer if (!registered) {
            _ = std.c.close(fd);
        };
        // Once registered, keep reading from the fd for `.repl_ack` frames
        // so we can record per-follower lag. Stop when the FollowerState's
        // drain thread marks itself non-running (write failure → reap).
        var my_state: ?*FollowerState = null;

        while (self.running.load(.acquire)) {
            // If we were registered but the drain thread has marked the
            // follower for reaping, stop reading.
            if (my_state) |st| {
                if (!st.running.load(.acquire)) return;
            }

            var pfd = [1]std.c.pollfd{.{
                .fd = fd,
                .events = std.c.POLL.IN,
                .revents = 0,
            }};
            const poll_rc = std.c.poll(&pfd, 1, 500);
            if (poll_rc <= 0) continue;

            const frame = protocol.readFrame(fd, self.allocator) catch |err| {
                vex_log.warn("repl-leader: follower fd={d} read error: {s}", .{ fd, @errorName(err) });
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
                    // Decode requested seq
                    const req_seq = if (frame.payload.len >= 8)
                        protocol.decodeReplRequest(frame.payload) catch 0
                    else
                        0;
                    if (frame.payload.len > 0) self.allocator.free(@constCast(frame.payload));

                    // If seq=0, send full sync (snapshot transfer)
                    if (req_seq == 0) {
                        if (self.snapshot_fn) |snap_fn| {
                            vex_log.info("repl-leader: follower fd={d} requesting full sync", .{fd});
                            if (snap_fn(self.allocator)) |snap_data| {
                                defer self.allocator.free(snap_data);
                                protocol.writeFrame(fd, .full_sync_data, snap_data) catch {
                                    vex_log.warn("repl-leader: full sync write failed for fd={d}", .{fd});
                                };
                                vex_log.info("repl-leader: full sync sent to fd={d} ({d} bytes)", .{ fd, snap_data.len });
                            }
                        }
                    }

                    // Register for broadcast list: allocate FollowerState, spawn drain thread,
                    // append to leader's followers list. Ownership of `fd` transfers to the state.
                    const state = createFollowerState(self.allocator, fd, DEFAULT_OUTBOX_MAX) catch {
                        vex_log.warn("repl-leader: failed to allocate FollowerState for fd={d}", .{fd});
                        break;
                    };
                    state.drain_thread = std.Thread.spawn(.{}, followerDrainLoop, .{state}) catch {
                        vex_log.warn("repl-leader: failed to spawn drain thread for fd={d}", .{fd});
                        destroyFollowerState(state);
                        break;
                    };

                    _ = std.c.pthread_mutex_lock(&self.mutex);
                    self.followers.append(state) catch {
                        _ = std.c.pthread_mutex_unlock(&self.mutex);
                        // Failed to append — shut down the drain thread and clean up.
                        state.running.store(false, .release);
                        _ = std.c.pthread_mutex_lock(&state.outbox_mutex);
                        _ = std.c.pthread_cond_broadcast(&state.outbox_cond);
                        _ = std.c.pthread_mutex_unlock(&state.outbox_mutex);
                        if (state.drain_thread) |t| {
                            t.join();
                            state.drain_thread = null;
                        }
                        destroyFollowerState(state);
                        break;
                    };
                    _ = std.c.pthread_mutex_unlock(&self.mutex);
                    _ = self.follower_count.fetchAdd(1, .monotonic);
                    registered = true;
                    my_state = state;
                    vex_log.info(
                        "repl-leader: follower {s} (fd={d}) registered for replication stream (from seq={d})",
                        .{ state.addrSlice(), fd, req_seq },
                    );
                    // Continue the loop to keep reading repl_ack frames from
                    // this follower. The drain thread now owns writes; we
                    // own reads. When the drain thread marks running=false
                    // (write failure), we exit on the next iteration.
                },
                .repl_ack => {
                    if (frame.payload.len >= 16) {
                        if (protocol.decodeReplAck(frame.payload)) |ack| {
                            if (my_state) |st| {
                                st.last_ack_seq.store(ack.applied_seq, .release);
                                st.last_ack_epoch.store(ack.epoch, .release);
                                var ts: std.c.timespec = undefined;
                                _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
                                const now_ms: i64 = @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.nsec)), 1_000_000);
                                st.last_ack_ts_ms.store(now_ms, .release);
                            }
                        } else |_| {}
                    }
                    if (frame.payload.len > 0) self.allocator.free(@constCast(frame.payload));
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

    /// Drain loop: one per follower. Pulls frames from the outbox and writes
    /// them to the follower's socket. Exits on write error or when
    /// `running` becomes false.
    fn followerDrainLoop(state: *FollowerState) void {
        while (state.running.load(.acquire)) {
            // Wait for an item to appear in the outbox.
            _ = std.c.pthread_mutex_lock(&state.outbox_mutex);
            while (state.running.load(.acquire) and state.outbox.items.len == 0) {
                _ = std.c.pthread_cond_wait(&state.outbox_cond, &state.outbox_mutex);
            }
            if (!state.running.load(.acquire)) {
                _ = std.c.pthread_mutex_unlock(&state.outbox_mutex);
                break;
            }

            // Pop the front item (FIFO order). swapRemove is O(1) but reorders;
            // use orderedRemove to preserve ordering for correctness.
            const item = state.outbox.orderedRemove(0);
            _ = std.c.pthread_mutex_unlock(&state.outbox_mutex);

            // Write the frame outside the outbox lock. If this blocks (slow
            // follower with full kernel buffer), only this follower's outbox
            // backs up — other followers and the broadcast path are unaffected.
            protocol.writeFrame(state.fd, item.frame_type, item.payload) catch |err| {
                vex_log.warn(
                    "repl-leader: drain write failed for follower {s}: {s}",
                    .{ state.addrSlice(), @errorName(err) },
                );
                if (item.payload.len > 0) state.allocator.free(item.payload);
                state.running.store(false, .release);
                // Reaper (in broadcastMutation/heartbeatLoop) will join us and clean up.
                return;
            };

            if (item.payload.len > 0) state.allocator.free(item.payload);
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
    /// Callback to load a snapshot (full sync)
    load_snapshot_fn: ?*const fn (data: []const u8) bool,
    local_port: u16,
    /// Set when this follower has been promoted to leader (by an external
    /// trigger, e.g. VEX.PROMOTE driven by vex-sentinel). vex itself never
    /// flips this — failover policy lives outside the data plane.
    promoted: std.atomic.Value(bool),
    /// After promotion, points to the new ReplicationLeader (stored as usize for atomics)
    promoted_leader_ptr: std.atomic.Value(usize),
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
            .load_snapshot_fn = null,
            .local_port = local_port,
            .promoted = std.atomic.Value(bool).init(false),
            .promoted_leader_ptr = std.atomic.Value(usize).init(0),
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

        vex_log.info("repl-follower: connected to leader {s}:{d}", .{ leader.host, repl_port });
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

    /// Get the ReplicationLeader created after this follower was promoted.
    /// Returns null if not promoted or leader not yet initialized.
    pub fn getPromotedLeader(self: *const ReplicationFollower) ?*ReplicationLeader {
        const v = self.promoted_leader_ptr.load(.acquire);
        return if (v == 0) null else @ptrFromInt(v);
    }

    /// Forward a write command to the leader and get the response.
    /// Returns the RESP response bytes to send back to the client.
    pub fn forwardWrite(self: *ReplicationFollower, args: []const []const u8) ![]u8 {
        if (self.promoted.load(.acquire)) return error.Promoted;
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
        self.runReceiverOnce();

        // If not promoted and still running, attempt reconnection to a new leader
        while (self.running.load(.acquire) and !self.promoted.load(.acquire)) {
            vex_log.warn("failover: lost leader connection, attempting reconnection...", .{});

            // Close stale fds
            if (self.leader_fd >= 0) {
                _ = std.c.close(self.leader_fd);
                self.leader_fd = -1;
            }
            if (self.forward_fd >= 0) {
                _ = std.c.close(self.forward_fd);
                self.forward_fd = -1;
            }

            var attempts: u32 = 0;
            var reconnected = false;
            while (self.running.load(.acquire) and !self.promoted.load(.acquire) and attempts < 30) : (attempts += 1) {
                // Wait 2s between attempts
                var dummy_pfd = [1]std.c.pollfd{.{ .fd = -1, .events = 0, .revents = 0 }};
                _ = std.c.poll(&dummy_pfd, 0, 2000);

                if (probeForLeader(self.allocator, self.config)) |leader_node| {
                    const repl_port = leader_node.port + 10000;
                    const sock = std.c.socket(std.c.AF.INET, std.c.SOCK.STREAM, 0);
                    if (sock < 0) continue;

                    var addr: std.c.sockaddr.in = .{
                        .family = std.c.AF.INET,
                        .port = std.mem.nativeToBig(u16, repl_port),
                        .addr = 0,
                    };
                    addr.addr = resolveHost(self.allocator, leader_node.host) orelse {
                        _ = std.c.close(sock);
                        continue;
                    };

                    if (std.c.connect(sock, @ptrCast(&addr), @sizeOf(std.c.sockaddr.in)) >= 0) {
                        self.leader_fd = sock;

                        // Open forward connection
                        const fwd_sock = std.c.socket(std.c.AF.INET, std.c.SOCK.STREAM, 0);
                        if (fwd_sock >= 0) {
                            if (std.c.connect(fwd_sock, @ptrCast(&addr), @sizeOf(std.c.sockaddr.in)) >= 0) {
                                self.forward_fd = fwd_sock;
                            } else {
                                _ = std.c.close(fwd_sock);
                            }
                        }

                        vex_log.info("failover: reconnected to new leader node {d} at {s}:{d}", .{ leader_node.id, leader_node.host, repl_port });
                        reconnected = true;
                        break;
                    }
                    _ = std.c.close(sock);
                }
            }

            if (!reconnected) {
                vex_log.warn("failover: exhausted reconnection attempts", .{});
                break;
            }

            // Re-enter the receive loop with new leader connection
            self.runReceiverOnce();
        }
    }

    /// Inner receive loop: sends repl_request, processes frames until disconnect or promotion.
    fn runReceiverOnce(self: *ReplicationFollower) void {
        // Send initial repl_request with seq=0
        const req = protocol.encodeReplRequest(0);
        protocol.writeFrame(self.leader_fd, .repl_request, &req) catch return;

        // Record initial time for heartbeat tracking
        self.last_heartbeat_ms.store(nowMs(), .release);
        // Throttle the timeout block so we don't spam logs / probe every 500ms.
        var last_timeout_check_ms: i64 = 0;
        const TIMEOUT_CHECK_INTERVAL_MS: i64 = 5_000;

        while (self.running.load(.acquire)) {
            // Poll for data with timeout
            var pfd = [1]std.c.pollfd{.{
                .fd = self.leader_fd,
                .events = std.c.POLL.IN,
                .revents = 0,
            }};
            const poll_rc = std.c.poll(&pfd, 1, 500);

            // Check heartbeat timeout. vex never decides to promote itself —
            // failover policy lives in vex-sentinel, which issues VEX.PROMOTE
            // over the admin port. Here we just surface the condition (log +
            // obs_stats flag) and keep probing so we can reconnect once a new
            // leader appears.
            const now = nowMs();
            const last_hb = self.last_heartbeat_ms.load(.acquire);
            if (last_hb > 0 and (now - last_hb) > HEARTBEAT_TIMEOUT_MS and
                (now - last_timeout_check_ms) > TIMEOUT_CHECK_INTERVAL_MS)
            {
                last_timeout_check_ms = now;
                vex_log.warn("leader heartbeat timeout ({d}ms); awaiting VEX.PROMOTE", .{now - last_hb});
                obs_stats.leader_unreachable.store(true, .release);
                if (probeForLeader(self.allocator, self.config)) |_| {
                    vex_log.info("new leader detected — reconnecting", .{});
                    return; // Exit to reconnect in outer loop
                }
            }

            if (poll_rc <= 0) continue;

            const frame = protocol.readFrame(self.leader_fd, self.allocator) catch |err| {
                vex_log.warn("repl-follower: read error: {s}", .{@errorName(err)});
                return; // Exit to reconnect
            };
            vex_log.debug("repl-follower: received frame type={d}", .{@intFromEnum(frame.frame_type)});

            // Any valid frame from the leader means the link is alive — clear
            // the unreachable flag so INFO Replication / sentinel see :up again.
            obs_stats.leader_unreachable.store(false, .release);

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
                .full_sync_data => {
                    vex_log.info("repl-follower: received full sync ({d} bytes)", .{frame.payload.len});
                    if (self.load_snapshot_fn) |load_fn| {
                        if (load_fn(frame.payload)) {
                            vex_log.info("repl-follower: full sync loaded successfully", .{});
                        } else {
                            vex_log.warn("repl-follower: full sync load failed", .{});
                        }
                    }
                    if (frame.payload.len > 0) self.allocator.free(@constCast(frame.payload));
                },
                .heartbeat => {
                    if (frame.payload.len >= 16) {
                        if (protocol.decodeHeartbeat(frame.payload)) |hb| {
                            // Epoch protection: reject heartbeats from stale
                            // leaders. If the incoming epoch is older than
                            // what we know, the sender is no longer
                            // authoritative — drop the heartbeat so the
                            // follower detects timeout and reconnects.
                            const my_epoch = current_epoch.load(.monotonic);
                            if (hb.epoch < my_epoch) {
                                vex_log.warn("repl-follower: rejecting heartbeat from stale epoch {d} (current {d})", .{ hb.epoch, my_epoch });
                            } else {
                                if (hb.epoch > my_epoch) {
                                    vex_log.info("repl-follower: leader epoch advanced from {d} to {d}", .{ my_epoch, hb.epoch });
                                    current_epoch.store(hb.epoch, .release);
                                }
                                self.leader_seq.store(hb.mutation_seq, .release);
                                self.last_heartbeat_ms.store(hb.timestamp_ms, .release);
                                // Piggyback an ack on every heartbeat. This is
                                // ~5s cadence — sufficient for the leader to
                                // measure lag in seq units. A finer cadence
                                // (every N applied mutations) is a follow-up
                                // optimization if needed.
                                const ack_payload = protocol.encodeReplAck(self.local_seq.load(.monotonic), current_epoch.load(.monotonic));
                                protocol.writeFrame(self.leader_fd, .repl_ack, &ack_payload) catch {};
                            }
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
    if (std.mem.eql(u8, upper, "PEXPIRE")) return true;
    if (std.mem.eql(u8, upper, "UNLINK")) return true;
    if (std.mem.eql(u8, upper, "SETNX")) return true;
    if (std.mem.eql(u8, upper, "SETEX")) return true;
    if (std.mem.eql(u8, upper, "GETSET")) return true;
    if (std.mem.eql(u8, upper, "GETDEL")) return true;
    if (std.mem.eql(u8, upper, "RENAME")) return true;
    if (std.mem.eql(u8, upper, "RENAMENX")) return true;
    if (std.mem.eql(u8, upper, "COPY")) return true;
    if (std.mem.eql(u8, upper, "FLUSHDB")) return true;
    if (std.mem.eql(u8, upper, "FLUSHALL")) return true;
    // List write commands
    if (std.mem.eql(u8, upper, "LPUSH")) return true;
    if (std.mem.eql(u8, upper, "RPUSH")) return true;
    if (std.mem.eql(u8, upper, "LPOP")) return true;
    if (std.mem.eql(u8, upper, "RPOP")) return true;
    if (std.mem.eql(u8, upper, "LSET")) return true;
    if (std.mem.eql(u8, upper, "LREM")) return true;
    // Hash write commands
    if (std.mem.eql(u8, upper, "HSET")) return true;
    if (std.mem.eql(u8, upper, "HDEL")) return true;
    if (std.mem.eql(u8, upper, "HMSET")) return true;
    if (std.mem.eql(u8, upper, "HINCRBY")) return true;
    // Set write commands
    if (std.mem.eql(u8, upper, "SADD")) return true;
    if (std.mem.eql(u8, upper, "SREM")) return true;
    // Sorted set write commands
    if (std.mem.eql(u8, upper, "ZADD")) return true;
    if (std.mem.eql(u8, upper, "ZREM")) return true;
    if (std.mem.eql(u8, upper, "ZINCRBY")) return true;
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
    const host_z = allocator.dupeSentinel(u8, host, 0) catch return null;
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

