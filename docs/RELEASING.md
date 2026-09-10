# Signing and Notarization

This repository has three user-facing distribution paths and two build
mechanisms:

- the signed release DMG for normal users, which needs neither Homebrew nor
  administrator access;
- the signed Homebrew Cask for command-line setup and upgrades;
- the source formula for inspection and self-builds.

The build mechanisms are:

- `scripts/install-local.sh` is a source installer. It defaults to an ad-hoc
  signature, so it does not need a developer certificate on the target Mac. If
  `MACMCP_SIGNING_IDENTITY` is provided, it signs both the app and its local
  CLI with that identity; this keeps Keychain access under one designated
  requirement. `MACMCP_SIGNING_KEYCHAIN` can select the signing keychain.
- `scripts/notarize-local-app.sh` is the release path. It creates a Developer
  ID-signed, Apple-notarized `MacMCP.app` with a stable macOS code identity.

The release script embeds the pinned `mail-mcp` and EventKit sidecars plus the
signed OpenAI `tunnel-client` and its matching companion files in the app
bundle. It publishes both a ZIP for Homebrew and a drag-and-drop DMG for users
without Homebrew or administrator access. Per-user mail account configuration
and Keychain secrets remain outside the bundle.

## One-Time Release-Machine Setup

Import a `Developer ID Application` certificate into the login keychain. Store
an App Store Connect team API key as a `notarytool` Keychain profile. Do not put
the `.p8` file, API key ID, issuer ID, or passwords in this repository.

The release build compiles the bridge, `mail-mcp`, and `CheICalMCP` from their
pinned source revisions. Install Xcode Command Line Tools with Swift 6.1 or
later, Go 1.25.4 or later, Git, and Python 3. The release Mac also needs
outbound access to GitHub, the Go module proxy, and the pinned Swift package
repositories while building.

The release Mac must also have the OpenAI `tunnel-client` executable available
on `PATH` (for example, `brew install openai/tools/tunnel-client`). The release
build signs and embeds that binary and its companion files so target Macs do
not need to install it separately.

The release Mac also needs outbound access to Apple's code-signing timestamp
service while `codesign` runs. Notarization requires this secure timestamp; a
Developer ID signature without it is intentionally rejected by the release
script.

For example, after creating the Apple API key locally:

```sh
xcrun notarytool store-credentials macmcp-notarization \
  --key /secure/path/AuthKey_ABC123.p8 \
  --key-id ABC123 \
  --issuer 00000000-0000-0000-0000-000000000000
```

The profile name and private key are local-only. Validate it without submitting
software:

```sh
xcrun notarytool history --keychain-profile macmcp-notarization
```

## Update the Changelog

Before changing the source version, update the top `Unreleased` section in
[`changelog.txt`](../changelog.txt) from the Git history since the previous
release tag. Use the commit history as the source of truth, for example:

```sh
git log --no-merges --pretty=format:'- %s' v0.2.24..HEAD
```

Keep the changelog user-facing: summarize meaningful behavior changes and fold
repetitive Cask/formula publication commits into the release entry. Move the
completed bullets into a new dated section named for the version being
released, then leave an empty `Unreleased` section at the top. Do not list
secrets, account data, or internal implementation noise. The changelog update
must be included in the intended source commit before `scripts/release.sh` is
run; the release script intentionally refuses a dirty worktree.

## Publish a Release

The normal release path is one command. First update `changelog.txt`, bump all
source version fields, commit the intended release, and ensure the worktree is
clean. The command
runs the full tests, builds the pinned sidecars, signs and notarizes the app,
creates the ZIP and DMG release artifacts, validates Gatekeeper, tags and pushes
the source commit, creates the GitHub
Release, regenerates and commits the Cask and source formula, and pushes that
metadata commit. Every stage is printed as a numbered step; on failure it
reports the last completed boundary and does not run later publication steps.
Steps include timestamps and elapsed time. The full output is saved in a
private `dist/release-*.log` file, including the failing stage on early exit.

Run this only on the release Mac:

```sh
scripts/release.sh \
  --signing-identity "Developer ID Application: Your Name (TEAMID)" \
  --install-local
```

