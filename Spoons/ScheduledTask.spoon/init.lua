--- === ScheduledTask ===
---
--- Execute commands on configurable schedules
---
--- Download: https://github.com/sorinpohontu/Hammerspoon/releases
---
--- This Spoon provides scheduled execution of commands with support for:
--- - Interval-based scheduling (every N seconds)
--- - Time-based scheduling (specific times daily)
--- - Random time window scheduling (once per window at random time)
--- - Day-of-week filtering
--- - Output capture, notification and logging
--- - Success/error callbacks
---
--- Example configuration in init.lua:
---   hs.loadSpoon("ScheduledTask")
---   spoon.ScheduledTask:start()
---
--- Or with config file at ~/.hammerspoon/Spoons/ScheduledTask.spoon/config.lua:
---   return {
---     tasks = {
---       { name = "backup", command = "/usr/local/bin/backup.sh", interval = 3600 }
---     }
---   }

local obj = {}
obj.__index = obj

-- Metadata
obj.name = "ScheduledTask"
obj.version = "2.2.0"
obj.author = "Sorin Pohontu <sorin@frontline.ro>"
obj.homepage = "https://github.com/sorinpohontu/Hammerspoon"
obj.license = "BSD-3-Clause - https://opensource.org/license/bsd-3-clause"

--- ScheduledTask.logger
--- Variable
--- Logger object used within the Spoon
obj.logger = hs.logger.new('ScheduledTask')

--- ScheduledTask.enabled
--- Variable
--- If false, the Spoon loads but :start() does nothing
--- Default: true
obj.enabled = true

--- ScheduledTask.logLevel
--- Variable
--- Logger verbosity level: 'verbose', 'debug', 'info', 'warning', 'error'
--- Default: 'info'
obj.logLevel = "info"

--- ScheduledTask.showMenuBar
--- Variable
--- Boolean to show the menu bar indicator with task status
--- Default: false
obj.showMenuBar = false

--- ScheduledTask.showDisabledInMenu
--- Variable
--- Boolean to list disabled tasks in the menu
--- Default: true
obj.showDisabledInMenu = true

--- ScheduledTask.showTaskCountInMenu
--- Variable
--- Boolean to show the task count summary in the menu
--- Default: true
obj.showTaskCountInMenu = true

--- ScheduledTask.catchUpMinutes
--- Variable
--- Number of missed minutes (timer drift, short sleeps) to catch up for time-based
--- and random-window tasks. Longer gaps (e.g. overnight sleep) are not caught up.
--- Default: 5
obj.catchUpMinutes = 5

--- ScheduledTask.extraPath
--- Variable
--- Directories prepended to PATH for tasks (if not already present), since the
--- PATH Hammerspoon inherits from launchd does not include Homebrew or ~/.local/bin
--- Default: {"/opt/homebrew/bin", "/usr/local/bin", "~/.local/bin"}
obj.extraPath = { "/opt/homebrew/bin", "/usr/local/bin", "~/.local/bin" }

--- ScheduledTask.maxOutputBytes
--- Variable
--- Maximum output (stdout + stderr) kept per run. Output beyond this is dropped
--- and the kept output ends with a "[output truncated ...]" note.
--- Default: 1048576 (1 MB)
obj.maxOutputBytes = 1024 * 1024

-- Runtime state (public for inspection from the console)
obj.tasks = {}          -- Registered tasks keyed by name
obj.intervalTimers = {} -- Interval timers keyed by task name
obj.timeBasedTimer = nil -- Single shared minute timer for time-based and random tasks
obj.runningTasks = {}   -- hs.task objects keyed by task name
obj.lastRun = {}        -- Last start time (epoch seconds) keyed by task name, persisted
obj.menuBar = nil       -- Menu bar indicator

-- Internal state
local configTasks = {}      -- Task definitions loaded from config.lua
local runs = {}             -- Current run record per task name (see _executeTask)
local delayedAlerts = {}    -- Pending notifyDelay timers
local lastCheckedMinute = nil -- Last minute (epoch / 60) processed by the minute timer
local started = false
local generation = 0        -- Incremented by stop(); runs from an older generation are ignored
local menuIcons = nil -- { idle = hs.image, running = hs.image }, drawn on first use

-- Seconds to wait after a task exits for its final output chunk; hs.task may deliver
-- the last stream callback after the termination callback
local OUTPUT_GRACE = 0.5

-- Seconds between SIGTERM (timeout) and SIGKILL if the task is still running
local KILL_GRACE = 5

-- Config keys accepted from config.lua and their expected Lua types
local configTypes = {
	enabled = "boolean",
	logLevel = "string",
	showMenuBar = "boolean",
	showDisabledInMenu = "boolean",
	showTaskCountInMenu = "boolean",
	catchUpMinutes = "number",
	extraPath = "table",
	maxOutputBytes = "number",
	tasks = "table",
}

local function isFinite(n)
	return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge
end

local function isStringList(list)
	for key, value in pairs(list) do
		if math.type(key) ~= "integer" or type(value) ~= "string" then
			return false
		end
	end
	return true
end

-- Range checks for config values that passed the type check; return an error or nil
local configChecks = {
	catchUpMinutes = function(v)
		if not isFinite(v) or v < 0 or v ~= math.floor(v) then return "must be a whole number >= 0" end
	end,
	maxOutputBytes = function(v)
		if not isFinite(v) or v < 1024 then return "must be a number >= 1024" end
	end,
	extraPath = function(v)
		if not isStringList(v) then return "must be a list of folder paths (strings)" end
	end,
}

-- Every field a task definition may have, with its expected type(s).
-- Fields starting with "_" are internal (filled in by validation).
local TASK_FIELDS = {
	name = "string", command = "string",
	interval = "number|string", times = "table", timesRandom = "table",
	args = "table", argsRandom = "table", env = "table",
	days = "table", timeWindow = "table",
	enabled = "boolean", timeout = "number",
	captureOutput = "boolean", outputFile = "string",
	notify = "boolean", notifyOnError = "boolean", notifyLines = "number", notifyDelay = "number",
	onSuccess = "function", onError = "function",
	intervalDisplay = "string",
}

