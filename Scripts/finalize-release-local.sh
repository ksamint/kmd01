#!/bin/bash
#
# Publishes a draft kmd release once Apple has accepted both notarization
# submissions, then updates the Homebrew tap. Replaces the retired
# finalize-release.yml ("Finalize notarized release") workflow.
#
# Gates (fail closed):
#   * the local release gate passed for the tag's commit (Scripts/release-local.sh
#     on this Mac), and the draft's NotarySubmission.json matches it;
#   * the draft's unstapled DMG and CLI bytes match the digests that gate recorded;
#   * Apple accepted both submissions (nothing is ever resubmitted);
#   * the stapled DMG, app, and CLI verify for the team and commit.
# Evidence: .local-evidence/<commit>/finalize-release.json.
#
# The Homebrew tap is pushed with your own git credentials. When the kmd cask
# is already installed on this Mac, the install/uninstall smoke test is
# replaced by `brew fetch` so your installed app is never removed.
#
# Usage: Scripts/finalize-release-local.sh --tag vX.Y.Z [--repo OWNER/REPO]
#          [--wait [MINUTES]]
# Exit status 4 means Apple is still processing; rerun later or use --wait.
set -euo pipefail

release_tag=
repository=fengurt/ksa-MarkEdit
wait_minutes=0
original_args=("$@")
while [ "$#" -gt 0 ]; do
  case "$1" in
    --tag) release_tag=${2:?--tag needs a value}; shift 2 ;;
    --repo) repository=${2:?--repo needs a value}; shift 2 ;;
    --wait)
      case "${2:-}" in
        ''|-*) wait_minutes=60; shift ;;
        *) wait_minutes=$2; shift 2 ;;
      esac ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done
case "$release_tag" in
  v[0-9]*.[0-9]*.[0-9]*) ;;
  *) echo "--tag must look like v1.2.3" >&2; exit 2 ;;
esac
case "$wait_minutes" in
  *[!0-9]*) echo "--wait takes whole minutes" >&2; exit 2 ;;
esac
version="${release_tag#v}"

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=Scripts/lib/local-evidence.sh
. "$script_dir/lib/local-evidence.sh"
# shellcheck source=Scripts/lib/developer-id.sh
. "$script_dir/lib/developer-id.sh"

le_require_macos
le_require_commands git jq gh xcrun codesign spctl hdiutil ditto lipo shasum stat ruby brew security
le_require_clean_tree
gh auth status >/dev/null 2>&1 || le_die "Sign in with gh auth login first."

temporary=$(mktemp -d "${TMPDIR:-/tmp}/kmd-finalize.XXXXXX")
work="$temporary/work"
mount="$temporary/mount"
source_dir="$temporary/src"
mkdir -p "$work"
cleanup() {
  local code=$?
  le_on_exit "$code"
  if [ -d "$mount" ]; then hdiutil detach "$mount" >/dev/null 2>&1 || true; fi
  le_remove_checkout "$source_dir"
  rm -rf "$temporary"
  exit "$code"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

release_state=$(gh release view "$release_tag" --repo "$repository" --json isDraft --jq '.isDraft|tostring')
test "$release_state" = true || le_die "$release_tag on $repository is not a draft release."
gh release download "$release_tag" --repo "$repository" --dir "$work" --pattern NotarySubmission.json \
  || le_die "$release_tag has no persisted notarization metadata."
metadata="$work/NotarySubmission.json"
test "$(jq -r '.tag' "$metadata")" = "$release_tag" || le_die "NotarySubmission.json names another tag."
commit=$(jq -r '.commit' "$metadata")
team=$(jq -r '.teamID' "$metadata")
remote_commit=$(gh api "repos/$repository/commits/$release_tag" --jq .sha)
test "$remote_commit" = "$commit" || le_die "Tag $release_tag is $remote_commit, metadata says $commit."
test "$(le_resolve_commit "refs/tags/$release_tag")" = "$commit" || le_die "Local tag $release_tag does not match $commit."
le_require_gate release "$commit" ".tag == \"$release_tag\" and .repository == \"$repository\""
le_require_artifact release "$commit" NotarySubmission.json "$metadata"

le_begin finalize-release "$commit" ${original_args[@]+"${original_args[@]}"}
le_set_string tag "$release_tag"
le_set_string repository "$repository"
di_resolve_credentials
test "$team" = "$APPLE_TEAM_ID" || le_die "Release team $team does not match APPLE_TEAM_ID."

check_notary() {
  local id status all_accepted=true
  for id in $(jq -r '.dmg.submissionID,.cli.submissionID' "$metadata"); do
    status=$(di_notary_status "$id")
    echo "$release_tag $id: $status"
    case "$status" in
      Accepted) ;;
      Invalid|Rejected)
        xcrun notarytool log "$id" "${DI_NOTARY_ARGS[@]}" "$work/notary-$id.json" || true
        gh release upload "$release_tag" "$work/notary-$id.json" --repo "$repository" --clobber || true
        echo "Apple rejected $release_tag submission $id; the draft remains unpublished." >&2
        return 1 ;;
      *) all_accepted=false ;;
    esac
  done
  if $all_accepted; then echo accepted > "$work/notary-state"; else echo pending > "$work/notary-state"; fi
}

