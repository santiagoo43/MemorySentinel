<p align="center"><img src="Documentation/Assets/AppIcon.png" width="96" alt="MemorySentinel icon"></p>

# MemorySentinel

A native macOS memory monitor for ChatGPT, Codex and their related processes. It keeps an eye on system pressure, swap and process growth, with a menu bar view for quick checks and a dashboard for the details.

**Version 1.3.0** adds quieter alerts, explicitly registered automatic repairs and application/task identities for generic processes. Get the [1.3.0 release](https://github.com/santiagoo43/MemorySentinel/releases/tag/v1.3.0) or see the [changelog](CHANGELOG.md) for the full list.

[Download the latest release](https://github.com/santiagoo43/MemorySentinel/releases/latest) · [Installation](Documentation/INSTALLATION.md) · [Manual Fix guide](Documentation/FIX.md)

## What it does

- Samples real Darwin memory counters every five seconds by default.
- Identifies apps and helpers using bundle IDs, executable paths and verified ancestry. A process name alone does not make a generic `node` or `python` process part of Codex.
- Shows footprint, RSS, growth trends, pressure, swap, free storage and an incident timeline.
- Keeps ordinary warnings visible without repeated banners. Smart alerts track persistent issues and reserve urgent notifications for critical pressure or a decision that needs attention.
- Separates a process's application, verified launcher and optional task name, including generic `python` and `node` runtimes.
- Repairs its own monitoring and offers opt-in external actions with exact, expiring permissions, usage limits and **Stop automation**. External actions start off; Force Quit stays manual.
- Offers a manual **Fix…** workflow: fresh assessment, one concrete approval, then measured results.
- Keeps monitoring when the dashboard is closed. **Simulation Mode** exercises the same analyzer without creating memory pressure or sending real process actions.
- Stores bounded history locally and exports JSON or CSV. No telemetry, account or server is needed.
- Work profiles keep exact watch rules, notification preferences and advisory application/group budgets.
- Application cards show version-aware normal ranges, data quality and conditional time-to-budget estimates.
- Flight recordings retain available lead-in, subsequent measurements and event markers for a shared-cursor review.
- Named work sessions compare time-weighted memory, coverage, pressure time and warning rates.
- Five-minute Fix follow-ups separate sustained observations from the original immediate result.
- Local HTML and Markdown reports provide a privacy-focused preview before saving.

Footprint and RSS are different accounting measures. Group totals can overlap shared memory; they are not a count of unique physical RAM. Growth is a warning signal, not proof of a leak.

## Requirements

The downloadable app is for **Apple Silicon Macs running macOS 14 or later**. Source builds need Swift 6 and the macOS SDK, supplied by Xcode or compatible Command Line Tools. There are no third-party package dependencies.

The deployment target is macOS 14; the tested environments are listed in [Validation](Documentation/VALIDATION.md). Intel and universal downloads are not provided.

## Install

1. Download `MemorySentinel-macOS-arm64.zip` and `SHA256SUMS` from the same [release](https://github.com/santiagoo43/MemorySentinel/releases/latest).
2. Verify the checksum, unzip the archive, then move **MemorySentinel.app** to Applications or `~/Applications`.
3. Open the app. Allow notifications if you want urgent system alerts; ordinary warnings stay in the dashboard by default.

The release is **ad-hoc signed, not Developer ID signed or notarized**. macOS may require a user-approved first launch. See [Installation](Documentation/INSTALLATION.md) for verification and first-launch steps; do not disable Gatekeeper.

## Use

- **Overview** shows the current risk and memory timeline. The menu bar gives a compact view.
- **Processes** shows the application, verified launcher, optional task name and technical runtime. Search or group by application. **Name this task…** grants no action; **Register managed task…** creates a separate exact permission.
- **Fix…** opens a plan; it does not stop anything. App Quit is the normal macOS request. **Quit and reopen** waits for the old instance to exit. **Force Quit** always has its own confirmation.
- Results separate action completion, the target problem and system improvement. A remaining warning or missing reading is not hidden.
- **Incidents** includes recorded Fix evidence. An old incident is reassessed using current data before any action.
- **Activity** collects current issues, handoff reasons and separate manual, automatic, self-repair and notification decisions.
- **Settings → Automation** lists permissions, outcomes and limits. **Stop automation** is also available in the dashboard and menu bar.
- **Settings** controls the interval, exact watch rules, thresholds, Smart notifications, appearance and retention.
- **Simulation → Simulation Mode** enables synthetic scenarios. Use **Return to live** when finished.
- **Profiles** edits the active work context; the menu bar can switch profiles too.
- **Recordings → Record now** captures the available lead-in and subsequent samples. Captures can be partial or expire under storage limits.
- **Sessions → Start…** records a named work session. Select another session under **Compare with** to overlay their measured timelines.

See [Notifications, task identity and automation](Documentation/AUTOMATION.md) for permissions, safe defaults and cooperative application limits.

See [Profiles, recordings, sessions and reports](Documentation/WORKFLOWS.md) for learning conditions, forecast limits, scoped snoozes, follow-up interpretation and recovery.

Save your work before approving a process action. An app can refuse Quit or show a save prompt. Reopening cannot guarantee restoration of its previous session. External automatic actions are off by default. An exact, explicit permission can authorize a disposable task stop/restart or a cooperative app restart. Force Quit always needs a new manual confirmation; there is no Fix All.

## Build and test

```sh
git clone https://github.com/santiagoo43/MemorySentinel.git
cd MemorySentinel
swift build -c release
zsh Scripts/test.sh
zsh Scripts/build-app.sh
open build/MemorySentinel.app
```

The packaging script creates `build/MemorySentinel.app` and an architecture-named ZIP under `build/`; it does not install over your running copy. Quit a previously opened build before rebuilding its bundle. Output locations can be overridden with `SENTINEL_OUTPUT_DIR` and `SENTINEL_ARCHIVE_PATH`.

The test runner is a standalone Swift executable. It includes native AppKit integration tests using a disposable, uniquely identified test app. Those tests need a working logged-in macOS graphical session; they are not silently skipped in CI.

Optional checks:

```sh
xcrun swift-format lint --strict --recursive Sources Tests Package.swift Scripts/make-icon.swift
xcrun clang --analyze Sources/CSystem/CSystem.c -I Sources/CSystem/include -o build/CSystem.plist
xcrun clang --analyze Sources/CSystem/Cooperative.c -I Sources/CSystem/include -o build/Cooperative.plist
swift run -c release sentinel-diagnostics --duration 10 --interval 5
```

The diagnostic command prints local process names, identities and memory readings. Review its output before sharing it. A direct compiler build is also available with `zsh Scripts/build-direct.sh --tests`; its output goes to `~/Library/Caches/MemorySentinel/DirectBuild/`.

## Local data and removal

Settings and history live in `~/Library/Application Support/MemorySentinel/`. **Settings → Data** opens that folder, exports diagnostics and offers a separately confirmed history deletion.

Version 1.3 also keeps bounded episodes, task labels, permissions and usage records in a separate owner-only `control-state.json`; external actions default off for an upgrade.

SQLite schema 2 adds bounded experience storage. Migration creates a consistent `history.pre-v2.sqlite` backup; the first settings update preserves legacy settings as `settings.pre-v2.json` when a legacy settings file exists. **Profiles → Storage and recovery** offers a recovery snapshot and explicit pre-migration restore controls. Restoring history pauses sampling and preserves the replaced database separately.

To uninstall, turn off **Launch at login** if enabled, quit MemorySentinel and move the app to Trash. The data folder and any exports remain until you remove them yourself. See [Installation](Documentation/INSTALLATION.md#uninstall).

## Limits

- Some protected-process metrics are unavailable. Missing data remains unavailable and cannot prove recovery.
- System used/available values are estimates. A drop in footprint is not a promise of the same amount of unique RAM being released; swap may stay high after an app exits.
- The local ad-hoc build may report **App service not found** for launch at login. That state is not treated as a successful registration.
- The final POSIX identity-check/signal race cannot be made atomic with these APIs. System processes, other users, the watchdog and its ancestors are protected.
- Full compatibility, accessibility and long-duration validation have limits; see [Validation](Documentation/VALIDATION.md).

[Architecture](Documentation/ARCHITECTURE.md) · [Contributing](CONTRIBUTING.md) · [Security](SECURITY.md)

## License

[MIT](LICENSE) — Gergely Kristóf Pál.
