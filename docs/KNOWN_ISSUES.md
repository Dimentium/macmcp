# Known Issues

This is the engineering issue register for MacMCP. It records confirmed
implementation and delivery gaps found during the consistency audit on
2026-09-05. It does not contain account addresses, credentials, or personal
data.

The project is a usable local reader MVP. It is not yet a production-grade
deployment package until the high-priority items below are resolved.

## High Priority

### 1. Direct CLI mode bypasses app-owned client approval

The installed executable still accepts `--mail-sidecar` and
`--eventkit-sidecar` and starts a full bridge directly. That path does not pass
through the menu-bar app's local IPC server or `ClientApprovalStore`.

- Evidence: `Sources/MacAgentBridge/main.swift` starts `BridgeRuntime` directly
  when sidecar arguments are supplied.
- Impact: the documented per-client approval boundary applies only to the proxy
  path, not to every production data-serving path.
- Resolution: make the app-owned IPC/proxy path the only production reader
  entry point. Keep raw sidecar execution in a separate developer-only target,
  or remove it once development tooling no longer needs it.

### 2. Sidecar recovery is still manual

Runtime status is now verified with bounded initial and recurring probes, and
sidecar termination marks the affected reader unavailable. The sidecars still
use `restartPolicy: .never`; a failed Mail or EventKit process remains down
until the app is restarted.

- Evidence: `Sources/MacAgentBridge/BridgeRuntime.swift`,
  `MailHealthProber.swift`, and `SidecarStatusObserver.swift`.
- Impact: the menu and `bridge_status` report failure accurately, but an
  unattended transient sidecar failure interrupts service until manual recovery.
- Resolution: add controlled sidecar restart with backoff. Mail recovery must
  rematerialize a new private configuration from Keychain before restart.

### 3. Ad-hoc signing causes recurring permissions

The installer now stages and validates artifacts before stopping the active
runtime, then has an ordinary-error rollback path during activation. It still
uses ad-hoc signing. Each replacement can change the identity seen by Keychain,
TCC, and Login Item services.

- Evidence: `scripts/install-local.sh` stages before activation;
  `scripts/build-local-app.sh` uses `codesign --sign -`.
- Impact: users can repeatedly need Keychain, Calendar, Reminders, Login Item,
  and local client approvals after an upgrade. A forced kill or power loss in
  the multi-file activation window also cannot be rolled back automatically.
- Resolution: distribute with a stable Developer ID signing identity and
  notarization. Add an activation journal and startup recovery if interruption
  resilience becomes necessary before that release channel exists.

### 4. Tunnel failure diagnostics are incomplete

The tunnel supervisor now serializes lifecycle changes, waits for a bounded
termination grace period, and bounds health probes. It only keeps transient
status text, so the reason for a failed tunnel start or control-plane check is
lost after a restart.

- Evidence: `Sources/MacAgentBridge/ChatGPTTunnelSupervisor.swift`.
- Impact: duplicate-process and stuck-probe failure modes are addressed, but
  intermittent remote failures remain harder to diagnose after the fact.
- Resolution: persist a bounded, redacted diagnostic history for failed
  init, health, and run phases, and expose it through the menu and
  `bridge_status`.

## Medium Priority

### 5. Dependency resolution is not fully reproducible

`mail-mcp` is downloaded with a pinned checksum. CheICalMCP is pinned to a git
commit, but its SwiftPM dependency graph is resolved on the target Mac.
`Package.resolved` is ignored, and `UPSTREAMS.lock.json` is not consumed by
SwiftPM or the installer.

- Evidence: `scripts/install-local.sh`, `.gitignore`, and
  `UPSTREAMS.lock.json`.
- Impact: a clean installation can build a different transitive dependency set
  from the one validated locally.
- Resolution: commit and enforce resolution files for both bridge and pinned
  sidecar builds, or distribute verified release artifacts for every dependency
  boundary.

### 6. Reader transport needs resource and TLS hardening

