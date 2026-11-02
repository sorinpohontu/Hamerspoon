--- === WindowManager ===
---
--- Hotkey-based window positioning and resizing for macOS.
---
--- Provides keyboard shortcuts to center windows, move them to halves,
--- and resize to fullscreen with proper handling of macOS window decorations.

local obj = {}
obj.__index = obj

-- Metadata
obj.name = "WindowManager"
obj.version = "1.3.0"
obj.author = "Sorin Pohontu <sorin@frontline.ro>"
obj.homepage = "https://github.com/sorinpohontu/Hammerspoon"
obj.license = "BSD-3-Clause - https://opensource.org/license/bsd-3-clause"

--- WindowManager.logger
--- Variable
--- Logger object used within the Spoon. Can be accessed to set the default log level for the messages coming from the Spoon.
obj.logger = hs.logger.new('WindowManager')

--- WindowManager.enabled
--- Variable
--- If false, the Spoon loads but :start() does nothing
--- Default: true
obj.enabled = true

--- WindowManager.logLevel
--- Variable
--- Logger verbosity level: 'verbose', 'debug', 'info', 'warning', 'error'
--- Default: 'info'
obj.logLevel = 'info'

--- WindowManager.showAlerts
--- Variable
--- Boolean to show/hide alert messages for window operations
--- Default: true
obj.showAlerts = true

--- WindowManager.frameOffset
--- Variable
--- Table with offsets to account for macOS window decorations
--- Offsets: {x = horizontal gap, y = top offset, h = bottom offset}
--- Default: {x = 2, y = 2, h = 6}
obj.frameOffset = { x = 2, y = 2, h = 6 }

--- WindowManager.defaultHotkeys
--- Variable
--- Hotkeys bound by start() (set from `hotkeys` in config.lua); see bindHotkeys().
--- Multiple hotkeys can be bound to the same action by providing a table of hotkeys.
--- Default: center ⌘⌥⌃C / F16, topRight ⌘⇧T, halfLeft ⌘⇧[, halfRight ⌘⇧], fullDesktop ⌘⇧0 / F13
obj.defaultHotkeys = {
	center = { { { "cmd", "alt", "ctrl" }, "C" }, { nil, "F16" } },
	topRight = { { "cmd", "shift" }, "T" },
	halfLeft = { { "cmd", "shift" }, "[" },
	halfRight = { { "cmd", "shift" }, "]" },
	fullDesktop = { { { "cmd", "shift" }, "0" }, { nil, "F13" } }
}

-- Internal state
local hotkeyBindings = {}

-- Config keys accepted from config.lua and their expected Lua types
local configTypes = {
	enabled = "boolean",
	logLevel = "string",
	showAlerts = "boolean",
	frameOffset = "table",
	hotkeys = "table",
}

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

--- WindowManager:init()
--- Method
--- Spoon initializer (called automatically when Spoon is loaded)
---
--- Parameters:
---  * None
---
--- Returns:
---  * The WindowManager object
function obj:init()
	self.logger.i("Initializing WindowManager")
	self:_loadConfig()
	self.logger.setLogLevel(self.logLevel)
	return self
end

--- WindowManager:start()
--- Method
--- Start the Spoon and bind default hotkeys
---
--- Parameters:
---  * None
---
--- Returns:
---  * The WindowManager object
---
--- Notes:
---  * Does nothing when `WindowManager.enabled` is false
function obj:start()
	if not self.enabled then
		self.logger.i("Not starting WindowManager (enabled = false)")
		return self
	end
	self.logger.i("Starting WindowManager")
	self:bindHotkeys(self.defaultHotkeys)
	return self
end

--- WindowManager:stop()
--- Method
--- Stop the Spoon and cleanup hotkeys
---
--- Parameters:
---  * None
---
--- Returns:
---  * The WindowManager object
function obj:stop()
	self.logger.i("Stopping WindowManager")
	self:_clearHotkeys()
	return self
end

---------------------------------------------------------------------------
-- Public methods
---------------------------------------------------------------------------

