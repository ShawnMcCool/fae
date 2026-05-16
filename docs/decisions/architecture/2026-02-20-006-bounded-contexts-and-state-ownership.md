---
status: accepted
date: 2026-02-20
---
# Bounded contexts, single-writer ownership, and mutation broadcast

## Context and Problem Statement

Applications tend to reach into each other's internals without clear boundaries, creating tight coupling where a change in one subsystem requires understanding several others. Without a designated owner for shared storage, write conflicts and unclear cleanup responsibility follow. Without a consistent broadcast contract, some mutations silently fail to notify subscribers, leaving them stale.

## Decision Outcome

### Bounded contexts with message-passing

Contexts never call into another context's internal modules. All cross-context interaction uses a message-passing mechanism (PubSub, event bus, message queue). Data-layer hooks and callbacks are intrinsic only — they must not orchestrate external integrations, call APIs, or cross context boundaries. Orchestration processes (pipelines, coordinators) may actively call into services and hand results to domain contexts, but domain resources never trigger orchestration behavior through state changes.

### Single writer for shared state

Exactly one component writes to each shared resource (database table, filesystem directory, cache). Other components read from it but never create, modify, or delete. Non-owning components send commands, not mutations — the owning component decides what state changes result. The owning component is responsible for integrity, cleanup, and orphan detection. The write boundary should be documented explicitly: "component X owns table/directory Y."

### Mutation broadcast contract

Every operation that creates, updates, or destroys records broadcasts a single change event carrying the affected IDs — e.g., `{:records_changed, ids}`. IDs must be collected **before** deletion (records are gone afterward). Subscribers resolve IDs into updated/removed state by querying current data — the broadcaster does not distinguish create from update from delete. Bulk operations must check error counts; silent failures stall subscribers.

### Consequences

* Good, because modifying one context does not require analyzing blast radius on unrelated contexts
* Good, because a single-writer model eliminates write conflicts and makes one component the authoritative source
* Good, because one event type covers all mutation kinds — no separate create/update/destroy events to maintain
* Good, because contexts can be tested in isolation with message stubs
* Bad, because messages are fire-and-forget — debugging cross-context flows requires correlating events across subscribers
* Bad, because all write paths must go through the owner, adding a coordination step for operations that could theoretically be done locally
* Bad, because subscribers must query the database on every notification — cannot optimize based on mutation type
