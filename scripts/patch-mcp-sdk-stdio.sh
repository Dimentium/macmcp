#!/bin/bash
set -euo pipefail

usage() {
  cat <<'EOF'
usage: scripts/patch-mcp-sdk-stdio.sh [--package-path PATH]

Applies MacMCP's idle-safe stdio transport patch to the resolved MCP Swift SDK
checkout. The patch is kept in Packaging because SwiftPM dependencies are
generated under .build and are not part of this repository.
EOF
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd "$script_dir/.." && pwd)"
package_path="$project_dir"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --package-path)
      [[ $# -ge 2 ]] || { echo "missing value for --package-path" >&2; exit 2; }
      package_path="$2"
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

if [[ "$package_path" != /* ]]; then
  echo "package path must be absolute: $package_path" >&2
  exit 2
fi

command -v swift >/dev/null || {
  echo "missing required command: swift" >&2
  exit 1
}

patch_file="$project_dir/Packaging/mcp-sdk-stdio-idle.patch"
swift_sdk="$package_path/.build/checkouts/swift-sdk"
transport="$swift_sdk/Sources/MCP/Base/Transports/StdioTransport.swift"

swift package resolve --disable-automatic-resolution --package-path "$package_path" >&2
[[ -f "$transport" ]] || {
  echo "Swift MCP SDK checkout was not materialized: $transport" >&2
  exit 1
}

if grep -Fq "MacMCP idle transport: avoid a 100 Hz retry loop" "$transport"; then
  exit 0
fi

chmod u+w "$transport"
git -C "$swift_sdk" apply --check "$patch_file"
git -C "$swift_sdk" apply "$patch_file"
