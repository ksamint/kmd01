#!/bin/sh
set -eu

# These lifecycle tests may only launch/quit apps in a disposable hosted account.
test "${GITHUB_ACTIONS:-}" = true
test "${CI_ISOLATED_RUNNER:-}" = github-hosted
smoke_script="$(cd "$(dirname "$0")" && pwd)/ci-document-smoke.js"

app=${1:?"usage: test-document-open-smoke.sh /path/to/kmd.app"}
executable="$app/Contents/MacOS/kmd"
test -d "$app"
if [ ! -x "$executable" ]; then
  executable_name=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Contents/Info.plist")
  executable="$app/Contents/MacOS/$executable_name"
fi
test -x "$executable"
process_name=$(basename "$executable")
helper_plist="$app/Contents/Library/LoginItems/ConversationCaptureHelper.app/Contents/Info.plist"
helper_name=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$helper_plist")
# Names become find patterns; reject metacharacters instead of widening the scan.
case "$process_name:$helper_name" in
  *[!a-zA-Z0-9_.:-]*|:*|*:) echo 'Invalid application executable names' >&2; exit 1 ;;
esac
if pgrep -x "$process_name" >/dev/null 2>&1; then
  echo "$process_name is already running; refusing an ambiguous lifecycle smoke test" >&2
  exit 2
fi

temporary=$(mktemp -d)
fixture="$temporary/document-open-smoke.md"
printf '# Dedicated open fixture\n' > "$fixture"
app_pid=""

# Diagnostics have their own short bounds and never inspect another app's
# documents or change privacy settings. Only disposable hosted fixtures exist.
diagnostic_command() {
  "$@" &
  diagnostic_pid=$!
  diagnostic_attempt=0
  while kill -0 "$diagnostic_pid" >/dev/null 2>&1 && [ "$diagnostic_attempt" -lt 20 ]; do
    diagnostic_attempt=$((diagnostic_attempt + 1))
    sleep 0.25
  done
  if kill -0 "$diagnostic_pid" >/dev/null 2>&1; then
    kill -TERM "$diagnostic_pid" >/dev/null 2>&1 || true
    sleep 0.25
    kill -KILL "$diagnostic_pid" >/dev/null 2>&1 || true
  fi
  wait "$diagnostic_pid" 2>/dev/null || true
}

capture_failure() {
  [ ! -f "$temporary/diagnostics-captured" ] || return 0
  touch "$temporary/diagnostics-captured"
  echo "Smoke failure stage=$1 app_pid=${app_pid:-none} osascript_pid=$2" >&2
  if [ -f "$fixture" ]; then
    stat -f 'Dedicated fixture bytes=%z mode=%Lp' "$fixture" >&2
    shasum -a 256 "$fixture" >&2
  fi
  if [ -n "$app_pid" ]; then
    ps -p "$app_pid,$2" -o pid,ppid,stat,etime,comm >&2 || true
    diagnostic_command osascript -l JavaScript "$smoke_script" pid "$app" > "$temporary/diagnostic-pid.log" 2>&1
    if [ "$(cat "$temporary/diagnostic-pid.log")" = "$app_pid" ]; then
      if [ -n "${CI_SMOKE_EVIDENCE_DIR:-}" ] && [ -d "$CI_SMOKE_EVIDENCE_DIR" ]; then
        diagnostic_command osascript -l JavaScript "$smoke_script" diagnostic-window-ids "$app" "$app_pid" \
          > "$temporary/window-ids" 2>"$CI_SMOKE_EVIDENCE_DIR/window-capture.log"
        while IFS= read -r window_id; do
          case "$window_id" in ''|*[!0-9]*) continue ;; esac
          diagnostic_command screencapture -x -o -l "$window_id" \
            "$CI_SMOKE_EVIDENCE_DIR/window-$app_pid-$window_id.png" \
            >>"$CI_SMOKE_EVIDENCE_DIR/window-capture.log" 2>&1
        done < "$temporary/window-ids"
      fi
      diagnostic_command sample "$app_pid" 2 10 -file "$temporary/app-sample.log" >/dev/null 2>&1
    fi
  fi
  if kill -0 "$2" >/dev/null 2>&1; then
    diagnostic_command sample "$2" 2 10 -file "$temporary/osascript-sample.log" >/dev/null 2>&1
  fi
  diagnostic_command /usr/bin/log show --last 2m --style compact --info \
    --predicate "processIdentifier == ${app_pid:-0} AND processImagePath == '$executable'" \
    > "$temporary/automation.log" 2>&1
  # Only sample renderer PIDs reported unresponsive by this exact app process.
  sed -n 's/.*\[PID=\([0-9][0-9]*\)\] WebProcessProxy::didBecomeUnresponsive:.*/\1/p' \
    "$temporary/automation.log" | sort -u | head -4 | while IFS= read -r renderer_pid; do
      renderer_command=$(ps -p "$renderer_pid" -o comm= 2>/dev/null || true)
      echo "Owned unresponsive renderer pid=$renderer_pid executable=$renderer_command" >&2
      case "$renderer_command" in
        */com.apple.WebKit.WebContent)
          diagnostic_command sample "$renderer_pid" 2 10 \
            -file "$temporary/webcontent-$renderer_pid.log" \
            >"$temporary/webcontent-$renderer_pid-command.log" 2>&1 ;;
      esac
    done
  for diagnostic in "$temporary/app-sample.log" "$temporary/osascript-sample.log" \
    "$temporary/automation.log" "$temporary"/webcontent-*.log; do
    [ -f "$diagnostic" ] || continue
    echo "Diagnostic: $(basename "$diagnostic")" >&2
    cat "$diagnostic" >&2
  done
}

