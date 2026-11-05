#!/bin/bash
#
# Runs the repository checks on this machine for an exact commit and records
# one evidence gate per suite (checks-<suite>) under .local-evidence/<commit>/.
#
# Replaces the retired build-and-test.yml workflow: each suite runs the same
# commands that workflow's job ran, in its own pristine worktree of the commit
# (like a fresh CI checkout). Scripts/release-local.sh refuses to release a
# commit unless every suite in KSAMINT_CHECK_SUITES passed for it.
#
# Suites: resource-modules agent-sdk agent-contracts cloud web mac compatibility
#   The mac and compatibility suites need macOS with Xcode; the others also
#   run on Linux. The cloud suite needs Docker (compose wiring check) and
#   cargo-audit 0.22.2 (`cargo install cargo-audit --locked --version 0.22.2`).
#
# Usage: Scripts/local-checks.sh [--ref REF] [--suite NAME[,NAME...]]
set -euo pipefail

requested_ref=HEAD
suites=
original_args=("$@")
while [ "$#" -gt 0 ]; do
  case "$1" in
    --ref) requested_ref=${2:?--ref needs a value}; shift 2 ;;
    --suite) suites="$suites ${2:?--suite needs a value}"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=Scripts/lib/local-evidence.sh
. "$script_dir/lib/local-evidence.sh"

suites=$(printf '%s' "${suites:-$KSAMINT_CHECK_SUITES}" | tr ',' ' ')
for suite in $suites; do
  case " $KSAMINT_CHECK_SUITES " in
    *" $suite "*) ;;
    *) echo "Unknown suite: $suite (known: $KSAMINT_CHECK_SUITES)" >&2; exit 2 ;;
  esac
done

le_require_commands git jq node
le_require_clean_tree
commit=$(le_resolve_commit "$requested_ref")

