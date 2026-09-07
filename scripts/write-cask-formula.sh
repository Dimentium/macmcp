#!/bin/bash
set -euo pipefail

usage() {
  cat <<'EOF'
usage: scripts/write-cask-formula.sh --archive PATH [--output PATH]

Creates a Homebrew Cask formula for a signed, notarized MacMCP ZIP already
uploaded to the matching GitHub Release. The archive name must be
MacMCP-VERSION-macos.zip, where VERSION is a numeric semantic version.

Options:
  --archive PATH  required absolute path to MacMCP-VERSION-macos.zip
  --output PATH   absolute Cask output path; default: Casks/macmcp.rb
  -h, --help      show this help
EOF
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd "$script_dir/.." && pwd)"
archive=""
output="$project_dir/Casks/macmcp.rb"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --archive)
      [[ $# -ge 2 ]] || { echo "missing value for --archive" >&2; exit 2; }
      archive="$2"
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

[[ -n "$archive" ]] || { echo "--archive is required" >&2; usage >&2; exit 2; }
for path in "$archive" "$output"; do
  [[ "$path" == /* ]] || { echo "path must be absolute: $path" >&2; exit 2; }
done
[[ -f "$archive" ]] || { echo "archive does not exist: $archive" >&2; exit 1; }
command -v shasum >/dev/null || { echo "missing required tool: shasum" >&2; exit 1; }

archive_name="$(basename "$archive")"
if [[ ! "$archive_name" =~ ^MacMCP-([0-9]+\.[0-9]+\.[0-9]+)-macos\.zip$ ]]; then
  echo "archive name must be MacMCP-VERSION-macos.zip" >&2
  exit 2
fi
version="${BASH_REMATCH[1]}"
sha256="$(shasum -a 256 "$archive" | awk '{print $1}')"

mkdir -p "$(dirname "$output")"
cat > "$output" <<EOF
# typed: strict
# frozen_string_literal: true

cask "macmcp" do
  version "$version"
  sha256 "$sha256"

  url "https://github.com/Dimentium/macmcp/releases/download/v#{version}/MacMCP-#{version}-macos.zip",
      verified: "github.com/Dimentium/macmcp/"
  name "MacMCP"
  desc "Local MCP bridge for mail, Calendar, and Reminders"
  homepage "https://github.com/Dimentium/macmcp"

  depends_on macos: ">= :sonoma"

  app "MacMCP.app"
  binary "#{appdir}/MacMCP.app/Contents/Resources/macmcp"

  zap trash: [
    "~/Library/Application Support/macmcp",
    "~/Library/Caches/macmcp",
  ]
end
EOF

echo "$output"
