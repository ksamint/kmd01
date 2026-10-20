#!/bin/bash
set -euo pipefail
test_dir="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/clipboard-tests.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
swiftc -parse-as-library ConversationCaptureHelper/ClipboardCaptureDecoder.swift \
  Scripts/ClipboardCaptureDecoderTestMain.swift -o "$test_dir/decoder"
"$test_dir/decoder"
swiftc -parse-as-library ConversationCaptureHelper/ClipboardHistory.swift \
  Scripts/ClipboardHistoryStoreTestMain.swift -o "$test_dir/history"
"$test_dir/history"
swiftc -typecheck Shared/WorkspaceBookmarkAccess.swift ConversationCaptureHelper/ClipboardCaptureDecoder.swift \
  ConversationCaptureHelper/ClipboardHistory.swift \
  ConversationCaptureHelper/ClipboardPaletteController.swift ConversationCaptureHelper/main.swift
if grep -R -n -E 'NSAttributedString\(data:|readObjects\(forClasses:.*NSURL' ConversationCaptureHelper; then
  echo 'Clipboard helper contains an unsafe rich-text or URL importer.' >&2
  exit 1
fi
