--- === SqueezeliteManager ===
---
--- Menu bar control for the Squeezelite audio player.
---
--- Starts and stops Squeezelite from the menu bar. Squeezelite runs as an
--- independent background process, so playback continues while Hammerspoon
--- reloads; the Spoon reattaches to it and remembers whether it was playing.

local obj = {}
obj.__index = obj

-- Metadata
obj.name = "SqueezeliteManager"
obj.version = "2.0.0"
obj.author = "Sorin Pohontu <sorin@frontline.ro>"
obj.homepage = "https://github.com/sorinpohontu/Hammerspoon"
obj.license = "BSD-3-Clause - https://opensource.org/license/bsd-3-clause"

--- SqueezeliteManager.logger
--- Variable
--- Logger object used within the Spoon
obj.logger = hs.logger.new('SqueezeliteManager')

--- SqueezeliteManager.enabled
--- Variable
--- If false, the Spoon loads but :start() does nothing
--- Default: true
obj.enabled = true

--- SqueezeliteManager.logLevel
--- Variable
--- Logger verbosity level: 'verbose', 'debug', 'info', 'warning', 'error'
--- Default: 'info'
obj.logLevel = 'info'

--- SqueezeliteManager.squeezelitePath
--- Variable
--- Path to the Squeezelite binary
--- Default: nil (must be set before start())
obj.squeezelitePath = nil

