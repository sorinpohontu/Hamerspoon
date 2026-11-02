--- === CaffeinateControl ===
---
--- Menu bar toggle to prevent system sleep with state persistence.
---
--- Provides a menu bar control to toggle sleep prevention. Automatically
--- restores the caffeinate state after screen unlock or screensaver stop.

local obj = {}
obj.__index = obj

-- Metadata
obj.name = "CaffeinateControl"
obj.version = "1.2.0"
obj.author = "Sorin Pohontu <sorin@frontline.ro>"
obj.homepage = "https://github.com/sorinpohontu/Hammerspoon"
obj.license = "BSD-3-Clause - https://opensource.org/license/bsd-3-clause"

--- CaffeinateControl.logger
--- Variable
--- Logger object used within the Spoon
obj.logger = hs.logger.new('CaffeinateControl')

--- CaffeinateControl.enabled
--- Variable
--- If false, the Spoon loads but :start() does nothing
--- Default: true
obj.enabled = true

--- CaffeinateControl.logLevel
--- Variable
--- Logger verbosity level: 'debug', 'info', 'warning', 'error'
--- Default: 'info'
obj.logLevel = 'info'

--- CaffeinateControl.startCaffeinated
--- Variable
--- Boolean to enable caffeinate on startup
--- Default: true
obj.startCaffeinated = true

--- CaffeinateControl.showAlerts
--- Variable
--- Boolean to show/hide alert messages
--- Default: true
obj.showAlerts = true

--- CaffeinateControl.menuIcon
--- Variable
--- Custom menu bar icon while caffeinate is on: an image path or an "ASCII:" diagram
--- (see hs.menubar:setIcon). nil uses the built-in steaming cup.
--- Default: nil
obj.menuIcon = nil

--- CaffeinateControl.menuIconOff
--- Variable
--- Custom menu bar icon while caffeinate is off. nil uses the built-in dimmed cup,
--- or menuIcon when only menuIcon is set.
--- Default: nil
obj.menuIconOff = nil

-- Internal state
local menuBar = nil
local powerWatcher = nil
local shouldCaffeinate = nil   -- The user's choice; nil until the first start()
local locked = false            -- Screen is locked
local screensaverActive = false -- Screensaver is running
local builtInIcons = nil -- { on = hs.image, off = hs.image }, drawn on first use

