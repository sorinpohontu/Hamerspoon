# ScheduledTask.spoon

Run commands and scripts on a schedule from Hammerspoon: every few minutes, at fixed times of day, or once at a random moment inside a time window.

**Version**: 2.2.0 · **Needs**: Hammerspoon only · **Changes**: [CHANGELOG.md](CHANGELOG.md)

## What you get

- **Three ways to schedule**: every N seconds/minutes/hours, at set times (`09:00`, `17:30`), or once at a random time within a window (`06:10`–`06:20`).
- **Limits**: only on certain days, or (for repeating tasks) only between certain hours.
- **Output where you want it**: appended to a log file, shown as an on-screen alert (always, or only when something fails), or handed to your own Lua function.
- **Reliable timing**: reloading Hammerspoon doesn't reset countdowns or run a task twice, and short delays (timer drift, a brief sleep) are caught up.
- **Optional menu bar menu** (a clock icon, with a dot while something runs) to see each task's status and last run, and switch tasks on or off.
- **Safe**: a task that runs too long is stopped after its timeout (5 minutes by default; SIGTERM, then SIGKILL if it doesn't exit). A task never runs twice at the same time, and its output kept in memory is capped (1 MB by default).

## Quick start

1. Make sure the `ScheduledTask.spoon` folder is in `~/.hammerspoon/Spoons/`.
2. Create `~/.hammerspoon/Spoons/ScheduledTask.spoon/config.lua`:
   ```lua
   return {
       showMenuBar = true,
       tasks = {
           {
               name = "cleanup",
               command = "/usr/local/bin/cleanup.sh",
               interval = "1h",
           },
       },
   }
   ```
   `config.lua.sample` has many more examples.
3. Add to `~/.hammerspoon/init.lua`:
   ```lua
   hs.loadSpoon("ScheduledTask")
   spoon.ScheduledTask:start()
   ```
4. Reload Hammerspoon.

The Spoon works on its own. It does not need any of the other Spoons in this repository.

## Scheduling a task

Every task needs a `name` (unique), a `command` (the **full path** to a program or script), and **one** way of scheduling.

### Every N seconds, minutes or hours

```lua
{ name = "sync", command = "/usr/local/bin/sync.sh", interval = "15m" }
```

`interval` accepts `"30s"`, `"15m"`, `"2h"`, or a number of seconds (`900`).

The first run is one interval after the task's last run, even across reloads. If that time has already passed, the task runs right away. A brand-new task waits one full interval.

### At set times of day

```lua
{ name = "report", command = "/usr/local/bin/report.sh", times = {"09:00", "12:30", "17:00"} }
```

Times use 24-hour `HH:MM`.

### Once at a random time inside a window

```lua
{
    name = "check-in",
    command = "/usr/local/bin/check-in.sh",
    timesRandom = {
        {start = "06:10", stop = "06:20"},   -- once between 6:10 and 6:20
        {start = "14:30", stop = "14:45"},   -- and once between 14:30 and 14:45
    },
}
```

- The task runs once per window per day, at a different moment each day, as long as Hammerspoon is running and the Mac is awake during the window (and the task isn't disabled or still running from before).
- A window can't cross midnight. Use two windows instead (`23:50`–`23:59` and `00:00`–`00:10`).
- Windows of one task must not overlap or share a minute (`09:00`–`09:30` and `09:30`–`10:00` is rejected; use `09:31`).
- If you run the task by hand while a window is open, that counts as the window's run.

### Only on some days

```lua
{ name = "weekday-backup", command = "/usr/local/bin/backup.sh", times = {"18:00"},
  days = {"Mon", "Tue", "Wed", "Thu", "Fri"} }
```

Full names or 3-letter abbreviations, in any case (`"monday"`, `"Mon"`, `"MONDAY"`).

### Only during certain hours (repeating tasks)

```lua
{ name = "office-check", command = "/usr/local/bin/check.sh", interval = "5m",
  timeWindow = {start = "09:00", stop = "17:00"} }
```

`timeWindow` may cross midnight, e.g. `{start = "22:00", stop = "06:00"}`.

## Arguments and environment

```lua
{
    name = "ask",
    command = "/Users/me/.local/bin/claude",
    args = {"--model", "haiku", "-p", "What day is today?"},
    times = {"09:00"},
}
```

- Each argument is passed exactly as written. Spaces need **no quoting**. (The old `quoted:` prefix still works; it is simply removed.)
- Commands are **not** run through a shell. For pipes, `$(...)` or wildcards, call the shell yourself:
  ```lua
  command = "/bin/sh", args = {"-c", "df -h / | tail -1"}
  ```
- `argsRandom` picks one set of arguments at random for each run (use either `args` or `argsRandom`):
  ```lua
  argsRandom = { {"--type", "incremental"}, {"--type", "full"} }
  ```
- Tasks get Hammerspoon's environment. `/opt/homebrew/bin`, `/usr/local/bin` and `~/.local/bin` are added to `PATH` (see `extraPath`). Add your own variables with `env = {API_URL = "https://…"}`.
- The task's input (stdin) is closed, so commands that would wait for typing don't hang.

## Getting the output

### Log file

```lua
{ name = "backup", command = "/usr/local/bin/backup.sh", interval = "1h",
  captureOutput = true, outputFile = "~/.hammerspoon/logs/backup.log" }
```

Each run appends the time, the command line, the output and the exit code. Create the folder first (`mkdir -p ~/.hammerspoon/logs`). If `notifyLines` is set, only that many lines are written.

### On-screen alert

```lua
captureOutput = true,
notify = true,          -- after every run
-- or: notifyOnError = true   -- only when the command fails (exit code not 0)
notifyLines = 3,        -- show the first 3 non-empty lines
notifyDelay = 2,        -- wait 2 seconds first (optional)
```

The alert shows for 3 seconds. Empty lines are skipped. Normal output comes first, then error output.

### Your own Lua code

```lua
onSuccess = function(stdout, stderr)
    hs.alert.show("Backup done")
end,
onError = function(exitCode, stdout, stderr)
    hs.notify.new({title = "Backup failed", informativeText = stderr}):send()
end,
```

Callbacks get the output even without `captureOutput`. An error inside a callback is logged and does no harm.

## Menu bar

With `showMenuBar = true`, a clock icon appears in the menu bar. It shows a small dot while any task is running, has the same size as the macOS icons, and adapts to light and dark menu bars. Its menu lists every task (sorted by name):

- **▶** running · **⏵** enabled, waiting · **⏸** disabled (in *italics*)
- Hover over a task to see its schedule, whether it's enabled, and its last run.
- Click a task to switch it on or off. This lasts until the next reload, when `config.lua` applies again.
- *Reload Config* reloads Hammerspoon.

The menu is built fresh each time you open it, so it always shows the current state.

## Reference

### Task settings

| Setting | Required | Default | What it does |
|---|---|---|---|
| `name` | yes | | Unique name |
| `command` | yes | | Full path to the program or script |
| `interval` | one of these three | | `"30s"`, `"5m"`, `"2h"` or seconds |
| `times` | | | `{"09:00", "17:00"}` |
| `timesRandom` | | | `{{start = "06:10", stop = "06:20"}, …}` |
| `args` | no | | Fixed arguments |
| `argsRandom` | no | | Several argument sets; one is picked per run |
| `env` | no | | Extra environment variables `{NAME = "value"}` |
| `days` | no | every day | `{"Mon", "Fri"}` |
| `timeWindow` | no | always | Hours for `interval` tasks: `{start = "09:00", stop = "17:00"}` |
| `enabled` | no | `true` | `false` keeps the task listed but never runs it |
| `timeout` | no | `300` | Seconds before a running task is stopped (SIGTERM, then SIGKILL after 5 s); `0` = no limit |
| `captureOutput` | no | `false` | Needed for `outputFile` and alerts |
| `outputFile` | no | | Log file; `~` means your home folder |
| `notify` | no | `false` | Alert after every run |
| `notifyOnError` | no | `false` | Alert only when the command fails |
| `notifyLines` | no | | Number of output lines in alerts and the log file |
| `notifyDelay` | no | `0` | Seconds to wait before the alert |
| `onSuccess` | no | | `function(stdout, stderr)` |
| `onError` | no | | `function(exitCode, stdout, stderr)` |

### Global settings

| Setting | Default | What it does |
|---|---|---|
| `enabled` | `true` | `false` keeps the Spoon loaded but inactive |
| `logLevel` | `"info"` | How much is written to the Console: `"debug"`, `"info"`, `"warning"`, `"error"` |
| `showMenuBar` | `false` | Show the clock menu |
| `showDisabledInMenu` | `true` | List disabled tasks in the menu |
| `showTaskCountInMenu` | `true` | Show "Tasks: N total, M enabled, K running" |
| `catchUpMinutes` | `5` | How many missed minutes to catch up (see How it works) |
| `extraPath` | Homebrew, `/usr/local/bin`, `~/.local/bin` | Folders added to the tasks' `PATH` |
| `maxOutputBytes` | `1048576` (1 MB) | Output kept per run (stdout + stderr). More is dropped, and the kept output ends with `[output truncated …]` |
| `tasks` | `{}` | The list of tasks |

Typos and wrong value types in the global settings are reported in the Console (Hammerspoon menu → *Console*) and ignored. A task with an unknown field (e.g. a typo like `tiemout`), a wrong type or an invalid value is **not added**; the Console says why.

### Lua functions

```lua
local st = spoon.ScheduledTask
st:addTask({ name = "x", command = "/bin/date", interval = 60 })  -- true/false; scheduled once started
st:runTaskNow("x")       -- run now, ignoring schedule and limits
st:disableTask("x")      -- until the next reload
st:enableTask("x")
st:removeTask("x")
st:stop()                -- stop timers, terminate running tasks (results discarded), remove the menu
st:start()               -- again after stop(): reschedules all tasks, including ones added from Lua
```

## How it works

- **Interval tasks** each have their own timer. The first run is due `lastRun + interval` (at least 1 s, at most one interval from now). After that, a repeating timer runs every `interval`.
- **Time and random-window tasks** share one timer that ticks at the start of every minute. Each tick handles every minute since the previous tick, up to `catchUpMinutes` (default 5). So timer drift or a short sleep doesn't skip a scheduled time, but tasks don't pile up after waking from a long sleep (the skip is logged).
- **Random windows** run with probability `1 / minutes left in the window` each minute. This spreads runs evenly and guarantees a run in the last minute. Randomness comes from Lua 5.4's `math.random`, which Lua seeds randomly at startup.
- **Last runs** (start times) are saved in `state.json` next to the Spoon, written to a temporary file and renamed, so a failed write never truncates it. Invalid entries are ignored with a warning. They are used to continue interval countdowns after a reload, and to know whether a time or window has already run today. This is best-effort de-duplication, not a guarantee of exactly-once execution.
- **Running a task**: `hs.task` with the arguments passed directly (no shell), the working directory set to your home folder, stdin closed (`closeInput()`), and Hammerspoon's environment plus `TERM=dumb`, `CI=true`, `extraPath` and `env`.
- **Output** is collected as it arrives. `hs.task` may deliver the last piece *after* reporting that the process ended, so the Spoon waits for that piece (or 0.5 s) before writing the log, showing the alert or calling your callback.
- **Each run has its own record** (process, timeout, output, generation). Only that run's callbacks change its state, so a late exit of an earlier run can't affect a newer one.
- **Timeouts** belong to each run and are cancelled when the run ends. A run past its timeout gets SIGTERM, then SIGKILL after 5 seconds if it is still running. Until the process has really exited, the task counts as running and won't start again.
- **stop()** terminates running tasks and discards their results: no log file entry, alert or callback after `stop()`. Pending delayed alerts are cancelled. A second `start()` does nothing; `start()` after `stop()` reschedules every registered task.
- **Output limit**: at most `maxOutputBytes` of output is kept per run; the rest is counted and reported in a note at the end.
- **Duplicate task names** in `config.lua` are reported. The enabled definition wins; if both or neither are enabled, the last one wins.
- **Menu bar icon**: a template image drawn with `hs.canvas` on the standard 18×18 pt grid at 2× resolution. The "running" dot clears a small gap in the clock outline (`compositeRule = "clear"`).
- Config is read when the Spoon is loaded (`init()`). When `enabled = false`, `start()` does nothing.

## Troubleshooting

- **A task never runs**: check the Console for errors about its definition. Make sure `command` is a full path (`/usr/local/bin/x`, not `x`), the file is executable (`chmod +x`), and `days` / `timeWindow` allow the current time.
- **"command not found" inside a script**: the script's own commands are looked up in `PATH`. Add their folder to `extraPath`, or use full paths in the script.
- **Shell syntax doesn't work** (`|`, `>`, `$(...)`, `*`): run it through `/bin/sh -c` (see *Arguments and environment*).
- **Nothing is written to the log file**: set `captureOutput = true` and make sure the folder exists.
- **The task is stopped early**: raise `timeout`, or set it to `0`.
- **More detail**: set `logLevel = "debug"` in `config.lua` and watch the Console.

## License

BSD-3-Clause · Sorin Pohontu <sorin@frontline.ro>
