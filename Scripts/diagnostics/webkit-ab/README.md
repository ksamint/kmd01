# Isolated WebKit startup/paint A/B

This is a diagnostic experiment, not a production patch. It never launches,
quits, installs, or uses the bundle identifier of kmd.

Run in two separate, fresh macOS 15 GitHub-hosted jobs:

```sh
CI_ISOLATED_RUNNER=github-hosted bash run.sh default "$RUNNER_TEMP/webkit-ab-evidence" 90
CI_ISOLATED_RUNNER=github-hosted bash run.sh startup-paint-spi "$RUNNER_TEMP/webkit-ab-evidence" 90
```

Run only ONE command per fresh job. `GITHUB_ACTIONS=true` must already be set.
Use the same Xcode/SDK selection for both jobs and a 20-minute job timeout.
Always upload the explicit evidence directory. No secrets are needed.

Both variants have the same dedicated bundle identifier:
`dev.ksamint.diagnostics.webkitstartupab`. Each job compiles once, signs its
diagnostic app ad hoc with App Sandbox and outgoing-network entitlements, then
launches a new process for each cycle. Its own cache is retained between cycles.
The only variant difference is setting these two private configuration options
to false in `startup-paint-spi`:

- `_setDelaysWebProcessLaunchUntilFirstLoad:`
- `_setWaitsForPaintAfterViewDidMoveToWindow:`

Both variants use `.preferredConfig()` from the unchanged copy of the app's
`MarkEditCore/Sources/Extensions/WebKit+Extension.swift` in `BaselineWebKit.swift`.
Thus both share its transparent `_drawsBackground` configuration and developer
extras. The `default` label means defaults for the TWO tested startup/paint
settings, not a fully public-API configuration. Neither variant calls
`enablePerformanceFlags()`: the app's occlusion, DOM timer, CORS, feature, and
background-process overrides are omitted equally. There are two visible 720x480 windows, two retained
hidden zero-sized views, and one retained detached spare created 0.2 seconds later.
All five load identical local HTML data with no external resources.

Each cycle requires all five navigation completions, the exact cycle marker and
nonzero DOM bounds in both visible views, two distinct requestAnimationFrame
timestamps, and successful nonempty WKWebView snapshot callbacks. JavaScript
evaluation only reads DOM/page state. A snapshot is not OCR-checked and rAF alone
is not proof of compositor/GPU presentation. After readiness, the process holds
all views for four seconds and terminates normally through NSApplication.

The external watchdog bounds each cycle to 30 seconds and stops on the first
failure. Before cleanup, it captures the exact main process, its unified logs,
and WebContent PIDs identified by that app's `didFinishLaunching` WebKit events.
It validates child executable paths and launch times, then records their samples,
open files, process states, and unified logs. Diagnostics have individual timeouts.
Only after capture may the watchdog TERM/KILL its own stuck harness child;
it never signals WebContent, other applications, or production processes.
Every cycle retains stdout/stderr, and the evidence includes source copies/hashes,
compiler, OS, signing/build logs, executable hash, and machine-readable results.
`test_watchdog.py` runs nine mocked process-identity checks before the build;
it never launches a GUI application.

Interpretation: reproducing the same CA/Metal/CoreFSCache/flock stack without
the editor would narrow the problem to WebKit/graphics startup behavior.
An A/B difference is evidence about this two-setting combination, not proof
which setting causes it. A follow-up would vary one setting at a time.
A passing simplified harness does not clear the real app: there is no NSDocument
restoration, CoreEditor, custom scheme, workspace preview code, user customization,
or production signing identity. The two jobs have separate initially fresh caches,
and virtual GPU behavior may differ from physical Macs. A single 90-cycle pass
is useful bounded evidence, not a guarantee of absence.
