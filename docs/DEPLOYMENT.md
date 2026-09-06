# Deployment

Status: local installer is usable for the current Mac. The install path now
targets an app-owned runtime: local stdio MCP clients connect through an IPC
proxy instead of starting their own sidecar runtime. Reader-data tools require a
per-client local approval grant. ChatGPT private tunnel startup is owned by the
same menu-bar app rather than by a persistent Terminal.

## Validation Record

On 2026-09-04, the installer completed in a temporary prefix with
`--skip-password --no-open`. It downloaded and verified `mail-mcp`, built and
signed pinned CheICalMCP, built and signed the app bundle, signed the installed
CLI, wrote the MCP config example, and passed `codesign --verify` for the
installed app. It did not prompt for the Keychain password and did not launch
the app, so Calendar/Reminders TCC prompts were not exercised by this run.

Temporary-prefix hashes from that run:

- `mail-mcp`: `688dc96b45fa677b7f62239966ed2616e6dde94e3ab8aa9fe8c7c27202a7ff00`
- `CheICalMCP`: `91c20c9b00e943e9500bdf22d8ad2bdac4ab048a206889e7afeca47d210dfc17`
- CLI `mac-agent-bridge`: `e4d1a16709a955388aba03316bbf5779432c9622362554b31bafe35769dd2257`
- app bridge executable: `261d051718103ed51e75237cb5e02ceff1858473a01a54c6cb2af2a412026afa`
- app CheICalMCP executable: `91c20c9b00e943e9500bdf22d8ad2bdac4ab048a206889e7afeca47d210dfc17`

A later dry run used one iCloud preset, one Gmail preset, and one explicit IMAP
account in the same install command. It produced a valid MCP JSON file with all
account flags and passed code-signature verification. This still did not run
live Gmail authentication or no-mutation checks.

Temporary-prefix hashes from the multi-account run:

- `mail-mcp`: `688dc96b45fa677b7f62239966ed2616e6dde94e3ab8aa9fe8c7c27202a7ff00`
- `CheICalMCP`: `300745a98485ececfe6e34fcb21075302b4290e9bed46990c9bbf100a51a044a`
- CLI `mac-agent-bridge`: `de361fba0f0e38cdc57423ccb7df30a6e294fed785e5e3df221c29efefa7f8c2`

A real user-local install was completed with one iCloud account and one Gmail
account. The Gmail app password was stored through the installed CLI's hidden
Terminal prompt. The installed app, CLI, and sidecars launched successfully; a
privacy-safe MCP smoke test reached `bridge_status`, and Login Item status
reported `enabled`. A later privacy-safe local validation run passed with both
mail accounts in one stdio bridge runtime: MCP tool surface, account auth,
`mail.search`, `mail.read`, and independent IMAP no-mutation snapshots.
The app-owned IPC runtime was then installed and validation passed through the
generated `--stdio-proxy` config. Process validation showed the app-owned bridge
and installed sidecars without a second CLI bridge runtime. A restart validation
then passed: the proxy failed closed while the app was stopped and validation
passed again after relaunch. The installed `--status-json` command now reports
the running app-owned status through the same IPC path. A local per-client
approval gate was added after that validation record; reader-data tools now
require an approved local client identity. The upgraded real install was
validated for first-call denial, CLI approval of the pending local client, and a
post-approval privacy-safe no-mutation pass.

On 2026-09-05, the first post-reboot check exposed two deployment defects: idle
local MCP sessions could occupy the IPC server's cooperative executor, and a
replaced ad-hoc app bundle could lose its Login Item registration. The server
now puts persistent blocking socket reads on GCD worker threads, status probes
time out in three seconds, and the menu-bar app re-registers a missing Login
Item when launched after an upgrade. The updated local install passed the full
post-upgrade gate: one app-owned runtime and sidecar of each type, Login Item
status enabled, ready Mail/Calendar/Reminders, reader-only status, local client
approval, and privacy-safe no-mutation validation of the two configured mail
accounts. A clean reboot was then completed without manually launching the app;
the final post-reboot gate passed for Login Item status, a single app-owned
runtime and each sidecar, ready components, current local approval, and both
configured mail accounts' privacy-safe no-mutation reader validation.

