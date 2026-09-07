# Signing and Notarization

This repository has two intentionally separate installation paths:

- `scripts/install-local.sh` is a source installer. It builds locally and uses
  an ad-hoc signature, so it does not need a developer certificate on the
  target Mac.
- `scripts/notarize-local-app.sh` is the release path. It creates a Developer
  ID-signed, Apple-notarized `MacMCP.app` with a stable macOS code identity.

The release script embeds the pinned `mail-mcp` and EventKit sidecars in the
app bundle, so it is the build basis for the future Homebrew Cask. Per-user
mail account configuration and Keychain secrets remain outside the bundle.

## One-Time Release-Machine Setup

Import a `Developer ID Application` certificate into the login keychain. Store
an App Store Connect team API key as a `notarytool` Keychain profile. Do not put
the `.p8` file, API key ID, issuer ID, or passwords in this repository.

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

## Build a Notarized App

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
