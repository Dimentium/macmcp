# Current Plan

This is the single planning note for the project. Older spike and validation
documents are evidence records, not forward plans.

## Status

MacMCP is a local MVP+ for MCP clients that can launch a local stdio server:
the signed release DMG, optional Homebrew Cask, source formula, menu-bar app,
Keychain password storage,
iCloud/Gmail presets, multi-account config, account-gated mail actions, upgrade,
uninstall, and in-app Cask update control exist. The target Mac has a real local
install with iCloud and Gmail configured. Local MCP reader-data calls require
per-client approval.

Local stdio MCP validation has passed with iCloud and Gmail in one runtime:
tool surface, account auth, `mail.search`, `mail.read`, folder listing,
Calendar, Reminders, and structured output. `scripts/validate-local-mcp.sh`
now runs this local acceptance
without the ChatGPT tunnel and is part of `scripts/release.sh --install-local`.
The menu-bar app now owns the local bridge/sidecars, and local MCP clients
attach through a stdio proxy over user-local IPC. Restart and app-owned
`--status-json` validation have passed. The post-upgrade and final
post-reboot gates both pass for components, Login Item persistence, local
approval, and the two-account no-mutation reader path. `mail-mcp` is pinned to
the small `Dimentium/mail-mcp` compatibility fork, which restores iCloud folder
listing while preserving Gmail SPECIAL-USE metadata. Sidecar restarts retain
their private config, reconnect the router, and expose restart counts in bridge
status. A CI deployment acceptance runs setup, upgrade, diagnose, and uninstall
inside a temporary HOME without touching a real user configuration.

Release execution details, including the local acceptance gate and the
Keychain-prompt caveat of the optional deep IMAP validator, are kept in
[docs/RELEASING.md](RELEASING.md).

## Direction

1. Keep the direct release install and signed Cask upgrades reliable.
   The release DMG is the primary user path: it contains the complete signed
   runtime, signed `tunnel-client`, and companion files, and works without
   Homebrew or administrator access. On first launch, the app's setup window
   optionally configures mail and/or the ChatGPT tunnel, storing secrets in
   Keychain. The Cask remains useful for command-line setup and repeatable
   upgrades.
   The Developer ID-signed, Apple-notarized Cask is published and contains the
   complete runtime. It checks GitHub Releases at launch and every six hours;
   its Updates menu can then refresh the Homebrew tap, upgrade the Cask, and
   restart from the new bundle.
   `scripts/release.sh --install-local` now exercises the live local iCloud,
   Gmail, EventKit, approval, structured-output, and reader paths after
   installing the published Cask. Tunnel behavior remains outside this local
   gate. The menu-bar runtime now takes a per-user exclusive lock, so a
   repeated launch cannot create another sidecar or tunnel tree. The source
   formula remains
supported for self-builds and may still require macOS permissions again after
each ad-hoc-signed replacement.

2. Validate the app-managed ChatGPT tunnel beyond the validated local Work path.
   ChatGPT Work on the desktop app is the primary client target and has now
   completed a live local mail check through the shared Codex-host MCP config.
   The ordinary desktop Chat composer did not expose local MCP tools in that
   client. For web Chat and hosted Work, use the prepared Secure MCP Tunnel
   profile over the existing private STDIO proxy. The installer now provisions
   the Homebrew client when requested, stores the runtime key in Keychain, and
   the menu-bar app owns its lifecycle. A live new ChatGPT chat has completed
   consecutive remote mail calls after reconnect. Continue validating
   account-gated remote mail actions. A connector disabled in one existing
   ChatGPT chat was a per-chat state issue; subsequent signed Cask updates
   have not broken existing chats. The public untrusted-data envelope is bounded below 12 KiB
   after JSON escaping and duplication into both MCP response fields; this
   keeps large mail, Calendar, Reminder, and attachment results within a
   conservative remote transport budget. Claude Desktop support is
   opportunistic only.

