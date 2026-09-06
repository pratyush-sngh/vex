//! engine/lexical — lexical / hybrid (BM25-style) index over stored records.
//!
//! BOUNDARY: deterministic indexing and exact lexical retrieval only. Tokenisation,
//! posting lists, and scoring are mechanical and reproducible. No LLM reranking,
//! no learned weights — those belong to the memory runtime (vex-python).
//!
//! Stub: no implementation yet. Establishes the module boundary so lexical
//! retrieval lands here rather than leaking into query/ or vector/.