## Local Install

Run this on the Mac that owns the mail account:

```sh
scripts/install-local.sh --icloud-address you@icloud.com
```

Gmail uses a dedicated preset:

```sh
scripts/install-local.sh --gmail-address you@gmail.com
```

Multiple mailboxes can be installed in one bridge instance:

```sh
scripts/install-local.sh \
  --icloud-address you@icloud.com \
  --gmail-address you@gmail.com \
  --mail-account work=you@example.com,imap.example.com,993,tls
```

The script installs for the current user by default:

- app bundle: `~/Applications/Mac Agent Bridge.app`
- CLI: `~/.local/bin/mac-agent-bridge`
- sidecars: `~/.local/opt/mac-agent-bridge/libexec/`
- MCP stdio example: `~/.local/opt/mac-agent-bridge/share/mcp.local.json`
- app launch config:
  `~/Library/Application Support/mac-agent-bridge/launch.json`
- local IPC socket while the app is running:
  `~/Library/Application Support/mac-agent-bridge/mcp.sock`
- approved MCP clients:
  `~/Library/Application Support/mac-agent-bridge/approved-clients.json`

The local deployment scripts use `/bin/bash`; they do not require the user's
login shell to be zsh.

## Optional Local Mail Actions

The reader profile is the default and the only profile that may be connected to
ChatGPT. To enable local-only recipient-free drafts and message state changes,
add the opt-in flag during first installation:

```sh
scripts/install-local.sh \
  --gmail-address you@gmail.com \
  --enable-local-mail-actions
```

The installer writes a second local config at
`~/.local/opt/mac-agent-bridge/share/mcp.mail-actions.local.json`, backed by
`~/Library/Application Support/mac-agent-bridge/mail-actions.sock`. It has a
separate approvals file, so approve the local client again from the `Local Mail
Actions` menu item. This config must not be added to ChatGPT or a tunnel.

The action profile can create recipient-free managed drafts and change one
message's `read`, `unread`, `flagged`, or `unflagged` state. It has no SMTP or
send operation. Updating a managed draft requires its exact revision and fails
closed if a human added a recipient or changed the draft.

It downloads the pinned `mail-mcp` macOS archive and verifies its SHA-256. It
does not use the published CheICalMCP release binary because that artifact has
already failed strict code-signature validation on the target Mac. Instead it
clones the pinned CheICalMCP source commit, builds it locally, applies an
ad-hoc hardened-runtime signature with Calendar/Reminders entitlements, and
verifies the result.

The installer prompts for each account password through
`mac-agent-bridge --store-mail-password ADDRESS`. Use app-specific passwords
where the provider requires them. Passwords are stored in Keychain by account
address; do not put them in config files, command-line arguments, environment
variables, or MCP client config.

## ChatGPT Tunnel

Create a private tunnel at
<https://platform.openai.com/settings/organization/tunnels> and a restricted
runtime API key at <https://platform.openai.com/api-keys>. Add the tunnel ID to
the normal installation:

```sh
scripts/install-local.sh \
  --gmail-address you@gmail.com \
  --chatgpt-tunnel-id tunnel_YOUR_ID
```

On demand, the installer installs `tunnel-client` with `brew install
openai/tools/tunnel-client`, saves the runtime key in its dedicated Keychain
service, and stores only the tunnel ID, client path, and profile in
`launch.json`. The app starts, monitors, and stops `tunnel-client` with its own
lifecycle. An ordinary `--reuse-existing-configuration` upgrade preserves the
tunnel config and Keychain key. The uninstaller preserves that key unless
`--delete-chatgpt-tunnel-key` is explicitly supplied.

At the end, the installer launches the menu-bar app. Approve Calendar and
Reminders in the macOS permission prompts. If Keychain asks MacMCP to access an
already stored secret, choose `Always Allow` once. Do not use broad `tccutil
reset` commands during troubleshooting.

## Transfer Archive

When the target Mac should not receive a git checkout, create a clean source
archive:

```sh
scripts/package-local-archive.sh
```

The script writes:

