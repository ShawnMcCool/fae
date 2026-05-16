---
status: accepted
date: 2026-02-27
---
# Code quality standards: naming, testing, and zero-tolerance for decay

## Context and Problem Statement

Systems that process data silently in the background produce invisible bugs — a malformed record, a dropped event, or a misparsed value causes no visible error. Meanwhile, inconsistent naming and ad-hoc module organization accumulate cognitive debt. These failure modes share a common fix: enforced standards applied consistently from day one.

## Decision Outcome

### Naming

**Variables:** Never abbreviate. `file` not `wf`, `entity` not `ent`, `result` not `res`, `index` not `idx`. Name the variable what the value *is*, not what type it came from.

**Modules:** Name for domain purpose, not design pattern. `ExtractMetadata` not `MetadataProcessor`; `PeriodicallyRefreshData` not `RefreshWorker`; `IdentifyDomainEvents` not `Translator`. Name integrations for the external system: `Tmdb` not `TmdbImporter`. If the name only makes sense to someone who knows the pattern, rename it.

**Module structure:** Organize by domain context, not technical role. Each domain context has a clear public API; internal modules are implementation details. New functionality belongs in the domain it serves — not in a catch-all `utils` or `helpers` module.

**Readability:** Prefer explicit, boring code over clever abstractions. Functions and modules should be understandable from their names alone.

### Testing

**Test-first:** Write tests before implementation for all new features and bug fixes. Tests are the executable specification — if you can't write the test, the requirements aren't clear enough.

**Spec-first contracts:** Every contract between system components (especially backend/frontend, or between services) must be documented in a spec file before implementation ships. Both sides code against the same document. Wire format or data contract changes must update both the spec and the corresponding tests.

**Test through the public interface:** Never promote private functions to public for testability. Instead, extract complex logic into its own module with a proper public API. Test observable behavior by calling the public function with inputs that exercise the private path. If a code path can't be reached through the public API, question whether it should exist.

**Regression tests are append-only:** Tests may only be added, never removed or weakened. Use real inputs observed in the wild — never synthetic or invented inputs. Assertions must not be loosened to accommodate a code change (no changing exact matches to substring matches, no loosening numeric bounds). If a code change causes a test to fail, fix the code. The test suite is a monotonically growing record of real failure modes.

### Zero warnings

Application code and tests must compile and run with zero warnings — unused variables, unused imports, and log output indicating misconfiguration. Enforce warnings-as-errors in CI and pre-commit checks.

### Consequences

* Good, because test-first and append-only regression tests catch processing bugs before they silently corrupt data
* Good, because spec-first prevents component contract drift — both sides code against the same document
* Good, because zero warnings eliminates dead code accumulation and catches misconfigured stubs
* Good, because unabbreviated names and domain-driven structure let new contributors navigate without a glossary
* Bad, because test-first adds up-front time; zero warnings can slow exploratory work
* Bad, because longer names require more horizontal space — acceptable trade-off for clarity
