# Current Plan

This is the single planning note for the project. Older spike and validation
documents are evidence records, not forward plans.

## Status

MacMCP is a local MVP+ for MCP clients that can launch a local stdio server:
the installer, menu-bar app, Keychain password storage, iCloud/Gmail presets,
multi-account config, reader-only gateway, upgrade, uninstall, and transfer
archive exist. The target Mac has a real local install with iCloud and Gmail
configured. Local MCP reader-data calls now require per-client approval.

Local stdio MCP validation has passed with iCloud and Gmail in one runtime:
tool surface, account auth, `mail.search`, `mail.read`, and independent IMAP
no-mutation snapshots. The menu-bar app now owns the local bridge/sidecars, and
local MCP clients attach through a stdio proxy over user-local IPC. Restart and
app-owned `--status-json` validation have passed. The post-upgrade and final
post-reboot gates both pass for components, Login Item persistence, local
approval, and the two-account no-mutation reader path. The menu refreshes
component/client approval status, and local approval grants are collapsed to the
current executable hash during upgrade.

## Direction

1. Polish local deployment.
   Keep install/upgrade/uninstall simple, preserve Keychain passwords by
   default, and stage/validate upgrades before switching away from a working
   runtime. Document the one-command local install and keep the archive path
   clean for a fresh Mac. Add a Homebrew tap/formula only after the local
   archive flow is stable enough to justify it.

2. Validate the app-managed ChatGPT tunnel beyond the validated local Work path.
   ChatGPT Work on the desktop app is the primary client target and has now
   completed a live local mail check through the shared Codex-host MCP config.
   The ordinary desktop Chat composer did not expose local MCP tools in that
   client. For web Chat and hosted Work, use the prepared Secure MCP Tunnel
   profile over the existing private STDIO proxy. The installer now provisions
   the Homebrew client when requested, stores the runtime key in Keychain, and
   the menu-bar app owns its lifecycle. Validate the developer-mode app,
   workspace visibility, tunnel reconnect after login, and reader-only remote
   calls. Claude Desktop support is opportunistic only.

3. Finish the reader MVP workflow.
   Add the macOS notification path and run the end-to-end acceptance test:
   new mail, classification, notification, and no mutation of Mail, Calendar,
   or Reminders.

## Not In The Current Plan

- Raw headless LaunchAgent as the EventKit owner.
- Write tools or action tools in the reader profile.
- Notes, Contacts, Messages, Apple Mail private databases, Full Disk Access, or
  generic shell/browser/filesystem access.
- Forking upstream sidecars unless validation proves the gateway cannot enforce
  the reader contract.

## Deferred: Managed Drafts and Message State

After runtime reliability and deployment work, add a separate, opt-in actions
profile. It may create recipient-free managed drafts and change the read or
flagged state of one message at a time. It never exposes SMTP or a send tool.

Managed drafts must be created without `To`, `Cc`, `Bcc`, `Reply-To`, or
`Resent-*` headers. The actions profile may edit only a draft that remains
recipient-free and is verified as MacMCP-managed through a provider-supported
persistent IMAP keyword plus a locally authenticated ownership record. Once a
human adds a recipient, MacMCP must refuse further edits. Providers that do not
preserve the required keyword may support draft creation but not managed-draft
editing.

IMAP body edits are replacement operations, not in-place updates. Start with
draft creation; add replacement only with a revision token and a validated
append-then-retire protocol. Gmail-specific importance is separate from the
portable `\\Flagged` state and must remain capability-gated.
