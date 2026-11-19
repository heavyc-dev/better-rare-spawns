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
	local done = false

	local tomtom = _G.TomTom
	if tomtom and tomtom.AddWaypoint then
		done = pcall(tomtom.AddWaypoint, tomtom, mapID, x / 100, y / 100, { title = name, from = "BetterRareSpawns" })
	end

	if not done and C_Map.SetUserWaypoint and UiMapPoint then
		done = pcall(function()
			C_Map.ClearUserWaypoint()
			C_Map.SetUserWaypoint(UiMapPoint.CreateFromCoordinates(mapID, x / 100, y / 100))
			if C_SuperTrack and C_SuperTrack.SetSuperTrackedUserWaypoint then
				C_SuperTrack.SetSuperTrackedUserWaypoint(true)
			end
		end)
	end

	ns.tracked = { id = npcID, map = mapID, x = x, y = y }
	ns.Fire("TRACK_CHANGED")
	ns.Print(string.format("Tracking %s - %s %.1f, %.1f", name, Util.MapName(mapID), x, y))
	return true
end

function Status.ClearWaypoint()
	if ns.tracked then
		ns.tracked = nil
		if C_Map.ClearUserWaypoint then
			pcall(C_Map.ClearUserWaypoint)
		end
		ns.Fire("TRACK_CHANGED")
	end
end

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
