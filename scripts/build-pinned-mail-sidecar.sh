#!/bin/bash
set -euo pipefail

MAIL_REPO="https://github.com/Dimentium/mail-mcp.git"
MAIL_VERSION="v1.2.4"
MAIL_COMMIT="e26b28ef87e6eab46d796d63ec1bbaa210d080d4"
MAIL_GO_MOD_SHA256="41c501de585b0948adc7aadf0c80f493d79a29779f1648b99124a20388d643b4"
MAIL_GO_SUM_SHA256="65acf0c5d1563f6749f1fb495f8b1a03edf7882a0e2febb73ed659604062d5e6"
MAIL_MINIMUM_GO_VERSION="1.25.4"

usage() {
  cat <<'EOF'
usage: scripts/build-pinned-mail-sidecar.sh [--build-root PATH]

Builds the pinned mail-mcp source commit with its reviewed Go module graph and
writes the absolute executable path to stdout. Progress and errors are written
to stderr so this command can be used in command substitution.

Options:
  --build-root PATH  workspace for the upstream checkout and build output
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
for tool in git go shasum; do
  command -v "$tool" >/dev/null || {
    echo "missing required tool: $tool" >&2
    if [[ "$tool" == "go" ]]; then
      echo "Install Go with Homebrew: brew install go" >&2
    fi
    exit 1
  }
done

go_version_at_least() {
  local actual="$1"
  local expected="$2"
  local index current required
  local -a actual_parts expected_parts

  IFS='.' read -r -a actual_parts <<< "$actual"
  IFS='.' read -r -a expected_parts <<< "$expected"
  for index in 0 1 2; do
    current="${actual_parts[index]:-0}"
    required="${expected_parts[index]:-0}"
    [[ "$current" =~ ^[0-9]+$ && "$required" =~ ^[0-9]+$ ]] || return 1
    if (( 10#$current > 10#$required )); then
      return 0
    fi
    if (( 10#$current < 10#$required )); then
      return 1
    fi
  done
}

go_version="$(go env GOVERSION)"
go_version="${go_version#go}"
if ! go_version_at_least "$go_version" "$MAIL_MINIMUM_GO_VERSION"; then
  echo "mail-mcp requires Go $MAIL_MINIMUM_GO_VERSION or later; found $go_version" >&2
  exit 1
fi

mail_src="$build_root/mail-mcp-source"
mail_binary="$build_root/mail-mcp"

mkdir -p "$build_root"
if [[ -e "$mail_src" && ! -d "$mail_src/.git" ]]; then
  echo "mail-mcp build checkout is not a Git repository: $mail_src" >&2
  exit 1
fi

if [[ ! -d "$mail_src/.git" ]]; then
  echo "Cloning pinned mail-mcp source" >&2
  git clone "$MAIL_REPO" "$mail_src" >&2
fi

actual_remote="$(git -C "$mail_src" remote get-url origin)"
if [[ "$actual_remote" != "$MAIL_REPO" ]]; then
  echo "mail-mcp checkout has an unexpected origin: $actual_remote" >&2
  exit 1
fi

echo "Building pinned mail-mcp $MAIL_VERSION from $MAIL_COMMIT" >&2
git -C "$mail_src" fetch --tags origin >&2
git -C "$mail_src" checkout --detach "$MAIL_COMMIT" >&2
for spec in "go.mod:$MAIL_GO_MOD_SHA256" "go.sum:$MAIL_GO_SUM_SHA256"; do
  filename="${spec%%:*}"
  expected_sha256="${spec#*:}"
  actual_sha256="$(shasum -a 256 "$mail_src/$filename" | awk '{print $1}')"
  if [[ "$actual_sha256" != "$expected_sha256" ]]; then
    echo "mail-mcp $filename checksum mismatch" >&2
    exit 1
  fi
done

GOWORK=off GOFLAGS= go -C "$mail_src" build -trimpath -mod=readonly -buildvcs=false \
  -ldflags "-s -w -X main.version=$MAIL_VERSION" \
  -o "$mail_binary" \
  ./cmd/mail-mcp \
  >&2
[[ -x "$mail_binary" ]] || {
  echo "mail-mcp release binary was not produced" >&2
  exit 1
}

printf '%s\n' "$mail_binary"
