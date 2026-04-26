# Performance Optimization Plan

Goal: Bring all commands to +30% vs Redis (median of 15 runs, `redis-benchmark` P=50 c=16).

## Current State

| # | Command | Current Δ | Target | Gap |
|---|---|---|---|---|
| 1 | RPUSH UDS | -15% | +30% | 45% |
| 2 | INCR UDS | -4% | +30% | 34% |
| 3 | RPUSH TCP | +7% | +30% | 23% |
| 4 | INCR TCP | +8% | +30% | 22% |
| 5 | GET TCP | +9% | +30% | 21% |
| 6 | LPUSH UDS | +10% | +30% | 20% |
| 7 | RPOP TCP | +14% | +30% | 16% |
| 8 | SADD TCP | +21% | +30% | 9% |
| 9 | GET UDS | +22% | +30% | 8% |
| 10 | SET TCP | +23% | +30% | 7% |
| 11 | HSET TCP | +24% | +30% | 6% |
| 12 | HSET UDS | +24% | +30% | 6% |

## Task A: Pre-alloc outside lock for data types

**Fixes:** RPUSH, LPUSH, RPOP, SADD, HSET (7 commands)
**Priority:** Highest (biggest combined impact)

**Problem:** Currently the hot path for data type commands (RPUSH, LPUSH, HSET, SADD) allocates memory INSIDE the ds_lock write lock. Allocation is ~60ns, the lock serializes all workers waiting on the same stripe.

**Fix:** Copy/allocate argument values BEFORE taking the lock, then do only the pointer insert under lock. Same pattern as ConcurrentKV's `setPrealloc` which reduced SET lock hold time to ~20ns.

**Files:**
- `src/server/worker.zig` — Hot path for RPUSH/LPUSH/RPOP/SADD/HSET
- `src/engine/list.zig` — Add `rpushPrealloc`/`lpushPrealloc` that accept owned values
- `src/engine/set.zig` — Add `saddPrealloc` that accepts owned values
- `src/engine/hash.zig` — Add `hsetPrealloc` that accepts owned field+value

**Pattern:**
```
Before (lock held ~80ns):
  wrlock(stripe)
  alloc key copy        ← 60ns under lock
  insert into HashMap   ← 20ns under lock
  unlock(stripe)

After (lock held ~20ns):
  alloc key copy        ← 60ns, no lock
  wrlock(stripe)
  insert into HashMap   ← 20ns under lock
  unlock(stripe)
  free stale if any     ← outside lock
```

**Status:** [ ] Not started

---

## Task B: Atomic INCR in ConcurrentKV

**Fixes:** INCR TCP, INCR UDS (2 commands)
**Priority:** High (biggest single-command gap after RPUSH)

**Problem:** Current INCR hot path does:
1. ConcurrentKV GET (read lock → copy value → unlock)
2. Parse string to i64
3. Add delta
4. Format i64 to string
5. ConcurrentKV SET (write lock → insert → unlock)

Two lock acquisitions + string alloc/free + parse/format = ~200ns total.

**Fix:** Add `ConcurrentKV.incrBy(key, delta)` that does everything under ONE write lock:
1. Write lock stripe
2. Get entry pointer (no copy)
3. Parse i64 from value in-place
4. Add delta
5. Format back into a small stack buffer
6. Update value pointer (alloc new, free old)
7. Unlock

Single lock acquisition, no intermediate allocation.

**Files:**
- `src/engine/concurrent_kv.zig` — Add `incrBy(key: []const u8, delta: i64) -> i64`
- `src/server/worker.zig` — Hot path INCR uses `ckv.incrBy` instead of GET+parse+SET

**Status:** [ ] Not started

---

## Task C: Inline RESP for GET

**Fixes:** GET TCP, GET UDS (2 commands)
**Priority:** Medium (smaller gap but high-frequency command)

**Problem:** Current GET hot path (`getAndWriteBulk`) under read lock:
1. Read lock stripe
2. Look up key
3. Format `$len\r\n` header
4. Copy value bytes to write_buf
5. Append `\r\n`
6. Unlock

Steps 3-5 happen under the read lock. The `appendSlice` calls may trigger write_buf reallocation (~100ns), extending lock hold time.

**Fix:** Pre-size write_buf before taking the lock. Compute expected response size (`$` + digits + `\r\n` + value.len + `\r\n`), call `ensureTotalCapacity` on write_buf, THEN take the read lock and do the copy with guaranteed no-realloc.

**Files:**
- `src/engine/concurrent_kv.zig` — Modify `getAndWriteBulk` to accept pre-sized buffer hint
- `src/server/worker.zig` — Pre-size write_buf before GET

**Status:** [ ] Not started

---

## Verification

After each task, run:
```bash
docker compose -f docker-compose.compare.yml up --build -d
./tools/bench.sh 15
docker compose -f docker-compose.compare.yml down -v
```

Target: all 9 commands at +30% or better on both TCP and UDS.
