---
status: accepted
date: 2026-05-16
---
# Desktop application with a real-time web UI

## Context and Problem Statement

A personal-machine tooling daemon needs a UI. The convenient and mature option is a web UI in the local browser. The trap is to then *think of the application as a web application* and inherit its assumptions: stateless request/response handling, controllers as the primary entry points, the database as the source of truth, the UI as the principal driver of behavior. These assumptions are wrong for a desktop daemon, which is fundamentally a long-running stateful supervised process that happens to be observable via a browser.

## Decision Outcome

Chosen option: "treat the running supervised process as the source of truth, the browser as a real-time viewer, and LiveView + PubSub as the entire UI mechanism", because it aligns the architecture with what the application actually is and eliminates accidental request/response complexity.

**Principles:**

1. **The application is persistent supervised state.** Domain processes (GenServers, sub-supervisors) hold live state. The database is durable persistence for that state, not the source of truth. The running process is.
2. **The web UI is a thin real-time viewer.** Every page subscribes to the PubSub topics relevant to what it displays. There is no "refresh to see changes" — a state change anywhere reaches every observing LiveView within a frame.
3. **No request/response controllers in the application surface.** The only HTTP routes are LiveView mounts and incidental concerns (file downloads, health endpoints). User-visible behavior is LiveView, not controller actions.
4. **Tools are sub-supervisor trees.** Each tool the application offers is a self-contained subtree under the root supervisor: its own processes, schemas, PubSub topics, and LiveView pages. Adding a tool means adding a supervised subtree, not wiring up new web routes.

### Consequences

* Good, because the architecture matches what the application is — supervised state with an observation surface — eliminating impedance mismatch
* Good, because the UI is always live; the entire class of stale-data bugs caused by request/response thinking does not arise
* Good, because every new tool follows a single repeatable shape: supervisor subtree + PubSub topic + LiveView page
* Good, because the system can be inspected and operated directly through `:observer` or `iex --remsh` — the BEAM *is* the runtime, not just the process hosting it
* Bad, because developers familiar with web frameworks must unlearn request/response habits when adding features here
* Bad, because every data-producing code path must remember to broadcast on the appropriate PubSub topic; missed broadcasts leave LiveViews stale
