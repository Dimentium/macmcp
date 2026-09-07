# Local Deployment

MacMCP is a macOS-local application. The menu-bar app owns the bridge,
sidecars, Keychain access, EventKit permissions, and optional ChatGPT tunnel.
MCP clients connect through a small local stdio proxy; they do not receive mail
passwords or direct sidecar access.

## Install

The public Homebrew formula installs the source package and exposes one command:

```bash
brew tap Dimentium/macmcp https://github.com/Dimentium/macmcp
brew trust --tap Dimentium/macmcp
brew install macmcp
macmcp setup
```

`macmcp setup` asks for one or more mail accounts and their app-specific
passwords. It supports repeated `--icloud-address`, repeated `--gmail-address`,
and custom `--mail-account` values. It stores passwords in macOS Keychain and
starts `~/Applications/MacMCP.app`.

macOS can ask for Keychain, Calendar, Reminders, and Login Item permissions.
Grant only the capabilities you intend to use.

## Layout

- App: `~/Applications/MacMCP.app`
- Bridge command: `~/.local/bin/macmcp-bridge`
- Mail sidecar: `~/Applications/MacMCP.app/Contents/Resources/mail-mcp`
- EventKit sidecar: `~/Applications/MacMCP.app/Contents/Resources/CheICalMCP`
- Runtime configuration and IPC: `~/Library/Application Support/macmcp/`

There is only one EventKit sidecar copy: the one inside the app bundle.

## Upgrade

```bash
brew update
brew upgrade macmcp
macmcp upgrade
```

The upgrade is staged and rolls back if activation fails. It preserves the
configured accounts, legacy Keychain records, client approvals, per-account
mail action settings, monitor state, and tunnel failure history. It migrates
the canonical layout to `macmcp` automatically.

Because current builds are ad-hoc signed, a replacement can require macOS to
ask for permissions again. Developer ID signing and notarization will remove
this instability from normal upgrades.

## Remove

```bash
macmcp uninstall
brew uninstall macmcp
```

The uninstaller removes the app, local runtime, state, IPC socket, and cached
tunnel wrapper. It preserves Keychain records by default. To remove a specific
mail password or tunnel key as well, use the explicit options printed by
`macmcp uninstall --help`.

## Local MCP Client

The installer writes a ready-to-use example at:

```text
~/.local/opt/macmcp/share/mcp.local.json
```

For Codex:

```bash
codex mcp add macmcp -- \
  "$HOME/.local/bin/macmcp-bridge" \
  --stdio-proxy "$HOME/Library/Application Support/macmcp/mcp.sock"
```

Keep the menu-bar app running. On the first reader-data request, approve the
pending local MCP client from `MacMCP > Clients`. `bridge_status` remains
available before approval.

## ChatGPT Tunnel

The secure tunnel is optional and intended for remote ChatGPT developer-mode
use. Before enabling it, create a tunnel and restricted runtime key in OpenAI
Platform:

- <https://platform.openai.com/settings/organization/tunnels>
- <https://platform.openai.com/api-keys>

Then run:

```bash
brew install openai/tools/tunnel-client
macmcp upgrade --chatgpt-tunnel-id tunnel_YOUR_ID
```

The installer stores the runtime key in Keychain. The MacMCP menu owns the
`tunnel-client` process and shows its status, restart control, and the two
Platform setup links. See [CHATGPT.md](CHATGPT.md) for the ChatGPT-side steps.

## Verification

```bash
macmcp diagnose
```

The output is sanitized: it includes only component states, counts, Login Item
state, and bounded redacted tunnel failures. It excludes mail addresses,
message content, paths, tunnel IDs, and secrets.
