-- Minimal stand-in for the WoW client API, enough to load the addon and drive
-- it through events in plain Lua 5.1. Anything not modelled here is a no-op.

local T = {} -- test controls, returned to the spec
T.now = 1000000 -- server time
T.clock = 100 -- GetTime
T.errors = {}
T.frames = {}
T.units = {} -- [unitToken] = { guid, name, level, class, dead, type }
T.player = { map = 1429, x = 0.5, y = 0.5 }
T.combat = false
T.instance = false
T.chat = {}
T.sent = {}

-------------------------------------------------------------------------------
-- Frames: every unknown method is a no-op, a few have real behaviour.
-------------------------------------------------------------------------------
local Frame = {}
local function NewObject(kind, name)
	local object = { __kind = kind, __name = name, __scripts = {}, __attributes = {}, __shown = true, __events = {} }
	return setmetatable(object, Frame)
end

local methods = {}
function methods:SetScript(script, fn) self.__scripts[script] = fn end
function methods:GetScript(script) return self.__scripts[script] end
function methods:HookScript(script, fn) self.__scripts[script] = fn end
function methods:Show()
	local was = self.__shown
	self.__shown = true
	if not was and self.__scripts.OnShow then self.__scripts.OnShow(self) end
end
function methods:Hide()
	local was = self.__shown
	self.__shown = false
	if was and self.__scripts.OnHide then self.__scripts.OnHide(self) end
end
function methods:SetShown(shown) if shown then self:Show() else self:Hide() end end
function methods:IsShown() return self.__shown end
function methods:IsVisible() return self.__shown end
function methods:RegisterEvent(event)
	if T.unknownEvents and T.unknownEvents[event] then error("unknown event " .. event) end
	self.__events[event] = true
