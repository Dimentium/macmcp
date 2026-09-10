#!/bin/bash
set -euo pipefail

usage() {
  cat <<'EOF'
usage: scripts/build-local-app.sh /absolute/path/to/CheICalMCP [options]

Builds MacMCP.app. The default ad-hoc signature is intended for the local
source installer. A Developer ID Application identity creates a distributable
signed app with a secure timestamp.

Options:
  --mail-sidecar PATH    embed the verified mail-mcp executable in the app
  --tunnel-client PATH   embed tunnel-client and its adjacent companions in the app
  --signing-identity ID  codesign identity; default: MACMCP_SIGNING_IDENTITY or -
  --signing-keychain PATH Keychain containing the signing identity; optional
  --output PATH          absolute build output directory; default: .build/local
  -h, --help             show this help
EOF
}

[[ $# -ge 1 ]] || { usage >&2; exit 2; }

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd "$script_dir/.." && pwd)"
eventkit_binary="$1"
shift
mail_binary=""
tunnel_client_binary=""
signing_identity="${MACMCP_SIGNING_IDENTITY:--}"
signing_keychain="${MACMCP_SIGNING_KEYCHAIN:-}"
output_dir="${MACMCP_APP_BUILD_ROOT:-$project_dir/.build/local}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mail-sidecar)
      [[ $# -ge 2 ]] || { echo "missing value for --mail-sidecar" >&2; exit 2; }
      mail_binary="$2"
      shift 2
      ;;
    --tunnel-client)
      [[ $# -ge 2 ]] || { echo "missing value for --tunnel-client" >&2; exit 2; }
      tunnel_client_binary="$2"
      shift 2
      ;;
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

if [[ -n "$signing_keychain" && ( "$signing_keychain" != /* || ! -e "$signing_keychain" ) ]]; then
  echo "signing Keychain must be an existing absolute path: $signing_keychain" >&2
  exit 2
fi

app="$output_dir/MacMCP.app"
info_plist="$project_dir/Packaging/Info.plist"
entitlements="$project_dir/Sources/MacMCPBridge/Entitlements.plist"
bridge_binary="$project_dir/.build/release/macmcp-bridge"
app_bridge="$app/Contents/MacOS/macmcp-bridge"
app_eventkit="$app/Contents/Resources/CheICalMCP"
app_mail="$app/Contents/Resources/mail-mcp"
app_cli="$app/Contents/Resources/macmcp"
app_tunnel_dir="$app/Contents/Resources/tunnel-client"
app_tunnel_client="$app_tunnel_dir/tunnel-client"
app_tunnel_cloudflared="$app_tunnel_dir/cloudflared"
app_notices="$app/Contents/Resources/ThirdPartyNotices"
cask_cli="$project_dir/Packaging/macmcp"
notices_dir="$project_dir/Packaging/ThirdPartyNotices"

if [[ "$eventkit_binary" != /* ]]; then
  echo "CheICalMCP path must be absolute: $eventkit_binary" >&2
  exit 2
fi

if [[ ! -x "$eventkit_binary" ]]; then
  echo "CheICalMCP is not executable: $eventkit_binary" >&2
  exit 2
fi

if [[ -n "$mail_binary" && "$mail_binary" != /* ]]; then
  echo "mail-mcp path must be absolute: $mail_binary" >&2
  exit 2
fi

if [[ -n "$mail_binary" && ! -x "$mail_binary" ]]; then
  echo "mail-mcp is not executable: $mail_binary" >&2
  exit 2
fi

if [[ -n "$tunnel_client_binary" && "$tunnel_client_binary" != /* ]]; then
  echo "tunnel-client path must be absolute: $tunnel_client_binary" >&2
  exit 2
fi
if [[ -n "$tunnel_client_binary" && ! -x "$tunnel_client_binary" ]]; then
  echo "tunnel-client is not executable: $tunnel_client_binary" >&2
  exit 2
fi
if [[ -n "$tunnel_client_binary" && "$(basename "$tunnel_client_binary")" != "tunnel-client" ]]; then
  echo "tunnel-client path must name tunnel-client" >&2
  exit 2
fi

if [[ ! -f "$info_plist" || ! -f "$entitlements" || ! -f "$cask_cli" || ! -d "$notices_dir" ]]; then
  echo "Packaging template or entitlements file is missing" >&2
  exit 2
fi

cd "$project_dir"
plutil -lint "$info_plist" "$entitlements" >/dev/null
# Keep the final app path as this script's only stdout value for callers.
"$script_dir/patch-mcp-sdk-stdio.sh" --package-path "$project_dir" >&2
swift build -c release --product macmcp-bridge >&2
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
cp "$cask_cli" "$app_cli"
cp -R "$notices_dir" "$app_notices"
if [[ -n "$mail_binary" ]]; then
  cp "$mail_binary" "$app_mail"
fi
if [[ -n "$tunnel_client_binary" ]]; then
  resolve_tunnel_client_path() {
    local path="$1"
    while [[ -L "$path" ]]; do
      local directory
      directory="$(cd -P "$(dirname "$path")" && pwd)"
      local link
      link="$(readlink "$path")"
      [[ "$link" == /* ]] || link="$directory/$link"
      path="$link"
    done
    printf '%s\n' "$path"
  }

  tunnel_client_real_path="$(resolve_tunnel_client_path "$tunnel_client_binary")"
  tunnel_client_source_dirs=(
    "$(dirname "$tunnel_client_real_path")"
    "$(dirname "$tunnel_client_real_path")/../libexec"
  )
  mkdir -p "$app_tunnel_dir"
  cp "$tunnel_client_real_path" "$app_tunnel_client"
  for companion in cloudflared cloudflared-manifest.json; do
    for source_dir in "${tunnel_client_source_dirs[@]}"; do
      if [[ -f "$source_dir/$companion" ]]; then
        cp "$source_dir/$companion" "$app_tunnel_dir/$companion"
        break
      fi
    done
  done
  for notice in LICENSE NOTICE sbom.spdx.json; do
    for source_dir in "${tunnel_client_source_dirs[@]}" "$(dirname "$tunnel_client_real_path")/.."; do
      if [[ -f "$source_dir/$notice" ]]; then
        mkdir -p "$app_notices/tunnel-client"
        cp "$source_dir/$notice" "$app_notices/tunnel-client/$notice"
        break
      fi
    done
  done
fi
chmod 755 "$app_bridge" "$app_eventkit" "$app_cli"
[[ -z "$mail_binary" ]] || chmod 755 "$app_mail"
[[ -z "$tunnel_client_binary" ]] || chmod 755 "$app_tunnel_client"
[[ ! -f "$app_tunnel_cloudflared" ]] || chmod 755 "$app_tunnel_cloudflared"

sign_target() {
  local target="$1"
  local needs_eventkit_entitlements="${2:-0}"
  local arguments=(--force --sign "$signing_identity" --options runtime)
  if [[ -n "$signing_keychain" ]]; then
    arguments+=(--keychain "$signing_keychain")
  fi
  if [[ "$needs_eventkit_entitlements" == "1" ]]; then
    arguments+=(--entitlements "$entitlements")
  fi
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

sign_target "$app_bridge" 1
sign_target "$app_eventkit" 1
if [[ -n "$mail_binary" ]]; then
  sign_target "$app_mail"
fi
if [[ -n "$tunnel_client_binary" ]]; then
  sign_target "$app_tunnel_client"
  if [[ -f "$app_tunnel_cloudflared" ]]; then
    sign_target "$app_tunnel_cloudflared"
  fi
fi
sign_target "$app" 1
codesign --verify --strict --verbose=2 "$app_bridge"
codesign --verify --strict --verbose=2 "$app_eventkit"
if [[ -n "$mail_binary" ]]; then
  codesign --verify --strict --verbose=2 "$app_mail"
fi
if [[ -n "$tunnel_client_binary" ]]; then
  codesign --verify --strict --verbose=2 "$app_tunnel_client"
  if [[ -f "$app_tunnel_cloudflared" ]]; then
    codesign --verify --strict --verbose=2 "$app_tunnel_cloudflared"
  fi
fi
codesign --verify --deep --strict --verbose=2 "$app"
if [[ "$signing_identity" != "-" ]]; then
  verify_secure_timestamp "$app_bridge"
  verify_secure_timestamp "$app_eventkit"
  if [[ -n "$mail_binary" ]]; then
    verify_secure_timestamp "$app_mail"
  fi
  if [[ -n "$tunnel_client_binary" ]]; then
    verify_secure_timestamp "$app_tunnel_client"
    if [[ -f "$app_tunnel_cloudflared" ]]; then
      verify_secure_timestamp "$app_tunnel_cloudflared"
    fi
  fi
  verify_secure_timestamp "$app"
fi
echo "$app"
