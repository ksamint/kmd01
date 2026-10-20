#!/bin/sh
set -eu
umask 077

source_mode=auto
requested_ref=HEAD
repository=ksamint/kmd01
team_id=${KSAMINT_EXPECTED_TEAM_ID:-A64LJ32AZT}
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

printf '%s\n' "$team_id" | grep -Eq '^[A-Z0-9]{10}$' || { echo "A valid expected Team ID is required." >&2; exit 2; }
case "$source_mode" in auto|ci|local|release|candidate) ;; *) echo "--source must be auto, ci, local, release, or candidate" >&2; exit 2 ;; esac
universal_source() { [ "$source_mode" = release ] || [ "$source_mode" = candidate ]; }
release_state_is_allowed() {
  case "$1:$2" in
    release:false:false|candidate:true:false|candidate:true:true) return 0 ;;
    *) return 1 ;;
  esac
}
case "$requested_arch" in auto|arm64|universal) ;; *) echo "--arch must be auto, arm64, or universal" >&2; exit 2 ;; esac
if universal_source; then
  requested_arch=universal
elif [ "$requested_arch" = auto ]; then
  requested_arch=arm64
fi
if ! universal_source && [ "$requested_arch" != arm64 ]; then
  echo "Signed CI installs currently provide arm64; use --source release for universal builds." >&2
  exit 2
fi
if [ "$requested_arch" = arm64 ] && [ "$(uname -m)" != arm64 ]; then
  echo "Use a universal release on an Intel Mac." >&2
  exit 2
fi

root=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
temporary=$(mktemp -d "${TMPDIR:-/tmp}/ksamint-install.XXXXXX")
target="/Applications/kmd.app"
legacy_target="/Applications/ksamint MarkEdit.app"
backup_root="$HOME/Library/Application Support/kmd/Local App Backups.noindex"
backup=
backup_source=
staging=
mounted=false
replacement_started=false
new_install_started=false
installation_complete=false
process_helper="$root/Scripts/ci-document-smoke.js"