deadline=$(( $(date +%s) + wait_minutes * 60 ))
while true; do
  le_step notary-status check_notary
  test "$(cat "$work/notary-state")" = accepted && break
  if [ "$(date +%s)" -ge "$deadline" ]; then
    le_set_string notary pending
    LE_STATUS=pending
    le_write_record pending 4
    le_release_lock
    echo "$release_tag remains in progress at Apple; no bytes were resubmitted. Rerun later." >&2
    exit 4
  fi
  sleep 60
done
le_set_string notary accepted

dmg_asset=$(jq -r '.dmg.asset' "$metadata")
cli_asset=$(jq -r '.cli.asset' "$metadata")
dmg="$work/$dmg_asset"
cli="$work/$cli_asset"
sdk="$work/ksamint-agent-sdk-$version.tgz"
modules="$work/ksamint-resource-modules-$version.zip"

download_assets() {
  gh release download "$release_tag" --repo "$repository" --dir "$work" \
    --pattern "$dmg_asset" --pattern "$cli_asset" \
    --pattern 'ksamint-agent-sdk-*.tgz' --pattern 'ksamint-resource-modules-*.zip' \
    --pattern ReleaseInfo.json
  test -f "$dmg" && test -f "$cli" && test -f "$sdk" && test -f "$modules"
}

verify_submitted_bytes() {
  ( le_require_artifact release "$commit" dmg "$dmg" )
  ( le_require_artifact release "$commit" cli "$cli" )
  ( le_require_artifact release "$commit" agent-sdk "$sdk" )
  ( le_require_artifact release "$commit" resource-modules "$modules" )
  test "$(jq -r .commit "$work/ReleaseInfo.json")" = "$commit"
  test "$(jq -r .arch "$work/ReleaseInfo.json")" = arm64
}

staple_and_verify() {
  local app cli_dir cli_binary size
  xcrun stapler staple "$dmg"
  xcrun stapler validate "$dmg"
  mkdir -p "$mount"
  hdiutil attach "$dmg" -nobrowse -readonly -mountpoint "$mount"
  app="$mount/kmd.app"
  (cd "$source_dir" && Scripts/verify-release-app.sh "$app" "$team" "$commit")
  spctl --assess --type execute -vv "$app"
  hdiutil detach "$mount"
  rmdir "$mount"

  cli_dir="$work/cli"
  mkdir -p "$cli_dir"
  ditto -x -k "$cli" "$cli_dir"
  cli_binary="$cli_dir/ksamint-vault"
  codesign --verify --strict --verbose=2 "$cli_binary"
  test "$(codesign -dvv "$cli_binary" 2>&1 | sed -n 's/^TeamIdentifier=//p')" = "$team"
  lipo -archs "$cli_binary" | grep -qw arm64
  if lipo -archs "$cli_binary" | grep -qw x86_64; then exit 1; fi

  size="$(stat -f '%z' "$dmg")"
  echo "Stapled UDBZ size: $size bytes (limit: 6291456)"
  test "$size" -le 6291456
  (cd "$work" && shasum -a 256 \
    "$(basename "$dmg")" "$(basename "$cli")" "$(basename "$sdk")" "$(basename "$modules")" \
    > SHA256SUMS)
}

