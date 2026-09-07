#!/bin/bash
set -euo pipefail

usage() {
  cat <<'EOF'
usage: scripts/validate-live-acceptance.sh [--phase NAME] [--require-tunnel] [--skip-mail-validation]

Privacy-safe precondition gate for a live MacMCP acceptance check. It verifies
the installed app-owned runtime and, when requested, the app-managed ChatGPT
tunnel. It prints no account addresses, message data, folder names, client
names, paths, command output, or secrets.

This script cannot prove a ChatGPT UI tool call or a macOS notification was
presented. Complete those two observations manually after this gate passes.

Options:
  --phase NAME               label for the output, e.g. tunnel-reconnect
  --require-tunnel           fail unless the tunnel reports running
  --skip-mail-validation     skip the IMAP no-mutation validation
  -h, --help                 show this help
EOF
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
install_root="${MACMCP_INSTALL_ROOT:-${MAC_AGENT_BRIDGE_INSTALL_ROOT:-$HOME/.local/opt/macmcp}}"
runtime_cli="$install_root/bin/macmcp-bridge"
phase="manual"
require_tunnel=0
skip_mail_validation=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --phase)
      [[ $# -ge 2 ]] || { echo "missing value for --phase" >&2; exit 2; }
      phase="$2"
      shift 2
      ;;
    --require-tunnel)
      require_tunnel=1
      shift
      ;;
    --skip-mail-validation)
      skip_mail_validation=1
      shift
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

[[ -x "$runtime_cli" ]] || {
  echo "runtime_cli=FAIL reason=not_installed"
  exit 1
}

diagnostics="$($runtime_cli --diagnose-json)" || {
  echo "diagnostics=FAIL reason=unavailable"
  exit 1
}

python3 - "$diagnostics" "$phase" "$require_tunnel" <<'PY'
import json
import sys

raw, phase, require_tunnel = sys.argv[1:]
try:
    report = json.loads(raw)
except Exception:
    print("diagnostics=FAIL reason=invalid_json")
    sys.exit(1)

if report.get("schemaVersion") != 1:
    print("diagnostics=FAIL reason=unsupported_schema")
    sys.exit(1)
bridge = report.get("bridge") or {}
if bridge.get("availability") != "available":
    print("runtime=FAIL reason=bridge_unavailable")
    sys.exit(1)
status = bridge.get("status") or {}
if status.get("writeCapabilitiesEnabled") is not False:
    print("runtime=FAIL reason=reader_contract")
    sys.exit(1)
if require_tunnel == "1" and report.get("tunnel") != "running":
    print("tunnel=FAIL reason=not_running")
    sys.exit(1)

print("macmcp-live-acceptance")
print(f"phase={phase}")
print("runtime=PASS reader_only=true")
print("tunnel=" + ("PASS running" if require_tunnel == "1" else "SKIP not_required"))
PY

if [[ "$skip_mail_validation" -eq 0 ]]; then
  "$script_dir/validate-local-mail-readonly.py"
else
  echo "mail_no_mutation=SKIP"
fi

echo "manual_chatgpt_tool_call=REQUIRED"
echo "manual_notification_delivery=REQUIRED"
