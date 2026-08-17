#!/bin/sh
set -eu

source_mode=auto
requested_ref=HEAD
repository=fengurt/ksa-MarkEdit
team_id=${KSAMINT_EXPECTED_TEAM_ID:-}
requested_arch=auto
requested_tag=

while [ "$#" -gt 0 ]; do
  case "$1" in
    --source) source_mode=$2; shift 2 ;;
    --ref) requested_ref=$2; shift 2 ;;
    --tag) requested_tag=$2; shift 2 ;;
    --repo) repository=$2; shift 2 ;;
    --team-id) team_id=$2; shift 2 ;;
    --arch) requested_arch=$2; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

case "$source_mode" in auto|ci|local|release) ;; *) echo "--source must be auto, ci, local, or release" >&2; exit 2 ;; esac
case "$requested_arch" in
  auto) requested_arch=$(uname -m) ;;
  arm64) ;;
  *) echo "--arch must resolve to arm64 for v2.5" >&2; exit 2 ;;
esac
test "$requested_arch" = arm64 || {
  echo "kmd v2.5 supports Apple Silicon Macs only." >&2
  exit 2
}

root=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
temporary=$(mktemp -d "${TMPDIR:-/tmp}/ksamint-install.XXXXXX")
cleanup() { rm -rf "$temporary"; }
trap cleanup EXIT INT TERM

command -v gh >/dev/null 2>&1 || { echo "GitHub CLI is required to obtain the signed build." >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "Sign in with gh auth login first." >&2; exit 1; }

if [ "$source_mode" = release ]; then
  test -n "$requested_tag" || { echo "--tag is required with --source release" >&2; exit 2; }
  expected_commit=$(gh api "repos/$repository/commits/$requested_tag" --jq .sha)
else
  expected_commit=$(git -C "$root" rev-parse "$requested_ref^{commit}")
fi

build_locally=false
if [ "$source_mode" = local ]; then build_locally=true; fi
if [ "$source_mode" = auto ] && xcode-select -p 2>/dev/null | grep -q '/Xcode.app/Contents/Developer'; then
  if security find-identity -v -p codesigning | grep -q 'Developer ID Application'; then build_locally=true; fi
fi

if $build_locally; then
  echo "A notarized local build requires the release workflow; dispatching CI for $expected_commit."
fi

if [ "$source_mode" = release ]; then
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
  mkdir -p "$temporary/mount" "$temporary/unpacked"
  hdiutil attach "$dmg" -nobrowse -readonly -mountpoint "$temporary/mount" >/dev/null
  ditto "$temporary/mount/kmd.app" "$temporary/unpacked/kmd.app"
  hdiutil detach "$temporary/mount" >/dev/null
else
  gh workflow run signed-local-install.yml --repo "$repository" --ref main \
    -f ref="$expected_commit" -f architecture="$requested_arch"
  run_id=
  attempt=0
  while [ "$attempt" -lt 120 ]; do
    run_id=$(gh run list --repo "$repository" --workflow signed-local-install.yml --limit 30 --json databaseId,displayTitle,status,conclusion --jq ".[] | select(.displayTitle == \"Signed local $requested_arch $expected_commit\") | .databaseId" | head -1)
    if [ -n "$run_id" ]; then
      state=$(gh run view "$run_id" --repo "$repository" --json status,conclusion --jq '.status + ":" + (.conclusion // "")')
      case "$state" in
        completed:success) break ;;
        completed:*) echo "Signed CI build failed: $state" >&2; exit 1 ;;
      esac
    fi
    attempt=$((attempt + 1))
    sleep 15
  done
  test -n "$run_id" || { echo "Timed out waiting for the signed CI run." >&2; exit 1; }
  gh run download "$run_id" --repo "$repository" --name ksamint-MarkEdit-signed-local --dir "$temporary/artifact"
  archive="$temporary/artifact/ksamint-MarkEdit-signed-local.zip"
  test -f "$archive" || { echo "Signed app artifact is missing." >&2; exit 1; }
  ditto -x -k "$archive" "$temporary/unpacked"
fi
candidate="$temporary/unpacked/kmd.app"
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
# the safe-install gate is identical for Release and CI artifacts.
if [ "$source_mode" = release ]; then
  xcrun stapler staple "$candidate"
fi
xcrun stapler validate "$candidate"

actual_team=$(codesign -dvv "$candidate" 2>&1 | sed -n 's/^TeamIdentifier=//p')
if [ -z "$team_id" ]; then team_id=$actual_team; fi
test -n "$team_id" && test "$actual_team" = "$team_id" || { echo "Unexpected signing Team ID: $actual_team" >&2; exit 1; }

target="/Applications/kmd.app"
legacy_target="/Applications/ksamint MarkEdit.app"
backup_root="$HOME/Library/Application Support/kmd/Local App Backups.noindex"
if [ -d "$target" ] && [ -d "$legacy_target" ]; then
  echo "Installation deferred: both the old and renamed app are installed; remove one after checking for unsaved documents." >&2
  exit 3
fi
if pgrep -x 'kmd' >/dev/null 2>&1 || pgrep -x 'ksamint MarkEdit' >/dev/null 2>&1; then
  osascript -e 'tell application id "art.apuch.ksamint.markedit" to quit' >/dev/null 2>&1 || true
  wait_count=0
  while { pgrep -x 'kmd' >/dev/null 2>&1 || pgrep -x 'ksamint MarkEdit' >/dev/null 2>&1; } && [ "$wait_count" -lt 20 ]; do
    sleep 1
    wait_count=$((wait_count + 1))
  done
  if pgrep -x 'kmd' >/dev/null 2>&1 || pgrep -x 'ksamint MarkEdit' >/dev/null 2>&1; then
    echo "Installation deferred: the app still has a window or unsaved document open." >&2
    exit 3
  fi
fi

backup=
backup_source=
if [ -d "$target" ]; then
  backup_source="$target"
  backup="$backup_root/kmd-backup-$(date +%Y%m%d-%H%M%S).app.disabled"
elif [ -d "$legacy_target" ]; then
  backup_source="$legacy_target"
  backup="$backup_root/ksamint-MarkEdit-backup-$(date +%Y%m%d-%H%M%S).app.disabled"
fi
if [ -n "$backup_source" ]; then
  mkdir -p "$backup_root"
  chmod 700 "$backup_root"
  # A stopped helper cannot keep executing from the rollback bundle after the
  # app moves. The replacement app re-registers the same stable login item.
  pkill -TERM -x ConversationCaptureHelper >/dev/null 2>&1 || true
  mv "$backup_source" "$backup"
fi
rollback() {
  rm -rf "$target"
  if [ -n "$backup" ] && [ -d "$backup" ]; then mv "$backup" "$backup_source"; fi
}
trap 'rollback; cleanup' HUP INT TERM

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

version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$target/Contents/Info.plist")
build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$target/Contents/Info.plist")
test -d "$target/Contents/Library/LoginItems/ConversationCaptureHelper.app"
test -d "$target/Contents/PlugIns/FinderExtension.appex"
test -d "$target/Contents/PlugIns/QuickActionExtension.appex"
echo "Installed kmd $version ($build), commit $actual_commit."
if [ -n "$backup" ]; then echo "Previous app retained at $backup"; fi
