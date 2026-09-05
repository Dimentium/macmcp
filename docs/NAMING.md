# Naming

## Canonical Names

`MacMCP` is the product name used in the menu bar, application UI,
documentation, and MCP-client-facing descriptions.

`macmcp` is the lowercase technical identifier used for the repository,
commands, configuration directories, release artifacts, and Homebrew tap.

Components use the same namespace:

- `macmcp-bridge`: the local MCP bridge runtime.
- `macmcp-mail`: the mail sidecar.
- `macmcp-eventkit`: the Calendar and Reminders sidecar.
- `tunnel-client`: the external OpenAI executable used for the optional
  ChatGPT tunnel; it is not renamed as a MacMCP component.

The public source repository is `macmcp`. Its Homebrew tap will be
`homebrew-macmcp`.

## Compatibility

`Mac Agent Bridge` and `mac-agent-bridge` are legacy names. New user-facing
text, commands, documentation, and release artifacts must not introduce them.
They remain only where required to migrate existing installations safely.

`reader` is an access-profile name, not product branding. It remains valid in
configuration and diagnostic status where it describes the read-only capability
set.

Changes to bundle identifiers, Keychain service names, IPC paths, or executable
names require an explicit migration and compatibility test. They must not be
silently changed as part of cosmetic renaming because macOS permissions and
existing MCP-client configuration depend on those identities.
