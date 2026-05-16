---
status: accepted
date: 2026-05-16
---
# Self-update via public GitHub Releases (unauthenticated)

## Context and Problem Statement

Fae is a desktop daemon. Users install it once and expect it to keep itself reasonably current — manually rebuilding from source on every patch is friction this project exists to avoid. The application needs a way to detect new releases, fetch them, verify them, and replace itself.

Two upstream choices were considered and made (see [[027-desktop-application-with-realtime-web-ui]] and the conversation that produced this commit set):

- **Release host:** `ShawnMcCool/fae` public GitHub Releases. Public so the in-app updater can call the GitHub API and download tarballs without managing any auth credentials on the client.
- **Publish flow:** manual via `bin/release`, which builds, pairs the tarball with a `SHA256SUMS` file, and calls `gh release create`. No CI for now; can be added later without changing the client.

The remaining design question is the trust model: what's the security posture of an in-app updater that pulls and applies bytes from a third-party service?

## Decision Outcome

Chosen option: **anchor trust to GitHub's TLS + account control, plus client-side SHA256 verification of the artifact against the sibling `SHA256SUMS` file, plus strict tag validation. No GPG/Sigstore signing in v1; tracked as a follow-up if the threat model changes.**

### What's defended against

- **Network man-in-the-middle on the download:** TLS verification is always on (no `:verify_peer` toggle in the code path). A MITM cannot serve a swapped tarball without breaking GitHub's certificate chain.
- **Tag-injection / shell-injection in derived URLs and filesystem paths:** every `tag_name` is validated against a strict semver regex (`v\d+\.\d+\.\d+(-[A-Za-z0-9\.]+)?`) before being interpolated anywhere. Tags like `v1.0.0;rm -rf /` are rejected at parse time.
- **API field tampering:** the download URL is built from a **fixed template** (`https://github.com/ShawnMcCool/fae/releases/download/{tag}/{filename}`), never from the API's `browser_download_url`. A compromised API response cannot redirect the client to an attacker-controlled host. The `html_url` shown in the UI is similarly rewritten to the canonical repo path if it doesn't already start with one.
- **Modified tarball post-publish:** `SHA256SUMS` is fetched alongside the tarball and the downloaded bytes must hash to the entry that names the tarball file (looked up by filename, not by index). Mismatch aborts and deletes any partial file.
- **Tarball extraction abuse:** entries with absolute paths, `..` traversal, symlinks, or non-regular types are rejected before extraction. Cumulative declared size is capped at 1GB. Staging dir is mode 0700.
- **Installer hijack via shell expansion:** the staged installer path is passed as a positional argv entry, never interpolated into the `sh -c` command string. The handoff runs under `env -i` with a minimal `PATH` and only the env vars `systemctl --user` actually needs.

### What's NOT defended against

- **Compromised GitHub account / personal access token:** an attacker who can push a tag to `ShawnMcCool/fae` and upload a malicious tarball + matching `SHA256SUMS` wins. The client cannot tell whether the legitimate maintainer or an attacker produced the release. This is the same threat model as `apt` against a compromised package signer, with the difference that Fae has no signing layer.
- **Compromised GitHub infrastructure:** if GitHub itself serves a malicious tarball with a forged `SHA256SUMS` under the legitimate URL, the client accepts it. Out of scope for v1.
- **Local same-UID attacker:** a process running as the user can read the install dir, the staging dir, the auth token (none in v1 — see [[028-no-application-layer-auth-on-single-user-desktop]]), and replace files directly. Application-layer mitigation doesn't change this; the OS-level trust boundary does.

### Reversal triggers

Revisit this decision (most likely toward Sigstore or minisign signing) if any become true:

- Fae's user base grows beyond "the person who maintains it" and the maintainer's GitHub account compromise becomes a higher-impact event.
- A second maintainer or CI signing pipeline is added — at which point the cost of release signing drops to "configure CI once."
- A reproducible-build chain becomes available for Phoenix/Elixir releases, making signature verification meaningful beyond identity attestation.

## Consequences

* Good, because the implementation is small and entirely on the BEAM — no client-side keyring, no GPG dependency, no Sigstore client.
* Good, because the publish flow is one command (`bin/release`), one external service (GitHub), one credential (the maintainer's gh CLI auth). Setup cost is near zero.
* Good, because the trust boundary is explicit and documented — the next decision can be made with eyes open if signing ever becomes warranted.
* Bad, because a compromised GitHub account can ship malicious updates to every Fae install. The mitigating factor today is the very small user base (one).
* Bad, because the SHA256SUMS file lives in the same trust scope as the tarball (same release, same uploader) — it defends against post-upload corruption and network tampering, not against a maintainer who has been compromised.
* Good (procedural), because the trust assumptions are recorded in this ADR so a future "we should sign releases now" decision has the prior reasoning visible.
