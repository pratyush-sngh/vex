//! engine/persistence — WAL, snapshotting, and recovery semantics.
//!
//! BOUNDARY: deterministic durability and crash consistency. This is the logical
//! persistence layer (write-ahead log ordering, snapshot consistency, recovery).
//!
//! NOTE: today the concrete implementations live in src/storage/ (aof.zig,
//! snapshot.zig) over the low-level src/storage/atomic_io.zig substrate. This
//! module marks the intended home; aof.zig/snapshot.zig migrate here when the
//! WAL/recovery logic is separated from the raw IO substrate (which stays in
//! src/storage/). Left as a stub to avoid a high-churn move before that split
//! earns its keep.