3. Keep diagnostics actionable.
   `macmcp diagnose` reports a sanitized state snapshot. Extend it only with
   non-personal operational evidence when a real failure reveals a gap. Tunnel
   failures persist as a bounded history of timestamps, fixed phases, and fixed
   reasons, so intermittent init, doctor, run, and health failures survive an
   app restart without retaining command output.

## Settings Window Migration Contract

The approved single-page SwiftUI settings UX is being migrated from the
standalone prototype into the menu-bar app. The AppKit host remains responsible
for runtime ownership and lifecycle; the SwiftUI model is an adapter, not a
second configuration store.

State ownership during migration:

- `AppLaunchConfigurationStore` remains the source of truth for launch
  arguments, Login Item preference, and the non-secret ChatGPT tunnel
  configuration (`tunnelID`, client path, and profile).
- `MigratingCredentialStore.chatGPTTunnel()` remains the source of truth for
  the tunnel runtime key. It must never be written to `launch.json`, logs, or
  diagnostic snapshots. Mail passwords continue to use the account username as
  their Keychain account.
- `MCPDataAccessController` owns Calendar and Reminders MCP access. The
  existing `MailActionAccessController` owns per-account read-only/draft
  permissions. Both must continue to gate local IPC, STDIO, and tunnel calls.
- `MenuBarHost` and `ChatGPTTunnelSupervisor` remain the source of live bridge
  and tunnel status. Settings actions must use their existing lifecycle paths
  rather than starting an independent runtime or tunnel client.
- `HomebrewCaskUpdater` remains the source of update state and installation;
  logs open from `MacMCPPaths.logsDirectory(homeDirectory:)`, without exposing
  their contents in settings.

The first integration pass must explicitly resolve two UX/runtime gaps. A
Local Bridge switch is only valid if it invokes the app-owned runtime stop/start
path, and a mail-account on/off switch needs a real account access gate across
all transports; neither may be implemented as a preference that only changes
the display. Until those semantics are wired, the UI may show status without
presenting a misleading control.

The old status-bar actions remain available as compatibility aliases until the
new window has passed the parity matrix. The final cleanup may remove duplicate
menu actions only after manual checks cover empty, partially configured,
configured, unavailable, and multi-account states.

## Per-Account Mail Actions

The standard MacMCP endpoint always advertises the three narrow mail-action
tools and applies the same policy through local IPC, stdio, and the ChatGPT
tunnel. Every configured account begins with `Read only` enabled. The
`MacMCP > Mail > account` toggle enables or disables new action calls for that
specific account immediately and persists across app restarts.

It exposes only recipient-free managed drafts and one-message `read`, `unread`,
`flagged`, or `unflagged` operations. SMTP, send, delete, move, archive,
calendar, and reminder writes remain unavailable.

Each managed draft has an HMAC marker created from a persistent Keychain key
and held only in the private runtime sidecar config. Updating requires the
exact revision returned by the previous operation; a legacy draft with the
valid marker but without a revision header gets a one-time revision derived
from its current MIME. The server refuses an invalid marker, a changed draft,
or any `To`, `Cc`, `Bcc`, `Reply-To`, or
`Resent-*` recipient header.

Updating appends the replacement before marking the prior draft deleted, without
expunging it. A partial retirement is reported as `saved_unretired` and must
not be blindly retried. Gmail-specific importance is not part of the portable
action profile; it needs a capability-gated design instead of being mapped to
`\\Flagged`.

## Not In The Current Plan

- Raw headless LaunchAgent as the EventKit owner.
- Mail mutations beyond recipient-free managed drafts and the four explicit
  message-state changes, whether local or through the ChatGPT tunnel.
- Notes, Contacts, Messages, Apple Mail private databases, Full Disk Access, or
  generic shell/browser/filesystem access.
- Broad sidecar forks unrelated to the reviewed iCloud compatibility and
  managed-draft contract.