temporary=$(mktemp -d "${TMPDIR:-/tmp}/kmd-local-checks.XXXXXX")
source_dir=
cleanup() {
  local code=$?
  le_on_exit "$code"
  le_remove_checkout "$source_dir"
  rm -rf "$temporary"
  exit "$code"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

core_editor_install() {
  cd "$source_dir/CoreEditor"
  corepack yarn --version
  corepack yarn install --immutable
}

core_editor_build() {
  cd "$source_dir/CoreEditor"
  corepack yarn build
}

in_dir() {
  local dir=$1
  shift
  cd "$source_dir/$dir"
  "$@"
}

agent_cli_install() {
  npm install --prefix "$temporary/agent-clis" --no-package-lock --no-save \
    @openai/codex@0.142.5 @anthropic-ai/claude-code@2.1.173
}

codex_contract() {
  local codex="$temporary/agent-clis/node_modules/.bin/codex"
  "$codex" --version | grep -F '0.142.5'
  "$codex" app-server --help | grep -F -- '--config'
  "$codex" app-server --help | grep -F -- '--stdio'
}

claude_contract() {
  local claude="$temporary/agent-clis/node_modules/.bin/claude"
  "$claude" --version | grep -F '2.1.173'
  "$claude" --help | grep -F -- '--input-format'
  "$claude" --help | grep -F -- '--output-format'
  "$claude" --help | grep -F -- '--permission-mode'
  "$claude" --help | grep -F -- '--mcp-config'
}

cargo_audit() {
  cargo audit --version | grep -F '0.22.2' || {
    echo 'Install cargo-audit 0.22.2: cargo install cargo-audit --locked --version 0.22.2' >&2
    return 1
  }
  "$source_dir/Cloud/audit.sh"
}

# Placeholder values only: proves the compose file wires each variable through.
tencent_compose_wiring() {
  local rendered="$temporary/ksamint-compose.yml"
  cd "$source_dir/Cloud"
  POSTGRES_PASSWORD=ci-postgres-password \
  TENCENT_SECRET_ID=ci-secret-id \
  TENCENT_SECRET_KEY=ci-secret-key \
  TENCENT_STS_ROLE_ARN=qcs::cam::uin/100022600923:roleName/KsamintVaultStsRole \
  TENCENT_COS_BUCKET=ksamint-vault-1308586823 \
  TENCENT_COS_REGION=ap-singapore \
  TENCENT_APP_ID=1308586823 \
    docker compose -f docker-compose.tencent.yml config > "$rendered"
  grep -F 'TENCENT_SECRET_ID: ci-secret-id' "$rendered"
  grep -F 'TENCENT_SECRET_KEY: ci-secret-key' "$rendered"
  grep -F 'TENCENT_STS_ROLE_ARN: qcs::cam::uin/100022600923:roleName/KsamintVaultStsRole' "$rendered"
  grep -F 'TENCENT_COS_BUCKET: ksamint-vault-1308586823' "$rendered"
  grep -F 'TENCENT_APP_ID: "1308586823"' "$rendered"
}

xcode_unsigned() {
  cd "$source_dir"
  xcodebuild "$@" \
    -project MarkEdit.xcodeproj \
    -derivedDataPath "$temporary/DerivedData-$suite" \
    CODE_SIGN_IDENTITY="" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO
}

run_suite() {
  case "$suite" in
    resource-modules)
      le_step npm-ci in_dir ResourceModules npm ci
      le_step npm-audit in_dir ResourceModules npm audit --audit-level=high
      le_step verify in_dir ResourceModules npm run verify
      ;;
    agent-sdk)
      le_step npm-ci in_dir AgentSDK npm ci
      le_step npm-audit in_dir AgentSDK npm audit --audit-level=high
      le_step lint in_dir AgentSDK npm run lint
      le_step test in_dir AgentSDK npm test
      le_step build in_dir AgentSDK npm run build
      ;;
    agent-contracts)
      le_step install-cli-fixtures agent_cli_install
      le_step codex-app-server-contract codex_contract
      le_step claude-stream-json-contract claude_contract
      ;;
    cloud)
      le_step toolchain-cargo in_dir Cloud le_toolchain_report cargo docker
      le_step cargo-fmt in_dir Cloud cargo fmt --all -- --check
      le_step cargo-clippy in_dir Cloud cargo clippy --workspace --all-targets -- -D warnings
      le_step cargo-test in_dir Cloud cargo test --workspace
      le_step cargo-audit in_dir Cloud cargo_audit
      le_step tencent-compose-wiring tencent_compose_wiring
      ;;
    web)
      le_step core-editor-install core_editor_install
      le_step core-editor-audit in_dir CoreEditor corepack yarn npm audit --severity high --all
      le_step core-editor-build core_editor_build
      le_step core-editor-test in_dir CoreEditor corepack yarn test
      le_step webapp-npm-ci in_dir WebApp npm ci
      le_step webapp-npm-audit in_dir WebApp npm audit --audit-level=high
      le_step webapp-lint in_dir WebApp npm run lint
      le_step webapp-test in_dir WebApp npm test
      le_step webapp-build in_dir WebApp npm run build
      le_step webapp-build-mac in_dir WebApp npm run build:mac
      le_step webapp-validate-mac-bundle in_dir WebApp npm run validate:mac-bundle
      ;;
    mac)
      le_step toolchain-xcode le_toolchain_report xcodebuild swift
      le_step validate-localizations node "$source_dir/Scripts/validate-localizations.mjs"
      le_step validate-product-identity node "$source_dir/Scripts/validate-product-identity.mjs"
      le_step core-editor-install core_editor_install
      le_step core-editor-build core_editor_build
      le_step xcodebuild-build xcode_unsigned build -scheme MarkEditMac -destination 'platform=macOS'
      le_step swift-test-markeditkit swift test --package-path "$source_dir/MarkEditKit"
      le_step xcodebuild-test-core xcode_unsigned test -scheme MarkEditCoreTests -destination 'platform=macOS'
      le_step xcodebuild-test-modules xcode_unsigned test -scheme ModulesTests -destination 'platform=macOS'
      ;;
    compatibility)
      le_step toolchain-xcode le_toolchain_report xcodebuild
      le_step core-editor-install core_editor_install
      le_step core-editor-build core_editor_build
      le_step xcodebuild-release-macos15 xcode_unsigned build -scheme MarkEditMac \
        -configuration Release -destination 'platform=macOS' MACOSX_DEPLOYMENT_TARGET=15.0
      ;;
  esac
}

for suite in $suites; do
  case "$suite" in
    mac|compatibility) le_require_macos; le_require_commands xcodebuild swift corepack ;;
    web) le_require_commands corepack npm ;;
    cloud) le_require_commands cargo docker ;;
    *) le_require_commands npm ;;
  esac
  source_dir="$temporary/src-$suite"
  le_begin "checks-$suite" "$commit" ${original_args[@]+"${original_args[@]}"}
  le_step checkout le_checkout_exact "$commit" "$source_dir"
  le_step toolchain le_toolchain_report node npm
  le_step node-version le_require_node_24
  run_suite
  le_pass
  le_remove_checkout "$source_dir"
  source_dir=
done

echo "Local checks passed for $commit: $suites"
missing=
for suite in $KSAMINT_CHECK_SUITES; do
  (le_require_gate "checks-$suite" "$commit") >/dev/null 2>&1 || missing="$missing $suite"
done
if [ -n "$missing" ]; then
  echo "Release gate still needs passed suites for this commit:$missing"
else
  echo "Every release check suite has passed for $commit."
fi