- `dist/mac-agent-bridge-local.tar.gz`
- `dist/mac-agent-bridge-local.tar.gz.sha256`

It excludes git metadata, CI metadata, build output, previous dist output,
runtime state, handoff/backlog notes, and local workspace files. On the target
Mac, unpack the archive and run the normal installer:

```sh
tar -xzf mac-agent-bridge-local.tar.gz
cd mac-agent-bridge-local
scripts/install-local.sh --gmail-address you@gmail.com
```

## Upgrade

For an ordinary upgrade, run
`scripts/install-local.sh --reuse-existing-configuration`; it reads the already
saved account configuration and preserves Keychain passwords. The script builds,
signs, and validates replacements in staging while the installed app continues
to run. Only then does it stop the app and sidecars, move the existing files
aside, and activate the staged files. An ordinary activation failure restores
the prior files and relaunches the previous app. The activated files are:

- `~/Applications/Mac Agent Bridge.app`
- `~/.local/opt/mac-agent-bridge/bin/mac-agent-bridge`
- `~/.local/opt/mac-agent-bridge/libexec/mail-mcp`
- `~/.local/opt/mac-agent-bridge/libexec/CheICalMCP`
- `~/.local/opt/mac-agent-bridge/share/mcp.local.json`
- `~/.local/opt/mac-agent-bridge/share/mcp.mail-actions.local.json` when opted in
- `~/Library/Application Support/mac-agent-bridge/launch.json`

Existing Keychain passwords are preserved. This guards against build, download,
and ordinary activation failures; it cannot protect against a forced process
kill or a power loss during the small multi-file activation window. You can also
supply the account flags again and use `--skip-password` when the account
passwords are already stored:

```sh
scripts/install-local.sh --gmail-address you@gmail.com --skip-password
```

If account flags change, the generated MCP config and menu-bar app launch
config are rewritten with the new account list. Store passwords for any newly
added accounts before expecting mail reads to work.

Ad-hoc binary replacement can change the code-signing identity hash seen by
macOS. The menu-bar app re-registers its Login Item on its first launch after a
replacement. Keychain, Calendar, or Reminders can ask for approval again after
an upgrade; this is expected for the current local-only package.
If the installed CLI/proxy hash changes, the local MCP client approval
fingerprint changes too. Approve the pending client again from the `MacMCP`
menu or with `~/.local/bin/mac-agent-bridge --approve-pending-client`. When a
new hash for the same local executable is approved, older grants for that
executable are removed automatically.

## Uninstall

Remove the installed app, CLI, sidecars, and generated MCP config:

```sh
scripts/uninstall-local.sh
```

The uninstall script stops the installed menu-bar app and installed sidecar
processes before deleting files. It removes the app launch config and removes
the `~/.local/bin/mac-agent-bridge` symlink only when that symlink points at
this install.

Keychain mail passwords are preserved by default. Delete stored account
passwords only with explicit flags:

```sh
scripts/uninstall-local.sh \
  --delete-mail-password you@icloud.com \
  --delete-mail-password you@gmail.com
```

The script does not run broad TCC resets. macOS privacy grants may remain in
System Settings after the files are removed.

The Keychain key that authenticates locally managed drafts is also preserved by
default, so an uninstall followed by a reinstall does not orphan safe drafts.

## Verify

Basic local check:

```sh
~/.local/bin/mac-agent-bridge --status-json
```

This command queries the running menu-bar app over local IPC. Start
`~/Applications/Mac Agent Bridge.app` first.

Installed mail reader validation:

```sh
scripts/validate-local-mail-readonly.py
```

The validation harness reads the generated stdio MCP config and app launch
config, connects through the same path as a local MCP client, checks the reader
tool surface, validates mail account auth, calls `mail.search` and `mail.read`,
and compares independent IMAP snapshots before and after the MCP reads. It
prints only aggregate status and never prints credentials, message content,
subjects, senders, folder names, events, or reminder text.

For a live tunnel reconnect or notification acceptance run, use:

```sh
scripts/validate-live-acceptance.sh --phase tunnel-reconnect --require-tunnel
```

It verifies the local reader-only runtime, optional tunnel state, and
no-mutation mail behavior. Observing a real ChatGPT tool call and a macOS
notification remains a required manual step.

