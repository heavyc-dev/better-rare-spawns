-- Shared presentation logic: status text/colors, waypoints, chat links.
-- Every UI surface (map card, tracker, alert, minimap) uses these so a rare
-- reads the same everywhere.
local ADDON, ns = ...

local Status = {}
ns.Status = Status

local Util, Rares, Respawn = ns.Util, ns.Rares, ns.Respawn

Status.COLORS = {
	up = { 0.30, 1.00, 0.40 },
	overdue = { 1.00, 0.60, 0.15 },
	window = { 1.00, 0.85, 0.20 },
	seen = { 0.45, 0.75, 1.00 },
	dead = { 0.60, 0.60, 0.60 },
	killed = { 0.60, 0.60, 0.60 },
	unknown = { 0.80, 0.80, 0.80 },
}

Status.RANK_COLORS = {
	rare = { 0.78, 0.80, 0.85 },
	rareelite = { 1.00, 0.82, 0.30 },
}

local scratch = {}

--- Returns text, r, g, b, state for a rare. `short` gives a compact form
-- for list rows ("Up 2m", "Opens 14m").
function Status.Describe(npcID, short)
	local info = Respawn.GetState(npcID, nil, scratch)
	local state = info.state
	local color = Status.COLORS[state]
	local D = Util.Duration
	local text

	if state == "up" then
		text = short and ("Up " .. D(info.since)) or ("Up now - seen " .. D(info.since) .. " ago")
	elseif state == "seen" then
		text = short and ("Seen " .. D(info.since)) or ("Last seen alive " .. D(info.since) .. " ago")
	elseif state == "window" then
		text = short and ("Window " .. D(info.closesIn)) or ("Spawn window open - closes in ~" .. D(info.closesIn))
	elseif state == "overdue" then
		text = short and ("Overdue " .. D(info.since)) or ("Overdue by " .. D(info.since) .. " - likely up")
	elseif state == "dead" then
		text = short and ("Opens " .. D(info.opensIn)) or ("Dead - window opens in ~" .. D(info.opensIn))
	elseif state == "killed" then
		text = short and ("Dead " .. D(info.since)) or ("Killed " .. D(info.since) .. " ago - respawn not learned yet")
	else
		text = short and "-" or "No sightings yet"
	end

	if info.otherShard and not short then
		text = text .. " (other layer)"
	end
	return text, color[1], color[2], color[3], state, info
end

--- "Respawn 20m - 38m (6 samples)" or nil.
function Status.WindowText(npcID)
	local low, high, count = Respawn.GetWindow(npcID)
	if not low then
		return nil
	end
	local range = low == high and Util.Duration(low) or (Util.Duration(low) .. " - " .. Util.Duration(high))
	if count == 0 then
		return string.format("Respawn %s (from guild)", range)
	end
	return string.format("Respawn %s (%d sample%s)", range, count, count == 1 and "" or "s")
end

--- Where to draw a rare that is up on `mapID`: x, y, or nil when it has no

-- live sighting there. A position reported by someone else is used as it is.
-- The player's own sighting records where the player stood, which would put
-- the pin under their own arrow, so it snaps to the nearest spawn point.
function Status.LivePoint(npcID, mapID)
	local rec = Respawn.GetRecord(npcID)
	local seen = rec and rec.seen
	if not (seen and seen.map == mapID and seen.x) then
		return nil
	end
	if not seen.by then
		local x, y = Rares.NearestPoint(npcID, mapID, seen.x, seen.y)
		if x then
			return x, y
		end
	end
	return seen.x, seen.y
end

function Status.BestPoint(npcID, preferMap)
	local rec = Respawn.GetRecord(npcID)
	local seen = rec and rec.seen
	if seen and seen.map and seen.x and (GetServerTime() - (seen.t or 0)) <= Respawn.UP_TTL then
		return seen.map, seen.x, seen.y
	end

	local entry = Rares.Get(npcID)
	if not entry then
		return nil
	end
	local playerMap, px, py = Util.PlayerPosition()
	local mapID = preferMap
	if not (mapID and entry.spawns[mapID]) then
		mapID = (playerMap and entry.spawns[playerMap]) and playerMap or next(entry.spawns)
	end
	if not mapID then
		return nil
	end
	local x, y = Rares.NearestPoint(npcID, mapID, mapID == playerMap and px or nil, mapID == playerMap and py or nil)
	return mapID, x, y
end

-------------------------------------------------------------------------------
-- Waypoints
-------------------------------------------------------------------------------

-- The waypoint this addon placed, so it can be taken away again without
-- touching one the player set by hand:
--   { tomtom = uid }  or  { map = mapID, x = 0-1, y = 0-1 } for the map pin
local placed

