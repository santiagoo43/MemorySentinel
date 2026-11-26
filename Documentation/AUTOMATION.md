# Notifications, task identity and automation

MemorySentinel keeps collecting evidence when a warning banner is suppressed. A large footprint or an advisory budget crossing does not automatically require interruption.

## Smart notifications

Ordinary warnings stay in Overview, Activity and the menu bar. Optional warning banners need at least 60 seconds of sufficiently covered observations, appear once per problem episode, have no sound and share a limit of three per hour. An unchanged condition is not resent when the old cooldown expires.

Related app and system memory signals are presented together. Independent storage or monitoring problems remain separate. PID/helper changes do not by themselves create a new application episode. Two minutes of continuously measured recovery close an episode; missing readings, sleep, clock changes and short improvements do not prove recovery. Notification reservations and Reviewing acknowledgement survive restart.

Fresh critical kernel pressure can attempt an urgent notification immediately. It bypasses the ordinary warning budget and warning snoozes. At most one further reminder is attempted after five minutes if critical pressure is still measured and you have not selected **Reviewing**. A genuinely actionable handoff can also notify once. Missing automation permission alone does not make an ordinary warning urgent.

All native risk alerts use the same policy. macOS notification permission, Focus and delivery settings still apply. The app has no Apple Critical Alerts entitlement and cannot guarantee a visible banner. Reviewing acknowledges an issue; it does not mark it resolved.

## Which program owns a process?

Processes separates the technical name, direct application, verified launcher, application instance and task label. A `node` or `python` name, shared interpreter path or process group is not enough to identify a project.

Application icons and names come from native bundle metadata. The direct bundle and launcher remain separate: a bundled Python runtime can show its verified editor/Terminal launcher in the row while retaining Python as its direct bundle. Launcher evidence follows a bounded current parent chain with matching owners and valid start times. **Why this application?** and the parent chain explain the association. **Historical** retains the last verified origin and time after a parent disappears; it cannot authorize an action. Unknown origins stay unknown. The resolver does not depend on the monitoring watchlist.

Use **Name this task…** to distinguish two tasks launched from the same Terminal or IDE. The label is bound to PID, start time, owner and executable. It does not prove an application relationship or allow a stop. **Register managed task…** is a separate permission workflow. Application/task names can be searched and application groups can be collapsed.

No process argument list, environment, terminal content or project files are scanned to guess a task name. A restart specification is supplied explicitly by you.

## Own monitoring repair

**Settings → Automation → Repair MemorySentinel's own monitoring** starts on. It can replace the sole sampler, recreate its pressure observer, release its own regenerable icon cache and check fresh measurements. Critical pressure also reduces the retained UI timeline to 240 points; stored measurements and critical sampling remain intact. Normal history retention continues under the existing limits.

Self-repair uses a bounded retry cycle with 2-, 10- and 30-second backoffs, no more than three attempts in five minutes, and no continuing cycle until monitoring has been healthy for two minutes. It yields to manual Fix and active interventions. An uninterruptible kernel call cannot be forcibly repaired; requests remain bounded and stale restart contexts are rejected when the engine becomes available.

A monitor repair is distinct from fixing another application or observing system recovery. No settings, notes, backups, project files, user caches or swap files are deleted.

## Register a disposable task

1. Open the exact process in **Processes** and choose **Register managed task…**.
2. Give it a useful name. Check PID, start time, owner, executable and launcher evidence.
3. Select sustained system pressure, critical system pressure or a separate explicit task stop threshold. Advisory reference budgets grant no action.
4. Choose the observed hold and an expiry of 1–30 days. The permission is bound to the current profile and analysis configuration.
5. Acknowledge interruption risk and register the permission. Registration does not turn on the external master switch.
6. Enable **Allow registered external actions** when ready.

The task must be disposable. SIGTERM can interrupt work; it is not a guarantee that an application saves. Permission starts with one exact process instance. It does not cover every Python/Node process, the launcher, siblings or children. A GUI application's main process requires the advanced cooperative application permission instead.

Restart requires a separate choice and a complete launch specification. Arguments are entered as a JSON string array, for example `["/absolute/path/to/disposable-worker.js"]`; no shell is invoked. The same pinned executable runs with those arguments, an optional absolute working directory, and a minimal PATH/LANG environment. Inherited arguments, tokens and environment variables are not guessed. Missing dependencies or configuration stop the attempt rather than broaden its permission.

The replacement is verified with a new kernel identity. Its known task label can be retained, but the old single-instance permission does not automatically authorize stopping the replacement. Register a new exact permission if needed.

## Advanced cooperative application restart

