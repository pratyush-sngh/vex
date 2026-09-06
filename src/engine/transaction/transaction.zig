//! engine/transaction — atomic memory transitions and namespace-level MVCC.
//!
//! BOUNDARY: deterministic transaction engine. Owns atomicity, isolation, and
//! the commit/abort of memory-state transitions (supersede, correct, retract,
//! verify, merge). It ENFORCES transitions; it never DECIDES which transition
//! to apply — that decision is the memory runtime's (vex-python).
//!
//! Stub: no implementation yet. Marks the boundary per the engine/runtime split.
