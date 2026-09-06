pub const VERSION = @import("build_options").version;

pub const kv = @import("engine/kv/kv.zig");
pub const graph = @import("engine/graph/graph.zig");
pub const query = @import("query/query.zig");
pub const ch = @import("engine/graph/ch.zig");
pub const snapshot = @import("storage/snapshot.zig");
pub const aof = @import("storage/aof.zig");

// Data-structure stores, surfaced for benches that route through the `app`
// module (see build.zig) so they can reach engine internals without tripping
// Zig's "import outside module path" rule.
pub const list = @import("engine/types/list.zig");
pub const set = @import("engine/types/set.zig");
pub const sorted_set = @import("engine/types/sorted_set.zig");
pub const hash = @import("engine/types/hash.zig");
