# MacMCP

MacMCP is a local MCP bridge for macOS. It gives an approved MCP client access
to configured mail accounts, Calendar, and Reminders without placing mail
passwords in the client configuration. Mail is read-only by default for every
account. The menu can explicitly enable a narrow, recipient-free draft and
message-flag action surface per account.

The app owns the local runtime, stores secrets in macOS Keychain, and exposes a
MCP endpoint. An optional OpenAI tunnel makes the same endpoint available to
ChatGPT.

For the current engineering state, verified behavior, and continuation notes,
see [docs/HANDOFF.md](docs/HANDOFF.md).

## What It Can Do

- Search and read mail from multiple IMAP accounts, including iCloud Mail and
  Gmail.
- Read supported text attachments.
- Read Calendar events and Reminders through EventKit.
- Provide structured MCP responses for reliable client use.
- Create recipient-free managed drafts and change one message's read/unread or
  flagged/unflagged state after `Read only` is cleared for that account.

MacMCP cannot send, delete, move, or modify calendar events or reminders.
Its only mail mutations are recipient-free managed drafts and the four
per-message state changes, and they remain blocked until the account's `Read
only` control is cleared. Drafts have no recipient fields and cannot be sent.

## Installation

MacMCP has a normal, Homebrew-free installation. Homebrew is optional and is
not needed on the Mac that will actually use the app.

### Recommended: download the release DMG

Use the `MacMCP-<version>-macos.dmg` asset on the [latest GitHub
Release](https://github.com/Dimentium/macmcp/releases). Do not download
`Source code` and do not start with the ZIP unless you specifically want the
Homebrew path.

Requirements: an Apple Silicon Mac running macOS 14 (Sonoma) or later. An
administrator account and Homebrew are not required.

1. Open the downloaded DMG.
2. Drag `MacMCP.app` onto `Applications`. If macOS asks for an administrator
   password, open your Home folder, create `Applications` there if needed, and
   drag the app into that folder instead. `~/Applications` is fully supported.
3. Open `MacMCP` from Applications. If macOS shows a first-launch warning,
   right-click the app, choose `Open`, and confirm once.
4. The MacMCP setup window appears. Mail and the ChatGPT tunnel are optional:
   enable either section only if you need it. For mail, choose Gmail or iCloud
   Mail, enter the address, and enter an app-specific password. The password is
   saved in the macOS Keychain; it is not your normal Google or Apple Account
   password. For ChatGPT, enter the tunnel ID and restricted runtime API key.
5. Leave MacMCP running. Its menu-bar item shows the health of Mail, Calendar,
   and Reminders. `Launch MacMCP at login` is enabled by default.

If you closed the setup window, choose `MacMCP > Mail > Set Up Mail...` or
`MacMCP > ChatGPT Tunnel > Set Up ChatGPT Tunnel...` from the menu-bar item. You
can choose `Set Up Later` when you only need Calendar or Reminders.

To pause personal-data access without stopping MacMCP, open the `Calendar` or
`Reminders` status item and toggle `Allow MCP access`. The switch applies to
local MCP clients and the ChatGPT tunnel immediately; disabled tools disappear
from the next `tools/list` response and cached calls receive a fixed denial.

The optional ChatGPT tunnel is configured later from the MacMCP menu. The
release DMG includes a signed `tunnel-client`, so Homebrew is not needed for
tunnel setup either. It is not needed for local MCP use and must not be a
prerequisite for the first launch.

### Connect a local MCP client

Keep MacMCP running in the menu bar, then add this command to your MCP client.
Replace the app path with `/Applications/MacMCP.app` if you installed it there:

```bash
app="$HOME/Applications/MacMCP.app"
codex mcp add macmcp -- \
  "$app/Contents/MacOS/macmcp-bridge" \
  --stdio-proxy "$HOME/Library/Application Support/macmcp/mcp.sock"
