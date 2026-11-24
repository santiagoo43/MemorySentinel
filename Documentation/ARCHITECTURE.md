# Architecture

MemorySentinel is a Swift 6 package targeting macOS 14. The app uses SwiftUI, AppKit and Swift Charts. It has no external package dependencies or server component.

| Module | Responsibility |
|---|---|
| `CSystem` | Darwin/libproc metrics, SQLite exposure and checked signals |
| `SentinelCore` | Models, discovery, classification, trends, risk, sampling, persistence and Fix coordination |
| `MemorySentinel` | Dashboard, menu bar, process/incident views, settings, notifications and native Fix runtime |
| `SentinelDiagnostics` | A command-line entry point for the production collector |
| `SentinelCoreTests` | Dependency-free test runner, mocks and disposable native fixtures |

## Monitoring

Identity is PID plus microsecond process start time. Classification uses exact bundle/executable evidence and verified, older parent ancestry; a generic runtime name or process group alone is not enough. Optional metrics remain unavailable instead of becoming zero.

The monitoring actor owns one loop and serializes fresh-snapshot requests. Its scoped activity prevents App Nap from deferring continuous sampling while permitting system/display sleep. Pause/stop release the activity. AppModel owns one pressure observer. Closing the dashboard releases its heavy views without stopping the engine.

The analyzer combines bounded 1/5/15-minute trends, jumps, sustained footprint, swap growth and pressure. Escalation/recovery use confirmation and hysteresis; true critical pressure can bypass normal confirmation. Notification cooldown is tracked per identity. Insights are deterministic measured statements.

System used/available are estimates based on VM counters. Pressure combines the readable kernel level and dispatch events. Footprint, RSS and group accounting have distinct semantics; no sum claims unique RAM.

## Fix

`FixCoordinator` is an actor with one session: assess → review → execute → verify → result. It claims approval before suspension, persists the decision, requests fresh data and revalidates identity. UI approvals carry the displayed session/plan IDs; a Force confirmation retains the same target.

`NativeFixRuntime` connects the engine to `ProcessActionService`. The service handles normal Quit, verified reopen and checked individual signals. A synchronous epoch gate blocks effects crossing cancellation, pause, settings, sleep or live/demo changes. The C guard protects identity, owner, self/ancestors and system paths. POSIX does not make the final check and signal atomic.

Verification uses at least three fresh engine samples and a bounded deadline. Action, target and system outcomes are separate. `hasUnavailableMemoryReadings` keeps diagnosis, dashboard and monitoring-repair verification consistent. Unknown baseline comparisons, missing worker trends and partial process readings cannot establish success. Demo state is separate, and the native executor rejects demo tokens.

## Storage

SQLite WAL stores bounded detailed samples, minute rollups, incidents and Fix sessions. Detailed payload is capped at 48 MiB/20,000 samples; minute buckets at 10,080; incidents at 2,000; Fix sessions at 500 with a 256 KiB per-record cap. Time retention can prune earlier.

Fix revisions prevent stale writes. Startup marks nonterminal sessions Interrupted without replay. JSON schema 2 and 17-column CSV exports include the audit and split outcomes. Corrupt databases are preserved as local backups before recovery. Arguments and environment values are not logged.
