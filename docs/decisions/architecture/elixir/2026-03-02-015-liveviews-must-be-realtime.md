---
status: accepted
date: 2026-03-02
---
# All LiveViews must update in real time via PubSub

## Context and Problem Statement

A LiveView that requires manual page reload to show new data defeats the purpose of a live interface. When some views subscribe to PubSub and others don't, users have inconsistent expectations — some pages update automatically, others silently go stale. During batch operations, naive PubSub handling can also trigger N database queries for N events when one query after a quiet period would suffice.

## Decision Outcome

Chosen option: "every LiveView subscribes to PubSub, debounces rapid updates, and re-fetches with current filters", because consistency eliminates special cases and debouncing prevents query storms.

**Pattern:**
1. **Subscribe in mount** — inside `connected?(socket)`, subscribe to the relevant PubSub topic(s).
2. **Debounce rapid updates** — when a message arrives, cancel any pending reload timer and schedule a new one (typically 300–500ms). Multiple events during a batch collapse into one database query after a quiet period.
3. **Re-fetch with current assigns** — the reload handler must pass the current filter state when fetching data. Never call a bare `list_*` without the current active filters.

Any code path that mutates data visible in a LiveView must broadcast to the appropriate PubSub topic. The broadcaster does not need to know which LiveViews are listening.

### Consequences

* Good, because users see new data immediately without page reload
* Good, because the pattern is consistent across all LiveViews — no special cases
* Good, because debouncing prevents unnecessary database queries during batch processing
* Bad, because each new data-producing code path must remember to broadcast
