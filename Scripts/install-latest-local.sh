#!/bin/bash
#
# Installs a Developer ID-signed, notarized kmd at /Applications/kmd.app.
#
#   --source local (default; "auto" is an alias)
#       Builds, signs, notarizes, and staples the exact commit on this Mac.
#       Replaces the retired signed-local-install.yml workflow and records the
#       signed-local-build gate under .local-evidence/<commit>/.
#   --source release --tag vX.Y.Z
#       Downloads the published, final GitHub release and verifies it.
#
# Both sources then pass the same safe-install gate (signed-install evidence),
# which refuses to install anything that does not verify for the exact commit.
# Signing credentials: see Scripts/lib/developer-id.sh.
#
# Usage: Scripts/install-latest-local.sh [--source local|release] [--ref REF]
#          [--tag TAG] [--repo OWNER/REPO] [--team-id TEAM] [--arch arm64]
set -euo pipefail

source_mode=local
requested_ref=HEAD
repository=fengurt/ksa-MarkEdit
team_id=${KSAMINT_EXPECTED_TEAM_ID:-}
requested_arch=auto
requested_tag=
original_args=("$@")

while [ "$#" -gt 0 ]; do
  case "$1" in
    --source) source_mode=${2:?--source needs a value}; shift 2 ;;
    --ref) requested_ref=${2:?--ref needs a value}; shift 2 ;;
    --tag) requested_tag=${2:?--tag needs a value}; shift 2 ;;
    --repo) repository=${2:?--repo needs a value}; shift 2 ;;
    --team-id) team_id=${2:?--team-id needs a value}; shift 2 ;;
    --arch) requested_arch=${2:?--arch needs a value}; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

case "$source_mode" in
  auto|local) source_mode=local ;;
  release) ;;
  ci) echo "--source ci was removed: GitHub runners are retired. Use --source local." >&2; exit 2 ;;
  *) echo "--source must be local or release" >&2; exit 2 ;;
esac
case "$requested_arch" in
  auto) requested_arch=$(uname -m) ;;
  arm64) ;;
  *) echo "--arch must resolve to arm64 for v2.5" >&2; exit 2 ;;
esac
test "$requested_arch" = arm64 || {
  echo "kmd v2.5 supports Apple Silicon Macs only." >&2
  exit 2
}

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=Scripts/lib/local-evidence.sh
. "$script_dir/lib/local-evidence.sh"
# shellcheck source=Scripts/lib/developer-id.sh
. "$script_dir/lib/developer-id.sh"

le_require_macos
le_require_commands git jq ditto codesign spctl lipo xcrun pgrep osascript shasum