--- SqueezeliteManager.playerName
--- Variable
--- Player name shown in the media server (Squeezelite's -n option).
--- Ignored when squeezeliteArgs already contains -n.
--- Default: nil (the computer name, as shown in the Finder sidebar)
obj.playerName = nil

--- SqueezeliteManager.squeezeliteArgs
--- Variable
--- Table of command-line arguments (strings) to pass to Squeezelite
--- Default: {}
obj.squeezeliteArgs = {}

--- SqueezeliteManager.autoStart
--- Variable
--- Boolean to start Squeezelite when the Spoon starts, if there is no remembered
--- state (see rememberState)
--- Default: true
obj.autoStart = true

--- SqueezeliteManager.rememberState
--- Variable
--- Boolean to restore the last state (playing or stopped) when Hammerspoon
--- reloads or restarts, instead of using autoStart
--- Default: true
obj.rememberState = true

--- SqueezeliteManager.logFile
--- Variable
--- File that receives Squeezelite's output. It is rotated to ".1" when it is
--- larger than 1 MB at the time Squeezelite starts. Its last line is shown when
--- Squeezelite stops unexpectedly. "" discards the output.
--- Default: "~/.hammerspoon/logs/squeezelite.log"
obj.logFile = "~/.hammerspoon/logs/squeezelite.log"

--- SqueezeliteManager.checkInterval
--- Variable
--- Interval in seconds for checking if Squeezelite is still running
--- Default: 5
obj.checkInterval = 5

--- SqueezeliteManager.showAlerts
--- Variable
--- Boolean to show/hide alert messages
--- Default: true
obj.showAlerts = true

--- SqueezeliteManager.playIcon
--- Variable
--- Optional text shown in the menu bar while Squeezelite is stopped, instead of the player icon
--- Default: nil (dimmed player icon)
obj.playIcon = nil

--- SqueezeliteManager.pauseIcon
--- Variable
--- Optional text shown in the menu bar while Squeezelite is running, instead of the player icon
--- Default: nil (player icon with level bars)
obj.pauseIcon = nil

-- Internal state
--
-- Every change goes through one state machine, so operations never overlap:
--   stopped -> starting -> running -> stopping -> stopped, and restoring at start().
-- `wanted` is the user's latest choice; it is applied once the current operation
-- has finished (see _reconcile), so clicks during an operation are not lost.
local menuBar = nil
local monitorTimer = nil
local state = "stopped"    -- "restoring" | "starting" | "running" | "stopping" | "stopped"
local pid = nil            -- PID of the Squeezelite process we own
local pidStart = nil       -- Its start time (from ps), to recognise PID reuse
local wanted = false       -- The user's latest choice: playing or not
local generation = 0       -- Incremented by stop(); results of older operations are ignored
local checking = false     -- A periodic process check is in progress
local menuIcons = nil      -- { on = hs.image, off = hs.image }, drawn on first use

-- hs.settings keys (persist across reloads and restarts)
local PID_KEY = "SqueezeliteManager.pid"
local PID_START_KEY = "SqueezeliteManager.pidStart"
local RUNNING_KEY = "SqueezeliteManager.running"

local LOG_ROTATE_BYTES = 1024 * 1024
local HELPER_TIMEOUT = 10  -- Deadline for the launcher, ps and kill helpers
local LAUNCH_SETTLE = 1    -- Seconds after launch before confirming the process is running
local STOP_GRACE = 3       -- Seconds after SIGTERM before SIGKILL

-- Config keys accepted from config.lua and their expected Lua types
local configTypes = {
	enabled = "boolean",
	logLevel = "string",
	squeezelitePath = "string",
	playerName = "string",
	squeezeliteArgs = "table",
	autoStart = "boolean",
	rememberState = "boolean",
	logFile = "string",
	checkInterval = "number",
	showAlerts = "boolean",
	playIcon = "string",
	pauseIcon = "string",
}

-- Range checks for config values that passed the type check; return an error or nil
local configChecks = {
	squeezeliteArgs = function(v)
		for key, value in pairs(v) do
			if math.type(key) ~= "integer" or type(value) ~= "string" then
				return "must be a list of strings"
			end
		end
	end,
	checkInterval = function(v)
		if v ~= v or v == math.huge or v < 1 then return "must be a number >= 1" end
	end,
}

-- Menu bar icons are drawn in an 18x18 point space (the standard menu bar icon
-- size) and rendered at 2x so they stay sharp on Retina displays
local ICON_SIZE = 18
local ICON_SCALE = 2

-- Black with the given opacity; template images only use the alpha channel
local function ink(alpha)
	return { white = 0, alpha = alpha or 1 }
end

-- Scale an element from 18-point coordinates to the 2x canvas
local function scaleElement(element)
	local s = ICON_SCALE
	local e = {}
	for key, value in pairs(element) do
		e[key] = value
	end
	if element.frame then
		e.frame = { x = element.frame.x * s, y = element.frame.y * s, w = element.frame.w * s, h = element.frame.h * s }
	end
	if element.coordinates then
		e.coordinates = {}
		for i, point in ipairs(element.coordinates) do
			local p = {}
			for key, value in pairs(point) do
				p[key] = value * s
			end
			e.coordinates[i] = p
		end
	end
	if element.roundedRectRadii then
		e.roundedRectRadii = { xRadius = element.roundedRectRadii.xRadius * s, yRadius = element.roundedRectRadii.yRadius * s }
	end
	e.strokeWidth = (element.strokeWidth or 1.4) * s
	return e
end

-- Draw a template icon from elements given in 18-point coordinates
local function drawIcon(elements)
	local size = ICON_SIZE * ICON_SCALE
	local canvas = hs.canvas.new({ x = 0, y = 0, w = size, h = size })
	if not canvas then
		return nil
	end
	for _, element in ipairs(elements) do
		canvas:appendElements(scaleElement(element))
	end
	local image = canvas:imageFromCanvas()
	canvas:delete()
	if not image then
		return nil
	end
	return image:setSize({ w = ICON_SIZE, h = ICON_SIZE }, true):template(true)
end

-- Squeezebox-style player, after the Squeezelite app icon: device outline, display
-- and grille. While playing, the display shows a title line and level bars;
-- while stopped the whole icon is dimmed
local function drawPlayer(on)
	local color = ink(on and 1 or 0.45)
	local radius = function(r) return { xRadius = r, yRadius = r } end
	local elements = {
		-- Device body
		{ type = "rectangle", action = "stroke", strokeColor = color,
		  frame = { x = 1.75, y = 4, w = 14.5, h = 10 }, roundedRectRadii = radius(2) },
		-- Display
		{ type = "rectangle", action = "fill", fillColor = color,
		  frame = { x = 3.75, y = 6, w = 10.5, h = 3.75 }, roundedRectRadii = radius(0.75) },
	}
	if on then
		-- Cut the "now playing" title and level bars out of the display
		local cutouts = {
			{ x = 4.75, y = 7.25, w = 4, h = 1 },
			{ x = 10.25, y = 7.75, w = 0.85, h = 1.25 },
			{ x = 11.5, y = 6.75, w = 0.85, h = 2.25 },
			{ x = 12.75, y = 7.25, w = 0.85, h = 1.75 },
		}
		for _, frame in ipairs(cutouts) do
			table.insert(elements, { type = "rectangle", action = "fill", fillColor = ink(), compositeRule = "clear",
				frame = frame })
		end
	end
	-- Speaker grille
	table.insert(elements, { type = "rectangle", action = "fill", fillColor = color,
		frame = { x = 4.25, y = 11.25, w = 9.5, h = 1 }, roundedRectRadii = radius(0.5) })
	return drawIcon(elements)
end

-- Expand a leading "~" to the home directory
local function expandHome(path)
	local home = os.getenv("HOME") or ""
	return (path:gsub("^~", function() return home end))
end

local function basename(path)
	return (path or ""):match("([^/]+)/*$") or ""
end

-- Create a folder and any missing parents; returns true or nil and an error
local function makeDirectories(dir)
	if hs.fs.attributes(dir) then
		return true
	end
	local parent = dir:match("^(.*)/[^/]+$")
	if parent and parent ~= "" then
		local ok, err = makeDirectories(parent)
		if not ok then
			return nil, err
		end
	end
	return hs.fs.mkdir(dir)
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

--- SqueezeliteManager:init()
--- Method
--- Spoon initializer (called automatically when Spoon is loaded)
---
--- Parameters:
---  * None
---
--- Returns:
---  * The SqueezeliteManager object
function obj:init()
	self.logger.i("Initializing SqueezeliteManager")
	self:_loadConfig()
	self.logger.setLogLevel(self.logLevel)
	return self
end

--- SqueezeliteManager:start()
--- Method
--- Show the menu bar item, reattach to a Squeezelite left running by a previous
--- Hammerspoon session, or restore the remembered state
---
--- Parameters:
---  * None
---
--- Returns:
---  * The SqueezeliteManager object
---
--- Notes:
---  * Does nothing when `SqueezeliteManager.enabled` is false, or when already started
function obj:start()
	if not self.enabled then
		self.logger.i("Not starting SqueezeliteManager (enabled = false)")
		return self
	end
	if menuBar then
		self.logger.d("SqueezeliteManager already started")
		return self
	end
	self.logger.i("Starting SqueezeliteManager")

	menuBar = hs.menubar.new()
	if menuBar then
		menuBar:setClickCallback(function()
			self:toggle()
		end)
	end

	monitorTimer = hs.timer.doEvery(self.checkInterval, function()
		self:_checkProcessStatus()
	end)

	self:_restore()
	return self
end

--- SqueezeliteManager:stop()
--- Method
--- Remove the menu bar item and stop monitoring
---
--- Parameters:
---  * None
---
--- Returns:
---  * The SqueezeliteManager object
---
--- Notes:
---  * Squeezelite itself keeps playing (as it does across reloads); use
---    `stopSqueezelite()` to stop playback
---  * Operations still in progress are abandoned; a player launched just before
---    is remembered (its PID is saved) and reattached on the next start()
function obj:stop()
	self.logger.i("Stopping SqueezeliteManager")
	generation = generation + 1
	checking = false

	if monitorTimer then
		monitorTimer:stop()
		monitorTimer = nil
	end

	if menuBar then
		menuBar:delete()
		menuBar = nil
	end

	state = pid and "running" or "stopped"
	return self
end

---------------------------------------------------------------------------
-- Public methods
---------------------------------------------------------------------------

--- SqueezeliteManager:toggle()
--- Method
--- Start Squeezelite if it is stopped (or stopping), stop it if it is running (or starting)
---
--- Parameters:
---  * None
---
--- Returns:
---  * The SqueezeliteManager object
function obj:toggle()
	if wanted then
		self:stopSqueezelite()
	else
		self:startSqueezelite()
	end
	return self
end

--- SqueezeliteManager:startSqueezelite()
--- Method
--- Start the Squeezelite process in the background
---
--- Parameters:
---  * None
---
--- Returns:
---  * The SqueezeliteManager object
---
--- Notes:
---  * Squeezelite is detached from Hammerspoon (`nohup ... &`), so it keeps
---    running when Hammerspoon reloads or quits
---  * If another operation is in progress, the request is applied when it finishes
function obj:startSqueezelite()
	self:_setWanted(true)
	self:_reconcile()
	return self
end

--- SqueezeliteManager:stopSqueezelite()
--- Method
--- Stop the Squeezelite process
---
--- Parameters:
---  * None
---
--- Returns:
---  * The SqueezeliteManager object
---
--- Notes:
---  * Squeezelite gets SIGTERM, then SIGKILL if it is still running after 3 seconds.
---    "Stopped" is reported only once the process has really exited
---  * If another operation is in progress, the request is applied when it finishes
function obj:stopSqueezelite()
	self:_setWanted(false)
	self:_reconcile()
	return self
end

--- SqueezeliteManager:isRunning()
--- Method
--- Check if Squeezelite process is currently running
---
--- Parameters:
---  * None
---
--- Returns:
---  * Boolean: true if running, false otherwise
function obj:isRunning()
	return state == "running"
end

---------------------------------------------------------------------------
-- Private methods
---------------------------------------------------------------------------

-- Private helper function to load configuration from config.lua
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

-- Reattach to a Squeezelite left running by a previous session, or restore the remembered state
function obj:_restore()
	-- hs.settings stores values as property-list types: a boolean may come back as 1/0
	-- and an integer as a float, so accept both forms
	local remembered = self.rememberState and hs.settings.get(RUNNING_KEY)
	if remembered == true or remembered == 1 then
		wanted = true
	elseif remembered == false or remembered == 0 then
		wanted = false
	else
		wanted = self.autoStart
	end

	local savedPid = math.tointeger(tonumber(hs.settings.get(PID_KEY)) or 0)
	if not savedPid or savedPid <= 0 then
		state = "stopped"
		self:_reconcile()
		return
	end

	state = "restoring"
	self:_updateMenu()
	local myGeneration = generation
	local savedStart = hs.settings.get(PID_START_KEY)
	self:_probe(savedPid, type(savedStart) == "string" and savedStart or nil, function(status, startTime)
		if myGeneration ~= generation then return end
		if status == "alive" then
			pid, pidStart = savedPid, startTime
			hs.settings.set(PID_START_KEY, startTime)
			state = "running"
			self.logger.i("Reattached to running Squeezelite, PID " .. pid)
		elseif status == "dead" then
			hs.settings.clear(PID_KEY)
			hs.settings.clear(PID_START_KEY)
			state = "stopped"
		else
			-- Can't tell: neither adopt it nor start a second player
			self.logger.w("Could not check saved Squeezelite PID " .. savedPid .. "; not starting another one")
			state = "stopped"
			wanted = false
		end
		self:_reconcile()
	end)
end

-- Record the user's choice (remembered across reloads)
function obj:_setWanted(value)
	wanted = value
	hs.settings.set(RUNNING_KEY, value)
end

-- Move towards the wanted state, unless an operation is already in progress
function obj:_reconcile()
	if state == "stopped" and wanted then
		self:_launch()
	elseif state == "running" and not wanted then
		self:_terminate()
	end
	self:_updateMenu()
end

-- Launch Squeezelite detached, then confirm it is running before reporting success
function obj:_launch()
	if not self.squeezelitePath then
		self.logger.e("squeezelitePath not configured")
		self:_launchFailed("Squeezelite path not configured")
		return
	end
	local file = io.open(self.squeezelitePath, "r")
	if not file then
		self.logger.e("Squeezelite binary not found at: " .. self.squeezelitePath)
		self:_launchFailed("Squeezelite binary not found")
		return
	end
	file:close()

	local logPath = self:_prepareLogFile()
	local args = self:_buildArgs()
	self.logger.i("Starting Squeezelite: " .. self.squeezelitePath .. " " .. table.concat(args, " "))

	-- The shell only detaches Squeezelite and prints its PID. Paths and arguments
	-- are passed as positional parameters ("$@"), never interpolated into the script.
	local script = 'log="$1"; shift; nohup "$@" </dev/null >>"$log" 2>&1 & echo $!'
	local shellArgs = { "-c", script, "sh", logPath, self.squeezelitePath }
	for _, arg in ipairs(args) do
		table.insert(shellArgs, arg)
	end

	state = "starting"
	local myGeneration = generation
	self:_runHelper("/bin/sh", shellArgs, function(exitCode, stdout)
		local newPid = math.tointeger(tonumber((stdout or ""):match("(%d+)")))
		if exitCode == 0 and newPid then
			-- Save it straight away, so it can be reattached even if the Spoon stops now
			hs.settings.set(PID_KEY, newPid)
		end
		if myGeneration ~= generation then return end
		if not (exitCode == 0 and newPid) then
			self.logger.e("Failed to launch Squeezelite")
			self:_launchFailed("Failed to start Squeezelite")
			return
		end

		-- Give it a moment, then make sure the player is really running
		hs.timer.doAfter(LAUNCH_SETTLE, function()
			if myGeneration ~= generation then return end
			self:_probe(newPid, nil, function(status, startTime)
				if myGeneration ~= generation then return end
				if status == "alive" then
					pid, pidStart = newPid, startTime
					hs.settings.set(PID_START_KEY, startTime)
					state = "running"
					self.logger.i("Squeezelite started, PID " .. pid)
					if self.showAlerts then
						hs.alert.show("Squeezelite started")
					end
					self:_reconcile()
				elseif status == "unknown" then
					-- Assume it runs (the launcher succeeded); the monitor will check again
					pid, pidStart = newPid, nil
					state = "running"
					self.logger.w("Squeezelite launched (PID " .. newPid .. ") but could not be confirmed yet")
					self:_reconcile()
				else
					hs.settings.clear(PID_KEY)
					local reason = self:_lastLogLine()
					self.logger.e("Squeezelite exited right after starting" .. (reason and (": " .. reason) or ""))
					self:_launchFailed("Squeezelite exited right after starting" .. (reason and ("\n" .. reason) or ""))
				end
			end)
		end)
	end)
	self:_updateMenu()
end

-- Build Squeezelite's arguments: squeezeliteArgs plus "-n <name>" (playerName,
-- or the computer name) unless -n is already given
function obj:_buildArgs()
	local args = {}
	local hasName = false
	for _, arg in ipairs(self.squeezeliteArgs) do
		if arg == "-n" then
			hasName = true
		end
		table.insert(args, arg)
	end

	if not hasName then
		local name = self.playerName or hs.host.localizedName()
		if name and name ~= "" then
			table.insert(args, "-n")
			table.insert(args, name)
		end
	end

	return args
