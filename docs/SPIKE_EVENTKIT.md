# EventKit / launchd spike

Status: source analysis, interactive read validation, GUI/menu-bar host work,
and local install smoke are complete. Reboot persistence is deferred until the
menu-bar app owns the single runtime.

## Upstream examined

- Repository: `https://github.com/PsychQuant/che-ical-mcp`
- Commit: `a8598378b5e280b27005ab8cd21e9b5758312423` (`v1.16.1`)
- License: MIT
- Platform: macOS 14+
- Swift tools version: 5.9
- Transport: MCP over stdio, plus a JSON CLI mode

The repository previously appeared under `kiki830621`; its own installation
and release metadata now use the `PsychQuant` organization. New configuration
must use the canonical location.

## Source findings

- Calendar and Reminders use EventKit rather than AppleScript or private
  databases.
- The executable embeds an Info.plist containing Calendar and Reminders full
  access usage descriptions.
- Release builds carry the unrestricted Calendar and Reminders entitlements.
- The project has a dedicated `--setup` flow intended to request permission in
  an interactive GUI session before a launchd job starts.
- A non-interactive `--setup` fails instead of hanging when authorization is
  still undetermined.
- Current releases detect TCC drift and print the responsible process chain.
- TCC may attribute access to the responsible parent process rather than only
  the sidecar. An ad-hoc identity can therefore lose access after an update.

## Architectural consequence

This is a local-only project. The final runtime is a Developer ID-signed,
Apple-notarized foreground GUI app that can show TCC prompts. Its stable signing
identity is intended to retain Calendar and Reminders access across Cask
updates. A source install remains ad-hoc signed and can require permissions
again after a replacement.

A raw LaunchAgent whose process is a direct child of launchd is not sufficient
with the tested ad-hoc build. In that context EventKit reports `notDetermined`,
while the identical binary reports `fullAccess` under an interactive host, and
upstream intentionally suppresses permission requests when `ppid == 1`.

The deployed runtime launches the pinned CheICalMCP sidecar from the signed
GUI/menu-bar app. The app may be started as a Login Item or through
LaunchServices, but not as a headless raw CLI LaunchAgent.

## Reader allowlist

Only these upstream tools may be projected through the reader gateway:

- `list_calendars`
- `list_events`
- `list_events_quick`
- `search_events`
- `check_conflicts`
- `find_duplicate_events`
- `list_reminders`
- `search_reminders`
- `list_reminder_tags`

All create, update, complete, copy, move, delete, cleanup, undo, and redo tools
are denied even if the sidecar advertises them.

## Live macOS validation procedure

Use the exact binary that launchd will later execute. Do not overwrite it in
place during the test.

1. Verify that its ad-hoc signature is internally valid and that the required
   entitlements are present:

   ```sh
   codesign --verify --deep --strict --verbose=2 "$CHE_ICAL_BIN"
   codesign -d --entitlements :- "$CHE_ICAL_BIN"
   ```

2. From an interactive local Terminal session, run:

   ```sh
   "$CHE_ICAL_BIN" --setup
   "$CHE_ICAL_BIN" --print-tcc-path
   echo '{"tool":"list_calendars","arguments":{}}' | "$CHE_ICAL_BIN" --cli
   echo '{"tool":"list_events_quick","arguments":{"range":"today"}}' | "$CHE_ICAL_BIN" --cli
   echo '{"tool":"list_reminders","arguments":{"limit":1}}' | "$CHE_ICAL_BIN" --cli
   ```

3. Run the same three read calls from the final GUI/menu-bar bridge host. Record
   the responsible-process chain, stdout, stderr, and exit status.
4. Restart that host through its intended Login Item/LaunchServices path and
   repeat without another permission prompt.
5. Reboot once and repeat without replacing either binary.
6. After a Cask update, verify the foreground permission flow only if macOS
   asks again or the sidecar reports a denied state. Source-install replacements
   can require a fresh grant.

## Pass conditions

- All three read calls work directly and under the final GUI host.
- No write tool is invoked during the test.
- Authorization survives process restart and reboot while binary hashes remain
  unchanged.
- After a binary update, the documented re-grant procedure restores access.
- No Full Disk Access or Automation permission is needed.
- A denied/revoked permission produces a closed failure and actionable status.

## Remaining validation item

On the target Apple Silicon Mac, interactive read-only calls work both directly
and through the bridge. The malformed published artifact was replaced by an
arm64 build from pinned v1.16.1 source, ad-hoc signed with hardened runtime and
the upstream EventKit entitlements; strict verification passes. Under launchd,
however, the identical binary reports both permissions as `notDetermined`;
Calendar calls fail closed and Reminders does not finish in the bounded window.
Running `--setup` as an Interactive LaunchAgent is still classified as
non-interactive and skips both requests.

The adopted path is the installed GUI/menu-bar app. App-owned restart validation
has passed; reboot/Login Item persistence with unchanged app and sidecar hashes
remains open. See `MAC_VALIDATION.md` for recorded evidence and `PLAN.md` for
the forward plan.
