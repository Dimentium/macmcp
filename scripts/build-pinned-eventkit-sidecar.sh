#!/bin/bash
set -euo pipefail

CHE_REPO="https://github.com/PsychQuant/che-ical-mcp.git"
CHE_COMMIT="a8598378b5e280b27005ab8cd21e9b5758312423"
CHE_RESOLUTION_SHA256="1bbf18605e61eb13014d140fa86e5aa550327bdf005f5567de40db6e2df4b93d"

usage() {
  cat <<'EOF'
usage: scripts/build-pinned-eventkit-sidecar.sh [--build-root PATH]

Builds the reviewed CheICalMCP commit with the pinned Swift package graph.
Writes the absolute path of the resulting executable to stdout. Progress and
errors are written to stderr so this command can be used in command substitution.

Options:
  --build-root PATH  workspace for the upstream checkout and build output
                      default: .build/eventkit
  -h, --help         show this help
EOF
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd "$script_dir/.." && pwd)"
build_root="${MACMCP_EVENTKIT_BUILD_ROOT:-$project_dir/.build/eventkit}"

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

for tool in git shasum swift; do
  command -v "$tool" >/dev/null || {
    echo "missing required tool: $tool" >&2
    exit 1
  }
done

che_src="$build_root/che-ical-mcp"
che_resolution="$project_dir/Packaging/CheICalMCP.Package.resolved"
che_binary="$che_src/.build/release/CheICalMCP"

mkdir -p "$build_root"
if [[ -e "$che_src" && ! -d "$che_src/.git" ]]; then
  echo "EventKit build checkout is not a Git repository: $che_src" >&2
  exit 1
fi

if [[ ! -d "$che_src/.git" ]]; then
  echo "Cloning pinned CheICalMCP source" >&2
  git clone "$CHE_REPO" "$che_src" >&2
fi

actual_remote="$(git -C "$che_src" remote get-url origin)"
if [[ "$actual_remote" != "$CHE_REPO" ]]; then
  echo "EventKit checkout has an unexpected origin: $actual_remote" >&2
  exit 1
fi

[[ -f "$che_resolution" ]] || {
  echo "pinned CheICalMCP resolution is missing" >&2
  exit 1
}
actual_che_resolution_sha256="$(shasum -a 256 "$che_resolution" | awk '{print $1}')"
if [[ "$actual_che_resolution_sha256" != "$CHE_RESOLUTION_SHA256" ]]; then
  echo "CheICalMCP resolution checksum mismatch" >&2
  exit 1
fi

echo "Building pinned CheICalMCP from $CHE_COMMIT" >&2
git -C "$che_src" fetch --tags origin >&2
git -C "$che_src" checkout --detach "$CHE_COMMIT" >&2
cp "$che_resolution" "$che_src/Package.resolved"
swift build --disable-automatic-resolution -c release --product CheICalMCP --package-path "$che_src" >&2

[[ -x "$che_binary" ]] || {
  echo "CheICalMCP release binary was not produced" >&2
  exit 1
}

printf '%s\n' "$che_binary"
