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

## Install Locally

The supported installation path is from source. A Homebrew cask is planned but
is not published yet.

Install Xcode Command Line Tools once if the Mac does not already have them:

```bash
xcode-select --install
```

Then install MacMCP:

```bash
git clone git@github.com:Dimentium/macmcp.git
cd macmcp
./scripts/install-local.sh
```

The installer builds and validates the app before switching the active runtime.
It asks only for the credentials and optional integrations that are configured.
On first use, macOS may ask MacMCP for Keychain, Calendar, or Reminders access.
Grant only the permissions needed for the features you enable.

Use the MacMCP menu-bar item to add mail accounts and inspect the state of the
bridge, mail, Calendar, Reminders, client approvals, and optional tunnel.

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

## Update And Remove

To update a source installation while retaining its configuration:

```bash
git pull --ff-only
./scripts/install-local.sh --reuse-existing-configuration
```

The installer stages the new build before stopping the old runtime. A macOS
permission prompt after an app-binary update is expected with the current local
ad-hoc signing workflow.

To remove MacMCP:

```bash
./scripts/uninstall-local.sh
```

Removal stops the app and tunnel, removes the installed runtime and its local
configuration, and leaves unrelated system data untouched.

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
