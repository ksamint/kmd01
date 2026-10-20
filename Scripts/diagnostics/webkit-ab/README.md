# Public WebKit configuration control

Temporary diagnostic only, not production acceptance. This revision retains the
previous harness, watchdog, 90 cold launches, 30-second deadline and four-second
post-readiness hold, but uses only `WKWebViewConfiguration()` and no private
selectors. `BaselineWebKit.swift` is removed and is not compiled.

Run once on a fresh hosted macOS 15 account:

```sh
CI_ISOLATED_RUNNER=github-hosted bash run.sh public-default "$RUNNER_TEMP/webkit-ab-evidence" 90
```

The same dedicated diagnostic bundle identifier, local HTML, two visible views,
two hidden views and one delayed detached view are retained. Readiness requires
all five navigation completions, exact visible markers, nonzero DOM bounds, two
requestAnimationFrame timestamps and nonempty snapshots. Failure diagnostics
observe the exact harness and validated owned WebContent processes before
terminating only the watchdog-owned harness child. No cache changes or external
process signals are introduced.

A reproduced failure would establish that the private transparency/developer
settings are not necessary for this hosted minimal reproduction. A pass does not
prove absence or clear the production application. Source hashes and evidence
remain bound to this exact diagnostic commit.
