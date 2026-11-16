-- Helpers: GUIDs, time formatting, map positions and distances.
local ADDON, ns = ...

local Util = {}
ns.Util = Util

local Clean = ns.Clean
local floor = math.floor

-------------------------------------------------------------------------------
-- GUIDs
-------------------------------------------------------------------------------

--- Splits a creature GUID.
-- "Creature-0-<server>-<instance>-<zoneUID>-<npcID>-<spawnUID>"
-- Returns npcID, shard, spawnUID, unitType (nil when not a creature GUID).
function Util.ParseGUID(guid)
	guid = Clean(guid)
	if type(guid) ~= "string" then
		return nil
	end
	local unitType, _, serverID, instanceID, zoneUID, npcID, spawnUID = strsplit("-", guid)
	if unitType ~= "Creature" and unitType ~= "Vehicle" then
		return nil
	end
	npcID = tonumber(npcID)
	if not npcID or not serverID or not instanceID or not zoneUID or not spawnUID or spawnUID == "" then
		return nil
	end
	-- Server + instance + zone identify the shard (layer): timers from one
	-- layer say nothing about another.
	return npcID, serverID .. "-" .. instanceID .. "-" .. zoneUID, spawnUID, unitType
end

-------------------------------------------------------------------------------
-- Time
-------------------------------------------------------------------------------

--- "45s", "12m", "1h 05m", "2d 3h"
function Util.Duration(seconds)
	seconds = floor(seconds or 0)
	if seconds < 0 then
		seconds = 0
	end
	if seconds < 60 then
		return seconds .. "s"
	elseif seconds < 3600 then
		return floor(seconds / 60) .. "m"
	elseif seconds < 86400 then
		return string.format("%dh %02dm", floor(seconds / 3600), floor(seconds % 3600 / 60))
	end
	return string.format("%dd %dh", floor(seconds / 86400), floor(seconds % 86400 / 3600))
end

-------------------------------------------------------------------------------
-- Maps
-------------------------------------------------------------------------------

--- Player map and position (x, y in 0-100), or nil inside instances.
function Util.PlayerPosition()
	local mapID = C_Map.GetBestMapForUnit("player")
	if not mapID then
		return nil
	end
	local pos = C_Map.GetPlayerMapPosition(mapID, "player")
	if not pos then
		return mapID
	end
	local x, y = pos:GetXY()
	x, y = Clean(x), Clean(y)
	if not x or not y or (x == 0 and y == 0) then
		return mapID
	end
	return mapID, x * 100, y * 100
end

local mapSizes = {}

--- Width and height of a map in yards, or nil.
function Util.MapSize(mapID)
	local size = mapSizes[mapID]
	if size == nil then
		local width, height = C_Map.GetMapWorldSize(mapID)
		size = (width and height and width > 0 and height > 0) and { width, height } or false
		mapSizes[mapID] = size
	end
	if size then
		return size[1], size[2]
	end
end

--- Offset in yards from A to B on one map: dx (east positive), dy (south positive).
function Util.Offset(mapID, xA, yA, xB, yB)
	local width, height = Util.MapSize(mapID)
	if not width then
		return nil
	end
	return (xB - xA) / 100 * width, (yB - yA) / 100 * height
end

local mapRects = {}

--- Converts a position on a zone map to a parent map (both 0-100), or nil.
function Util.Translate(fromMap, x, y, toMap)
	if fromMap == toMap then
		return x, y
	end
	local key = fromMap * 100000 + toMap
	local rect = mapRects[key]
	if rect == nil then
		local minX, maxX, minY, maxY = C_Map.GetMapRectOnMap(fromMap, toMap)
		rect = (minX and maxX and maxX > minX and maxY > minY) and { minX, maxX, minY, maxY } or false
		mapRects[key] = rect
	end
	if not rect then
		return nil
	end
	return (rect[1] + (rect[2] - rect[1]) * x / 100) * 100, (rect[3] + (rect[4] - rect[3]) * y / 100) * 100
end

--- Distance in yards between two positions on the same map, or nil.
function Util.Distance(mapA, xA, yA, mapB, xB, yB)
	if mapA ~= mapB then
		return nil
	end
	local dx, dy = Util.Offset(mapA, xA, yA, xB, yB)
	if not dx then
		return nil
	end
	return math.sqrt(dx * dx + dy * dy)
end

--- Distance in yards from the player, or nil.
function Util.DistanceFromPlayer(mapID, x, y)
	local playerMap, px, py = Util.PlayerPosition()
	if not px then
		return nil
	end
	return Util.Distance(playerMap, px, py, mapID, x, y)
end

local mapNames = {}

function Util.MapName(mapID)
	local name = mapNames[mapID]
	if name == nil then
		local info = mapID and C_Map.GetMapInfo(mapID)
		name = info and info.name or false
		mapNames[mapID] = name
	end
	return name or ("Map " .. tostring(mapID))
end

--- True when mapID is `ancestor` or lies below it in the map hierarchy.
function Util.IsMapWithin(mapID, ancestor)
	local guard = 0
	while mapID and mapID ~= 0 and guard < 10 do
		if mapID == ancestor then
			return true
		end
		local info = C_Map.GetMapInfo(mapID)
		mapID = info and info.parentMapID
		guard = guard + 1
	end
	return false
end

-------------------------------------------------------------------------------
-- Frames
-------------------------------------------------------------------------------

--- Makes a frame draggable and remembers where the user left it.
function Util.MakeMovable(frame, key, isLocked)
	frame:SetMovable(true)
	frame:SetClampedToScreen(true)
	frame:EnableMouse(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", function(self)
		if not (isLocked and isLocked()) then
			self:StartMoving()
		end
	end)
	frame:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		local point, _, relPoint, x, y = self:GetPoint(1)
		ns.db.windows[key] = { point, relPoint, x, y }
	end)

	local saved = ns.db.windows[key]
	if saved then
		frame:ClearAllPoints()
		frame:SetPoint(saved[1], UIParent, saved[2], saved[3], saved[4])
	end
end

--- A dark rounded panel background that works without any template.
function Util.Skin(frame, alpha)
	local bg = frame:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints()
	bg:SetColorTexture(0.05, 0.06, 0.08, alpha or 0.92)
	frame.bg = bg

	local function Edge(p1, p2, w, h)
		local t = frame:CreateTexture(nil, "BORDER")
		t:SetColorTexture(0, 0, 0, 1)
		t:SetPoint(p1)
		t:SetPoint(p2)
		if w then t:SetWidth(w) end
		if h then t:SetHeight(h) end
		return t
	end
	Edge("TOPLEFT", "TOPRIGHT", nil, 1)
	Edge("BOTTOMLEFT", "BOTTOMRIGHT", nil, 1)
	Edge("TOPLEFT", "BOTTOMLEFT", 1, nil)
	Edge("TOPRIGHT", "BOTTOMRIGHT", 1, nil)
end
