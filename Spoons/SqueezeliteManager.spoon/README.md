# SqueezeliteManager.spoon

Start and stop the [Squeezelite](https://github.com/ralph-irving/squeezelite) audio player from the menu bar, so your Mac can play music from a Lyrion (Logitech) Media Server.

**Version**: 2.0.0 · **Needs**: Hammerspoon and Squeezelite · **Changes**: [CHANGELOG.md](CHANGELOG.md)

## What you get

- **A menu bar player icon**, modelled on the Squeezelite app icon. While playing, its display shows a title line and level bars; while stopped, it is dimmed. Click to start or stop. Hover to see the state.
- **Music keeps playing when Hammerspoon reloads.** Squeezelite runs on its own in the background, and the Spoon reconnects to it afterwards.
- **It remembers whether you left it playing or stopped**, across reloads and restarts.
- **Named after your Mac** in the media server, unless you choose a name.
- **Clear errors**: if Squeezelite stops on its own, or exits right after starting, an alert shows the reason (the last line of its log).
- **Honest status**: "started" is shown only once the player is confirmed running, and "stopped" only once it has really exited. Clicks while it is starting or stopping are remembered and applied afterwards.

## Quick start

1. Install Squeezelite. The default path used in the sample is `/Applications/Audio/Squeezelite.app/Contents/MacOS/Squeezelite`.
2. Make sure the `SqueezeliteManager.spoon` folder is in `~/.hammerspoon/Spoons/`.
3. Create the settings file and set the path to Squeezelite:
   ```bash
   cd ~/.hammerspoon/Spoons/SqueezeliteManager.spoon
   cp config.lua.sample config.lua
   ```
4. Add to `~/.hammerspoon/init.lua`:
   ```lua
   hs.loadSpoon("SqueezeliteManager")
   spoon.SqueezeliteManager:start()
   ```
5. Reload Hammerspoon.

The Spoon works on its own. It does not need any of the other Spoons in this repository.

## Settings

| Setting | Default | What it does |
|---|---|---|
| `enabled` | `true` | `false` keeps the Spoon loaded but inactive (no menu bar item) |
| `logLevel` | `"info"` | How much is written to the Hammerspoon Console |
| `squeezelitePath` | *(none)* | **Required.** Full path to the Squeezelite program |
| `playerName` | computer name | Name shown in the media server. Leave unset to use your Mac's name (Finder sidebar) |
| `squeezeliteArgs` | `{}` | Extra Squeezelite options, e.g. server or output device (see below) |
| `autoStart` | `true` | Start playing when there is no remembered state (first run, or `rememberState = false`) |
| `rememberState` | `true` | Restore playing/stopped after a reload or restart |
| `logFile` | `~/.hammerspoon/logs/squeezelite.log` | Where Squeezelite's messages go (`""` to discard them) |
| `checkInterval` | `5` | Seconds between "is it still running?" checks |
| `showAlerts` | `true` | Show "Squeezelite started/stopped" messages |
| `playIcon` / `pauseIcon` | *(icon)* | Text to show instead of the icon while stopped / playing, e.g. `"▶"` and `"▮▮"` |

Typos and wrong value types are reported in the Console (Hammerspoon menu → *Console*) and ignored.

### Common Squeezelite options

Each option and its value are separate items in the list. Spaces in values need no quoting.

```lua
squeezeliteArgs = {
    "-s", "192.168.1.50:9000",    -- server address (otherwise found automatically)
    "-o", "1",                    -- output device (see `Squeezelite -l`)
}
```

The player name (`-n`) is added for you from `playerName`, or from your Mac's name. If you put `-n` in `squeezeliteArgs` yourself, that one is used instead.

## Examples

Start only when clicked, never restore automatically:

```lua
return {
    squeezelitePath = "/Applications/Audio/Squeezelite.app/Contents/MacOS/Squeezelite",
    playerName = "Office",
    autoStart = false,
    rememberState = false,
}
```

Text instead of the icon:

```lua
return {
    squeezelitePath = "/Applications/Audio/Squeezelite.app/Contents/MacOS/Squeezelite",
    playIcon = "▶",
    pauseIcon = "▮▮",
}
```

## Using it from Lua

```lua
spoon.SqueezeliteManager:startSqueezelite()
spoon.SqueezeliteManager:stopSqueezelite()
spoon.SqueezeliteManager:toggle()
spoon.SqueezeliteManager:isRunning()   -- true/false
spoon.SqueezeliteManager:stop()        -- remove the menu bar item; music keeps playing
```

## How it works

- **Detached process.** Squeezelite is started as `/bin/sh -c 'nohup "$@" … & echo $!'`. The shell only detaches it and prints its PID. The program path and arguments are passed as positional parameters, never pasted into the script. Squeezelite's parent becomes launchd, so reloading or quitting Hammerspoon doesn't stop it. Its stdin is `/dev/null`; stdout and stderr are appended to `logFile`.
- **One state machine**: stopped → starting → running → stopping → stopped, plus "restoring" at start. Only one operation runs at a time. Your latest choice (click, `startSqueezelite()`, `stopSqueezelite()`) is remembered and applied when the current operation finishes. The tooltip shows the state ("starting…", "stopping…", "checking…").
- **State** is kept in `hs.settings`: `SqueezeliteManager.pid` and `.pidStart` (the running process and its start time) and `SqueezeliteManager.running` (your last choice).
- **Identity check**: `ps -p <pid> -o lstart= -o comm=`. The program's file name must be exactly the Squeezelite binary's name, and its start time must match the saved one, so a PID reused by another program (or a different Squeezelite) isn't mistaken for ours. If `ps` can't run, a saved PID is neither adopted nor duplicated.
- **On start**, the Spoon checks the saved PID. If Squeezelite is running, it reattaches. If not, it starts Squeezelite when you left it playing (`rememberState`), or when `autoStart` is on and nothing is remembered.
- **Starting**: after launching, the Spoon waits a second and checks the new process. If it already exited (for example a wrong output device), the start is reported as failed with the log's last line.
- **While running**, the identity check runs every `checkInterval` seconds. If Squeezelite has quit on its own, the menu updates, the alert shows the last line of the log, and the state becomes "stopped", so a crashing player isn't restarted on every reload.
- **Stopping**: identity check right before signalling, SIGTERM, check again after 3 seconds, SIGKILL if it is still running. "Stopped" is reported only when the process is gone; if it can't be stopped, it stays tracked and you get an alert. (Checking right before signalling narrows, but cannot completely close, the window in which a PID could be reused.)
- **Helper commands** (`sh`, `ps`, `kill`) have a 10-second deadline, so a hung helper can't leave the Spoon stuck.
- **Log file** folders are created as needed (all levels). If the file can't be written, output is discarded with a warning in the Console. The file is rotated to `.1` when larger than 1 MB at the time Squeezelite starts (it is not a live size limit).
- **Menu bar icon**: a template image drawn with `hs.canvas` on the standard 18×18 pt grid at 2× resolution, so it matches the size and colour of the macOS icons in light and dark mode.
- Config is read when the Spoon is loaded (`init()`). When `enabled = false`, `start()` does nothing.

## Troubleshooting

- **"Squeezelite path not configured" / "binary not found"**: check `squeezelitePath` in `config.lua`.
- **"Squeezelite stopped unexpectedly"**: the alert shows Squeezelite's last message. The full output is in the log:
  ```bash
  tail -20 ~/.hammerspoon/logs/squeezelite.log
  ```
  Often the cause is a wrong output device (`-o`). List devices with `Squeezelite -l`.
- **The player has the wrong name**: set `playerName`, or check for a `-n` in `squeezeliteArgs`, which takes priority.
- **The player doesn't show up in the server**: add `"-s", "<server-ip>:9000"` to `squeezeliteArgs`.
- **Music keeps playing after quitting Hammerspoon**: this is by design. Click the icon after Hammerspoon starts again, or run `pkill Squeezelite`.
- **Disabling the Spoon**: stop playback first (click the icon). With `enabled = false` there is no menu item to stop it later.

## License

BSD-3-Clause · Sorin Pohontu <sorin@frontline.ro>
