# MacMCP Handoff

Last verified: 2026-09-25
Repository: `Dimentium/macmcp`
Working branch: `ux/settings-window` (published through `public/main`)
Current published and installed bundle: `MacMCP 0.2.33`; its runtime failed to
start after the local Cask upgrade. The 0.2.34 startup fix is pending.

This is the canonical current-state handoff. Read it first, then use
`docs/PLAN.md` for forward work, `docs/KNOWN_ISSUES.md` for unresolved items,
`docs/RELEASING.md` for release operations, and `docs/DEPLOYMENT.md` for user
installation.

## Executive Summary

MacMCP is a local macOS MCP bridge for Mail, Calendar, and Reminders. The
normal distribution is a Developer ID-signed and Apple-notarized Homebrew Cask
containing the bridge, both sidecars, and a signed OpenAI `tunnel-client`; the
release DMG provides the same runtime without Homebrew. The app owns the runtime, local IPC,
sidecars, Keychain access, EventKit access, Login Item, and optional OpenAI
Secure MCP Tunnel.

The project is beyond MVP for local use:

- iCloud Mail and Gmail are configured on the target Mac as separate accounts.
- Mail passwords and the tunnel runtime key are stored in macOS Keychain.
- Mail reader tools, Calendar, Reminders, attachment text extraction, and
  structured MCP output work through the local app-owned IPC path.
- Mail actions are always published but are gated independently per account by
  `Draft creation allowed`, which defaults to disabled and changes without a
  restart.
- Calendar and Reminders have independent MCP access gates in the menu. They
  default to enabled, persist per user, and gate local IPC, STDIO, and the
  ChatGPT tunnel without a restart.
- Calendar and Reminders each also have a separate default-off write gate in
  Settings. Enabling it exposes only the reviewed narrow action tools and
  takes effect for all transports without a restart.
- The published 0.2.33 contract accepts optional To/Cc/Bcc on managed draft
  creation and preserves them through content updates. The Cask installed its
  bundle locally, but optimized validation rejected valid account and sidecar
  IDs at startup. The 0.2.34 fix adds a release-mode test gate; controlled Mail
  and ChatGPT draft acceptance remains pending.
- The signed Cask upgrade path, app restart, single-instance lock, diagnostics,
  log rotation, uninstall preservation, and local acceptance gate exist.
- The Cask is the preferred path on Macs with Homebrew: it installs, upgrades,
  and starts the signed app. The release DMG is the Homebrew-free,
  administrator-free alternative. A first-launch setup window optionally
  configures mail and/or the ChatGPT tunnel, storing secrets in Keychain;
  either or both can be left disabled. After first launch, `Open Settings...`
  is the single entry point for these configuration tasks.
- The approved single-page settings window is now integrated into the
  menu-bar app on this branch. It centralizes Login Item, local/tunnel access,
  EventKit access, mail-account CRUD and gates, tunnel configuration, update,
  logs, repository, and close actions. Secrets remain Keychain-only.
- The status-bar menu intentionally contains only `Open Settings...` and
  `Quit`; component status and lifecycle controls are shown in settings.

## Current Release Verification

The 0.2.33 source and signed artifacts were published, and the local Cask
upgrade installed bundle version 0.2.33. The app did not reach runtime-ready
state: release diagnostics reported the bridge and tunnel unavailable, and the
local acceptance step did not run. Optimized validation rejected standard
account and sidecar IDs although debug tests passed. The corrected 0.2.34
release runs the full Swift suite in both debug and optimized release
configurations before publishing.

## Previously Verified State (0.2.32)

The target Mac was checked with:

```text
bridge: available
mail: ready
calendar: ready
reminders: ready
app version: 0.2.32
mail restarts: 0
EventKit restarts: 0
configured mail accounts: 2
approved local clients: 5
tunnel: running
```

The installed 0.2.32 app was upgraded through the Cask during the latest
check. The existing tunnel profile and runtime-key reference were preserved;
the app-owned tunnel reported `running` again. The bridge and tunnel became
ready after 28 seconds.
The Calendar/Reminders settings write gates are included in the installed
release. Before release, a signed temporary 0.2.32 bundle created a test event
in the personal iCloud calendar and a test reminder in the personal `ToDo`
list through the new MCP actions; the user confirmed both were visible and
removed them.

Automated local acceptance passed:

```text
tool_surface=PASS tools=21 structured_output=true
bridge_status=PASS
mail_reader=PASS accounts=2
attachment_reader=PASS attachments=1 bytes=39
calendar_reader=PASS
reminders_reader=PASS
result=PASS
```

The local check does not start the tunnel, create drafts, or modify mail. The
attachment line is from the explicit `--attachment-fixture` run; the default
gate remains fixture-free. The fixture is the Gmail draft titled `MacMCP
attachment validation fixture — do not send`, containing one non-inline
`text/plain` attachment, `5091-2_2-test.txt` (39 bytes).

Manual ChatGPT acceptance also passed for both account types: recipient-free
managed drafts were created and updated, and disabling `Draft creation allowed`
blocked a later update immediately without restarting MacMCP. Routine signed
Cask updates did not break existing ChatGPT chats.