--- True when the built-in map pin is still the one placed here.
local function PinIsOurs(pin)
	if not C_Map.GetUserWaypoint then
		return true -- cannot tell: assume nobody moved it
	end
	local ok, point = pcall(C_Map.GetUserWaypoint)
	if not ok then
		return true
	end
	if type(point) ~= "table" or point.uiMapID ~= pin.map or not point.position then
		return false
	end
	local px, py = point.position:GetXY()
	return math.abs(px - pin.x) < 0.001 and math.abs(py - pin.y) < 0.001
end

local function RemovePlaced()
	local old = placed
	placed = nil
	if not old then
		return
	end
	if old.tomtom then
		local tomtom = _G.TomTom
		if tomtom and tomtom.RemoveWaypoint then
			pcall(tomtom.RemoveWaypoint, tomtom, old.tomtom)
		end
	elseif C_Map.ClearUserWaypoint and PinIsOurs(old) then
		pcall(C_Map.ClearUserWaypoint)
	end
end

--- Points the player at a position. Uses TomTom when installed, else the
-- built-in map pin. Also marks the rare as tracked for the minimap.
function Status.SetWaypoint(npcID, mapID, x, y)
	if not mapID or not x then
		mapID, x, y = Status.BestPoint(npcID)
	end
	if not mapID or not x then
		ns.Print("No known position for " .. Rares.Name(npcID) .. ".")
		return false
	end

	local name = Rares.Name(npcID)

	-- One waypoint at a time: the previous one goes before the new one comes.
	RemovePlaced()

	local tomtom = _G.TomTom
	if tomtom and tomtom.AddWaypoint then
		local ok, uid = pcall(tomtom.AddWaypoint, tomtom, mapID, x / 100, y / 100, { title = name, from = "BetterRareSpawns" })
		if ok and uid then
			placed = { tomtom = uid }
		end
	end

	if not placed and C_Map.SetUserWaypoint and UiMapPoint then
		local ok = pcall(function()
			C_Map.ClearUserWaypoint()
			C_Map.SetUserWaypoint(UiMapPoint.CreateFromCoordinates(mapID, x / 100, y / 100))
			if C_SuperTrack and C_SuperTrack.SetSuperTrackedUserWaypoint then
				C_SuperTrack.SetSuperTrackedUserWaypoint(true)
			end
		end)
		if ok then
			placed = { map = mapID, x = x / 100, y = y / 100 }
		end
	end

	ns.tracked = { id = npcID, map = mapID, x = x, y = y }
	ns.Fire("TRACK_CHANGED")
	ns.Print(string.format("Tracking %s - %s %.1f, %.1f", name, Util.MapName(mapID), x, y))
	return true
end

--- Stops tracking and removes the waypoint placed for it. Returns true when
-- something was being tracked.
function Status.ClearWaypoint()
	if not ns.tracked then
		return false
	end
	ns.tracked = nil
	RemovePlaced()
	ns.Fire("TRACK_CHANGED")
	return true
end

--- A click on something that sets a waypoint: the same thing again stops
-- tracking. `anyPoint` treats every position of the tracked rare as "the
-- same thing" (list rows, whose position follows the player).
function Status.ToggleWaypoint(npcID, mapID, x, y, anyPoint)
	local tracked = ns.tracked
	if tracked and tracked.id == npcID
		and (anyPoint or not mapID or (tracked.map == mapID and tracked.x == x and tracked.y == y)) then
		Status.ClearWaypoint()
		ns.Print("Stopped tracking " .. Rares.Name(npcID) .. ".")
		return false
	end
	return Status.SetWaypoint(npcID, mapID, x, y)
end

-- The tracked rare died on this layer: there is nothing left to walk to.
ns.Listen("RARE_DIED", function(npcID, shard)
	local tracked = ns.tracked
	if not tracked or tracked.id ~= npcID then
		return
	end
	if shard and shard ~= "?" and ns.currentShard and shard ~= ns.currentShard then
		return
	end
	Status.ClearWaypoint()
	ns.Print(Rares.Name(npcID) .. " died - stopped tracking.")
end)

-------------------------------------------------------------------------------
-- Chat
-------------------------------------------------------------------------------

--- Puts "Name - Zone 45.2, 33.1 - status" into the chat box for the player
-- to send wherever they like.
function Status.LinkToChat(npcID, mapID, x, y)
	if not mapID or not x then
		mapID, x, y = Status.BestPoint(npcID)
	end
	local text = Rares.Name(npcID)
	if mapID and x then
		text = string.format("%s - %s %.1f, %.1f", text, Util.MapName(mapID), x, y)
	end
	local status, _, _, _, state = Status.Describe(npcID)
	if state ~= "unknown" then
		text = text .. " - " .. status
	end

	local editBox = ChatEdit_GetActiveWindow and ChatEdit_GetActiveWindow()
	if editBox then
		editBox:Insert(text)
	elseif ChatFrame_OpenChat then
		ChatFrame_OpenChat(text)
	else
		ns.Print(text)
	end
end
