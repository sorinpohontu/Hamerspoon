--- === DiskTemp ===
---
--- Menu bar display of disk temperature via SMART data.
---
--- Displays real-time disk temperature in the menu bar with click-to-refresh
--- functionality and automatic periodic updates via smartctl. Supports both
--- manual configuration and automatic external disk detection. All external
--- commands run asynchronously, so Hammerspoon never blocks on a slow disk.

local obj = {}
obj.__index = obj

-- Metadata
obj.name = "DiskTemp"
obj.version = "2.3.0"
obj.author = "Sorin Pohontu <sorin@frontline.ro>"
obj.homepage = "https://github.com/sorinpohontu/Hammerspoon"
obj.license = "BSD-3-Clause - https://opensource.org/license/bsd-3-clause"

--- DiskTemp.logger
--- Variable
--- Logger object used within the Spoon
obj.logger = hs.logger.new('DiskTemp')

--- DiskTemp.enabled
--- Variable
--- If false, the Spoon loads but :start() does nothing
--- Default: true
obj.enabled = true

--- DiskTemp.logLevel
--- Variable
--- Logger verbosity level: 'verbose', 'debug', 'info', 'warning', 'error'
--- Default: 'info'
obj.logLevel = 'info'

--- DiskTemp.diskDevices
--- Variable
--- Array of device paths to monitor (e.g., {"/dev/disk4", "/dev/disk5"})
--- If nil, will auto-detect external disks
--- Default: nil (auto-detect)
obj.diskDevices = nil

--- DiskTemp.autoDetectExternal
--- Variable
--- Boolean to enable auto-detection of external physical disks
--- Default: true
obj.autoDetectExternal = true

--- DiskTemp.updateInterval
--- Variable
--- Interval in seconds for automatic temperature updates
--- Default: 15
obj.updateInterval = 15

--- DiskTemp.showDeviceName
--- Variable
--- Boolean to show device labels in the menu bar when monitoring multiple disks (e.g., "D4|45°")
--- Default: true
obj.showDeviceName = true

--- DiskTemp.separator
--- Variable
--- Separator between multiple disk temperatures
--- Default: " | "
obj.separator = " | "

--- DiskTemp.temperatureUnit
--- Variable
--- Unit symbol to display after the temperature value
--- Default: "°"
obj.temperatureUnit = "°"

--- DiskTemp.smartctlPath
--- Variable
--- Path to the smartctl binary
--- Default: "/opt/homebrew/bin/smartctl"
obj.smartctlPath = "/opt/homebrew/bin/smartctl"

--- DiskTemp.smartctlArgs
--- Variable
--- Arguments passed to smartctl before the device path. "-A" reads only the
--- SMART attributes / health log, which is enough for the temperature.
--- Default: {"-A"}
obj.smartctlArgs = { "-A" }

--- DiskTemp.commandTimeout
--- Variable
--- Seconds after which a hung smartctl or diskutil call is terminated
--- Default: 20
obj.commandTimeout = 20

--- DiskTemp.showAlerts
--- Variable
--- Boolean to show alert messages on errors
--- Default: false
obj.showAlerts = false

--- DiskTemp.warnMissingSmartctl
--- Variable
--- Boolean to show a dialog with install instructions when smartctl is not found
--- Default: true
obj.warnMissingSmartctl = true

-- Internal state
local menuBar = nil
local updateTimer = nil
local updateInProgress = false
local generation = 0          -- Incremented by stop() so in-flight results are discarded
local lastDetected = nil      -- Last auto-detected disk list (for change logging)
local missingWarned = {}      -- Devices already warned about missing temperature
local inflight = {}           -- Running commands: [task] = true (terminated by stop())
local dialogTimer = nil       -- Deferred "smartctl missing" dialog

local KILL_GRACE = 5          -- Seconds between SIGTERM (timeout) and SIGKILL

-- Config keys accepted from config.lua and their expected Lua types
local configTypes = {
    enabled = "boolean",
    logLevel = "string",
    diskDevices = "table",
    autoDetectExternal = "boolean",
    updateInterval = "number",
    showDeviceName = "boolean",
    separator = "string",
    temperatureUnit = "string",
    smartctlPath = "string",
    smartctlArgs = "table",
    commandTimeout = "number",
    showAlerts = "boolean",
    warnMissingSmartctl = "boolean",
}

local function isStringList(list)
    for key, value in pairs(list) do
        if math.type(key) ~= "integer" or type(value) ~= "string" then
            return false
        end
    end
    return true
end

local function isFinite(n)
    return n == n and n ~= math.huge and n ~= -math.huge
end