When the 0.2.32 runtime was healthy, a Codex MCP tool context once returned
`Transport closed`; this was a stale client-session condition. The currently
installed 0.2.33 runtime is separately unavailable due to its startup bug.

The Settings window is a completed, released part of the app. It was verified
with a production Swift build, the full XCTest suite, a locally launched
Developer ID-signed bundle, and interactive UX review. The signed local bundle
also exercised the empty local state and unavailable-tunnel path without
replacing the installed app. `docs/images/settings-window.png` is the current
framed visual reference; there is no remaining Settings-specific release gate.

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

The menu's Calendar and Reminders access controller is shared by both server
transports. It filters `tools/list`, rejects stale `tools/call` requests, and
also suppresses background EventKit health reads while a category is disabled.

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

MacMCP exposes 17 tools by default. When a Calendar or Reminders write
gate is enabled, it additionally publishes the corresponding narrow actions:

- `bridge_status`
- `mail.list_accounts`, `mail.server_info`, `mail.list_folders`,
  `mail.search`, `mail.read`, `mail.read_attachment_text`
- `calendar.list`, `calendar.events`, `calendar.upcoming`, `calendar.search`
- `reminders.list`, `reminders.search`, `reminders.tags`
- `mail.create_managed_draft`, `mail.update_managed_draft`, `mail.mark`

Every tool has an `outputSchema`; successful calls return structured output.
The EventKit actions are `calendar.create`, `calendar.update`,
`reminders.create`, and `reminders.complete`. Calendar and Reminders each
start read-only; their action tools are absent from `tools/list` and rejected
on direct calls until both the ordinary data-access switch and that category's
write gate are enabled. They are shared by local IPC, stdio, and the ChatGPT
tunnel, so no restart is required. The action contract excludes deletion,
moving, invitation management, and reopening reminders. Recurrence is
independently granted for Calendar and Reminders; Calendar alerts and Reminder
location triggers are independently granted as well. Those advanced arguments
are rejected on every call unless their matching Settings switch is enabled.

The bridge does not expose send, reply, forward, delete, move, archive, shell,
filesystem, browser, or arbitrary attachment-download tools.

Mail action rules:

- Each account starts with `Draft creation allowed` disabled.
- The account control is in `MacMCP > Open Settings...`.
- The control gates local MCP, STDIO, and ChatGPT tunnel calls immediately.
- The published 0.2.33 contract accepts optional To/Cc/Bcc recipients,
  validates them, and preserves them through updates. It still excludes
  `Reply-To` and `Resent-*`. Runtime acceptance awaits the 0.2.34 startup fix.
- Only drafts carrying the valid MacMCP marker can be updated.
- Updating requires the exact current revision.
- The bridge never sends mail and never exposes a delete action.

## Normal Operations

On a Mac with Homebrew, install with the Cask:

```sh
brew tap Dimentium/macmcp https://github.com/Dimentium/macmcp
brew install --cask macmcp
macmcp setup --gmail-address you@example.com
```

Add iCloud with `--icloud-address`; repeat either preset for multiple accounts.
Use `--mail-account` for custom IMAP.

Without Homebrew or administrator rights, install from the release DMG on Apple
Silicon macOS 14+:

1. Download `MacMCP-<version>-macos.dmg` from GitHub Releases.
2. Open it and drag `MacMCP.app` to `/Applications`, or to `~/Applications`
   when the user is not an administrator.
3. Open the app and complete its setup window.

Upgrade without losing configuration or Keychain secrets:

