# SqueezeliteManager.spoon Changelog

All notable changes to SqueezeliteManager.spoon are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.0.0] - 2026-10-22

Music now keeps playing while Hammerspoon reloads, the Spoon remembers whether you left it playing, and a new menu bar icon matches the macOS icons.

### Breaking changes
- **The Spoon's `stop()` no longer stops the music.** Squeezelite now runs on its own, so it keeps playing across reloads; use `stopSqueezelite()` to stop playback.
- **The menu bar shows a player icon instead of the `▶` / `▮▮` text.** To keep the text, set `playIcon = "▶"` and `pauseIcon = "▮▮"` in `config.lua`.
- **`autoStart` only applies when nothing is remembered.** With the new `rememberState` (on by default), the last state wins after a reload or restart.

### Added
- **Playback survives reloads**: Squeezelite runs in the background, independent of Hammerspoon, and the Spoon reconnects to it afterwards.
- **Remembers playing/stopped** across reloads and restarts (`rememberState`).
- **Player icon modelled on the Squeezelite app icon**: device, display and grille; level bars while playing, dimmed while stopped. Same 18 pt size as the macOS icons, and adapts to light and dark menu bars.
- **Squeezelite's messages are saved** to `~/.hammerspoon/logs/squeezelite.log` (`logFile`, rotated at 1 MB). When Squeezelite stops on its own, the alert shows its last message.
- **The player is named after your Mac by default** (`playerName`); a `-n` in `squeezeliteArgs` still takes priority.
- Tooltip showing the state; `logLevel` setting; typos and wrong value types in `config.lua` are reported in the Console.

### Fixed
- **No more races between restore, start and stop.** One state machine runs one operation at a time; clicks during an operation are remembered and applied afterwards. Before, a click during the restore check could start a second player, and stop could target the wrong one.
- **Stopping is verified**: the process's identity (exact binary name and start time) is checked right before signalling; SIGTERM is followed by SIGKILL if needed, and "stopped" is reported only once it has exited. A stale PID is never signalled; a failed stop keeps tracking the player and says so.
- **"Started" is reported only when the player is confirmed running**; a player that exits right away (e.g. wrong output device) is reported as a failed start, with the log's last line.
- **Helper commands can't hang the Spoon**: `sh`, `ps` and `kill` have a 10-second deadline. If `ps` can't run, a saved PID is neither adopted nor duplicated.
- **Log setup failures are handled**: nested log folders are created, and an unwritable log path falls back to discarding output with a warning.
- A second `start()` no longer restores twice.
- **Squeezelite can no longer freeze when it writes a lot of output.** As a Hammerspoon child process its output had nowhere to go, and Hammerspoon's docs warn the process is suspended once that buffer fills. Output now goes to the log file.
- **Stopping and quickly starting again no longer confuses the button.** A late "process exited" message from the old Squeezelite used to reset the new one, so the button showed ▶ while music played, and the next click could start a second copy.
- A Squeezelite that keeps crashing is not restarted on every reload.

### Changed
- `checkInterval` default is 5 seconds (was 2).
- Settings are read when the Spoon is loaded, and `start()` does nothing when `enabled = false`, so the Spoon behaves the same whether it is started by the main `init.lua` or by you.

### Technical notes
- Review fixes (REV-2, 3, 4, 12 in `docs/CODE_REVIEW-2026-10-22.md`): states restoring/starting/running/stopping/stopped, `wanted` reconciled after each operation, generation counter for `stop()`; identity via `ps -o lstart= -o comm=` (saved as `SqueezeliteManager.pidStart`).
- Started via `/bin/sh -c 'log="$1"; shift; nohup "$@" </dev/null >>"$log" 2>&1 & echo $!'`, with the binary and arguments as positional parameters.
- PID and last state are kept in `hs.settings` (`SqueezeliteManager.pid`, `SqueezeliteManager.running`). Liveness is checked with `ps -p <pid> -o comm=` (matching the binary name, to guard against PID reuse); stopping is `kill -TERM <pid>`.
- Icons are `hs.canvas` drawings rendered at 2× and resized to 18×18 pt template images.

## [1.3.0]

### Added
- `enabled` setting to keep the Spoon loaded but inactive.

## [1.2.0] - 2025-12-13

### Added
- Optional `config.lua` (see `config.lua.sample`) for all settings.
- README and this changelog.

## [1.1.0]

### Added
- Menu bar toggle for Squeezelite with process monitoring, alerts and custom icons.
