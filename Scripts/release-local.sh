#!/bin/bash
#
# Builds, signs, and submits a kmd release on this Mac, then creates the draft
# GitHub release. Replaces the retired release.yml ("Signed release") workflow;
# Scripts/finalize-release-local.sh replaces finalize-release.yml.
#
# Gates (fail closed, all for the exact commit the remote tag names):
#   * the tag exists on --repo and locally, at the same commit;
#   * every Scripts/local-checks.sh suite passed for that commit;
#   * versions in Build.xcconfig, WebApp, AgentSDK, and Cloud match the tag.
# Evidence: .local-evidence/<commit>/release.json, with the signed bytes and
# Apple's submission IDs kept under release-runs/<run>/out/.
# Signing credentials: see Scripts/lib/developer-id.sh. GitHub access uses
# your own `gh auth login` session.
#
# Usage: Scripts/release-local.sh --tag vX.Y.Z [--repo OWNER/REPO]
set -euo pipefail

release_tag=
repository=fengurt/ksa-MarkEdit
original_args=("$@")
while [ "$#" -gt 0 ]; do
  case "$1" in
    --tag) release_tag=${2:?--tag needs a value}; shift 2 ;;
    --repo) repository=${2:?--repo needs a value}; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done
case "$release_tag" in
  v[0-9]*.[0-9]*.[0-9]*) ;;
  *) echo "--tag must look like v1.2.3" >&2; exit 2 ;;
esac
version="${release_tag#v}"

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=Scripts/lib/local-evidence.sh
. "$script_dir/lib/local-evidence.sh"
# shellcheck source=Scripts/lib/developer-id.sh
. "$script_dir/lib/developer-id.sh"

le_require_macos
le_require_commands git jq gh node npm corepack cargo rustup xcodebuild xcrun \
  codesign security plutil ruby curl ditto hdiutil lipo shasum stat
le_require_clean_tree
gh auth status >/dev/null 2>&1 || le_die "Sign in with gh auth login first."

remote_commit=$(gh api "repos/$repository/commits/$release_tag" --jq .sha)
local_commit=$(le_resolve_commit "refs/tags/$release_tag")
test "$remote_commit" = "$local_commit" \
  || le_die "Tag $release_tag is $remote_commit on $repository but $local_commit locally."
commit=$local_commit
if gh release view "$release_tag" --repo "$repository" >/dev/null 2>&1; then
  le_die "Release $release_tag already exists on $repository; refusing to build or submit new bytes."
fi
le_require_checks "$commit"