Custom IMAP configuration permits `plain` authentication despite the security
model describing TLS connections. The local IPC server has no maximum buffered
JSON-line frame and no connection or request limits.

- Evidence: `Sources/MacAgentBridge/MailSidecarConfiguration.swift` and
  `Sources/MacAgentBridge/LocalBridgeIPC.swift`.
- Impact: accidental plaintext credential transport for custom providers and
  same-user resource exhaustion against the IPC host.
- Resolution: reject plaintext by default behind an explicit, separately
  reviewed unsafe override; cap frame size, active clients, request duration,
  and queued work.

### 7. App bundle ownership is unclear for the EventKit sidecar

The app bundle contains `CheICalMCP`, but generated launch configuration points
to a second copy in `~/.local/opt/mac-agent-bridge/libexec`.

- Evidence: `scripts/build-local-app.sh` embeds the sidecar while
  `scripts/install-local.sh` writes the libexec path into `launch.json`.
- Impact: duplicated artifacts complicate signing, update correctness, and the
  claim that the app is the runtime owner.
- Resolution: choose one authoritative location. Prefer a self-contained app
  bundle for app-owned sidecars, or stop embedding unused binaries.

## Product and Documentation Consistency

### 8. The documented V1 scope includes features not wired into the runtime

`docs/SCOPE.md` describes classification and deduplicated notifications as V1.
`docs/PLAN.md` correctly lists notifications and end-to-end acceptance as future
work. `MailScanner` exists but has no runtime scheduler or macOS notification
implementation, and its default account is only `icloud`.

- Impact: the product boundary is ambiguous, especially for multi-account
  monitoring.
- Resolution: treat interactive reader MCP as the shipped MVP, mark monitor and
  notifications as planned, and define multi-account monitor scheduling before
  wiring it in.

### 9. Threat model contains obsolete claims

The threat model says approval replay is prevented by a short-lived, single-use
token bound to operation arguments. The implementation uses persistent
executable-hash approvals instead. It also calls all sidecars checksum-verified,
which is not true for the CheICalMCP transitive dependency graph.

- Evidence: `docs/THREAT_MODEL.md`, `ClientApprovalStore`, and the installer.
- Resolution: revise claims to match actual controls before presenting the
  document as a security model; add the missing controls only if they remain
  intended requirements.

### 10. Branding has three competing names

The visible menu says `MacMCP`, while the app bundle is `Mac Agent Bridge`, the
server identity is `mac-agent-bridge`, and privacy prompts retain the older
name.

- Evidence: `Packaging/Info.plist`, `Sources/MacAgentBridge/Info.plist`, and
  `Sources/MacAgentBridge/AppVersion.swift`.
- Impact: permission dialogs and MCP discovery are less clear than the menu.
- Resolution: explicitly separate a stable technical server identifier from the
  user-facing product name, then apply the product name consistently to the app
  bundle and TCC wording.

## Verification Gaps

### 11. The automated suite does not exercise a clean install or upgrade

The Swift suite currently passes 115 tests, but packaging tests inspect script
text rather than running a staged install under an isolated `HOME`. It does not
exercise an interrupted upgrade, custom config paths, TCC/Keychain behavior,
sidecar crash recovery, tunnel restart races, a real attachment download, or an
actual remote ChatGPT call.

- Evidence: `Tests/MacAgentBridgeTests/PackagingScriptTests.swift`.
- Resolution: add hermetic installer tests with fake sidecars/tools and a
  dedicated manual release checklist for macOS permissions and remote ChatGPT.

## Recommended Order

1. Remove the direct production bridge path and make approval enforcement
   complete.
2. Implement controlled sidecar recovery after the truthful health checks.
3. Establish stable signing before wider deploy and add an actual installer test.
4. Consolidate tunnel ownership and add persistent diagnostics.
5. Make dependencies reproducible and unify sidecar ownership.
6. Reconcile scope, threat model, branding, and verification gates with the
   actual shipped MVP.
