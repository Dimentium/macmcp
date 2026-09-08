# Signing and Notarization

This repository has two intentionally separate installation paths:

- `scripts/install-local.sh` is a source installer. It builds locally and uses
  an ad-hoc signature, so it does not need a developer certificate on the
  target Mac.
- `scripts/notarize-local-app.sh` is the release path. It creates a Developer
  ID-signed, Apple-notarized `MacMCP.app` with a stable macOS code identity.

The release script embeds the pinned `mail-mcp` and EventKit sidecars in the
app bundle, which is the artifact distributed by the Homebrew Cask. Per-user
mail account configuration and Keychain secrets remain outside the bundle.

## One-Time Release-Machine Setup

Import a `Developer ID Application` certificate into the login keychain. Store
an App Store Connect team API key as a `notarytool` Keychain profile. Do not put
the `.p8` file, API key ID, issuer ID, or passwords in this repository.

The release build compiles the bridge, `mail-mcp`, and `CheICalMCP` from their
pinned source revisions. Install Xcode Command Line Tools with Swift 6.1 or
later, Go 1.25.4 or later, Git, and Python 3. The release Mac also needs
outbound access to GitHub, the Go module proxy, and the pinned Swift package
repositories while building.

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

## Publish a Release

The normal release path is one command. First bump all source version fields,
commit the intended release, and ensure the worktree is clean. The command
runs the full tests, builds the pinned sidecars, signs and notarizes the app,
validates Gatekeeper, tags and pushes the source commit, creates the GitHub
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
runtime is `MacMCP 0.2.19`; changes to these scripts and docs do not require a
new binary release by themselves.

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
Apple, staples the accepted ticket, performs Gatekeeper assessment, and writes:

```text
dist/MacMCP-<version>-macos.zip
dist/MacMCP-<version>-macos.zip.sha256
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
After creating the signed artifact, create a GitHub Release for the matching
`v<version>` tag and upload both files from `dist/`. Then generate and commit
the Cask formula with the archive that was uploaded:

```sh
scripts/write-cask-formula.sh \
  --archive /absolute/path/to/dist/MacMCP-<version>-macos.zip
git add Casks/macmcp.rb
git commit -m "Publish MacMCP <version> Cask"
git push public public-main:main
```

The generated Cask installs `MacMCP.app` and exposes its bundle-owned `macmcp`
command. `brew uninstall --cask macmcp` leaves Keychain secrets and user
configuration intact; `--zap` removes configuration and caches but never
removes Keychain records.
