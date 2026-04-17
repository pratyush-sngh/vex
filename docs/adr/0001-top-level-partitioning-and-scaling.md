# ADR 0001: Top-Level Partitioning and Scaling Path

- **Status**: Accepted
- **Date**: 2026-04-15
- **Decision makers**: Vex maintainers

## Context

Vex currently runs as a single-node process serving both key-value and graph workloads through one RESP endpoint.  
Recent parallel-load testing showed pressure and instability risk when all command classes share the same mutable runtime path.

We want a design that:

1. works on one machine today,
2. preserves Redis-compatible client experience,
3. can evolve into horizontal scaling without major rewrites.

## Decision

Adopt a **top-level partitioned architecture** with three logical components:

1. **Router**: protocol termination and command routing.
2. **KV domain**: owns key-value state and KV persistence.
3. **Graph domain**: owns graph state and graph persistence.

Initial deployment may still be one host, but the runtime boundaries are treated as independent domains.

## Scope of this ADR

This ADR defines the architectural direction and boundaries only.  
It does **not** claim that cluster partitioning, replication, or rebalance are implemented yet.

## Consequences

### Positive

- Clear ownership boundaries (KV vs graph) reduce coupling.
- Independent scaling path for router, KV, and graph.
- Enables future deployment where router/KV/graph can run on separate machines.
- Provides an explicit base for read replicas and horizontal scaling later.

### Trade-offs

- Adds routing and orchestration complexity versus a monolith.
- Requires clear behavior for cross-domain admin commands (`INFO`, `SAVE`, etc.).
- Future cluster features need control-plane metadata and versioning.

## Compatibility Position

- Vex remains Redis-protocol compatible for supported commands.
- Multi-db Redis semantics (`SELECT`, 16 logical DBs) are currently out of scope and remain unsupported.

## Future Work (planned, not yet implemented)

1. Slot/partition ownership map and epoch-based routing config.
2. Replication roles (leader/follower) for domain partitions.
3. Rebalance workflow for moving partition ownership.
4. Read routing policy for replicas.
5. Failure-domain aware orchestration for cross-domain commands.

## Rollout Strategy

1. Keep one-machine deployment but enforce logical boundaries.
2. Move router/KV/graph into independently deployable units.
3. Add control-plane primitives before enabling multi-node write scaling.

