# MacMCP

MacMCP is a local MCP bridge for macOS. It gives an approved MCP client access
to configured mail accounts, Calendar, and Reminders without placing mail
passwords in the client configuration. Mail is read-only by default for every
account. The menu can explicitly enable a narrow, recipient-free draft and
message-flag action surface per account.

The app owns the local runtime, stores secrets in macOS Keychain, and exposes a
MCP endpoint. An optional OpenAI tunnel makes the same endpoint available to
ChatGPT.

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

MacMCP has two installation paths: a signed Cask for normal use and a source
installation for inspection and local builds.

### Source Install

Choose this path to inspect and build the runtime locally. It requires:

- macOS 14 or later;
- Xcode Command Line Tools with Swift 6.1 or later (`xcode-select --install`);
- Homebrew;
- outbound access to GitHub, the Go module proxy, and the pinned Swift package
  repositories during setup.

The formula pulls Go and Python 3 as dependencies; `mail-mcp` requires Go
1.25.4 or later. The setup then downloads this source package, checks out the
pinned `mail-mcp` and `CheICalMCP` source commits, verifies their Go and Swift
dependency graphs, and builds all three MacMCP executables locally. It does
not download a prebuilt `mail-mcp` or EventKit runtime binary.

Install and configure it with:

```bash
brew tap Dimentium/macmcp https://github.com/Dimentium/macmcp
brew trust --tap Dimentium/macmcp
brew install macmcp
macmcp setup --gmail-address you@gmail.com
```

`macmcp setup` installs the app, prompts for the account app password, and
starts first-run configuration. Use `--icloud-address` for iCloud Mail or
`--mail-account` for a custom IMAP account; account options may be repeated.
The implementation scripts remain internal. After installation, the MacMCP
menu-bar item shows bridge, mail, Calendar, Reminders, client approvals,
and the optional tunnel. Open `Mail > account` to keep an account read-only or
allow its limited mail actions. The control applies immediately and persists
across app restarts.

macOS may ask for Keychain, Calendar, or Reminders access on first use. Grant
only the permissions needed for the features you enable.

### Signed Cask

The Cask downloads one prebuilt, Developer ID-signed and Apple-notarized
`MacMCP.app` from GitHub Releases. It currently requires an
Apple Silicon Mac running macOS 14 or later. It contains the bridge, mail
sidecar, and EventKit sidecar, so it will not need Swift, Go, or source
checkouts on the target Mac. The first launch will still need account setup and
the macOS permissions required by the enabled features.

Install it with:

```bash
brew tap Dimentium/macmcp https://github.com/Dimentium/macmcp
brew install --cask macmcp
macmcp setup --gmail-address you@gmail.com
```

`macmcp setup` prompts for the app password, stores it in Keychain, registers
the Login Item, and opens the app. It accepts repeatable `--gmail-address`,
`--icloud-address`, and `--mail-account` options. Adding
`--chatgpt-tunnel-id tunnel_YOUR_ID` installs `tunnel-client` when needed and
prompts once for the restricted runtime API key. Cask upgrades use
`macmcp upgrade` or `brew upgrade --cask macmcp` and retain configuration and
Keychain secrets.

## Connect ChatGPT

The default local setup works with local MCP clients. To use MacMCP from
ChatGPT, configure the optional tunnel during setup or reconfiguration.

1. Create a tunnel in the [OpenAI tunnel settings](https://platform.openai.com/settings/organization/tunnels).
2. Create a restricted runtime API key in the [OpenAI API key settings](https://platform.openai.com/api-keys).
3. Configure the tunnel. The Cask wrapper installs `tunnel-client` when needed:

   ```bash
   # Source installation with an existing configured runtime
   macmcp upgrade --chatgpt-tunnel-id tunnel_YOUR_ID

   # Cask installation, including the configured account again
   macmcp configure --gmail-address you@gmail.com \
     --chatgpt-tunnel-id tunnel_YOUR_ID
   ```

   This requests the runtime key once and stores it in Keychain; the tunnel ID
   is stored in MacMCP configuration. The menu owns tunnel startup and offers
   restart and key replacement controls.
5. Add the resulting MacMCP connector in ChatGPT's Apps and Connectors
   settings. ChatGPT Work is the currently validated client. The advertised
   mail-action tools use the same tunnel but return a clear disabled error
   until `Mail > account > Read only` is cleared locally.

The tunnel is optional. Do not create or configure it when local-only MCP use
is sufficient.

## Daily Use

Use the menu-bar item to inspect component health, approve local MCP clients,
manage account-level `Read only`, and manage the optional tunnel.
For a Cask installation, `Updates` checks the latest GitHub Release at launch
and every six hours. It enables `Update to <version>` only after a newer release
is confirmed. That explicit command refreshes Homebrew, upgrades the Cask, and
restarts MacMCP. Source installs continue to use their normal Homebrew upgrade.

For a privacy-safe support snapshot, run:

```bash
macmcp diagnose
```

The report includes component states and restart counts, configuration counts,
client-approval counts, Login Item state, tunnel health, and up to 12 recent
tunnel failures. Each tunnel record has only a timestamp, fixed phase, and
fixed reason. It excludes email addresses, client names, paths, tunnel IDs,
command output, and secrets.

When the ChatGPT tunnel is configured, `ChatGPT Tunnel > Open Tunnel Log` opens
`~/Library/Logs/MacMCP/chatgpt-tunnel.log`. The app keeps the active log and up
to four rotated files; each file is capped at 10 MiB. Its one-line records are
readable in Console and include timestamp, level, source, component, message,
and safe status fields. Routine tunnel startup noise is omitted. The log never
contains MCP payloads, mail data, headers, tunnel IDs, or credentials.

## Updates And Removal

Update the source package and the installed runtime:

```bash
brew update
brew upgrade macmcp
macmcp upgrade
```

Remove MacMCP:

```bash
macmcp uninstall
brew uninstall macmcp
```

The source formula remains supported after the Cask is published. The Developer
ID release pipeline is documented in [docs/RELEASING.md](docs/RELEASING.md).

## Third-Party Components

MacMCP directly uses the following upstream projects:

| Component | Purpose | License | Source |
| --- | --- | --- | --- |
| [mail-mcp](https://github.com/Dimentium/mail-mcp) v1.2.2 | IMAP mail sidecar for iCloud Mail and Gmail, including the iCloud folder-list fallback and authenticated managed drafts | MIT | [MacMCP fork](https://github.com/Dimentium/mail-mcp), based on [upstream](https://github.com/kacperkwapisz/mail-mcp) |
| [che-ical-mcp](https://github.com/PsychQuant/che-ical-mcp) v1.16.1 | EventKit Calendar and Reminders sidecar | MIT | [upstream](https://github.com/PsychQuant/che-ical-mcp) |
| [MCP Swift SDK](https://github.com/modelcontextprotocol/swift-sdk) | Local MCP server implementation | MIT / Apache-2.0 | [upstream](https://github.com/modelcontextprotocol/swift-sdk) |
| [Swift System](https://github.com/apple/swift-system) | Swift system interfaces | Apache-2.0 | [upstream](https://github.com/apple/swift-system) |

The exact sidecar revisions are recorded in
[UPSTREAMS.lock.json](UPSTREAMS.lock.json); direct and transitive Swift package
revisions are pinned in [Package.resolved](Package.resolved). `tunnel-client`
is an optional, separately installed OpenAI component and is not included in a
MacMCP release. A signed app bundle includes the corresponding full license
texts under `Contents/Resources/ThirdPartyNotices`.

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