local DAY_NAMES = { "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" }

-- Lookup of accepted day spellings (full name or 3-letter abbreviation, any case)
local DAY_LOOKUP = {}
for _, day in ipairs(DAY_NAMES) do
	DAY_LOOKUP[day:lower()] = day
	DAY_LOOKUP[day:sub(1, 3):lower()] = day
end

-- Parse "HH:MM" into minutes since midnight, or nil if invalid
local function parseTime(timeStr)
	if type(timeStr) ~= "string" then
		return nil
	end
	local hour, min = timeStr:match("^(%d%d):(%d%d)$")
	if not hour then
		return nil
	end
	hour, min = tonumber(hour), tonumber(min)
	if hour > 23 or min > 59 then
		return nil
	end
	return hour * 60 + min
end

-- Validate an argument list; returns a new list of strings, or nil and an error message.
-- The legacy "quoted:" prefix is stripped: hs.task passes each argument verbatim, so
-- arguments containing spaces need no quoting.
local function normalizeArgs(args)
	if type(args) ~= "table" then
		return nil, "must be a table"
	end
	local result = {}
	for i, value in ipairs(args) do
		local arg = value
		if type(arg) == "number" then
			arg = tostring(arg)
		elseif type(arg) ~= "string" then
			return nil, "argument " .. i .. " must be a string"
		end
		if arg:sub(1, 7) == "quoted:" then
			arg = arg:sub(8)
		end
		table.insert(result, arg)
	end
	return result
end

-- Format a command line for logs, quoting arguments that contain special characters
local function formatCommandLine(command, args)
	local parts = { command }
	for _, arg in ipairs(args or {}) do
		if arg == "" or arg:match("[^%w%-%._/=:,@+%%]") then
			table.insert(parts, '"' .. arg:gsub('[\\"]', "\\%0") .. '"')
		else
			table.insert(parts, arg)
		end
	end
	return table.concat(parts, " ")
end

-- Expand a leading "~" to the home directory
local function expandHome(path)
	local home = os.getenv("HOME") or ""
	return (path:gsub("^~", function() return home end))
end

-- Extract non-empty lines from output
local function getNonEmptyLines(output)
	local lines = {}
	for line in output:gmatch("[^\n]+") do
		if line:match("%S") then
			table.insert(lines, line)
		end
	end
	return lines
end

-- Collect the first `count` non-empty lines of stdout followed by stderr
local function firstOutputLines(stdout, stderr, count)
	local lines = {}
	for _, output in ipairs({ stdout, stderr }) do
		for _, line in ipairs(getNonEmptyLines(output)) do
			if #lines >= count then
				return lines
			end
			table.insert(lines, line)
		end
	end
	return lines
end

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

-- Clock outline; a dot in the top-right corner while a task is running
local function drawClock(running)
	local elements = {
		{ type = "oval", action = "stroke", strokeColor = ink(), frame = { x = 2.25, y = 2.25, w = 13.5, h = 13.5 } },
		{ type = "segments", action = "stroke", strokeColor = ink(), closed = false,
		  strokeCapStyle = "round", strokeJoinStyle = "round",
		  coordinates = { { x = 9, y = 5.25 }, { x = 9, y = 9 }, { x = 11.75, y = 10.5 } } },
	}
	if running then
		-- Clear a gap around the dot, then draw the dot
		table.insert(elements, { type = "oval", action = "fill", fillColor = ink(), compositeRule = "clear",
			frame = { x = 11.25, y = 0.25, w = 6.5, h = 6.5 } })
		table.insert(elements, { type = "oval", action = "fill", fillColor = ink(),
			frame = { x = 12.25, y = 1.25, w = 4.5, h = 4.5 } })
	end
	return drawIcon(elements)
end


---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

--- ScheduledTask:init()
--- Method
--- Spoon initializer (called automatically when Spoon is loaded)
---
--- Parameters:
---  * None
---
--- Returns:
---  * The ScheduledTask object
function obj:init()
	self.logger.i("Initializing " .. self.name .. " v" .. self.version)
	self:_loadConfig()
	self.logger.setLogLevel(self.logLevel)
	return self
end

--- ScheduledTask:start()
--- Method
--- Schedule all tasks from config.lua and show the menu bar (if enabled)
---
--- Parameters:
---  * None
---
--- Returns:
---  * The ScheduledTask object
---
--- Notes:
---  * Does nothing when `ScheduledTask.enabled` is false, or when already started
---  * After stop(), start() schedules every registered task again, including
---    tasks added with addTask()
function obj:start()
	if not self.enabled then
		self.logger.i("Not starting ScheduledTask (enabled = false)")
		return self
	end
	if started then
		self.logger.d("ScheduledTask already started")
		return self
	end
	self.logger.i("Starting ScheduledTask.spoon")
	started = true

	-- Load last run times from persistent state
	self:_loadState()

	-- (Re)register the config.lua tasks; addTask() schedules them
	local fromConfig = {}
	for _, taskConfig in ipairs(self:_selectTaskDefinitions(configTasks)) do
		if self:addTask(taskConfig) then
			fromConfig[taskConfig.name] = true
		end
	end
	-- Tasks added from Lua (before start, or before a stop/start) are scheduled too
	for name, task in pairs(self.tasks) do
		if not fromConfig[name] and task.enabled then
			self:_scheduleTask(task)
		end
	end

	if self.showMenuBar then
		self:_setupMenuBar()
	end

	local count = 0
	for _ in pairs(self.tasks) do count = count + 1 end
	self.logger.i("ScheduledTask.spoon started with " .. count .. " task(s)")
	return self
end

