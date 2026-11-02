# WindowManager.spoon Changelog

All notable changes to WindowManager.spoon are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.3.0] - 2026-10-22

Settings are more forgiving, the right half fits the screen exactly, and the Spoon can be used on its own.

### Fixed
- **A malformed hotkey entry no longer stops the other hotkeys**: each action is bound separately; bad entries and unknown action names are reported in the Console. `frameOffset` values must be finite numbers.
- **Right-half windows no longer stick out past the screen edge.** The width now accounts for the gap between halves.
- **Changing one gap value no longer breaks window moves.** `frameOffset = {y = 0}` used to remove the other values and cause an error; values are now merged with the defaults.
- **A one-item hotkey list now works** (`halfLeft = {{{"cmd"}, "["}}` used to be ignored silently).
- **A wrong key name no longer stops the other hotkeys** (or the other Spoons) from loading; it is reported in the Console.
- Old hotkeys are now deleted, not just disabled, when hotkeys are re-bound or the Spoon stops.
- The Console no longer shows a misleading "Stopping WindowManager" each time the Spoon starts.

### Added
- `logLevel` setting.
- Typos and wrong value types in `config.lua` are reported in the Console.

### Changed
- `start()` does nothing when `enabled = false`, so the Spoon behaves the same whether it is started by the main `init.lua` or by you.

## [1.2.0]

### Added
- Optional `config.lua` (see `config.lua.sample`) for alerts, gaps and hotkeys.
- `enabled` setting to keep the Spoon loaded but inactive.

### Changed
- The gap between halves is now the configurable `frameOffset.x` instead of a fixed 2 pixels.

## [1.1.0]

### Added
- Several hotkeys per action (e.g. `⌘⌥⌃C` and `F16` both center a window).
- Configurable gaps around windows (`frameOffset`).

## [1.0.0]

### Added
- First release: center, top right, left half, right half and full desktop, each with a hotkey and an on-screen alert.
