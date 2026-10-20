#!/bin/bash
set -euo pipefail

app=${1:?usage: verify-release-app.sh APP TEAM_ID COMMIT [arm64|universal]}
expected_team=${2:?missing Team ID}
expected_commit=${3:?missing commit}
architecture=${4:-arm64}
[[ "$expected_commit" =~ ^[0-9a-f]{40}$ ]]
case "$architecture" in arm64|universal) ;; *) exit 2 ;; esac
root=$(git rev-parse --show-toplevel)
git cat-file -e "$expected_commit^{commit}"
temporary=$(mktemp -d)
trap 'rm -rf "$temporary"' EXIT

test -d "$app"
codesign --verify --deep --strict --verbose=2 "$app"

actual_commit=$(/usr/libexec/PlistBuddy -c 'Print :KSAMINTBuildCommit' "$app/Contents/Info.plist")
test "$actual_commit" = "$expected_commit" || {
  echo "Build commit mismatch: expected $expected_commit, found $actual_commit" >&2
  exit 1
}

git show "$expected_commit:Build.xcconfig" > "$temporary/Build.xcconfig"
expected_version=$(sed -n 's/^MARKETING_VERSION = //p' "$temporary/Build.xcconfig")
expected_build=$(sed -n 's/^CURRENT_PROJECT_VERSION = //p' "$temporary/Build.xcconfig")
test -n "$expected_version"
test -n "$expected_build"
source_icon="$temporary/Icon.png"
git show "$expected_commit:Icon.png" > "$source_icon"
built_icon="$app/Contents/Resources/Icon.png"
test -f "$source_icon"
test -f "$built_icon"
expected_icon_hash=$(shasum -a 256 "$source_icon" | awk '{print $1}')
actual_icon_hash=$(shasum -a 256 "$built_icon" | awk '{print $1}')
test "$actual_icon_hash" = "$expected_icon_hash" || {
  echo "App icon mismatch: expected $expected_icon_hash, found $actual_icon_hash" >&2
  exit 1
}

for bundle in \
  "$app" \
  "$app/Contents/Library/LoginItems/ConversationCaptureHelper.app" \
  "$app/Contents/PlugIns/FinderExtension.appex" \
  "$app/Contents/PlugIns/PreviewExtension.appex" \
  "$app/Contents/PlugIns/QuickActionExtension.appex"
do
  test -d "$bundle"
  signature=$(codesign -dvv "$bundle" 2>&1)
  printf '%s\n' "$signature" | grep -Eq '^CodeDirectory .*flags=.*runtime'
  team=$(printf '%s\n' "$signature" | sed -n 's/^TeamIdentifier=//p')
  test "$team" = "$expected_team" || {
    echo "Unexpected Team ID for $bundle: $team" >&2
    exit 1
  }
  test -f "$bundle/Contents/embedded.provisionprofile"
  security cms -D -i "$bundle/Contents/embedded.provisionprofile" > "$temporary/profile.plist"
  codesign -d --entitlements :- "$bundle" > "$temporary/signed.plist"
  component=$(basename "$bundle")
  case "$component" in
    kmd.app) target=MarkEditMac; expected_id=art.apuch.ksamint.markedit ;;
    ConversationCaptureHelper.app) target=ConversationCaptureHelper; expected_id=art.apuch.ksamint.markedit.conversation-capture-helper ;;
    FinderExtension.appex) target=FinderExtension; expected_id=art.apuch.ksamint.markedit.finder-extension ;;
    PreviewExtension.appex) target=PreviewExtension; expected_id=art.apuch.ksamint.markedit.preview-extension ;;
    QuickActionExtension.appex) target=QuickActionExtension; expected_id=art.apuch.ksamint.markedit.quick-actions ;;
    *) exit 1 ;;
  esac
  bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$bundle/Contents/Info.plist")
  test "$bundle_id" = "$expected_id"
  test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$bundle/Contents/Info.plist")" = "$expected_version"
  test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$bundle/Contents/Info.plist")" = "$expected_build"
  test "$(/usr/libexec/PlistBuddy -c 'Print :KSAMINTBuildCommit' "$bundle/Contents/Info.plist")" = "$expected_commit"
  git show "$expected_commit:$target/Info.entitlements" > "$temporary/source.plist"
  python3 "$root/Scripts/verify-release-profile.py" \
    "$temporary/profile.plist" "$temporary/signed.plist" "$temporary/source.plist" \
    "$bundle_id" "$expected_team"
done

mach_o_count=0
while IFS= read -r -d '' executable; do
  if file "$executable" | grep -q 'Mach-O'; then
    mach_o_count=$((mach_o_count + 1))
    codesign --verify --strict "$executable"
    archs=$(lipo -archs "$executable" | xargs -n 1 | sort | xargs)
    expected_archs=arm64
    if [ "$architecture" = universal ]; then expected_archs='arm64 x86_64'; fi
    if [ "$archs" != "$expected_archs" ]; then
      echo "Architecture mismatch in $executable: expected $expected_archs, found $archs" >&2
      exit 1
    fi
  fi
done < <(find "$app" -type f -print0)
test "$mach_o_count" -ge 5

echo "Verified $architecture release app for commit $expected_commit and Team ID $expected_team."
