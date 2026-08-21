#!/bin/sh
set -eu

app=${1:?"usage: test-document-open-smoke.sh /path/to/kmd.app"}
executable="$app/Contents/MacOS/kmd"

test -d "$app"
test -x "$executable"

if pgrep -x kmd >/dev/null 2>&1; then
  echo "kmd is already running; refusing an ambiguous document-open smoke test" >&2
  exit 2
fi

temporary=$(mktemp -d)
fixture="$temporary/document-open-smoke.md"
touch "$fixture"

cleanup() {
  if [ -n "${app_pid:-}" ] && kill -0 "$app_pid" >/dev/null 2>&1; then
    kill -TERM "$app_pid" >/dev/null 2>&1 || true
  fi
  rm -f "$fixture"
  rmdir "$temporary" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

diagnostic_directory="$HOME/Library/Logs/DiagnosticReports"
before_reports=0
if [ -d "$diagnostic_directory" ]; then
  before_reports=$(find "$diagnostic_directory" -maxdepth 1 -type f -name 'kmd-*.ips' | wc -l | tr -d ' ')
fi

open -n -a "$app"

app_pid=""
attempt=0
while [ "$attempt" -lt 20 ]; do
  app_pid=$(pgrep -x kmd | head -1 || true)
  [ -n "$app_pid" ] && break
  attempt=$((attempt + 1))
  sleep 0.25
done

if [ -z "$app_pid" ]; then
  echo "kmd did not launch" >&2
  exit 1
fi

# AppKit creates an untitled document during launch on the main thread. Opening
# a second document exercises NSDocumentController's concurrent-read queue,
# which is the path that previously violated EditorDocument's actor isolation.
sleep 1
open -a "$app" "$fixture"
sleep 4

# Exercise NSDocument's write path as well as its concurrent-read path. Swift 6
# traps if EditorDocument advertises asynchronous writes while touching its
# main-actor AppKit/WebKit state.
osascript <<'APPLESCRIPT'
tell application "kmd"
  set source of front document to "# Save smoke test"
  save front document
end tell
APPLESCRIPT
sleep 2

after_reports=$before_reports
if [ -d "$diagnostic_directory" ]; then
  after_reports=$(find "$diagnostic_directory" -maxdepth 1 -type f -name 'kmd-*.ips' | wc -l | tr -d ' ')
fi

print_latest_crash() {
  latest_report=$(find "$diagnostic_directory" -maxdepth 1 -type f -name 'kmd-*.ips' -print 2>/dev/null | sort | tail -1)
  if [ -n "$latest_report" ]; then
    echo "Latest crash report: $latest_report" >&2
    sed -n '1,180p' "$latest_report" >&2
  fi
}

if ! kill -0 "$app_pid" >/dev/null 2>&1; then
  echo "kmd crashed while opening a Markdown document" >&2
  print_latest_crash
  exit 1
fi

if [ "$after_reports" -gt "$before_reports" ]; then
  echo "kmd generated a crash report while opening or saving a Markdown document" >&2
  print_latest_crash
  exit 1
fi

grep -F '# Save smoke test' "$fixture" >/dev/null

echo "Document open/save smoke test passed (pid=$app_pid)"
