# Known Issues

This is the current engineering issue register for MacMCP. It records remaining
delivery and reliability gaps without account addresses, credentials, or
personal data.

## High Priority

### 1. Stable signing and notarization are not available yet

The source formula builds locally and the installer stages artifacts before
activation, but it uses ad-hoc signing. Replacing the app can therefore change
the identity seen by Keychain, TCC, and Login Item services.

- Impact: an upgrade can require Keychain, Calendar, Reminders, Login Item, or
  client approvals to be granted again.
- Resolution: establish Developer ID signing, notarization, and a Cask release
  path. Run the live acceptance checklist on the first signed release.

## Medium Priority

### 2. CheICalMCP transitive dependencies are resolved on the target Mac

`mail-mcp` is downloaded as a pinned, checksum-verified release archive.
CheICalMCP is pinned to a source commit, but its SwiftPM dependency graph is
resolved during setup.

- Impact: a fresh Mac can build a different transitive dependency set from the
  one validated in CI.
- Resolution: enforce the sidecar resolution file or distribute a verified,
  signed CheICalMCP artifact with the app.

### 3. Reader transport needs resource and TLS hardening

Custom IMAP configuration still permits `plain` authentication. The local IPC
server also needs explicit limits for buffered frames, active clients, request
duration, and queued work.

- Impact: a custom-provider misconfiguration can lower transport security, and
  a same-user process can consume unbounded local IPC resources.
- Resolution: make plaintext an explicit unsafe override and add bounded IPC
  resource controls.

### 4. EventKit sidecar has two installed copies

The app bundle embeds CheICalMCP while launch configuration points to the copy
in `libexec`.

- Impact: duplicated artifacts complicate signing and release ownership.
- Resolution: choose one signed, authoritative sidecar location as part of the
  Cask packaging work.

## Naming Consistency

### 5. Technical and product names remain intentionally split

The visible product is MacMCP, while existing bundle and protocol identifiers
retain `mac-agent-bridge` for migration compatibility.

- Resolution: complete the Developer ID migration before changing bundle and
  TCC-facing identifiers. [docs/NAMING.md](NAMING.md) is the canonical mapping.

## Verification Still Needed

- Live acceptance of the first signed build: iCloud and Gmail reads and folder
  listing, Calendar, Reminders, approvals, tunnel reconnect, and upgrade.
- Opt-in mail notifications on a real account: baseline, one classified new
  message, a fixed-text notification, sidecar restart recovery, and no data
  mutation.
- A real remote ChatGPT tunnel call after login/reconnect.

## Resolved Since The 2026-09-05 Audit

- Reader sidecars cannot start through the direct production CLI path; data
  clients use the app-owned IPC/proxy path and per-client approval.
- Sidecars restart with bounded backoff, retain the private mail config for the
  runtime lifetime, reconnect the router, and surface restart counts.
- Notifications are an opt-in menu feature, disabled by default. They baseline
  every configured INBOX, use reader-only calls, and show fixed copy only.
- macOS CI runs an isolated temporary-HOME acceptance through setup, upgrade,
  diagnose, and uninstall.
- Tunnel diagnostics retain the 12 newest redacted failures across app and
  process restarts, and expose the latest one in the menu and all records in
  `macmcp diagnose`.