end

-- Resolve the log file path, create its folders and rotate it when large.
-- Returns the path to use; "/dev/null" if logging is off or the file is not writable.
function obj:_prepareLogFile()
	if not self.logFile or self.logFile == "" then
		return "/dev/null"
	end
	local path = expandHome(self.logFile)
	local dir = path:match("^(.*)/[^/]+$")
	if dir then
		local ok, err = makeDirectories(dir)
		if not ok then
			self.logger.w("Could not create log folder " .. dir .. ": " .. tostring(err) .. "; discarding output")
			return "/dev/null"
		end
	end

	local attributes = hs.fs.attributes(path)
	if attributes and attributes.size and attributes.size > LOG_ROTATE_BYTES then
		os.remove(path .. ".1")
		local ok, err = os.rename(path, path .. ".1")
		if not ok then
			self.logger.w("Could not rotate log file: " .. tostring(err))
		end
	end

	local file, err = io.open(path, "a")
	if not file then
		self.logger.w("Log file not writable (" .. tostring(err) .. "); discarding output")
		return "/dev/null"
	end
	file:close()
	return path
end

-- A start attempt failed: back to stopped, and don't retry automatically
function obj:_launchFailed(message)
	state = "stopped"
	self:_setWanted(false)
	if self.showAlerts then
		hs.alert.show(message)
	end
	self:_updateMenu()
