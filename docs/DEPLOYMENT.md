# Local Deployment

MacMCP is a macOS-local application. The menu-bar app owns the bridge,
sidecars, Keychain access, EventKit permissions, and optional ChatGPT tunnel.
MCP clients connect through a small local stdio proxy; they do not receive mail
passwords or direct sidecar access.

## Direct install from GitHub Releases (recommended)

Download `MacMCP-<version>-macos.dmg` from the [latest GitHub
Release](https://github.com/Dimentium/macmcp/releases). The DMG contains the
Developer ID-signed and Apple-notarized app, the bridge, both sidecars, and a
signed `tunnel-client`. The target Mac does not need Swift, Go, Homebrew, or
administrator access.

Open the DMG and drag `MacMCP.app` to `Applications`. If `/Applications`
requires an administrator password, put it in `~/Applications` instead; create
that folder in your Home folder if necessary. Open the app from there. A
first-launch setup window lets the user optionally configure Gmail or iCloud
Mail and/or the ChatGPT tunnel. Mail passwords and tunnel keys are stored in
macOS Keychain.

If the setup window was closed, choose `MacMCP > Open Settings...` and
configure mail or the ChatGPT tunnel there. Choose `Set Up Later` during first
launch when only Calendar or Reminders are needed.

macOS can ask for Keychain, Calendar, Reminders, and Login Item permissions.
Grant only the capabilities you intend to use.

## Homebrew Cask (optional)

The signed Cask is convenient for command-line setup and repeatable upgrades:

```bash
brew tap Dimentium/macmcp https://github.com/Dimentium/macmcp
brew install --cask macmcp
macmcp setup --gmail-address you@gmail.com
```

`macmcp setup` asks for the app-specific password for each configured account.
It supports repeated `--icloud-address`, repeated `--gmail-address`, and
custom `--mail-account` values. It stores passwords in macOS Keychain and
starts `/Applications/MacMCP.app`. The Cask and the DMG use the same prebuilt
runtime.

On its first launch, `0.2.5` or later imports a legacy `mac-agent-bridge`
configuration when present. Mail accounts, Keychain-backed secrets, mail action
settings, and the ChatGPT tunnel configuration are retained. The
legacy local MCP proxy is deliberately not trusted by the new app, so approve
the new proxy once with `macmcp-bridge --approve-pending-client`.

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
- Direct app (without admin rights): `~/Applications/MacMCP.app`
- Direct app bridge: `~/Applications/MacMCP.app/Contents/MacOS/macmcp-bridge`
- Direct app CLI: `~/Applications/MacMCP.app/Contents/Resources/macmcp`
- Source app: `~/Applications/MacMCP.app` (same location, ad-hoc signed)
- Source bridge: `~/.local/bin/macmcp-bridge`
- Runtime configuration and IPC: `~/Library/Application Support/macmcp/`

There is only one EventKit sidecar copy: the one inside the app bundle.

## Upgrade

For a direct DMG installation, download the next DMG, quit MacMCP, replace the
app in the same Applications folder, and open it again. Configuration and
Keychain secrets live outside the app and are retained.

For Homebrew:

```bash
brew update
brew upgrade --cask macmcp
```

Use `brew upgrade macmcp` for the source formula. Cask upgrades retain the
configuration and Keychain secrets outside the app bundle. The signed Cask has
a stable Developer ID identity; source-install replacements remain ad-hoc
signed and may need macOS permissions again.

The Homebrew Cask menu-bar app checks the latest GitHub Release at launch and
every six hours. Its `Updates` submenu can refresh Homebrew, install the Cask
update, and restart the app. A direct DMG install does not silently replace the
app; update it by downloading the new DMG.

## Remove

```bash
macmcp uninstall
brew uninstall --cask macmcp
```

For a source install use `brew uninstall macmcp`. Cask removal preserves
Keychain records and configuration; add `--zap` to remove configuration and
caches as well. For a direct DMG install, quit MacMCP and move the app to the
Trash; configuration and Keychain records are preserved for a later reinstall.

## Local MCP Client

For Codex:

```bash
codex mcp add macmcp -- \
  "$HOME/Applications/MacMCP.app/Contents/MacOS/macmcp-bridge" \
  --stdio-proxy "$HOME/Library/Application Support/macmcp/mcp.sock"
```

Use `/Applications/MacMCP.app` in that command if you installed there.

Keep the menu-bar app running. On the first reader-data request, approve the
pending local MCP client with `macmcp-bridge --approve-pending-client`.
`bridge_status` remains available before approval.

## ChatGPT Tunnel

The secure tunnel is optional and intended for remote ChatGPT developer-mode
use. Before enabling it, create a tunnel and restricted runtime key in OpenAI
Platform:

- <https://platform.openai.com/settings/organization/tunnels>
- <https://platform.openai.com/settings/organization/api-keys>

For a Homebrew installation, run:

```bash
brew install openai/tools/tunnel-client
macmcp configure --gmail-address you@example.com \
  --chatgpt-tunnel-id tunnel_YOUR_ID
```

For a direct DMG installation, open `MacMCP > Open Settings...` and use the
ChatGPT Tunnel settings gear. The release DMG includes a signed
`tunnel-client`, so neither Homebrew nor administrator access is needed:

```bash
open "$HOME/Applications/MacMCP.app"
```

The setup window stores the runtime key in Keychain and the tunnel ID in the
MacMCP configuration. The MacMCP menu owns the bundled `tunnel-client` process
and shows its status, restart, reconfiguration, disable control, and the two
Platform setup links. See [CHATGPT.md](CHATGPT.md) for the ChatGPT-side steps.

## Verification

```bash
# Homebrew installation
macmcp diagnose

# Direct DMG installation
"$HOME/Applications/MacMCP.app/Contents/Resources/macmcp" diagnose
```

The output is sanitized: it includes only component states, counts, Login Item
state, and bounded redacted tunnel failures. It excludes mail addresses,
message content, paths, tunnel IDs, and secrets.

From a MacMCP checkout, run the local MCP acceptance test as well:

```bash
scripts/validate-local-mcp.sh
```

This exercises the app-owned local stdio proxy and all three local data
components, including Mail folder/search/read calls. It does not start or test
the ChatGPT tunnel; remote connector behavior is a separate product-surface
check.
