//! modules/semantic_cache — deterministic semantic-cache primitives.
//!
//! BOUNDARY: storage and exact-match/threshold lookup primitives for cached
//! query→result entries keyed by vector similarity. The engine provides the
//! deterministic store, eviction, and lookup mechanism. Deciding cache policy,
//! similarity thresholds learned from feedback, or what is "semantically
//! equivalent" beyond a fixed metric belongs to the runtime.
//!
//! Stub: no implementation yet. Marks the semantic-cache boundary.