publish_release() {
  local release_id pre_id
  gh release upload "$release_tag" "$dmg" "$work/SHA256SUMS" --repo "$repository" --clobber
  # The releases/tags REST endpoint hides drafts; resolve the draft ID from the
  # collection without changing or resubmitting any bytes.
  release_id="$(gh api --paginate "repos/$repository/releases?per_page=100" \
    --jq ".[] | select(.draft and .tag_name == \"$release_tag\") | .id" | head -1)"
  test -n "$release_id"
  pre_id="$(gh api "repos/$repository/releases/$release_id" \
    --jq '.assets[] | select(.name=="SHA256SUMS.pre-notary") | .id')"
  if [ -n "$pre_id" ]; then
    gh api -X DELETE "repos/$repository/releases/assets/$pre_id"
  fi
  gh release edit "$release_tag" --repo "$repository" --draft=false --latest --verify-tag
}

update_homebrew_tap() {
  local sha tap cask apps
  sha="$(shasum -a 256 "$dmg" | awk '{print $1}')"
  tap="$(brew --repository)/Library/Taps/fengurt/homebrew-ksamint"
  cask="fengurt/ksamint/kmd"
  if [ -d "$tap" ]; then
    git -C "$tap" remote get-url --push origin | grep -Eq 'github\.com[:/]fengurt/homebrew-ksamint(\.git)?$'
    test -z "$(git -C "$tap" status --porcelain)"
    git -C "$tap" pull --ff-only
  else
    git clone git@github.com:fengurt/homebrew-ksamint.git "$tap"
  fi
  mkdir -p "$tap/Casks"
  ruby "$source_dir/Scripts/render-cask.rb" "$version" "$sha" > "$tap/Casks/kmd.rb"
  rm -f "$tap/Casks/ksamint-markedit.rb"
  printf '%s\n' \
    '{' \
    '  "ksamint-markedit": "kmd"' \
    '}' > "$tap/cask_renames.json"
  brew style --cask "$cask"
  brew audit --strict --cask "$cask"
  if brew list --cask kmd >/dev/null 2>&1; then
    echo "kmd cask is installed here; verifying download and checksum instead of reinstalling."
    brew fetch --cask --force "$cask"
  else
    apps="$temporary/cask-apps"
    brew install --cask --appdir="$apps" "$cask"
    test -d "$apps/kmd.app"
    brew uninstall --cask "$cask"
  fi
  git -C "$tap" add Casks/kmd.rb cask_renames.json
  git -C "$tap" rm --ignore-unmatch Casks/ksamint-markedit.rb
  git -C "$tap" commit -m "kmd: renamed from ksamint-markedit ($version)"
  git -C "$tap" push
}

le_step checkout le_checkout_exact "$commit" "$source_dir"
le_step download-assets download_assets
le_step verify-submitted-bytes verify_submitted_bytes
le_step staple-and-verify staple_and_verify
le_artifact stapled-dmg "$dmg"
le_artifact SHA256SUMS "$work/SHA256SUMS"
le_step publish-release publish_release
le_step homebrew-tap update_homebrew_tap
le_pass
echo "Published $release_tag ($commit) and updated the Homebrew tap."
