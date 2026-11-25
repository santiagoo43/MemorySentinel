# Profiles, recordings, sessions and reports

Profiles, recordings, work sessions and reports are available in MemorySentinel 1.2.0 and later.

## Work profiles

Choose a profile in the dashboard header or menu bar. **Profiles → Edit…** controls its built-in targets, exact watch rules, notification preference, exclusions and reference budgets. Up to 12 profiles are stored. Editing an active profile updates its effective monitoring settings. Relevant changes invalidate pending Fix approvals.

A group budget applies to its attributed application groups. An application budget takes precedence for its exact observed application identity. Budgets are advisory footprint-accounting limits: they do not reserve RAM or state how much unique physical memory is available. Different apps can share counted resources.

Application targets can be selected from currently measured apps. Rules match complete bundle IDs or executable paths. Generic process names never establish ownership. Profiles do not inspect project files, shell commands or environment values.

## Normal ranges and forecasts

Application cards show current footprint, members, available version metadata, reference budget, normal range, trend and measurement quality.

**Learning** continues until at least 60 minutes of eligible observations are available. Normal ranges use local bounded minute buckets, separated by profile, application, observed version and relevant configuration. Warnings, critical pressure, unavailable readings, budget/normal-range deviations, Simulation Mode and intervention periods are excluded. Renaming a profile or changing notification delivery does not reset measurement context. Unknown application versions remain explicitly unknown.

Reset one application's range from its card menu, or all ranges for the active profile from **Profiles**. Resetting ranges does not clear history or settings.

A forecast estimates when the application may reach its reference budget if measured growth continues. It requires at least 10 minutes of recent, adequately covered observations, with consistent growth across time windows. Flat/noisy trends, gaps, missing readings and instance changes prevent a forecast. Estimates outside the two-hour horizon are withheld. The displayed range is conditional extrapolation, not a calibrated probability interval or a prediction of system memory exhaustion.

## Flight Recorder

Confirmed memory events automatically trigger a recording. **Record now** starts a manual capture using the same monitoring samples. It retains up to 10 minutes of available lead-in and up to 10 minutes after the latest trigger. Overlapping triggers merge. Total duration, frame, count and shared storage limits can shorten a capture.

Select a capture under **Recordings**. Drag either chart or use its keyboard-accessible time slider; both charts share the cursor. The detail panel shows the nearest actual sample, its process subset and the capture's before/after footprint. Event markers distinguish recorded lifecycle, profile, warning, Fix and gap events.

Historical data is read-only evidence. To act on a current problem, open a fresh Fix plan from the current dashboard or process view.

Capture states:

- **Recording:** subsequent samples are still being collected.
- **Complete:** the bounded post-trigger capture finished.
- **Partial:** unavailable readings, sampling gaps, changed context, interruption or capture limits left incomplete evidence. A capture can keep recording while displaying its quality limitation, then finish as Partial.
- **Expired:** automatic retention or storage quotas removed the frames; an expiry notice can remain.

Frames contain at most 96 monitored processes plus 12 other measured consumers. A process entering that subset is not automatically called a newly started process. A successful enumeration and identity check distinguish a disappearance from an unreadable PID. Omitted processes and event-marker limits are disclosed.

## Work sessions

Use **Sessions → Start…** to choose a name, profile and optional private note. End it from that page or the menu bar. Measurement uses the existing engine; it does not inspect the work being performed.

The summary includes observation time and coverage, time-weighted mean and observed peak footprint, measured pressure time, swap change, warning events, approved Fix sessions and leading consumers. Gaps contribute no invented observations. A session left active when the app exits is recovered as **Interrupted**, retaining its stored evidence.

Choose another session under **Compare with**. Curves align at their own starts without stretching different durations. Warning rates use observed time. Cautions identify differing profiles, applications, versions, configurations, interrupted endings and low coverage. Workload differences can explain changes; an overlay does not establish causation.

## Fix follow-up

Immediate Fix results remain unchanged. A separate five-minute observation tracks existing samples after an accepted action. It never sends another process action.

**Incidents** and recorded Fix details show coverage, sample count, before/immediate/follow-up measurements and any related warning observed. Interrupted or incomplete windows are partial or unavailable. A missing metric is not zero, and an exited process has no current footprint. Process footprint and attributed group totals remain separate.

**What helped before** groups matching profile, application, observed version, diagnosis and action. Complete, partial/unavailable and still-observing counts are separate. Few cases and unknown versions remain explicit; past observations never authorize a new action.

## Warning snoozes

An application card's menu can snooze a particular warning type for 15, 30 or 60 minutes. The active profile and exact observed application scope are retained. **Resume alerts** removes a snooze early.

Snoozes affect notification delivery. Sampling and event recording continue, current warnings remain visible, and critical system alerts bypass warning snoozes. Operating-system notification permission and the profile's notification preference still apply.

## Reports

Use **Report…** on a recording or session, or **Report preview…** in recorded Fix evidence. Review the complete preview before **Save report…**.

The default shared version omits personal paths, user-defined names, process identities and private notes. Custom application names become report-local labels. **Include private details** and **Include private notes** are separate explicit choices. Review detailed reports carefully; they can reveal private workspace information.

Standalone HTML contains inline styling and an inline measured chart, with no scripts or external assets. Markdown includes measured timeline values. Both formats retain unavailable values and observation limits. Saving a report is a local operation; no upload or automatic message is sent.

## Bounded storage and recovery

Experience data has a shared 64 MiB logical-payload quota, in addition to the existing history limits. There are up to 20 retained recordings plus expiry notices, 100 sessions, 200 follow-ups and 128 learning contexts. Quotas can expire older data sooner than the count limits. Frames, record payloads, event buffers, chart series and learning buckets have additional finite bounds. SQLite indexes, free pages, WAL and recovery snapshots can use extra physical disk space.

Migration creates `history.pre-v2.sqlite` using SQLite's consistent backup API, then adds the experience tables in a transaction. Existing sample, minute, incident and Fix tables remain intact. A legacy settings file is preserved as `settings.pre-v2.json` on its first update.

**Profiles → Storage and recovery** can create `history.recovery.sqlite`. Its restore buttons specifically use the pre-migration backups. History restore stops and drains sampling first, saves the current database as `history.before-restore.sqlite`, restores the backup and leaves monitoring paused. Settings restore preserves current settings as `settings.before-restore.json`. Review the result before resuming.

For manual recovery from another snapshot, quit all copies of MemorySentinel, preserve the entire current data folder, and place the chosen snapshot as `history.sqlite` in a fresh data folder. Keep the old folder aside; do not mix a restored database with unrelated WAL files. Reopen the app to run the supported migration.

## Simulation

**Simulation → Growth toward reference budget** seeds a synthetic trend that can exercise a conditional forecast. Recordings, work sessions, follow-up and reports use a separate in-memory simulation context. Simulated data does not train live normal ranges or write live history. The native execution layer continues to reject simulation tokens.
