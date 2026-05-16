---
status: accepted
date: 2026-03-03
---
# OTP process design: supervision, encapsulation, and durability

## Context and Problem Statement

OTP process design has three interrelated failure modes. First, flat supervision trees with default restart limits allow any three crashes in five seconds to terminate the entire application, and stale event handlers registered with dead PIDs fail silently after crash-restart. Second, when callers use `GenServer.call/2` directly, the message protocol leaks across module boundaries, coupling callers to implementation details. Third, stateful processes that hold in-memory queues, timers, or resource handles lose their work silently on crash-restart — invisible data loss that compounds over time.

## Decision Outcome

### Supervision structure

1. **Always use `Task.Supervisor.start_child` for async work.** Never use bare `Task.start` — unsupervised tasks are invisible when they crash and prevent graceful shutdown ordering.
2. **Every supervisor must set explicit `max_restarts` and `max_seconds`.** Never rely on Erlang defaults.
3. **Processes with restart dependencies must be grouped under a sub-supervisor** with the appropriate strategy (`:rest_for_one` for sequential dependencies, `:one_for_all` for mutual dependencies).
4. **Event handlers attached in `init/1` must detach stale handlers before re-attaching.** Call `:telemetry.detach/1` before `:telemetry.attach_many/4`.
5. **GenServers that subscribe to PubSub should use `handle_continue/2`** to run an immediate recovery check on restart, closing the gap where events may have been missed.
6. **The root supervisor remains `:one_for_one`** for independent subsystems. Sub-supervisors encode structural dependencies within subsystems.

### GenServer API encapsulation

Never call `GenServer.call/2` or `GenServer.cast/2` from outside the module that defines the GenServer. Expose a public function API on the module that wraps the call or cast internally. Callers use the module's public functions, not the GenServer protocol directly. This lets the process be refactored (renamed, split, replaced with ETS) without changing callers.

### Durable process design

Every stateful process must satisfy one of two properties:

- **Resumable:** reconnects to existing external state via a stable identifier and picks up where it left off.
- **Idempotent restart:** re-derives state from durable sources (database, filesystem, config) such that restarting from scratch produces the same eventual outcome.

Requirements:
1. **In-memory queues must have a durable backstop.** Re-derive from DB or filesystem on restart.
2. **External processes must be discoverable.** OS processes spawned by the backend must use stable, deterministic identifiers so the backend can reconnect after restart.
3. **Startup must reconcile.** Processes that watch for real-time events must run a reconciliation pass in `handle_continue/2` to detect anything that changed while they were down.
4. **Debounce buffers and deferred writes must flush on shutdown** in `terminate/2`. Requires `trap_exit`.

### Consequences

* Good, because a crash in one subsystem no longer risks tripping the root's restart limit for unrelated children
* Good, because event handlers survive crash-restart without manual intervention
* Good, because the GenServer's message format is an internal implementation detail — refactoring doesn't ripple to callers
* Good, because restart-related data loss becomes a design defect with a clear fix pattern
* Bad, because sub-supervisor modules add structural code; `terminate/2` flush requires `trap_exit` boilerplate
