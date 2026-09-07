#!/bin/bash
set -euo pipefail

usage() {
  cat <<'EOF'
usage: scripts/release.sh --signing-identity "Developer ID Application: Name (TEAMID)" [options]

Publishes one complete MacMCP release from the current clean source commit.
The source version must already be bumped and committed, but this command
creates and pushes the source tag only after tests and notarization succeed.

Options:
  --signing-identity ID  required unless MACMCP_SIGNING_IDENTITY is set
  --signing-keychain PATH optional Keychain containing the signing identity
  --notary-profile NAME  notarytool Keychain profile; default: macmcp-notarization
  --remote NAME          Git remote for the public repository; default: public
  --install-local        update the local Homebrew Cask and restart MacMCP last
  -h, --help             show this help
EOF
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd "$script_dir/.." && pwd)"
signing_identity="${MACMCP_SIGNING_IDENTITY:-}"
signing_keychain="${MACMCP_SIGNING_KEYCHAIN:-}"
notary_profile="${MACMCP_NOTARY_PROFILE:-macmcp-notarization}"
remote="${MACMCP_RELEASE_REMOTE:-public}"
install_local=0
step_number=0
step_total=8
step_title="startup"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --signing-identity)
      [[ $# -ge 2 ]] || { echo "missing value for --signing-identity" >&2; exit 2; }
      signing_identity="$2"
      shift 2
      ;;
    --signing-keychain)
      [[ $# -ge 2 ]] || { echo "missing value for --signing-keychain" >&2; exit 2; }
      signing_keychain="$2"
      shift 2
      ;;
    --notary-profile)
      [[ $# -ge 2 ]] || { echo "missing value for --notary-profile" >&2; exit 2; }
      notary_profile="$2"
      shift 2
      ;;
    --remote)
      [[ $# -ge 2 ]] || { echo "missing value for --remote" >&2; exit 2; }
      remote="$2"
      shift 2
      ;;
    --install-local)
      install_local=1
      step_total=10
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

log_step() {
  if [[ "$step_number" -gt 0 ]]; then
    printf 'Completed in %ss\n' "$((SECONDS - step_started))"
  fi
  step_number="$1"
  step_title="$2"
  step_started=$SECONDS
  printf '\n==> [%s] [%s/%s] %s\n' "$(date '+%H:%M:%S')" "$step_number" "$step_total" "$step_title"
}

fail_release() {
  local status="$?"
  [[ "$status" -ne 0 ]] || return 0
  printf '\nRelease failed at step %s/%s (%s), exit %s. No later publication step was run.\n' \
    "$step_number" "$step_total" "$step_title" "$status" >&2
  exit "$status"
}

require_command() {
  command -v "$1" >/dev/null || {
    echo "missing required command: $1" >&2
    exit 1
  }
}

require_clean_worktree() {
  [[ -z "$(git status --porcelain)" ]] || {
    echo "release requires a clean worktree" >&2
    exit 1
  }
}

version_from_source() {
  local source_version
  local runtime_info_version
  local bundle_info_version

  source_version="$(awk -F'"' '/static let version = / { print $2; exit }' Sources/MacMCPBridge/AppVersion.swift)"
  runtime_info_version="$(plutil -extract CFBundleVersion raw Sources/MacMCPBridge/Info.plist)"
  bundle_info_version="$(plutil -extract CFBundleShortVersionString raw Packaging/Info.plist)"
  [[ "$source_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
    echo "source version is invalid: $source_version" >&2
    exit 1
  }
  [[ "$source_version" == "$runtime_info_version" && "$source_version" == "$bundle_info_version" ]] || {
    echo "source, runtime, and bundle versions must match" >&2
    exit 1
  }
  printf '%s\n' "$source_version"
}

update_source_formula() {
  local formula_path="$1"
  local tag="$2"
  local revision="$3"

  FORMULA_PATH="$formula_path" RELEASE_TAG="$tag" SOURCE_REVISION="$revision" ruby <<'RUBY'
path = ENV.fetch("FORMULA_PATH")
tag = ENV.fetch("RELEASE_TAG")
revision = ENV.fetch("SOURCE_REVISION")
source = File.read(path)
pattern = /  url "https:\/\/github\.com\/Dimentium\/macmcp\.git", tag: "v\d+\.\d+\.\d+", revision: "[0-9a-f]{40}"/
replacement = %(  url "https://github.com/Dimentium/macmcp.git", tag: "#{tag}", revision: "#{revision}")
updated = source.sub(pattern, replacement)
abort "MacMCP source formula release line was not found" if updated == source
File.write(path, updated)
RUBY
}

restart_local_app() {
  if pgrep -x macmcp-bridge >/dev/null; then
    osascript -e 'tell application id "com.dimentium.macmcp" to quit'
    for _ in {1..20}; do
      pgrep -x macmcp-bridge >/dev/null || break
      sleep 0.5
    done
    pgrep -x macmcp-bridge >/dev/null && {
      echo "MacMCP did not exit after the requested restart" >&2
      exit 1
    }
  fi
  open -na /Applications/MacMCP.app
  wait_for_local_runtime
}

local_runtime_ready() {
  local report
  report="$(macmcp diagnose --json 2>/dev/null)" || return 1
  REPORT="$report" ruby -rjson -e '
    report = JSON.parse(ENV.fetch("REPORT"))
    bridge_ready = report.dig("bridge", "availability") == "available"
    tunnel_ready = ["running", "not_configured"].include?(report["tunnel"])
    exit(bridge_ready && tunnel_ready ? 0 : 1)
  '
}

wait_for_local_runtime() {
  local max_attempts=30
  echo "Waiting for MacMCP bridge and configured tunnel to become ready (up to 60s)"
  for attempt in $(seq 1 "$max_attempts"); do
    if pgrep -x macmcp-bridge >/dev/null && local_runtime_ready; then
      echo "MacMCP runtime is ready after $(((attempt - 1) * 2))s"
      return 0
    fi
    if [[ "$attempt" -eq 1 || $((attempt % 5)) -eq 0 ]]; then
      echo "MacMCP is still starting (${attempt}/${max_attempts})"
    fi
    sleep 2
  done
  echo "MacMCP did not become ready after the Cask upgrade" >&2
  macmcp diagnose --json || true
  return 1
}

trap fail_release EXIT
cd "$project_dir"
umask 077
mkdir -p "$project_dir/dist"
release_log="$project_dir/dist/release-$(date '+%Y%m%d-%H%M%S')-$$.log"
exec > >(tee -a "$release_log") 2>&1
printf 'Release log: %s\n' "$release_log"

log_step 1 "Validate release inputs"
[[ -n "$signing_identity" ]] || {
  echo "--signing-identity is required" >&2
  usage >&2
  exit 2
}
[[ "$signing_identity" == "Developer ID Application:"* ]] || {
  echo "signing identity must be a Developer ID Application certificate" >&2
  exit 2
}
[[ -z "$signing_keychain" || ( "$signing_keychain" == /* && -e "$signing_keychain" ) ]] || {
  echo "signing Keychain must be an existing absolute path" >&2
  exit 2
}
for tool in git gh swift ruby plutil shasum codesign xcrun; do
  require_command "$tool"
done
[[ "$install_local" -eq 0 ]] || require_command brew
git remote get-url "$remote" >/dev/null
gh auth status --hostname github.com >/dev/null
require_clean_worktree
version="$(version_from_source)"
tag="v$version"
branch="$(git branch --show-current)"
[[ -n "$branch" ]] || {
  echo "release requires a checked-out branch" >&2
  exit 1
}
source_revision="$(git rev-parse HEAD)"
git show-ref --verify --quiet "refs/tags/$tag" && {
  echo "release tag already exists locally: $tag" >&2
  exit 1
}
git ls-remote --exit-code --tags "$remote" "refs/tags/$tag" >/dev/null 2>&1 && {
  echo "release tag already exists on $remote: $tag" >&2
  exit 1
}
printf 'Release version: %s\nSource commit: %s\nPublic remote: %s\n' \
  "$version" "$source_revision" "$remote"

log_step 2 "Run the full test suite"
swift test
require_clean_worktree

log_step 3 "Build, sign, notarize, and assess the app"
notarize_arguments=(
  "$script_dir/notarize-local-app.sh"
  --signing-identity "$signing_identity"
  --notary-profile "$notary_profile"
)
if [[ -n "$signing_keychain" ]]; then
  notarize_arguments+=(--signing-keychain "$signing_keychain")
fi
"${notarize_arguments[@]}"
archive="$project_dir/dist/MacMCP-$version-macos.zip"
checksum="$archive.sha256"
[[ -f "$archive" && -f "$checksum" ]] || {
  echo "notarization did not produce the expected release artifact" >&2
  exit 1
}
expected_checksum="$(awk 'NR == 1 { print $1 }' "$checksum")"
actual_checksum="$(shasum -a 256 "$archive" | awk '{ print $1 }')"
[[ "$actual_checksum" == "$expected_checksum" ]] || {
  echo "release artifact checksum does not match its checksum file" >&2
  exit 1
}
printf 'Notarized archive: %s\nSHA-256: %s\n' "$archive" "$actual_checksum"

log_step 4 "Tag and publish the signed source commit"
require_clean_worktree
[[ "$(git rev-parse HEAD)" == "$source_revision" ]] || {
  echo "source commit changed during the build" >&2
  exit 1
}
git ls-remote --exit-code --tags "$remote" "refs/tags/$tag" >/dev/null 2>&1 && {
  echo "release tag appeared on $remote while notarization was running: $tag" >&2
  exit 1
}
git tag -a "$tag" -m "MacMCP $version" "$source_revision"
git push "$remote" "$branch:main" "$tag"

log_step 5 "Create the GitHub Release"
gh release create "$tag" "$archive" "$checksum" \
  --repo "Dimentium/macmcp" \
  --title "MacMCP $version" \
  --notes "Signed and Apple-notarized MacMCP $version."

log_step 6 "Generate and validate the Homebrew Cask and source formula"
"$script_dir/write-cask-formula.sh" --archive "$archive"
update_source_formula "$project_dir/Formula/macmcp.rb" "$tag" "$source_revision"
ruby -c Casks/macmcp.rb
ruby -c Formula/macmcp.rb
cask_version="$(ruby -ne 'puts Regexp.last_match(1) if /^  version "([0-9.]+)"/' Casks/macmcp.rb)"
[[ "$cask_version" == "$version" ]] || {
  echo "generated Cask version does not match release version" >&2
  exit 1
}
[[ "$(grep -F "revision: \"$source_revision\"" Formula/macmcp.rb)" != "" ]] || {
  echo "source formula revision does not match the tagged source commit" >&2
  exit 1
}

log_step 7 "Commit and publish the Homebrew metadata"
git add Casks/macmcp.rb Formula/macmcp.rb
git diff --cached --quiet && {
  echo "release did not update Homebrew metadata" >&2
  exit 1
}
git commit -m "Publish MacMCP $version Cask"
git push "$remote" "$branch:main"

log_step 8 "Verify published release metadata"
gh release view "$tag" --repo "Dimentium/macmcp" --json url,isDraft,isPrerelease,assets
git status --short

if [[ "$install_local" -eq 1 ]]; then
  log_step 9 "Install the published Cask and restart MacMCP"
  brew update
  brew fetch --cask --force macmcp
  if brew list --cask macmcp >/dev/null 2>&1; then
    brew upgrade --cask macmcp
  else
    brew install --cask macmcp
  fi
  installed_version="$(plutil -extract CFBundleShortVersionString raw /Applications/MacMCP.app/Contents/Info.plist)"
  [[ "$installed_version" == "$version" ]] || {
    echo "installed Cask version does not match the release" >&2
    exit 1
  }
  restart_local_app
  macmcp diagnose --json

  log_step 10 "Run local MCP acceptance"
  "$project_dir/scripts/validate-local-mcp.sh"
fi

printf '\nRelease MacMCP %s completed successfully in %ss. Log: %s\n' "$version" "$SECONDS" "$release_log"
