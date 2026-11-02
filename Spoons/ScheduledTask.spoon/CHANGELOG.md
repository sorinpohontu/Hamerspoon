# ScheduledTask.spoon Changelog

All notable changes to ScheduledTask.spoon are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.2.0] - 2026-10-22

A reliability release: tasks run when they should, once, and with all of their output.

### Fixed
- **A stopped run can no longer interfere with a new one.** Each run now has its own record; an earlier run's late exit could cancel a newer run's timeout. After `stop()`, a task stays "running" until its process has really exited, so runs never overlap.
- **Timeouts now really end a task**: SIGTERM, then SIGKILL after 5 seconds if it is still running. Before, a task that ignored SIGTERM blocked all later runs.
- **`stop()` cancels everything**: results of terminated runs are discarded (no log entry, alert or callback after stop) and delayed alerts are cancelled.
- **Tasks added from Lua survive `stop()` / `start()`**, and a second `start()` no longer re-adds tasks. `enableTask()` restores a missing schedule.
- **Invalid task definitions are rejected up front** instead of failing later: unknown fields (typos), wrong types (e.g. `timeout = "10"`), non-finite numbers, bad `env` entries, `addTask(nil)`. Global `catchUpMinutes`, `extraPath` and `maxOutputBytes` are range-checked.
- **Overlapping random windows are rejected** with a clear message; before, a window inside another one never ran.
- **`state.json` is safer**: invalid entries are ignored with a warning (a text timestamp used to break scheduling), and it is written via a temporary file and rename, so a failed write can't truncate it.
- **`enabled = false` in `config.lua` now works.** Before, it was ignored and the Spoon always started.
- **Timeouts no longer interfere between runs.** A timeout left over from an earlier run could make the Spoon "forget" a later run: that run was not stopped when it should have been, and could overlap with the next one.
- **`timeout = 0` now means "no limit".** It used to stop the task the moment it started.
- **Output is no longer cut off.** The last piece of a command's output could arrive after the log file was written or the alert was shown.
- **Scheduled times are no longer skipped.** The minute timer slowly drifted and could miss a `times` entry, or the last minute of a random window. Missed minutes are now caught up.
- **Reloading no longer resets countdowns.** An `interval = "24h"` task never ran if Hammerspoon was reloaded more often than once a day.
- **No double runs after a reload.** Reloading during a random window, or in the minute of a `times` entry, could run the task again.
- **The menu shows the real status.** Finished tasks kept showing as running.
- **Numbers in `args` no longer break scheduling.** They are converted to text; other wrong types are rejected with a clear message.
- `outputFile` only expands a leading `~`, and errors inside `onSuccess` / `onError` are caught and logged.

### Changed
- **Commands no longer go through a shell.** Arguments are passed exactly as written, so spaces need no quoting and `quoted:` is no longer needed (it still works). Before, one `quoted:` argument made all the *other* arguments open to shell interpretation. Use `/bin/sh -c` when you want shell features.
- **Tasks keep Hammerspoon's environment** (language, temp folder, etc.) instead of getting only six variables. Homebrew, `/usr/local/bin` and `~/.local/bin` are added to `PATH`.
- "Last run" is now when a run *started* (it was when it finished).
- Stricter checks with clear messages: times must be real (`00:00`–`23:59`), random windows can't cross midnight, day names are checked (and may now be abbreviated, in any case).
- Random choices use Lua's built-in generator instead of starting an extra process every minute.
- Menu items are sorted by name.
- `start()` does nothing when `enabled = false`, so the Spoon behaves the same whether it is started by the main `init.lua` or by you.

### Added
- `maxOutputBytes` setting (default 1 MB): output kept per run; more is dropped with a `[output truncated …]` note, so a noisy task can't use unbounded memory.
- **New menu bar icon**: a clock that matches the macOS icons (size, light and dark mode), with a dot while a task is running. It replaces the `⏱` character.
- `enabled`, `catchUpMinutes` and `extraPath` settings.
- `env` task setting for extra environment variables.
- `timeWindow` may cross midnight (e.g. `22:00`–`06:00`).
- `onSuccess` / `onError` receive the output even without `captureOutput`.
- Typos and wrong value types in `config.lua` are reported in the Console.

### Removed
- `showNotifications` setting (it never did anything; alerts are set per task).

### Technical notes
- Review fixes (REV-1, 4, 5, 6, 8, 9, 10, 11 in `docs/CODE_REVIEW-2026-10-22.md`): per-run records with a generation counter; `addTask()` before `start()` only registers; `KILL_GRACE` = 5 s.
- Config is read in `init()`; scheduling happens in `start()`.
- Output is collected only from the `hs.task` stream callback. It is processed when the final chunk arrives (stream callback with `task == nil`), or 0.5 s after the termination callback.
- The minute timer is aligned to `:00`, and each tick processes `(lastCheckedMinute, now]`, capped at `catchUpMinutes`.
- Whether a time or window has already run comes from the persisted `lastRun` (start time), not from in-memory tables.
- Removed `_secureRandom()` (one `od /dev/urandom` process per call, on the main thread) and the reseeding of `math.random`. Hammerspoon's Lua 5.4 seeds it randomly.

## [2.0.0] - 2025-12-17

### Changed
- **Breaking:** the setting `randomTimes` is now called `timesRandom`, to match `times`. Rename it in your `config.lua`.
- Random choices used system randomness (`/dev/urandom`). Replaced in 2.2.0.

## [1.8.1] - 2025-12-17

### Fixed
- `argsRandom` sometimes picked the same argument set several times in a row.

## [1.8.0] - 2025-12-17

### Added
- `notifyOnError`: show an alert only when a task fails.

## [1.7.1] - 2025-12-17

### Fixed
- Attempted fix for repeated `argsRandom` picks (replaced in 1.8.1).

## [1.7.0] - 2025-12-15

### Changed
- Random windows pick their moment while the window is open, instead of at startup, so run times are no longer visible in advance in the log.

## [1.6.0] - 2025-12-15

### Added
- Duplicate task names in `config.lua` are detected and reported. The enabled definition wins.

## [1.5.0] - 2025-12-14

### Added
- `showDisabledInMenu` and `showTaskCountInMenu` settings.

## [1.4.0] - 2025-12-13

### Added
- Menu shows enabled tasks in bold and disabled ones in italics. Tooltips show status and last run.

## [1.3.0] - 2025-12-12

### Added
- `argsRandom`: pick a random set of arguments for each run.

## [1.2.0] - 2025-12-11

### Added
- ⏱ menu bar menu with task status, last run, on/off toggle and *Reload Config* (`showMenuBar`).

## [1.1.0] - 2025-12-11

### Added
- `times`: run at set times of day.
- Random time windows: run once per window at a random moment.
- `timeWindow`: limit repeating tasks to certain hours.
- `onSuccess` / `onError` callbacks.

## [1.0.0] - 2025-12-11

### Added
- First release: repeating tasks, day filter, arguments, timeouts, output to a log file, on-screen alerts with the first lines of output, and Lua functions to add, remove, enable, disable and run tasks.
