# Manual Fix

**Fix…** is available from the dashboard, menu bar view, process details and incident details. The first click requests current data and prepares a plan. It never sends a process action by itself.

## Review and approve

The plan shows the problem, measured evidence, exact target and limits. A global pressure or swap warning does not automatically select a process: use **Review current large consumers** to choose one. This does not reclassify it as Codex.

For a verified app, **Quit** sends the normal macOS request. The app may show a save prompt or refuse to exit. **Quit and reopen** waits for the original instance to exit and rechecks the bundle before opening it; session restoration is not guaranteed. Independently selected processes use SIGTERM. Helpers are not terminated as a group.

**Force Quit** is a separate action with its own exact-target confirmation. A timed-out Quit never escalates automatically. Save work before approving an action. Cancel stops remaining steps; it cannot undo a request already sent.

Each approval is bound to the displayed session and plan. Native effects recheck PID, microsecond start time, path, owner, bundle and source relationship. The watchdog, its ancestors, system paths and other users' processes are protected.

## Verification

The coordinator compares the baseline with at least three fresh, distinct monitoring samples, within a 120-second verification window. Original-process exit has a separate bounded wait. Results distinguish:

- whether the action completed;
- whether the target problem recovered;
- whether the system improved.

An app can exit successfully while the system remains under pressure. Unknown data never establishes recovery, and an incomplete baseline cannot establish system improvement. A missing helper trend or monitored footprint can leave the result unverifiable. A monitoring retry cannot succeed on continuing partial readings.

Swap does not have to shrink immediately. Footprint accounting is not a promise of the same amount of unique RAM being released.

## Other problems

Monitoring retry replaces the existing sampling loop and preserves settings/history. Storage, notifications and login-item problems offer public system tools and guidance. Opening a settings pane is not reported as a repair. Fix never deletes user files, caches or swap files, and has no Fix All.

The Incident Timeline keeps the approved plan, identity, pre/post evidence and outcome. Old incidents always trigger fresh assessment. Unfinished sessions become **Interrupted** on restart; no dangerous action is resumed.

## Simulation

**Simulation Mode** uses synthetic data and simulated effects. Native actions and live-history writes are blocked in the execution layer too. **missingMetrics** can exercise a complete monitoring-repair workflow; recovery includes process readings as well as system values. **Return to live** restores real monitoring.