`--install-local` is optional. It refreshes Homebrew, installs or upgrades the
published Cask, verifies its bundled version, performs a single-instance
MacMCP restart, prints `macmcp diagnose --json`, and runs the privacy-safe
local MCP acceptance test. That final test covers the local bridge, published
tools and structured output, Mail folder/search/read calls, Calendar, and
Reminders. It intentionally does not start or test the ChatGPT tunnel. Omit
`--install-local` when publishing without changing the release Mac's installed
application.

The release script requires an authenticated `gh` CLI, the `public` Git remote,
and the one-time signing/notary setup above. `--remote NAME` and
`--notary-profile NAME` override their defaults. It deliberately refuses a
dirty worktree, mismatched version fields, existing version tag, absent GitHub
authentication, missing artifact, checksum mismatch, or mismatched Cask and
formula revision.

## Local Acceptance Gate

Run the local gate directly from this checkout when diagnosing or verifying an
installed runtime:

```sh
scripts/validate-local-mcp.sh
```

It uses the app-owned bridge and socket, so it also works with a Cask install
that has no standalone `mcp.local.json`. It checks diagnostics, approvals, all
17 published tools, `outputSchema` plus real `structuredContent`, both
configured mail accounts, Calendar, and Reminders. It does not start
`tunnel-client`, create drafts, change message flags, or modify mail data.

The same gate runs automatically as the final step of
`scripts/release.sh --install-local`. The current published and installed
runtime is `MacMCP 0.2.27`; changes to these scripts and docs do not require a
new binary release by themselves. The 0.2.27 publication completed through
Apple notarization, GitHub, and Cask installation. Its local restart initially
exposed that a still-running Codex `macmcp-bridge --stdio-proxy` could be
mistaken for the app runtime; the release helper now matches the app's exact
command line, and the installed runtime passes `macmcp diagnose --json` and
`scripts/validate-local-mcp.sh`.

The 0.2.24 build also patches the pinned MCP Swift SDK's empty-pipe retry from
10 ms to 100 ms. The patch is applied by `scripts/patch-mcp-sdk-stdio.sh` to
both the bridge dependency and the pinned CheICalMCP build.

`scripts/validate-local-mail-readonly.py --deep` remains an optional deeper IMAP
snapshot check. The script refuses to run without `--deep`, so an accidental
invocation cannot touch Keychain or start an IMAP session. The deep check reads
passwords through the macOS `security` CLI and may trigger a Keychain prompt;
it is intentionally not part of the normal release gate.

## Low-Level Notarization

Run this only on the release Mac:

```sh
scripts/notarize-local-app.sh \
  --signing-identity "Developer ID Application: Your Name (TEAMID)"
```

The script builds the pinned EventKit sidecar, applies hardened-runtime signing
and a secure timestamp to the app and nested executable, submits a ZIP to
Apple, staples the accepted ticket, performs Gatekeeper assessment, and writes
both release formats:

```text
dist/MacMCP-<version>-macos.zip
dist/MacMCP-<version>-macos.zip.sha256
dist/MacMCP-<version>-macos.dmg
dist/MacMCP-<version>-macos.dmg.sha256
```

It leaves the currently installed `~/Applications/MacMCP.app` untouched. The
artifact can be inspected before publication with:

```sh
codesign --verify --deep --strict --verbose=2 /path/to/MacMCP.app
spctl --assess --type execute --verbose=4 /path/to/MacMCP.app
```

## Low-Level Cask Publishing

`scripts/release.sh` is preferred. These lower-level commands remain useful
only for diagnosing a failed release step after its state has been inspected.
After creating the signed artifacts, create a GitHub Release for the matching
`v<version>` tag and upload the ZIP, ZIP checksum, DMG, and DMG checksum from
`dist/`. Then generate and commit the Cask formula with the archive that was
uploaded:

```sh
scripts/write-cask-formula.sh \
  --archive /absolute/path/to/dist/MacMCP-<version>-macos.zip
git add Casks/macmcp.rb
git commit -m "Publish MacMCP <version> Cask"
git push public public-main:main
```

The generated Cask installs `MacMCP.app` and exposes its bundle-owned `macmcp`
command. The DMG is intentionally independent of Homebrew and can be copied
to `~/Applications` by a non-admin user. `brew uninstall --cask macmcp` leaves
Keychain secrets and user configuration intact; `--zap` removes configuration
and caches but never removes Keychain records.