--- ScheduledTask:stop()
--- Method
--- Cancel all timers, terminate running tasks and remove the menu bar
---
--- Parameters:
---  * None
---
--- Returns:
---  * The ScheduledTask object
---
--- Notes:
---  * Runs in progress are terminated and their results discarded: no output
---    file, alert or onSuccess/onError callback happens after stop()
---  * A terminated task stays in `runningTasks` until its process has exited, so
---    a new run of the same task cannot overlap it
function obj:stop()
	self.logger.i("Stopping ScheduledTask.spoon")
	started = false
	generation = generation + 1

	for name, timer in pairs(self.intervalTimers) do
		timer:stop()
		self.logger.d("Stopped timer for task: " .. name)
	end
	self.intervalTimers = {}

	if self.timeBasedTimer then
		self.timeBasedTimer:stop()
		self.timeBasedTimer = nil
		self.logger.d("Stopped time-based timer")
	end

	for _, timer in pairs(delayedAlerts) do
		timer:stop()
	end
	delayedAlerts = {}

	if self.menuBar then
		self.menuBar:delete()
		self.menuBar = nil
		self.logger.d("Removed menu bar")
	end

	for name, run in pairs(runs) do
		self:_cancelRun(run)
		if run.task:isRunning() then
			self:_terminateRun(run)
			self.logger.w("Terminating running task: " .. name)
		end
	end

	self.logger.i("ScheduledTask.spoon stopped")
	return self
end

---------------------------------------------------------------------------
-- Public methods
---------------------------------------------------------------------------

--- ScheduledTask:addTask(taskConfig)
--- Method
--- Validate a task definition, register it and schedule it (if enabled)
---
--- Parameters:
---  * taskConfig - Task configuration table (see README.md for fields)
---
--- Returns:
---  * true if the task was added, false if the definition is invalid
---
--- Notes:
---  * A task with the same name as an existing one replaces it
---  * Before start(), the task is registered and scheduled when start() runs
function obj:addTask(taskConfig)
	local ok, err = self:_validateTask(taskConfig)
	if not ok then
		local name = type(taskConfig) == "table" and taskConfig.name or nil
		self.logger.e("Task '" .. tostring(name) .. "' " .. err)
		return false
	end

	if self.tasks[taskConfig.name] then
		self:_cancelIntervalTimer(taskConfig.name)
	end
	self.tasks[taskConfig.name] = taskConfig

	if taskConfig.enabled and started then
		self:_scheduleTask(taskConfig)
	end

	local scheduleInfo = ""
	if taskConfig.interval then
		scheduleInfo = "interval: " .. taskConfig.intervalDisplay
	elseif taskConfig.times then
		scheduleInfo = "times: " .. table.concat(taskConfig.times, ", ")
	elseif taskConfig.timesRandom then
		scheduleInfo = #taskConfig.timesRandom .. " random windows"
	end
	local enabledStatus = taskConfig.enabled and "Enabled" or "Disabled"
	self.logger.i("Added task: " .. taskConfig.name .. " (" .. scheduleInfo .. ") [" .. enabledStatus .. "]")
	return true
end

--- ScheduledTask:removeTask(taskName)
--- Method
--- Remove a task from the schedule
---
--- Parameters:
---  * taskName - Name of the task to remove
---
--- Returns:
---  * The ScheduledTask object
---
--- Notes:
---  * A run already in progress is left to finish
function obj:removeTask(taskName)
	self:_cancelIntervalTimer(taskName)
	self.tasks[taskName] = nil
	self.lastRun[taskName] = nil
	self:_saveState()
	self.logger.i("Removed task: " .. taskName)
	return self
end

--- ScheduledTask:enableTask(taskName)
--- Method
--- Enable a disabled task
---
--- Parameters:
---  * taskName - Name of the task to enable
---
--- Returns:
---  * true if the task exists, false otherwise
---
--- Notes:
---  * Not persisted: the task's config.lua `enabled` value applies again after a reload
function obj:enableTask(taskName)
	local task = self.tasks[taskName]
	if not task then
		self.logger.w("Task not found: " .. taskName)
		return false
	end

	if task.enabled then
		-- Make sure it is actually scheduled (e.g. an interval timer that was lost)
		if started and task.interval and not self.intervalTimers[taskName] then
			self:_scheduleTask(task)
		end
		self.logger.d("Task already enabled: " .. taskName)
		return true
	end

	task.enabled = true
	if started then
		self:_scheduleTask(task)
	end
	self.logger.i("Enabled task: " .. taskName)
	return true
end

--- ScheduledTask:disableTask(taskName)
--- Method
--- Disable a task (a run already in progress is left to finish)
---
--- Parameters:
---  * taskName - Name of the task to disable
---
--- Returns:
---  * true if the task exists, false otherwise
---
--- Notes:
---  * Not persisted: the task's config.lua `enabled` value applies again after a reload
function obj:disableTask(taskName)
	local task = self.tasks[taskName]
	if not task then
		self.logger.w("Task not found: " .. taskName)
		return false
	end

	if not task.enabled then
		self.logger.d("Task already disabled: " .. taskName)
		return true
	end

	task.enabled = false
	self:_cancelIntervalTimer(taskName)
	self.logger.i("Disabled task: " .. taskName)
	return true
end

--- ScheduledTask:runTaskNow(taskName)
--- Method
--- Execute a task immediately, ignoring its schedule and filters
---
--- Parameters:
---  * taskName - Name of the task to run
---
--- Returns:
---  * true if the task was started, false otherwise
---
--- Notes:
---  * A manual run counts as the run for a random window that is currently open
function obj:runTaskNow(taskName)
	local task = self.tasks[taskName]
	if not task then
		self.logger.w("Task not found: " .. taskName)
		return false
	end

	self.logger.i("Manual execution of task: " .. taskName)
	return self:_executeTask(task)
end

---------------------------------------------------------------------------
-- Private methods
---------------------------------------------------------------------------

-- Load configuration from config.lua (called from init() so `enabled` is known before start())
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
		elseif key == "tasks" then
			configTasks = value
		else
			self[key] = value
		end
	end
	self.logger.i("Configuration loaded successfully")
end

