---
status: accepted
date: 2026-03-03
---
# File path display convention

## Context and Problem Statement

File paths displayed in the UI were truncated from the end (CSS `text-overflow: ellipsis`), hiding the most useful part — the filename. Tooltip behavior was inconsistent across pages: some showed just the filename, some showed the full path, some had no tooltip at all.

## Decision Outcome

Chosen option: "start-truncation with full-path tooltip", because the filename is the most identifying part of a path and must always be visible, while the full path should be available on hover.

All file paths in the UI must follow these rules:

1. **Tooltip (`title`):** Always the complete, untruncated path.
2. **Visible text:** A context-relative path (or full path if no shorter form applies).
3. **Truncation direction:** From the start of the string — the directory prefix is elided, the filename stays visible.
4. **CSS technique:** Use `direction: rtl` with `unicode-bidi: plaintext` to place the ellipsis at the start instead of the end.

### Consequences

* Good, because the filename — the most useful identifier — is always visible
* Good, because hovering any path reveals the complete location
* Good, because the convention is consistent across all pages
* Bad, because `direction: rtl` can cause minor visual quirks with certain punctuation; mitigated by `unicode-bidi: plaintext`
