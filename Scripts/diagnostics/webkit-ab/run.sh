#!/bin/bash
set -euo pipefail
export LC_ALL=C
test "${GITHUB_ACTIONS:-}" = true
test "${CI_ISOLATED_RUNNER:-}" = github-hosted
variant=${1:?usage: run.sh public-default evidence-directory [cycles]}
evidence=${2:?missing evidence directory}
cycles=${3:-90}
case "$variant" in public-default) ;; *) echo "Unknown variant" >&2; exit 2 ;; esac
case "$cycles" in ''|*[!0-9]*) exit 2 ;; esac
if ((cycles < 1 || cycles > 90)); then echo "Cycles must be 1..90" >&2; exit 2; fi
source_dir=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$evidence"
evidence=$(cd "$evidence" && pwd)
mkdir "$evidence/source"
cp "$source_dir/Harness.swift" "$source_dir/run.sh" "$source_dir/watchdog.py" "$source_dir/test_watchdog.py" "$source_dir/README.md" "$evidence/source/"
shasum -a 256 "$evidence/source/"* > "$evidence/source.sha256"
printf '%s\n' "$variant" > "$evidence/variant.txt"
sw_vers > "$evidence/os.txt"
uname -m > "$evidence/architecture.txt"
xcrun swiftc --version > "$evidence/compiler.txt"
python3 "$source_dir/test_watchdog.py" > "$evidence/watchdog-selfcheck.txt"
app="$evidence/WebKitAB.app"
mkdir -p "$app/Contents/MacOS"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.ksamint.diagnostics.webkitstartupab</string>
<key>CFBundleExecutable</key><string>WebKitAB</string>
<key>CFBundleName</key><string>WebKitAB</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
cat > "$evidence/entitlements.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>com.apple.security.app-sandbox</key><true/>
<key>com.apple.security.network.client</key><true/>
</dict></plist>
PLIST
flags=(-swift-version 6)
xcrun swiftc -parse-as-library -O -g \
  -target "$(uname -m)-apple-macosx15.0" \
  -framework AppKit -framework WebKit "${flags[@]}" \
  "$source_dir/Harness.swift" \
  -o "$app/Contents/MacOS/WebKitAB" > "$evidence/build.log" 2>&1
codesign --force --sign - --entitlements "$evidence/entitlements.plist" "$app" > "$evidence/sign.log" 2>&1
codesign --verify --strict "$app" >> "$evidence/sign.log" 2>&1
shasum -a 256 "$app/Contents/MacOS/WebKitAB" > "$evidence/executable.sha256"
python3 "$source_dir/watchdog.py" "$app" "$evidence" "$variant" "$cycles"
