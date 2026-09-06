# MacMCP

MacMCP is a local MCP bridge for macOS. It gives an approved MCP client
read-only access to configured mail accounts, Calendar, and Reminders without
placing mail passwords in the client configuration.

The app owns the local runtime, stores secrets in macOS Keychain, and exposes a
single local MCP endpoint. An optional OpenAI tunnel makes that endpoint
available to ChatGPT.

## What It Can Do

- Search and read mail from multiple IMAP accounts, including iCloud Mail and
  Gmail.
- Read supported text attachments.
- Read Calendar events and Reminders through EventKit.
- Provide structured MCP responses for reliable client use.

MacMCP is intentionally read-only. It cannot send, delete, move, or modify
mail, calendar events, or reminders.

## Installation

Install the source package through Homebrew:

```bash
brew tap Dimentium/macmcp https://github.com/Dimentium/macmcp
brew trust Dimentium/macmcp
brew install macmcp
macmcp setup
```

`macmcp setup` installs the app and starts first-run configuration. It is the
only setup command users need to run; the implementation scripts remain
internal. After installation, use the MacMCP menu-bar item to add mail accounts
and inspect the bridge, mail, Calendar, Reminders, client approvals, and the
optional tunnel.

macOS may ask for Keychain, Calendar, or Reminders access on first use. Grant
only the permissions needed for the features you enable.

## Connect ChatGPT

The default local setup works with local MCP clients. To use MacMCP from
ChatGPT, configure the optional tunnel from the MacMCP menu.

1. Create a tunnel in the [OpenAI tunnel settings](https://platform.openai.com/settings/organization/tunnels).
2. Create a restricted runtime API key in the [OpenAI API key settings](https://platform.openai.com/api-keys).
3. Install the OpenAI tunnel client once:

   ```bash
   brew install openai/tools/tunnel-client
   ```

4. In the MacMCP menu, configure the tunnel ID and runtime key, then start the
   tunnel. The key is stored in Keychain; the tunnel ID is stored in MacMCP
   configuration.
5. Add the resulting MacMCP connector in ChatGPT's Apps and Connectors
   settings. ChatGPT Work is the currently validated client.

The tunnel is optional. Do not create or configure it when local-only MCP use
is sufficient.

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

The source formula is an interim package. It will be replaced by a signed and
notarized MacMCP cask when the release pipeline is available.

## Third-Party Components

MacMCP directly uses the following upstream projects:

| Component | Purpose | License | Source |
| --- | --- | --- | --- |
| [mail-mcp](https://github.com/Dimentium/mail-mcp) v1.1.1 | IMAP mail sidecar for iCloud Mail and Gmail, including the iCloud folder-list fallback | MIT | [MacMCP fork](https://github.com/Dimentium/mail-mcp), based on [upstream](https://github.com/kacperkwapisz/mail-mcp) |
| [che-ical-mcp](https://github.com/PsychQuant/che-ical-mcp) v1.16.1 | EventKit Calendar and Reminders sidecar | MIT | [upstream](https://github.com/PsychQuant/che-ical-mcp) |
| [MCP Swift SDK](https://github.com/modelcontextprotocol/swift-sdk) | Local MCP server implementation | MIT | [upstream](https://github.com/modelcontextprotocol/swift-sdk) |
| [Swift System](https://github.com/apple/swift-system) | Swift system interfaces | Apache-2.0 | [upstream](https://github.com/apple/swift-system) |

The exact sidecar revisions are recorded in
[UPSTREAMS.lock.json](UPSTREAMS.lock.json); direct and transitive Swift package
revisions are pinned in [Package.resolved](Package.resolved). `tunnel-client`
is an optional, separately installed OpenAI component and is not included in a
MacMCP release.

## Security Model

- Mail passwords and tunnel keys are stored in Keychain, not in the repository
  or MCP-client configuration.
- Each local MCP client needs approval from MacMCP before it can use data tools.
- The bridge does not expose arbitrary shell, file-system, or automation tools.
- The tunnel uses an explicit restricted runtime key and can be disabled at any
  time from the menu.

See [docs/NAMING.md](docs/NAMING.md) for canonical component names,
[docs/KNOWN_ISSUES.md](docs/KNOWN_ISSUES.md) for known limitations, and
[docs/PLAN.md](docs/PLAN.md) for the current engineering priorities.
