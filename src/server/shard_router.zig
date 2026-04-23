const std = @import("std");
const Allocator = std.mem.Allocator;

/// Number of key slots (Redis Cluster compatible).
pub const TOTAL_SLOTS: u32 = 16384;

/// Compute the slot for a key. Uses wyhash for speed.
pub fn slotForKey(key: []const u8) u32 {
    return @as(u32, @truncate(std.hash.Wyhash.hash(0, key))) % TOTAL_SLOTS;
}

/// Compute which worker owns a slot.
pub fn workerForSlot(slot: u32, num_workers: u32) u16 {
    return @intCast(slot % num_workers);
}

/// Compute which worker owns a key directly.
pub fn workerForKey(key: []const u8, num_workers: u32) u16 {
    return workerForSlot(slotForKey(key), num_workers);
}

/// Lock-free MPSC (multi-producer single-consumer) ring buffer for
/// cross-worker command routing. Producers (any worker) enqueue via CAS.
/// Consumer (the owning worker) drains in its event loop.
pub fn MpscQueue(comptime T: type, comptime CAPACITY: usize) type {
    return struct {
        const Self = @This();

        buf: [CAPACITY]T = undefined,
        head: std.atomic.Value(usize) = std.atomic.Value(usize).init(0), // consumer reads from here
        tail: std.atomic.Value(usize) = std.atomic.Value(usize).init(0), // producers write here
        slot_ready: [CAPACITY]std.atomic.Value(u8) = [_]std.atomic.Value(u8){std.atomic.Value(u8).init(0)} ** CAPACITY,

        /// Try to enqueue an item. Returns false if queue is full.
        pub fn push(self: *Self, item: T) bool {
            while (true) {
                const tail = self.tail.load(.monotonic);
                const head = self.head.load(.acquire);
                if (tail -% head >= CAPACITY) return false; // full

                // CAS to claim this slot
                if (self.tail.cmpxchgWeak(tail, tail +% 1, .release, .monotonic)) |_| {
                    // CAS failed, another producer got it — retry
                    continue;
                }

                // Won the slot — write data and mark ready
                self.buf[tail % CAPACITY] = item;
                self.slot_ready[tail % CAPACITY].store(1, .release);
                return true;
            }
        }

        /// Try to dequeue one item. Returns null if queue is empty.
        /// Only called by the single consumer (owning worker).
        pub fn pop(self: *Self) ?T {
            const head = self.head.load(.monotonic);
            const tail = self.tail.load(.acquire);
            if (head == tail) return null; // empty

            // Wait for the slot to be marked ready (producer might still be writing)
            if (self.slot_ready[head % CAPACITY].load(.acquire) != 1) return null;

            const item = self.buf[head % CAPACITY];
            self.slot_ready[head % CAPACITY].store(0, .release);
            self.head.store(head +% 1, .release);
            return item;
        }

        /// Drain all available items, calling callback for each.
        pub fn drain(self: *Self, callback: anytype) usize {
            var count: usize = 0;
            while (self.pop()) |item| {
                callback.handle(item);
                count += 1;
            }
            return count;
        }
    };
}

/// A cross-worker command request. Sent from the receiving worker to
/// the owning worker's MPSC queue.
pub const ShardRequest = struct {
    /// The command arguments (slices into the connection's accum buffer — valid
    /// because the sending worker holds the connection until response arrives).
    args: [8][]const u8,
    argc: usize,
    /// FD + connection info for the response path
    response_fd: i32,
    response_worker_id: u16,
    selected_db: u8,
    /// Response buffer pointer — owning worker writes response here
    response_buf: *std.array_list.Managed(u8),
    /// Signaled when the owning worker has written the response
    done: *std.atomic.Value(bool),
};

/// Queue capacity — must be power of 2.
pub const SHARD_QUEUE_CAP = 4096;

pub const ShardQueue = MpscQueue(ShardRequest, SHARD_QUEUE_CAP);

// ─── Tests ────────────────────────────────────────────────────────────

test "slot computation is deterministic" {
    const s1 = slotForKey("hello");
    const s2 = slotForKey("hello");
    try std.testing.expectEqual(s1, s2);
}

test "slot distributes across range" {
    const s1 = slotForKey("key:0");
    const s2 = slotForKey("key:99999");
    try std.testing.expect(s1 != s2);
    try std.testing.expect(s1 < TOTAL_SLOTS);
    try std.testing.expect(s2 < TOTAL_SLOTS);
}

test "worker routing" {
    const w1 = workerForKey("key:a", 4);
    const w2 = workerForKey("key:b", 4);
    try std.testing.expect(w1 < 4);
    try std.testing.expect(w2 < 4);
}

test "mpsc queue push pop" {
    var q = MpscQueue(u32, 8){};
    try std.testing.expect(q.push(42));
    try std.testing.expect(q.push(99));
    try std.testing.expectEqual(@as(?u32, 42), q.pop());
    try std.testing.expectEqual(@as(?u32, 99), q.pop());
    try std.testing.expectEqual(@as(?u32, null), q.pop());
}

test "mpsc queue full" {
    var q = MpscQueue(u32, 4){};
    try std.testing.expect(q.push(1));
    try std.testing.expect(q.push(2));
    try std.testing.expect(q.push(3));
    try std.testing.expect(q.push(4));
    try std.testing.expect(!q.push(5)); // full
    _ = q.pop();
    try std.testing.expect(q.push(5)); // space available
}
