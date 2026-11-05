# shellcheck shell=bash
#
# Local build and release evidence.
#
# GitHub-hosted and self-hosted runners are retired (owner decision
# 2026-11-05). Every check, build, install, and release gate now runs on the
# developer's Mac and records what it did under the git-ignored
# `.local-evidence/<commit>/` directory:
#
#   <gate>.json               latest record for that gate and commit
#   <gate>-runs/<run>/        per-run step logs, steps.jsonl, record.json
#
# A record holds the commit and tree, every command (argv), working directory,
# start and finish timestamps, exit codes, artifact SHA-256 digests, and the
# toolchain. A gate passes only when its record says "passed" for the exact
# commit and tree; a missing, running, failed, or mismatched record blocks the
# next gate (fail closed). Records never contain credentials: scripts pass key
# IDs and keychain profile names, never passwords or key material.
#
# Sourced by Scripts/local-checks.sh, Scripts/install-*-local.sh,
# Scripts/release-local.sh, and Scripts/finalize-release-local.sh.
# Compatible with macOS /bin/bash 3.2.

le_repo_root=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
le_evidence_root="$le_repo_root/.local-evidence"

# The release gate requires a passed record for every suite in this list.
# Scripts/local-checks.sh implements each one.
KSAMINT_CHECK_SUITES="resource-modules agent-sdk agent-contracts cloud web mac compatibility"

LE_GATE=
LE_COMMIT=
LE_TREE=
LE_DIR=
LE_RUN_DIR=
LE_STEPS=
LE_ARTIFACTS=
LE_STARTED=
LE_RUN_ID=
LE_STATUS=
LE_LOCK=
LE_ARGS_JSON='[]'
LE_EXTRA_JSON='{}'
LE_STEP_INDEX=0

le_die() {
  printf '%s\n' "$*" >&2
  exit 1
}

le_now() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

le_sha256() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

le_json_array() {
  local out='[]' item
  for item in "$@"; do
    out=$(jq -c --arg v "$item" '. + [$v]' <<<"$out")
  done
  printf '%s' "$out"
}

le_require_commands() {
  local name
  for name in "$@"; do
    command -v "$name" >/dev/null 2>&1 || le_die "Required command not found: $name"
  done
}

le_require_macos() {
  test "$(uname -s)" = Darwin || le_die "This step builds the macOS app and must run on a Mac."
  test "$(uname -m)" = arm64 || le_die "kmd v2.5 builds and installs on Apple Silicon (arm64) only."
}

# Resolves a ref to a full commit SHA in the developer's clone.
le_resolve_commit() {
  git -C "$le_repo_root" rev-parse --verify --quiet "$1^{commit}" \
    || le_die "Unknown commit or ref: $1"
}

# Refuses to start from a working tree with tracked or untracked changes, so
# nobody mistakes uncommitted edits for part of the exact-SHA build.
le_require_clean_tree() {
  local status
  status=$(git -C "$le_repo_root" status --porcelain --untracked-files=normal)
  if [ -n "$status" ]; then
    printf '%s\n' "$status" >&2
    le_die "Working tree is not clean. Commit or stash these changes first; local gates build exact commits only."
  fi
}

# Creates a detached, pristine worktree at the exact commit (the local
# equivalent of actions/checkout) and verifies it.
le_checkout_exact() {
  local commit=$1 dir=$2
  git -C "$le_repo_root" worktree add --detach "$dir" "$commit"
  test "$(git -C "$dir" rev-parse HEAD)" = "$commit"
  test -z "$(git -C "$dir" status --porcelain --untracked-files=normal)"
}

le_remove_checkout() {
  local dir=$1
  if [ -n "$dir" ] && [ -d "$dir" ]; then
    git -C "$le_repo_root" worktree remove --force "$dir" >/dev/null 2>&1 || rm -rf "$dir"
  fi
  git -C "$le_repo_root" worktree prune >/dev/null 2>&1 || true
}

# Requires Node.js to satisfy the packages' engines (>=24.19 <25).
le_require_node_24() {
  local version major minor
  version=$(node -p 'process.versions.node')
  major=${version%%.*}
  minor=${version#*.}
  minor=${minor%%.*}
  if [ "$major" -ne 24 ] || [ "$minor" -lt 19 ]; then
    le_die "Node.js $version does not satisfy >=24.19 <25 (see .node-version)."
  fi
}

# Prints the toolchain; used as an evidence step so versions land in the log.
le_toolchain_report() {
  uname -a
  if command -v sw_vers >/dev/null 2>&1; then sw_vers; fi
  local tool
  for tool in "$@"; do
    case "$tool" in
      xcodebuild) xcode-select -p; xcodebuild -version ;;
      swift) swift --version ;;
      node) node --version ;;
      npm) npm --version ;;
      cargo) cargo --version; rustc --version ;;
      gh) gh --version | head -1 ;;
      docker) docker --version; docker compose version ;;
      brew) brew --version | head -1 ;;
      *) "$tool" --version ;;
    esac
  done
}

