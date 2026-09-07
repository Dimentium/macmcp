#!/bin/bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd "$script_dir/.." && pwd)"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/macmcp-deployment.XXXXXX")"
test_home="$test_root/home"
install_root="$test_home/.local/opt/macmcp"
bin_dir="$test_home/.local/bin"
app_dir="$test_home/Applications"
build_root="$test_root/build"
fixture_address="deployment-check@example.invalid"
legacy_install_root="$test_home/.local/opt/mac-agent-bridge"
legacy_config_dir="$test_home/Library/Application Support/mac-agent-bridge"
legacy_bin_link="$bin_dir/mac-agent-bridge"

remove_test_root() {
  # Go owns the read-only permissions in its module cache.
  HOME="$test_home" go clean -modcache >/dev/null 2>&1 || true
  rm -rf "$test_root"
}

cleanup() {
  HOME="$test_home" "$script_dir/uninstall-local.sh" \
    --install-root "$install_root" \
    --bin-dir "$bin_dir" \
    --app-dir "$app_dir" >/dev/null 2>&1 || true
  remove_test_root
}
trap cleanup EXIT

phase="initializing"
report_failure_phase() {
  local status=$?
  printf 'MacMCP deployment acceptance failed during phase=%s\n' "$phase" >&2
  if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
    printf '::error title=MacMCP deployment acceptance::phase=%s\n' "$phase"
  fi
  exit "$status"
}
trap report_failure_phase ERR

run_installer() {
  HOME="$test_home" \
  MACMCP_BUILD_ROOT="$build_root" \
  "$script_dir/install-local.sh" \
    --no-open \
    --skip-password \
    --install-root "$install_root" \
    --bin-dir "$bin_dir" \
    --app-dir "$app_dir" \
    "$@"
}

mkdir -p "$test_home"
mkdir -p "$legacy_install_root/bin" "$legacy_config_dir" "$bin_dir"
printf '#!/bin/bash\nexit 0\n' > "$legacy_install_root/bin/mac-agent-bridge"
chmod 700 "$legacy_install_root/bin/mac-agent-bridge"
ln -s "$legacy_install_root/bin/mac-agent-bridge" "$legacy_bin_link"
printf '%s\n' '{"schemaVersion":1,"writableAccountIDs":["gmail"]}' \
  > "$legacy_config_dir/mail-action-access.json"
printf 'legacy socket' > "$legacy_config_dir/mcp.sock"
phase="initial-install"
run_installer --gmail-address "$fixture_address"

phase="initial-contract"
runtime_cli="$install_root/bin/macmcp-bridge"
launch_config="$test_home/Library/Application Support/macmcp/launch.json"
[[ -x "$runtime_cli" ]]
[[ ! -e "$install_root/libexec/mail-mcp" ]]
[[ ! -e "$install_root/libexec/CheICalMCP" ]]
[[ -x "$app_dir/MacMCP.app/Contents/MacOS/macmcp-bridge" ]]
[[ -x "$app_dir/MacMCP.app/Contents/Resources/mail-mcp" ]]
[[ -x "$app_dir/MacMCP.app/Contents/Resources/CheICalMCP" ]]
[[ -x "$app_dir/MacMCP.app/Contents/Resources/macmcp" ]]
[[ -f "$app_dir/MacMCP.app/Contents/Resources/ThirdPartyNotices/README.md" ]]
[[ -f "$app_dir/MacMCP.app/Contents/Resources/ThirdPartyNotices/go/github.com/modelcontextprotocol/go-sdk/LICENSE" ]]
"$app_dir/MacMCP.app/Contents/Resources/macmcp" help >/dev/null
[[ -L "$bin_dir/macmcp-bridge" ]]
[[ -f "$launch_config" ]]
[[ -L "$legacy_install_root" ]]
[[ "$(readlink "$legacy_install_root")" == "$install_root" ]]
[[ -L "$legacy_bin_link" ]]
[[ "$(readlink "$legacy_bin_link")" == "$runtime_cli" ]]
[[ -L "$legacy_config_dir/mcp.sock" ]]
[[ "$(readlink "$legacy_config_dir/mcp.sock")" == "$test_home/Library/Application Support/macmcp/mcp.sock" ]]
python3 - "$test_home/Library/Application Support/macmcp/mail-action-access.json" <<'PY'
import json
import pathlib
import sys

payload = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert payload == {"schemaVersion": 1, "writableAccountIDs": ["gmail"]}
PY
[[ "$("$runtime_cli" --version)" == "MacMCP "* ]]
if HOME="$test_home" "$runtime_cli" \
  --mail-sidecar "$app_dir/MacMCP.app/Contents/Resources/mail-mcp" \
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
bridge = report["bridge"]
assert bridge["availability"] in {"available", "unavailable"}
assert (bridge["status"] is not None) == (bridge["availability"] == "available")
assert report["tunnel"] == "not_configured"
assert address not in output
PY

phase="upgrade"
run_installer --reuse-existing-configuration
phase="upgrade-contract"
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
assert "--eventkit-sidecar" not in payload["args"]
PY

phase="uninstall"
HOME="$test_home" "$script_dir/uninstall-local.sh" \
  --install-root "$install_root" \
  --bin-dir "$bin_dir" \
  --app-dir "$app_dir" >/dev/null

[[ ! -e "$install_root" ]]
[[ ! -e "$app_dir/MacMCP.app" ]]
[[ ! -e "$launch_config" ]]
[[ ! -e "$bin_dir/macmcp-bridge" ]]
[[ ! -e "$legacy_install_root" ]]
[[ ! -e "$legacy_config_dir" ]]
[[ ! -e "$legacy_bin_link" ]]

phase="complete"
trap - EXIT
remove_test_root
printf 'MacMCP local deployment acceptance passed\n'
