# Validation

## Local release checks

Version 1.1.4 was checked on Apple Silicon, macOS 26.3.1, with Swift 6.0.3 and the macOS SDK. The package deployment target is macOS 14. This is not a claim that every supported macOS version has been tested.

The complete suite has **41 groups and 262 assertions**. It covers identity/ancestry, PID reuse, risk hysteresis, trends, missing metrics, persistence/retention/exports, monitoring restart, cancellation, stale approvals, independent Fix outcomes and live/demo isolation.

Native integration uses a uniquely identified disposable AppKit app. It verifies its actual normal-Quit callback, a newly identified reopened instance, refused Quit without escalation, separately confirmed Force Quit and individual SIGTERM, plus native identity/owner/self/demo guards. No normal user workload is used as a signal target.

Release validation includes optimized compilation, strict Swift formatting, C static analysis, shell syntax, icon dimensions, archive contents and strict ad-hoc signature verification. Targeted UI checks exercise process plans, Force confirmation/cancellation, simulated reopen, three-sample results, old-incident reassessment, recorded evidence and complete monitoring repair. Restart recovery and continued sampling after dashboard close have also been checked.

## CI

The macOS workflow builds, runs the full suite, checks formatting/static analysis and packages the app. Native AppKit tests require a functioning logged-in graphical session. There is no automatic test skip: a fixture-startup problem is a failed check and must be investigated. CI is not a substitute for the interactive dashboard checks.

See the repository's [Actions page](https://github.com/santiagoo43/MemorySentinel/actions) for actual run results. No badge or statement substitutes for a completed run.

## Remaining coverage limits

- macOS 14/15 compatibility matrix and full VoiceOver/contrast traversal.
- Hardware sleep/wake, login/logout and long-duration real-world soak testing.
- Exact system menu bar, Dock and Command–Tab appearance across macOS versions and display settings.
- Developer ID signing, notarization and reliable launch-at-login registration for a distributed build.

Short resource measurements are not long-term upper bounds. Open charts and native framework caches can cost more than a closed dashboard. Process accounting is not unique physical RAM, and sampling can miss events between observations.