le_write_record() {
  local status=$1 exit_code=${2:-null} finished=null tmp
  if [ "$status" != running ]; then finished="\"$(le_now)\""; fi
  tmp="$LE_DIR/.$LE_GATE.json.$$"
  jq -n \
    --arg gate "$LE_GATE" \
    --arg commit "$LE_COMMIT" \
    --arg tree "$LE_TREE" \
    --arg status "$status" \
    --arg started "$LE_STARTED" \
    --argjson finished "$finished" \
    --argjson exitCode "$exit_code" \
    --arg runId "$LE_RUN_ID" \
    --arg host "$(hostname -s 2>/dev/null || hostname)" \
    --arg os "$(uname -sr)" \
    --arg osVersion "$(sw_vers -productVersion 2>/dev/null || true)" \
    --arg script "${0#"$le_repo_root"/}" \
    --arg scriptCommit "$(git -C "$le_repo_root" rev-parse HEAD)" \
    --argjson arguments "$LE_ARGS_JSON" \
    --argjson extra "$LE_EXTRA_JSON" \
    --slurpfile steps "$LE_STEPS" \
    --slurpfile artifacts "$LE_ARTIFACTS" \
    '{schema: 1, gate: $gate, commit: $commit, tree: $tree, status: $status,
      startedAt: $started, finishedAt: $finished, exitCode: $exitCode,
      runId: $runId, host: $host, os: $os, osVersion: $osVersion,
      script: $script, scriptCommit: $scriptCommit, arguments: $arguments,
      steps: $steps, artifacts: $artifacts} + $extra' > "$tmp"
  cp "$tmp" "$LE_RUN_DIR/record.json"
  mv -f "$tmp" "$LE_DIR/$LE_GATE.json"
}

# le_begin GATE COMMIT [ARG...] starts a gate record for an exact commit.
le_begin() {
  le_require_commands jq git
  LE_GATE=$1
  LE_COMMIT=$2
  shift 2
  case "$LE_COMMIT" in
    *[!0-9a-f]*|'') le_die "Evidence needs a full commit SHA, got: $LE_COMMIT" ;;
  esac
  test "${#LE_COMMIT}" -eq 40 || le_die "Evidence needs a full commit SHA, got: $LE_COMMIT"
  LE_TREE=$(git -C "$le_repo_root" rev-parse "$LE_COMMIT^{tree}")
  LE_STARTED=$(le_now)
  LE_RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
  LE_DIR="$le_evidence_root/$LE_COMMIT"
  LE_RUN_DIR="$LE_DIR/$LE_GATE-runs/$LE_RUN_ID"
  LE_STEPS="$LE_RUN_DIR/steps.jsonl"
  LE_ARTIFACTS="$LE_RUN_DIR/artifacts.jsonl"
  LE_STATUS=running
  LE_STEP_INDEX=0
  LE_EXTRA_JSON='{}'
  LE_ARGS_JSON=$(le_json_array "$@")
  (umask 077 && mkdir -p "$LE_RUN_DIR")
  LE_LOCK="$LE_DIR/.$LE_GATE.lock"
  if ! mkdir "$LE_LOCK" 2>/dev/null; then
    LE_LOCK=
    le_die "Another $LE_GATE run for $LE_COMMIT holds $LE_DIR/.$LE_GATE.lock; remove it if no run is active."
  fi
  : > "$LE_STEPS"
  : > "$LE_ARTIFACTS"
  le_write_record running
  printf '==> %s for %s (evidence: %s)\n' "$LE_GATE" "$LE_COMMIT" "$LE_RUN_DIR" >&2
}

# le_set KEY JSON adds a top-level field to the record (non-secret values only).
le_set() {
  LE_EXTRA_JSON=$(jq -c --arg k "$1" --argjson v "$2" '. + {($k): $v}' <<<"$LE_EXTRA_JSON")
}

le_set_string() {
  LE_EXTRA_JSON=$(jq -c --arg k "$1" --arg v "$2" '. + {($k): $v}' <<<"$LE_EXTRA_JSON")
}