end

-- Stop our Squeezelite: verify it is still ours, SIGTERM, then SIGKILL if needed.
-- It is reported stopped only once the process is gone.
function obj:_terminate()
	local target, expectedStart = pid, pidStart
	state = "stopping"
	self:_updateMenu()
	local myGeneration = generation

	local function finished()
		pid, pidStart = nil, nil
		hs.settings.clear(PID_KEY)
		hs.settings.clear(PID_START_KEY)
		state = "stopped"
		self.logger.i("Squeezelite stopped")
		if self.showAlerts then
			hs.alert.show("Squeezelite stopped")
		end
		self:_reconcile()
	end

	local function failed(message)
		state = "running"
		self.logger.e(message)
		if self.showAlerts then
			hs.alert.show(message)
		end
		self:_setWanted(true) -- it is still playing
		self:_updateMenu()
	end

	local function signal(name, nextStep)
		self:_runHelper("/bin/kill", { "-" .. name, tostring(target) }, function(exitCode)
			if myGeneration ~= generation then return end
			if exitCode == nil then
				failed("Could not stop Squeezelite (PID " .. target .. ")")
				return
			end
			hs.timer.doAfter(STOP_GRACE, function()
				if myGeneration ~= generation then return end
				self:_probe(target, expectedStart, function(status)
					if myGeneration ~= generation then return end
					if status == "dead" then
						finished()
					elseif nextStep then
						nextStep()
					else
						failed("Squeezelite (PID " .. target .. ") is still running after SIGKILL")
					end
				end)
			end)
		end)
	end

	-- Check identity right before signalling (narrows, but cannot fully close, the PID-reuse window)
	self:_probe(target, expectedStart, function(status)
		if myGeneration ~= generation then return end
		if status == "dead" then
			finished()
		elseif status == "unknown" then
			failed("Could not verify Squeezelite (PID " .. target .. "); not sending a signal")
		else
			signal("TERM", function()
				self.logger.w("Squeezelite ignored SIGTERM; sending SIGKILL")
				signal("KILL", nil)
			end)
		end
	end)
