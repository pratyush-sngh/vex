# Vex Makefile — convenience wrappers around zig build + release housekeeping.
# Most day-to-day work goes through `zig build` directly; this file exists
# so release bumps and CI checks have a single canonical entry point.

# ── Canonical version ─────────────────────────────────────────────────
# Single source of truth lives in build.zig.zon; build.zig propagates it
# to the binary via a build option. The Makefile reads the same field so
# `sync-docs` can rewrite human-facing prose to match a release bump.
VERSION := $(shell awk -F'"' '/^[[:space:]]*\.version[[:space:]]*=/{print $$2; exit}' build.zig.zon)

# Docs that carry a "current example" version string that must track each
# release. Each one is rewritten by `sync-docs` and checked by `check-docs`.
# CHANGELOG-style mentions (e.g. README.md "### v0.7.1") are intentionally
# excluded — they are historical records, not current pointers.
VERSIONED_DOCS := docs/deployment.md docs/observability.md

.PHONY: help version sync-docs check-docs check-docs-strict \
        test test-release-safe test-tsan \
        stress stress-quick stress-prod-shape

# Default Zig binary; override if your toolchain lives elsewhere.
ZIG ?= zig

help:
	@echo "Vex Makefile targets:"
	@echo ""
	@echo "Release housekeeping:"
	@echo "  make version             — print the canonical version from build.zig.zon"
	@echo "  make sync-docs           — rewrite \"current example\" version mentions in $(VERSIONED_DOCS)"
	@echo "  make check-docs          — exit 1 if any versioned doc disagrees with build.zig.zon"
	@echo "  make check-docs-strict   — same as check-docs, plus warns on other 0.x.y strings in those files"
	@echo ""
	@echo "Test profiles:"
	@echo "  make test                — Debug unit tests (fastest; default Zig pointer/leak checks)"
	@echo "  make test-release-safe   — ReleaseSafe unit tests (keeps Zig safety checks; close to prod perf)"
	@echo "  make test-tsan           — ThreadSanitizer unit tests (catches data races; slow)"
	@echo ""
	@echo "Stress / chaos:"
	@echo "  make stress              — full chaos suite (the production gate before tagging)"
	@echo "  make stress-quick        — the cheap regressions only (~3 min total)"
	@echo "  make stress-prod-shape   — production-shape stress alone (longest individual run)"
	@echo ""
	@echo "Build/run/bench directly: 'zig build' (see build.zig for all steps)."

version:
	@echo "$(VERSION)"

# In-place rewrite. Touches:
#   - "ghcr.io/pratyush-sngh/vex:X.Y.Z" specific-tag lines
#   - "vex_version:X.Y.Z" INFO-output examples
#   - "vex vX.Y.Z ready" startup-log examples
# These are the only "current example" patterns documented today. Add new
# patterns as new doc examples are written; keep the deletion side small.
sync-docs:
	@if [ -z "$(VERSION)" ]; then \
		echo "ERR: could not read .version from build.zig.zon"; exit 1; \
	fi
	@for f in $(VERSIONED_DOCS); do \
		sed -i.bak -E \
			-e 's@(ghcr\.io/pratyush-sngh/vex:)[0-9]+\.[0-9]+\.[0-9]+@\1$(VERSION)@g' \
			-e 's@(vex_version:)[0-9]+\.[0-9]+\.[0-9]+@\1$(VERSION)@g' \
			-e 's@(vex v)[0-9]+\.[0-9]+\.[0-9]+( ready)@\1$(VERSION)\2@g' \
			"$$f" && rm "$$f.bak"; \
	done
	@echo "synced $(VERSIONED_DOCS) → $(VERSION)"

# Read-only check. Suitable for CI: exits 1 if any tracked doc references
# a version that is not the canonical one.
check-docs:
	@if [ -z "$(VERSION)" ]; then \
		echo "ERR: could not read .version from build.zig.zon"; exit 1; \
	fi
	@stale=0; \
	for f in $(VERSIONED_DOCS); do \
		bad=$$(grep -nE \
			-e "ghcr\.io/pratyush-sngh/vex:[0-9]+\.[0-9]+\.[0-9]+" \
			-e "vex_version:[0-9]+\.[0-9]+\.[0-9]+" \
			-e "vex v[0-9]+\.[0-9]+\.[0-9]+ ready" "$$f" \
			| grep -vE "(:$(VERSION)|v$(VERSION) )" || true); \
		if [ -n "$$bad" ]; then \
			echo "$$f: stale version mentions (canonical: $(VERSION)):"; \
			echo "$$bad" | sed 's/^/    /'; \
			stale=1; \
		fi; \
	done; \
	if [ $$stale -eq 1 ]; then \
		echo "run 'make sync-docs' to fix"; \
		exit 1; \
	fi; \
	echo "docs in sync with $(VERSION)"