```

On the first data request, choose `MacMCP > Clients > Approve` in the menu-bar
menu. The app must remain running; the client connects to its private local
socket and does not start the mail or EventKit sidecars itself.

### Homebrew (optional)

Homebrew is convenient for repeatable upgrades and for developers, but it is
not required. The signed Cask contains the same prebuilt bridge, mail sidecar,
and EventKit sidecar as the DMG:

```bash
brew tap Dimentium/macmcp https://github.com/Dimentium/macmcp
brew install --cask macmcp
macmcp setup --gmail-address you@gmail.com
```

The Cask also installs the `macmcp` command. Its setup accepts repeatable
`--gmail-address`, `--icloud-address`, and `--mail-account` options. Cask
upgrades retain configuration and Keychain secrets.

### Advanced: source install

Use this path only to inspect or build MacMCP locally. It requires macOS 14 or
later, Xcode Command Line Tools with Swift 6.1 or later, Homebrew, Go 1.25.4 or
later, and network access to the pinned GitHub and Swift package sources.

```bash
brew tap Dimentium/macmcp https://github.com/Dimentium/macmcp
brew install macmcp
macmcp setup --gmail-address you@gmail.com
```

The source formula builds the bridge and both sidecars locally; it does not
download prebuilt runtime binaries. macOS may ask for Keychain, Calendar, or
Reminders access on first use. Grant only the permissions needed for the
features you enable.

## Connect ChatGPT

The default local setup works with local MCP clients. To use MacMCP from
ChatGPT, configure the optional tunnel during setup or reconfiguration.

1. Create a tunnel in the [OpenAI tunnel settings](https://platform.openai.com/settings/organization/tunnels).
2. Create a restricted runtime API key in the [OpenAI Runtime API key settings](https://platform.openai.com/settings/organization/api-keys).
3. Configure the tunnel. The MacMCP menu opens a setup window where you enter
   the tunnel ID and restricted runtime API key. The release DMG already
   includes the signed `tunnel-client`; Homebrew is optional.

   ```bash
   # Optional CLI equivalent for a Homebrew install
   macmcp configure --gmail-address you@gmail.com \
     --chatgpt-tunnel-id tunnel_YOUR_ID
   ```

   For a DMG install, use `MacMCP > ChatGPT Tunnel > Set Up ChatGPT Tunnel...`.
   This requests the runtime key once and stores it in Keychain; the tunnel ID
   is stored in MacMCP configuration. The menu owns tunnel startup and offers
   restart, reconfiguration, key replacement, and disable controls.
4. Add the resulting MacMCP connector in ChatGPT's Apps and Connectors
   settings. ChatGPT Work is the currently validated client. The advertised
   mail-action tools use the same tunnel but return a clear disabled error
   until `Mail > account > Read only` is cleared locally.

The tunnel is optional. Do not create or configure it when local-only MCP use
is sufficient.

## Daily Use

Use the menu-bar item to inspect component health, approve local MCP clients,
quickly enable or disable Calendar and Reminders MCP access, manage account-level
`Read only`, and manage the optional tunnel.
For a Homebrew installation, `Updates` checks the latest GitHub Release at
launch and every six hours. It enables `Update to <version>` only after a newer
release is confirmed. That command refreshes Homebrew, upgrades the Cask, and
restarts MacMCP. For a DMG installation, download the next DMG, quit MacMCP,
replace the app in the same Applications folder, and open it again; settings
and Keychain secrets remain outside the app.

For a privacy-safe support snapshot, run:

```bash
# Homebrew installation
macmcp diagnose

