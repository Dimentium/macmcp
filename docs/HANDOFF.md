# MacMCP Handoff

Last verified: 2026-09-09
Repository: `Dimentium/macmcp`
Working branch: `public-main`, pushed to `public/main`
Current published and installed app: `MacMCP 0.2.22`

This is the canonical current-state handoff. Read it first, then use
`docs/PLAN.md` for forward work, `docs/KNOWN_ISSUES.md` for unresolved items,
`docs/RELEASING.md` for release operations, and `docs/DEPLOYMENT.md` for user
installation.

## Executive Summary

MacMCP is a local macOS MCP bridge for Mail, Calendar, and Reminders. The
normal distribution is a Developer ID-signed and Apple-notarized Homebrew Cask
containing the bridge and both sidecars. The app owns the runtime, local IPC,
sidecars, Keychain access, EventKit access, Login Item, and optional OpenAI
Secure MCP Tunnel.

The project is beyond MVP for local use:

- iCloud Mail and Gmail are configured on the target Mac as separate accounts.
- Mail passwords and the tunnel runtime key are stored in macOS Keychain.
- Mail reader tools, Calendar, Reminders, attachment text extraction, and
  structured MCP output work through the local app-owned IPC path.
- Mail actions are always published but are gated independently per account by
  `Read only`, which defaults to enabled and changes without a restart.
- Managed drafts are recipient-free and protected by a Keychain-backed marker.
- The signed Cask upgrade path, app restart, single-instance lock, diagnostics,
  log rotation, uninstall preservation, and local acceptance gate exist.

## Verified State

The target Mac was checked with:

```text
bridge: available
mail: ready
calendar: ready
reminders: ready
app version: 0.2.22
mail restarts: 0
EventKit restarts: 0
configured mail accounts: 2
approved local clients: 1
tunnel: running
```

Automated local acceptance passed:

```text
tool_surface=PASS tools=17 structured_output=true
bridge_status=PASS
mail_reader=PASS accounts=2
calendar_reader=PASS
reminders_reader=PASS
result=PASS
```

The local check does not start the tunnel, create drafts, or modify mail.

Manual ChatGPT acceptance also passed for both account types: recipient-free
managed drafts were created and updated, and turning `Read only` back on
blocked a later update immediately without restarting MacMCP. Routine signed
Cask updates did not break existing ChatGPT chats.

The current Codex MCP tool context once returned `Transport closed` while the
local runtime remained healthy. This is a stale client-session condition, not
evidence that MacMCP is down. Restart the `macmcp` MCP server from the Codex /
ChatGPT desktop MCP settings and start a new Codex session if necessary. Do not
reinstall MacMCP for this condition.

## Architecture

```text
local Codex / ChatGPT Desktop MCP client
        |
        | stdio proxy
        v
user-local Unix socket
        |
        v
MacMCP.app -> macmcp-bridge -> GatewayRouter
                                  |-> mail-mcp sidecar
                                  `-> CheICalMCP sidecar

optional ChatGPT remote path:
OpenAI Secure MCP Tunnel -> app-owned tunnel-client
                           -> private stdio proxy -> same local socket
```

The local Codex entry is direct STDIO and does not need a tunnel. The current
`~/.codex/config.toml` entry points at the app-owned bridge and socket. The
`tunnel-mcp` Codex plugin is an operator surface for managing tunnel-client
runtimes; it is not the MacMCP data server itself.

Secure MCP Tunnel supports Codex/API product flows, but a `tunnel_id` is not a
drop-in field for the local `[mcp_servers.macmcp]` entry. A supported product
surface must expose/select the tunnel-backed target, and the tunnel must be
associated with the Platform organization used by that Codex/API flow. Do not
create a second runtime just to test this; the MacMCP app already owns the
configured tunnel-client process.

## Tool And Safety Contract

The published surface currently contains 17 tools:

- `bridge_status`
- `mail.list_accounts`, `mail.server_info`, `mail.list_folders`,
  `mail.search`, `mail.read`, `mail.read_attachment_text`
- `calendar.list`, `calendar.events`, `calendar.upcoming`, `calendar.search`
- `reminders.list`, `reminders.search`, `reminders.tags`
- `mail.create_managed_draft`, `mail.update_managed_draft`, `mail.mark`

Every tool has an `outputSchema`; successful calls return structured output.
The bridge does not expose send, reply, forward, delete, move, archive,
calendar-write, reminder-write, shell, filesystem, browser, or arbitrary
attachment-download tools.

Mail action rules:

- Each account starts in `Read only` mode.
- The menu path is `MacMCP > Mail > <account>`.
- The control gates local MCP, STDIO, and ChatGPT tunnel calls immediately.
- Managed drafts have no `To`, `Cc`, `Bcc`, `Reply-To`, or `Resent-*` headers.
- Only drafts carrying the valid MacMCP marker can be updated.
- Updating requires the exact current revision.
- The bridge never sends mail and never exposes a delete action.

## Normal Operations

Install the signed Cask on Apple Silicon macOS 14+:

```sh
brew tap Dimentium/macmcp https://github.com/Dimentium/macmcp
brew install --cask macmcp
macmcp setup --gmail-address you@example.com
```

Add iCloud with `--icloud-address`; repeat either preset for multiple accounts.
Use `--mail-account` for custom IMAP.

Upgrade without losing configuration or Keychain secrets:

```sh
brew upgrade --cask macmcp
# or use MacMCP > MacMCP version > Update to <version>
```

The app's update checker queries GitHub Releases at launch and every six hours.
The `Update` menu item is enabled only after a newer release is confirmed.

Safe diagnostics and local validation:

```sh
macmcp diagnose
scripts/validate-local-mcp.sh
```

The old independent IMAP snapshot validator is deliberately opt-in:

```sh
scripts/validate-local-mail-readonly.py --deep
```

It invokes the macOS `security` CLI and may produce a Keychain prompt. The
normal local gate does not use that path.

## Release Operations

Use `scripts/release.sh` as the single normal release entrypoint. Before it:

1. Bump the source version in `AppVersion.swift`, both bundle plists, and the
   matching packaging test.
2. Update pinned sidecar revisions only when intended and run `swift test`.
3. Commit the release source changes and ensure the worktree is clean.

On the release Mac:

```sh
scripts/release.sh \
  --signing-identity "Developer ID Application: Your Name (TEAMID)" \
  --install-local
