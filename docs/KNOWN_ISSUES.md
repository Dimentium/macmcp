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

### 2. EventKit sidecar has two installed copies

The app bundle embeds CheICalMCP while launch configuration points to the copy
in `libexec`.

- Impact: duplicated artifacts complicate signing and release ownership.
- Resolution: choose one signed, authoritative sidecar location as part of the
  Cask packaging work.

## Naming Consistency

### 3. Technical and product names remain intentionally split

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
- Per-account mail actions on iCloud and Gmail: create a recipient-free draft,
  reject a human recipient edit, update an unchanged draft, and confirm that
  toggling `Read only` blocks and re-allows the same tools through local MCP
  and the tunnel without a restart.

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
- CheICalMCP now builds only with the reviewed, checksum-verified
  `CheICalMCP.Package.resolved` graph and `--disable-automatic-resolution`.
- Custom plain IMAP requires an explicit `--allow-unsafe-plain-imap` override.
  Local IPC has bounded frames, clients, concurrent requests, and deadlines.
