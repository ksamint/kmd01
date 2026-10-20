#!/bin/sh
set -eu

repository=ksamint/kmd01
requested_ref=HEAD
run_id=

while [ "$#" -gt 0 ]; do
  case "$1" in
    --ref) requested_ref=$2; shift 2 ;;
    --run-id) run_id=$2; shift 2 ;;
    --repo) repository=$2; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

root=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
expected_commit=$(git -C "$root" rev-parse "$requested_ref^{commit}")
temporary=$(mktemp -d "${TMPDIR:-/tmp}/kmd-development-install.XXXXXX")
cleanup() { rm -rf "$temporary"; }
trap cleanup EXIT INT TERM

command -v gh >/dev/null 2>&1 || { echo "GitHub CLI is required." >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "Sign in with gh auth login first." >&2; exit 1; }

if [ -z "$run_id" ]; then
  gh workflow run build-local-development.yml \
    --repo "$repository" \
    --ref main \
    -f ref="$expected_commit"

  attempt=0
  while [ "$attempt" -lt 120 ]; do
    run_id=$(gh run list \
      --repo "$repository" \
      --workflow build-local-development.yml \
      --limit 30 \
      --json databaseId,displayTitle,status,conclusion \
      --jq ".[] | select(.displayTitle == \"Development app $expected_commit\") | .databaseId" \
      | head -1)
    if [ -n "$run_id" ]; then
      state=$(gh run view "$run_id" --repo "$repository" --json status,conclusion \
        --jq '.status + ":" + (.conclusion // "")')
      case "$state" in
        completed:success) break ;;
        completed:*) echo "Development build failed: $state" >&2; exit 1 ;;
      esac
    fi
    attempt=$((attempt + 1))
    sleep 10
  done
fi

test -n "$run_id" || { echo "Timed out waiting for the development build." >&2; exit 1; }
state=$(gh run view "$run_id" --repo "$repository" --json status,conclusion \
  --jq '.status + ":" + (.conclusion // "")')
test "$state" = completed:success || { echo "Development build is not successful: $state" >&2; exit 1; }

mkdir -p "$temporary/artifact" "$temporary/unpacked"
gh run download "$run_id" --repo "$repository" --name kmd-development --dir "$temporary/artifact"
(cd "$temporary/artifact" && shasum -a 256 -c kmd-development.zip.sha256)
ditto -x -k "$temporary/artifact/kmd-development.zip" "$temporary/unpacked"

candidate="$temporary/unpacked/kmd.app"
test -d "$candidate" || { echo "Development app bundle is missing." >&2; exit 1; }
test "$(/usr/libexec/PlistBuddy -c 'Print :KSAMINTBuildCommit' "$candidate/Contents/Info.plist")" = "$expected_commit"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$candidate/Contents/Info.plist")" = art.apuch.ksamint.markedit.dev
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$candidate/Contents/Info.plist")" = "kmd Dev"
test "$(lipo -archs "$candidate/Contents/MacOS/kmd")" = arm64
codesign --verify --deep --strict --verbose=2 "$candidate"

target="/Applications/kmd Dev.app"
backup=""
if osascript -e 'application id "art.apuch.ksamint.markedit.dev" is running' 2>/dev/null | grep -q true; then
  osascript -e 'tell application id "art.apuch.ksamint.markedit.dev" to quit' >/dev/null 2>&1 || true
  wait_count=0
  while osascript -e 'application id "art.apuch.ksamint.markedit.dev" is running' 2>/dev/null | grep -q true; do
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
trap 'rollback; cleanup' HUP INT TERM

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
if ! osascript -e 'application id "art.apuch.ksamint.markedit.dev" is running' 2>/dev/null | grep -q true; then
  echo "Installed development app failed its launch smoke test; rolling back." >&2
  rollback
  if [ -d "$target" ]; then open "$target"; fi
  exit 1
fi

trap cleanup EXIT INT TERM
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$target/Contents/Info.plist")
build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$target/Contents/Info.plist")
echo "Installed kmd Dev $version ($build), commit $expected_commit, arm64."
echo "Formal kmd remains unchanged at /Applications/kmd.app."
if [ -n "$backup" ]; then echo "Previous development app backup: $backup"; fi

