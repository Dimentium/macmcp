# Known Issues

This is the current engineering issue register for MacMCP. It records remaining
delivery and reliability gaps without account addresses, credentials, or
personal data.

## Deferred Verification

- Recipient-aware managed drafts are implemented in the working tree, but the
  installed 0.2.32 release still has the recipient-free contract. On the next
  signed build, create a managed draft with To/Cc/Bcc recipients in the local
  and ChatGPT paths, then update its content and confirm all recipients remain
  in the draft. Do not send the acceptance draft.
- Recheck remote ChatGPT calls after the `0.2.15` response-size bound. A live
  `reminders.list` response with the old default of 100 items occupied about
  125 KiB because the untrusted-data envelope is intentionally present in both
  `content` and `structuredContent`; the connector then disabled the tool.
  The new filter measures the fully JSON-escaped public result and bounds it
  below 12 KiB before JSON-RPC framing, while `reminders.list` now defaults to
  10 items. A fully new ChatGPT chat has completed consecutive mail calls
  through the same live tunnel. Start a new chat when an older chat has already
  disabled its connector; a branch may help because it creates a new chat, but
  is not a reliable repair for an already disabled tool session.

## Settings Window

- Local Bridge is shown as a live status row, but its switch is disabled. The
  menu-bar app does not yet expose an independent stop/start lifecycle that can
  be safely controlled from settings.
- Calendar and Reminders access switches are live. Their settings gears control
  separate default-off write gates and advanced recurrence/alert/location
  controls; the 0.2.32 release was visually verified on the configured
  production host.
- Saving mail-account configuration restarts the app-owned runtime so local
  IPC, STDIO, and the ChatGPT tunnel receive the same account set. This is
  intentional, but it is not an in-place account reload.
- The Update button is available only for a newer Homebrew Cask release. A
  source or ad-hoc install must be updated through its normal source workflow.

## Resolved Since The 2026-09-05 Audit

- MacMCP 0.2.30 records an exact tunnel runtime lease and only reclaims a
  matching app-owned process after an interrupted restart. A same-profile
  process without that lease is left untouched and reported as unavailable.
- The source installer preserves and embeds a configured tunnel client when
  reusing its existing launch configuration. Source install and uninstall do
  not signal a runtime matched only by profile; a surviving exact configured
  client fails closed, and a foreign same-profile client is untouched. The
  isolated deployment acceptance verifies both operations against a live
  foreign client.
- Transient GitHub runner DNS failures while cloning/fetching pinned sidecar
  repositories retry twice before surfacing the original Git failure. The
  pinned origin, revision, and checksums are still independently verified.
- The release helper retries one ordinary app launch after a Cask upgrade when
  LaunchServices misses the initial request; the 0.2.30 local upgrade verified
  this recovery path.

- Reader sidecars cannot start through the direct production CLI path; data
  clients use the app-owned IPC/proxy path and per-client approval.
- Sidecars restart with bounded backoff, retain the private mail config for the
  runtime lifetime, reconnect the router, and surface restart counts.
- macOS CI runs an isolated temporary-HOME acceptance through setup, upgrade,
  diagnose, and uninstall.
- Tunnel diagnostics retain the 12 newest redacted failures across app and
  process restarts, and expose the latest one in the menu and all records in
  `macmcp diagnose`.
- The idle CPU issue is resolved in 0.2.24: the pinned MCP Swift SDK's empty
  stdio retry now backs off to 100 ms for both the bridge and EventKit sidecar.
- CheICalMCP now builds only with the reviewed, checksum-verified
  `CheICalMCP.Package.resolved` graph and `--disable-automatic-resolution`.
- Custom plain IMAP requires an explicit `--allow-unsafe-plain-imap` override.
  Local IPC has bounded frames, clients, concurrent requests, and deadlines.
- The mail and EventKit sidecars are embedded only in the signed app bundle.
  The installer no longer stages `libexec` copies.
- Canonical product, package, executable, bundle, state-path, and Keychain
  names now use the `macmcp` namespace. The installer carries legacy aliases
  and state forward during an upgrade.
- The menu-bar runtime holds a per-user exclusive lock. A repeated app launch
  now leaves the existing runtime active, and the restart helper waits for the
  current process to exit instead of starting a second sidecar and tunnel tree.
- A live remote ChatGPT tunnel session completed consecutive Mail calls after
  tunnel reconnect. The app, tunnel client, local proxy, and both mail
  sidecars remained healthy throughout.
- Subsequent signed Cask updates preserved the working ChatGPT tunnel in
  already-open chats; discovery and normal tool calls did not regress after
  updates.
- ChatGPT validation covered both Gmail and iCloud: recipient-free managed
  drafts were created and updated, and disabling Draft creation allowed blocked
  a later update immediately without restarting MacMCP.
- Public sidecar outputs are bounded after JSON escaping and structured-output
  duplication, rather than only at their raw source-text size. This prevents a
  large Calendar, Reminders, mail, or attachment response from producing an
  oversized remote MCP frame.
