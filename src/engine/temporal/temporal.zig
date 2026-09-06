//! engine/temporal — bitemporal validity and versioned state.
//!
//! BOUNDARY: deterministic valid-time + transaction-time tracking, supersession
//! chains, and snapshot-consistent reads "as of" a point in time. Pure mechanism:
//! given transitions, it maintains coherent temporal history. No importance,
//! decay curves, or forgetting policy — those are runtime/model concerns.
//!
//! Stub: no implementation yet. Establishes the temporal-state boundary.
