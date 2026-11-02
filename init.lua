-- Hammerspoon Configuration Loader
-- Each Spoon is self-contained: it reads its own config.lua when loaded, and its
-- :start() does nothing when that config sets enabled = false.
-- Each Spoon is isolated: an error in one is logged and does not stop the others.

local initLog = hs.logger.new("init")

local function loadAndStart(name)
	local ok, err = pcall(function()
		local s = hs.loadSpoon(name)
		if not s then
			initLog.e(name .. " could not be loaded")
			return
		end
		s:start()
	end)
	if not ok then
		initLog.e(name .. " failed: " .. tostring(err))
		hs.alert.show(name .. " failed to load - see Console")
	end
end

loadAndStart("WindowManager")
loadAndStart("CaffeinateControl")
loadAndStart("SqueezeliteManager")
loadAndStart("DiskTemp")
loadAndStart("ScheduledTask")

initLog.i("Hammerspoon configuration loaded")