# Bound every automation request, including identity queries and graceful quit.
# Only this invocation's osascript child is terminated on timeout, never the app.
jxa() {
  osascript -l JavaScript "$smoke_script" "$@" &
  script_pid=$!
  attempt=0
  while kill -0 "$script_pid" >/dev/null 2>&1 && [ "$attempt" -lt 40 ]; do
    attempt=$((attempt + 1))
    sleep 0.25
  done
  if kill -0 "$script_pid" >/dev/null 2>&1; then
    capture_failure "$1-timeout" "$script_pid"
    kill -TERM "$script_pid" >/dev/null 2>&1 || true
    sleep 0.25
    kill -KILL "$script_pid" >/dev/null 2>&1 || true
    wait "$script_pid" 2>/dev/null || true
    echo "Timed out during $1; check application responsiveness and Automation permission" >&2
    return 1
  fi
  if wait "$script_pid"; then return 0; fi
  # Restoration may legitimately need to wait for its window; diagnose only
  # after that existing bounded retry expires.
  if [ "$1" != restored ]; then capture_failure "$1-error" "$script_pid"; fi
  return 1
}

wait_for_exit() {
  exit_deadline=$(($(date +%s) + 20))
  while :; do
    current_pid=$(jxa pid "$app") || return 1
    if [ -z "$current_pid" ]; then
      app_pid=""
      return
    fi
    if [ "$current_pid" != "$app_pid" ]; then
      echo "Test process identity changed while waiting for graceful exit" >&2
      return 1
    fi
    if [ "$(date +%s)" -ge "$exit_deadline" ]; then
      echo "$process_name did not quit gracefully (pid=$app_pid)" >&2
      return 1
    fi
    sleep 0.25
  done
}

