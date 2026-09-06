//! engine/event_log — immutable observation log with idempotent ingestion.
//!
//! BOUNDARY: append-only, deterministic event log. Owns idempotency keys
//! (exact-replay dedup) and ordered, crash-consistent ingestion of immutable
//! observations. NOT similarity-based dedup, NOT "should this become memory?"
//! — those probabilistic decisions live in the memory runtime (vex-python).
//!
//! Stub: no implementation yet. Marks the ingestion boundary.