-- Load persistent state (last run times)
function obj:_loadState()
	local file = io.open(self:_statePath(), "r")
	if not file then
		return
	end
	local content = file:read("*all")
	file:close()

	local success, state = pcall(hs.json.decode, content)
	if not (success and type(state) == "table" and type(state.lastRun) == "table") then
		self.logger.w("Could not parse state file, ignoring it")
		return
	end

	-- Keep only plausible entries: task name -> positive epoch seconds
	local lastRun, count = {}, 0
	for name, time in pairs(state.lastRun) do
		if type(name) == "string" and isFinite(time) and time > 0 then
			lastRun[name] = time
			count = count + 1
		else
			self.logger.w("Ignoring invalid last-run entry in state file: " .. tostring(name) .. " = " .. tostring(time))
		end
	end
	self.lastRun = lastRun
	self.logger.d("Loaded state with " .. count .. " task(s)")
end

-- Save persistent state (last run times). Written to a temporary file and renamed
-- over the old one, so a failed write never leaves a truncated state file.
-- Last-run times are best-effort: they prevent double runs across reloads, but are
-- not a guarantee of exactly-once execution.
function obj:_saveState()
	local success, json = pcall(hs.json.encode, { lastRun = self.lastRun })
	if not success then
		self.logger.w("Could not encode state: " .. tostring(json))
		return
	end

	local path = self:_statePath()
	local tmpPath = path .. ".tmp"
	local file, openErr = io.open(tmpPath, "w")
	if not file then
		self.logger.w("Could not write state file: " .. tostring(openErr))
		return
	end
	local wrote, writeErr = file:write(json)
	local closed, closeErr = file:close()
	if not wrote or not closed then
		self.logger.w("Could not write state file: " .. tostring(writeErr or closeErr))
		os.remove(tmpPath)
		return
	end
	local renamed, renameErr = os.rename(tmpPath, path)
	if not renamed then
		self.logger.w("Could not replace state file: " .. tostring(renameErr))
		os.remove(tmpPath)
		return
	end
	self.logger.d("Saved state")
end

-- Path of the persistent state file
function obj:_statePath()
	local base = self.spoonPath
	if not base or base == "" then
		base = os.getenv("HOME") .. "/.hammerspoon/Spoons/" .. self.name .. ".spoon"
	end
	return base .. "/state.json"
end

-- Resolve duplicate task names: keep the enabled definition, or the last one if both or neither are enabled
function obj:_selectTaskDefinitions(definitions)
	local selected, order = {}, {}
	for _, def in ipairs(definitions) do
		if type(def) ~= "table" or type(def.name) ~= "string" then
			self.logger.e("Ignoring task definition without a 'name' field")
		elseif not selected[def.name] then
			selected[def.name] = def
			table.insert(order, def.name)
		else
			local prevEnabled = selected[def.name].enabled ~= false
			local currEnabled = def.enabled ~= false
			self.logger.e("DUPLICATE TASK NAME DETECTED: '" .. def.name .. "' is defined multiple times in config!")
			self.logger.e("  First definition:  enabled=" .. tostring(prevEnabled))
			self.logger.e("  Second definition: enabled=" .. tostring(currEnabled))
			if prevEnabled and not currEnabled then
				self.logger.e("Using first definition (enabled)")
			else
				self.logger.e(currEnabled and not prevEnabled and "Using second definition (enabled)" or
					"Using last definition")
				selected[def.name] = def
			end
		end
	end

	local result = {}
	for _, name in ipairs(order) do
		table.insert(result, selected[name])
	end
	return result
end

