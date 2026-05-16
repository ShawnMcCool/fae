---
status: accepted
date: 2026-03-01
---
# Test environment must be structurally isolated from real state

## Context and Problem Statement

When tests inherit real configuration — user directories, database connections, external service credentials — destructive test operations (clearing databases, deleting files, resetting state) can affect real data. Relying on per-test overrides is fragile: a missing override in one test silently operates on real state.

## Decision Outcome

Chosen option: "defense-in-depth isolation via structural configuration", because it makes real-state access impossible at multiple independent layers rather than relying on per-test discipline.

**Layers:**
1. **Environment-gated real config.** Real configuration (watch directories, external paths, credentials) is guarded by `config_env() != :test` in runtime config — the test environment never loads them.
2. **Test config overrides.** `config/test.exs` sets all external paths to empty or temp values, so any code iterating real paths is a no-op.
3. **Per-test temp directories.** Tests that need filesystem access create isolated temp directories programmatically and clean them up after.

Isolation must be structural (compile-time config) rather than behavioral (per-test discipline). If a developer forgets to override a value in a single test, the structural layer must prevent real-state access anyway.

### Consequences

* Good, because no test can touch real user state, even if the test author forgets to override config
* Good, because the fix is structural — adding new config values that need test isolation is a deliberate act
* Bad, because test config must be updated whenever new real-world config values are added
