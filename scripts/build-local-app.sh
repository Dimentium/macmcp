#!/bin/bash
set -euo pipefail

usage() {
  cat <<'EOF'
usage: scripts/build-local-app.sh /absolute/path/to/CheICalMCP [options]

Builds MacMCP.app. The default ad-hoc signature is intended for the local
source installer. A Developer ID Application identity creates a distributable
signed app with a secure timestamp.

Options:
  --signing-identity ID  codesign identity; default: MACMCP_SIGNING_IDENTITY or -
  --output PATH          absolute build output directory; default: .build/local
  -h, --help             show this help
EOF
}

[[ $# -ge 1 ]] || { usage >&2; exit 2; }

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd "$script_dir/.." && pwd)"
eventkit_binary="$1"
shift
signing_identity="${MACMCP_SIGNING_IDENTITY:--}"
output_dir="${MACMCP_APP_BUILD_ROOT:-$project_dir/.build/local}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --signing-identity)
      [[ $# -ge 2 ]] || { echo "missing value for --signing-identity" >&2; exit 2; }
      signing_identity="$2"
      shift 2
      ;;
    --output)
      [[ $# -ge 2 ]] || { echo "missing value for --output" >&2; exit 2; }
      output_dir="$2"
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

if [[ "$output_dir" != /* ]]; then
  echo "app build output must be absolute: $output_dir" >&2
  exit 2
fi

app="$output_dir/MacMCP.app"
info_plist="$project_dir/Packaging/Info.plist"
entitlements="$project_dir/Sources/MacMCPBridge/Entitlements.plist"
bridge_binary="$project_dir/.build/release/macmcp-bridge"
app_bridge="$app/Contents/MacOS/macmcp-bridge"
app_eventkit="$app/Contents/Resources/CheICalMCP"

if [[ "$eventkit_binary" != /* ]]; then
  echo "CheICalMCP path must be absolute: $eventkit_binary" >&2
  exit 2
fi

if [[ ! -x "$eventkit_binary" ]]; then
  echo "CheICalMCP is not executable: $eventkit_binary" >&2
  exit 2
fi

if [[ ! -f "$info_plist" || ! -f "$entitlements" ]]; then
  echo "Packaging template or entitlements file is missing" >&2
  exit 2
fi

cd "$project_dir"
plutil -lint "$info_plist" "$entitlements" >/dev/null
swift build -c release --product macmcp-bridge
if [[ ! -x "$bridge_binary" ]]; then
  echo "Release bridge binary was not produced" >&2
  exit 1
fi

mkdir -p "$output_dir"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$info_plist" "$app/Contents/Info.plist"
cp "$bridge_binary" "$app_bridge"
cp "$eventkit_binary" "$app_eventkit"
chmod 755 "$app_bridge" "$app_eventkit"

sign_target() {
  local target="$1"
  local arguments=(--force --sign "$signing_identity" --options runtime --entitlements "$entitlements")
  if [[ "$signing_identity" != "-" ]]; then
    arguments+=(--timestamp)
  fi
  codesign "${arguments[@]}" "$target"
}

verify_secure_timestamp() {
  local target="$1"
  if ! codesign -dvv "$target" 2>&1 | awk -F= '/^Timestamp=/{ found = 1 } END { exit !found }'; then
    echo "Developer ID signature is missing a secure timestamp: $target" >&2
    exit 1
  fi
}

sign_target "$app_bridge"
sign_target "$app_eventkit"
sign_target "$app"
codesign --verify --strict --verbose=2 "$app_bridge"
codesign --verify --strict --verbose=2 "$app_eventkit"
codesign --verify --deep --strict --verbose=2 "$app"
if [[ "$signing_identity" != "-" ]]; then
  verify_secure_timestamp "$app_bridge"
  verify_secure_timestamp "$app_eventkit"
  verify_secure_timestamp "$app"
fi
echo "$app"