# Same as check-docs, but ALSO flags any other 0.x.y in the versioned
# docs. Use when adding new doc content — catches embedded version
# strings that the regex set above doesn't know about yet so they can
# be added to sync-docs.
check-docs-strict: check-docs
	@for f in $(VERSIONED_DOCS); do \
		others=$$(grep -nE "[0-9]+\.[0-9]+\.[0-9]+" "$$f" \
			| grep -vE "[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+" \
			| grep -vE "(ghcr\.io/pratyush-sngh/vex:[0-9]+|vex_version:[0-9]+|vex v[0-9]+)" \
			| grep -vE "minimum_zig_version|zig 0\." || true); \
		if [ -n "$$others" ]; then \
			echo "WARN: $$f has other version-like strings not covered by sync-docs:"; \
			echo "$$others" | sed 's/^/    /'; \
		fi; \
	done

# ── Test profiles ─────────────────────────────────────────────────────
# Each profile is a different sanitizer / optimization mix. The chaos
# suite (below) builds the binary once at the requested optimization
# level and exercises it under load — sanitizers there catch bugs the
# unit tests can't reach because they need real concurrency.

test:
	$(ZIG) build test --summary all

# ReleaseSafe keeps Zig's bounds / overflow / null-deref panics. Close
# to ReleaseFast perf. If the production crash was a slice OOB, this is
# where it shows up cleanly (file:line panic) instead of as glibc's
# late-detection realloc abort.
test-release-safe:
	$(ZIG) build test -Doptimize=ReleaseSafe --summary all

# ThreadSanitizer instruments every load/store with happens-before
# tracking. Catches data races between Zig threads (e.g. hot-path
# read of HashMap bucket vs concurrent rehash) by reporting on the
# OFFENDING access, not the eventual corruption. ~5-10x slower; use
# for diagnosis, not steady-state CI.
test-tsan:
	$(ZIG) build test -Dsanitize-thread=true --summary all

# ── Stress / chaos suite ──────────────────────────────────────────────
# A chaos script PASS means vex stayed alive under a specific load
# shape. Failure surfaces as the script printing FAIL + the relevant
# vex.log tail; logs are preserved under /tmp/vex-chaos-*.

# Cheap regressions (each ≤ ~60s). Suitable for PR-gate CI.
QUICK_CHAOS = \
    tests/chaos/pubsub-cross-worker-tls.sh \
    tests/chaos/pipelined-large-response.sh \
    tests/chaos/set-large-then-small.sh \
    tests/chaos/multi-with-graph.sh \
    tests/chaos/chbuild-storm.sh \
    tests/chaos/self-publish-burst.sh \
    tests/chaos/hotpath-rehash.sh \
    tests/chaos/bgrewriteaof-availability.sh \
    tests/chaos/bgsave-snapshot.sh

# Production-shape stress. Long-running (5+ min) — the canary that
# runs before tagging. Catches load-shape-specific bugs (the kind that
# blew up after 0.7.2 → 0.7.3).
PROD_CHAOS = tests/chaos/production-shape.sh

stress-quick: build-check
	@set -e; \
	failed=0; \
	for s in $(QUICK_CHAOS); do \
		echo "═══ $$s ═══"; \
		if ! "$$s"; then failed=$$((failed+1)); fi; \
	done; \
	if [ $$failed -gt 0 ]; then echo ""; echo "FAIL: $$failed quick chaos scripts failed"; exit 1; fi; \
	echo ""; echo "All quick chaos scripts PASS"

stress-prod-shape: build-check
	@set -e; \
	for s in $(PROD_CHAOS); do \
		echo "═══ $$s ═══"; "$$s"; \
	done

stress: stress-quick stress-prod-shape
	@echo ""
	@echo "Full chaos suite PASS"

.PHONY: build-check
build-check:
	@if [ ! -x ./zig-out/bin/vex ]; then \
		echo "zig-out/bin/vex missing — building with 'zig build'..."; \
		$(ZIG) build; \
	fi