-- Validate a task definition and fill in parsed fields and defaults.
-- Returns true, or false and an error message.
function obj:_validateTask(taskConfig)
	if type(taskConfig) ~= "table" then
		return false, "definition must be a table"
	end
	if type(taskConfig.name) ~= "string" or taskConfig.name == "" then
		return false, "must have a 'name' field"
	end
	if type(taskConfig.command) ~= "string" or taskConfig.command == "" then
		return false, "must have a 'command' field"
	end

	-- Every field must be known and of the right type
	for key, value in pairs(taskConfig) do
		local expected = TASK_FIELDS[key]
		if type(key) ~= "string" then
			return false, "has a field with a non-string name"
		elseif key:sub(1, 1) ~= "_" then
			if not expected then
				return false, "has unknown field '" .. key .. "'"
			elseif not expected:find(type(value), 1, true) then
				return false, string.format("field '%s' must be %s, got %s", key, (expected:gsub("|", " or ")), type(value))
			elseif type(value) == "number" and not isFinite(value) then
				return false, "field '" .. key .. "' must be a finite number"
			end
		end
	end
	if taskConfig.timeout ~= nil and taskConfig.timeout < 0 then
		return false, "timeout must be >= 0 (0 = no timeout)"
	end
	if taskConfig.notifyLines ~= nil and (taskConfig.notifyLines < 0 or taskConfig.notifyLines ~= math.floor(taskConfig.notifyLines)) then
		return false, "notifyLines must be a whole number >= 0"
	end
	if taskConfig.notifyDelay ~= nil and taskConfig.notifyDelay < 0 then
		return false, "notifyDelay must be >= 0"
	end
	if taskConfig.env ~= nil then
		for key, value in pairs(taskConfig.env) do
			if type(key) ~= "string" or (type(value) ~= "string" and type(value) ~= "number") then
				return false, "env must be a table of NAME = \"value\" pairs"
			end
		end
	end

	-- Exactly one scheduling mode
	local schedulingModes = 0
	if taskConfig.interval then schedulingModes = schedulingModes + 1 end
	if taskConfig.times then schedulingModes = schedulingModes + 1 end
	if taskConfig.timesRandom then schedulingModes = schedulingModes + 1 end
	if schedulingModes == 0 then
		return false, "must have one of: 'interval', 'times', or 'timesRandom'"
	elseif schedulingModes > 1 then
		return false, "cannot have multiple scheduling modes"
	end

	-- Interval: plain seconds or human-readable "30s", "5m", "2h"
	if taskConfig.interval then
		local interval = taskConfig.interval
		if type(interval) == "string" then
			local value, unit = interval:match("^(%d+)([smh])$")
			if not value then
				return false, "invalid interval format (use: 30s, 5m, 2h)"
			end
			taskConfig.intervalDisplay = interval
			interval = tonumber(value) * ({ s = 1, m = 60, h = 3600 })[unit]
		elseif type(interval) == "number" then
			taskConfig.intervalDisplay = taskConfig.intervalDisplay or (interval .. "s")
		else
			return false, "interval must be a number or string (30s, 5m, 2h)"
		end
		if interval <= 0 then
			return false, "interval must be positive"
		end
		taskConfig.interval = interval
	end

	-- Times: list of "HH:MM"
	if taskConfig.times then
		if type(taskConfig.times) ~= "table" or #taskConfig.times == 0 then
			return false, "times must be a non-empty table"
		end
		taskConfig._timeSet = {}
		for _, timeStr in ipairs(taskConfig.times) do
			local minutes = parseTime(timeStr)
			if not minutes then
				return false, "invalid time: " .. tostring(timeStr) .. " (expected HH:MM, 00:00-23:59)"
			end
			taskConfig._timeSet[minutes] = true
		end
	end

	-- Random windows: list of {start = "HH:MM", stop = "HH:MM"} within one day
	if taskConfig.timesRandom then
		if type(taskConfig.timesRandom) ~= "table" or #taskConfig.timesRandom == 0 then
			return false, "timesRandom must be a non-empty table"
		end
		taskConfig._windows = {}
		for i, window in ipairs(taskConfig.timesRandom) do
			if type(window) ~= "table" then
				return false, "timesRandom[" .. i .. "] must have 'start' and 'stop' fields"
			end
			local startMinutes, stopMinutes = parseTime(window.start), parseTime(window.stop)
			if not startMinutes or not stopMinutes then
				return false, "timesRandom[" .. i .. "] invalid time format (expected HH:MM, 00:00-23:59)"
			end
			if startMinutes > stopMinutes then
				return false, "timesRandom[" .. i .. "] cannot cross midnight; split it into two windows"
			end
			table.insert(taskConfig._windows, { start = startMinutes, stop = stopMinutes, index = i })
		end
		-- Windows must not overlap (a shared minute counts as overlap): the task runs
		-- once per window, and "has it run" is judged from the last run time
		local sorted = {}
		for _, window in ipairs(taskConfig._windows) do table.insert(sorted, window) end
		table.sort(sorted, function(a, b) return a.start < b.start end)
		for i = 2, #sorted do
			if sorted[i].start <= sorted[i - 1].stop then
				return false, string.format("timesRandom[%d] and timesRandom[%d] overlap; windows must not share any minute",
					sorted[i - 1].index, sorted[i].index)
			end
		end
	end

	-- Time window restriction for interval tasks (may cross midnight)
	if taskConfig.timeWindow then
		if not taskConfig.interval then
			self.logger.w("Task '" .. taskConfig.name .. "' timeWindow is only applicable for interval-based tasks")
		end
		local window = taskConfig.timeWindow
		if type(window) ~= "table" then
			return false, "timeWindow must have 'start' and 'stop' fields"
		end
		local startMinutes, stopMinutes = parseTime(window.start), parseTime(window.stop)
		if not startMinutes or not stopMinutes then
			return false, "timeWindow invalid time format (expected HH:MM, 00:00-23:59)"
		end
		taskConfig._timeWindow = { start = startMinutes, stop = stopMinutes }
	end

	-- Days: full names or 3-letter abbreviations, any case
	if taskConfig.days then
		if type(taskConfig.days) ~= "table" then
			return false, "days must be a table of day names"
		end
		local days = {}
		for _, day in ipairs(taskConfig.days) do
			local canonical = type(day) == "string" and DAY_LOOKUP[day:lower()]
			if not canonical then
				return false, "unknown day: " .. tostring(day)
			end
			table.insert(days, canonical)
		end
		taskConfig.days = days
	end

	-- Arguments
	if taskConfig.args and taskConfig.argsRandom then
		return false, "cannot have both 'args' and 'argsRandom'"
	end
	if taskConfig.args then
		local args, argErr = normalizeArgs(taskConfig.args)
		if not args then
			return false, "args " .. argErr
		end
		taskConfig.args = args
	end
	if taskConfig.argsRandom then
		if type(taskConfig.argsRandom) ~= "table" or #taskConfig.argsRandom == 0 then
			return false, "argsRandom must be a non-empty table"
		end
		for i, argSet in ipairs(taskConfig.argsRandom) do
			local args, argErr = normalizeArgs(argSet)
			if not args then
				return false, "argsRandom[" .. i .. "] " .. argErr
			end
			taskConfig.argsRandom[i] = args
		end
	end

	-- Defaults
	if taskConfig.enabled == nil then
		taskConfig.enabled = true
	end
	if taskConfig.timeout == nil then
		taskConfig.timeout = 300 -- 5 minutes; 0 or negative disables the timeout
	end
	if taskConfig.captureOutput == nil then
		taskConfig.captureOutput = false
	end

	return true
end

-- Schedule a task with its configured mode (interval, times, or timesRandom)
function obj:_scheduleTask(taskConfig)
	if taskConfig.times or taskConfig.timesRandom then
		-- Time-based and random-window tasks share the minute timer
		self:_ensureTimeBasedTimer()
		self.logger.d("Scheduled time-based task: " .. taskConfig.name)
		return
	end

	-- Interval-based: dedicated timer per task. The first run is due `interval` seconds
	-- after the persisted last run, so reloads don't restart the countdown.
	local name = taskConfig.name
	local interval = taskConfig.interval
	self:_cancelIntervalTimer(name)

	local function fire()
		if self:_shouldRunNow(taskConfig) then
			self:_executeTask(taskConfig)
		end
	end

	local firstDelay = interval
	if self.lastRun[name] then
		firstDelay = math.min(interval, math.max(1, self.lastRun[name] + interval - os.time()))
	end

	self.intervalTimers[name] = hs.timer.doAfter(firstDelay, function()
		self.intervalTimers[name] = hs.timer.doEvery(interval, fire)
		fire()
	end)

	self.logger.d(string.format("Scheduled interval-based task: %s (every %s, next run in %ds)",
		name, taskConfig.intervalDisplay, math.floor(firstDelay)))
