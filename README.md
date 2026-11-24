<p align="center"><img src="Documentation/Assets/AppIcon.png" width="96" alt="MemorySentinel icon"></p>

# MemorySentinel

A native macOS memory monitor for ChatGPT, Codex and their related processes. It keeps an eye on system pressure, swap and process growth, with a menu bar view for quick checks and a dashboard for the details.

[Download the latest release](https://github.com/santiagoo43/MemorySentinel/releases/latest) · [Installation](Documentation/INSTALLATION.md) · [Manual Fix guide](Documentation/FIX.md)

## What it does

- Samples real Darwin memory counters every five seconds by default.
- Identifies apps and helpers using bundle IDs, executable paths and verified ancestry. A process name alone does not make a generic `node` or `python` process part of Codex.
- Shows footprint, RSS, growth trends, pressure, swap, free storage and an incident timeline.
- Offers a manual **Fix…** workflow: fresh assessment, one concrete approval, then measured results.
- Keeps monitoring when the dashboard is closed. **Simulation Mode** exercises the same analyzer without creating memory pressure or sending real process actions.
- Stores bounded history locally and exports JSON or CSV. No telemetry, account or server is needed.

Footprint and RSS are different accounting measures. Group totals can overlap shared memory; they are not a count of unique physical RAM. Growth is a warning signal, not proof of a leak.

## Requirements

The downloadable app is for **Apple Silicon Macs running macOS 14 or later**. Source builds need Swift 6 and the macOS SDK, supplied by Xcode or compatible Command Line Tools. There are no third-party package dependencies.

The deployment target is macOS 14; the tested environments are listed in [Validation](Documentation/VALIDATION.md). Intel and universal downloads are not provided.

## Install

1. Download `MemorySentinel-macOS-arm64.zip` and `SHA256SUMS` from the same [release](https://github.com/santiagoo43/MemorySentinel/releases/latest).
2. Verify the checksum, unzip the archive, then move **MemorySentinel.app** to Applications or `~/Applications`.
3. Open the app. Allow notifications if you want system warning banners.

The release is **ad-hoc signed, not Developer ID signed or notarized**. macOS may require a user-approved first launch. See [Installation](Documentation/INSTALLATION.md) for verification and first-launch steps; do not disable Gatekeeper.

## Use

- **Overview** shows the current risk and memory timeline. The menu bar gives a compact view.
- **Processes** lets you search, sort and inspect a process and its helpers.
- **Fix…** opens a plan; it does not stop anything. App Quit is the normal macOS request. **Quit and reopen** waits for the old instance to exit. **Force Quit** always has its own confirmation.
- Results separate action completion, the target problem and system improvement. A remaining warning or missing reading is not hidden.
- **Incidents** includes recorded Fix evidence. An old incident is reassessed using current data before any action.
- **Settings** controls the interval, exact watch rules, thresholds, notifications, appearance and retention.
- **Simulation → Simulation Mode** enables synthetic scenarios. Use **Return to live** when finished.

Save your work before approving a process action. An app can refuse Quit or show a save prompt. Reopening cannot guarantee restoration of its previous session. There is no automatic termination or Fix All.

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
swift run -c release sentinel-diagnostics --duration 10 --interval 5
```

The diagnostic command prints local process names, identities and memory readings. Review its output before sharing it. A direct compiler build is also available with `zsh Scripts/build-direct.sh --tests`; its output goes to `~/Library/Caches/MemorySentinel/DirectBuild/`.

## Local data and removal

Settings and history live in `~/Library/Application Support/MemorySentinel/`. **Settings → Data** opens that folder, exports diagnostics and offers a separately confirmed history deletion.

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
