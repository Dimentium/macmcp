#!/bin/bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd "$script_dir/.." && pwd)"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/macmcp-deployment.XXXXXX")"
test_home="$test_root/home"
install_root="$test_home/.local/opt/mac-agent-bridge"
bin_dir="$test_home/.local/bin"
app_dir="$test_home/Applications"
build_root="$test_root/build"
fixture_address="deployment-check@example.invalid"

cleanup() {
  HOME="$test_home" "$script_dir/uninstall-local.sh" \
    --install-root "$install_root" \
    --bin-dir "$bin_dir" \
    --app-dir "$app_dir" >/dev/null 2>&1 || true
  rm -rf "$test_root"
}
trap cleanup EXIT

run_installer() {
  HOME="$test_home" \
  MAC_AGENT_BRIDGE_BUILD_ROOT="$build_root" \
  "$script_dir/install-local.sh" \
    --no-open \
    --skip-password \
    --install-root "$install_root" \
    --bin-dir "$bin_dir" \
    --app-dir "$app_dir" \
    "$@"
}

mkdir -p "$test_home"
run_installer --gmail-address "$fixture_address"

runtime_cli="$install_root/bin/mac-agent-bridge"
launch_config="$test_home/Library/Application Support/mac-agent-bridge/launch.json"
[[ -x "$runtime_cli" ]]
[[ -x "$install_root/libexec/mail-mcp" ]]
[[ -x "$install_root/libexec/CheICalMCP" ]]
[[ -x "$app_dir/Mac Agent Bridge.app/Contents/MacOS/mac-agent-bridge" ]]
[[ -L "$bin_dir/mac-agent-bridge" ]]
[[ -f "$launch_config" ]]
[[ "$("$runtime_cli" --version)" == "MacMCP "* ]]
if HOME="$test_home" "$runtime_cli" \
  --mail-sidecar "$install_root/libexec/mail-mcp" \
  --gmail-address "$fixture_address" >/dev/null 2>&1; then
  echo "direct sidecar runtime was unexpectedly accepted" >&2
  exit 1
else
  [[ "$?" -eq 2 ]]
fi

diagnostics="$(HOME="$test_home" "$runtime_cli" --diagnose-json)"
python3 - "$fixture_address" "$diagnostics" <<'PY'
import json
import sys

address, output = sys.argv[1:]
report = json.loads(output)
assert report["schemaVersion"] == 1
assert report["configuration"] == {
    "availability": "available",
    "mailAccountCount": 1,
    "launchAtLogin": True,
}
assert report["bridge"] == {"availability": "unavailable", "status": None}
assert report["tunnel"] == "not_configured"
assert address not in output
PY

run_installer --reuse-existing-configuration
[[ -x "$runtime_cli" ]]
[[ -f "$launch_config" ]]
python3 - "$launch_config" "$fixture_address" <<'PY'
import json
import pathlib
import sys

payload = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert payload["args"].count("--gmail-address") == 1
index = payload["args"].index("--gmail-address")
assert payload["args"][index + 1] == sys.argv[2]
PY

HOME="$test_home" "$script_dir/uninstall-local.sh" \
  --install-root "$install_root" \
  --bin-dir "$bin_dir" \
  --app-dir "$app_dir" >/dev/null

[[ ! -e "$install_root" ]]
[[ ! -e "$app_dir/Mac Agent Bridge.app" ]]
[[ ! -e "$launch_config" ]]
[[ ! -e "$bin_dir/mac-agent-bridge" ]]

trap - EXIT
rm -rf "$test_root"
printf 'MacMCP local deployment acceptance passed\n'