end
function methods:SetAttribute(key, value) self.__attributes[key] = value end
function methods:GetAttribute(key) return self.__attributes[key] end
function methods:SetText(text) self.__text = text end
function methods:GetText() return self.__text end
function methods:GetWidth() return self.__width or 200 end
function methods:GetHeight() return self.__height or 100 end
function methods:SetWidth(w) self.__width = w end
function methods:SetHeight(h) self.__height = h end
function methods:SetSize(w, h) self.__width, self.__height = w, h end
function methods:GetStringHeight() return 12 end
function methods:GetScale() return self.__scale or 1 end
function methods:SetScale(scale) self.__scale = scale end
function methods:GetEffectiveScale() return 1 end
function methods:GetAlpha() return self.__alpha or 1 end
function methods:SetAlpha(alpha) self.__alpha = alpha end
function methods:GetCenter() return 400, 300 end
function methods:GetFrameLevel() return 1 end
function methods:IsMouseOver() return false end
function methods:GetPoint() return "CENTER", nil, "CENTER", 0, 0 end
function methods:GetZoom() return 0 end
function methods:GetMapID() return T.mapShown or 1429 end
function methods:GetCanvasScale() return T.canvasScale or 1 end
function methods:CreateTexture() return NewObject("Texture") end
function methods:CreateFontString() return NewObject("FontString") end
function methods:CreateMaskTexture() return NewObject("Mask") end
function methods:CreateAnimationGroup() return NewObject("AnimationGroup") end
function methods:CreateAnimation() return NewObject("Animation") end
function methods:AddMessage(text) T.chat[#T.chat + 1] = text end
function methods:Insert(text) T.chat[#T.chat + 1] = text end

local noop = function() end
Frame.__index = function(_, key)
	if methods[key] then
		return methods[key]
	end
	-- Unknown capitalised names are API methods; anything else is a plain
	-- field that was never set.
	if type(key) == "string" and key:match("^%u") then
		return noop
	end
	return nil
end

function CreateFrame(kind, name, parent, template)
	local frame = NewObject(kind, name)
	frame.__parent, frame.__template = parent, template
	T.frames[#T.frames + 1] = frame
	if name then _G[name] = frame end
	return frame
end

UIParent = CreateFrame("Frame", "UIParent")
UIParent.__width, UIParent.__height = 1920, 1080
Minimap = CreateFrame("Frame", "Minimap")
Minimap.__width = 140
WorldMapFrame = CreateFrame("Frame", "WorldMapFrame")
WorldMapFrame.ScrollContainer = CreateFrame("Frame")
WorldMapFrame.ScrollContainer.Child = CreateFrame("Frame")
WorldMapFrame.ScrollContainer.Child.__width = 1000
WorldMapFrame.ScrollContainer.Child.__height = 660
WorldMapFrame.OnCanvasScaleChanged = noop
GameTooltip = CreateFrame("GameTooltip", "GameTooltip")
DEFAULT_CHAT_FRAME = CreateFrame("Frame")
UIErrorsFrame = CreateFrame("Frame")
UISpecialFrames = {}
SlashCmdList = {}
UNKNOWNOBJECT = "Unknown"

--- Fires a game event at every frame that registered for it.
function T.Fire(event, ...)
	for _, frame in ipairs(T.frames) do
		if frame.__events[event] and frame.__scripts.OnEvent then
			frame.__scripts.OnEvent(frame, event, ...)
		end
	end
end

--- Runs every OnUpdate handler once with the given delta.
function T.Update(delta)
	for i = 1, #T.frames do
		local frame = T.frames[i]
		if frame.__shown and frame.__scripts.OnUpdate then
			frame.__scripts.OnUpdate(frame, delta)
		end
	end
end

-------------------------------------------------------------------------------
-- Lua helpers the client adds
-------------------------------------------------------------------------------
strlower, strfind, strsub, strmatch, gsub, format = string.lower, string.find, string.sub, string.match, string.gsub, string.format
function strtrim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
function strsplit(sep, text)
	local parts, from = {}, 1
	while true do
		local at = string.find(text, sep, from, true)
		if not at then
			parts[#parts + 1] = string.sub(text, from)
			break
		end
		parts[#parts + 1] = string.sub(text, from, at - 1)
		from = at + 1
	end
	return unpack(parts)
end
-- The client's xpcall forwards extra arguments; stock Lua 5.1 does not.
local stockXpcall = xpcall
function xpcall(fn, handler, ...)
	local args, count = { ... }, select("#", ...)
	return stockXpcall(function() return fn(unpack(args, 1, count)) end, handler)
end
function wipe(t) for k in pairs(t) do t[k] = nil end return t end
function hooksecurefunc(owner, name, hook)
	local original = owner[name]
	owner[name] = function(...)
		local a, b, c = original(...)
		hook(...)
		return a, b, c
	end
end
function geterrorhandler()
	return function(err) T.errors[#T.errors + 1] = tostring(err) end
end

-------------------------------------------------------------------------------
-- Secret values
-------------------------------------------------------------------------------
T.SECRET = setmetatable({}, { __tostring = function() return "<secret>" end })
function issecretvalue(v) return v == T.SECRET end

-------------------------------------------------------------------------------
-- Time and timers
-------------------------------------------------------------------------------
function GetTime() return T.clock end
function GetServerTime() return T.now end

local timers = {}
local function AddTimer(delay, fn, repeating)
	local timer = { at = T.clock + delay, fn = fn, every = repeating and delay or nil }
	function timer:Cancel() self.cancelled = true end
	function timer:IsCancelled() return self.cancelled end
	timers[#timers + 1] = timer
	return timer
end
C_Timer = {
	After = function(delay, fn) AddTimer(delay, fn) end,
	NewTimer = function(delay, fn) return AddTimer(delay, fn) end,
	NewTicker = function(delay, fn) return AddTimer(delay, fn, true) end,
}

--- Moves both clocks forward, running timers that come due.
function T.Advance(seconds)
	local target = T.clock + seconds
	while true do
		local nextTimer
		for _, timer in ipairs(timers) do
			if not timer.cancelled and timer.at <= target and (not nextTimer or timer.at < nextTimer.at) then
				nextTimer = timer
			end
		end
		if not nextTimer then break end
		T.now = T.now + (nextTimer.at - T.clock)
		T.clock = nextTimer.at
		if nextTimer.every then
			nextTimer.at = nextTimer.at + nextTimer.every
		else
			nextTimer.cancelled = true
		end
		nextTimer.fn(nextTimer)
	end
	T.now = T.now + (target - T.clock)
	T.clock = target
end

-------------------------------------------------------------------------------
-- Units
-------------------------------------------------------------------------------
local function U(unit, field)
	local data = T.units[unit]
	if not data then return nil end
	if data.secret then return T.SECRET end
	return data[field]
end
function UnitGUID(unit) return U(unit, "guid") end
function UnitName(unit) if unit == "player" then return "Tester" end return U(unit, "name") end
function UnitLevel(unit) return U(unit, "level") end
function UnitClassification(unit) return U(unit, "class") end
function UnitCreatureType(unit) return U(unit, "type") end
function UnitIsDead(unit) local d = U(unit, "dead") if d == nil then return false end return d end
function UnitExists(unit) return T.units[unit] ~= nil end
function UnitPlayerControlled() return false end
function CheckInteractDistance(unit) local d = T.units[unit] return d ~= nil and not d.far end
function GetRaidTargetIndex() return nil end
function SetRaidTarget(unit, index) T.marked = index end

function InCombatLockdown() return T.combat end
function IsInInstance() return T.instance end
function GetLocale() return "enUS" end
function IsInGuild() return true end
function IsInGroup() return T.grouped end
function IsInRaid() return false end
function IsAltKeyDown() return T.alt end
function IsShiftKeyDown() return T.shift end
function IsControlKeyDown() return T.ctrl end
date = os.date
T.said = {}
function SendChatMessage(text, chatType, _, target) T.said[#T.said + 1] = { text, chatType, target } end
function GetChannelList() return 1, "General - Elwynn Forest", false, 2, "Trade", false end
function UnitCreatureFamily(unit) local data = T.units[unit] return data and data.family end
UNIT_SKINNABLE_LEATHER = "Skinnable"
C_TooltipInfo = { GetUnit = function(unit)
	local data = T.units[unit]
	return { lines = { { leftText = data and data.name }, { leftText = data and data.tooltip } } }
end }
function GetCursorPosition() return 0, 0 end
T.items = {} -- [itemID] = { name, quality }
function GetItemInfo(itemID)
	local item = T.items[itemID]
	if item then return item[1], "[" .. item[1] .. "]", item[2] end
end
-- The player is "Tester" on "Realm". "none" keeps the realm of other realms.
function GetNormalizedRealmName() return "Realm" end
function Ambiguate(name, mode)
	if mode == "none" then
		return (name:gsub("%-Realm$", ""))
	end
	return (name:gsub("%-.*", ""))
end
function PlaySound(kit) T.sound = kit end
function FlashClientIcon() T.flashed = true end
function GetCVar() return "0" end
function GetPlayerFacing() return 0 end
function GetNumLootItems() return 0 end
T.bindings = {} -- [key] = command
function GetBindingKey(command)
	for key, bound in pairs(T.bindings) do
		if bound == command then return key end
	end
	return nil
end
function GetBindingAction(key) return T.bindings[key] or "" end
function SetBinding(key, command) T.bindings[key] = command return true end
function SaveBindings() T.bindingsSaved = true end
function GetCurrentBindingSet() return 1 end
function CreateVector2D(x, y) return { x = x, y = y, GetXY = function() return x, y end } end
function ChatEdit_GetActiveWindow() return nil end
function ChatFrame_OpenChat(text) T.chat[#T.chat + 1] = text end
SOUNDKIT = { RAID_WARNING = 8959 }
Enum = { UIMapType = { Continent = 2, Zone = 3 } }

-------------------------------------------------------------------------------
-- Maps: two zones (1429 Elwynn, 1433 Redridge) under continent 1415.
-------------------------------------------------------------------------------
local maps = {
	[1415] = { mapID = 1415, name = "Eastern Kingdoms", mapType = 2, parentMapID = 947 },
	[1429] = { mapID = 1429, name = "Elwynn Forest", mapType = 3, parentMapID = 1415 },
	[1433] = { mapID = 1433, name = "Redridge Mountains", mapType = 3, parentMapID = 1415 },
}
local function Vector(x, y)
	return { GetXY = function() return x, y end }
end
C_Map = {
	GetBestMapForUnit = function() return T.player.map end,
	GetPlayerMapPosition = function()
		if not T.player.x then return nil end
		return Vector(T.player.x, T.player.y)
	end,
	GetMapInfo = function(mapID) return maps[mapID] end,
	GetMapWorldSize = function() return 3000, 2000 end,
	-- Elwynn (1429) and Redridge (1433) side by side: Redridge starts where
	-- Elwynn ends, 3000 yards further east (world y falls eastward).
	GetWorldPosFromMapPos = function(mapID, point)
		local left = ({ [1429] = 0, [1433] = -3000 })[mapID]
		if not left then return nil end
		return 0, Vector(1000 - point.y * 2000, left - point.x * 3000)
	end,
	GetMapRectOnMap = function(from, to)
		if to == 1415 and from == 1429 then return 0.4, 0.5, 0.6, 0.7 end
		if to == 1415 and from == 1433 then return 0.5, 0.6, 0.6, 0.7 end
	end,
	GetMapChildrenInfo = function() return { maps[1429], maps[1433] } end,
	GetAreaInfo = function(areaID) return ({ [12] = "Elwynn Forest", [44] = "Redridge Mountains" })[areaID] end,
	SetUserWaypoint = function(point) T.waypoint = point end,
	ClearUserWaypoint = function() T.waypoint = nil end,
	GetUserWaypoint = function() return T.waypoint end,
}
UiMapPoint = { CreateFromCoordinates = function(mapID, x, y)
	return { uiMapID = mapID, position = Vector(x, y) }
end }
C_SuperTrack = { SetSuperTrackedUserWaypoint = noop }
C_VignetteInfo = {
	GetVignettes = function() return {} end,
	GetVignetteInfo = function(id) return T.vignettes and T.vignettes[id] end,
	GetVignettePosition = function() return Vector(0.3, 0.4) end,
}
C_ChatInfo = {
	RegisterAddonMessagePrefix = noop,
	SendAddonMessage = function(prefix, message, channel) T.sent[#T.sent + 1] = { prefix, message, channel } end,
}
C_AddOns = {
	GetAddOnMetadata = function() return "1.1.2" end,
	IsAddOnLoaded = function(name) return T.addons and T.addons[name] or false end,
}
EventRegistry = { RegisterCallback = function(_, _, fn) T.mapSet = fn end }

return T