end

-- Periodic check that Squeezelite is still running
function obj:_checkProcessStatus()
	if state ~= "running" or checking then
		return
	end
	checking = true
	local target, myGeneration = pid, generation
	self:_probe(target, pidStart, function(status, startTime)
		checking = false
		if myGeneration ~= generation or state ~= "running" or pid ~= target then return end
		if status == "dead" then
			self:_onUnexpectedExit()
		elseif status == "alive" and not pidStart then
			pidStart = startTime
			hs.settings.set(PID_START_KEY, startTime)
		end
	end)
end

-- Squeezelite stopped without being asked: update state and explain why
function obj:_onUnexpectedExit()
	pid, pidStart = nil, nil
	hs.settings.clear(PID_KEY)
	hs.settings.clear(PID_START_KEY)
	state = "stopped"
	self:_setWanted(false) -- don't restart a crashing player on the next reload
	self:_updateMenu()

	local reason = self:_lastLogLine()
	self.logger.w("Squeezelite stopped unexpectedly" .. (reason and (": " .. reason) or ""))
	if self.showAlerts then
		hs.alert.show("Squeezelite stopped unexpectedly" .. (reason and ("\n" .. reason) or ""))
	end
end

-- Last non-empty line of the log file, or nil
function obj:_lastLogLine()
	if not self.logFile or self.logFile == "" then
		return nil
	end
	local file = io.open(expandHome(self.logFile), "r")
	if not file then
		return nil
	end
	local size = file:seek("end")
	file:seek("set", math.max(0, size - 4096))
	local tail = file:read("a") or ""
	file:close()

	local last = nil
	for line in tail:gmatch("[^\r\n]+") do
		if line:match("%S") then
			last = line
		end
	end
	return last
