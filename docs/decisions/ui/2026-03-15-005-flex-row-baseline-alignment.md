---
status: accepted
date: 2026-03-15
---
# Flex rows with mixed-size text use baseline alignment

## Context and Problem Statement

Flex rows containing a label and a value in different font sizes visually misalign when using `align-items: center` — the text bottoms don't line up, creating a subtle but noticeable vertical offset.

## Decision Outcome

Chosen option: "align-items: baseline for text/text rows; align-items: center for text/control rows", because baseline aligns the typographic baseline of both items regardless of font size.

**Rules:**
- **Text/text rows** (label + value, both rendered as text): `align-items: baseline`
- **Text/control rows** (label + toggle, checkbox, button): `align-items: center` — controls are UI elements, not text, so baseline has no meaning

### Consequences

* Good, because text rows look aligned at any font-size combination
* Good, because the rule is simple: text pairs → baseline, control pairs → center
