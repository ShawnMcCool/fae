---
status: accepted
date: 2026-04-02
---
# Extract LiveView behavior into tested pure functions

## Context and Problem Statement

LiveView components accumulate conditional logic — state classification, label computation, variant selection, data transformation — inlined in templates and private component functions. This logic is untestable without rendering HTML, which is fragile and couples tests to DOM structure rather than behavior. Logic bugs in inlined functions are invisible to the test suite until they manifest as rendering errors.

## Decision Outcome

Chosen option: "mandatory extraction of non-trivial LiveView logic into public pure functions with unit tests", because it catches logic bugs with fast async tests and forces clear boundaries between data logic and presentation.

**Rules:**
1. **LiveViews are thin wiring.** Any logic beyond trivial assignment — an `if`, `case`, `cond`, or `Enum` pipeline on domain data — must be extracted into a public function.
2. **Extract into the same module or a dedicated helper.** Small helpers (1–3 functions) can live as public functions on the LiveView module. Larger clusters belong in a dedicated module.
3. **Extracted functions must have unit tests.** Use `async: true` — no database, no rendering. Test inputs and outputs directly.
4. **Never assert on rendered HTML.** No `render_component`, no `=~` on markup. LiveView integration tests (mount, patch, event handling) are acceptable — they test navigation and data flow, not DOM structure.

Examples of logic that must be extracted: state classification, label computation, icon/variant selection, data transformation, conditional display predicates.

### Consequences

* Good, because logic bugs are caught by fast async unit tests
* Good, because extracted functions are reusable across LiveViews and components
* Good, because schema refactors break tests at the function level, not at the rendering level
* Bad, because introduces more public functions and potentially more modules — each is small and focused
