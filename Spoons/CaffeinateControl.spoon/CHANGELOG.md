# CaffeinateControl.spoon Changelog

All notable changes to CaffeinateControl.spoon are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.2.0] - 2026-10-22

Staying awake now survives locking the screen, as it was always meant to.

### Fixed
- **Lock and screensaver are tracked separately**: ending the screensaver while the screen is still locked no longer switches caffeinate back on. If Hammerspoon starts while the screen is locked, caffeinate starts suspended.
- **A second `start()` no longer resets your choice**, and your choice is kept across `stop()` / `start()` (`startCaffeinated` applies to the first start only).
- **Caffeinate is restored after you unlock.** Before, locking the screen switched it off for good, and you had to click the icon again after every lock.
- **No more alert pop-ups on every lock and unlock.** Alerts appear when you click the icon (and once at startup, if `showAlerts` is on).
- `stop()` now allows sleep again, instead of leaving the Mac awake with no icon to switch it off.

### Added
- **New menu bar icon that shows the state**: a steaming cup when on, a dimmed cup when off. It replaces the old icon, which rendered as a `#`, and matches the size and style of the macOS icons in light and dark mode.
- `menuIconOff` setting for a custom "off" icon.
- The icon's tooltip shows whether caffeinate is on or off.
- `isCaffeinated()` method.
- `config.lua.sample`. Typos and wrong value types in `config.lua` are reported in the Console.

### Changed
- `start()` does nothing when `enabled = false`, so the Spoon behaves the same whether it is started by the main `init.lua` or by you.

## [1.1.0]

### Added
- Optional `config.lua` for `startCaffeinated`, `showAlerts`, `logLevel` and `menuIcon`.
- `enabled` setting to keep the Spoon loaded but inactive.

## [1.0.0]

### Added
- First release: menu bar toggle for sleep prevention, paused while the screen is locked.