cleanup() {
  result=$?
  trap - EXIT INT TERM
  if [ -n "$app_pid" ]; then
    if ! jxa quit "$app" "$app_pid" || ! wait_for_exit; then
      echo "Could not gracefully stop the test app; preserving fixture at $fixture" >&2
      exit 1
    fi
  fi
  rm -f "$fixture" "$temporary/saved.md" "$temporary/restoration-error.log"
  rm -f "$temporary/diagnostics-captured" "$temporary/diagnostic-pid.log" \
    "$temporary/app-sample.log" "$temporary/osascript-sample.log" "$temporary/automation.log" "$temporary/window-ids"
  rm -f "$temporary"/webcontent-*.log
  rmdir "$temporary" 2>/dev/null || true
  exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

diagnostic_directory="$HOME/Library/Logs/DiagnosticReports"
report_count() {
  if [ -d "$diagnostic_directory" ]; then
    find "$diagnostic_directory" -maxdepth 1 -type f \
      \( -name "$process_name-*.ips" -o -name "$helper_name-*.ips" \) | wc -l | tr -d ' '
  else
    echo 0
  fi
}
before_reports=$(report_count)
check_crashes() {
  if ! kill -0 "$app_pid" >/dev/null 2>&1 || [ "$(report_count)" -gt "$before_reports" ]; then
    echo "$process_name exited unexpectedly, or $process_name/$helper_name generated a crash report" >&2
    latest_report=$(find "$diagnostic_directory" -maxdepth 1 -type f \
      \( -name "$process_name-*.ips" -o -name "$helper_name-*.ips" \) -print 2>/dev/null | sort | tail -1)
    if [ -n "$latest_report" ]; then
      echo "Latest crash report: $latest_report" >&2
      sed -n '1,180p' "$latest_report" >&2
    fi
    return 1
  fi
}

launch() {
  # Argument-domain defaults apply to this test process only. Do not persist
  # preferences, and never pass the fixture on a restoration launch.
  open -n -a "$app" --args -NSQuitAlwaysKeepsWindows YES
  launch_deadline=$(($(date +%s) + 20))
  while :; do
    app_pid=$(jxa pid "$app")
    [ -n "$app_pid" ] && return
    if [ "$(date +%s)" -ge "$launch_deadline" ]; then
      echo "$process_name did not launch" >&2
      return 1
    fi
    sleep 0.25
  done
}

verify_restoration() {
  restore_deadline=$(($(date +%s) + 30))
  while ! jxa restored "$app" "$app_pid" "$fixture" 2>"$temporary/restoration-error.log"; do
    check_crashes || return 1
    if [ "$(date +%s)" -ge "$restore_deadline" ]; then
      cat "$temporary/restoration-error.log" >&2
      capture_failure restoration-timeout "$script_pid"
      echo "Timed out waiting for the exact saved fixture to restore" >&2
      return 1
    fi
    sleep 0.25
  done
  cmp "$temporary/saved.md" "$fixture"
  check_crashes
}

saved_payload_matches() {
  # Accept only the complete payload, with at most one terminal LF.
  # A matching line within additional text is not a successful save.
  printf '%s' "$payload" | cmp -s - "$fixture" ||
    printf '%s\n' "$payload" | cmp -s - "$fixture"
}

launch
# Opening a second document exercises the NSDocument read path that previously
# violated EditorDocument's actor isolation. Writing also exercises its save path.
sleep 1
jxa open "$app" "$app_pid" "$fixture"
# Initial WebKit accessibility loading is asynchronous, just like restoration.
# Verify the original text before issuing any edit; never retry a partial save.
cp "$fixture" "$temporary/saved.md"
verify_restoration
# Each launch after this point must use AppKit's saved window/document state.
# No open event is sent, so a normal-open success cannot hide a restore failure.
# Temporary diagnostic only: 90 cycles; integration acceptance stays at 30.
iteration=1
while [ "$iteration" -le 90 ]; do
  payload="# Save smoke test: lifecycle $iteration/90"
  jxa save "$app" "$app_pid" "$fixture" "$payload"
  # Saving may normalize the final newline. Preserve the resulting bytes and
  # require this cycle's distinct payload before using them as the restore oracle.
  save_deadline=$(($(date +%s) + 20))
  while ! saved_payload_matches; do
    check_crashes
    if [ "$(date +%s)" -ge "$save_deadline" ]; then
      echo "Timed out waiting for lifecycle $iteration to save its new content" >&2
      exit 1
    fi
    sleep 0.25
  done
  cp "$fixture" "$temporary/saved.md"
  verify_restoration
  previous_pid=$app_pid
  jxa quit "$app" "$app_pid"
  wait_for_exit
  launch
  if [ "$app_pid" = "$previous_pid" ]; then
    echo "Relaunch reused the previous process instead of restoring a new session" >&2
    exit 1
  fi
  verify_restoration
  echo "Document modify/save/quit/restore lifecycle $iteration/90 passed (pid=$app_pid)"
  iteration=$((iteration + 1))
done

echo 'Document open/save and 90 graceful quit/relaunch restoration cycles passed'
