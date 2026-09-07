# ChatGPT Integration

Status: ChatGPT desktop local `Work` transport is live-validated. Private
remote developer-mode access uses an app-managed OpenAI Secure MCP Tunnel.

Official OpenAI documentation establishes the split:

- ChatGPT desktop app, Codex CLI, and IDE extension can use MCP servers
  configured on the local Codex host.
- Local MCP can use STDIO servers started by a command, or Streamable HTTP
  servers reached by URL.
- ChatGPT on the web does not read local Codex config. Web Chat/Work uses
  plugin-provided connectors and remote MCP tools.

References:

- <https://learn.chatgpt.com/docs/extend/mcp>
- <https://learn.chatgpt.com/docs/plugins>
- <https://developers.openai.com/api/docs/guides/tools-connectors-mcp>
- <https://developers.openai.com/api/docs/guides/secure-mcp-tunnels>

## ChatGPT Desktop Local Work Path

This path uses the installed app-owned runtime and the shared Codex-host MCP
configuration. On the target Mac it has been live-validated in `Work` mode with
a reader query to the configured mailboxes.

In the tested ChatGPT desktop client, ordinary `Chat` did not expose local MCP
tools. Use `Work` for the local MacMCP workflow.

1. Start `/Applications/MacMCP.app` for a Cask install, or the app installed by
   the source formula.
2. In ChatGPT desktop, open Settings, then MCP servers.
3. Add a server named `macmcp`.
4. Choose STDIO.
5. Command:

   ```sh
   ~/.local/bin/macmcp-bridge
   ```

6. Arguments:

   ```text
   --stdio-proxy
   ~/Library/Application Support/macmcp/mcp.sock
   ```

The server process does not own sidecars. It connects to the running menu-bar
app over user-local IPC. If the app is not running, it fails closed. The
`bridge_status` tool, initialization, and tool listing remain available before
approval. Reader-data tools require approving the pending local client in the
MacMCP menu under `Clients`.

The equivalent generated config lives at:

```sh
~/.local/opt/macmcp/share/mcp.local.json
```

## Private Remote ChatGPT Path

ChatGPT web Chat/Work cannot read `~/.codex/config.toml`. Do not expose a local
MacMCP port or build a public HTTP adapter for this use case. OpenAI Secure MCP
Tunnel can forward the existing private STDIO proxy over outbound HTTPS: the
Mac keeps the app, sidecars, and IPC socket private.

Before starting, obtain from OpenAI Platform:

1. A `tunnel_id` associated with the target ChatGPT workspace from
   <https://platform.openai.com/settings/organization/tunnels>.
2. A restricted runtime API key from <https://platform.openai.com/api-keys>.
3. ChatGPT developer-mode and Platform tunnel permissions for the account or
   workspace.

For a new install, add the tunnel ID to the regular installer command:

```sh
scripts/install-local.sh \
  --gmail-address you@gmail.com \
  --chatgpt-tunnel-id tunnel_YOUR_ID
```

For an existing local installation:

```sh
scripts/install-local.sh \
  --reuse-existing-configuration \
  --chatgpt-tunnel-id tunnel_YOUR_ID
```

The installer installs `tunnel-client` through `brew install
openai/tools/tunnel-client` when it is missing. It prompts for the key with no
echo and saves it in a dedicated macOS Keychain service. The app launch config
contains only the tunnel ID, client path, and profile. Once the menu-bar app is
running, it owns `tunnel-client`: it creates a mode-`700` local proxy wrapper,
runs `init --force`, `doctor`, and then `run`. It repeats this after login.
No Terminal needs to remain open, and neither the key nor an inbound network
listener is written to disk.

The `MacMCP` menu shows `ChatGPT Tunnel: running` only after the managed client
has completed a successful control-plane poll. Its submenu shows the latest
redacted tunnel failure, if any, with an ISO timestamp, fixed phase, and fixed
reason; `macmcp diagnose` retains the most recent 12 records. It also opens the
`Restart Tunnel` command, `Replace Runtime API Key...`, and the two Platform
setup URLs. If Keychain asks MacMCP to access an already stored runtime key,
choose `Allow`. `Always Allow` is not required.

Then create the ChatGPT developer-mode app: open
<https://chatgpt.com/plugins>, select plus, choose `Tunnel` for Connection, and
select this tunnel or paste its ID.

The remote authorization boundary is the OpenAI tunnel identity and its
associated ChatGPT workspace. The private MCP process sees the local
`tunnel-client`-spawned proxy, not an authenticated individual ChatGPT user, so
it cannot implement a trustworthy per-person approval from MCP request fields.
Use one tunnel per intended remote principal when separation is required. The
current MacMCP local executable approval still applies to the proxy process.

The tunnel path preserves the same account-gated contract as local MCP:

- the three narrow mail-action tools are advertised, but every account begins
  with `Read only` enabled;
- clear `MacMCP > Mail > account > Read only` locally before a remote action;
- re-enable `Read only` to block new local and remote action calls immediately;
- same argument filtering and untrusted-data wrapping;
- same privacy-safe status and errors;
- no credentials, subjects, senders, folder names, bodies, event text, or
  reminder text in logs;
- fail closed if the menu-bar app, sidecars, tunnel, runtime API key, or local
  approval is missing.

## Mail Actions

MacMCP can create recipient-free managed drafts and change `read`, `unread`,
`flagged`, or `unflagged` state. It cannot send email. These tools are available
to the tunnel only when the relevant account's local `Read only` control has
been cleared; every new account is blocked by default.

## Validation Gate

Desktop-local validation:

```sh
scripts/validate-login-item-persistence.sh --phase chatgpt-desktop-local
```

This validates the installed app-owned runtime, local IPC, approval state, and
default read-only mail behavior through the same STDIO proxy shape. Manual ChatGPT
desktop UI validation is still needed to confirm the app accepts the STDIO
server entry and lists `bridge_status`.

The remote developer-mode validation gate is:

1. The `MacMCP` menu reports `ChatGPT Tunnel: running`.
2. ChatGPT lists the developer-mode app backed by the selected tunnel.
3. Tool listing exposes reader tools and the three account-gated mail actions.
4. `bridge_status` works before approval.
5. `mail.search` and `mail.read` pass the same no-mutation validation.
6. A mail action returns the fixed `Read only` error before the local control is
   cleared, then works only for that account.

After restarting the tunnel from the MacMCP menu, run:

```sh
scripts/validate-live-acceptance.sh --phase tunnel-reconnect --require-tunnel
```

The script verifies local prerequisites and the no-mutation path. A real tool
call in ChatGPT still needs to be observed in the client UI.