This starts off and requires a separately registered main application, exact code identity and a private readiness endpoint implemented by that application. Ordinary apps do not gain this capability from their bundle ID. Version 1.3.0 has no built-in ChatGPT/Codex readiness integrations.

The application must explicitly prove it is idle, has no unsaved work, and will hold that state briefly. Low CPU, hidden windows and background execution are insufficient. Unknown/busy state, unsupported integration, failed identity checks, refused Quit, save prompts and timeout lead to a human decision. The app never clicks dialogs or escalates to Force Quit.

### Local readiness protocol v1

The cooperating app owns a Unix stream socket in a directory owned by the same user with mode `0700`; the socket has mode `0600`. The resolved socket path must fit Darwin's 104-byte path field. The endpoint is entered during registration, not discovered by scanning the filesystem. No Accessibility, general Apple Events, Full Disk Access, root or helper service is requested.

MemorySentinel sends one UTF-8 JSON line containing `version: 1`, a fresh UUID `nonce`, and `identity` with `pid`, `seconds` and `microseconds`. The reply is one JSON line containing the same version, nonce and identity, plus Boolean `idle`, Boolean `unsavedWork` and integer `leaseMilliseconds` (1–2000). Request/response limits are 2048/4096 bytes. The total exchange has a one-second deadline.

The app must prevent new work or edits for the declared lease, even after the client disconnects. It must keep the connection open until the client closes it so that the client can repeat its kernel peer checks. It must return busy/unsaved state when it cannot make that commitment. A reply is a current readiness assessment, not an irrevocable quit instruction.

The client verifies kernel peer PID/effective PID, UID and process start time before and after the exchange. The exact executable digest is freshly checked before the operation, with final owner, mode, inode, size, modification/change times and native target checks at the effect boundary. A nonce reply from a different same-user process is insufficient. The actual quit path requests readiness again immediately before its one-use primary effect. A disconnected or unverifiable peer cannot authorize the step.

Normal Quit is sent through the existing checked executor. Reopen waits for the old exact instance to exit and rechecks permission, code and bundle. A submitted request cannot be undone, and a reopened app may not restore its prior session. The protocol trusts the explicitly selected application's implementation of its work-state contract; it cannot inspect arbitrary apps' unsaved state.

## Limits, revocation and handoff

Every external attempt requires fresh complete data, 60 seconds of fresh context after start/wake/discontinuity, an active exact permission and a durable audit reservation before a short-lived one-use permit is issued. Manual approval, self-repair and policy authority are recorded separately.

External limits are one intervention at a time, one attempt per episode, one per target per hour, and three per rolling 24 hours. Two failed attempts pause a rule until review. PID changes do not create a new application target allowance. Rule/executable/profile changes, expiry and revoked permissions block subsequent steps. Ambiguous interrupted attempts are marked Interrupted and never replayed after restart.

**Stop automation** is available in the dashboard, menu bar and Automation settings. It prevents further automatic steps, including a pending reopen. It cannot recall a SIGTERM or Quit request already sent. Manual Fix takes priority. Revoking a permission invalidates pending authority before its storage update.

Activity links the problem, attempt, exact Fix evidence, remaining condition and next decision. The existing three-sample check and five-minute observation distinguish process exit, target recovery and measured system improvement. A successful request alone does not close the problem episode or produce repeated success banners.

Always manual: Force Quit/SIGKILL; unregistered targets; uncertain identity; interactive work without a verified readiness contract; broader permissions; new sensitive OS privileges. Self/ancestor, other-user and system-process protections remain. No RAM purge, swap deletion, project/cache cleanup, SIGSTOP or blanket killall is provided.

## Local state and privacy

Existing SQLite schema-2 measurements and Fix history remain. Legacy settings get safe control defaults and a pre-v3 settings copy before their first update. External permissions do not turn on during migration. A separate atomic, owner-only `control-state.json` stores versioned control data; corrupt/future versions are preserved and block external automation.

Bounds: 128 episodes, 512 exact task labels, 500 activity entries, 64 permissions, 256 attempt records, 4096/one-hour origin cache entries, 128/4 MiB regenerated icon entries and a 4 MiB control-state file. A permission expires within 30 days. Historical usage and review breakers remain when ordinary history is cleared so that clearing a chart does not reset attempt limits.

Explicit restart arguments and private task labels stay local. Shareable Fix/recording/session reports omit private names, paths, identities and notes by default; a launch argument list is not included in those reports. Raw diagnostic exports and private-detail previews should still be reviewed before sharing.

The local build is ad-hoc signed and not App Sandbox restricted. No entitlement escalation is attempted if macOS refuses an operation. Developer ID signing/notarization and App Store sandbox distribution remain separate unverified work. See [Validation](VALIDATION.md) for checks actually completed and remaining limits.
