# Validation

## 1.3.0 checks — November 26, 2026

Both the SwiftPM and optimized direct-compiler full suites passed **81 groups and 703 assertions, with no failures**, on Apple Silicon, macOS 26.3.1 and Swift 6.0.3. Coverage adds episode deduplication, persistence, warning/critical budgets, recovery clocks, application origin and bounded caches, exact executable pins, permission scope/expiry, one-use permits, revocation, bounded reopen, durable reservations, interrupted no-replay recovery and self-repair backoff. Long warning/recovery windows use a controlled clock. No real system memory-pressure stress was created to test urgent notifications.

Real native checks stopped an owned disposable task with SIGTERM and relaunched it from its approved specification through the policy runtime. Cooperative readiness tests use a real private Unix socket with kernel peer checks, accepted/busy/unsaved replies, nonce/identity rejection and a bounded no-reply deadline. An independently running AppKit fixture supplies real peer credentials and readiness replies. Its policy-gated normal Quit/reopen passed; an unsaved-work reply was observed; and a real native save prompt left the fixture running without an automatic Force request. Existing identity, refusal, separately confirmed Force and live/demo guards passed. After correcting a temporary-path alias in native replacement verification, both complete suites passed again. A final targeted direct-build run passed 2 native groups / 31 assertions and verified test-child cleanup. Only owned disposable fixtures received test process actions.

Interactive checks on an isolated live-data copy verified the process table, detail/launcher chain, label/search/grouping, exact registration, default-off master switch, UI-to-native policy SIGTERM, Reviewing, Stop/revoke, redacted report and completed five-minute observation (58 samples, 296.5 covered seconds). The live process detail also showed a bundled Python runtime separately from its verified ChatGPT launcher, including each exact application instance. A closed-dashboard development window persisted 41 new samples over about 208 seconds, with a maximum 5.331-second gap and valid SQLite integrity. Reopening showed a one-second-old sample.

The installed app and original data were backed up outside the managed data folder before the local update. The installed 1.3.0 executable matches the extracted ZIP. Native settings checks confirmed self-repair on, external actions off, zero registered permissions, warning banners off and the critical reminder on. Original settings stayed byte-identical. SQLite remains schema 2 with valid integrity; pre-update minute, incident, Fix and experience-frame rows were retained byte-for-byte at the comparison. The existing 48 MiB detailed-payload retention removed 43 oldest rows as new samples arrived. An in-progress recording was preserved as partial with an explicit restart/gap reason, and the experience state advanced normally. The consistent backup preserves the entire pre-update snapshot.

Optimized packaging, strict formatting, both C static analyses, shell syntax and whitespace checks passed locally. The final Apple Silicon ZIP was extracted and its ad-hoc signature verified strictly (1.3.0, build 11, minimum macOS 14). Its executable contains no personal build-home path and the archive contains no local settings, database or control state. The release's `SHA256SUMS` verifies the final archive. The app has no Developer ID signature or notarization ticket. GitHub Actions results are tracked separately under CI below. Previous-version measurements below do not establish 1.3 resource cost.

### 1.3 resource observations

The final installed executable was measured against the original live data at a five-second interval. The open window used Overview's 15-minute chart; the closed window made no dashboard/accessibility queries. Each window lasted 60 seconds. CPU is average percentage of one core; footprint and RSS are separate accounting measures.

| Final installed 1.3.0 | CPU, one core | Peak footprint | Peak RSS |
|---|---:|---:|---:|
| Dashboard open | 5.733% | 90.06 MiB | 160.33 MiB |
| Dashboard closed | 1.717% | 85.20 MiB | 118.86 MiB |

The closed window persisted 12 new samples, with a maximum 5.329-second gap and valid SQLite integrity. The latest stored sample was 0.70 seconds old at the final probe; reopening showed a zero-second-old sample. Activity kept a measured warning visible without requesting another native banner.

