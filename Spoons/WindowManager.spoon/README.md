# WindowManager.spoon

Move and resize the focused window with a keystroke: center it, snap it to the left or right half, fill the screen, or tuck it into the top-right corner.

**Version**: 1.3.0 · **Needs**: Hammerspoon only · **Changes**: [CHANGELOG.md](CHANGELOG.md)

## What you get

| Action | Default keys | What happens |
|---|---|---|
| Center | `⌘⌥⌃C` or `F16` | Window keeps its size and moves to the middle of the screen |
| Top right | `⌘⇧T` | Window keeps its size and moves to the top-right corner |
| Left half | `⌘⇧[` | Window fills the left half of the screen |
| Right half | `⌘⇧]` | Window fills the right half of the screen |
| Full desktop | `⌘⇧0` or `F13` | Window fills the whole screen (not macOS full-screen mode) |

Each action briefly shows its name on screen (turn off with `showAlerts = false`). Windows always stay on the screen they are on.

## Quick start

1. Make sure the `WindowManager.spoon` folder is in `~/.hammerspoon/Spoons/`.
2. Add to `~/.hammerspoon/init.lua`:
   ```lua
   hs.loadSpoon("WindowManager")
   spoon.WindowManager:start()
   ```
3. Reload Hammerspoon (menu bar icon → *Reload Config*).

The Spoon works on its own. It does not need any of the other Spoons in this repository.

## Settings

Settings are optional. To change them, copy the sample and edit it:

```bash
cd ~/.hammerspoon/Spoons/WindowManager.spoon
cp config.lua.sample config.lua
```

| Setting | Default | What it does |
|---|---|---|
| `enabled` | `true` | `false` keeps the Spoon loaded but inactive (no hotkeys) |
| `logLevel` | `"info"` | How much is written to the Hammerspoon Console |
| `showAlerts` | `true` | Show the action name on screen |
| `frameOffset` | `{x = 2, y = 2, h = 6}` | Small gaps around windows (see below) |
| `hotkeys` | see table above | Your own key combinations |

After editing, reload Hammerspoon. Typos and wrong value types are reported in the Console (Hammerspoon menu → *Console*) and ignored.

### Gaps around windows (`frameOffset`)

- `x`: gap between the left and right halves
- `y`: gap at the top of the screen
- `h`: how much shorter than the screen a window is (bottom gap)

You can change just one value, e.g. `frameOffset = {y = 0}`. The others keep their defaults.

### Your own hotkeys

```lua
return {
    hotkeys = {
        center      = {{"cmd", "alt"}, "C"},                       -- one hotkey
        halfLeft    = {{{"cmd", "alt"}, "Left"}, {nil, "F14"}},    -- two hotkeys
        halfRight   = {{{"cmd", "alt"}, "Right"}},                 -- a list with one hotkey
        fullDesktop = {{"cmd", "alt"}, "F"},
        -- topRight not listed: no hotkey for it
    },
}
```

- A hotkey is `{modifiers, key}`. Modifiers are `"cmd"`, `"alt"`, `"ctrl"`, `"shift"`, or `nil` for none.
- Use a list of hotkeys to give an action several shortcuts.
- `hotkeys` replaces the whole default set, so list every action you want to keep.
- A key name that doesn't exist is reported in the Console. The other hotkeys still work.

## Using it from Lua

```lua
spoon.WindowManager:centerWindow()
spoon.WindowManager:topRight()
spoon.WindowManager:halfLeft()
spoon.WindowManager:halfRight()
spoon.WindowManager:fullDesktop()

-- Replace the hotkeys at runtime
spoon.WindowManager:bindHotkeys({ center = {{"cmd", "ctrl"}, "C"} })

spoon.WindowManager:stop()   -- remove all hotkeys
```

All methods return the Spoon, so calls can be chained.

## How it works

- Positions are calculated from the usable area of the window's current screen (`win:screen():frame()`, which excludes the menu bar and Dock).
- Right half: `x = screen.x + screen.w/2 + frameOffset.x`, `w = screen.w/2 - frameOffset.x`, so the window ends exactly at the right edge.
- `stop()` deletes the hotkeys. `bindHotkeys()` deletes the previous hotkeys first, so re-binding never leaves stale shortcuts behind.
- Each action is bound separately: a malformed entry or unknown key name is reported in the Console and skipped, and the other actions still get their hotkeys.
- Config is read when the Spoon is loaded (`init()`). When `enabled = false`, `start()` does nothing.

## Troubleshooting

- **A hotkey does nothing**: another app may already use it. Check the Console for "Failed to bind hotkey", and try a different combination.
- **Nothing happens and the Console says "No focused window"**: click the window first, so it has focus.
- **Windows are a few pixels off**: adjust `frameOffset`.

## License

BSD-3-Clause · Sorin Pohontu <sorin@frontline.ro>