```

The script tests, builds, signs, notarizes, publishes the GitHub release,
regenerates Cask/formula metadata, upgrades the local Cask, restarts the app,
and runs the local gate. Release logs are private files under `dist/`.

Do not run a binary release for documentation-only or validator-only changes.
Do not manually replace the Cask unless diagnosing a failed release step.

## Open Work, In Order

1. Clarify and, only if needed, validate a genuine Codex/API
   tunnel-backed-target flow. The current local Codex path is already direct
   STDIO. The official Secure MCP Tunnel wording is intentionally product
   surface-specific; do not infer an endpoint from `tunnel_id`.
2. Validate large Calendar, Reminders, and attachment responses through the
   remote ChatGPT/tunnel product surface. Local attachment text extraction has
   already passed; the current local gate checks the tool surface but does not
   call an attachment.
3. Consider adding a privacy-safe local attachment call to the acceptance gate
   if a deterministic attachment fixture can be used without modifying a real
   mailbox.

The earlier `launchAtLogin=true` / `loginItem=not_registered` observation was
confirmed to be two distinct states: the persisted preference in `launch.json`
and the actual `SMAppService.mainApp.status`. On the installed 0.2.22 runtime
both the diagnostic and direct Login Item query report `enabled`; no Login Item
behavior change is needed.

The 0.2.22 publication reproduced the release-script follow-up: the Cask
upgrade completed, but `release.sh --install-local` mistook the still-running
Codex `macmcp-bridge --stdio-proxy` for the app runtime and stopped during its
restart wait. Launching the new Cask manually produced a healthy 0.2.22 app;
the post-install diagnostic and local gate pass, and the configured tunnel is
running. The restart/quit detection still needs a follow-up.

The per-account draft/read-only acceptance item is closed by manual ChatGPT
testing. The response-size edge case remains a deferred remote verification,
not a reason to change the local bridge without a reproduction.

## Do Not Do

- Do not create a replacement runtime API key while the existing Keychain key
  is still being used successfully.
- Do not start a second `tunnel-client` or run `runtimes connect` against the
  app-managed tunnel during normal testing.
- Do not invoke the deep IMAP validator accidentally without `--deep`.
- Do not print passwords, API keys, tunnel IDs, account addresses, subjects,
  message bodies, or raw tunnel output in logs or handoff documents.
- Do not revert unrelated user changes or use destructive Git reset/checkout.
- Do not change the bundle identifier; it creates a new macOS code identity and
  can invalidate existing permission/approval continuity.

## Key Files

- `Sources/MacMCPBridge/BridgeRuntime.swift`: runtime wiring and sidecars.
- `Sources/MacMCPBridge/GatewayRouter.swift`: MCP routing and policy boundary.
- `Sources/MacMCPBridge/ReaderPolicy.swift`: published reader/action policy.
- `Sources/MacMCPBridge/LocalBridgeIPC.swift`: bounded local IPC.
- `Sources/MacMCPBridge/LocalBridgeStdioProxy.swift`: client-facing STDIO.
- `Sources/MacMCPBridge/MenuBarHost.swift`: menu, settings, restart, update.
- `Sources/MacMCPBridge/ChatGPTTunnelSupervisor.swift`: app-owned tunnel.
- `Sources/MacMCPBridge/ClientApprovalStore.swift`: local client approvals.
- `Sources/MacMCPBridge/MailActionAccessStore.swift`: account read-only state.
- `Sources/MacMCPBridge/ManagedDraftKeyStore.swift`: draft marker key.
- `Sources/MacMCPBridge/AttachmentTextReader.swift`: bounded text extraction.
- `scripts/release.sh`: normal release entrypoint.
- `scripts/validate-local-mcp.sh`: normal local acceptance gate.
- `scripts/validate-live-acceptance.sh`: manual remote precondition gate.
- `docs/PLAN.md`: only forward-looking plan.
- `docs/KNOWN_ISSUES.md`: current issue register.
- `docs/RELEASING.md`: signing, notarization, and release runbook.

## Recent Commits

- `252b995` Support Cask runtime in live validation
- `ac73a60` Record mail action acceptance
- `90774bd` Record stable ChatGPT updates
- `b5b019b` Make deep IMAP validation opt in

The worktree was clean when this handoff was written.