--- WindowManager:bindHotkeys(mapping)
--- Method
--- Binds hotkeys for WindowManager
---
--- Parameters:
---  * mapping - A table containing hotkey modifier/key pairs for the following items:
---    * center - Center window (can be single hotkey or array of hotkeys)
---    * topRight - Move to top right
---    * halfLeft - Move to half left
---    * halfRight - Move to half right
---    * fullDesktop - Full desktop (can be single hotkey or array of hotkeys)
---
--- Returns:
---  * The WindowManager object
---
--- Notes:
---  * Hotkey format: {modifiers, key} where modifiers is a table like {"cmd", "shift"}
---  * Multiple hotkeys can be assigned to one action:
---    ```lua
---    spoon.WindowManager:bindHotkeys({
---      center = {{{"cmd", "alt", "ctrl"}, "C"}, {nil, "F16"}},  -- Two hotkeys
---      topRight = {{"cmd", "shift"}, "T"}                       -- Single hotkey
---    })
---    ```
function obj:bindHotkeys(mapping)
	self.logger.d("Binding hotkeys")

	-- Remove previous hotkeys
	self:_clearHotkeys()

	if not mapping then return self end

	-- Helper to bind a hotkey if specified; an invalid key is logged instead of
	-- aborting the remaining bindings
	local function bindKey(name, keys, callback)
		if type(keys) ~= "table" or keys[2] == nil then
			self.logger.w("Invalid hotkey spec for " .. name)
			return
		end
		local ok, hotkey = pcall(hs.hotkey.bind, keys[1] or {}, keys[2], callback)
		if ok and hotkey then
			table.insert(hotkeyBindings, hotkey)
			self.logger.d("Bound hotkey: " .. name)
		else
			self.logger.e("Failed to bind hotkey " .. name .. " (" .. tostring(keys[2]) .. "): " .. tostring(hotkey))
		end
	end

	-- Helper to bind one or more hotkeys to an action
	local function bindAction(actionName, hotkeySpec, callback)
		if hotkeySpec == nil then return end
		if type(hotkeySpec) ~= "table" then
			self.logger.w("Invalid hotkey spec for " .. actionName .. " (expected {modifiers, key})")
			return
		end

		-- A single hotkey has format: {modifiers, key} where modifiers is a table or nil
		--   Example: {{"cmd", "shift"}, "T"} or {nil, "F16"}
		-- Multiple hotkeys have format: {{modifiers, key}, {modifiers, key}, ...}
		--   Example: {{{"cmd", "shift"}, "T"}, {nil, "F16"}} or {{{"cmd"}, "T"}}
		--
		-- A string (or keycode number) in the second position means a single hotkey;
		-- anything else is a list, including a one-element list
		local keyType = type(hotkeySpec[2])
		local isMultiple = keyType ~= "string" and keyType ~= "number"

		if isMultiple then
			-- Multiple hotkeys
			for i, keys in ipairs(hotkeySpec) do
				bindKey(actionName .. "_" .. i, keys, callback)
			end
		else
			-- Single hotkey
			bindKey(actionName, hotkeySpec, callback)
		end
	end

	local actions = {
		center = function() self:centerWindow() end,
		topRight = function() self:topRight() end,
		halfLeft = function() self:halfLeft() end,
		halfRight = function() self:halfRight() end,
		fullDesktop = function() self:fullDesktop() end,
	}
	for name in pairs(mapping) do
		if not actions[name] then
			self.logger.w("Unknown hotkey action: " .. tostring(name))
		end
	end
	-- Each action is bound on its own, so one malformed entry cannot stop the others
	for _, name in ipairs({ "center", "topRight", "halfLeft", "halfRight", "fullDesktop" }) do
		local ok, err = pcall(bindAction, name, mapping[name], actions[name])
		if not ok then
			self.logger.e("Failed to bind hotkeys for " .. name .. ": " .. tostring(err))
		end
	end

	return self
end

--- WindowManager:centerWindow()
--- Method
--- Center the focused window on the current screen
---
--- Parameters:
---  * None
---
--- Returns:
---  * The WindowManager object
function obj:centerWindow()
	self.logger.d("Centering window")

	local win = hs.window.focusedWindow()
	if not win then
		self.logger.w("No focused window")
		return self
	end

	local frame = win:frame()
	local desktop = win:screen():frame()

	frame.x = desktop.x + ((desktop.w - frame.w) / 2)
	frame.y = desktop.y + ((desktop.h - frame.h) / 2)

	win:setFrame(frame)

	if self.showAlerts then
		hs.alert.show("Desktop Center")
	end

	return self
