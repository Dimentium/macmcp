# Upstream dependency decision

## Decision

The first prototype uses two pinned, unmodified sidecars behind a Swift policy
gateway:

| Component | Pin | License | Purpose |
| --- | --- | --- | --- |
| `kacperkwapisz/mail-mcp` | `v1.1.0` / `3bf846d7…` | MIT | iCloud IMAP reads |
| `PsychQuant/che-ical-mcp` | `v1.16.1` / `a8598378…` | MIT | EventKit Calendar/Reminders reads |

The machine-readable pins live in `UPSTREAMS.lock.json`. The installer verifies
the pinned `mail-mcp` release archive checksum and builds CheICalMCP from the
pinned source commit because the published CheICalMCP binary failed strict
signature validation on the target Mac. Current artifact hashes are recorded in
`docs/MAC_VALIDATION.md` and `docs/DEPLOYMENT.md`.

## Why no fork yet

The gateway can enforce the version 1 policy without modifying either server:

- it projects a static tool allowlist instead of forwarding `tools/list`;
- it rejects unknown tools and parameters;
- it forces mail read arguments to non-mutating values;
- it excludes direct attachment download, send, organize, delete, and EventKit
  write tools; a bridge-owned adapter exposes bounded text from a small set of
  attachment types;
- it validates and bounds every result before returning it to an agent.

This keeps upstream updates reviewable and avoids maintaining two forks before
we have live macOS evidence that a fork is necessary.

## Known gaps accepted for the prototype

### mail-mcp

- No native read-only profile.
- `read_email` can mark a message read unless the gateway blocks the argument.
- `get_attachment` writes to disk. MacMCP permits it only behind an adapter
  that fixes a private directory, validates the resulting file, and removes it
  after text extraction.
- `verify_account` checks SMTP as well as IMAP.
- It does not expose UIDNEXT or IDLE; version 1 uses polling and deduplication.
- Its YAML config requires a plaintext password value at load time; the bridge
  will generate a private temporary config from Keychain and remove it after
  startup.

### che-ical-mcp

- It advertises both read and write tools.
- EventKit read access is a macOS full-access TCC grant, so OS permission alone
  is not a read-only boundary.
- TCC depends on the responsible parent process. The tested ad-hoc binary has
  full access under an interactive host but remains `notDetermined` as a direct
  launchd child. The local deployment therefore needs a GUI/menu-bar responsible
  process; re-granting after replacing a binary is acceptable.

## Fork triggers

Fork an upstream only when at least one of these becomes true:

- the gateway cannot prevent a mutation before the call reaches the sidecar;
- a sidecar performs an unwanted write during startup or a read operation;
- a required secret cannot be supplied without persisting plaintext;
- an upstream update breaks the pinned reader contract;
- UIDNEXT/IDLE becomes necessary for performance or correctness;
- the GUI-hosted two-process TCC attribution cannot be made reliable after an
  explicit interactive re-grant.

If a fork is required, the preferred patches are narrow:

1. native `reader` mode that registers only read tools;
2. handler-level rejection of mutations in reader mode;
3. Keychain/password-command support for mail;
4. incremental mail listing as a dedicated read-only operation.

## Alternatives rejected for the core path

- Direct Apple Mail SQLite readers: private schema, stale-cache risk, and Full
  Disk Access are unnecessary for an iCloud-only monitor.
- AppleScript/JXA mail reads: too slow and fragile for unattended scanning.
- `apple-pim`: useful security/evaluation reference, but combines reads and
  writes in action-valued tools and prefers the local Mail database.
- Rewriting IMAP in Swift now: large protocol/MIME surface with no version 1
  user benefit. It remains a possible later replacement behind the same
  gateway contract.

## Upgrade policy

- Never track `main` or `latest` at runtime.
- Update one sidecar at a time.
- Review tool schemas and source changes before changing a pin.
- Verify the downloaded artifact SHA-256 before installation.
- Run reader tool-list, argument-policy, prompt-injection, and no-mutation
  integration tests before accepting the update.
