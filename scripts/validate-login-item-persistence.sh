#!/bin/bash
set -euo pipefail

usage() {
  cat <<'EOF'
usage: scripts/validate-login-item-persistence.sh [--phase NAME] [--skip-mail-validation]

Privacy-safe local persistence gate for the installed MacMCP app-owned runtime.
Run once before reboot as a baseline and again after reboot to validate Login
Item persistence. The script prints only aggregate status, counts, and component
states; it does not print account addresses, message data, folder names, or
process command lines.

Options:
  --phase NAME               label for the output, e.g. pre-reboot or post-reboot
  --skip-mail-validation     skip the slower IMAP no-mutation validation
  -h, --help                 show this help
EOF
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd "$script_dir/.." && pwd)"
install_root="${MACMCP_INSTALL_ROOT:-${MAC_AGENT_BRIDGE_INSTALL_ROOT:-$HOME/.local/opt/macmcp}}"
bin_dir="${MACMCP_BIN_DIR:-${MAC_AGENT_BRIDGE_BIN_DIR:-$HOME/.local/bin}}"
app_dir="${MACMCP_APP_DIR:-${MAC_AGENT_BRIDGE_APP_DIR:-$HOME/Applications}}"
config_dir="$HOME/Library/Application Support/macmcp"
phase="manual"
run_mail_validation=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --phase)
      [[ $# -ge 2 ]] || { echo "missing value for --phase" >&2; exit 2; }
      phase="$2"
      shift 2
      ;;
    --skip-mail-validation)
      run_mail_validation=0
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

target_app="$app_dir/MacMCP.app"
app_executable="$target_app/Contents/MacOS/macmcp-bridge"
cli_path="$install_root/bin/macmcp-bridge"
mail_sidecar="$install_root/libexec/mail-mcp"
eventkit_sidecar="$target_app/Contents/Resources/CheICalMCP"
launch_config="$config_dir/launch.json"
ipc_socket="$config_dir/mcp.sock"

failures=0

pass() {
  echo "$1=PASS${2:+ $2}"
}

fail() {
  echo "$1=FAIL${2:+ $2}"
  failures=$((failures + 1))
}

process_count() {
  local pattern="$1"
  local output
  output="$(pgrep -f "$pattern" 2>/dev/null || true)"
  if [[ -z "$output" ]]; then
    echo 0
  else
    printf '%s\n' "$output" | wc -l | tr -d ' '
  fi
}

process_count_excluding_argument() {
  local pattern="$1"
  local excluded_argument="$2"
  local output
  local command_line
  local count=0
  output="$(pgrep -f "$pattern" 2>/dev/null || true)"
  [[ -n "$output" ]] || {
    echo 0
    return 0
  }
  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    command_line="$(ps -p "$pid" -o command= 2>/dev/null || true)"
    [[ "$command_line" == *"$excluded_argument"* ]] && continue
    count=$((count + 1))
  done <<< "$output"
  echo "$count"
}

account_count() {
  python3 - "$launch_config" <<'PY'
import json
import pathlib
import sys

try:
    args = json.loads(pathlib.Path(sys.argv[1]).read_text())["args"]
except Exception:
    sys.exit(1)

count = 0
index = 0
while index < len(args):
    if args[index] == "--allow-unsafe-plain-imap":
        index += 1
    elif args[index] in ("--icloud-address", "--gmail-address", "--mail-account"):
        count += 1
        index += 2
    else:
        index += 1
print(count)
PY
}

tunnel_profile() {
  python3 - "$launch_config" <<'PY'
import json
import pathlib
import sys

try:
    tunnel = json.loads(pathlib.Path(sys.argv[1]).read_text()).get("chatGPTTunnel")
    profile = tunnel.get("profile") if isinstance(tunnel, dict) else None
except Exception:
    sys.exit(1)

if not isinstance(profile, str) or not profile:
    sys.exit(2)
print(profile)
PY
}

parse_status_json() {
  python3 - "$1" <<'PY'
import json
import sys

try:
    status = json.loads(sys.argv[1])
except Exception:
    sys.exit(1)

mail = status.get("mail", "unknown")
calendar = status.get("calendar", "unknown")
reminders = status.get("reminders", "unknown")
writes = status.get("writeCapabilitiesEnabled")
print(f"mail={mail} calendar={calendar} reminders={reminders} writes={str(writes).lower()}")
if mail != "ready" or calendar != "ready" or reminders != "ready" or writes is not False:
    sys.exit(2)
PY
}

parse_approvals_json() {
  python3 - "$1" <<'PY'
import json
import sys

try:
    snapshot = json.loads(sys.argv[1])
except Exception:
    sys.exit(1)

approved = len(snapshot.get("approved", []))
pending = 1 if snapshot.get("pending") else 0
print(f"approved={approved} pending={pending}")
if pending != 0:
    sys.exit(2)
PY
}

echo "macmcp-login-item-validation"
echo "phase=$phase"

[[ -d "$target_app" ]] && pass app_bundle || fail app_bundle
[[ -x "$app_executable" ]] && pass app_executable || fail app_executable
[[ -x "$cli_path" ]] && pass installed_cli || fail installed_cli
[[ -x "$mail_sidecar" ]] && pass mail_sidecar || fail mail_sidecar
[[ -x "$eventkit_sidecar" ]] && pass eventkit_sidecar || fail eventkit_sidecar
[[ -S "$ipc_socket" ]] && pass ipc_socket || fail ipc_socket

if [[ -f "$launch_config" ]]; then
  if count="$(account_count 2>/dev/null)"; then
    pass launch_config "accounts_configured=$count"
  else
    fail launch_config "reason=unreadable"
  fi
else
  fail launch_config
fi

if [[ -x "$app_executable" ]]; then
  if login_item_state="$("$app_executable" --login-item-status 2>/dev/null)"; then
    if [[ "$login_item_state" == "enabled" ]]; then
      pass login_item "status=$login_item_state"
    else
      fail login_item "status=$login_item_state"
    fi
  else
    fail login_item "reason=status_unavailable"
  fi
fi

app_count="$(process_count_excluding_argument "$app_executable" "--stdio-proxy")"
mail_count="$(process_count "$mail_sidecar")"
eventkit_count="$(process_count "$eventkit_sidecar")"
proxy_count="$(process_count "$cli_path --stdio-proxy $ipc_socket")"
app_proxy_count="$(process_count "$app_executable --stdio-proxy $ipc_socket")"

[[ "$app_count" == "1" ]] && pass process_app "count=$app_count" || fail process_app "count=$app_count"
[[ "$mail_count" == "1" ]] && pass process_mail_sidecar "count=$mail_count" || fail process_mail_sidecar "count=$mail_count"
[[ "$eventkit_count" == "1" ]] && pass process_eventkit_sidecar "count=$eventkit_count" || fail process_eventkit_sidecar "count=$eventkit_count"
pass process_stdio_proxy "count=$proxy_count"

if profile="$(tunnel_profile 2>/dev/null)"; then
  tunnel_count="$(process_count "tunnel-client run --profile $profile")"
  [[ "$tunnel_count" == "1" ]] && pass process_chatgpt_tunnel "count=$tunnel_count" || fail process_chatgpt_tunnel "count=$tunnel_count"
  [[ "$app_proxy_count" == "1" ]] && pass process_chatgpt_tunnel_proxy "count=$app_proxy_count" || fail process_chatgpt_tunnel_proxy "count=$app_proxy_count"
else
  echo "process_chatgpt_tunnel=SKIP"
  echo "process_chatgpt_tunnel_proxy=SKIP"
fi

if [[ -x "$cli_path" ]]; then
  if status_json="$("$cli_path" --status-json 2>/dev/null)"; then
    if parsed="$(parse_status_json "$status_json" 2>/dev/null)"; then
      pass runtime_status "$parsed"
    else
      parsed="$(parse_status_json "$status_json" 2>/dev/null || true)"
      fail runtime_status "${parsed:-reason=unready}"
    fi
  else
    fail runtime_status "reason=status_json_failed"
  fi

  if approvals_json="$("$cli_path" --client-approvals-json 2>/dev/null)"; then
    if parsed="$(parse_approvals_json "$approvals_json" 2>/dev/null)"; then
      pass client_approvals "$parsed"
    else
      parsed="$(parse_approvals_json "$approvals_json" 2>/dev/null || true)"
      fail client_approvals "${parsed:-reason=unreadable}"
    fi
  else
    fail client_approvals "reason=unreadable"
  fi
fi

if [[ "$run_mail_validation" -eq 1 ]]; then
  if [[ -x "$project_dir/scripts/validate-local-mail-readonly.py" ]]; then
    if "$project_dir/scripts/validate-local-mail-readonly.py"; then
      pass mail_reader_validation
    else
      fail mail_reader_validation
    fi
  else
    fail mail_reader_validation "reason=script_missing"
  fi
else
  echo "mail_reader_validation=SKIP"
fi

if [[ "$failures" -eq 0 ]]; then
  echo "result=PASS"
else
  echo "result=FAIL failures=$failures"
  exit 1
fi