-- Range checks for config values that passed the type check; return an error or nil
local configChecks = {
    diskDevices = function(v)
        if not isStringList(v) then return "must be a list of device paths (strings)" end
    end,
    smartctlArgs = function(v)
        if not isStringList(v) then return "must be a list of strings" end
    end,
    updateInterval = function(v)
        if not isFinite(v) or v < 1 then return "must be a number >= 1" end
    end,
    commandTimeout = function(v)
        if not isFinite(v) or v <= 0 then return "must be a number > 0" end
    end,
}

-- Run a command asynchronously. callback(exitCode, stdout) is always called exactly
-- once: with the real result, or with -1 if the command could not start or hit
-- its timeout. A timed-out command gets SIGTERM, then SIGKILL after KILL_GRACE
-- seconds if it is still running; its late result is ignored.
local function runCommand(path, args, timeout, callback)
    local timeoutTimer, killTimer = nil, nil
    local done = false
    local task
    local function complete(exitCode, stdout)
        if done then return end
        done = true
        if timeoutTimer then
            timeoutTimer:stop()
            timeoutTimer = nil
        end
        callback(exitCode, stdout or "")
    end

    task = hs.task.new(path, function(exitCode, stdout)
        inflight[task] = nil
        if killTimer then
            killTimer:stop()
            killTimer = nil
        end
        complete(exitCode, stdout)
    end, args)

    if not task or not task:start() then
        complete(-1, "")
        return
    end
    inflight[task] = true

    timeoutTimer = hs.timer.doAfter(timeout, function()
        timeoutTimer = nil
        if task:isRunning() then
            task:terminate()
            killTimer = hs.timer.doAfter(KILL_GRACE, function()
                killTimer = nil
                if task:isRunning() then
                    local killer = hs.task.new("/bin/kill", nil, { "-KILL", tostring(task:pid()) })
                    if killer then killer:start() end
                end
            end)
        end
        complete(-1, "") -- finish now; don't wait for the process to actually exit
    end)
end

-- Extract the current temperature (°C) from smartctl output, or nil
local function parseTemperature(output)
    local ataTemp, airflowTemp
    for line in output:gmatch("[^\r\n]+") do
        -- NVMe health log: "Temperature:                        41 Celsius"
        local temp = line:match("^Temperature:%s*(%d+)%s*Celsius")
        -- SCSI: "Current Drive Temperature:     35 C"
            or line:match("^Current Drive Temperature:%s*(%d+)%s*C")
        if temp then
            return tonumber(temp)
        end

        -- ATA attributes: "194 Temperature_Celsius 0x0022 036 052 000 Old_age Always - 36 (Min/Max 22/48)"
        local id, raw = line:match("^%s*(%d+)%s+%S+%s+0x%x+%s+%S+%s+%S+%s+%S+%s+%S+%s+%S+%s+%S+%s+(%d+)")
        if id == "194" then
            ataTemp = tonumber(raw)
        elseif id == "190" then
            airflowTemp = tonumber(raw)
        end
    end

    local temp = ataTemp or airflowTemp
    if temp and temp > 255 then
        -- Some drives pack min/max into the raw value; the low byte is the current temperature
        temp = temp % 256
    end
    return temp
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

--- DiskTemp:init()
--- Method
--- Spoon initializer (called automatically when Spoon is loaded)
---
--- Parameters:
---  * None
---
--- Returns:
---  * The DiskTemp object
function obj:init()
    self.logger.i("Initializing DiskTemp v" .. self.version)
    self:_loadConfig()
    self.logger.setLogLevel(self.logLevel)
    return self
end

--- DiskTemp:start()
--- Method
--- Start the Spoon and begin monitoring disk temperature
---
--- Parameters:
---  * None
---
--- Returns:
---  * The DiskTemp object
---
--- Notes:
---  * The menu bar item is hidden while there are no disks to monitor and
---    appears automatically when one is connected
---  * Does nothing when `DiskTemp.enabled` is false, or when already started
function obj:start()
    if not self.enabled then
        self.logger.i("Not starting DiskTemp (enabled = false)")
        return self
    end
    if menuBar or dialogTimer then
        self.logger.d("DiskTemp already started")
        return self
    end
    self.logger.i("Starting DiskTemp")

    if not hs.fs.attributes(self.smartctlPath) then
        self.logger.e("smartctl not found at " .. self.smartctlPath .. " (brew install smartmontools)")
        if self.warnMissingSmartctl then
            -- Deferred: blockAlert halts Lua, so let the remaining Spoons load first
            dialogTimer = hs.timer.doAfter(1, function()
                dialogTimer = nil
                self:_showMissingSmartctlDialog()
            end)
        end
        return self
    end

    -- Create menu bar item (hidden until a disk is found)
    menuBar = hs.menubar.new(false)
    if menuBar then
        menuBar:setTitle("—")
        menuBar:setTooltip("Disk temperature (click to refresh)")
        menuBar:setClickCallback(function()
            self:updateTemp()
        end)
    end

    -- Initial temperature update
    self:updateTemp()

    -- Start periodic updates (also picks up disks connected later)
    updateTimer = hs.timer.doEvery(self.updateInterval, function()
        self:updateTemp()
    end)

    return self
