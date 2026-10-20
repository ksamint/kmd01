#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/swift-stability.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
swiftc -swift-version 6 -D STABILITY_STANDALONE -parse-as-library \
  Scripts/SwiftStabilityTestMain.swift \
  MarkEditMac/Modules/Sources/SharedUI/ProcessOutput.swift \
  MarkEditMac/Modules/Sources/SharedUI/LocalAgentBridge.swift \
  MarkEditMac/Modules/Sources/SharedUI/LocalMCPUnixBridge.swift \
  -o "$test_dir/stability"
python3 - "$test_dir/stability" <<'PY'
import subprocess
import sys
subprocess.run([sys.argv[1]], check=True, timeout=45)
PY