end

-- Stop and forget a task's interval timer
function obj:_cancelIntervalTimer(taskName)
	if self.intervalTimers[taskName] then
		self.intervalTimers[taskName]:stop()
		self.intervalTimers[taskName] = nil
	end
end

-- Start the shared minute timer (aligned to the start of each minute) if not running
function obj:_ensureTimeBasedTimer()
	if self.timeBasedTimer then
		return
	end

	-- Process the current minute on the first tick as well
	lastCheckedMinute = math.floor(os.time() / 60) - 1

	local delay = 60 - os.date("*t").sec + 0.5
	self.logger.d(string.format("Starting time-based timer (first tick in %.1fs)", delay))

	self.timeBasedTimer = hs.timer.doAfter(delay, function()
		self.timeBasedTimer = hs.timer.doEvery(60, function() self:_onMinuteTick() end)
		self:_onMinuteTick()
	end)
end

-- Process every minute since the last tick, so timer drift doesn't skip scheduled times
function obj:_onMinuteTick()
	local currentMinute = math.floor(os.time() / 60)
	local firstMinute = math.max(lastCheckedMinute + 1, currentMinute - self.catchUpMinutes)
	local skipped = firstMinute - (lastCheckedMinute + 1)
	if skipped > 0 then
		self.logger.i("Skipped " .. skipped .. " minute(s) (sleep or timer delay), not catching up")
	end
	lastCheckedMinute = currentMinute

	for minute = firstMinute, currentMinute do
		self:_checkMinute(minute)
	end
end

-- Run time-based and random-window tasks due in the given minute (epoch / 60)
function obj:_checkMinute(minute)
	local minuteStart = minute * 60
	local t = os.date("*t", minuteStart)
	local minuteOfDay = t.hour * 60 + t.min
	local timeLabel = string.format("%02d:%02d", t.hour, t.min)

	for name, task in pairs(self.tasks) do
		if task.enabled and (task._timeSet or task._windows) and self:_shouldRunToday(task.days, minuteStart) then
			if task._timeSet then
				if task._timeSet[minuteOfDay] and not self:_ranSince(name, minuteStart) then
					self.logger.d("Time-based execution triggered for: " .. name .. " at " .. timeLabel)
					self:_executeTask(task)
				end
			else
				for windowIndex, window in ipairs(task._windows) do
					if minuteOfDay >= window.start and minuteOfDay <= window.stop then
						local windowStart = minuteStart - (minuteOfDay - window.start) * 60
						if not self:_ranSince(name, windowStart) then
							-- 1 / remaining minutes gives a uniform pick and guarantees a run in the last minute
							local probability = 1 / (window.stop - minuteOfDay + 1)
							if math.random() < probability then
								self.logger.d(string.format(
									"Random-time execution triggered for: %s at %s (window %d, probability: %.2f%%)",
									name, timeLabel, windowIndex, probability * 100))
								self:_executeTask(task)
							end
						end
						break
					end
				end
			end
		end
	end
end

-- True if the task was started at or after the given epoch time
function obj:_ranSince(taskName, epoch)
	local last = self.lastRun[taskName]
	return last ~= nil and last >= epoch
end

-- Check day and time window restrictions for interval tasks
function obj:_shouldRunNow(taskConfig)
	if not self:_shouldRunToday(taskConfig.days) then
		return false
	end
	if taskConfig._timeWindow and not self:_isInTimeWindow(taskConfig._timeWindow) then
		return false
	end
	return true
end

-- Check if the current time is within a parsed window ({start, stop} in minutes);
-- a window with start > stop crosses midnight
function obj:_isInTimeWindow(window)
	local now = os.date("*t")
	local current = now.hour * 60 + now.min
	if window.start <= window.stop then
		return current >= window.start and current <= window.stop
	end
	return current >= window.start or current <= window.stop
end

-- Check the day-of-week filter for the given time (default: now)
function obj:_shouldRunToday(taskDays, time)
	if not taskDays or #taskDays == 0 then
		return true
	end
	local today = DAY_NAMES[os.date("*t", time or os.time()).wday]
	for _, day in ipairs(taskDays) do
		if day == today then
			return true
		end
	end
	return false
end