temporary=$(mktemp -d "${TMPDIR:-/tmp}/ksamint-install.XXXXXX")
source_dir="$temporary/src"
cleanup() {
  local code=$?
  le_on_exit "$code"
  if [ -d "$temporary/mount" ]; then hdiutil detach "$temporary/mount" >/dev/null 2>&1 || true; fi
  le_remove_checkout "$source_dir"
  rm -rf "$temporary"
  exit "$code"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

if [ "$source_mode" = release ]; then
  le_require_commands gh hdiutil
  gh auth status >/dev/null 2>&1 || le_die "Sign in with gh auth login first."
  test -n "$requested_tag" || { echo "--tag is required with --source release" >&2; exit 2; }
  expected_commit=$(gh api "repos/$repository/commits/$requested_tag" --jq .sha)
  git -C "$le_repo_root" cat-file -e "$expected_commit^{commit}" 2>/dev/null \
    || le_die "Release commit $expected_commit is not in this clone; fetch it first."
else
  le_require_commands node corepack xcodebuild security plutil ruby curl
  le_require_clean_tree
  expected_commit=$(le_resolve_commit "$requested_ref")
fi

work="$temporary/work"
mkdir -p "$work" "$temporary/unpacked"
signed_archive="$temporary/ksamint-MarkEdit-signed-local.zip"

build_core_editor() {
  cd "$source_dir/CoreEditor"
  corepack yarn --version
  corepack yarn install --immutable
  corepack yarn build
}

zip_unstapled() {
  ditto -c -k --keepParent "$work/export/kmd.app" "$work/ksamint-MarkEdit-signed-unstapled.zip"
}

notarize_app() {
  di_notary_submit "$work/ksamint-MarkEdit-signed-unstapled.zip" "$work/notary-submission.json"
  di_notary_wait "$(jq -r '.id' "$work/notary-submission.json")" "$work/notary-log.json" \
    "${KSAMINT_NOTARY_TIMEOUT:-1800}"
}

staple_and_verify_build() {
  local app="$work/export/kmd.app" archs
  xcrun stapler staple "$app"
  xcrun stapler validate "$app"
  codesign --verify --deep --strict --verbose=2 "$app"
  spctl --assess --type execute -vv "$app"
  archs="$(lipo -archs "$app/Contents/MacOS/kmd")"
  echo "$archs" | grep -qw arm64
  if echo "$archs" | grep -qw x86_64; then exit 1; fi
  test -d "$app/Contents/Library/LoginItems/ConversationCaptureHelper.app"
  test -d "$app/Contents/PlugIns/QuickActionExtension.appex"
  ditto -c -k --keepParent "$app" "$signed_archive"
}

download_release() {
  local release_state dmg expected_sha actual_sha
  release_state=$(gh release view "$requested_tag" --repo "$repository" \
    --json isDraft,isPrerelease --jq '(.isDraft|tostring) + ":" + (.isPrerelease|tostring)')
  test "$release_state" = false:false || { echo "Release is not final: $release_state" >&2; exit 1; }
  mkdir -p "$temporary/release"
  gh release download "$requested_tag" --repo "$repository" --dir "$temporary/release" \
    --pattern 'ksamint-MarkEdit-*.dmg' --pattern SHA256SUMS --pattern ReleaseInfo.json
  dmg=$(find "$temporary/release" -maxdepth 1 -name 'ksamint-MarkEdit-*.dmg' -print -quit)
  test -f "$dmg" && test -f "$temporary/release/SHA256SUMS"
  expected_sha=$(awk -v name="$(basename "$dmg")" '$2 == name {print $1}' "$temporary/release/SHA256SUMS")
  actual_sha=$(shasum -a 256 "$dmg" | awk '{print $1}')
  test -n "$expected_sha" && test "$actual_sha" = "$expected_sha" || { echo "Release checksum mismatch." >&2; exit 1; }
  test "$(jq -r .arch "$temporary/release/ReleaseInfo.json")" = arm64
  test "$(jq -r .commit "$temporary/release/ReleaseInfo.json")" = "$expected_commit"
  xcrun stapler validate "$dmg"
  mkdir -p "$temporary/mount"
  hdiutil attach "$dmg" -nobrowse -readonly -mountpoint "$temporary/mount" >/dev/null
  ditto "$temporary/mount/kmd.app" "$temporary/unpacked/kmd.app"
  hdiutil detach "$temporary/mount" >/dev/null
  rmdir "$temporary/mount"
}

if [ "$source_mode" = local ]; then
  # Gate 1: sign and notarize the exact commit on this Mac.
  le_begin signed-local-build "$expected_commit" ${original_args[@]+"${original_args[@]}"}
  le_set_string architecture "$requested_arch"
  di_resolve_credentials
  if [ -z "$team_id" ]; then team_id=$APPLE_TEAM_ID; fi
  le_step checkout le_checkout_exact "$expected_commit" "$source_dir"
  le_step toolchain le_toolchain_report xcodebuild node
  le_step node-version le_require_node_24
  le_step validate-product-identity node "$source_dir/Scripts/validate-product-identity.mjs"
  le_step core-editor build_core_editor
  le_step provisioning-profiles di_install_profiles
  le_step archive-and-export di_archive_and_export "$source_dir" "$work" "$expected_commit"
  le_step zip-unstapled zip_unstapled
  le_artifact signed-unstapled.zip "$work/ksamint-MarkEdit-signed-unstapled.zip"
  le_step notarize notarize_app
  le_set_string notarySubmissionID "$(jq -r '.id' "$work/notary-submission.json")"
  le_step staple-and-verify staple_and_verify_build
  le_artifact ksamint-MarkEdit-signed-local.zip "$signed_archive"
  le_pass
  le_require_gate signed-local-build "$expected_commit"
  le_require_artifact signed-local-build "$expected_commit" ksamint-MarkEdit-signed-local.zip "$signed_archive"
fi

# Gate 2: the same safe-install checks for local builds and final releases.
le_begin signed-install "$expected_commit" ${original_args[@]+"${original_args[@]}"}
le_set_string source "$source_mode"
if [ "$source_mode" = release ]; then
  le_set_string tag "$requested_tag"
  le_step download-release download_release
else
  le_step unpack-local-build ditto -x -k "$signed_archive" "$temporary/unpacked"
fi

candidate="$temporary/unpacked/kmd.app"
verify_candidate() {
  local actual_commit archs actual_team
  test -d "$candidate" || { echo "Signed app bundle is missing." >&2; exit 1; }
  actual_commit=$(/usr/libexec/PlistBuddy -c 'Print :KSAMINTBuildCommit' "$candidate/Contents/Info.plist")
  test "$actual_commit" = "$expected_commit" || { echo "Artifact commit mismatch: $actual_commit" >&2; exit 1; }
  archs=$(lipo -archs "$candidate/Contents/MacOS/kmd")
  echo "$archs" | grep -qw arm64
  if echo "$archs" | grep -qw x86_64; then exit 1; fi
  codesign --verify --deep --strict --verbose=2 "$candidate"
  spctl --assess --type execute -vv "$candidate"
  # The distributed DMG carries its own ticket. Also staple the exact accepted
  # App after extraction so the installed bundle remains verifiable offline and
  # the safe-install gate is identical for release and local builds.
  if [ "$source_mode" = release ]; then
    xcrun stapler staple "$candidate"
  fi
  xcrun stapler validate "$candidate"
  actual_team=$(codesign -dvv "$candidate" 2>&1 | sed -n 's/^TeamIdentifier=//p')
  printf '%s\n' "$actual_team" > "$temporary/actual-team"
}
le_step verify-candidate verify_candidate

actual_team=$(cat "$temporary/actual-team")
if [ -z "$team_id" ]; then team_id=$actual_team; fi
test -n "$team_id" && test "$actual_team" = "$team_id" || { echo "Unexpected signing Team ID: $actual_team" >&2; exit 1; }
le_set_string teamID "$actual_team"

target="/Applications/kmd.app"
legacy_target="/Applications/ksamint MarkEdit.app"
if [ -d "$target" ] && [ -d "$legacy_target" ]; then
  echo "Installation deferred: both the old and renamed app are installed; remove one after checking for unsaved documents." >&2
  exit 3
fi
app_running() {
  pgrep -x 'kmd' >/dev/null 2>&1 || pgrep -x 'ksamint MarkEdit' >/dev/null 2>&1
}
if app_running; then
  osascript -e 'tell application id "art.apuch.ksamint.markedit" to quit' >/dev/null 2>&1 || true
  wait_count=0
  while app_running && [ "$wait_count" -lt 20 ]; do
    sleep 1
    wait_count=$((wait_count + 1))
  done
  if app_running; then
    echo "Installation deferred: the app still has a window or unsaved document open." >&2
    exit 3
  fi
fi

backup=
backup_source=
if [ -d "$target" ]; then
  backup_source="$target"
  backup="/Applications/kmd.backup-$(date +%Y%m%d-%H%M%S).app"
elif [ -d "$legacy_target" ]; then
  backup_source="$legacy_target"
  backup="/Applications/ksamint MarkEdit.backup-$(date +%Y%m%d-%H%M%S).app"
fi
if [ -n "$backup_source" ]; then
  mv "$backup_source" "$backup"
fi
rollback() {
  rm -rf "$target"
  if [ -n "$backup" ] && [ -d "$backup" ]; then mv "$backup" "$backup_source"; fi
}
trap 'rollback; exit 130' HUP INT TERM

if ! ditto "$candidate" "$target"; then rollback; exit 1; fi
if ! codesign --verify --deep --strict "$target" || ! spctl --assess --type execute "$target"; then
  echo "Installed app failed verification; rolling back." >&2
  rollback
  exit 1
fi

open -a "$target"
sleep 3
if ! pgrep -x 'kmd' >/dev/null 2>&1; then
  echo "Installed app failed its launch smoke test; rolling back." >&2
  rollback
  if [ -n "$backup_source" ] && [ -d "$backup_source" ]; then open -a "$backup_source"; fi
  exit 1
fi
trap 'exit 130' HUP INT TERM

installed_checks() {
  test -d "$target/Contents/Library/LoginItems/ConversationCaptureHelper.app"
  test -d "$target/Contents/PlugIns/FinderExtension.appex"
  test -d "$target/Contents/PlugIns/QuickActionExtension.appex"
  codesign --verify --deep --strict --verbose=2 "$target"
}
le_step installed-checks installed_checks
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$target/Contents/Info.plist")
build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$target/Contents/Info.plist")
le_set_string installedVersion "$version ($build)"
if [ -n "$backup" ]; then le_set_string backupPath "$backup"; fi
le_pass
echo "Installed kmd $version ($build), commit $expected_commit."
if [ -n "$backup" ]; then echo "Previous app retained at $backup"; fi
