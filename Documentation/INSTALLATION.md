# Installation

## Download and verify

The prebuilt release requires an Apple Silicon Mac and macOS 14 or later.

Version [1.3.0](https://github.com/santiagoo43/MemorySentinel/releases/tag/v1.3.0) adds Smart notifications, exact task identity and opt-in automatic repairs. External actions start off after an upgrade. See [the automation guide](AUTOMATION.md) and [workflow guide](WORKFLOWS.md).

1. Open the [latest release](https://github.com/santiagoo43/MemorySentinel/releases/latest).
2. Download both `MemorySentinel-macOS-arm64.zip` and `SHA256SUMS` from that release.
3. With both files in the same folder, run:

```sh
cd ~/Downloads
shasum -a 256 -c SHA256SUMS
```

The ZIP must report `OK`. If the checksum differs, do not open it; download a fresh copy from the release.

Unzip it with Finder, then move **MemorySentinel.app** to `/Applications` or `~/Applications`. Quit an older copy before replacing it. Open the app from its installed location.

## First launch

This release is ad-hoc signed. It has no Developer ID certificate or Apple notarization ticket. The signature checks bundle integrity; it does not establish a verified developer identity.

If macOS blocks an unidentified developer, review the source and checksum first. If you choose to proceed, use the normal user-approved option in **System Settings → Privacy & Security**, then reopen the app. Do not disable Gatekeeper or use blanket quarantine-removal commands. If macOS reports malware, modification or damage, stop and investigate rather than bypassing that warning. Building from source is an alternative.

Basic monitoring does not require administrator, Accessibility, Screen Recording or Full Disk Access permission. macOS can withhold individual protected-process readings. Grant notification permission if you want urgent native alerts (ordinary warnings stay visual by default); this can be changed in **System Settings → Notifications → MemorySentinel**.

The dashboard can be closed while the menu bar monitor keeps running. Quit MemorySentinel to stop monitoring. Launch at login uses the macOS app-service mechanism; a local ad-hoc build may show **App service not found**. That is a known limitation, not an enabled login item.

## Build from source

Install compatible Xcode or Command Line Tools with Swift 6, then follow the [README commands](../README.md#build-and-test). The build script stages the app under `build/` and signs it ad hoc. Copy the resulting app to Applications yourself after quitting any older copy.

The repository has no third-party Swift package dependencies. Release archives are Apple Silicon only; other build architectures are not validated for distribution.

If code signing reports resource forks or Finder information in a cloud-synced checkout, build outside that synced folder, or set `SENTINEL_OUTPUT_DIR` to a nonsynced directory. Sync software can add metadata to an otherwise signed app bundle.

## Data

`~/Library/Application Support/MemorySentinel/` contains `settings.json`, the SQLite history database and its related files. Corrupt database backups are retained for recovery. Exports are saved where you choose and may contain sensitive process paths.

**Settings → Data → Delete all history…** asks for confirmation before clearing local history. It preserves settings, exact task labels, permissions and attempt-limit records; revoke permissions separately under Automation. It does not remove projects, downloads or exports.

On the first 1.2 launch, history migrates transactionally to schema 2 after a consistent `history.pre-v2.sqlite` backup. Updating legacy settings first preserves `settings.pre-v2.json`. Keep enough free storage for both the live data and recovery copies. **Profiles → Storage and recovery** provides a consistent recovery snapshot and pre-migration restore controls. Restoring history or clearing it drains sampling first and leaves monitoring paused; resume it when ready. The database being replaced is preserved as `history.before-restore.sqlite`.

Version 1.3 keeps SQLite schema 2. Its separate, bounded `control-state.json` stores episodes, notification reservations, private task names, rules and attempt audit. The first legacy settings update keeps `settings.pre-v3.json`; external actions default off and no task is registered automatically. An unsupported or corrupt control file is preserved and disables external automation.

## Uninstall

1. Turn off **Settings → General → Launch at login** if it was enabled.
2. Quit MemorySentinel and move the app to Trash.
3. If you also want to remove settings and history, remove `~/Library/Application Support/MemorySentinel/` after quitting. Keep a backup first if needed. Remove exports separately.

The app does not delete its data folder automatically on uninstall. Backups or exports kept outside that folder also remain; review those separately if reclaiming disk space.