-- Execute a task; returns true if it was started
--
-- Each run has its own record (task, timers, output, generation). Only that record's
-- callbacks may change its timers or the task's "running" state, so a late callback
-- from an earlier run can never affect a newer one.
function obj:_executeTask(taskConfig)
	local name = taskConfig.name
	if self.runningTasks[name] then
		self.logger.w("Task already running: " .. name)
		return false
	end

	local args, argsIndex = taskConfig.args, nil
	if taskConfig.argsRandom then
		argsIndex = math.random(1, #taskConfig.argsRandom)
		args = taskConfig.argsRandom[argsIndex]
	end
	local cmdLine = formatCommandLine(taskConfig.command, args)

	self.logger.i("Executing task: " .. name)
	self.logger.d("Command: " .. cmdLine)

	local run = {
		name = name,
		generation = generation,
		collect = taskConfig.captureOutput or taskConfig.onSuccess or taskConfig.onError,
		stdout = {}, stderr = {},
		keptBytes = 0, droppedBytes = 0,
		exitCode = nil, finished = false, cancelled = false, timedOut = false,
	}

	-- Keep output up to maxOutputBytes (stdout + stderr together)
	local function keep(list, data)
		if not run.collect or run.cancelled or not data or #data == 0 then
			return
		end
		local room = self.maxOutputBytes - run.keptBytes
		if room <= 0 then
			run.droppedBytes = run.droppedBytes + #data
			return
		end
		if #data > room then
			table.insert(list, data:sub(1, room))
			run.droppedBytes = run.droppedBytes + #data - room
			run.keptBytes = run.keptBytes + room
		else
			table.insert(list, data)
			run.keptBytes = run.keptBytes + #data
		end
	end

	local function finish()
		if run.finished then return end
		run.finished = true
		if run.graceTimer then
			run.graceTimer:stop()
			run.graceTimer = nil
		end
		if run.cancelled or run.generation ~= generation then
			return
		end
		local stdout = table.concat(run.stdout)
		if run.droppedBytes > 0 then
			stdout = stdout .. string.format("\n[output truncated: %d bytes not kept, limit %d bytes]",
				run.droppedBytes, self.maxOutputBytes)
		end
		if run.timedOut then
			self.logger.w("Task '" .. name .. "' was stopped by its timeout (" .. taskConfig.timeout .. "s)")
		end
		self:_onTaskFinished(taskConfig, run.exitCode, stdout, table.concat(run.stderr), cmdLine, argsIndex, args)
	end

	local task = hs.task.new(taskConfig.command,
		function(code)
			run.exitCode = code
			for _, key in ipairs({ "timeoutTimer", "killTimer" }) do
				if run[key] then
					run[key]:stop()
					run[key] = nil
				end
			end
			if self.runningTasks[name] == run.task then
				self.runningTasks[name] = nil
			end
			if runs[name] == run then
				runs[name] = nil
			end
			self:_updateMenuIcon()
			if run.cancelled or run.generation ~= generation then
				self.logger.d("Discarding result of cancelled run: " .. name)
				return
			end
			-- The final output chunk may arrive after this callback; wait for it briefly
			run.graceTimer = hs.timer.doAfter(OUTPUT_GRACE, finish)
		end,
		function(streamTask, stdoutData, stderrData)
			keep(run.stdout, stdoutData)
			keep(run.stderr, stderrData)
			-- A nil task marks the final chunk after termination
			if streamTask == nil and run.exitCode ~= nil then
				finish()
			end
			return true
		end,
		args or {}
	)

	if not task then
		self.logger.e("Failed to create task: " .. name .. " (command: " .. taskConfig.command .. ")")
		return false
	end
	run.task = task

	-- Inherit Hammerspoon's environment, mark it non-interactive and extend PATH
	local env = task:environment()
	env.TERM = "dumb"
	env.CI = "true"
	env.PATH = self:_buildPath(env.PATH)
	for key, value in pairs(taskConfig.env or {}) do
		env[key] = tostring(value)
	end
	task:setEnvironment(env)
	task:setWorkingDirectory(os.getenv("HOME"))

	if not task:start() then
		self.logger.e("Failed to start task: " .. name)
		return false
	end
	-- Send EOF on stdin so commands that read input don't hang
	task:closeInput()

	runs[name] = run
	self.runningTasks[name] = task
	self.lastRun[name] = os.time()
	self:_saveState()
	self:_updateMenuIcon()
	self.logger.d("Task started, PID: " .. tostring(task:pid()))

	if taskConfig.timeout and taskConfig.timeout > 0 then
		run.timeoutTimer = hs.timer.doAfter(taskConfig.timeout, function()
			run.timeoutTimer = nil
			if task:isRunning() then
				self.logger.w("Task timeout after " .. taskConfig.timeout .. "s, terminating: " .. name)
				run.timedOut = true
				self:_terminateRun(run)
			end
		end)
	end

	return true
end

-- Build PATH for tasks: extraPath entries first (if missing), then the inherited PATH
function obj:_buildPath(inheritedPath)
	local path = inheritedPath or "/usr/bin:/bin:/usr/sbin:/sbin"
	local present = {}
	for dir in path:gmatch("[^:]+") do
		present[dir] = true
	end
	local prefix = {}
	for _, entry in ipairs(self.extraPath or {}) do
		local dir = expandHome(entry)
		if not present[dir] then
			table.insert(prefix, dir)
			present[dir] = true
		end
	end
	if #prefix == 0 then
		return path
	end
	return table.concat(prefix, ":") .. ":" .. path
end

-- Mark a run as cancelled: its result is discarded and its pending timers stopped
-- (the kill timer is kept, so a terminated process is still made to exit)
function obj:_cancelRun(run)
	run.cancelled = true
	for _, key in ipairs({ "timeoutTimer", "graceTimer" }) do
		if run[key] then
			run[key]:stop()
			run[key] = nil
		end
	end
end

-- Ask a run's process to exit: SIGTERM now, SIGKILL after KILL_GRACE seconds if still running
function obj:_terminateRun(run)
	if not run.task:isRunning() then
		return
	end
	run.task:terminate()
	if run.killTimer then
		return
	end
	run.killTimer = hs.timer.doAfter(KILL_GRACE, function()
		run.killTimer = nil
		if run.task:isRunning() then
			local pid = run.task:pid()
			self.logger.w(string.format("Task '%s' ignored SIGTERM; sending SIGKILL to PID %s", run.name, tostring(pid)))
			local killer = hs.task.new("/bin/kill", nil, { "-KILL", tostring(pid) })
			if not killer or not killer:start() then
				self.logger.e("Could not send SIGKILL to task '" .. run.name .. "' (PID " .. tostring(pid) .. ")")
			end
		end
	end)
end

-- Handle a finished run: output file, notification, callbacks and logging
function obj:_onTaskFinished(taskConfig, exitCode, stdout, stderr, cmdLine, argsIndex, args)
	local name = taskConfig.name
	self.logger.d(string.format("Task completed: %s with exit code %d (stdout %d bytes, stderr %d bytes)",
		name, exitCode, #stdout, #stderr))

	if taskConfig.captureOutput then
		if taskConfig.outputFile then
			self:_writeOutputFile(taskConfig, exitCode, stdout, stderr, cmdLine, argsIndex, args)
		end

		local hasLines = taskConfig.notifyLines and taskConfig.notifyLines > 0
		if hasLines and (taskConfig.notify or (taskConfig.notifyOnError and exitCode ~= 0)) then
			self:_showOutputNotification(taskConfig, stdout, stderr)
		end
	end

	local callback, callbackName
	if exitCode == 0 then
		self.logger.i("Task completed successfully: " .. name)
		callback, callbackName = taskConfig.onSuccess, "onSuccess"
	else
		self.logger.e("Task failed with exit code " .. exitCode .. ": " .. name)
		self.logger.e("Command: " .. cmdLine)
		callback, callbackName = taskConfig.onError, "onError"
	end

	if callback then
		local ok, err
		if exitCode == 0 then
			ok, err = pcall(callback, stdout, stderr)
		else
			ok, err = pcall(callback, exitCode, stdout, stderr)
		end
		if not ok then
			self.logger.e("Task '" .. name .. "' " .. callbackName .. " callback failed: " .. tostring(err))
		end
	end
end

-- Append a run record to the task's outputFile
function obj:_writeOutputFile(taskConfig, exitCode, stdout, stderr, cmdLine, argsIndex, args)
	local path = expandHome(taskConfig.outputFile)
	local file = io.open(path, "a")
	if not file then
		self.logger.w("Could not write to output file: " .. path)
		return
	end

	file:write(string.format("[%s] %s\n", os.date("%Y-%m-%d %H:%M:%S"), taskConfig.name))
	file:write("Command: " .. cmdLine .. "\n")
	if argsIndex then
		local argsText = formatCommandLine("", args):sub(2)
		file:write("Args set: " .. argsIndex .. " (" .. argsText .. ")\n")
	end

	if taskConfig.notifyLines and taskConfig.notifyLines > 0 then
		local lines = firstOutputLines(stdout, stderr, taskConfig.notifyLines)
		if #lines > 0 then
			file:write("Output (first " .. #lines .. " lines):\n")
			file:write(table.concat(lines, "\n") .. "\n\n")
		end
	else
		if stdout ~= "" then
			file:write("STDOUT:\n" .. stdout .. "\n")
		end
		if stderr ~= "" then
			file:write("STDERR:\n" .. stderr .. "\n")
		end
	end

	file:write("Exit code: " .. exitCode .. "\n\n")
	file:close()
end

-- Show an on-screen alert with the first notifyLines output lines
function obj:_showOutputNotification(taskConfig, stdout, stderr)
	local text = table.concat(firstOutputLines(stdout, stderr, taskConfig.notifyLines), "\n")
	if text == "" then
		self.logger.d("No non-empty output lines to show for task: " .. taskConfig.name)
		return
	end

	local function show()
		hs.alert.show(text, 3)
		self.logger.d("Alert shown for task: " .. taskConfig.name)
	end

	if (taskConfig.notifyDelay or 0) > 0 then
		-- Tracked so stop() can cancel it
		local timer
		timer = hs.timer.doAfter(taskConfig.notifyDelay, function()
			delayedAlerts[timer] = nil
			show()
		end)
		delayedAlerts[timer] = timer
	else
		show()
	end
end

-- Create the menu bar indicator; the menu is rebuilt each time it is opened
function obj:_setupMenuBar()
	if self.menuBar then
		return
	end

	self.menuBar = hs.menubar.new()
	if not self.menuBar then
		self.logger.e("Failed to create menu bar")
		return
	end

	self.menuBar:setTooltip("ScheduledTask")
	self.menuBar:setMenu(function() return self:_buildMenu() end)
	self:_updateMenuIcon()
	self.logger.d("Menu bar setup complete")
end

-- Show the clock icon, with a dot while any task is running
function obj:_updateMenuIcon()
	if not self.menuBar then
		return
	end
	if not menuIcons then
		menuIcons = { idle = drawClock(false), running = drawClock(true) }
	end
	local running = next(self.runningTasks) ~= nil
	local icon = running and menuIcons.running or menuIcons.idle
	if icon then
		self.menuBar:setIcon(icon)
	else
		self.menuBar:setTitle("⏱") -- fallback if the icon could not be drawn
	end
end

-- Build the menu table with current task status
function obj:_buildMenu()
	local names = {}
	local enabledTasks, runningTasks = 0, 0
	for name, task in pairs(self.tasks) do
		table.insert(names, name)
		if task.enabled then enabledTasks = enabledTasks + 1 end
		if self.runningTasks[name] then runningTasks = runningTasks + 1 end
	end
	table.sort(names)

	local menuItems = {
		{ title = string.format("📋 ScheduledTask v%s", self.version), disabled = true },
	}
	if self.showTaskCountInMenu then
		table.insert(menuItems, {
			title = string.format("Tasks: %d total, %d enabled, %d running", #names, enabledTasks, runningTasks),
			disabled = true
		})
	end
	table.insert(menuItems, { title = "-" })

	for _, name in ipairs(names) do
		local task = self.tasks[name]
		if task.enabled or self.showDisabledInMenu then
			local status = "⏸"
			if task.enabled then
				status = self.runningTasks[name] and "▶" or "⏵"
			end

			local schedulingInfo = ""
			if task.interval then
				schedulingInfo = "every " .. task.intervalDisplay
			elseif task.times then
				schedulingInfo = string.format("%d times/day", #task.times)
			elseif task.timesRandom then
				schedulingInfo = string.format("%d windows/day", #task.timesRandom)
			end

			local lastRunText = self.lastRun[name] and os.date("%Y-%m-%d %H:%M:%S", self.lastRun[name]) or "never"
			local fontName = task.enabled and "Helvetica-Bold" or "Helvetica-Oblique"
			local title = hs.styledtext.new(status .. " ") ..
				hs.styledtext.new(name, { font = { name = fontName, size = 13 } })

			table.insert(menuItems, {
				title = title,
				tooltip = string.format("%s | %s | Last run: %s", schedulingInfo,
					task.enabled and "Enabled" or "Disabled", lastRunText),
				fn = function()
					if task.enabled then
						self:disableTask(name)
					else
						self:enableTask(name)
					end
				end
			})
		end
	end

	table.insert(menuItems, { title = "-" })
	table.insert(menuItems, { title = "⟳ Reload Config", fn = function() hs.reload() end })
	return menuItems
end

return obj
