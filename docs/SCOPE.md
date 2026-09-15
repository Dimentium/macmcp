# MacMCP Scope

## Product goal

Run a small local macOS bridge that lets a constrained agent inspect IMAP mail,
Calendar, and Reminders without modifying source data by default.

The bridge exposes narrowly scoped interactive write operations only through
separate default-off capability controls.

## Version 1

Version 1 includes:

- IMAP mail access, with iCloud and Gmail presets;
- bounded text extraction from supported mail attachments;
- read access to Apple Calendar and Reminders through EventKit;
- a deny-by-default MCP gateway in front of the upstream sidecars;
- a local menu-bar host with health status;
- local install, upgrade, uninstall, and transfer archive scripts;
- per-client local approval before MCP reader-data tools can return data;
- local health/status information through the menu-bar app and `bridge_status`;
- macOS Keychain storage for mail passwords;
- adversarial tests for prompt injection and capability bypasses.

## Explicitly out of scope for version 1

- sending, replying to, moving, archiving, or deleting mail;
- persistent downloading or saving of attachments;
- attachment formats other than PDF and UTF-8 text, CSV, JSON, or XML;
- OCR, image analysis, or document conversion;
- deleting or moving Calendar/Reminder items, invitations, Reminder reopening,
  or broad Calendar/Reminder automation;
- Notes, Contacts, Messages, or generic filesystem access;
- direct reads from Apple Mail's private SQLite databases;
- remote administration or a network-listening MCP endpoint.

## Trust boundaries

- Email, event, and reminder text is untrusted content, never an instruction.
- The reader gateway exposes only explicitly allowed tools and arguments.
- Credentials remain inside the local bridge/sidecar process boundary.
- Local MCP clients must connect through the app-owned IPC proxy and receive a
  per-client grant before reader-data tools are served.
- Mail actions remain disabled per account until Draft creation allowed is
  enabled in Settings. EventKit write actions remain disabled until their
  category's Settings control is enabled.

## Version 1 acceptance criteria

1. Mail can be searched and read without changing flags or mailbox state.
2. Calendar and Reminders can be queried through EventKit without write tools
   appearing in the reader MCP tool list by default. When explicitly enabled,
   the only actions are Calendar create/update and Reminder create/complete.
3. A malicious message cannot cause an MCP write call, shell command, file
   access, a caller-selected attachment path, or arbitrary network request.
4. Logs contain no message bodies, credentials, or attachment data.
5. Revoking credentials or macOS permissions fails closed and is visible in
   status output.

## Later milestones

- ChatGPT integration through a supported app, remote MCP, or tunnel path.
- Additional Calendar, Reminders, and mail-triage actions require a separate
  security review.
- Sending, replying, and deletion require a separate security review and form
  version 4 at the earliest.
