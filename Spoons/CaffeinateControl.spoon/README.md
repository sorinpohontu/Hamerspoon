# CaffeinateControl.spoon

A coffee-cup icon in the menu bar that keeps your Mac awake. Click it to switch between "stay awake" and "sleep normally".

**Version**: 1.2.0 · **Needs**: Hammerspoon only · **Changes**: [CHANGELOG.md](CHANGELOG.md)

## What you get

- **One click to toggle.** When it's on, the display and the Mac don't go to sleep while you're idle.
- **You can see the state at a glance**: a steaming cup when on, a dimmed cup when off. It has the same size as the macOS icons and adapts to light and dark menu bars. Hover for a tooltip.
- **Lock-aware.** When you lock the screen or the screensaver starts, sleep prevention pauses so the display can turn off. It switches on again once the screen is unlocked *and* the screensaver has ended, if you had it on.
- **On at startup** by default (configurable).

## Quick start

1. Make sure the `CaffeinateControl.spoon` folder is in `~/.hammerspoon/Spoons/`.
2. Add to `~/.hammerspoon/init.lua`:
   ```lua
   hs.loadSpoon("CaffeinateControl")
   spoon.CaffeinateControl:start()
   ```
3. Reload Hammerspoon. The cup icon appears in the menu bar.

The Spoon works on its own. It does not need any of the other Spoons in this repository.

## Settings

Settings are optional. To change them, copy the sample and edit it:

```bash
cd ~/.hammerspoon/Spoons/CaffeinateControl.spoon
cp config.lua.sample config.lua
```

| Setting | Default | What it does |
|---|---|---|
| `enabled` | `true` | `false` keeps the Spoon loaded but inactive (no menu bar icon) |
| `logLevel` | `"info"` | How much is written to the Hammerspoon Console |
| `startCaffeinated` | `true` | Stay awake right after Hammerspoon starts |
| `showAlerts` | `true` | Show "Caffeinate enabled/disabled" when you click the icon |
| `menuIcon` | steaming cup | Your own icon while on: an image file path or [ASCII art](https://www.hammerspoon.org/docs/hs.image.html#imageFromASCII) |
| `menuIconOff` | dimmed cup | Your own icon while off (if only `menuIcon` is set, it is used for both) |

Example: start with sleep allowed, no alerts.

```lua
return {
    startCaffeinated = false,
    showAlerts = false,
}
```

## Using it from Lua

```lua
spoon.CaffeinateControl:toggle()             -- switch on/off
spoon.CaffeinateControl:setCaffeinate(true)  -- force on
spoon.CaffeinateControl:isCaffeinated()      -- true/false: your current choice
spoon.CaffeinateControl:stop()               -- remove the icon and allow sleep
```

## How it works

- Uses `hs.caffeinate.set("displayIdle", ...)`, which stops both the display and the system from sleeping because you're idle. Closing the lid or choosing *Sleep* still works.
- The Spoon keeps your choice (`isCaffeinated()`) separate from what is applied right now. It tracks the lock (`screensDidLock` / `screensDidUnlock`) and the screensaver (`screensaverDidStart` / `screensaverDidStop`) separately, and applies `your choice and not locked and not screensaver`. If Hammerspoon starts while the screen is locked (`hs.caffeinate.sessionProperties()`), it starts suspended.
- `startCaffeinated` applies to the first start only. A second `start()` does nothing, and after `stop()` / `start()` your last choice is kept.
- `stop()` releases sleep prevention, removes the icon and stops the lock watcher.
- The built-in icons are template images drawn with `hs.canvas` on the standard 18×18 pt menu bar grid at 2× resolution. The "off" cup uses 45% opacity, which macOS renders as dimmed. Strokes never overlap, because overlapping semi-transparent strokes would look darker.
- Config is read when the Spoon is loaded (`init()`). When `enabled = false`, `start()` does nothing.

## Troubleshooting

- **The Mac still sleeps**: macOS can override sleep prevention, for example when the battery is critically low or the Mac is too hot. Check the icon's tooltip to see whether caffeinate is on.
- **Is it really active?** The icon shows your choice, so it doesn't change while the screen is locked. To see what is applied right now, run `pmset -g assertions | grep hs.caffeinate` in Terminal. A `PreventUserIdleDisplaySleep` line from Hammerspoon means sleep prevention is active.
- **No icon**: check that `enabled` isn't `false` in `config.lua`, and look in the Console for errors.

## License

BSD-3-Clause · Sorin Pohontu <sorin@frontline.ro>
