# Local Deployment

MacMCP is a macOS-local application. The menu-bar app owns the bridge,
sidecars, Keychain access, EventKit permissions, and optional ChatGPT tunnel.
MCP clients connect through a small local stdio proxy; they do not receive mail
passwords or direct sidecar access.

## Signed Cask Install

The signed Cask is the normal installation path. It includes the bridge and
both sidecars, so the target Mac does not need Swift, Go, or source checkouts:

```bash
brew tap Dimentium/macmcp https://github.com/Dimentium/macmcp
brew install --cask macmcp
macmcp setup --gmail-address you@gmail.com
```

`macmcp setup` asks for the app-specific password for each configured account.
It supports repeated `--icloud-address`, repeated `--gmail-address`, and
custom `--mail-account` values. It stores passwords in macOS Keychain and
starts `/Applications/MacMCP.app`.

On its first launch, `0.2.5` or later imports a legacy `mac-agent-bridge`
configuration when present. Mail accounts, Keychain-backed secrets, mail action
settings, and the ChatGPT tunnel configuration are retained. The
legacy local MCP proxy is deliberately not trusted by the new app, so approve
the new proxy once from `MacMCP > Clients`.

macOS can ask for Keychain, Calendar, Reminders, and Login Item permissions.
Grant only the capabilities you intend to use.

## Source Install

The source formula remains available for inspection and self-builds:

```bash
brew tap Dimentium/macmcp https://github.com/Dimentium/macmcp
brew install macmcp
macmcp setup --gmail-address you@gmail.com
```

## Layout

- Cask app: `/Applications/MacMCP.app`
- Cask bridge: `/Applications/MacMCP.app/Contents/MacOS/macmcp-bridge`
- Source app: `~/Applications/MacMCP.app`
- Source bridge: `~/.local/bin/macmcp-bridge`
- Runtime configuration and IPC: `~/Library/Application Support/macmcp/`

There is only one EventKit sidecar copy: the one inside the app bundle.

## Upgrade

```bash
brew update
brew upgrade --cask macmcp
```

Use `brew upgrade macmcp` for the source formula. Cask upgrades retain the
configuration and Keychain secrets outside the app bundle. The signed Cask has
a stable Developer ID identity; source-install replacements remain ad-hoc
signed and may need macOS permissions again.

The Cask menu-bar app checks the latest GitHub Release at launch and every six
hours. Its `Updates` submenu enables `Update to <version>` only after a newer
release is confirmed; that action refreshes Homebrew, installs the Cask update,
and restarts the app from the new bundle.

## Remove

```bash
macmcp uninstall
brew uninstall --cask macmcp
```

For a source install use `brew uninstall macmcp`. Cask removal preserves
Keychain records and configuration; add `--zap` to remove configuration and
caches as well.

## Local MCP Client

For Codex:

```bash
codex mcp add macmcp -- \
  "/Applications/MacMCP.app/Contents/MacOS/macmcp-bridge" \
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