Earlier development windows observed 4.333–4.917% open-dashboard CPU and peak footprints of 132.97–195.81 MiB; closed windows observed 1.100–1.967% CPU and 100.25–118.11 MiB peaks. These were different live workloads and runtime states, rather than a matched causal comparison. Other applications remained active. The higher observations are not discarded because the final short window was lower.

The initial 2% CPU / 80 MiB footprint targets are **not generally achieved**. Open UI cost and retained native caches remain optimization work. No memory-pressure stress or long soak was used; these short windows do not establish a long-term ceiling. The older 1.2 measurements below used different conditions and should not be treated as a controlled 1.3 comparison.

Advanced app restart was exercised with owned cooperating fixtures, not arbitrary installed editors or ChatGPT/Codex. There is no built-in integration that proves those apps have no unsaved work. Missing readiness remains a manual decision. Actual hardware sleep/wake, all OS versions and a full accessibility traversal remain unverified, as listed below.

## 1.2.0 checks

The 1.2.0 release candidate was checked on November 24–25, 2026, on Apple Silicon with 18 GiB RAM, macOS 26.3.1 and Apple Swift 6.0.3. The deployment target remains macOS 14; this does not establish compatibility with every supported OS version.

The full suite passed **61 groups and 439 assertions, with no failures**, including the native AppKit fixtures. New coverage includes profile/version learning, excluded samples, short/noisy/gapped forecasts, capture merging and quotas, pre-trigger markers after restart, frozen report references, weighted sessions, omitted chart gaps, unknown/replacement consumer peaks, scoped snoozes and report privacy. Capture-boundary tests exclude late frames, start a separate capture for a later warning, and preserve incomplete-evidence status. Follow-up tests separate process/group accounting and incomplete observations, and exclude samples or warnings after the five-minute deadline. Maintenance tests drain a sample already in flight before allowing data replacement. Failure-injection checks verify whole-batch rollback, stale-revision rejection and legacy-data preservation after a failed migration. A 700-plan churn check verifies that unapproved Fix revisions remain bounded without losing retained follow-up evidence.

Optimized app compilation, strict formatting, C static analysis, shell syntax and whitespace checks passed. The delivered ZIP was extracted and its ad-hoc signature verified strictly. Its executable contains no personal build-home path. It has no Developer ID identity or notarization ticket.

Interactive checks used an isolated copy of the data. They covered profile editing/activation, budget warnings, automatic and merged manual captures, shared cursors, interrupted recovery, live session creation/end/comparison, active-comparison refresh, pressure/swap summaries, snooze/resume and the conditional forecast demo. Switching profiles cancelled a pending Fix plan. Simulated monitoring repair completed after three fresh samples, followed by a separate five-minute observation and updated past-outcome counts. The exact time boundary was additionally tested with a controlled clock.

HTML and Markdown previews omitted private details and notes by default. Both formats saved with responsive UI afterward; the existing CSV export also returned to the dashboard. Saved shared reports were checked for omitted personal data, owner-only permissions, escaped text, well-formed inline SVG, restrictive content policy and no scripts or external assets. Standalone browser rendering was not visually verified.

The local installation was updated after preserving the prior app and data. SQLite schema 2 and integrity were verified. Every row of all four legacy tables in the pre-migration backup matched the original snapshot by count and content hash: 1,759 detailed samples, 4,204 minute rollups, 445 incidents and 9 Fix sessions. The original settings file remained byte-for-byte unchanged. Normal retention continues after migration; the backup preserves the complete pre-update snapshot.

## Resource measurements

Short resource checks are observations rather than long-term upper bounds. CPU is a percentage of one core; footprint and RSS remain different accounting measures. The external probe converts Mach CPU counters with the machine's timebase and was cross-checked against POSIX `getrusage`.

A matched comparison used separate temporary data folders, the same copied settings with notifications disabled, five-second sampling, the stable simulation and the Overview's 15-minute chart. Both charts reported the same 1.01 GiB peak. Each window lasted 60 seconds; the 1.2.0 measurements below use the delivered executable.

