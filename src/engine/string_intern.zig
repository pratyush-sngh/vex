const std = @import("std");
const Allocator = std.mem.Allocator;

/// Bitmask type for up to 64 interned types.
pub const TypeMask = u64;
pub const MAX_INTERNED: u16 = 64;
/// Property keys can have many more unique names than node/edge types.
pub const MAX_PROPERTY_KEYS: u16 = 4096;

/// Deduplicating string interner. Assigns each unique string a dense u16 ID
/// (0..N-1). IDs double as bit positions in a TypeMask for fast bitmask
/// filtering during graph traversals.
pub const StringIntern = struct {
    strings: std.array_list.Managed([]const u8),
    lookup: std.StringHashMap(u16),
    allocator: Allocator,
    max_capacity: u16,

    pub fn init(allocator: Allocator) StringIntern {
        return initWithCapacity(allocator, MAX_INTERNED);
    }

    pub fn initWithCapacity(allocator: Allocator, max_cap: u16) StringIntern {
        return .{
            .strings = std.array_list.Managed([]const u8).init(allocator),
            .lookup = std.StringHashMap(u16).init(allocator),
            .allocator = allocator,
            .max_capacity = max_cap,
        };
    }

    pub fn deinit(self: *StringIntern) void {
        for (self.strings.items) |s| {
            self.allocator.free(s);
        }
        self.strings.deinit();
        self.lookup.deinit();
    }

    /// Intern a string, returning its dense u16 ID. If already interned,
    /// returns the existing ID. Errors if capacity is exceeded.
    pub fn intern(self: *StringIntern, s: []const u8) !u16 {
        if (self.lookup.get(s)) |id| return id;

        const next_id: u16 = @intCast(self.strings.items.len);
        if (next_id >= self.max_capacity) return error.TooManyInternedStrings;

        const owned = try self.allocator.dupe(u8, s);
        errdefer self.allocator.free(owned);

        try self.strings.append(owned);
        errdefer _ = self.strings.pop();

        try self.lookup.put(owned, next_id);
        return next_id;
    }

    /// Look up an ID without interning. Returns null if not found.
    pub fn find(self: *const StringIntern, s: []const u8) ?u16 {
        return self.lookup.get(s);
    }

    /// Resolve an ID back to its string.
    pub fn resolve(self: *const StringIntern, id: u16) []const u8 {
        return self.strings.items[id];
    }

    /// Return the bitmask for a given interned ID.
    pub fn mask(id: u16) TypeMask {
        return @as(TypeMask, 1) << @intCast(id);
    }

    /// Number of interned strings.
    pub fn count(self: *const StringIntern) u16 {
        return @intCast(self.strings.items.len);
    }
};

// ─── Tests ────────────────────────────────────────────────────────────

test "intern and resolve" {
    var si = StringIntern.init(std.testing.allocator);
    defer si.deinit();

    const id0 = try si.intern("service");
    const id1 = try si.intern("database");
    const id2 = try si.intern("service"); // duplicate

    try std.testing.expectEqual(@as(u16, 0), id0);
    try std.testing.expectEqual(@as(u16, 1), id1);
    try std.testing.expectEqual(id0, id2); // same ID for duplicate

    try std.testing.expectEqualStrings("service", si.resolve(0));
    try std.testing.expectEqualStrings("database", si.resolve(1));
    try std.testing.expectEqual(@as(u16, 2), si.count());
}

test "find returns null for unknown" {
    var si = StringIntern.init(std.testing.allocator);
    defer si.deinit();

    _ = try si.intern("known");
    try std.testing.expect(si.find("known") != null);
    try std.testing.expect(si.find("unknown") == null);
}

test "mask bit positions" {
    try std.testing.expectEqual(@as(TypeMask, 1), StringIntern.mask(0));
    try std.testing.expectEqual(@as(TypeMask, 2), StringIntern.mask(1));
    try std.testing.expectEqual(@as(TypeMask, 1 << 63), StringIntern.mask(63));
}

test "max interned limit" {
    var si = StringIntern.init(std.testing.allocator);
    defer si.deinit();

    var buf: [8]u8 = undefined;
    for (0..64) |i| {
        const s = std.fmt.bufPrint(&buf, "t{d}", .{i}) catch unreachable;
        _ = try si.intern(s);
    }
    try std.testing.expectEqual(@as(u16, 64), si.count());

    const result = si.intern("one_too_many");
    try std.testing.expect(result == error.TooManyInternedStrings);
}
