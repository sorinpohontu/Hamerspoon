# Hammerspoon Spoons

[![macOS](https://img.shields.io/badge/platform-macOS-lightgrey)](https://www.apple.com/macos/)
[![Hammerspoon](https://img.shields.io/badge/powered%20by-Hammerspoon-blue)](https://www.hammerspoon.org/)
[![License: BSD 3-Clause](https://img.shields.io/badge/license-BSD%203--Clause-blue)](LICENSE)

A collection of independent [Hammerspoon](https://www.hammerspoon.org/) Spoons for everyday macOS tasks. Each one solves a specific problem, bringing useful tools together without installing a separate app for every task. Use the whole configuration or pick only the Spoons you need.

## Meet the Spoons

| Spoon | What it does | Extra requirements |
|---|---|---|
| [WindowManager](Spoons/WindowManager.spoon/README.md) | Move, resize and arrange windows with keyboard shortcuts. | None |
| [CaffeinateControl](Spoons/CaffeinateControl.spoon/README.md) | Keep your Mac awake with a menu bar cup; pause sleep prevention when the screen is locked. | None |
| [SqueezeliteManager](Spoons/SqueezeliteManager.spoon/README.md) | Start and stop a Squeezelite player from the menu bar; playback continues across Hammerspoon reloads. | Squeezelite and a Lyrion Media Server |
| [DiskTemp](Spoons/DiskTemp.spoon/README.md) | Show external disk temperatures in the menu bar. | `smartctl` from `smartmontools`; a disk enclosure that passes SMART data through |
| [ScheduledTask](Spoons/ScheduledTask.spoon/README.md) | Run commands at intervals, at fixed times or in random time windows. | None |

Each Spoon works on its own. Follow its link for settings, examples and troubleshooting.

## Get started

Install [Hammerspoon](https://www.hammerspoon.org/) on your Mac first. Grant any permissions it requests for the features you use, such as Accessibility for window management.

### Use the whole configuration

Back up your existing `~/.hammerspoon` directory first. Place this repository at `~/.hammerspoon`, then reload Hammerspoon from its menu bar menu. The included `init.lua` loads all five Spoons independently, so an error in one does not prevent the others from loading.

Before using them, check their individual guides: SqueezeliteManager needs a configured player path, DiskTemp needs `smartctl`, and ScheduledTask needs task definitions. To turn off a Spoon, copy its `config.lua.sample` to `config.lua` in its Spoon folder and set `enabled = false`.

### Use individual Spoons

Copy the desired `.spoon` folder from `Spoons/` into `~/.hammerspoon/Spoons/`. Add it to your existing `~/.hammerspoon/init.lua`, for example:

```lua
hs.loadSpoon("WindowManager")
spoon.WindowManager:start()
```

Reload Hammerspoon. Repeat for any other Spoons you want; each guide covers its own setup and optional `config.lua` settings.

## Roadmap

See [ROADMAP.md](ROADMAP.md) for ideas under consideration.

## License

[BSD 3-Clause](LICENSE).
