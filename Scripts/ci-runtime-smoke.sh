#!/bin/bash
set -euo pipefail
evidence=$(cd "${1:?usage: ci-runtime-smoke.sh artifact-directory}" && pwd)
test "${CI_ISOLATED_RUNNER:-}" = github-hosted
test "${GITHUB_ACTIONS:-}" = true
cd "$evidence"
app="$evidence/runtime-app/kmd.app"
cleanup() {
  reports="$HOME/Library/Logs/DiagnosticReports"
  if [ -d "$reports" ]; then
    mkdir -p "$evidence/diagnostics"
    for plist in "$app/Contents/Info.plist" \
      "$app/Contents/Library/LoginItems/ConversationCaptureHelper.app/Contents/Info.plist"; do
      [ -f "$plist" ] || continue
      executable_name=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$plist") || continue
      find "$reports" -maxdepth 1 -name "$executable_name-*.ips" -exec cp {} "$evidence/diagnostics/" \;
    done
  fi
  rm -rf "$evidence/runtime-app"
}
trap cleanup EXIT
sw_vers > runtime-macos.txt
uname -m > runtime-architecture.txt
if [ -n "${CI_RUNTIME_ARCH:-}" ]; then test "$(uname -m)" = "$CI_RUNTIME_ARCH"; fi
shasum -a 256 -c kmd-release.zip.sha256
test "$(cat commit.txt)" = "$(git -C "$GITHUB_WORKSPACE" rev-parse HEAD)"
mkdir -p runtime-app
ditto -x -k kmd-release.zip runtime-app
test "$(/usr/libexec/PlistBuddy -c 'Print :KSAMINTBuildCommit' "$app/Contents/Info.plist")" = "$(cat commit.txt)"
codesign --verify --deep --strict "$app"
# Hosted runners provide a fresh user account; never run this against a developer's data.
CI_SMOKE_EVIDENCE_DIR="$evidence" \
  "$GITHUB_WORKSPACE/Scripts/test-document-open-smoke.sh" "$app" 2>&1 | tee runtime.log
