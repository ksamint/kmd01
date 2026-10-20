#!/bin/bash
set -euo pipefail
temporary=$(mktemp -d)
trap 'rm -rf "$temporary"' EXIT
swiftc -swift-version 6 -parse-as-library Shared/WorkspaceBookmarkAccess.swift \
  Scripts/WorkspaceBookmarkAccessTestMain.swift -o "$temporary/workspace-bookmark-tests"
"$temporary/workspace-bookmark-tests"
swiftc -swift-version 6 -typecheck Shared/WorkspaceBookmarkAccess.swift FinderExtension/FinderTools.swift
swiftc -swift-version 6 -typecheck Shared/WorkspaceBookmarkAccess.swift QuickActionExtension/QuickActionViewController.swift
