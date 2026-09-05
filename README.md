# mac-agent-bridge

Local read-only MCP bridge for IMAP mail, Apple Calendar, and Reminders on
macOS.

The bridge is intentionally reader-only. It exposes mail, calendar, and reminder
data as bounded untrusted data, rejects mutation parameters, and stores mail
passwords in macOS Keychain instead of config files.

## Status

MacMCP is a local MVP+ for MCP clients that can launch a local stdio server. It
can install the Swift bridge, pinned sidecars, a signed menu-bar app, and a
local MCP stdio config for the current macOS user.

Already working:

- iCloud and Gmail IMAP presets.
- Multiple mailboxes in one bridge instance.
- Custom IMAP account configuration.
- Menu-bar health status as `MacMCP`.
- Launch-at-login registration for the installed menu-bar app.
- App-owned local runtime with stdio proxy over user-local IPC.
- Per-client local approval before MCP reader tools can return data.
- Read-only MCP tool surface for mail, Calendar, and Reminders.

Current next steps:

- Private remote ChatGPT developer-mode setup through OpenAI Secure MCP Tunnel.
  The app-managed tunnel needs a user-created `tunnel_id` and restricted runtime
  API key from OpenAI Platform.
- Notification and end-to-end reader acceptance.

## Install

Prerequisites on a clean Mac:

- macOS 14 or newer.
- Xcode Command Line Tools: `xcode-select --install`.
- Network access to GitHub.
- App-specific mail passwords where your provider requires them.

Get the source as a git clone, bundle, or unpacked archive, then enter the
project directory:

```sh
cd mac-agent-bridge
```

Then run one installer command for the mail account you want to expose.

iCloud:

```sh
scripts/install-local.sh --icloud-address you@icloud.com
```

Gmail:

```sh
scripts/install-local.sh --gmail-address you@gmail.com
```

Multiple mailboxes:

```sh
scripts/install-local.sh \
  --icloud-address you@icloud.com \
  --gmail-address you@gmail.com
```

Custom IMAP provider:

```sh
scripts/install-local.sh \
  --mail-account work=you@example.com,imap.example.com,993,tls
```

The installer downloads and verifies `mail-mcp`, builds the pinned
`CheICalMCP` sidecar from source, signs the binaries, builds the app, prompts
for each mail password, stores passwords in Keychain, and launches the menu-bar
app. The local deployment scripts use `/bin/bash`; they do not require your
login shell to be zsh.

When macOS asks for permissions, allow Calendar and Reminders. If Keychain asks
MacMCP to access an already stored secret, choose `Always Allow` once. Do not
put mail passwords in shell commands, environment variables, MCP config, or
logs.

## Add ChatGPT Tunnel