| Version and dashboard | CPU, one core | Peak footprint | Peak RSS |
|---|---:|---:|---:|
| 1.1.4 open | 0.963% | 155.407 MiB | 124.297 MiB |
| 1.2.0 open | 1.577% | 161.892 MiB | 114.609 MiB |
| 1.1.4 closed | 0.150% | 57.829 MiB | 104.562 MiB |
| 1.2.0 closed | 0.184% | 60.720 MiB | 107.703 MiB |

This short comparison shows added analysis/UI cost. It does not isolate every effect of framework caches, memory compression or changing system load. Synthetic sampling does not include the cost of enumerating real processes.

The delivered app was also measured against the original live data, with five-second sampling and the Overview's 15-minute chart:

| Dashboard | CPU, one core | Peak footprint | Peak RSS |
|---|---:|---:|---:|
| Open, 60 seconds | 3.195% | 68.923 MiB | 116.859 MiB |
| Closed, 60 seconds | 0.596% | 62.548 MiB | 105.750 MiB |

The closed window produced 12 new persisted samples, with a maximum 5.329-second sample gap. Reopening the dashboard showed a one-second-old sample. The app kept running throughout the window and SQLite integrity remained valid.

Open-dashboard CPU exceeded the initial 2% target in this live window, and the matched simulation's chart footprint exceeded 80 MiB. These targets are not claimed as generally achieved. RSS can exceed footprint, and neither the short background result nor its lower footprint establishes a long-term memory bound.

During a storage snapshot, the original data folder grew from 57.70 MiB before migration to 116.46 MiB, including its pre-migration backup and SQLite journals. New experience payload occupied 1.36 MiB. Logical payload limits do not include SQLite free pages, indexes, journals or backups. Validation also preserved a separate verified copy of the pre-update app and data outside the managed data folder; such copies remain until manually removed.

## Earlier 1.1.4 validation

Version 1.1.4 was checked on Apple Silicon, macOS 26.3.1, with Swift 6.0.3 and the macOS SDK. The package deployment target is macOS 14. This is not a claim that every supported macOS version has been tested.

The complete suite has **41 groups and 262 assertions**. It covers identity/ancestry, PID reuse, risk hysteresis, trends, missing metrics, persistence/retention/exports, monitoring restart, cancellation, stale approvals, independent Fix outcomes and live/demo isolation.

Native integration uses a uniquely identified disposable AppKit app. It verifies its actual normal-Quit callback, a newly identified reopened instance, refused Quit without escalation, separately confirmed Force Quit and individual SIGTERM, plus native identity/owner/self/demo guards. No normal user workload is used as a signal target.

Release validation includes optimized compilation, strict Swift formatting, C static analysis, shell syntax, icon dimensions, archive contents and strict ad-hoc signature verification. Targeted UI checks exercise process plans, Force confirmation/cancellation, simulated reopen, three-sample results, old-incident reassessment, recorded evidence and complete monitoring repair. Restart recovery and continued sampling after dashboard close have also been checked.

## CI

The measurements and interactive checks above were run locally. GitHub Actions checks are separate; use the run for the relevant commit or release to confirm its result.

The macOS workflow builds, runs the full suite, checks formatting/static analysis and packages the app. Native AppKit tests require a functioning logged-in graphical session. There is no automatic test skip: a fixture-startup problem is a failed check and must be investigated. CI is not a substitute for the interactive dashboard checks.

See the repository's [Actions page](https://github.com/santiagoo43/MemorySentinel/actions) for actual run results. No badge or statement substitutes for a completed run.

## Remaining coverage limits

- macOS 14/15 compatibility matrix and full VoiceOver/contrast traversal.
- Hardware sleep/wake, login/logout and long-duration real-world soak testing.
- Exact system menu bar, Dock and Command–Tab appearance across macOS versions and display settings.
- Developer ID signing, notarization and reliable launch-at-login registration for a distributed build.
- Standalone HTML layout across browsers.

Short resource measurements are not long-term upper bounds. Open charts and native framework caches can cost more than a closed dashboard. Process accounting is not unique physical RAM, and sampling can miss events between observations.
