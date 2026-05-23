---
status: accepted
date: 2026-03-03
---
# Visual style conventions: color, badges, buttons, and semantic fills

## Context and Problem Statement

Without consistent rules, solid-fill semantic colors (success, warning, error) on badges, buttons, and alert surfaces produce visual noise where everything looks equally loud. Full-saturation fills wash out text against translucent or blurred surfaces, and dense lists become harder to scan when bordered/filled badges compete with the backdrop. The principle: visual volume should match semantic weight.

## Decision Outcome

### Semantic fill surfaces (alerts, badges, containers)

Use soft or opacity-tinted variants for all text-bearing semantic surfaces — never the solid variant alone:
- **Alerts and banners:** `alert alert-soft alert-warning` — never solid variant alone
- **Badges:** `badge badge-soft badge-success` — never solid fill alone
- **Container backgrounds:** opacity tints (`bg-warning/10`, `bg-error/20`) — never raw `bg-warning`
- **Foreground icons:** `text-success`, `text-warning`, `text-error` stay at full saturation — glyphs, not fills
- **Primary CTA button:** unaffected — it is an action surface, not a semantic status highlight

The soft variant produces a low-saturation fill that reads as healthy/attention/error without shouting, and adapts to dark and light themes.

### Badges

1. **Status/reason labels** (states, reasons, warnings): plain colored text using semantic colors (`text-error`, `text-warning`, `text-info`) — no badge border or fill.
2. **Metric badges** (scores, counts): solid fill is acceptable — data values benefit from stronger visual weight for scanning.
3. **Type badges** (classification labels): outline style with no color override — neutral classification, not status.

### Buttons

1. **Action buttons** (approve, search, select): soft style with semantic color (e.g., `btn-soft btn-success`).
2. **Destructive/dismiss actions:** ghost style — minimal visual weight for secondary or negative actions.
3. **Primary CTA:** solid fill, one per view, where a single dominant action is needed (e.g., form submit).

### No wrapping in badges and buttons

Values inside badges and buttons never word-wrap. This is enforced structurally
by a global rule in `assets/css/app.css` (`.badge, .btn { white-space: nowrap;
flex-wrap: nowrap }`), written outside `@layer` so it wins over daisyUI's
component styles. Content stays on one line; overly long content overflows rather
than breaking, so truncate at the call site (e.g. `truncate max-w-…`) when a value
can be unbounded. No per-call class discipline is required — the rule applies to
every badge and button automatically.

### Consequences

* Good, because visual volume matches semantic weight — healthy states recede; warnings and errors stand out by contrast
* Good, because the rule is uniform across all status surfaces and mechanically checkable (grep for solid semantic classes missing `-soft`)
* Good, because button text remains readable against translucent surfaces
* Bad, because soft fill and plain text labels are less visually distinct in isolation; mitigated by consistent use of semantic colors
