#!/usr/bin/env python3
"""Pure mocked identity checks; no application is launched."""
import datetime
import subprocess
from unittest.mock import patch
import watchdog

started = datetime.datetime(2026, 10, 20, 13, 0, 0)
path = ("/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/"
        "com.apple.WebKit.WebContent.xpc/Contents/MacOS/com.apple.WebKit.WebContent")


def identity(stdout):
    with patch.object(watchdog.subprocess, "run",
                      return_value=subprocess.CompletedProcess([], 0, stdout, "")) as run:
        result = watchdog.renderer_identity(4123, started)
        assert run.call_args.args[0] == ["/bin/ps", "-p", "4123", "-o", "lstart=,comm="]
        return result


assert identity("Tue Oct 20 13:00:00 2026 " + path) == path
assert identity("Tue Oct 20 12:59:57 2026 " + path) == path
assert identity("Tue Oct 20 12:59:56 2026 " + path) is None
assert identity("Tue Oct 20 13:00:00 2026 /tmp/com.apple.WebKit.WebContent") is None
assert identity("Tue Oct 20 13:00:00 2026 /Applications/kmd.app/Contents/MacOS/kmd") is None
assert identity("") is None
assert identity("unparseable timestamp " + path) is None
cryptex = path.replace("/System/Library/", "/System/Volumes/Preboot/Cryptexes/OS/System/Library/", 1)
assert identity("Tue Oct 20 13:00:00 2026 " + cryptex) == cryptex
with patch.object(watchdog.subprocess, "run", side_effect=subprocess.TimeoutExpired("ps", 3)):
    try:
        watchdog.renderer_identity(4123, started)
    except subprocess.TimeoutExpired:
        pass
    else:
        raise AssertionError("ps timeout must propagate to caller's fail-closed check")
print("9 mocked renderer identity checks passed; no GUI launch")
