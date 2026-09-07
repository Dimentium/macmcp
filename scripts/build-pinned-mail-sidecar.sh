#!/bin/bash
set -euo pipefail

MAIL_REPO="https://github.com/Dimentium/mail-mcp"
MAIL_VERSION="v1.2.2"
MAIL_ARM64_SHA256="617e3322c2d240957767242d36dfd27f78d75f0dffff7c97c1538c597825b8e4"
MAIL_AMD64_SHA256="83ddb17c30da07e6be502cb1df230d6c9fb453cb52e5e79ea1980db666c6f4ac"

usage() {
  cat <<'EOF'
usage: scripts/build-pinned-mail-sidecar.sh [--build-root PATH]

Downloads the pinned mail-mcp release for the current macOS architecture,
verifies its SHA-256, and writes the absolute executable path to stdout.
Progress and errors are written to stderr so this command can be used in
command substitution.

Options:
  --build-root PATH  workspace for the verified release archive and binary
                      default: .build/mail
  -h, --help         show this help
EOF
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd "$script_dir/.." && pwd)"
build_root="${MACMCP_MAIL_BUILD_ROOT:-$project_dir/.build/mail}"

while [[ $# -gt 0 ]]; do
  case "$1" in
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

if [[ "$build_root" != /* ]]; then
  echo "build root must be absolute: $build_root" >&2
  exit 2
fi
for tool in curl find shasum tar; do
  command -v "$tool" >/dev/null || {
    echo "missing required tool: $tool" >&2
    exit 1
  }
done

case "$(uname -m)" in
  arm64)
    mail_asset="mail-mcp-darwin-arm64.tar.gz"
    mail_sha256="$MAIL_ARM64_SHA256"
    ;;
  x86_64)
    mail_asset="mail-mcp-darwin-amd64.tar.gz"
    mail_sha256="$MAIL_AMD64_SHA256"
    ;;
  *)
    echo "unsupported macOS architecture: $(uname -m)" >&2
    exit 1
    ;;
esac

archive="$build_root/$mail_asset"
extract_dir="$build_root/extract"
mail_binary="$build_root/mail-mcp"

mkdir -p "$build_root"
echo "Downloading pinned mail-mcp $MAIL_VERSION for $(uname -m)" >&2
curl -fL "$MAIL_REPO/releases/download/$MAIL_VERSION/$mail_asset" -o "$archive"
actual_sha256="$(shasum -a 256 "$archive" | awk '{print $1}')"
if [[ "$actual_sha256" != "$mail_sha256" ]]; then
  echo "mail-mcp checksum mismatch" >&2
  echo "expected: $mail_sha256" >&2
  echo "actual:   $actual_sha256" >&2
  exit 1
fi

rm -rf "$extract_dir"
mkdir -p "$extract_dir"
tar -xzf "$archive" -C "$extract_dir"
mail_candidate="$(find "$extract_dir" -type f \( -name 'mail-mcp' -o -name 'mail-mcp-darwin-*' \) | sort | head -n 1)"
if [[ -z "$mail_candidate" ]]; then
  echo "mail-mcp binary was not found in $mail_asset" >&2
  exit 1
fi

cp "$mail_candidate" "$mail_binary"
chmod 755 "$mail_binary"
printf '%s\n' "$mail_binary"
