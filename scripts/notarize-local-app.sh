#!/bin/bash
set -euo pipefail

usage() {
  cat <<'EOF'
usage: scripts/notarize-local-app.sh --signing-identity "Developer ID Application: Name (TEAMID)" [options]

Builds a signed MacMCP.app from pinned sources, submits it to Apple for
notarization, staples the accepted ticket, and produces a distributable ZIP.
It also produces a drag-and-drop DMG for users who do not have Homebrew or
administrator access. This script needs a Developer ID Application certificate
and an existing notarytool Keychain profile. It never reads API-key files or
stores secrets.

Options:
  --signing-identity ID  required unless MACMCP_SIGNING_IDENTITY is set
  --signing-keychain PATH optional Keychain containing the signing identity
  --notary-profile NAME  notarytool Keychain profile; default: macmcp-notarization
  --tunnel-client PATH   tunnel-client executable to embed in the app; default: PATH lookup
  --dist-dir PATH        absolute final artifact directory; default: dist
  --build-root PATH      absolute temporary build directory; default: .build/notarization
  -h, --help             show this help
EOF
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd "$script_dir/.." && pwd)"
tunnel_client_version_file="$project_dir/Packaging/tunnel-client.version"
signing_identity="${MACMCP_SIGNING_IDENTITY:-}"
signing_keychain="${MACMCP_SIGNING_KEYCHAIN:-}"
notary_profile="${MACMCP_NOTARY_PROFILE:-macmcp-notarization}"
tunnel_client="${MACMCP_TUNNEL_CLIENT:-}"
dist_dir="${MACMCP_DIST_DIR:-$project_dir/dist}"
build_root="${MACMCP_NOTARIZATION_BUILD_ROOT:-$project_dir/.build/notarization}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --signing-identity)
      [[ $# -ge 2 ]] || { echo "missing value for --signing-identity" >&2; exit 2; }
      signing_identity="$2"
      shift 2
      ;;
    --signing-keychain)
      [[ $# -ge 2 ]] || { echo "missing value for --signing-keychain" >&2; exit 2; }
      signing_keychain="$2"
      shift 2
      ;;
    --notary-profile)
      [[ $# -ge 2 ]] || { echo "missing value for --notary-profile" >&2; exit 2; }
      notary_profile="$2"
      shift 2
      ;;
    --tunnel-client)
      [[ $# -ge 2 ]] || { echo "missing value for --tunnel-client" >&2; exit 2; }
      tunnel_client="$2"
      shift 2
      ;;
    --dist-dir)
      [[ $# -ge 2 ]] || { echo "missing value for --dist-dir" >&2; exit 2; }
      dist_dir="$2"
      shift 2
      ;;
    --build-root)
      [[ $# -ge 2 ]] || { echo "missing value for --build-root" >&2; exit 2; }
      build_root="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "$tunnel_client" ]]; then
  tunnel_client="$(command -v tunnel-client || true)"
fi
[[ -n "$tunnel_client" && -x "$tunnel_client" ]] || {
  echo "tunnel-client is required to build the distributable MacMCP app" >&2
  echo "Install it with the OpenAI Homebrew tap or pass --tunnel-client PATH" >&2
  exit 1
}
[[ "$(basename "$tunnel_client")" == "tunnel-client" ]] || {
  echo "--tunnel-client must name tunnel-client" >&2
  exit 2
}
[[ -f "$tunnel_client_version_file" ]] || {
  echo "missing pinned tunnel-client version: $tunnel_client_version_file" >&2
  exit 1
}
tunnel_client_version="$(<"$tunnel_client_version_file")"
actual_tunnel_client_version="$($tunnel_client --version 2>/dev/null || true)"
[[ "$actual_tunnel_client_version" == "$tunnel_client_version"* ]] || {
  echo "tunnel-client version mismatch: expected $tunnel_client_version, got $actual_tunnel_client_version" >&2
  exit 1
}

[[ -n "$signing_identity" ]] || {
  echo "--signing-identity is required" >&2
  usage >&2
  exit 2
}
if [[ "$signing_identity" != "Developer ID Application:"* ]]; then
  echo "signing identity must be a Developer ID Application certificate" >&2
  exit 2
fi
if [[ -n "$signing_keychain" && ( "$signing_keychain" != /* || ! -e "$signing_keychain" ) ]]; then
  echo "signing Keychain must be an existing absolute path: $signing_keychain" >&2
  exit 2
fi
for path in "$dist_dir" "$build_root"; do
  if [[ "$path" != /* ]]; then
    echo "path must be absolute: $path" >&2
    exit 2
  fi
done
for tool in codesign ditto plutil shasum spctl xcrun; do
  command -v "$tool" >/dev/null || {
    echo "missing required tool: $tool" >&2
    exit 1
  }
done

mkdir -p "$dist_dir" "$build_root"
mail_binary="$("$script_dir/build-pinned-mail-sidecar.sh" --build-root "$build_root/mail")"
eventkit_binary="$("$script_dir/build-pinned-eventkit-sidecar.sh" --build-root "$build_root/eventkit")"
build_arguments=(
  "$script_dir/build-local-app.sh"
  "$eventkit_binary"
  --mail-sidecar "$mail_binary"
  --tunnel-client "$tunnel_client"
  --signing-identity "$signing_identity"
  --output "$build_root/app"
)
if [[ -n "$signing_keychain" ]]; then
  build_arguments+=(--signing-keychain "$signing_keychain")
fi
app="$("${build_arguments[@]}")"
version="$(plutil -extract CFBundleShortVersionString raw "$app/Contents/Info.plist")"
archive="$dist_dir/MacMCP-$version-macos.zip"
checksum="$archive.sha256"

codesign --verify --deep --strict --verbose=2 "$app"
rm -f "$archive" "$checksum"
ditto -c -k --sequesterRsrc --keepParent "$app" "$archive"

echo "Submitting MacMCP $version to Apple notarization" >&2
xcrun notarytool submit "$archive" --keychain-profile "$notary_profile" --wait
xcrun stapler staple "$app"
xcrun stapler validate "$app"
spctl --assess --type execute --verbose=4 "$app"

rm -f "$archive"
ditto -c -k --sequesterRsrc --keepParent "$app" "$archive"
shasum -a 256 "$archive" > "$checksum"

dmg="$dist_dir/MacMCP-$version-macos.dmg"
dmg_checksum="$dmg.sha256"
"$script_dir/create-release-dmg.sh" --app "$app" --output "$dmg" >/dev/null
shasum -a 256 "$dmg" > "$dmg_checksum"

cat <<EOF
Created signed and notarized app artifacts:
  $archive
  $checksum
  $dmg
  $dmg_checksum
EOF
