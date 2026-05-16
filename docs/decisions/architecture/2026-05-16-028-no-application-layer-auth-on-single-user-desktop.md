---
status: accepted
date: 2026-05-16
---
# No application-layer authentication on a single-user desktop

## Context and Problem Statement

A desktop-resident daemon bound to local-loopback on a single-user Linux machine needs to decide on an authentication model. The intuitive answer is "of course we need login" — but that intuition comes from server applications running in shared environments. For a daemon that runs only on its owner's machine, only listens on `127.0.0.1`, and is started by the owner's own user, the realistic threat model is materially different and may not justify an application-layer auth scheme.

## Decision Outcome

Chosen option: "no application-layer authentication; rely on local-loopback binding and single-user-desktop assumptions", because the only realistic threats are not actually defended against by application-layer auth, while the auth machinery imposes meaningful complexity and ongoing friction.

**Rationale:**

- The TCP listener binds to `127.0.0.1` only — no network exposure
- On a single-user desktop, the only UIDs on the machine are the owner's and a handful of system daemons that have no reason to probe a personal tool
- A hostile process running as the owner's UID can read any filesystem secret (a token file, a config password, in-memory PAM credentials) anyway — so application-layer auth does not defend against the only realistic local threat

**Important clarification, captured here so it stays correct:** systemd's *user scope* governs who can manage the service (start/stop/status). It does **not** restrict who can connect to a TCP port the service opens — `127.0.0.1` is shared across all local UIDs on a multi-user Linux system. The real reason no-auth works in this scenario is *single-user-desktop + loopback-only binding*, not "it's a user systemd service."

**Reversal triggers** — revisit this decision if any become true:

- The service is exposed beyond local loopback (SSH tunnel from another machine, binding to a LAN interface, accessed remotely)
- The machine becomes multi-user with untrusted UIDs
- The service starts holding secrets with broader blast radius than the rest of the user's account (e.g., long-lived production credentials)

If a reversal trigger fires, the most likely answer is the "token file + `<app> open` CLI" pattern (filesystem permissions as the identity check, browser handshake to set a session cookie) used by Jupyter, VS Code Server, and similar tools — not PAM or a username/password.

### Consequences

* Good, because the application is dramatically simpler — no auth code, no session machinery, no login pages, no password reset flows, no email infrastructure
* Good, because there is zero friction to use the daemon: open the browser to the local URL
* Good, because the trust model is honest — it does not pretend to defend against threats it cannot actually stop
* Bad, because the architecture has a load-bearing dependency on the loopback-only binding; if that ever silently changes (config drift, container with host networking, accidental port-forward), the service becomes unauthenticated to the network
* Bad, because the decision does not generalize to multi-user or networked deployments — any such future use case requires revisiting auth
* Mitigated, by asserting the loopback binding in runtime configuration (not just convention) so the trust model cannot quietly drift
