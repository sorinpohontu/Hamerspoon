# DiskTemp.spoon

Shows the temperature of your external disks in the menu bar, e.g. `41°`, or `D4|41° | D5|36°` for several disks.

**Version**: 2.3.0 · **Needs**: Hammerspoon and `smartctl` (Homebrew `smartmontools`) · **Changes**: [CHANGELOG.md](CHANGELOG.md)

## What you get

- **Automatic**: finds external disks by itself. Plug a disk in and its temperature appears within a few seconds. Unplug it and the menu bar item disappears.
- **Several disks** side by side, each labelled with its disk number (`D4`, `D5`, …).
- **Click to refresh** right away. Otherwise it updates every 15 seconds.
- **Works with NVMe, SATA and most USB disks**, as long as the enclosure passes SMART data through.
- **Never slows Hammerspoon down**: disks are read in the background, so a slow or waking disk can't freeze your hotkeys.

## Quick start

1. Install `smartctl`:
   ```bash
   brew install smartmontools
   ```
   If you skip this, DiskTemp shows a dialog with these instructions and a button that copies the command.
2. Make sure the `DiskTemp.spoon` folder is in `~/.hammerspoon/Spoons/`.
3. Add to `~/.hammerspoon/init.lua`:
   ```lua
   hs.loadSpoon("DiskTemp")
   spoon.DiskTemp:start()
   ```
4. Reload Hammerspoon. Connect an external disk to see its temperature.

The Spoon works on its own. It does not need any of the other Spoons in this repository.

## Settings

Settings are optional. To change them, copy the sample and edit it:

```bash
cd ~/.hammerspoon/Spoons/DiskTemp.spoon
cp config.lua.sample config.lua
```

| Setting | Default | What it does |
|---|---|---|
| `enabled` | `true` | `false` keeps the Spoon loaded but inactive |
| `logLevel` | `"info"` | How much is written to the Hammerspoon Console |
| `diskDevices` | *(auto)* | Watch only these disks, e.g. `{"/dev/disk4"}`. Leave unset to find external disks automatically |
| `autoDetectExternal` | `true` | Find external disks automatically when `diskDevices` is not set |
| `updateInterval` | `15` | Seconds between updates |
| `showDeviceName` | `true` | Show `D4\|` labels when several disks are shown |
| `separator` | `" \| "` | Text between disks |
| `temperatureUnit` | `"°"` | Text after the number |
| `smartctlPath` | `/opt/homebrew/bin/smartctl` | Where `smartctl` is installed |
| `smartctlArgs` | `{"-A"}` | Options passed to `smartctl` (see Troubleshooting) |
| `commandTimeout` | `20` | Seconds before a stuck disk read is cancelled |
| `showAlerts` | `false` | Pop up a message when a disk returns no temperature |
| `warnMissingSmartctl` | `true` | Show the install dialog when `smartctl` is missing |

Typos and wrong value types are reported in the Console (Hammerspoon menu → *Console*) and ignored.

Example: watch one specific disk, update every 30 seconds.

```lua
return {
    diskDevices = {"/dev/disk4"},
    updateInterval = 30,
}
```

To find a disk's number, run `diskutil list` and look for `/dev/diskN (external, physical)`.

## Using it from Lua

```lua
spoon.DiskTemp:updateTemp()                  -- refresh now
spoon.DiskTemp:setDevices({"/dev/disk5"})    -- watch a different disk
spoon.DiskTemp:setDevices(nil)               -- back to automatic detection
spoon.DiskTemp:stop()                        -- remove the menu bar item
```

## How it works

- Every `updateInterval` seconds, the Spoon runs `diskutil list` (unless `diskDevices` is set) and keeps the lines marked `(external, physical)`.
- For each disk it runs `smartctl -A /dev/diskN` and reads, in order of preference:
  - NVMe: `Temperature: 41 Celsius`
  - SCSI: `Current Drive Temperature: 35 C`
  - SATA/ATA: attribute 194 `Temperature_Celsius`, or else 190 `Airflow_Temperature_Cel`. If the raw value packs min/max values, only the low byte is used.
- All commands run asynchronously through `hs.task`, with arguments passed directly (no shell). A new update is skipped while the previous one is still running.
- Each command has a timeout (`commandTimeout`). At the timeout the update finishes without that reading (so a stuck disk can't block later updates), the command gets SIGTERM, and SIGKILL 5 seconds later if it is still running. Its late result is ignored.
- `stop()` terminates running reads and cancels the pending install dialog; results that arrive afterwards are ignored (no warnings or alerts).
- `-A` reads only SMART attributes, which is lighter than `--all`.
- Missing temperatures are logged once per disk until a reading succeeds again, so the Console isn't flooded.
- Config is read when the Spoon is loaded (`init()`). When `enabled = false`, `start()` does nothing.

## Troubleshooting

- **The menu bar shows `N/A`**: the disk didn't report a temperature. Try it in Terminal:
  ```bash
  /opt/homebrew/bin/smartctl -A /dev/disk4 | grep -i temperature
  ```
  Many USB enclosures need `-d sat`. If that works, set `smartctlArgs = {"-A", "-d", "sat"}`. Some enclosures can't pass SMART data through at all.
- **No menu bar item**: no external disk was found. Check `diskutil list`, or set `diskDevices` explicitly.
- **The install dialog keeps appearing**: install `smartmontools`, set `smartctlPath` if it lives elsewhere, or set `warnMissingSmartctl = false`.
- **Spinning disks don't go to sleep**: reading SMART data can keep a hard disk awake. Raise `updateInterval`.

## License

BSD-3-Clause · Sorin Pohontu <sorin@frontline.ro>
