# Known Issues

This is the current engineering issue register for MacMCP. It records remaining
delivery and reliability gaps without account addresses, credentials, or
personal data.

## Verification Still Needed

- Live acceptance after a normal in-app Cask update: iCloud and Gmail reads and
  folder listing, Calendar, Reminders, approvals, tunnel reconnect, and app
  restart from the replaced bundle.
- A real remote ChatGPT tunnel call after login/reconnect.
- Per-account mail actions on iCloud and Gmail: create a recipient-free draft,
  reject a human recipient edit, update an unchanged draft, and confirm that
  toggling `Read only` blocks and re-allows the same tools through local MCP
  and the tunnel without a restart.
- Reproduce one ChatGPT chat whose connector is marked unavailable after a
  tool call, then correlate it with the redacted local tunnel log. Branching
  the ChatGPT conversation is a confirmed workaround: it starts a fresh chat
  while retaining the history copy.

## Resolved Since The 2026-09-05 Audit

- Reader sidecars cannot start through the direct production CLI path; data
  clients use the app-owned IPC/proxy path and per-client approval.
- Sidecars restart with bounded backoff, retain the private mail config for the
  runtime lifetime, reconnect the router, and surface restart counts.
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
