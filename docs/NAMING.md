# Naming

## Canonical Names

`MacMCP` is the product name used in the menu bar, application UI,
documentation, and MCP-client-facing descriptions.

`macmcp` is the lowercase technical identifier used for the repository,
commands, configuration directories, release artifacts, and Homebrew tap.

Components use the same namespace:

- `macmcp-bridge`: the local MCP bridge runtime.
- `tunnel-client`: the external OpenAI executable used for the optional
  ChatGPT tunnel; it is not renamed as a MacMCP component.

The mail and EventKit sidecars retain their upstream executable names,
`mail-mcp` and `CheICalMCP`. They are third-party artifacts rather than
MacMCP-branded commands; the MacMCP app bundle owns their locations and
lifecycle.

The public source repository is `macmcp`. Its Homebrew tap will be
`homebrew-macmcp`.

## Compatibility

`Mac Agent Bridge` and `mac-agent-bridge` are legacy names. New user-facing
text, commands, documentation, and release artifacts must not introduce them.
They remain only where required to migrate existing installations safely.

`reader` is an access-profile name, not product branding. It remains valid in
configuration and diagnostic status where it describes the read-only capability
set.

## Current Installation Layout

- App: `~/Applications/MacMCP.app`
- Bridge executable: `macmcp-bridge`
- Support state and IPC: `~/Library/Application Support/macmcp/`
- Runtime cache: `~/Library/Caches/macmcp/`
- Keychain services: `com.dimentium.macmcp.*`
- App bundle identifier: `com.dimentium.macmcp`

## Upgrade Migration

The local installer migrates prior state from the legacy layout during its
staged activation. It copies client approvals, mail-action settings, and
redacted tunnel failures; reads old launch configuration and
Keychain items when needed; and keeps legacy command and socket aliases while
an installation is upgraded. The old EventKit copy in `libexec` is removed:
the only authoritative executable is the copy embedded in `MacMCP.app`.

Changing the bundle identifier intentionally creates a new macOS code identity.
Until Developer ID signing is available, the next explicit upgrade can prompt
again for Keychain, Calendar, Reminders, Login Item, and client approval.
