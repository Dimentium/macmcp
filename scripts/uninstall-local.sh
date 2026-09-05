#!/bin/bash
set -euo pipefail

usage() {
  cat <<'EOF'
usage: scripts/uninstall-local.sh [options]

Removes the current user's local mac-agent-bridge install:
  - stops the installed menu-bar app and installed sidecar processes
  - removes Mac Agent Bridge.app
  - removes ~/.local/opt/mac-agent-bridge by default
  - removes the ~/.local/bin/mac-agent-bridge symlink when it points there

Keychain mail passwords and the ChatGPT tunnel runtime API key are preserved by
default.

Options:
  --delete-mail-password ADDRESS   also delete this account password from Keychain; repeatable
  --delete-chatgpt-tunnel-key      also delete the ChatGPT tunnel runtime API key
  --install-root PATH              default: ~/.local/opt/mac-agent-bridge
  --bin-dir PATH                   default: ~/.local/bin
  --app-dir PATH                   default: ~/Applications
  -h, --help                       show this help
EOF
}

install_root="${MAC_AGENT_BRIDGE_INSTALL_ROOT:-$HOME/.local/opt/mac-agent-bridge}"
bin_dir="${MAC_AGENT_BRIDGE_BIN_DIR:-$HOME/.local/bin}"
app_dir="${MAC_AGENT_BRIDGE_APP_DIR:-$HOME/Applications}"
config_dir="$HOME/Library/Application Support/mac-agent-bridge"
delete_password_accounts=()
delete_chatgpt_tunnel_key=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --delete-mail-password)
      [[ $# -ge 2 ]] || { echo "missing value for --delete-mail-password" >&2; exit 2; }
      delete_password_accounts+=("$2")
      shift 2
      ;;
    --delete-chatgpt-tunnel-key)
      delete_chatgpt_tunnel_key=1
      shift
      ;;
    --install-root)
      [[ $# -ge 2 ]] || { echo "missing value for --install-root" >&2; exit 2; }
      install_root="$2"
      shift 2
      ;;
    --bin-dir)
      [[ $# -ge 2 ]] || { echo "missing value for --bin-dir" >&2; exit 2; }
      bin_dir="$2"
      shift 2
      ;;
    --app-dir)
      [[ $# -ge 2 ]] || { echo "missing value for --app-dir" >&2; exit 2; }
      app_dir="$2"
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

[[ "$(uname -s)" == "Darwin" ]] || { echo "macOS is required" >&2; exit 1; }
command -v pgrep >/dev/null || { echo "missing required tool: pgrep" >&2; exit 1; }

libexec_dir="$install_root/libexec"
cli_dir="$install_root/bin"
target_app="$app_dir/Mac Agent Bridge.app"
cli_path="$cli_dir/mac-agent-bridge"
bin_link="$bin_dir/mac-agent-bridge"
legacy_tunnel_setup_link="$bin_dir/mac-agent-bridge-tunnel-setup"
app_config="$config_dir/launch.json"

managed_tunnel_profile() {
  [[ -f "$app_config" ]] || return 0
  python3 - "$app_config" <<'PY'
import json
import pathlib
import re
import sys

try:
    tunnel = json.loads(pathlib.Path(sys.argv[1]).read_text()).get("chatGPTTunnel")
except Exception:
    sys.exit(1)

if tunnel is None:
    sys.exit(0)
profile = tunnel.get("profile") if isinstance(tunnel, dict) else None
if not isinstance(profile, str) or not re.fullmatch(r"[A-Za-z0-9._-]+", profile):
    sys.exit(1)
print(profile)
PY
}

tunnel_profile="$(managed_tunnel_profile)" || {
  echo "unable to validate the configured tunnel profile; leaving tunnel-client untouched" >&2
  tunnel_profile=""
}

terminate_matching_command() {
  local pattern="$1"
  local signal="$2"
  local output
  local pids=()
  output="$(pgrep -f "$pattern" 2>/dev/null || true)"
  [[ -n "$output" ]] || return 0
  while IFS= read -r pid; do
    [[ -n "$pid" ]] && pids+=("$pid")
  done <<< "$output"
  kill "-$signal" "${pids[@]}" 2>/dev/null || true
}

existing_runtime_is_running() {
  local pattern
  for pattern in \
    "$target_app/Contents/MacOS/mac-agent-bridge" \
    "$libexec_dir/CheICalMCP" \
    "$libexec_dir/mail-mcp"; do
    pgrep -f "$pattern" >/dev/null 2>&1 && return 0
  done
  if [[ -n "$tunnel_profile" ]]; then
    pgrep -f "tunnel-client run --profile $tunnel_profile" >/dev/null 2>&1 && return 0
  fi
  return 1
}

wait_for_existing_runtime_exit() {
  local timeout_seconds="$1"
  local deadline=$((SECONDS + timeout_seconds))
  while existing_runtime_is_running; do
    [[ "$SECONDS" -lt "$deadline" ]] || return 1
    sleep 0.1
  done
}

if [[ -d "$target_app" ]]; then
  echo "Stopping menu-bar app if it is running"
fi

if [[ -x "$target_app/Contents/MacOS/mac-agent-bridge" ]]; then
  echo "Unregistering Login Item if it is registered"
  "$target_app/Contents/MacOS/mac-agent-bridge" --unregister-login-item >/dev/null 2>&1 || true
fi

terminate_matching_command "$target_app/Contents/MacOS/mac-agent-bridge" TERM
terminate_matching_command "$libexec_dir/CheICalMCP" TERM
terminate_matching_command "$libexec_dir/mail-mcp" TERM
if [[ -n "$tunnel_profile" ]]; then
  terminate_matching_command "tunnel-client run --profile $tunnel_profile" TERM
fi
if ! wait_for_existing_runtime_exit 3; then
  terminate_matching_command "$target_app/Contents/MacOS/mac-agent-bridge" KILL
  terminate_matching_command "$libexec_dir/CheICalMCP" KILL
  terminate_matching_command "$libexec_dir/mail-mcp" KILL
  if [[ -n "$tunnel_profile" ]]; then
    terminate_matching_command "tunnel-client run --profile $tunnel_profile" KILL
  fi
  wait_for_existing_runtime_exit 2 || {
    echo "installed runtime did not stop; refusing to delete its files" >&2
    exit 1
  }
fi

if [[ ${#delete_password_accounts[@]} -gt 0 ]]; then
  [[ -x "$cli_path" ]] || {
    echo "cannot delete Keychain passwords because installed CLI is missing: $cli_path" >&2
    exit 1
  }
  for account in "${delete_password_accounts[@]}"; do
    echo "Deleting mail password from Keychain for $account"
    "$cli_path" --delete-mail-password "$account"
  done
fi

if [[ "$delete_chatgpt_tunnel_key" -eq 1 ]]; then
  [[ -x "$cli_path" ]] || {
    echo "cannot delete ChatGPT tunnel API key because installed CLI is missing: $cli_path" >&2
    exit 1
  }
  "$cli_path" --delete-chatgpt-tunnel-key
fi

if [[ -L "$bin_link" ]]; then
  link_target="$(readlink "$bin_link")"
  if [[ "$link_target" == "$cli_path" ]]; then
    rm -f "$bin_link"
  fi
fi

if [[ -L "$legacy_tunnel_setup_link" ]]; then
  link_target="$(readlink "$legacy_tunnel_setup_link")"
  if [[ "$link_target" == "$cli_dir/setup-chatgpt-tunnel" ]]; then
    rm -f "$legacy_tunnel_setup_link"
  fi
fi

rm -rf "$target_app"
rm -rf "$install_root"
rm -rf "$config_dir"

cat <<EOF
Removed local mac-agent-bridge install.

Removed:
  $target_app
  $install_root
  $config_dir

Keychain mail passwords and the ChatGPT tunnel runtime API key were preserved
unless explicitly deleted with --delete-mail-password or
--delete-chatgpt-tunnel-key.

EOF
