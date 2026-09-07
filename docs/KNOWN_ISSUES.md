# Known Issues

This is the current engineering issue register for MacMCP. It records remaining
delivery and reliability gaps without account addresses, credentials, or
personal data.

## High Priority

### 1. Cask migration from the legacy product name

The signed, notarized Cask is published. The next Cask release adds an
in-app migration from the former `mac-agent-bridge` layout: it removes obsolete
sidecar paths from the launch configuration, retains account settings and
tunnel configuration, and copies durable non-secret state. It intentionally
does not retain grants for the removed proxy executable, so the new local MCP
proxy needs one approval.

- Impact: a legacy source install must be checked once against the Cask path.
- Resolution: verify live mail, EventKit, local approval, and tunnel reconnect
  after replacing the legacy install with the signed Cask.

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
- Migration from a pre-`macmcp` local install: retain the mail accounts and
  Keychain secrets, re-approve the new local proxy identity, and confirm the
  prior tunnel reconnects.

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
- The mail and EventKit sidecars are embedded only in the signed app bundle.
  The installer no longer stages `libexec` copies.
- Canonical product, package, executable, bundle, state-path, and Keychain
  names now use the `macmcp` namespace. The installer carries legacy aliases
  and state forward during an upgrade.
