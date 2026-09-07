# Current Plan

This is the single planning note for the project. Older spike and validation
documents are evidence records, not forward plans.

## Status

MacMCP is a local MVP+ for MCP clients that can launch a local stdio server:
the signed Homebrew Cask, source formula, menu-bar app, Keychain password storage,
iCloud/Gmail presets, multi-account config, account-gated mail actions, upgrade,
uninstall, and in-app Cask update control exist. The target Mac has a real local
install with iCloud and Gmail configured. Local MCP reader-data calls require
per-client approval.

Local stdio MCP validation has passed with iCloud and Gmail in one runtime:
tool surface, account auth, `mail.search`, `mail.read`, and independent IMAP
no-mutation snapshots. The menu-bar app now owns the local bridge/sidecars, and
local MCP clients attach through a stdio proxy over user-local IPC. Restart and
app-owned `--status-json` validation have passed. The post-upgrade and final
post-reboot gates both pass for components, Login Item persistence, local
approval, and the two-account no-mutation reader path. `mail-mcp` is pinned to
the small `Dimentium/mail-mcp` compatibility fork, which restores iCloud folder
listing while preserving Gmail SPECIAL-USE metadata. Sidecar restarts retain
their private config, reconnect the router, and expose restart counts in bridge
status. A CI deployment acceptance runs setup, upgrade, diagnose, and uninstall
inside a temporary HOME without touching a real user configuration.

## Direction

1. Keep signed Cask upgrades reliable.
   The Developer ID-signed, Apple-notarized Cask is published and contains the
   complete runtime. It checks GitHub Releases at launch and every six hours;
   its Updates menu can then refresh the Homebrew tap, upgrade the Cask, and
   restart from the new bundle.
   Exercise a Cask upgrade against the live iCloud, Gmail, EventKit, local
approval, and tunnel paths when a release changes those components. The
menu-bar runtime now takes a per-user exclusive lock, so a repeated launch
cannot create another sidecar or tunnel tree. The source formula remains
supported for self-builds and may still require macOS permissions again after
each ad-hoc-signed replacement.

2. Validate the app-managed ChatGPT tunnel beyond the validated local Work path.
   ChatGPT Work on the desktop app is the primary client target and has now
   completed a live local mail check through the shared Codex-host MCP config.
   The ordinary desktop Chat composer did not expose local MCP tools in that
   client. For web Chat and hosted Work, use the prepared Secure MCP Tunnel
   profile over the existing private STDIO proxy. The installer now provisions
   the Homebrew client when requested, stores the runtime key in Keychain, and
   the menu-bar app owns its lifecycle. Validate the developer-mode app,
   workspace visibility, tunnel reconnect after login, account-gated remote
   mail actions, and reader calls. Claude Desktop support is opportunistic only.

3. Keep diagnostics actionable.
   `macmcp diagnose` reports a sanitized state snapshot. Extend it only with
   non-personal operational evidence when a real failure reveals a gap. Tunnel
   failures persist as a bounded history of timestamps, fixed phases, and fixed
   reasons, so intermittent init, doctor, run, and health failures survive an
   app restart without retaining command output.

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
exact revision returned by the previous operation; it refuses a missing or
invalid marker, a changed draft, or any `To`, `Cc`, `Bcc`, `Reply-To`, or
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