-- Config keys accepted from config.lua and their expected Lua types
local configTypes = {
    enabled = "boolean",
    logLevel = "string",
    startCaffeinated = "boolean",
    showAlerts = "boolean",
    menuIcon = "string",
    menuIconOff = "string",
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

-- Coffee cup outline; with steam when on, dimmed when off. The handle starts
-- outside the body stroke so the dimmed strokes don't overlap (overlaps look darker)
local function drawCup(on)
    local color = ink(on and 1 or 0.45)
    local elements = {
        -- Cup body
        { type = "rectangle", action = "stroke", strokeColor = color,
          frame = { x = 2.75, y = 6.5, w = 10, h = 8.5 }, roundedRectRadii = { xRadius = 2.5, yRadius = 2.5 } },
        -- Handle
        { type = "segments", action = "stroke", strokeColor = color, closed = false,
          coordinates = { { x = 13.45, y = 8.5 }, { x = 13.45, y = 13, c1x = 16.6, c1y = 8.5, c2x = 16.6, c2y = 13 } } },
    }
    if on then
        for _, x in ipairs({ 5.25, 7.75, 10.25 }) do
            table.insert(elements, { type = "segments", action = "stroke", strokeColor = color, closed = false,
                strokeCapStyle = "round", strokeWidth = 1.2,
                coordinates = { { x = x, y = 4.75 }, { x = x, y = 1.25, c1x = x - 1.4, c1y = 3.6, c2x = x + 1.4, c2y = 2.4 } } })
        end
    end
    return drawIcon(elements)
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

--- CaffeinateControl:init()
--- Method
--- Spoon initializer (called automatically when Spoon is loaded)
---
--- Parameters:
---  * None
---
--- Returns:
---  * The CaffeinateControl object
function obj:init()
    self.logger.i("Initializing CaffeinateControl")
    self:_loadConfig()
    self.logger.setLogLevel(self.logLevel)
    return self
end

--- CaffeinateControl:start()
--- Method
--- Start the Spoon and initialize the menu bar
---
--- Parameters:
---  * None
---
--- Returns:
---  * The CaffeinateControl object
---
--- Notes:
---  * Does nothing when `CaffeinateControl.enabled` is false, or when already started
---  * `startCaffeinated` applies to the first start only; after stop()/start()
---    the user's last choice is kept
function obj:start()
    if not self.enabled then
        self.logger.i("Not starting CaffeinateControl (enabled = false)")
        return self
    end
    if menuBar or powerWatcher then
        self.logger.d("CaffeinateControl already started")
        return self
    end
    self.logger.i("Starting CaffeinateControl")

    if shouldCaffeinate == nil then
        shouldCaffeinate = self.startCaffeinated
    end
    -- Hammerspoon may (re)load while the screen is locked
    locked = self:_isScreenLocked()
    screensaverActive = false

    menuBar = hs.menubar.new()
    if menuBar then
        menuBar:setClickCallback(function()
            self:toggle()
        end)
    end

    -- Set initial caffeinate state
    self:setCaffeinate(shouldCaffeinate)

    -- Set up power watcher for screen lock/unlock and screensaver events
    powerWatcher = hs.caffeinate.watcher.new(function(event)
        self:_onPowerEvent(event)
    end)
    powerWatcher:start()

    return self
end

--- CaffeinateControl:stop()
--- Method
--- Stop the Spoon and cleanup resources
---
--- Parameters:
---  * None
---
--- Returns:
---  * The CaffeinateControl object
function obj:stop()
    self.logger.i("Stopping CaffeinateControl")

    -- Release the sleep-prevention assertion
    self:_apply(false)

    -- Stop power watcher
    if powerWatcher then
        powerWatcher:stop()
        powerWatcher = nil
    end

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

--- CaffeinateControl:toggle()
--- Method
--- Toggle the caffeinate state
---
--- Parameters:
---  * None
---
--- Returns:
---  * The CaffeinateControl object
function obj:toggle()
    self.logger.d("Toggling caffeinate state")
    shouldCaffeinate = not shouldCaffeinate
    self:setCaffeinate(shouldCaffeinate)
    return self
end

--- CaffeinateControl:setCaffeinate(state)
--- Method
--- Explicitly set the caffeinate state (the user's preference, restored after unlock)
---
--- Parameters:
---  * state - Boolean: true to enable caffeinate, false to disable
---
--- Returns:
---  * The CaffeinateControl object
function obj:setCaffeinate(state)
    self.logger.f("Setting caffeinate to %s", state)
    shouldCaffeinate = state
    self:_applyCurrent()

    if menuBar then
        local icon = self:_icon(state)
        if icon then
            menuBar:setIcon(icon)
        else
            menuBar:setTitle(state and "☕" or "·") -- fallback if the icon could not be drawn
        end
        menuBar:setTooltip(state and "Caffeinate: on (click to disable)" or "Caffeinate: off (click to enable)")
    end

    if self.showAlerts then
        if state then
            hs.alert.show("Caffeinate enabled")
        else
            hs.alert.show("Caffeinate disabled")
        end
    end

    return self
end

--- CaffeinateControl:isCaffeinated()
--- Method
--- Get the caffeinate preference
---
--- Parameters:
---  * None
---
--- Returns:
---  * Boolean: true if caffeinate is enabled (it is suspended while the screen is locked)
function obj:isCaffeinated()
    return shouldCaffeinate == true
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
        else
            self[key] = value
        end
    end
    self.logger.i("Configuration loaded successfully")
end

-- Private helper: is the screen locked right now? (false if it cannot be determined)
function obj:_isScreenLocked()
    local ok, props = pcall(hs.caffeinate.sessionProperties)
    if not ok or type(props) ~= "table" then
        return false
    end
    local value = props.CGSSessionScreenIsLocked
    return value == true or value == 1
end

-- Private helper function to handle power events. Lock and screensaver are tracked
-- separately: sleep prevention resumes only when both are over.
function obj:_onPowerEvent(event)
    local watcher = hs.caffeinate.watcher
    if event == watcher.screensDidLock then
        locked = true
    elseif event == watcher.screensDidUnlock then
        locked = false
    elseif event == watcher.screensaverDidStart then
        screensaverActive = true
    elseif event == watcher.screensaverDidStop then
        screensaverActive = false
    else
        return
    end

    -- Name of the event constant (e.g. "screensDidUnlock") for a readable log line
    local eventName = tostring(event)
    for name, value in pairs(watcher) do
        if value == event and type(name) == "string" then
            eventName = name
            break
        end
    end
    self.logger.f("%s: locked=%s, screensaver=%s, caffeinate wanted=%s",
        eventName, locked, screensaverActive, shouldCaffeinate)
    self:_applyCurrent()
end

-- Private helper: apply the user's choice, suspended while locked or in the screensaver
function obj:_applyCurrent()
    local active = shouldCaffeinate == true and not locked and not screensaverActive
    self:_apply(active)
end

-- Private helper to apply sleep prevention without changing the user's preference
function obj:_apply(state)
    hs.caffeinate.set("displayIdle", state, true)
end

-- Private helper returning the menu bar icon for the given state
function obj:_icon(state)
    if self.menuIcon then
        return state and self.menuIcon or (self.menuIconOff or self.menuIcon)
    end
    if not state and self.menuIconOff then
        return self.menuIconOff
    end
    if not builtInIcons then
        builtInIcons = { on = drawCup(true), off = drawCup(false) }
    end
    return state and builtInIcons.on or builtInIcons.off
end

return obj
