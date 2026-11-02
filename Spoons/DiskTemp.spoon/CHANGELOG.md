# DiskTemp.spoon Changelog

All notable changes to DiskTemp.spoon are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.3.0] - 2026-10-22

Faster, works with more disks, and notices disks you plug in later.

### Fixed
- **A stuck disk read can no longer block updates forever.** At the timeout the update finishes without that reading; the command gets SIGTERM, then SIGKILL after 5 seconds, and its late result is ignored.
- **`stop()` cancels running reads and the pending install dialog**; results that arrive afterwards no longer log warnings or show alerts.
- The sample `config.lua` no longer turns off auto-detection (`diskDevices` is now a commented example) and lists `commandTimeout`.
- **Hammerspoon no longer freezes while disks are read.** Disk reads used to block everything (hotkeys, menus, timers) every 15 seconds, for seconds at a time with slow or spinning-up disks. They now run in the background.
- **SATA and many USB disks now show a temperature** instead of `N/A`. Before, only NVMe disks were read correctly.
- **Disks plugged in after Hammerspoon started now appear.** Before, if no disk was connected at startup, the Spoon never looked again.
- The Console is no longer flooded with a warning every 15 seconds for a disk without temperature data.
- `temperatureUnit`, `smartctlPath` and `showAlerts` can now really be set in `config.lua` (they were documented but ignored).

### Added
- **Help when `smartctl` is missing**: a dialog explains how to install it with Homebrew and can copy the command (`warnMissingSmartctl` to turn it off).
- The menu bar item hides while no disk is connected.
- `smartctlArgs` (e.g. `{"-A", "-d", "sat"}` for USB enclosures), `commandTimeout` and `logLevel` settings.
- Typos and wrong value types in `config.lua` are reported in the Console.

### Changed
- List and number settings are checked (`diskDevices` and `smartctlArgs` must be lists of strings, `updateInterval` >= 1, `commandTimeout` > 0).
- `configFile` is no longer a public variable (it could not be changed before the config was read anyway).
- A second `start()` does nothing.
- Reads only SMART attributes (`smartctl -A`) instead of the full report (`--all`).
- `start()` does nothing when `enabled = false`, so the Spoon behaves the same whether it is started by the main `init.lua` or by you.

## [2.2.0]

### Added
- `enabled` setting to keep the Spoon loaded but inactive.

### Changed
- Settings are read when the Spoon is loaded.

## [2.1.0]

### Added
- Short disk labels (`D4|45°`), shown only when several disks are monitored.
- Disk detection is cached briefly; clicking the menu bar item refreshes it.

## [2.0.0] - 2024-11-30

### Added
- Automatic detection of external disks.
- Optional `config.lua`.
- Several disks at once, with configurable separator and labels.

## [1.0.0]

### Added
- First release: temperature of one disk in the menu bar.