```sh
brew upgrade --cask macmcp
# or use MacMCP > Open Settings... > Update
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
2. Update pinned sidecar revisions only when intended and run `swift test` plus
   `swift test -c release`.
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

1. Publish and install 0.2.34 after fixing optimized account and sidecar
   identifier validation.
   Then run controlled To/Cc/Bcc create-and-update acceptance locally and
   through ChatGPT using the checks in `docs/RELEASING.md`.
2. Clarify and, only if needed, validate a genuine Codex/API
   tunnel-backed-target flow. The current local Codex path is already direct
   STDIO. The app-owned tunnel profile has passed the local `healthz`/`readyz`
   probe with a live control-plane poll, and its tunnel metadata was read
   successfully without changing the tunnel. The official Secure MCP Tunnel
   wording is intentionally product-surface-specific; do not infer an
   endpoint from `tunnel_id`. The remaining check is manual: select or paste
   this tunnel in the target ChatGPT workspace's developer-mode app.
3. Validate large Calendar, Reminders, and attachment responses through the
   remote ChatGPT/tunnel product surface. Local attachment text extraction has
   already passed; the default local gate remains fixture-free, while the
   explicit fixture mode calls one attachment.

The earlier `launchAtLogin=true` / `loginItem=not_registered` observation was
confirmed to be two distinct states: the persisted preference in `launch.json`
and the actual `SMAppService.mainApp.status`. On the installed 0.2.24 runtime
both the diagnostic and direct Login Item query report `enabled`; no Login
Item behavior change is needed.

The 0.2.33 publication completed through Apple notarization, GitHub, and the
Homebrew Cask, but its local runtime did not become ready after upgrade. The
release-only account validation bug blocked the final local acceptance step;
0.2.34 is the pending fix. The 0.2.32 publication completed through Apple
notarization, GitHub, and the Homebrew Cask. The local Cask upgraded from
0.2.31 to 0.2.32; the installed app, Calendar, Reminders, Mail, and tunnel all
became ready, and the standard
17-tool reader acceptance passed. The 0.2.31 publication completed through Apple notarization, GitHub, and the
Homebrew Cask. Apple initially returned a transient CloudKit ticket-validation
error after accepting notarization; a subsequent validation succeeded and the
normal release script completed. The post-install diagnostic, local MCP gate,
and configured tunnel check pass. The release has one app process, one
`tunnel-client`, and one app-owned `macmcp-bridge --stdio-proxy` child; other
proxy processes belong
to external local MCP clients. The release helper retried one ordinary app
launch after the first LaunchServices request was missed, without creating a
duplicate app runtime.

MacMCP 0.2.30 records a private lease with the tunnel runtime PID, start time,
executable path, and profile. It reclaims only an exact lease match after an
interrupted app restart, and fails closed before `init --force` if another
process already runs the same client/profile.

The source installer also preserves a configured tunnel on
`--reuse-existing-configuration`: it validates and embeds the existing client
in the replacement app, then rewrites the stored client path to that bundle.
Neither source install nor source uninstall selects or signals a tunnel by
profile alone. A surviving exact configured client blocks replacement or
deletion, while a foreign same-profile tunnel is left untouched. Its isolated
deployment acceptance runs a live foreign same-profile client across both
replacement and deletion and verifies that its PID survives. The pinned
sidecar builders retry `git clone` and `git fetch` up to three times for
transient runner/network failures; origin, revision, dependency, and checksum
checks remain fail-closed.

The 0.2.24 idle-CPU fix traced the remaining load to the pinned MCP Swift SDK:
each empty non-blocking stdio pipe was retried every 10 ms. The release build
now applies a reproducible 100 ms backoff to both the bridge and CheICalMCP
sidecar. After stabilization, a 20-second CPU-time sample measured roughly
0.35% for the bridge and 0.2% for CheICalMCP, with Mail and tunnel-client near
0%.

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
- `Sources/MacMCPBridge/SettingsWindow.swift`: production settings UI and model.
- `Sources/MacMCPBridge/MailAccountConfigurationStore.swift`: mail CRUD and validation.
- `Sources/MacMCPBridge/MailAccountAccessStore.swift`: persisted per-account gates.
- `Sources/MacMCPBridge/ChatGPTTunnelAccessStore.swift`: persisted tunnel gate.
- `Sources/MacMCPBridge/ChatGPTTunnelSupervisor.swift`: app-owned tunnel.
- `Sources/MacMCPBridge/TunnelRuntimeLease.swift`: exact-identity tunnel lease.
- `Sources/MacMCPBridge/ClientApprovalStore.swift`: local client approvals.
- `Sources/MacMCPBridge/MailActionAccessStore.swift`: account read-only state.
- `Sources/MacMCPBridge/MCPDataAccess.swift`: Calendar/Reminders MCP gates.
- `Sources/MacMCPBridge/ManagedDraftKeyStore.swift`: draft marker key.
- `Packaging/Patches/mail-mcp-managed-draft-recipients.patch`: recipient-aware
  managed draft overlay applied to the pinned mail sidecar build.
- `Sources/MacMCPBridge/AttachmentTextReader.swift`: bounded text extraction.
- `scripts/release.sh`: normal release entrypoint.
- `scripts/validate-local-mcp.sh`: normal local acceptance gate.
- `scripts/validate-live-acceptance.sh`: manual remote precondition gate.
- `docs/PLAN.md`: only forward-looking plan.
- `docs/KNOWN_ISSUES.md`: current issue register.
- `docs/RELEASING.md`: signing, notarization, and release runbook.

## Recent Commits

- `c880575` Cover settings integration behavior
- `f3302c7` Cover settings menu parity aliases
- `af7e710` Connect settings footer actions
- `f6d43eb` Add ChatGPT tunnel settings
- `8ee76e7` Add real mail account settings
- `2d3a610` Wire settings access controls
- `ef64bfc` Populate settings window from runtime state
- `a0d3b20` Open settings window from menu bar app
- `f4faa53` Add shared SwiftUI settings components
- `68a1ca9` Document settings window integration contract
- `252b995` Support Cask runtime in live validation
- `1db1f5b` Reduce idle MCP transport polling
- `3efb899` Publish MacMCP 0.2.24 Cask
- `ac73a60` Record mail action acceptance
- `90774bd` Record stable ChatGPT updates
- `b5b019b` Make deep IMAP validation opt in
- `f52c749` Prepare MacMCP 0.2.30
- `97f9402` Publish MacMCP 0.2.30 Cask
- `4f1aaad` Prepare MacMCP 0.2.31
- `0a51018` Publish MacMCP 0.2.31 Cask
- `37f31fd` Prepare MacMCP 0.2.32
- `6b32bfc` Publish MacMCP 0.2.32 Cask
