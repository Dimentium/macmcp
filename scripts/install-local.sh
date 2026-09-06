#!/bin/bash
set -euo pipefail

MAIL_REPO="https://github.com/Dimentium/mail-mcp"
MAIL_VERSION="v1.1.1"
MAIL_ARM64_SHA256="f9d7bc21b957927c68ed5e7466f82bc1d3c3673679eb549979825c0857188144"
MAIL_AMD64_SHA256="4e1c9edf0e49bb0af720b2ea2d6ae39a6f1cbc76d6e470a4c413611f8dd81a25"
CHE_REPO="https://github.com/PsychQuant/che-ical-mcp.git"
CHE_COMMIT="a8598378b5e280b27005ab8cd21e9b5758312423"

usage() {
  cat <<'EOF'
usage: scripts/install-local.sh [--reuse-existing-configuration | account options] [options]

Installs mac-agent-bridge for the current macOS user:
  - downloads pinned mail-mcp and verifies its SHA-256
  - builds pinned CheICalMCP from source and ad-hoc signs it
  - builds and installs Mac Agent Bridge.app
  - installs a CLI wrapper target and writes an MCP stdio config example
  - optionally stores mail passwords in Keychain
  - optionally installs and manages an OpenAI Secure MCP Tunnel

Re-run the same command to upgrade an existing local install. Use
`--skip-password` during upgrades to keep existing Keychain passwords.

Options:
  --icloud-address ADDRESS   iCloud preset; repeatable
  --gmail-address ADDRESS    Gmail preset; repeatable
  --mail-account SPEC        custom account: ID=ADDRESS[,HOST[,PORT[,SECURITY]]]
  --reuse-existing-configuration
                            upgrade using the current account configuration;
                            preserves existing Keychain passwords
  --skip-password            do not prompt for the Keychain password setup
  --chatgpt-tunnel-id ID     install tunnel-client when needed, prompt for its
                            restricted runtime API key, and enable app-managed
                            ChatGPT Tunnel startup
  --chatgpt-tunnel-client PATH
                            tunnel-client path; default: Homebrew-installed binary
  --no-open                  do not launch the installed menu-bar app
  --install-root PATH        default: ~/.local/opt/mac-agent-bridge
  --bin-dir PATH             default: ~/.local/bin
  --app-dir PATH             default: ~/Applications
  -h, --help                 show this help
EOF
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd "$script_dir/.." && pwd)"
install_root="${MAC_AGENT_BRIDGE_INSTALL_ROOT:-$HOME/.local/opt/mac-agent-bridge}"
bin_dir="${MAC_AGENT_BRIDGE_BIN_DIR:-$HOME/.local/bin}"
app_dir="${MAC_AGENT_BRIDGE_APP_DIR:-$HOME/Applications}"
config_dir="$HOME/Library/Application Support/mac-agent-bridge"
build_root="${MAC_AGENT_BRIDGE_BUILD_ROOT:-$project_dir/.build/local-install}"
mail_args=()
password_accounts=()
skip_password=0
open_app=1
reuse_existing_configuration=0
chatgpt_tunnel_id=""
chatgpt_tunnel_client=""
chatgpt_tunnel_profile="macmcp-local"
existing_tunnel_json=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --icloud-address)
      [[ $# -ge 2 ]] || { echo "missing value for --icloud-address" >&2; exit 2; }
      mail_args+=("--icloud-address" "$2")
      password_accounts+=("$2")
      shift 2
      ;;
    --gmail-address)
      [[ $# -ge 2 ]] || { echo "missing value for --gmail-address" >&2; exit 2; }
      mail_args+=("--gmail-address" "$2")
      password_accounts+=("$2")
      shift 2
      ;;
    --mail-account)
      [[ $# -ge 2 ]] || { echo "missing value for --mail-account" >&2; exit 2; }
      mail_args+=("--mail-account" "$2")
      account_value="${2#*=}"
      password_accounts+=("${account_value%%,*}")
      shift 2
      ;;
    --reuse-existing-configuration)
      reuse_existing_configuration=1
      shift
      ;;
    --skip-password)
      skip_password=1
      shift
      ;;
    --chatgpt-tunnel-id)
      [[ $# -ge 2 ]] || { echo "missing value for --chatgpt-tunnel-id" >&2; exit 2; }
      chatgpt_tunnel_id="$2"
      shift 2
      ;;
    --chatgpt-tunnel-client)
      [[ $# -ge 2 ]] || { echo "missing value for --chatgpt-tunnel-client" >&2; exit 2; }
      chatgpt_tunnel_client="$2"
      shift 2
      ;;
    --no-open)
      open_app=0
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

if [[ "$reuse_existing_configuration" -eq 1 && ${#mail_args[@]} -gt 0 ]]; then
  echo "--reuse-existing-configuration cannot be combined with account options" >&2
  exit 2
fi

if [[ "$reuse_existing_configuration" -eq 1 ]]; then
  existing_config="$config_dir/launch.json"
  [[ -f "$existing_config" ]] || {
    echo "existing launch configuration was not found: $existing_config" >&2
    exit 2
  }
  existing_mail_args="$(python3 - "$existing_config" <<'PY'
import json
import pathlib
import sys

try:
    args = json.loads(pathlib.Path(sys.argv[1]).read_text())["args"]
except Exception:
    sys.exit(1)

account_flags = {"--icloud-address", "--gmail-address", "--mail-account"}
index = 0
while index < len(args):
    if args[index] in account_flags:
        if index + 1 >= len(args) or "\n" in args[index + 1] or "\r" in args[index + 1]:
            sys.exit(1)
        print(args[index])
        print(args[index + 1])
        index += 2
    else:
        index += 1
PY
  )" || {
    echo "existing launch configuration is unreadable" >&2
    exit 2
  }
  while IFS= read -r argument; do
    [[ -n "$argument" ]] && mail_args+=("$argument")
  done <<< "$existing_mail_args"
  [[ ${#mail_args[@]} -gt 0 ]] || {
    echo "existing launch configuration has no mail accounts" >&2
    exit 2
  }
  skip_password=1
  echo "Reusing existing mail configuration and preserving Keychain passwords"

  existing_tunnel_json="$(python3 - "$existing_config" <<'PY'
import json
import pathlib
import sys

try:
    tunnel = json.loads(pathlib.Path(sys.argv[1]).read_text()).get("chatGPTTunnel")
except Exception:
    sys.exit(1)

if tunnel is not None:
    print(json.dumps(tunnel, separators=(",", ":")))
PY
  )" || {
    echo "existing ChatGPT tunnel configuration is unreadable" >&2
    exit 2
  }
  if [[ -n "$existing_tunnel_json" ]]; then
    chatgpt_tunnel_profile="$(printf '%s' "$existing_tunnel_json" | python3 -c '
import json
import sys

tunnel = json.load(sys.stdin)
profile = tunnel.get("profile")
if not isinstance(profile, str) or not profile:
    sys.exit(1)
print(profile)
')" || {
      echo "existing ChatGPT tunnel profile is unreadable" >&2
      exit 2
    }
  fi
fi

if [[ -n "$chatgpt_tunnel_id" ]] && ! [[ "$chatgpt_tunnel_id" =~ ^tunnel_[A-Za-z0-9_-]{16,128}$ ]]; then
  echo "invalid --chatgpt-tunnel-id" >&2
  exit 2
fi
if [[ -n "$chatgpt_tunnel_client" ]] && [[ ! "$chatgpt_tunnel_client" = /* ]]; then
  echo "--chatgpt-tunnel-client must be an absolute path" >&2
  exit 2
fi

[[ "$(uname -s)" == "Darwin" ]] || { echo "macOS is required" >&2; exit 1; }
[[ ${#mail_args[@]} -gt 0 ]] || {
  echo "at least one mail account is required" >&2
  exit 2
}

for tool in curl git plutil shasum swift codesign tar python3 pgrep; do
  command -v "$tool" >/dev/null || {
    echo "missing required tool: $tool" >&2
    echo "Install Xcode Command Line Tools first: xcode-select --install" >&2
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

libexec_dir="$install_root/libexec"
share_dir="$install_root/share"
cli_dir="$install_root/bin"
mail_archive="$build_root/$mail_asset"
mail_extract_dir="$build_root/mail-mcp"
che_src="$build_root/che-ical-mcp"
target_app="$app_dir/Mac Agent Bridge.app"
cli_path="$cli_dir/mac-agent-bridge"
mcp_config="$share_dir/mcp.local.json"
app_config="$config_dir/launch.json"
ipc_socket="$config_dir/mcp.sock"
bin_link="$bin_dir/mac-agent-bridge"
legacy_tunnel_setup_link="$bin_dir/mac-agent-bridge-tunnel-setup"

mkdir -p "$build_root" "$(dirname "$install_root")" "$bin_dir" "$app_dir" "$(dirname "$config_dir")"
stage_install_root="$(mktemp -d "$install_root.staging.XXXXXX")"
stage_libexec_dir="$stage_install_root/libexec"
stage_share_dir="$stage_install_root/share"
stage_cli_dir="$stage_install_root/bin"
stage_cli_path="$stage_cli_dir/mac-agent-bridge"
stage_mcp_config="$stage_share_dir/mcp.local.json"
stage_app_parent="$(mktemp -d "$app_dir/.macmcp-app.staging.XXXXXX")"
stage_app="$stage_app_parent/Mac Agent Bridge.app"
stage_config_parent="$(mktemp -d "$(dirname "$config_dir")/.macmcp-config.staging.XXXXXX")"
stage_app_config="$stage_config_parent/launch.json"

cleanup_staging() {
  rm -rf "$stage_install_root" "$stage_app_parent" "$stage_config_parent"
}
trap cleanup_staging EXIT

ensure_chatgpt_tunnel_client() {
  if [[ -n "$chatgpt_tunnel_client" ]]; then
    [[ -x "$chatgpt_tunnel_client" ]] || {
      echo "tunnel-client is not executable: $chatgpt_tunnel_client" >&2
      exit 1
    }
  else
    chatgpt_tunnel_client="$(command -v tunnel-client || true)"
    if [[ -z "$chatgpt_tunnel_client" ]]; then
      command -v brew >/dev/null || {
        echo "Homebrew is required to install tunnel-client" >&2
        echo "Install Homebrew, then re-run this command." >&2
        exit 1
      }
      echo "Installing OpenAI tunnel-client with Homebrew"
      brew install openai/tools/tunnel-client
      chatgpt_tunnel_client="$(command -v tunnel-client || true)"
    fi
    [[ -n "$chatgpt_tunnel_client" && -x "$chatgpt_tunnel_client" ]] || {
      echo "tunnel-client was not found after Homebrew installation" >&2
      exit 1
    }
  fi
  [[ "$(basename "$chatgpt_tunnel_client")" == "tunnel-client" ]] || {
    echo "--chatgpt-tunnel-client must name tunnel-client" >&2
    exit 2
  }
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
  if [[ -n "$chatgpt_tunnel_id" || -n "$existing_tunnel_json" ]]; then
    pgrep -f "tunnel-client run --profile $chatgpt_tunnel_profile" >/dev/null 2>&1 && return 0
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

stop_existing_runtime() {
  if [[ -d "$target_app" ]]; then
    echo "Stopping existing menu-bar app if it is running"
  fi

  terminate_matching_command "$target_app/Contents/MacOS/mac-agent-bridge" TERM
  terminate_matching_command "$libexec_dir/CheICalMCP" TERM
  terminate_matching_command "$libexec_dir/mail-mcp" TERM
  if [[ -n "$chatgpt_tunnel_id" || -n "$existing_tunnel_json" ]]; then
    terminate_matching_command "tunnel-client run --profile $chatgpt_tunnel_profile" TERM
  fi
  if wait_for_existing_runtime_exit 3; then
    return 0
  fi

  terminate_matching_command "$target_app/Contents/MacOS/mac-agent-bridge" KILL
  terminate_matching_command "$libexec_dir/CheICalMCP" KILL
  terminate_matching_command "$libexec_dir/mail-mcp" KILL
  if [[ -n "$chatgpt_tunnel_id" || -n "$existing_tunnel_json" ]]; then
    terminate_matching_command "tunnel-client run --profile $chatgpt_tunnel_profile" KILL
  fi
  wait_for_existing_runtime_exit 2 || {
    echo "existing runtime did not stop; leaving the installed version unchanged" >&2
    return 1
  }
}

activate_staged_install() {
  local install_backup_parent=""
  local app_backup_parent=""
  local config_backup_parent=""
  local bin_link_backup_parent=""
  local tunnel_link_backup_parent=""
  local install_backup=""
  local app_backup=""
  local config_backup=""
  local bin_link_backup=""
  local tunnel_link_backup=""
  local installed_new_root=0
  local installed_new_app=0
  local installed_new_config=0
  local installed_new_bin_link=0

  rollback_activation() {
    [[ "$installed_new_bin_link" -eq 0 ]] || rm -f "$bin_link"
    [[ "$installed_new_config" -eq 0 ]] || rm -f "$app_config"
    [[ "$installed_new_app" -eq 0 ]] || rm -rf "$target_app"
    [[ "$installed_new_root" -eq 0 ]] || rm -rf "$install_root"

    [[ -z "$tunnel_link_backup" ]] || mv "$tunnel_link_backup" "$legacy_tunnel_setup_link"
    [[ -z "$bin_link_backup" ]] || mv "$bin_link_backup" "$bin_link"
    [[ -z "$config_backup" ]] || mv "$config_backup" "$app_config"
    [[ -z "$app_backup" ]] || mv "$app_backup" "$target_app"
    [[ -z "$install_backup" ]] || mv "$install_backup" "$install_root"

    rm -rf "$install_backup_parent" "$app_backup_parent" "$config_backup_parent" \
      "$bin_link_backup_parent" "$tunnel_link_backup_parent"
    [[ ! -d "$target_app" ]] || open "$target_app" >/dev/null 2>&1 || true
  }

  if [[ -e "$install_root" ]]; then
    install_backup_parent="$(mktemp -d "$install_root.backup.XXXXXX")"
    install_backup="$install_backup_parent/previous"
    mv "$install_root" "$install_backup" || { rollback_activation; return 1; }
  fi
  if [[ -e "$target_app" ]]; then
    app_backup_parent="$(mktemp -d "$app_dir/.macmcp-app.backup.XXXXXX")"
    app_backup="$app_backup_parent/previous"
    mv "$target_app" "$app_backup" || { rollback_activation; return 1; }
  fi
  mkdir -p "$config_dir" && chmod 700 "$config_dir" || { rollback_activation; return 1; }
  if [[ -e "$app_config" ]]; then
    config_backup_parent="$(mktemp -d "$(dirname "$config_dir")/.macmcp-config.backup.XXXXXX")"
    config_backup="$config_backup_parent/previous"
    mv "$app_config" "$config_backup" || { rollback_activation; return 1; }
  fi
  if [[ -e "$bin_link" || -L "$bin_link" ]]; then
    bin_link_backup_parent="$(mktemp -d "$bin_dir/.macmcp-bin-link.backup.XXXXXX")"
    bin_link_backup="$bin_link_backup_parent/previous"
    mv "$bin_link" "$bin_link_backup" || { rollback_activation; return 1; }
  fi
  if [[ -e "$legacy_tunnel_setup_link" || -L "$legacy_tunnel_setup_link" ]]; then
    tunnel_link_backup_parent="$(mktemp -d "$bin_dir/.macmcp-tunnel-link.backup.XXXXXX")"
    tunnel_link_backup="$tunnel_link_backup_parent/previous"
    mv "$legacy_tunnel_setup_link" "$tunnel_link_backup" || { rollback_activation; return 1; }
  fi

  mv "$stage_install_root" "$install_root" || { rollback_activation; return 1; }
  installed_new_root=1
  mv "$stage_app" "$target_app" || { rollback_activation; return 1; }
  installed_new_app=1
  mv "$stage_app_config" "$app_config" || { rollback_activation; return 1; }
  installed_new_config=1

  local new_bin_link="$bin_dir/.mac-agent-bridge.new.$$"
  ln -s "$cli_path" "$new_bin_link" || { rollback_activation; return 1; }
  mv "$new_bin_link" "$bin_link" || { rollback_activation; return 1; }
  installed_new_bin_link=1

  rm -rf "$install_backup_parent" "$app_backup_parent" "$config_backup_parent" \
    "$bin_link_backup_parent" "$tunnel_link_backup_parent"
}

if [[ -n "$chatgpt_tunnel_id" ]]; then
  ensure_chatgpt_tunnel_client
fi

mkdir -p "$stage_libexec_dir" "$stage_share_dir" "$stage_cli_dir"

echo "Downloading pinned mail-mcp $MAIL_VERSION for $(uname -m)"
curl -fL \
  "$MAIL_REPO/releases/download/$MAIL_VERSION/$mail_asset" \
  -o "$mail_archive"
actual_mail_sha256="$(shasum -a 256 "$mail_archive" | awk '{print $1}')"
if [[ "$actual_mail_sha256" != "$mail_sha256" ]]; then
  echo "mail-mcp checksum mismatch" >&2
  echo "expected: $mail_sha256" >&2
  echo "actual:   $actual_mail_sha256" >&2
  exit 1
fi

rm -rf "$mail_extract_dir"
mkdir -p "$mail_extract_dir"
tar -xzf "$mail_archive" -C "$mail_extract_dir"
mail_candidate="$(find "$mail_extract_dir" -type f \( -name 'mail-mcp' -o -name 'mail-mcp-darwin-*' \) | sort | head -n 1)"
if [[ -z "$mail_candidate" ]]; then
  echo "mail-mcp binary was not found in $mail_asset" >&2
  exit 1
fi
cp "$mail_candidate" "$stage_libexec_dir/mail-mcp"
chmod 755 "$stage_libexec_dir/mail-mcp"

echo "Building pinned CheICalMCP from $CHE_COMMIT"
if [[ ! -d "$che_src/.git" ]]; then
  git clone "$CHE_REPO" "$che_src"
fi
git -C "$che_src" fetch --tags origin
git -C "$che_src" checkout --detach "$CHE_COMMIT"
swift build -c release --product CheICalMCP --package-path "$che_src"
che_binary="$che_src/.build/release/CheICalMCP"
[[ -x "$che_binary" ]] || { echo "CheICalMCP release binary was not produced" >&2; exit 1; }

cp "$che_binary" "$stage_libexec_dir/CheICalMCP"
chmod 755 "$stage_libexec_dir/CheICalMCP"
codesign --force --sign - --options runtime \
  --entitlements "$project_dir/Sources/MacAgentBridge/Entitlements.plist" \
  "$stage_libexec_dir/CheICalMCP"
codesign --verify --strict --verbose=2 "$stage_libexec_dir/CheICalMCP"

echo "Building local app bundle"
"$project_dir/scripts/build-local-app.sh" "$stage_libexec_dir/CheICalMCP" >/dev/null
built_app="$project_dir/.build/local/Mac Agent Bridge.app"
[[ -d "$built_app" ]] || { echo "app bundle was not produced" >&2; exit 1; }

cp -R "$built_app" "$stage_app"
codesign --verify --deep --strict --verbose=2 "$stage_app"

cp "$project_dir/.build/release/mac-agent-bridge" "$stage_cli_path"
chmod 755 "$stage_cli_path"
codesign --force --sign - --options runtime \
  --entitlements "$project_dir/Sources/MacAgentBridge/Entitlements.plist" \
  "$stage_cli_path"
codesign --verify --strict --verbose=2 "$stage_cli_path"

json_cli_path="$(printf '%s' "$cli_path" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')"
json_ipc_socket="$(printf '%s' "$ipc_socket" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')"

cat > "$stage_mcp_config" <<EOF
{
  "mcpServers": {
    "mac-agent-bridge": {
      "command": $json_cli_path,
      "args": [
        "--stdio-proxy",
        $json_ipc_socket
      ]
    }
  }
}
EOF
chmod 600 "$stage_mcp_config"

python3 - \
  "$stage_app_config" \
  "$libexec_dir/mail-mcp" \
  "$libexec_dir/CheICalMCP" \
  "$chatgpt_tunnel_id" \
  "$chatgpt_tunnel_client" \
  "$chatgpt_tunnel_profile" \
  "$existing_tunnel_json" \
  "${mail_args[@]}" <<'PY'
import json
import os
import pathlib
import sys
import tempfile

target = pathlib.Path(sys.argv[1])
mail_sidecar, eventkit_sidecar = sys.argv[2:4]
tunnel_id, tunnel_client, tunnel_profile, existing_tunnel = sys.argv[4:8]
mail_args = sys.argv[8:]

payload = {
    "schemaVersion": 1,
    "launchAtLogin": True,
    "args": ["--mail-sidecar", mail_sidecar, *mail_args, "--eventkit-sidecar", eventkit_sidecar],
}
if tunnel_id:
    payload["chatGPTTunnel"] = {
        "tunnelID": tunnel_id,
        "clientPath": tunnel_client,
        "profile": tunnel_profile,
    }
elif existing_tunnel:
    payload["chatGPTTunnel"] = json.loads(existing_tunnel)

target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
fd, temporary_path = tempfile.mkstemp(prefix="launch.", dir=target.parent)
try:
    with os.fdopen(fd, "w") as handle:
        json.dump(payload, handle, indent=2)
        handle.write("\n")
    os.chmod(temporary_path, 0o600)
    os.replace(temporary_path, target)
finally:
    if os.path.exists(temporary_path):
        os.unlink(temporary_path)
PY

if [[ "$skip_password" -eq 0 ]]; then
  for account in "${password_accounts[@]}"; do
    echo "Storing mail password in Keychain for $account"
    "$stage_cli_path" --store-mail-password "$account"
  done
else
  echo "Skipped Keychain password setup"
fi

if [[ -n "$chatgpt_tunnel_id" ]]; then
  echo "Storing ChatGPT tunnel runtime API key in Keychain"
  "$stage_cli_path" --store-chatgpt-tunnel-key
fi

echo "Activating staged local install"
stop_existing_runtime
activate_staged_install

if [[ "$open_app" -eq 1 ]]; then
  echo "Launching menu-bar app. Approve Calendar and Reminders when macOS asks."
  open "$target_app"
fi

cat <<EOF

Installed mac-agent-bridge locally.

CLI:
  $bin_dir/mac-agent-bridge

App:
  $target_app

Sidecars:
  $libexec_dir/mail-mcp
  $libexec_dir/CheICalMCP

MCP stdio config example:
  $mcp_config

Secure MCP Tunnel setup:
  Create or inspect tunnels: https://platform.openai.com/settings/organization/tunnels
  Create restricted runtime API keys: https://platform.openai.com/api-keys
  Configure during install: --chatgpt-tunnel-id tunnel_YOUR_ID

When configured, the MacMCP app owns tunnel-client and starts it automatically.

App launch config:
  $app_config

Verify:
  $bin_dir/mac-agent-bridge --status-json

EOF