# le_step NAME COMMAND [ARG...] runs one command (or shell function) in a
# subshell with errexit and xtrace, logs its output, and records the result.
# A failing step marks the gate failed and stops the script.
le_step() {
  local name=$1 log started finished code entry
  shift
  test -n "$LE_GATE" || le_die "le_step called outside a gate"
  LE_STEP_INDEX=$((LE_STEP_INDEX + 1))
  log="$LE_RUN_DIR/$(printf '%02d' "$LE_STEP_INDEX")-$name.log"
  started=$(le_now)
  printf '  -> %s\n' "$name" >&2
  set +e
  (
    set -euo pipefail
    PS4='+ '
    set -x
    "$@"
  ) > "$log" 2>&1
  code=$?
  set -e
  finished=$(le_now)
  entry=$(jq -c -n \
    --argjson index "$LE_STEP_INDEX" \
    --arg name "$name" \
    --argjson command "$(le_json_array "$@")" \
    --arg cwd "$PWD" \
    --arg started "$started" \
    --arg finished "$finished" \
    --argjson exitCode "$code" \
    --arg log "${log#"$LE_DIR"/}" \
    '{index: $index, name: $name, command: $command, cwd: $cwd,
      startedAt: $started, finishedAt: $finished, exitCode: $exitCode, log: $log}')
  printf '%s\n' "$entry" >> "$LE_STEPS"
  if [ "$code" -ne 0 ]; then
    tail -n 40 "$log" >&2
    LE_STATUS=failed
    le_write_record failed "$code"
    le_die "Step '$name' failed (exit $code). Log: $log"
  fi
  le_write_record running
}

# le_artifact LABEL PATH records the SHA-256 and size of a produced file.
le_artifact() {
  local label=$1 path=$2 digest bytes
  test -f "$path" || le_die "Artifact $label is missing: $path"
  digest=$(le_sha256 "$path")
  bytes=$(wc -c < "$path" | tr -d ' ')
  jq -c -n --arg label "$label" --arg name "$(basename "$path")" \
    --arg sha256 "$digest" --argjson bytes "$bytes" \
    '{label: $label, name: $name, sha256: $sha256, bytes: $bytes}' >> "$LE_ARTIFACTS"
  le_write_record running
}

le_release_lock() {
  if [ -n "$LE_LOCK" ]; then rmdir "$LE_LOCK" 2>/dev/null || true; fi
  LE_LOCK=
}

le_pass() {
  LE_STATUS=passed
  le_write_record passed 0
  le_release_lock
  printf '==> %s passed for %s: %s\n' "$LE_GATE" "$LE_COMMIT" "$LE_DIR/$LE_GATE.json" >&2
}

# Call from the script's EXIT trap with the exit status. Marks an unfinished
# gate failed so a crashed or interrupted run can never read as passed.
le_on_exit() {
  local code=${1:-1}
  if [ -n "$LE_GATE" ] && [ "$LE_STATUS" = running ]; then
    LE_STATUS=failed
    if [ "$code" -eq 0 ]; then code=1; fi
    le_write_record failed "$code" || true
  fi
  le_release_lock
}

le_record_path() {
  printf '%s/%s/%s.json' "$le_evidence_root" "$2" "$1"
}

# le_require_gate GATE COMMIT [JQ_CONDITION] fails unless the latest record of
# GATE for COMMIT passed, matches the commit's tree, has at least one step, and
# every step exited 0. JQ_CONDITION adds a gate-specific requirement.
le_require_gate() {
  local gate=$1 commit=$2 condition=${3:-true} record tree
  record=$(le_record_path "$gate" "$commit")
  test -f "$record" || le_die "No local '$gate' evidence for $commit ($record). Run that gate first."
  tree=$(git -C "$le_repo_root" rev-parse "$commit^{tree}")
  jq -e --arg gate "$gate" --arg commit "$commit" --arg tree "$tree" \
    ".schema == 1 and .gate == \$gate and .commit == \$commit and .tree == \$tree
     and .status == \"passed\" and .exitCode == 0 and (.steps | length) > 0
     and all(.steps[]; .exitCode == 0) and ($condition)" \
    "$record" >/dev/null \
    || le_die "Local '$gate' evidence for $commit has not passed (see $record)."
}

# le_require_checks COMMIT requires every Scripts/local-checks.sh suite.
le_require_checks() {
  local suite
  for suite in $KSAMINT_CHECK_SUITES; do
    le_require_gate "checks-$suite" "$1"
  done
}

# le_require_artifact GATE COMMIT LABEL PATH verifies a file still matches the
# digest a passed gate recorded for it.
le_require_artifact() {
  local record expected actual
  record=$(le_record_path "$1" "$2")
  expected=$(jq -r --arg label "$3" '[.artifacts[] | select(.label == $label) | .sha256] | last // empty' "$record")
  test -n "$expected" || le_die "Gate '$1' recorded no '$3' artifact for $2."
  actual=$(le_sha256 "$4")
  test "$actual" = "$expected" || le_die "Artifact '$3' digest $actual does not match recorded $expected."
}