end

--- DiskTemp:stop()
--- Method
--- Stop the Spoon and cleanup resources
---
--- Parameters:
---  * None
---
--- Returns:
---  * The DiskTemp object
function obj:stop()
    self.logger.i("Stopping DiskTemp")

    generation = generation + 1
    updateInProgress = false

    -- Stop update timer
    if updateTimer then
        updateTimer:stop()
        updateTimer = nil
    end

    -- Cancel the pending "smartctl missing" dialog
    if dialogTimer then
        dialogTimer:stop()
        dialogTimer = nil
    end

    -- Stop running disk reads; their results are ignored (generation changed)
    for task in pairs(inflight) do
        if task:isRunning() then
            task:terminate()
        end
    end
    inflight = {}

    -- Remove menu bar item
    if menuBar then
        menuBar:delete()
        menuBar = nil
    end

    return self
end

---------------------------------------------------------------------------
-- Public methods
---------------------------------------------------------------------------

--- DiskTemp:updateTemp()
--- Method
--- Start an asynchronous temperature update for all monitored disks
---
--- Parameters:
---  * None
---
--- Returns:
---  * The DiskTemp object
---
--- Notes:
---  * The menu bar title is updated when all readings have completed
---  * Skipped if the previous update is still running
function obj:updateTemp()
    if not menuBar then
        return self
    end
    if updateInProgress then
        self.logger.d("Previous update still running, skipping")
        return self
    end

    self.logger.d("Updating disk temperature(s)")
    updateInProgress = true
    local myGeneration = generation

    self:_getDisksToMonitor(function(disks)
        if myGeneration ~= generation then return end

        if #disks == 0 then
            self.logger.d("No disks to monitor, hiding menu bar item")
            updateInProgress = false
            self:_setVisible(false)
            return
        end

        self:_readTemperatures(disks, function(temperatures)
            if myGeneration ~= generation then return end
            updateInProgress = false
            self:_showTemperatures(disks, temperatures)
        end)
    end)

    return self
end

--- DiskTemp:setDevices(devices)
--- Method
--- Manually set the device paths to monitor
---
--- Parameters:
---  * devices - Array of device paths (e.g., {"/dev/disk4", "/dev/disk5"}), or nil to auto-detect
---
--- Returns:
---  * The DiskTemp object
function obj:setDevices(devices)
    self.logger.f("Setting monitored devices to: %s", devices and table.concat(devices, ", ") or "auto-detect")
    self.diskDevices = devices
    self:updateTemp()
    return self
end

---------------------------------------------------------------------------
-- Private methods
---------------------------------------------------------------------------

-- Private helper function to load configuration from file
function obj:_loadConfig()
    local base = self.spoonPath
    if not base or base == "" then
        base = os.getenv("HOME") .. "/.hammerspoon/Spoons/" .. self.name .. ".spoon"
    end
    local configPath = base .. "/config.lua"
    local file = io.open(configPath, "r")
    if not file then
        self.logger.d("No config.lua file found, using defaults")
        return
    end
    file:close()

    local success, config = pcall(dofile, configPath)
    if not success then
        self.logger.e("Failed to load configuration: " .. tostring(config))
        return
    end
    if type(config) ~= "table" then
        self.logger.w("Config file did not return a table")
        return
    end

    for key, value in pairs(config) do
        local expected = configTypes[key]
        if not expected then
            self.logger.w("Ignoring unknown config key: " .. tostring(key))
        elseif type(value) ~= expected then
            self.logger.w(string.format("Ignoring config key '%s': expected %s, got %s", key, expected, type(value)))
        elseif configChecks[key] and configChecks[key](value) then
            self.logger.w(string.format("Ignoring config key '%s': %s", key, configChecks[key](value)))
        else
            self[key] = value
        end
    end
    self.logger.i("Configuration loaded successfully")
end

