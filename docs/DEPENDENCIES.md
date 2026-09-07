# Upstream dependency decision

## Decision

MacMCP uses two pinned sidecars behind a Swift policy gateway:

| Component | Pin | License | Purpose |
| --- | --- | --- | --- |
| `Dimentium/mail-mcp` | `v1.2.2` / `a62cf5f…` | MIT | IMAP reads and authenticated managed drafts for iCloud Mail and Gmail |
| `PsychQuant/che-ical-mcp` | `v1.16.1` / `a8598378…` | MIT | EventKit Calendar/Reminders reads |

The machine-readable pins live in `UPSTREAMS.lock.json`. The source installer
builds both sidecars locally: `mail-mcp` is checked out at its pinned commit
with verified `go.mod` and `go.sum` hashes and built with `-mod=readonly`;
CheICalMCP is built from its pinned source commit and reviewed Swift package
resolution because the published CheICalMCP binary failed strict signature
validation on the target Mac. Current artifact hashes are recorded in
`docs/MAC_VALIDATION.md` and `docs/DEPLOYMENT.md`.

## Mail MCP Fork

`Dimentium/mail-mcp` is a focused fork of `kacperkwapisz/mail-mcp`. It changes
the iCloud compatibility path and adds the reviewed local managed-draft
contract. When a server
rejects `LIST ... RETURN (SPECIAL-USE)`, it retries plain IMAP `LIST`. This
keeps server-declared roles for Gmail while restoring folder discovery for
iCloud Mail. The behavior has dedicated unit coverage.

The gateway continues to enforce the version 1 policy independently of the
sidecar:

- it projects a static tool allowlist instead of forwarding `tools/list`;
- it rejects unknown tools and parameters;
- it forces mail read arguments to non-mutating values;
- it excludes direct attachment download, send, organize, delete, and EventKit
  write tools; a bridge-owned adapter exposes bounded text from a small set of
  attachment types;
- it validates and bounds every result before returning it to an agent.

The fork is limited to this compatibility and managed-draft contract; feature
and policy changes remain in MacMCP unless they cannot be enforced before an
upstream call.

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

## Future Fork Criteria

The iCloud `LIST` incompatibility and managed-draft contract are the current
reasons for the mail-mcp fork. Additional sidecar changes belong in a fork only
when at least one of these becomes true:

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
