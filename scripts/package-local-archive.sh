#!/bin/bash
set -euo pipefail

usage() {
  cat <<'EOF'
usage: scripts/package-local-archive.sh [--name NAME] [--dist-dir PATH]

Creates a clean source archive for local mac-agent-bridge installation on
another Mac. The archive includes the installer and project sources, but
excludes git metadata, build output, dist output, runtime state, and local
workspace artifacts.

Options:
  --name NAME       archive base name; default: mac-agent-bridge-local
  --dist-dir PATH   output directory; default: dist
  -h, --help        show this help
EOF
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd "$script_dir/.." && pwd)"
name="${MAC_AGENT_BRIDGE_ARCHIVE_NAME:-mac-agent-bridge-local}"
dist_dir="${MAC_AGENT_BRIDGE_DIST_DIR:-$project_dir/dist}"
build_root="${MAC_AGENT_BRIDGE_PACKAGE_BUILD_ROOT:-$project_dir/.build/package-local}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)
      [[ $# -ge 2 ]] || { echo "missing value for --name" >&2; exit 2; }
      name="$2"
      shift 2
      ;;
    --dist-dir)
      [[ $# -ge 2 ]] || { echo "missing value for --dist-dir" >&2; exit 2; }
      dist_dir="$2"
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

case "$name" in
  ""|*[!A-Za-z0-9._-]*)
    echo "archive name may contain only letters, digits, dot, underscore, and dash" >&2
    exit 2
    ;;
esac

for tool in rsync tar shasum; do
  command -v "$tool" >/dev/null || {
    echo "missing required tool: $tool" >&2
    exit 1
  }
done

staging="$build_root/$name"
archive="$dist_dir/$name.tar.gz"
checksum="$archive.sha256"

rm -rf "$staging"
mkdir -p "$staging" "$dist_dir"

rsync -a \
  --exclude '.git/' \
  --exclude '.github/' \
  --exclude '.build/' \
  --exclude '.swiftpm/' \
  --exclude '.DS_Store' \
  --exclude '__pycache__/' \
  --exclude '*.pyc' \
  --exclude '.claude/' \
  --exclude 'dist/' \
  --exclude 'runtime/' \
  --exclude 'HANDOFF.md' \
  --exclude 'backlog.md' \
  --exclude '*.xcodeproj/' \
  --exclude 'xcuserdata/' \
  "$project_dir/" "$staging/"

rm -f "$archive" "$checksum"
tar -C "$build_root" -czf "$archive" "$name"
shasum -a 256 "$archive" > "$checksum"

cat <<EOF
Created local install archive:
  $archive

Checksum:
  $checksum

Install on another Mac:
  tar -xzf $name.tar.gz
  cd $name
  scripts/install-local.sh --gmail-address you@gmail.com

EOF