-- Private helper to explain how to install smartctl
function obj:_showMissingSmartctlDialog()
    local installCommand = "brew install smartmontools"
    local hasBrew = hs.fs.attributes("/opt/homebrew/bin/brew") or hs.fs.attributes("/usr/local/bin/brew")

    local info = "DiskTemp needs smartctl to read disk temperatures, but it was not found at:\n" ..
        self.smartctlPath .. "\n\n"
    if hasBrew then
        info = info .. "Install it with Homebrew in Terminal:\n\n    " .. installCommand ..
            "\n\nthen reload Hammerspoon."
    else
        info = info .. "Homebrew is not installed either. Install Homebrew from https://brew.sh, then run:\n\n    " ..
            installCommand .. "\n\nand reload Hammerspoon."
    end
    info = info .. "\n\nIf smartctl is installed elsewhere, set smartctlPath in DiskTemp's config.lua. " ..
        "To stop this message, set enabled = false (disable DiskTemp) or warnMissingSmartctl = false."

    local button = hs.dialog.blockAlert("DiskTemp: smartctl not found", info,
        "Copy Install Command", "Close", "warning")
    if button == "Copy Install Command" then
        hs.pasteboard.setContents(installCommand)
        hs.alert.show("Copied: " .. installCommand)
    end
end

-- Private helper to determine which disks to monitor; callback(disks)
function obj:_getDisksToMonitor(callback)
    -- Priority 1: Manually configured devices
    if self.diskDevices and #self.diskDevices > 0 then
        callback(self.diskDevices)
    -- Priority 2: Auto-detect external disks if enabled
    elseif self.autoDetectExternal then
        self:_detectExternalDisks(callback)
    else
        callback({})
    end
end

-- Private helper to detect external physical disks; callback(disks)
function obj:_detectExternalDisks(callback)
    local myGeneration = generation
    runCommand("/usr/sbin/diskutil", { "list" }, self.commandTimeout, function(exitCode, output)
        if myGeneration ~= generation then return end -- stopped meanwhile
        local disks = {}
        if exitCode ~= 0 then
            self.logger.e("diskutil list failed with exit code " .. exitCode)
        else
            for line in output:gmatch("[^\r\n]+") do
                local disk = line:match("^(/dev/disk%d+)%s+%(external, physical%)")
                if disk then
                    table.insert(disks, disk)
                end
            end
        end

        -- Log only when the set of disks changes
        local detected = table.concat(disks, ", ")
        if detected ~= lastDetected then
            lastDetected = detected
            if #disks > 0 then
                self.logger.i("Auto-detected external disks: " .. detected)
            else
                self.logger.i("No external disks detected")
            end
        end

        callback(disks)
    end)
end

-- Private helper to read all disks in parallel; callback(temperatures keyed by device)
function obj:_readTemperatures(disks, callback)
    local temperatures = {}
    local pending = #disks

    for _, device in ipairs(disks) do
        local args = {}
        for _, arg in ipairs(self.smartctlArgs) do
            table.insert(args, arg)
        end
        table.insert(args, device)

        local myGeneration = generation
        runCommand(self.smartctlPath, args, self.commandTimeout, function(exitCode, output)
            if myGeneration ~= generation then return end -- stopped meanwhile: no logs or alerts
            local temp = parseTemperature(output)
            if temp then
                self.logger.df("Read temperature for %s: %d°C", device, temp)
                temperatures[device] = temp
                missingWarned[device] = nil
            elseif not missingWarned[device] then
                -- Warn once per device until a reading succeeds again
                missingWarned[device] = true
                self.logger.w(string.format("No temperature in smartctl output for %s (exit code %d)", device, exitCode))
                if self.showAlerts then
                    hs.alert.show("DiskTemp: no temperature for " .. device)
                end
            end

            pending = pending - 1
            if pending == 0 then
                callback(temperatures)
            end
        end)
    end
end

-- Private helper to render temperatures (keyed by device) in disk order
function obj:_showTemperatures(disks, temperatures)
    if not menuBar then return end

    local parts = {}
    local showLabels = #disks > 1 and self.showDeviceName
    for _, device in ipairs(disks) do
        local temp = temperatures[device]
        if temp then
            local text = temp .. self.temperatureUnit
            if showLabels then
                -- Format as "D6" instead of "disk6"
                text = "D" .. (device:match("disk(%d+)") or device) .. "|" .. text
            end
            table.insert(parts, text)
        end
    end

    menuBar:setTitle(#parts > 0 and table.concat(parts, self.separator) or "N/A")
    self:_setVisible(true)
end

-- Private helper to show or hide the menu bar item
function obj:_setVisible(visible)
    if not menuBar then return end
    if visible and not menuBar:isInMenuBar() then
        menuBar:returnToMenuBar()
    elseif not visible and menuBar:isInMenuBar() then
        menuBar:removeFromMenuBar()
    end
end

return obj
