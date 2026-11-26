# Security

For a potential vulnerability, use [GitHub private vulnerability reporting](https://github.com/santiagoo43/MemorySentinel/security/advisories/new). Include the version, reproduction steps, expected impact and a minimal example. Do not put sensitive diagnostics, exploit details or personal data in a public issue.

There is no guaranteed response time. The latest public release is the recommended version; older versions do not have a separate maintenance commitment.

MemorySentinel is a local monitoring tool, not a security boundary. External automatic actions are off by default. An exact, expiring permission can authorize SIGTERM for a disposable task or normal Quit/reopen for a cooperative app. Automatic Force Quit is unavailable. Native actions recheck identity, ownership and application relationships, but the final POSIX check/signal race is not atomic. Force Quit can lose unsaved work.

The downloadable app is ad-hoc signed and not notarized. Check the release checksum and source before installing it. Do not disable system security protections to run it.

Exports may contain process names, executable paths, identities and memory measurements. Process arguments and environment variables are not collected. Explicit restart arguments supplied during registration are private automation settings/audit data; raw detailed diagnostics may include those specifications and other workspace information. Review it before sharing.

HTML/Markdown report previews use a shared form by default. That default shared form omits personal paths, process identities, user-defined names and private notes. Private details and notes have separate opt-in controls. JSON/CSV diagnostics retain their existing detailed semantics; review them separately. Reports are saved locally and are never automatically uploaded.

Profiles, learned ranges, recordings, work-session notes and Fix follow-ups stay in the local data directory. Recovery copies and exports remain on disk until explicitly removed. History quotas apply to logical payload; they do not include all backup and SQLite journal overhead. Restoring a pre-migration backup preserves the replaced database and leaves monitoring paused.

Automatic rules pin executable contents and file identity; they are not a defense against a malicious same-user process or every filesystem/exec race. Cooperative readiness trusts the chosen application to hold its declared idle/no-unsaved-work lease. Unknown work state, save prompts, refused Quit and timeout require human review; the app never accepts dialogs or escalates a failed normal request.
