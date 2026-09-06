//! modules/memory — typed memory records and transition validation.
//!
//! BOUNDARY: the deterministic memory state model — typed observations, claims,
//! beliefs, procedures, outcomes, and state; evidence/provenance and revision
//! relationships; validation that a requested transition is well-formed and
//! coherent. This is the in-engine half of the "Vex stores coherent state"
//! boundary.
//!
//! It MUST NOT contain: extraction, entity resolution, contradiction detection,
//! consolidation, importance/trust scoring, or any LLM/model-driven logic.
//! Those belong to the memory runtime (vex-python / future vex-memory).
//!
//! Stub: no implementation yet. Establishes the engine-side memory boundary.