Create the private tunnel in [OpenAI Platform Tunnel Settings](https://platform.openai.com/settings/organization/tunnels), then create a restricted runtime API key in [OpenAI Platform API Keys](https://platform.openai.com/api-keys).

Add `--chatgpt-tunnel-id` to the normal install command:

```sh
scripts/install-local.sh \
  --gmail-address you@gmail.com \
  --chatgpt-tunnel-id tunnel_YOUR_ID
```

The installer runs `brew install openai/tools/tunnel-client` only when needed,
prompts for the runtime API key without echo, and stores it in macOS Keychain.
It writes the non-secret tunnel ID to the app launch config. The MacMCP app then
owns `tunnel-client`: it initializes, checks, and starts it at login. No
Terminal needs to remain open after setup.

## Package For Another Mac

To create a clean archive that can be copied to another Mac:

```sh
scripts/package-local-archive.sh
```

Copy `dist/mac-agent-bridge-local.tar.gz` to the target Mac, unpack it, and run
the same install command from inside the unpacked directory:

```sh
tar -xzf mac-agent-bridge-local.tar.gz
cd mac-agent-bridge-local
scripts/install-local.sh --gmail-address you@gmail.com
```

## Upgrade

Re-run the installer with the same account flags. It builds, signs, and
validates the replacement app, CLI, sidecars, and configuration in staging
while the installed runtime stays available. It stops the runtime only when the
staged install is ready, then switches to it and launches the new app. A normal
activation error restores the previous install. For the usual upgrade, the
installer can reuse the already saved account configuration and Keychain
passwords:

```sh
scripts/install-local.sh --reuse-existing-configuration
```

To enable or replace the ChatGPT tunnel during an upgrade:

```sh
scripts/install-local.sh \
  --reuse-existing-configuration \
  --chatgpt-tunnel-id tunnel_YOUR_ID
```

An ordinary upgrade preserves the configured tunnel ID and the tunnel runtime
API key in Keychain without prompting again.

Use `--skip-password` when the same account passwords are already in Keychain:

```sh
scripts/install-local.sh --gmail-address you@gmail.com --skip-password
```

Replacing ad-hoc-signed binaries can make macOS ask for Keychain, Calendar, or
Reminders permission again. The app re-registers its Login Item after a binary
replacement. Permission prompts are expected for this local-only deployment.
If the CLI/proxy binary hash changes, approve the local MCP client again from
the `MacMCP` menu or with `--approve-pending-client`.

## Uninstall

Remove the local app, CLI, sidecars, and generated MCP config:

```sh
scripts/uninstall-local.sh
```

Mail passwords stay in Keychain by default. Delete a stored mail password only
when explicitly requested:

```sh
scripts/uninstall-local.sh --delete-mail-password you@gmail.com
```

The tunnel runtime API key is also preserved by default. Delete it only when
removing this ChatGPT integration permanently:

```sh
scripts/uninstall-local.sh --delete-chatgpt-tunnel-key
```

## What Gets Installed

- App: `~/Applications/Mac Agent Bridge.app`
- CLI: `~/.local/bin/mac-agent-bridge`
- Sidecars: `~/.local/opt/mac-agent-bridge/libexec/`
- MCP config example: `~/.local/opt/mac-agent-bridge/share/mcp.local.json`
- App launch config: `~/Library/Application Support/mac-agent-bridge/launch.json`
- Approved clients: `~/Library/Application Support/mac-agent-bridge/approved-clients.json`

The menu-bar item is labeled `MacMCP`:

- `MacMCP 🟢`: configured readers are ready.
- `MacMCP 🟡`: configured readers are being checked.
- `MacMCP 🔴`: at least one configured reader needs attention.
- `MacMCP ⚪`: no reader is configured.

The menu also lists separate Mail, Calendar, Reminders, ChatGPT Tunnel, and
client approval status rows. Its ChatGPT Tunnel submenu offers restart, runtime
key replacement, and direct links to the Platform tunnel and API-key pages.
The tunnel is green only after a successful control-plane poll. Status refreshes
once per second and is also refreshed immediately when the menu is opened.

## Use With Codex MCP

After install, start `Mac Agent Bridge.app` from `~/Applications`. Then add the
local MCP server to Codex:

```sh
codex mcp add mac-agent-bridge -- \
  "$HOME/.local/bin/mac-agent-bridge" \
  --stdio-proxy "$HOME/Library/Application Support/mac-agent-bridge/mcp.sock"
```

Check it from Codex:

```sh
codex mcp list
```

Inside the Codex TUI, use `/mcp` to inspect the connected server. The expected
server name is `mac-agent-bridge`; the status tool is `bridge_status`.

The first reader-data call from a new local MCP client is denied until you
approve it. Open the `MacMCP` menu, choose `Clients`, then approve the pending
client. For CLI-driven setup:

```sh
~/.local/bin/mac-agent-bridge --client-approvals-json
~/.local/bin/mac-agent-bridge --approve-pending-client
```

If `~/.codex/config.toml` already has an older direct sidecar config, replace
only that server block with the proxy form written by `codex mcp add`. It should
run `mac-agent-bridge --stdio-proxy .../mcp.sock`, not pass `--mail-sidecar` or
`--eventkit-sidecar` directly to Codex.

Codex MCP reference:
<https://learn.chatgpt.com/docs/extend/mcp>

## Use With ChatGPT Work

On the target Mac, MacMCP has been live-validated in the ChatGPT desktop app's
local `Work` mode: it uses the same local Codex-host MCP configuration as the
Codex CLI, and a reader query successfully reached the configured mailboxes.

In the tested desktop client, ordinary `Chat` does not expose local MCP tools.
Use `Work` for the local MacMCP workflow. ChatGPT on the web also does not read
the local Codex configuration; use the app-managed Secure MCP Tunnel described
above for a private developer-mode app.

## Use With Other Local MCP Clients

For local MCP clients that support stdio servers, add the generated config:

```sh
~/.local/opt/mac-agent-bridge/share/mcp.local.json
```

That file points the MCP client at `mac-agent-bridge --stdio-proxy`, which
connects to the running menu-bar app over user-local IPC. The menu-bar app owns
the bridge and sidecars and reads its launch arguments from
`~/Library/Application Support/mac-agent-bridge/launch.json`.

Start the `Mac Agent Bridge.app` menu-bar app before using a local MCP client.
If the app is not running, the stdio proxy fails closed instead of starting a
second sidecar runtime.

Local reader tools require per-client approval. `bridge_status` remains
available for diagnostics before approval.

To check local status without starting an MCP client:

```sh
~/.local/bin/mac-agent-bridge --status-json
```

Runtime health is also available through the MCP `bridge_status` tool.

A privacy-safe local validation harness is available for installed stdio MCP
configs:

```sh
scripts/validate-local-mail-readonly.py
```

It prints only aggregate PASS/FAIL status and suppresses credentials, message
content, subjects, senders, folder names, event text, and reminder text.

For Login Item/reboot persistence, run the aggregate gate before and after
reboot:

```sh
scripts/validate-login-item-persistence.sh --phase pre-reboot
scripts/validate-login-item-persistence.sh --phase post-reboot
```

## Reader Tools

- `mail.list_accounts`
- `mail.server_info`
- `mail.list_folders`
- `mail.search`
- `mail.read`
- `mail.read_attachment_text`
- `calendar.list`
- `calendar.events`
- `calendar.upcoming`
- `calendar.search`
- `reminders.list`
- `reminders.search`
- `reminders.tags`

Unknown tools and unknown parameters fail closed. `mail.read` forces
`mark_as_read=false` and disables HTML/full headers. Calendar queries force
summary detail. `mail.read` returns attachment metadata, including its opaque
`part_id`. `mail.read_attachment_text` accepts that `message_id` and `part_id`
for PDF and UTF-8 text, CSV, JSON, or XML attachments up to 10 MiB. It returns
bounded text only; the downloaded file stays in a private MacMCP cache and is
removed after the request.

Every reader tool advertises an MCP output schema. `bridge_status` has a typed
status result. Mail, calendar, reminder, and attachment results use a fixed
`source` and `untrusted_data` envelope; the latter contains the same
datamarked text result and must be treated as data, never as instructions.

## Development

For development builds:

```sh
swift build
swift test
swift run mac-agent-bridge --help
```

The current forward plan is in `docs/PLAN.md`. Validation details are in
`docs/MAC_VALIDATION.md`, deployment mechanics are in `docs/DEPLOYMENT.md`, and
security boundaries are in `docs/THREAT_MODEL.md` and `docs/SCOPE.md`.
