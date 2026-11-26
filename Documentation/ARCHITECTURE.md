# Architecture

MemorySentinel is a Swift 6 package targeting macOS 14. The app uses SwiftUI, AppKit and Swift Charts. It has no external package dependencies or remote service dependency.

| Module | Responsibility |
|---|---|
| `CSystem` | Darwin/libproc metrics, SQLite exposure, checked signals and bounded local readiness transport |
| `SentinelCore` | Models, discovery, identity, analysis, sampling, persistence, notification policy, permission gates and native Fix runtime |
| `MemorySentinel` | Dashboard, process/Activity views, settings, permission registration and native notification delivery |
| `SentinelDiagnostics` | A command-line entry point for the production collector |
| `SentinelCoreTests` | Dependency-free test runner, mocks and disposable native fixtures |

## Profiles and experience analysis

`ExperienceCoordinator` consumes the existing engine's samples. Live and simulated state use separate actors; neither adds a sampling timer or sends process actions. Exact application roots and verified ancestry produce versioned application observations. Missing member readings leave an aggregate unavailable.

Profiles hold exact rules, exclusions, notification preferences and advisory budgets. A stable configuration label separates learning contexts. Names and notification delivery do not change that context. Configuration revisions and the intervention epoch gate invalidate stale Fix plans.

Normal ranges use bounded minute buckets and require 60 eligible minutes. Budget forecasts require at least ten minutes of adequately covered, consistent growth in the same application instance. They are conditional extrapolations, with explicit unavailable reasons, rather than predictions of system exhaustion.

Flight recordings reference shared compact frames, retain available lead-in and merge overlapping triggers. Per-frame lifecycle markers are also retained for later manual captures and restart recovery. Sessions accumulate time-weighted measurements and observation coverage, with bounded chart series and lazy completed-session details. Downsampling preserves peaks and propagates omitted gaps to prevent false continuity.

Fix follow-ups observe the next five minutes without invoking an executor. Original immediate results remain immutable. Exact process measurements, application totals and system observations retain distinct meanings. Comparison cohorts include profile, application, version, diagnosis and action; incomplete cases stay separate.

## Monitoring

Identity is PID plus microsecond process start time. Classification uses exact bundle/executable evidence and verified, older parent ancestry; a generic runtime name or process group alone is not enough. Optional metrics remain unavailable instead of becoming zero.

The monitoring actor owns one loop and serializes fresh-snapshot requests. Its scoped activity prevents App Nap from deferring continuous sampling while permitting system/display sleep. Pause/stop release the activity. AppModel owns one pressure observer. Closing the dashboard releases its heavy views without stopping the engine.

The analyzer combines bounded 1/5/15-minute trends, jumps, sustained footprint, swap growth and pressure. Escalation/recovery use confirmation and hysteresis; true critical pressure can bypass normal confirmation. The legacy incident gate retains per-identity event cadence; native delivery uses persistent problem episodes instead. An unchanged episode never resends a warning just because that cadence expires. Insights are deterministic measured statements.

System used/available are estimates based on VM counters. Pressure combines the readable kernel level and dispatch events. Footprint, RSS and group accounting have distinct semantics; no sum claims unique RAM.

## Fix

`FixCoordinator` is an actor with one session: assess → review → execute → verify → result. It claims approval before suspension, persists the decision, requests fresh data and revalidates identity. UI approvals carry the displayed session/plan IDs; a Force confirmation retains the same target.

`NativeFixRuntime` connects the engine to `ProcessActionService`. The service handles normal Quit, verified reopen and checked individual signals. A synchronous epoch gate blocks effects crossing cancellation, pause, settings, sleep or live/demo changes. The C guard protects identity, owner, self/ancestors and system paths. POSIX does not make the final check and signal atomic.

Verification uses at least three fresh engine samples and a bounded deadline. Action, target and system outcomes are separate. `hasUnavailableMemoryReadings` keeps diagnosis, dashboard and monitoring-repair verification consistent. Unknown baseline comparisons, missing worker trends and partial process readings cannot establish success. Demo state is separate, and the native executor rejects demo tokens.

## Storage

SQLite WAL stores bounded detailed samples, minute rollups, incidents and Fix sessions. Detailed payload is capped at 48 MiB/20,000 samples; minute buckets at 10,080; incidents at 2,000; Fix sessions at 500 with a 256 KiB per-record cap. Time retention can prune earlier.

Fix revisions prevent stale writes. Startup marks nonterminal sessions Interrupted without replay. JSON schema 2 and 17-column CSV exports include the audit and split outcomes. Corrupt databases are preserved as local backups before recovery. Arguments and environment values are not logged.

SQLite `user_version=2` adds shared experience frames and revision-guarded items. Migration uses a consistent SQLite backup before a transaction. Recovery and history deletion stop and drain sampling before replacing or clearing data; monitoring stays paused until explicitly resumed. Settings preserve a legacy copy on their first update.

Experience payload has a 64 MiB logical quota, up to 20 retained captures plus expiry headers, 100 sessions and 200 follow-ups. Frames are limited to 256 KiB, individual items to 512 KiB and learning state to 8 MiB. SQLite pages, WAL and recovery backups can make total filesystem usage larger than logical payload. Retention removes older evidence rather than reconstructing it.

HTML and Markdown reports are built off the main actor from a snapshot of the selected evidence. Default reports omit paths, identities, custom names and notes. HTML escapes all text and includes an inline chart, styling and a restrictive content policy without scripts or remote assets. SwiftUI owns the report file-export presentation.

## Episodes, identity and automatic authority

`ControlCoordinator` consumes the same measured snapshots. `ProblemEpisodes` uses wall/monotonic continuity and covered time for warning confirmation and stable recovery. It reserves native delivery before handing a stable notice ID to AppModel. Live and demo coordinators remain separate. A versioned atomic control file leaves SQLite schema 2 unchanged.

`AppIdentityResolver` separates direct bundle identity, verified launcher and their process instances. Its bounded current ancestry and historical cache are presentation evidence; watch classification and action authority stay separate. No arguments, environment, terminal contents or project files are inspected to infer a name.

External authority requires a registered exact rule, fresh code/target assessment, durable attempt reservation and a one-use `AutomationGate` permit bound to the current profile/context epoch. `FixCoordinator` records manual, policy and self-repair authority separately, then uses the existing checked executor, three-sample verification and five-minute observer. A cheap preflight avoids hashing or IPC while quotas/context already block an action. Executable changes lock a rule for review, including across restart.

The synchronous policy gate rechecks before the primary effect and any separately allowed reopen. Revocation, Stop automation, sleep, mode/profile changes and manual priority invalidate pending context. Crashed/ambiguous attempts are recorded as Interrupted and never replayed. Usage limits survive ordinary history clearing.

Own monitoring repair uses a separate three-attempt backoff cycle and the same sole engine. A non-sampling watchdog detects stale/incomplete system evidence; it never starts parallel collectors. Native calls that cannot be interrupted and unavailable audit storage can still require manual review. Regenerable icon/UI caches may be reduced; settings, notes, backups and user data are preserved.

Advanced application restart requires a private peer-verified readiness lease held by the explicitly selected cooperating app. The product includes a bounded client, not a general app-state detector or an IPC listener. The test app supplies the cooperative server and a real save prompt. See [Automation](AUTOMATION.md) for its protocol and trust limits.