temporary=$(mktemp -d "${TMPDIR:-/tmp}/kmd-release.XXXXXX")
source_dir="$temporary/src"
cleanup() {
  local code=$?
  le_on_exit "$code"
  le_remove_checkout "$source_dir"
  rm -rf "$temporary"
  exit "$code"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

le_begin release "$commit" ${original_args[@]+"${original_args[@]}"}
le_set_string tag "$release_tag"
le_set_string repository "$repository"
# shellcheck disable=SC2086 # the suite list is space-separated on purpose
le_set checksSuites "$(le_json_array $KSAMINT_CHECK_SUITES)"
di_resolve_credentials
out="$LE_RUN_DIR/out"
work="$temporary/work"
mkdir -p "$out" "$work"
dmg="$out/ksamint-MarkEdit-$version.dmg"
cli="$out/ksamint-vault-macos-arm64.zip"
sdk="$out/ksamint-agent-sdk-$version.tgz"
modules="$out/ksamint-resource-modules-$version.zip"

assert_equal() {
  if [ "$3" != "$2" ]; then
    printf '%s mismatch: expected <%s>, got <%s>\n' "$1" "$2" "$3" >&2
    return 1
  fi
}

verify_versions() {
  cd "$source_dir"
  assert_equal Build.xcconfig "$version" "$(sed -n 's/^MARKETING_VERSION = //p' Build.xcconfig)"
  assert_equal WebApp/package.json "$version" "$(node -p "require('./WebApp/package.json').version")"
  assert_equal AgentSDK/package.json "$version" "$(node -p "require('./AgentSDK/package.json').version")"
  assert_equal Cloud/Cargo.toml "$version" "$(awk -F '"' '/^version = "/ { print $2; exit }' Cloud/Cargo.toml)"
  assert_equal release-tag "$commit" "$(git rev-parse HEAD)"
  node Scripts/validate-localizations.mjs
  node Scripts/validate-product-identity.mjs
}

rust_toolchain() {
  cd "$source_dir/Cloud"
  rustc --version | grep -F 'rustc 1.97.1'
  rustup target list --installed | grep -Fx aarch64-apple-darwin
  cargo clippy --version
  cargo fmt --version
}

build_core_editor() {
  cd "$source_dir/CoreEditor"
  corepack yarn --version
  corepack yarn install --immutable
  corepack yarn build
}

build_web() {
  cd "$source_dir/WebApp"
  npm ci
  npm run build
  npm run build:mac
  npm run validate:mac-bundle
}

pack_agent_sdk() {
  cd "$source_dir/AgentSDK"
  npm ci
  npm run build
  npm pack --pack-destination "$out"
  test -f "$sdk"
}

package_resource_modules() {
  cd "$source_dir/ResourceModules"
  npm ci
  npm run verify
  ditto -c -k --keepParent dist "$modules"
}

build_cli() {
  local binary="$work/ksamint-vault"
  cd "$source_dir/Cloud"
  cargo build --locked --release -p ksamint-vault --target aarch64-apple-darwin
  cp target/aarch64-apple-darwin/release/ksamint-vault "$binary"
  codesign --force --options runtime --timestamp --sign "$APPLE_DEVELOPER_ID_SHA1" "$binary"
  "$binary" --version
  lipo -archs "$binary" | grep -q arm64
  if lipo -archs "$binary" | grep -q x86_64; then exit 1; fi
  ditto -c -k "$binary" "$cli"
}

archive_app() {
  di_archive_and_export "$source_dir" "$work" "$commit" \
    SWIFT_OPTIMIZATION_LEVEL="-Osize" \
    COPY_PHASE_STRIP=YES \
    STRIP_INSTALLED_PRODUCT=YES \
    STRIP_STYLE=non-global \
    DEPLOYMENT_POSTPROCESSING=NO
  cd "$source_dir"
  Scripts/verify-release-app.sh "$work/export/kmd.app" "$APPLE_TEAM_ID" "$commit"
}

create_dmg() {
  local staging="$work/dmg" dmg_size
  mkdir -p "$staging"
  ditto "$work/export/kmd.app" "$staging/kmd.app"
  ln -s /Applications "$staging/Applications"
  hdiutil create -volname "kmd" -srcfolder "$staging" -ov -format UDBZ "$dmg"
  codesign --force --timestamp --sign "$APPLE_DEVELOPER_ID_SHA1" "$dmg"
  dmg_size="$(stat -f '%z' "$dmg")"
  echo "Signed UDBZ size: $dmg_size bytes (limit: 6291456)"
  test "$dmg_size" -le 6291456
}

# Each byte sequence is submitted exactly once; finalize-release-local.sh only
# reads these IDs back and never resubmits.
submit_and_describe() {
  local dmg_id cli_id
  if gh release view "$release_tag" --repo "$repository" >/dev/null 2>&1; then
    echo "Release already exists; refusing to submit or replace bytes." >&2
    return 1
  fi
  di_notary_submit "$dmg" "$work/dmg-submission.json"
  di_notary_submit "$cli" "$work/cli-submission.json"
  dmg_id="$(jq -r '.id' "$work/dmg-submission.json")"
  cli_id="$(jq -r '.id' "$work/cli-submission.json")"
  jq -n \
    --arg tag "$release_tag" --arg commit "$commit" --arg team "$APPLE_TEAM_ID" \
    --arg dmgAsset "$(basename "$dmg")" --arg dmgSubmission "$dmg_id" \
    --arg cliAsset "$(basename "$cli")" --arg cliSubmission "$cli_id" \
    '{schema:1, tag:$tag, commit:$commit, teamID:$team,
      dmg:{asset:$dmgAsset,submissionID:$dmgSubmission},
      cli:{asset:$cliAsset,submissionID:$cliSubmission}}' \
    > "$out/NotarySubmission.json"
  jq -n --arg commit "$commit" \
    '{minOSVer:"15.0",arch:"arm64",commit:$commit}' \
    > "$out/ReleaseInfo.json"
  (cd "$out" && shasum -a 256 \
    "$(basename "$dmg")" "$(basename "$cli")" "$(basename "$sdk")" "$(basename "$modules")" \
    > SHA256SUMS.pre-notary)
}

create_draft_release() {
  gh release create "$release_tag" \
    "$dmg" "$cli" "$sdk" "$modules" \
    "$out/ReleaseInfo.json" \
    "$out/NotarySubmission.json" \
    "$out/SHA256SUMS.pre-notary" \
    --repo "$repository" --title "$version" \
    --generate-notes --verify-tag --draft
}

le_step checkout le_checkout_exact "$commit" "$source_dir"
le_step toolchain le_toolchain_report xcodebuild node npm cargo gh
le_step node-version le_require_node_24
le_step rust-toolchain rust_toolchain
le_step verify-tag-and-versions verify_versions
le_step core-editor build_core_editor
le_step web-pwa build_web
le_step agent-sdk pack_agent_sdk
le_step resource-modules package_resource_modules
le_step provisioning-profiles di_install_profiles
le_step recovery-cli build_cli
le_step archive-and-export archive_app
le_step dmg create_dmg
le_artifact dmg "$dmg"
le_artifact cli "$cli"
le_artifact agent-sdk "$sdk"
le_artifact resource-modules "$modules"
le_step notary-submit submit_and_describe
le_set notarySubmissions "$(jq -c '{dmg: .dmg.submissionID, cli: .cli.submissionID}' "$out/NotarySubmission.json")"
le_artifact NotarySubmission.json "$out/NotarySubmission.json"
le_artifact ReleaseInfo.json "$out/ReleaseInfo.json"
le_artifact SHA256SUMS.pre-notary "$out/SHA256SUMS.pre-notary"
le_step draft-release create_draft_release
le_pass
echo "Draft release $release_tag created on $repository for $commit."
echo "After Apple accepts both submissions, run: Scripts/finalize-release-local.sh --tag $release_tag --wait"