end

--- WindowManager:topRight()
--- Method
--- Move the focused window to the top right of the current screen
---
--- Parameters:
---  * None
---
--- Returns:
---  * The WindowManager object
function obj:topRight()
	self.logger.d("Moving window to top right")

	local win = hs.window.focusedWindow()
	if not win then
		self.logger.w("No focused window")
		return self
	end

	local frame = win:frame()
	local desktop = win:screen():frame()

	frame.x = desktop.x + (desktop.w - frame.w)
	frame.y = desktop.y + self.frameOffset.y

	win:setFrame(frame)

	if self.showAlerts then
		hs.alert.show("Top Right")
	end

	return self
end

--- WindowManager:halfLeft()
--- Method
--- Move the focused window to the left half of the current screen
---
--- Parameters:
---  * None
---
--- Returns:
---  * The WindowManager object
function obj:halfLeft()
	self.logger.d("Moving window to half left")

	local win = hs.window.focusedWindow()
	if not win then
		self.logger.w("No focused window")
		return self
	end

	local frame = win:frame()
	local desktop = win:screen():frame()

	frame.x = desktop.x
	frame.y = desktop.y + self.frameOffset.y
	frame.w = desktop.w / 2
	frame.h = desktop.h - self.frameOffset.h

	win:setFrame(frame)

	if self.showAlerts then
		hs.alert.show("Half Left")
	end

	return self
end

--- WindowManager:halfRight()
--- Method
--- Move the focused window to the right half of the current screen
---
--- Parameters:
---  * None
---
--- Returns:
---  * The WindowManager object
function obj:halfRight()
	self.logger.d("Moving window to half right")

	local win = hs.window.focusedWindow()
	if not win then
		self.logger.w("No focused window")
		return self
	end

	local frame = win:frame()
	local desktop = win:screen():frame()

	frame.x = desktop.x + (desktop.w / 2) + self.frameOffset.x
	frame.y = desktop.y + self.frameOffset.y
	frame.w = desktop.w / 2 - self.frameOffset.x
	frame.h = desktop.h - self.frameOffset.h

	win:setFrame(frame)

	if self.showAlerts then
		hs.alert.show("Half Right")
	end

	return self
end

--- WindowManager:fullDesktop()
--- Method
--- Resize the focused window to fill the entire screen (accounting for decorations)
---
--- Parameters:
---  * None
---
--- Returns:
---  * The WindowManager object
function obj:fullDesktop()
	self.logger.d("Resizing window to full desktop")

	local win = hs.window.focusedWindow()
	if not win then
		self.logger.w("No focused window")
		return self
	end

	local frame = win:frame()
	local desktop = win:screen():frame()

	frame.x = desktop.x
	frame.y = desktop.y + self.frameOffset.y
	frame.w = desktop.w
	frame.h = desktop.h - self.frameOffset.h

	win:setFrame(frame)

	if self.showAlerts then
		hs.alert.show("Full Desktop")
	end

	return self
end

---------------------------------------------------------------------------
-- Private methods
---------------------------------------------------------------------------

--- WindowManager:_loadConfig()
--- Method
--- Private helper function to load configuration from config.lua
---
--- Parameters:
---  * None
---
--- Returns:
---  * None
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
		elseif key == "frameOffset" then
			-- Merge so a partial table (e.g. {y = 0}) keeps the other defaults
			for k, v in pairs(value) do
				if type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge then
					self.frameOffset[k] = v
				else
					self.logger.w("Ignoring frameOffset." .. tostring(k) .. " (must be a finite number)")
				end
			end
		elseif key == "hotkeys" then
			self.defaultHotkeys = value
		else
			self[key] = value
		end
	end
	self.logger.i("Configuration loaded successfully")
end

-- Private helper to delete all bound hotkeys
function obj:_clearHotkeys()
	for _, hotkey in ipairs(hotkeyBindings) do
		hotkey:delete()
	end
	hotkeyBindings = {}
end

return obj
