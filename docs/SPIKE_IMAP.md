# IMAP mail spike

Status: live iCloud and Gmail authentication, bridge search/read, and
independent no-mutation snapshots are complete in one stdio bridge runtime.
Idle recovery, stale-handle, revoked-secret, and controlled temporary-mailbox
checks remain open.

## Sidecar source

- MacMCP fork: `https://github.com/Dimentium/mail-mcp`
- Release: `v1.1.1` / `f79c87b80154c5cc3197fecf69d5d2985b7e6b74`
- Original upstream: `https://github.com/kacperkwapisz/mail-mcp`
- License: MIT
- Implementation: Go 1.25.4, `emersion/go-imap` v2
- Transport: MCP over stdio or authenticated Streamable HTTP

## Source findings

- `search_emails` selects the mailbox with IMAP read-only mode (`EXAMINE`).
- `read_email` also uses a read-only selection and a non-seen `FETCH` when
  `mark_as_read` is false.
- `read_email` exposes `mark_as_read`; the reader gateway must reject true and
  omit that field from the projected schema.
- `get_attachment` writes to disk. It is used only behind the bridge's
  `mail.read_attachment_text` adapter, which fixes the directory, validates
  the resulting path, extracts bounded text from supported types, and deletes
  the file. The upstream tool itself never appears in the reader profile.
- Organizing and draft creation remain available even when `allow_send` and
  `allow_delete` are false. Configuration gates alone are therefore not a
  read-only profile.
- Message handles contain account, mailbox, UIDVALIDITY, and UID. A changed
  UIDVALIDITY makes a handle stale instead of targeting the wrong message.
- The connection pool serializes each account, health-checks idle connections
  with NOOP, closes timed-out sockets, and reconnects on the next call.
- UIDNEXT and IMAP IDLE are not exposed to MCP clients. The first version must
  use bounded polling plus deduplication by opaque message handle. A dedicated
  incremental-reader tool can be proposed upstream later.
- SMTP inherits IMAP credentials when omitted. The reader configuration must
  avoid SMTP entirely and the gateway must deny `verify_account`, because that
  tool verifies both IMAP and SMTP.
- iCloud accepts plain `LIST "" "*"` but rejects `LIST "" "*" RETURN
  (SPECIAL-USE)` with `BAD`. The pinned `mail-mcp v1.1.1` first requests
  `ReturnSpecialUse` and retries plain `LIST` when that extension is rejected.
  This preserves Gmail role metadata and makes iCloud `list_folders` usable.

## Reader projection

Allowed:

- `list_accounts`
- `get_server_info`
- `list_folders`
- `search_emails`
- `read_email`, with gateway-enforced values:
  - `mark_as_read = false`
  - `include_html = false`
  - `include_headers = false` unless a later policy explicitly allows a small
    header allowlist
  - `max_body_chars` clamped by bridge policy
- `mail.read_attachment_text`, an adapter over `get_attachment` that accepts
  only `message_id` and `part_id`; PDF and UTF-8 text, CSV, JSON, and XML are
  supported up to 10 MiB and the downloaded file is deleted after extraction

Denied:

- `verify_account`
- direct `get_attachment` access and caller-controlled output directories
- all sending, reply, forward, draft, folder-management, flag, move, archive,
  and delete tools

## Credential flow for the prototype

The upstream config format stores account passwords in YAML. We will not leave
such a file on disk:

1. Setup stores each mail account password in macOS Keychain under its account
   address.
2. The bridge retrieves each account password at startup. A rebuilt ad-hoc
   binary may require the user to approve Keychain access again.
3. The bridge creates a private temporary directory (`0700`) and config file
   (`0600`) containing each IMAP endpoint and a closed loopback SMTP sink that
   has no mail credential.
4. It starts the mail sidecar with that config.
5. After the sidecar has loaded successfully, it removes the temporary file.
6. The password is redacted from every error and log path.

Longer term, an upstream `password_command` or Keychain reference would remove
the temporary-file step.

## Live IMAP validation procedure

1. Generate dedicated app-specific passwords where required and store them in
   Keychain.
2. Start the bridge/mail sidecar with the temporary reader configuration.
3. Snapshot INBOX flags and mailbox list using an independent trusted client.
4. Repeatedly run searches and reads, including a message currently unread.
5. Confirm the message remains unread and no mailbox/flag counts change.
6. Leave the connection idle beyond its configured TTL, then scan again to
   exercise NOOP/reconnect.
7. Disable the network, trigger a scan, restore the network, and verify recovery.
8. Move or recreate a test mailbox to exercise stale UIDVALIDITY handles.
9. Revoke the app-specific password and verify a closed, redacted failure.

## Pass conditions

- TLS authentication to `imap.mail.me.com:993` succeeds.
- Searches and reads never change `\Seen` or another flag.
- Reconnect is automatic and bounded.
- A stale handle is rejected.
- No SMTP connection occurs.
- No credential appears in stdout, stderr, MCP output, process arguments, or
  persistent files.

## Live result on the target Mac

Authentication and bridge `search`/`read` succeeded. Before and after a bridge
read, an independent Python IMAP client opened separate TLS sessions, selected
`INBOX` read-only with `EXAMINE`, and compared the target UID. UIDVALIDITY,
UIDNEXT, unseen count, exact flags, target presence, and unread state were all
unchanged; the handle's UIDVALIDITY matched the server. No message content or
folder name was logged.

The installed stdio bridge later passed the same privacy-safe validation shape
with iCloud and Gmail configured together. The remaining mail gates are a
controlled temporary-mailbox comparison, idle-timeout recovery, a deliberately
stale handle, and revoked-secret failure.