end

-- Check whether `target` is our Squeezelite. callback(status, startTime), status is
-- "alive" (our binary, and the same start time if `expectedStart` is given),
-- "dead" (no such process, or a different program now uses the PID) or
-- "unknown" (ps could not be run).
function obj:_probe(target, expectedStart, callback)
	local wantName = basename(self.squeezelitePath or "Squeezelite")
	self:_runHelper("/bin/ps", { "-p", tostring(target), "-o", "lstart=", "-o", "comm=" }, function(exitCode, stdout)
		if exitCode == nil then
			callback("unknown")
			return
		end
		local startTime, command = stdout:match("^%s*(%a+%s+%a+%s+%d+%s+[%d:]+%s+%d+)%s+(.-)%s*$")
		if exitCode ~= 0 or not command then
			callback("dead")
		elseif basename(command) ~= wantName then
			callback("dead")      -- PID reused by another program
		elseif expectedStart and startTime ~= expectedStart then
			callback("dead")      -- PID reused by another Squeezelite
		else
			callback("alive", startTime)
		end
	end)
end

-- Run a short helper command with a deadline. callback(exitCode, stdout) is called
-- exactly once; exitCode is nil if the helper could not run or timed out.
function obj:_runHelper(path, args, callback)
	local done, timer = false, nil
	local task
	local function complete(exitCode, stdout)
		if done then return end
		done = true
		if timer then
			timer:stop()
		end
		callback(exitCode, stdout or "")
	end

	task = hs.task.new(path, function(exitCode, stdout) complete(exitCode, stdout) end, args)
	if not task or not task:start() then
		self.logger.e("Could not run " .. path)
		complete(nil, "")
		return
	end
	timer = hs.timer.doAfter(HELPER_TIMEOUT, function()
		timer = nil
		self.logger.w(path .. " did not finish within " .. HELPER_TIMEOUT .. "s")
		if task:isRunning() then
			task:terminate()
		end
		complete(nil, "")
	end)
end

-- Update the menu bar icon (or custom text) and tooltip
function obj:_updateMenu()
	if not menuBar then
		return
	end

	local playing = state == "running" or state == "stopping"
	local customText = playing and self.pauseIcon or self.playIcon
	if customText then
		menuBar:setIcon(nil)
		menuBar:setTitle(customText)
	else
		if not menuIcons then
			menuIcons = { on = drawPlayer(true), off = drawPlayer(false) }
		end
		local icon = playing and menuIcons.on or menuIcons.off
		if icon then
			menuBar:setTitle(nil)
			menuBar:setIcon(icon)
		else
			menuBar:setTitle(playing and "▮▮" or "▶") -- fallback if the icon could not be drawn
		end
	end

	local tooltips = {
		running = "Squeezelite: playing (click to stop)",
		stopped = "Squeezelite: stopped (click to start)",
		starting = "Squeezelite: starting…",
		stopping = "Squeezelite: stopping…",
		restoring = "Squeezelite: checking…",
	}
	menuBar:setTooltip(tooltips[state])
end

return obj