running_production() { osascript -l JavaScript "$process_helper" running-production; }
stop_production() {
  processes=$(running_production) || return 1
  [ -n "$processes" ] || return 0
  # Validate every process before asking any app to quit.
  printf '%s\n' "$processes" | while IFS="$(printf '\t')" read -r pid path identifier; do
    case "$path" in
      "$target"|"$target"/Contents/*|"$legacy_target"|"$legacy_target"/Contents/*) ;;
      *) echo "Installation deferred: production process $pid uses another bundle: $path" >&2; exit 1 ;;
    esac
  done || return 1
  printf '%s\n' "$processes" | while IFS="$(printf '\t')" read -r pid path identifier; do
    osascript -l JavaScript "$process_helper" quit "$path" "$pid" >/dev/null 2>&1 || true
  done
  wait_count=0
  while [ "$wait_count" -lt 20 ]; do
    processes=$(running_production) || return 1
    [ -n "$processes" ] || return 0
    sleep 1
    wait_count=$((wait_count + 1))
  done
  echo "Installation deferred: a production app/helper declined to quit; resolve unsaved work first." >&2
  return 1
}
rollback() {
  $replacement_started || return 0
  # Never replace an executing app or restore an old database over newly written data.
  if ! stop_production; then
    echo "Rollback deferred; current app and data retained. Previous app: $backup" >&2
    return 1
  fi
  if $new_install_started && [ -e "$target" ]; then
    mv "$target" "$backup_directory/failed-candidate.app.disabled" || return 1
  fi
  if [ -n "$backup" ] && [ -d "$backup" ] && [ ! -e "$backup_source" ]; then
    mv "$backup" "$backup_source" || return 1
  fi
  echo "App replacement rolled back; user data was preserved." >&2
}
cleanup() {
  status=$?
  trap - EXIT HUP INT TERM
  if ! $installation_complete; then rollback || status=1; fi
  if $mounted; then hdiutil detach "$temporary/mount" >/dev/null 2>&1 || true; fi
  if [ -n "$staging" ] && [ -d "$staging" ]; then rm -rf "$staging"; fi
  rm -rf "$temporary"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

command -v gh >/dev/null 2>&1 || { echo "GitHub CLI is required to obtain the signed build." >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "Sign in with gh auth login first." >&2; exit 1; }

if universal_source; then
  test -n "$requested_tag" || { echo "--tag is required with --source $source_mode" >&2; exit 2; }
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

if universal_source; then
  release_state=$(gh release view "$requested_tag" --repo "$repository" \
    --json isDraft,isPrerelease --jq '(.isDraft|tostring) + ":" + (.isPrerelease|tostring)')
  release_state_is_allowed "$source_mode" "$release_state" || {
    echo "Release state $release_state is not allowed for --source $source_mode." >&2
    exit 1
  }
  mkdir -p "$temporary/release"
  gh release download "$requested_tag" --repo "$repository" --dir "$temporary/release" \
    --pattern 'ksamint-MarkEdit-*.dmg' --pattern SHA256SUMS --pattern ReleaseInfo.json
  dmg=$(find "$temporary/release" -maxdepth 1 -name 'ksamint-MarkEdit-*.dmg' -print -quit)
  test -f "$dmg" && test -f "$temporary/release/SHA256SUMS"
  expected_sha=$(awk -v name="$(basename "$dmg")" '$2 == name {print $1}' "$temporary/release/SHA256SUMS")
  actual_sha=$(shasum -a 256 "$dmg" | awk '{print $1}')
  test -n "$expected_sha" && test "$actual_sha" = "$expected_sha" || { echo "Release checksum mismatch." >&2; exit 1; }
  test "$(jq -r .arch "$temporary/release/ReleaseInfo.json")" = universal
  test "$(jq -r .commit "$temporary/release/ReleaseInfo.json")" = "$expected_commit"
  xcrun stapler validate "$dmg"
  mkdir -p "$temporary/mount" "$temporary/unpacked"
  mounted=true
  hdiutil attach "$dmg" -nobrowse -readonly -mountpoint "$temporary/mount" >/dev/null
  ditto "$temporary/mount/kmd.app" "$temporary/unpacked/kmd.app"
  hdiutil detach "$temporary/mount" >/dev/null
  mounted=false
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
  test -n "$run_id" && [ "$state" = completed:success ] || { echo "Timed out waiting for the signed CI run." >&2; exit 1; }
  gh run download "$run_id" --repo "$repository" --name ksamint-MarkEdit-signed-local --dir "$temporary/artifact"
  archive="$temporary/artifact/ksamint-MarkEdit-signed-local.zip"
  test -f "$archive" || { echo "Signed app artifact is missing." >&2; exit 1; }
  ditto -x -k "$archive" "$temporary/unpacked"
fi
candidate="$temporary/unpacked/kmd.app"
test -d "$candidate" || { echo "Signed app bundle is missing." >&2; exit 1; }

actual_commit=$(/usr/libexec/PlistBuddy -c 'Print :KSAMINTBuildCommit' "$candidate/Contents/Info.plist")
test "$actual_commit" = "$expected_commit" || { echo "Artifact commit mismatch: $actual_commit" >&2; exit 1; }
# Verify every component/profile against the exact source commit, not candidate-provided identity.
git -C "$root" cat-file -e "$expected_commit^{commit}" 2>/dev/null ||
  git -C "$root" fetch --no-tags "https://github.com/$repository.git" "$expected_commit"
(cd "$root" && Scripts/verify-release-app.sh "$candidate" "$team_id" "$expected_commit" "$requested_arch")
spctl --assess --type execute -vv "$candidate"
if universal_source; then xcrun stapler staple "$candidate"; fi
xcrun stapler validate "$candidate"

if [ -d "$target" ] && [ -d "$legacy_target" ]; then
  echo "Installation deferred: both production app names are installed." >&2
  exit 3
fi
if [ -e "$target" ]; then backup_source="$target";
elif [ -e "$legacy_target" ]; then backup_source="$legacy_target"; fi
if [ -n "$backup_source" ]; then
  test ! -L "$backup_source"
  test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$backup_source/Contents/Info.plist")" = art.apuch.ksamint.markedit
  codesign --verify --deep --strict "$backup_source"
  old_team=$(codesign -dvv "$backup_source" 2>&1 | sed -n 's/^TeamIdentifier=//p')
  test "$old_team" = "$team_id" || { echo "Installed app signing identity differs; refusing replacement." >&2; exit 1; }
fi

staging=$(mktemp -d /Applications/.kmd-install.XXXXXX)
staging_app="$staging/kmd.app"
ditto "$candidate" "$staging_app"
(cd "$root" && Scripts/verify-release-app.sh "$staging_app" "$team_id" "$expected_commit" "$requested_arch")
stop_production || exit 3
mkdir -p "$backup_root"
chmod 700 "$backup_root"
backup_directory=$(mktemp -d "$backup_root/install-$(date +%Y%m%d-%H%M%S).XXXXXX")
# Preserve only production application state; originals and Keychain/TCC are never changed.
for identifier in art.apuch.ksamint.markedit art.apuch.ksamint.markedit.conversation-capture-helper \
  art.apuch.ksamint.markedit.finder-extension art.apuch.ksamint.markedit.preview-extension \
  art.apuch.ksamint.markedit.quick-actions; do
  for relative in Documents 'Library/Application Support' Library/Preferences \
    'Library/Autosave Information' 'Library/Saved Application State'; do
    source="$HOME/Library/Containers/$identifier/Data/$relative"
    if [ -d "$source" ]; then ditto "$source" "$backup_directory/data/Containers/$identifier/Data/$relative"; fi
  done
done
for identifier in group.art.apuch.ksamint-markedit "$team_id.group.art.apuch.ksamint-markedit"; do
  source="$HOME/Library/Group Containers/$identifier"
  if [ -d "$source" ]; then ditto "$source" "$backup_directory/data/Group Containers/$identifier"; fi
done
# An automatic helper restart during the backup must abort before app replacement.
processes=$(running_production)
test -z "$processes" || { echo "Production processes restarted during backup; installation deferred." >&2; exit 3; }
if [ -n "$backup_source" ]; then
  backup="$backup_directory/previous.app.disabled"
  replacement_started=true
  mv "$backup_source" "$backup"
else
  replacement_started=true
fi
new_install_started=true
test ! -e "$target"
mv "$staging_app" "$target"
(cd "$root" && Scripts/verify-release-app.sh "$target" "$team_id" "$expected_commit" "$requested_arch")
spctl --assess --type execute "$target"
xcrun stapler validate "$target"
open -a "$target"
sleep 3
app_pid=$(osascript -l JavaScript "$process_helper" pid "$target")
test -n "$app_pid" || { echo "Installed app failed its launch smoke test." >&2; exit 1; }
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$target/Contents/Info.plist")
build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$target/Contents/Info.plist")
test "$(osascript -l JavaScript "$process_helper" pid "$target")" = "$app_pid"
installation_complete=true
echo "Installed kmd $version ($build), commit $actual_commit (PID $app_pid)."
echo "Stopped-app data backup: $backup_directory/data"
if [ -n "$backup" ]; then echo "Previous app retained at $backup"; fi
