#!/bin/bash
set -euo pipefail
test "${GITHUB_ACTIONS:-}" = true
test "${CI_ISOLATED_RUNNER:-}" = github-hosted
test "${GITHUB_REF:-}" = refs/heads/main
[[ "${CANDIDATE_TAG:-}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]
root=$(git rev-parse --show-toplevel)
cd "$root"
test "$(git rev-parse HEAD)" = "$GITHUB_SHA"
work=$(mktemp -d "$RUNNER_TEMP/candidate-runtime.XXXXXX")
evidence="$RUNNER_TEMP/candidate-evidence"
mkdir -p "$evidence" "$work/input" "$work/mount"
mounted=false
date -u '+%Y-%m-%dT%H:%M:%SZ' > "$evidence/startedAt.txt"

finish() {
  result=$?
  trap - EXIT
  if $mounted; then hdiutil detach "$work/mount" || result=1; fi
  date -u '+%Y-%m-%dT%H:%M:%SZ' > "$evidence/completedAt.txt"
  printf '%s\n' "$result" > "$evidence/exit-code.txt"
  python3 - "$work" "$evidence" <<'PY'
import os
from pathlib import Path
import sys
work, evidence = map(Path, sys.argv[1:])
replacements = [(str(work), "<candidate-work>")]
replacements += [(os.environ[name], f"<{name.lower()}>")
                 for name in ("RUNNER_TEMP", "GITHUB_WORKSPACE", "HOME") if os.environ.get(name)]
paths = list(work.glob("*.log"))
reports = Path.home() / "Library/Logs/DiagnosticReports"
for name in ("kmd", "ConversationCaptureHelper"):
    paths += list(reports.glob(f"{name}-*.ips"))
for path in paths:
    text = path.read_text(errors="replace")
    for source, destination in replacements:
        text = text.replace(source, destination)
    (evidence / path.name).write_text(text)
PY
  exit "$result"
}
trap finish EXIT

verify_and_run() {
  sw_vers > "$evidence/macos.txt"
  uname -m > "$evidence/architecture.txt"
  test "$(sw_vers -productVersion | cut -d. -f1)" = "$CI_RUNTIME_OS"
  test "$(uname -m)" = "$CI_RUNTIME_ARCH"
  xcodebuild -version > "$evidence/xcode.txt"
  gh release view "$CANDIDATE_TAG" --repo "$GITHUB_REPOSITORY" \
    --json tagName,isDraft > "$work/input/Release.json"
  gh release download "$CANDIDATE_TAG" --repo "$GITHUB_REPOSITORY" --dir "$work/input" \
    --pattern "ksamint-MarkEdit-${CANDIDATE_TAG#v}.dmg" \
    --pattern NotarySubmission.json --pattern SHA256SUMS
  python3 Scripts/ci-candidate-provenance.py "$CANDIDATE_TAG" "$work/input" > "$evidence/candidate.json"
  test "$(jq -r .commit "$evidence/candidate.json")" = "$EXPECTED_COMMIT"
  test "$(jq -r .sha256 "$evidence/candidate.json")" = "$EXPECTED_DMG_SHA256"
  git fetch --no-tags origin "refs/tags/$CANDIDATE_TAG"
  test "$(git rev-parse 'FETCH_HEAD^{commit}')" = "$EXPECTED_COMMIT"
  printf '%s\n' "$EXPECTED_COMMIT" > "$evidence/commit.txt"
  printf '%s  %s\n' "$EXPECTED_DMG_SHA256" \
    "ksamint-MarkEdit-${CANDIDATE_TAG#v}.dmg" > "$evidence/original-DMG-SHA256SUMS"
  dmg="$work/input/ksamint-MarkEdit-${CANDIDATE_TAG#v}.dmg"
  team=$(jq -r .teamID "$evidence/candidate.json")
  codesign --verify --strict --verbose=2 "$dmg"
  test "$(codesign -dvv "$dmg" 2>&1 | sed -n 's/^TeamIdentifier=//p')" = "$team"
  xcrun stapler validate "$dmg"
  spctl --assess --type open --context context:primary-signature -vv "$dmg"
  hdiutil attach "$dmg" -nobrowse -readonly -mountpoint "$work/mount"
  mounted=true
  Scripts/verify-release-app.sh "$work/mount/kmd.app" "$team" "$EXPECTED_COMMIT" universal
  spctl --assess --type execute -vv "$work/mount/kmd.app"
  ditto "$work/mount/kmd.app" "$work/kmd.app"
  hdiutil detach "$work/mount"
  mounted=false
  codesign --verify --deep --strict "$work/kmd.app"
  spctl --assess --type execute -vv "$work/kmd.app"
  # Run protected-main test code against the copied signed app; no repacking,
  # re-signing, staple mutation, installation, or candidate-source execution.
  CI_SMOKE_EVIDENCE_DIR="$evidence" \
    Scripts/test-document-open-smoke.sh "$work/kmd.app" > "$work/runtime.log" 2>&1
  test "$(shasum -a 256 "$dmg" | awk '{print $1}')" = "$EXPECTED_DMG_SHA256"
}
verify_and_run > "$work/verification.log" 2>&1
