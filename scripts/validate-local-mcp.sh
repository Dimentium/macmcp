#!/bin/bash
set -euo pipefail

usage() {
  cat <<'EOF'
usage: scripts/validate-local-mcp.sh [--attachment-fixture]

Runs the privacy-safe local MCP acceptance check against the installed
app-owned bridge. It validates diagnostics, the complete tool surface and
structured output, Mail folder access, Calendar, Reminders, and Mail
reader calls. It never starts tunnel-client and never creates or modifies mail
data. With --attachment-fixture it additionally reads one existing, opt-in
attachment fixture; that mode still never modifies mail data.

Environment overrides:
  MACMCP_BRIDGE_PATH       app-owned macmcp-bridge executable
  MACMCP_IPC_SOCKET        app-owned local MCP socket
  MACMCP_LOCAL_CONFIG      optional standalone MCP JSON config
  MACMCP_VALIDATION_MCP_TIMEOUT  per-request timeout in seconds (default: 120)
  MACMCP_ATTACHMENT_FIXTURE_ACCOUNT  fixture account id (default: gmail)
  MACMCP_ATTACHMENT_FIXTURE_FOLDER   fixture folder (default: [Gmail]/Drafts)
  MACMCP_ATTACHMENT_FIXTURE_SUBJECT  fixture subject

  -h, --help               show this help
EOF
}

python_args=()
for argument in "$@"; do
  case "$argument" in
    --attachment-fixture)
      python_args+=("$argument")
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown option: $argument" >&2
      usage >&2
      exit 2
      ;;
  esac
done

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ((${#python_args[@]})); then
  exec python3 "$script_dir/validate-local-mcp.py" "${python_args[@]}"
else
  exec python3 "$script_dir/validate-local-mcp.py"
fi
