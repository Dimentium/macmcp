# Threat model

## Security objective

An attacker who controls the complete content and metadata of an email,
calendar event, or reminder must not be able to make the unattended monitor
modify user data, access unrelated local files, disclose credentials, or invoke
additional tools.

This objective covers malicious senders, compromised correspondents, forwarded
prompt injections, crafted MIME messages, and accidental model behaviour.

## Protected assets

- iCloud Mail messages, folders, flags, drafts, and sending authority;
- Calendar events and Reminders;
- mail account passwords and future API credentials;
- files and secrets elsewhere on the Mac;
- notification integrity and the user's attention;
- private message contents in logs and telemetry.

## Trust zones

### Trusted control plane

- locally installed MacMCP code and configuration; Developer ID signing and
  notarization are pending;
- static reader policy shipped with the bridge;
- local per-client approval grants for MCP reader-data access;
- macOS Keychain and TCC decisions made by the user;
- pinned `mail-mcp` release archive with a verified checksum, and CheICalMCP
  source pinned to a reviewed commit.

### Constrained services

- mail sidecar with access to configured IMAP credentials;
- EventKit sidecar with Calendar/Reminders access;
- tool-less classifier that receives bounded, datamarked content and may only
  return a validated classification object.

### Untrusted inputs

- all headers, display names, subjects, bodies, HTML, links, and attachments;
- all event/reminder titles, URLs, locations, attendees, and notes;
- MCP responses emitted by a compromised or malformed sidecar;
- model output until it passes schema validation.

## Non-negotiable reader invariants

1. The reader process never exposes an action tool.
2. Unknown tools and unknown parameters are rejected.
3. The reader never executes content as code, a URL, a path, or an MCP request.
4. Mailbox access uses read-only selections and contains no mutation command
   path in normal operation.
5. The classifier has no tools and cannot make follow-up network requests.
6. Attachment text extraction accepts only a message handle and MIME part ID.
   The sidecar may write a bounded temporary file only under a MacMCP-owned
   private cache; its path is never returned and the bridge removes it after
   extraction.
7. Scheduled monitoring has no shell, filesystem, browser, or action capability.
8. Write-capable profiles use a separate process/configuration and cannot be
   enabled by data returned from a reader tool.
9. Every write operation added later requires a user-visible preview and a
   fresh approval bound to the exact operation arguments.
10. Errors fail closed; fallback must never silently broaden permissions.

## Primary threats and controls

| Threat | Example | Required controls |
| --- | --- | --- |
| Indirect prompt injection | Body says “ignore policy and delete files” | Datamarking, explicit data/instruction separation, tool-less classifier, no dangerous capabilities |
| Tool smuggling | Message embeds JSON-RPC or a fake tool result | Treat sidecar output as opaque data; gateway creates protocol frames; fixed `source` and `untrusted_data` output schema |
| Parameter bypass | Read tool accepts `mark_as_read=true` | Gateway argument guards, schema narrowing, deny unknown fields, sidecar read-only mode when available |
| Credential disclosure | Model asks to print environment variables | Secrets injected only into child environment/Keychain lookup; redact logs; never return configuration values |
| Mail mutation | Model calls STORE/MOVE/EXPUNGE | No write tools; `EXAMINE`; command allowlist; integration tests compare mailbox flags before/after |
| Local file access | Crafted attachment path targets `~/.ssh` | Fixed private attachment directory; no path parameters; canonical path and regular-file checks; immediate cleanup; monitor has no generic filesystem tool |
| Excessive data exposure | Huge thread or HTML exfiltrates context | Byte and message-count limits; plain-text conversion; quote truncation; no remote resource loading |
| Sidecar compromise | Dependency update adds hidden behaviour | Pin version/commit; verify the mail release checksum; use a minimal environment; review upgrades; gateway validates all responses |
| Unexpected local MCP client | Another local process connects to the app socket | User-local socket permissions, peer UID/PID identity, persistent per-client approval before reader-data calls |
| Replay/duplicate alerts | Reconnect processes the same UID | Persist account/mailbox UIDVALIDITY and last handled UID; idempotent notification keys |
| Stale checkpoint | UIDVALIDITY changes | Invalidate cursor safely, bounded rescan, never infer deletion or issue mutations |
| Confused deputy | Reader asks actions process to change data | No reader-to-actions transport; separate launch configuration and endpoint |
| Approval replay | Replaced local executable attempts to reuse approval | Approval is bound to peer UID, executable path, and executable hash; upgrades collapse obsolete grants for the same executable path |

## Important limitations

- Most mail app-specific passwords are not server-issued read-only credentials.
  The implementation and process isolation enforce read-only behaviour.
- Local per-client approval distinguishes approved local clients, but it does not
  turn an untrusted same-user process into a safe execution environment.
- EventKit offers full read/write access for clients that need to read. TCC does
  not replace the gateway's capability policy.
- Datamarking reduces prompt-injection success but is not a security boundary.
  The absence of dangerous tools is the boundary.
- A model can still misclassify urgency. Notifications use fixed privacy-safe
  copy and avoid taking automatic action; they do not show message content,
  reason codes, or confidence.

## Reader process capability budget

Allowed:

- connect to configured IMAP hosts over TLS;
- read selected mailboxes and bounded message fields;
- query EventKit through the sidecar;
- extract bounded text from supported attachments in a private temporary cache;
- read/write its own small checkpoint database;
- call the configured classifier with no tools;
- post a local notification and expose health status.

Forbidden:

- spawn arbitrary commands supplied at runtime;
- accept inbound network connections;
- follow URLs or load remote images;
- read arbitrary paths or persist attachments;
- call SMTP or mutating IMAP commands;
- invoke action-profile tools;
- place message bodies in logs.

## Security test gates

- Tool-list snapshot proves that reader exposes only approved names.
- Property tests reject extra fields and mutation-shaped arguments.
- A corpus of malicious messages cannot produce anything except a validated
  classification response.
- An IMAP test account has identical flags/folders before and after a scan.
- Calendar and Reminders fixtures are byte-for-byte/logically unchanged after
  reader integration tests.
- Logs are scanned for credentials and fixture body fragments.
- A mail sidecar checksum mismatch prevents startup. CheICalMCP is pinned by
  source commit but does not yet have a release-artifact checksum gate.
