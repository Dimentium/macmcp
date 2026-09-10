#!/bin/bash
set -euo pipefail

usage() {
  cat <<'EOF'
usage: scripts/create-release-dmg.sh --app PATH [--output PATH]

Creates the user-friendly MacMCP disk image for GitHub Releases. The image
contains the signed app, a Finder Applications shortcut, and plain-language
first-run instructions. It does not require Homebrew or administrator access.

Options:
  --app PATH       required signed MacMCP.app path
  --output PATH    absolute output path; default: dist/MacMCP-VERSION-macos.dmg
  -h, --help       show this help
EOF
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd "$script_dir/.." && pwd)"
app=""
output=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app)
      [[ $# -ge 2 ]] || { echo "missing value for --app" >&2; exit 2; }
      app="$2"
      shift 2
      ;;
    --output)
      [[ $# -ge 2 ]] || { echo "missing value for --output" >&2; exit 2; }
      output="$2"
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

[[ -n "$app" ]] || { echo "--app is required" >&2; usage >&2; exit 2; }
[[ "$app" == /* ]] || { echo "app path must be absolute: $app" >&2; exit 2; }
[[ -d "$app" && "$(basename "$app")" == "MacMCP.app" ]] || {
  echo "signed MacMCP.app was not found: $app" >&2
  exit 1
}

for tool in ditto hdiutil plutil; do
  command -v "$tool" >/dev/null || {
    echo "missing required tool: $tool" >&2
    exit 1
  }
done

version="$(plutil -extract CFBundleShortVersionString raw "$app/Contents/Info.plist")"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "app bundle version is invalid: $version" >&2
  exit 1
}

if [[ -z "$output" ]]; then
  output="$project_dir/dist/MacMCP-$version-macos.dmg"
fi
[[ "$output" == /* ]] || { echo "output path must be absolute: $output" >&2; exit 2; }
mkdir -p "$(dirname "$output")"

staging="$(mktemp -d "${TMPDIR:-/tmp}/macmcp-release-dmg.XXXXXX")"
cleanup() {
  rm -rf "$staging"
}
trap cleanup EXIT

ditto "$app" "$staging/MacMCP.app"
ln -s /Applications "$staging/Applications"
cat > "$staging/Read Me First.txt" <<'EOF'
MacMCP — first run

1. Drag MacMCP.app onto Applications.
   If macOS asks for an administrator password, open your Home folder, create
   an Applications folder if needed, and drag it there instead. This works
   without administrator access.

2. Open MacMCP from Applications. If macOS shows a security warning, choose
   Open from the app's right-click menu once.

3. In the MacMCP setup window choose Gmail or iCloud Mail, enter your email,
   and enter an app-specific password. The password is stored in the macOS
   Keychain. Your normal account password is not accepted by these providers.

4. Keep MacMCP running. Its menu-bar item shows the status of Mail, Calendar,
   and Reminders. The setup window also enables Launch at Login by default.

Homebrew is not required. The optional ChatGPT tunnel is configured later
from the MacMCP menu and is not needed for local MCP use.
EOF

rm -f "$output"
hdiutil create \
  -volname "MacMCP" \
  -srcfolder "$staging" \
  -ov \
  -format UDZO \
  "$output" >/dev/null

echo "$output"
