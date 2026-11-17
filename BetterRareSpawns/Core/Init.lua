-- BetterRareSpawns: namespace, event bus, shared helpers.
local ADDON, ns = ...

ns.ADDON = ADDON
ns.VERSION = "0.2.0"
ns.PREFIX = "|cff4fc3f7BRS|r"

-------------------------------------------------------------------------------
-- Secret values
-- Newer clients hand addons opaque "secret" values in restricted situations
-- (combat, instances). They cannot be compared, indexed or concatenated, so
-- every value read from a unit API goes through Clean() first.
-------------------------------------------------------------------------------
local issecretvalue = _G.issecretvalue

--- Returns v, or nil when v is a secret value.
function ns.Clean(v)
	if issecretvalue and issecretvalue(v) then
		return nil
	end
	return v
end

-------------------------------------------------------------------------------
-- Error-isolated calls: one broken handler must never stop the others.
-------------------------------------------------------------------------------
local function Report(err)
	local handler = geterrorhandler and geterrorhandler()
	if handler then
		handler(err)
	end
end

function ns.SafeCall(fn, ...)
	local ok, a, b, c = xpcall(fn, Report, ...)
	if ok then
		return a, b, c
	end
end

-------------------------------------------------------------------------------
-- Game events
-------------------------------------------------------------------------------
local eventFrame = CreateFrame("Frame")
local eventHandlers = {}

--- Registers fn for a game event. Unknown events (other client flavors) are ignored.
function ns.OnEvent(event, fn)
	local list = eventHandlers[event]
	if not list then
		-- RegisterEvent raises on event names the client does not know.
		if not pcall(eventFrame.RegisterEvent, eventFrame, event) then
			return false
		end
		list = {}
		eventHandlers[event] = list
	end
	list[#list + 1] = fn
	return true
end

eventFrame:SetScript("OnEvent", function(_, event, ...)
	local list = eventHandlers[event]
	if list then
		for i = 1, #list do
			ns.SafeCall(list[i], ...)
		end
	end
end)

-------------------------------------------------------------------------------
-- Internal messages (module -> module, no hard dependencies)
-------------------------------------------------------------------------------
local listeners = {}

function ns.Listen(message, fn)
	local list = listeners[message]
	if not list then
		list = {}
		listeners[message] = list
	end
	list[#list + 1] = fn
end

function ns.Fire(message, ...)
	local list = listeners[message]
	if list then
		for i = 1, #list do
			ns.SafeCall(list[i], ...)
		end
	end
end

-------------------------------------------------------------------------------
-- Output
-------------------------------------------------------------------------------
function ns.Print(...)
	local out = ns.PREFIX
	for i = 1, select("#", ...) do
		out = out .. " " .. tostring((select(i, ...)))
	end
	if DEFAULT_CHAT_FRAME then
		DEFAULT_CHAT_FRAME:AddMessage(out)
	else
		print(out)
	end
end

function ns.Debug(...)
	if ns.db and ns.db.settings.debug then
		ns.Print("|cff888888[debug]|r", ...)
	end
end

-------------------------------------------------------------------------------
-- Deferred work that touches protected frames: runs now, or once combat ends.
-------------------------------------------------------------------------------
local afterCombat = {}

function ns.OutOfCombat(key, fn)
	if InCombatLockdown() then
		afterCombat[key] = fn
	else
		afterCombat[key] = nil
		fn()
	end
end

ns.OnEvent("PLAYER_REGEN_ENABLED", function()
	for key, fn in pairs(afterCombat) do
		afterCombat[key] = nil
		ns.SafeCall(fn)
	end
end)

-------------------------------------------------------------------------------
-- Startup: modules register ns.Listen("READY", ...) and run once the saved
-- variables exist and the player is in the world.
-------------------------------------------------------------------------------
local loaded, loggedIn, ready

local function TryReady()
	if loaded and loggedIn and not ready then
		ready = true
		ns.Fire("READY")
	end
end

ns.OnEvent("ADDON_LOADED", function(name)
	if name == ADDON then
		ns.DB.Load()
		loaded = true
		TryReady()
	end
end)

ns.OnEvent("PLAYER_LOGIN", function()
	loggedIn = true
	TryReady()
end)
