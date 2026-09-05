#!/bin/bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 /absolute/path/to/CheICalMCP" >&2
  exit 2
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd "$script_dir/.." && pwd)"
eventkit_binary="$1"
app="$project_dir/.build/local/Mac Agent Bridge.app"
info_plist="$project_dir/Packaging/Info.plist"
entitlements="$project_dir/Sources/MacAgentBridge/Entitlements.plist"
bridge_binary="$project_dir/.build/release/mac-agent-bridge"
app_bridge="$app/Contents/MacOS/mac-agent-bridge"
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
swift build -c release --product mac-agent-bridge
if [[ ! -x "$bridge_binary" ]]; then
  echo "Release bridge binary was not produced" >&2
  exit 1
fi

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$info_plist" "$app/Contents/Info.plist"
cp "$bridge_binary" "$app_bridge"
cp "$eventkit_binary" "$app_eventkit"
chmod 755 "$app_bridge" "$app_eventkit"

codesign --force --sign - --options runtime \
  --entitlements "$entitlements" \
  "$app_bridge"
codesign --force --sign - --options runtime \
  --entitlements "$entitlements" \
  "$app_eventkit"
codesign --force --sign - --options runtime \
  --entitlements "$entitlements" \
  "$app"
codesign --verify --strict --verbose=2 "$app_bridge"
codesign --verify --strict --verbose=2 "$app_eventkit"
codesign --verify --deep --strict --verbose=2 "$app"
echo "$app"
