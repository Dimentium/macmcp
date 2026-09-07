#!/bin/bash
set -euo pipefail

usage() {
  cat <<'EOF'
usage: scripts/validate-local-mcp.sh

Runs the privacy-safe local MCP acceptance check against the installed
app-owned bridge. It validates diagnostics, the complete tool surface and
structured output, Mail folder access, Calendar, Reminders, and Mail
reader calls. It never starts tunnel-client and never creates or modifies mail
data.

Environment overrides:
  MACMCP_BRIDGE_PATH       app-owned macmcp-bridge executable
  MACMCP_IPC_SOCKET        app-owned local MCP socket
  MACMCP_LOCAL_CONFIG      optional standalone MCP JSON config
  MACMCP_VALIDATION_MCP_TIMEOUT  per-request timeout in seconds (default: 120)

  -h, --help               show this help
EOF
}

case "${1:-}" in
  "") ;;
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

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$script_dir/validate-local-mcp.py"
