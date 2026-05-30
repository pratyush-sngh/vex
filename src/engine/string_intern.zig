const std = @import("std");
const Allocator = std.mem.Allocator;

/// Bitmask type for up to 64 interned types.
pub const TypeMask = u64;
pub const MAX_INTERNED: u16 = 64;
/// Property keys and type names can have many unique names.
/// u16 max (65535) effectively uncapped for practical use.
pub const MAX_PROPERTY_KEYS: u16 = std.math.maxInt(u16);

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