# DMG installation (choose the path you used)
"$HOME/Applications/MacMCP.app/Contents/Resources/macmcp" diagnose
```

The report includes component states and restart counts, configuration counts,
client-approval counts, Login Item state, tunnel health, and up to 12 recent
tunnel failures. Each tunnel record has only a timestamp, fixed phase, and
fixed reason. It excludes email addresses, client names, paths, tunnel IDs,
command output, and secrets.

For a complete local MCP smoke test from a checkout, run:

```bash
scripts/validate-local-mcp.sh
```

It checks the installed app-owned bridge, all published tools and output
schemas, Mail folder/search/read access, Calendar, and Reminders. It
deliberately skips the ChatGPT tunnel and does not create or modify mail data.

When the ChatGPT tunnel is configured, `ChatGPT Tunnel > Open Tunnel Log` opens
`~/Library/Logs/MacMCP/chatgpt-tunnel.log`. The app keeps the active log and up
to four rotated files; each file is capped at 10 MiB. Its one-line records are
readable in Console and include timestamp, level, source, component, message,
and safe status fields. Routine startup noise is omitted. MacMCP records only
valid structured tunnel events and its own lifecycle messages; it discards all
unstructured tunnel output. The log never contains MCP payloads, mail data,
headers, tunnel IDs, or credentials.

`ChatGPT Tunnel > Open Tunnel Proxy Log` opens
`~/Library/Logs/MacMCP/chatgpt-tunnel-proxy.log`. It records only each remote
tool category (`mail`, `calendar`, `reminders`, or `bridge_status`) and whether
the local proxy sent back an MCP result. It never records arguments, request
IDs, or result content.

## Updates And Removal

Update a Homebrew installation:

```bash
brew update
brew upgrade --cask macmcp
```

For the advanced source formula use `brew upgrade macmcp` instead.

Remove MacMCP:

```bash
macmcp uninstall
brew uninstall macmcp
```

For a DMG installation, quit MacMCP and move `MacMCP.app` from your
Applications folder to the Trash. Its configuration and Keychain entries are
left in place so a later reinstall can continue where you stopped.

The source formula remains supported after the Cask is published. The Developer
ID release pipeline is one numbered command, documented in
[docs/RELEASING.md](docs/RELEASING.md).

## Third-Party Components

MacMCP directly uses the following upstream projects:

| Component | Purpose | License | Source |
| --- | --- | --- | --- |
| [mail-mcp](https://github.com/Dimentium/mail-mcp) v1.2.5 | IMAP mail sidecar for iCloud Mail and Gmail, including the iCloud folder-list fallback and authenticated managed drafts | MIT | [MacMCP fork](https://github.com/Dimentium/mail-mcp), based on [upstream](https://github.com/kacperkwapisz/mail-mcp) |
| [che-ical-mcp](https://github.com/PsychQuant/che-ical-mcp) v1.16.1 | EventKit Calendar and Reminders sidecar | MIT | [upstream](https://github.com/PsychQuant/che-ical-mcp) |
| [MCP Swift SDK](https://github.com/modelcontextprotocol/swift-sdk) | Local MCP server implementation | MIT / Apache-2.0 | [upstream](https://github.com/modelcontextprotocol/swift-sdk) |
| [Swift System](https://github.com/apple/swift-system) | Swift system interfaces | Apache-2.0 | [upstream](https://github.com/apple/swift-system) |
| [OpenAI tunnel-client](https://github.com/openai/tunnel-client) | Optional ChatGPT Secure MCP Tunnel runtime | Apache-2.0 | [upstream](https://github.com/openai/tunnel-client) |

The exact sidecar revisions are recorded in
[UPSTREAMS.lock.json](UPSTREAMS.lock.json); direct and transitive Swift package
revisions are pinned in [Package.resolved](Package.resolved). The signed
release app embeds the pinned OpenAI `tunnel-client` runtime and its companion
files. A signed app bundle includes the corresponding full license texts under
`Contents/Resources/ThirdPartyNotices`.

## Security Model

- Mail passwords and tunnel keys are stored in Keychain, not in the repository
  or MCP-client configuration.
- Each local MCP client needs approval from MacMCP before it can use data tools.
- A per-account `Read only` control fails closed. It gates mail actions for all
  transports, including local MCP clients and the ChatGPT tunnel, and can be
  turned on again immediately without restarting MacMCP.
- Managed drafts carry an HMAC marker derived from a Keychain key. Drafts with
  recipients, an invalid marker, or a stale revision cannot be edited.
- The bridge does not expose arbitrary shell, file-system, or automation tools.
- The tunnel uses an explicit restricted runtime key and can be disabled at any
  time from the menu.

See [docs/NAMING.md](docs/NAMING.md) for canonical component names,
[docs/KNOWN_ISSUES.md](docs/KNOWN_ISSUES.md) for known limitations, and
[docs/PLAN.md](docs/PLAN.md) for the current engineering priorities.