The first validation run from a new client can fail with `Client approval
required in MacMCP`. Approve the pending client from the `MacMCP` menu under
`Clients`, or run:

```sh
~/.local/bin/mac-agent-bridge --approve-pending-client
```

Then rerun the validation harness.

Login Item/reboot persistence validation:

```sh
scripts/validate-login-item-persistence.sh --phase pre-reboot
scripts/validate-login-item-persistence.sh --phase post-reboot
```

Run the `pre-reboot` phase after install or upgrade, reboot the Mac without
rebuilding the app, then run the `post-reboot` phase. The script checks the
installed files, Login Item status, app-owned runtime process counts,
`bridge_status`, local client approvals, and the privacy-safe mail no-mutation
validation. It prints only aggregate status, counts, and component states.

Runtime health is exposed through the MCP `bridge_status` tool after starting
the menu-bar app. EventKit starts as `connected_unverified` and becomes `ready`
only after bounded read probes succeed. If Calendar or Reminders cannot be read,
the corresponding status becomes `unavailable` without reflecting private event
or reminder data.

The menu-bar app shows `MacMCP` in the status bar:

- `MacMCP 🟢` when configured readers are ready.
- `MacMCP 🟡` while configured readers are being checked.
- `MacMCP 🔴` when a configured reader needs attention.
- `MacMCP ⚪` when no reader is configured.

The menu lists separate status rows for Mail, Calendar, and Reminders. It
refreshes component and client approval status once per second and also
refreshes immediately when opened.

## Local MCP Config

The installer writes a stdio config example at:

```sh
~/.local/opt/mac-agent-bridge/share/mcp.local.json
```

The shape is:

```json
{
  "mcpServers": {
    "mac-agent-bridge": {
      "command": "/Users/YOU/.local/opt/mac-agent-bridge/bin/mac-agent-bridge",
      "args": [
        "--stdio-proxy",
        "/Users/YOU/Library/Application Support/mac-agent-bridge/mcp.sock"
      ]
    }
  }
}
```

This local stdio config is for MCP clients that can launch local processes. It
does not start sidecars; it connects to the already running menu-bar app. If the
app is not running, the proxy fails closed. `bridge_status`, initialization, and
tool listing remain available before approval; reader-data tool calls require an
approved client.

For Codex, add the server with:

```sh
codex mcp add mac-agent-bridge -- \
  "$HOME/.local/bin/mac-agent-bridge" \
  --stdio-proxy "$HOME/Library/Application Support/mac-agent-bridge/mcp.sock"
```

Use `codex mcp list` or `/mcp` in the Codex TUI to inspect it.

On the first reader-data call, approve the pending Codex/proxy client in the
MacMCP menu or with `~/.local/bin/mac-agent-bridge --approve-pending-client`.

ChatGPT integration is a separate packaging layer because ChatGPT does not
attach directly to a local stdio MCP server; it needs a supported app, remote
MCP, or tunnel path to the local Mac bridge.

## Menu-Bar App Config

LaunchServices and Login Item starts do not pass CLI arguments to the app. The
installer therefore writes:

```sh
~/Library/Application Support/mac-agent-bridge/launch.json
```

The app reads that file only when launched without command-line arguments. The
file stores sidecar paths, account flags, and `launchAtLogin: true`, but never
stores mail passwords. On launch, the app attempts to register itself as the
current user's Login Item through `SMAppService.mainApp`; the menu shows
whether that registration is enabled, pending approval, unavailable, or missing.

## Clean Mac Prerequisites

- macOS 14 or newer.
- Xcode Command Line Tools: `xcode-select --install`.
- Network access to GitHub for the pinned sidecar archive/source.
- Dedicated mail app-specific passwords where required by the provider.

## Open Gates

The current forward plan lives in `docs/PLAN.md`. Deployment-specific gates are:

- Controlled IMAP temporary-mailbox no-mutation gate.
- Revoked-secret failure gate with redacted errors.
- Reboot/Login Item validation.
- ChatGPT remote developer-mode validation after a Platform tunnel is created
  and associated with the target ChatGPT workspace.
