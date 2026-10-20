#!/usr/bin/env python3
"""Hosted-only supervisor; never launches or signals the production application."""
import datetime
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time


def command(args, destination, timeout=8):
    """Each diagnostic has a deadline; timeout only kills its own subprocess."""
    with destination.open("wb") as output:
        try:
            result = subprocess.run(args, stdout=output, stderr=subprocess.STDOUT,
                                    timeout=timeout, check=False)
            return result.returncode
        except subprocess.TimeoutExpired:
            output.write(b"\nDIAGNOSTIC_TIMEOUT\n")
            return 124


def renderer_identity(pid, started):
    result = subprocess.run(
        ["/bin/ps", "-p", str(pid), "-o", "lstart=,comm="],
        capture_output=True, text=True, timeout=3, check=False)
    fields = result.stdout.strip().split(maxsplit=5)
    if len(fields) != 6:
        return None
    try:
        born = datetime.datetime.strptime(" ".join(fields[:5]), "%a %b %d %H:%M:%S %Y")
    except ValueError:
        return None
    path = fields[5]
    if born < started - datetime.timedelta(seconds=3):
        return None
    if not path.startswith(("/System/Library/", "/System/Volumes/Preboot/Cryptexes/OS/System/Library/")):
        return None
    if not path.endswith("/com.apple.WebKit.WebContent.xpc/Contents/MacOS/com.apple.WebKit.WebContent"):
        return None
    return path


def capture(process, executable, started, directory):
    # Capture state before terminating the exact harness process.
    command(["/bin/ps", "-p", str(process.pid), "-o", "pid,ppid,stat,etime,comm"],
            directory / "main-process.txt")
    command(["/usr/bin/sample", str(process.pid), "2", "10"],
            directory / "main-sample.txt", 6)
    predicate = f"processIdentifier == {process.pid} AND processImagePath == {json.dumps(executable)}"
    command(["/usr/bin/log", "show", "--start", started.strftime("%Y-%m-%d %H:%M:%S"),
             "--style", "compact", "--info", "--predicate", predicate],
            directory / "app-unified.log", 12)
    log = (directory / "app-unified.log").read_text(errors="replace")
    owned = sorted(set(int(value) for value in re.findall(
        r"\[PID=(\d+)\] WebProcessProxy::didFinishLaunching:", log)))
    (directory / "owned-renderers.json").write_text(json.dumps(owned))
    for pid in owned[:8]:
        try:
            identity = renderer_identity(pid, started)
        except subprocess.TimeoutExpired:
            identity = None
        if identity is None:
            (directory / f"renderer-{pid}-identity.txt").write_text("Identity unavailable; not sampled.\n")
            continue
        (directory / f"renderer-{pid}-identity.txt").write_text(identity + "\n")
        command(["/bin/ps", "-p", str(pid), "-o", "pid,ppid,stat,etime,comm"],
                directory / f"renderer-{pid}-process.txt")
        command(["/usr/sbin/lsof", "-nP", "-p", str(pid), "-FpcftDinal"],
                directory / f"renderer-{pid}-files.txt", 6)
        # Revalidate immediately before sampling; no renderer is ever signaled.
        try:
            still_owned = renderer_identity(pid, started) == identity
        except subprocess.TimeoutExpired:
            still_owned = False
            (directory / f"renderer-{pid}-recheck.txt").write_text("Identity recheck timed out; not sampled.\n")
        if still_owned:
            command(["/usr/bin/sample", str(pid), "2", "10"],
                    directory / f"renderer-{pid}-sample.txt", 6)
    # Preserve corresponding child log events without mixing unrelated TCC traffic.
    if owned:
        child_predicate = " OR ".join(f"processIdentifier == {pid}" for pid in owned[:8])
        command(["/usr/bin/log", "show", "--start", started.strftime("%Y-%m-%d %H:%M:%S"),
                 "--style", "compact", "--info", "--predicate", child_predicate],
                directory / "renderers-unified.log", 12)


def main():
    if (os.environ.get("GITHUB_ACTIONS") != "true"
            or os.environ.get("CI_ISOLATED_RUNNER") != "github-hosted"):
        raise SystemExit("This diagnostic may only run on an isolated GitHub-hosted runner")
    app, evidence, variant, count = sys.argv[1:]
    evidence = Path(evidence).resolve()
    executable = str(Path(app).resolve() / "Contents/MacOS/WebKitAB")
    if variant != "public-default" or not 1 <= int(count) <= 90:
        raise SystemExit("Invalid experiment arguments")
    outcomes = []
    for cycle in range(1, int(count) + 1):
        directory = evidence / f"cycle-{cycle:03d}"
        directory.mkdir()
        started = datetime.datetime.now()
        beginning = time.monotonic()
        with (directory / "stdout.log").open("wb") as stdout, (directory / "stderr.log").open("wb") as stderr:
            process = subprocess.Popen([executable, str(cycle)], stdout=stdout, stderr=stderr)
            try:
                deadline = beginning + 30
                while process.poll() is None and time.monotonic() < deadline:
                    if b"AB_FAILURE " in (directory / "stdout.log").read_bytes():
                        break
                    time.sleep(0.1)
                output = (directory / "stdout.log").read_text(errors="replace")
                expected = f"AB_PASS variant={variant} cycle={cycle} visible=2 loaded=5"
                passed = process.poll() == 0 and expected in output
                elapsed = round(time.monotonic() - beginning, 3)
                outcomes.append({"cycle": cycle, "pid": process.pid, "passed": passed, "seconds": elapsed})
                (evidence / "results.json").write_text(json.dumps(outcomes, indent=2) + "\n")
                print(f"{variant}: cycle {cycle}/{count} {'PASS' if passed else 'FAIL'} ({elapsed}s)", flush=True)
                if not passed:
                    capture(process, executable, started, directory)
                    return 1
            finally:
                if process.poll() is None:
                    # Only the exact child created above, and only after diagnostics.
                    process.terminate()
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait(timeout=5)
        # Never delete Metal caches or reuse a process between cycles.
        time.sleep(0.25)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
