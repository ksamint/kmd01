#!/bin/bash
#
# Builds the ARM64 "kmd Dev" app for an exact commit on this Mac and installs
# it at /Applications/kmd Dev.app, leaving the formal /Applications/kmd.app
# untouched.
#
# Replaces the retired build-local-development.yml workflow: the same commands
# run in a pristine worktree of the commit, and the gates record local evidence
# under .local-evidence/<commit>/ (development-build, development-install).
# Installation refuses to start unless the build gate passed for the exact
# commit and the candidate still matches the recorded digest.
#
# Usage: Scripts/install-development-local.sh [--ref REF]
set -euo pipefail

requested_ref=HEAD
original_args=("$@")
while [ "$#" -gt 0 ]; do
  case "$1" in
    --ref) requested_ref=${2:?--ref needs a value}; shift 2 ;;
    --run-id|--repo)
      echo "$1 was removed: GitHub runners are retired and the app now builds locally." >&2
      exit 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=Scripts/lib/local-evidence.sh
. "$script_dir/lib/local-evidence.sh"

le_require_macos
le_require_commands git jq node corepack xcodebuild ditto codesign lipo osascript shasum
le_require_clean_tree
expected_commit=$(le_resolve_commit "$requested_ref")

temporary=$(mktemp -d "${TMPDIR:-/tmp}/kmd-development-install.XXXXXX")
source_dir="$temporary/src"
derived_data="$temporary/DerivedData"
archive="$temporary/kmd-development.zip"
app="$derived_data/Build/Products/Debug/kmd.app"
cleanup() {
  local code=$?
  le_on_exit "$code"
  le_remove_checkout "$source_dir"
  rm -rf "$temporary"
  exit "$code"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

build_core_editor() {
  cd "$source_dir/CoreEditor"
  corepack yarn --version
  corepack yarn install --immutable
  corepack yarn build
}

build_app() {
  cd "$source_dir"
  xcodebuild build \
    -project MarkEdit.xcodeproj \
    -scheme MarkEditMac \
    -configuration Debug \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$derived_data" \
    KSAMINT_BUILD_COMMIT="$expected_commit" \
    CODE_SIGN_IDENTITY="" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO
}

check_and_sign_bundle() {
  test -d "$app"
  /usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName kmd Dev' "$app/Contents/Info.plist"
  test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")" = art.apuch.ksamint.markedit.dev
  test "$(/usr/libexec/PlistBuddy -c 'Print :KSAMINTBuildCommit' "$app/Contents/Info.plist")" = "$expected_commit"
  lipo -archs "$app/Contents/MacOS/kmd" | grep -Fx arm64
  codesign --force --deep --sign - --timestamp=none "$app"
  codesign --verify --deep --strict --verbose=2 "$app"
  ditto -c -k --keepParent "$app" "$archive"
}

# Gate 1: build the exact commit.
le_begin development-build "$expected_commit" ${original_args[@]+"${original_args[@]}"}
le_set_string channel development
le_step checkout le_checkout_exact "$expected_commit" "$source_dir"
le_step toolchain le_toolchain_report xcodebuild node
le_step node-version le_require_node_24
le_step core-editor build_core_editor
le_step xcodebuild build_app
le_step bundle-checks-and-adhoc-sign check_and_sign_bundle
le_artifact kmd-development.zip "$archive"
le_pass

# Gate 2: install only what gate 1 accepted.
le_require_gate development-build "$expected_commit"
le_require_artifact development-build "$expected_commit" kmd-development.zip "$archive"
le_begin development-install "$expected_commit" ${original_args[@]+"${original_args[@]}"}

candidate="$temporary/unpacked/kmd.app"
verify_candidate() {
  mkdir -p "$temporary/unpacked"
  ditto -x -k "$archive" "$temporary/unpacked"
  test -d "$candidate"
  test "$(/usr/libexec/PlistBuddy -c 'Print :KSAMINTBuildCommit' "$candidate/Contents/Info.plist")" = "$expected_commit"
  test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$candidate/Contents/Info.plist")" = art.apuch.ksamint.markedit.dev
  test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$candidate/Contents/Info.plist")" = "kmd Dev"
  test "$(lipo -archs "$candidate/Contents/MacOS/kmd")" = arm64
  codesign --verify --deep --strict --verbose=2 "$candidate"
}
le_step verify-candidate verify_candidate

target="/Applications/kmd Dev.app"
backup=""
dev_running() {
  osascript -e 'application id "art.apuch.ksamint.markedit.dev" is running' 2>/dev/null | grep -q true
}
if dev_running; then
  osascript -e 'tell application id "art.apuch.ksamint.markedit.dev" to quit' >/dev/null 2>&1 || true
  wait_count=0
  while dev_running; do
    test "$wait_count" -lt 20 || {
      echo "Installation deferred: kmd Dev still has a window or unsaved document open." >&2
      exit 3
    }
    wait_count=$((wait_count + 1))
    sleep 1
  done
fi

if [ -d "$target" ]; then
  backup="/Applications/kmd Dev.backup-$(date +%Y%m%d-%H%M%S).app"
  mv "$target" "$backup"
fi

rollback() {
  if [ -d "$target" ]; then
    mv "$target" "$temporary/failed.app"
  fi
  if [ -n "$backup" ] && [ -d "$backup" ]; then
    mv "$backup" "$target"
  fi
}
trap 'rollback; exit 130' HUP INT TERM

if ! ditto "$candidate" "$target"; then
  rollback
  exit 1
fi
if ! codesign --verify --deep --strict "$target"; then
  echo "Installed development app failed signature verification; rolling back." >&2
  rollback
  exit 1
fi

open "$target"
sleep 3
if ! dev_running; then
  echo "Installed development app failed its launch smoke test; rolling back." >&2
  rollback
  if [ -d "$target" ]; then open "$target"; fi
  exit 1
fi

trap 'exit 130' HUP INT TERM
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$target/Contents/Info.plist")
build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$target/Contents/Info.plist")
le_set_string installedPath "$target"
le_set_string installedVersion "$version ($build)"
if [ -n "$backup" ]; then le_set_string backupPath "$backup"; fi
le_step installed-signature codesign --verify --deep --strict --verbose=2 "$target"
le_pass
echo "Installed kmd Dev $version ($build), commit $expected_commit, arm64."
echo "Formal kmd remains unchanged at /Applications/kmd.app."
if [ -n "$backup" ]; then echo "Previous development app backup: $backup"; fi
