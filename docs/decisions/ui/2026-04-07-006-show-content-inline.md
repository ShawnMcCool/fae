---
status: accepted
date: 2026-04-07
---
# Show content inline — don't hide it behind expand interactions

## Context and Problem Statement

The natural instinct when building data-heavy list pages is to show compact summary rows that the user clicks to expand. This hides the most interesting data behind an interaction barrier. When the item content IS the information users came for, forcing a click-to-reveal defeats the purpose of the page and makes pattern recognition impossible at a glance.

## Decision Outcome

Chosen option: "always show the key data inline in the list row; never hide it behind an expandable or click-to-reveal", because browsing is visual pattern recognition, not a series of deliberate reveal interactions.

**Rule:** If the content of each row is what the user came to see, display it directly in the row. Solve performance concerns (too many images, too much data) with batching and caching — not by hiding the content.

Examples:
- A hand history page should show the cards in each hand directly in the row, not "Hand #3 — click to expand"
- A deck list should show card images, not just card names
- A pick history should show the card that was picked inline

Expandable rows are appropriate for supplementary detail (audit logs, raw data, secondary metadata) — not for the primary content the page exists to display.

### Consequences

* Good, because users see the data they care about immediately
* Good, because browsing becomes visual pattern recognition rather than reading text
* Neutral, because pages load more content per view — mitigate with lazy loading and caching
