-- Scan key: one bindable key that tries to target every rare that could be
-- near the player. Targeting needs a key press (the game forbids addons from
-- doing it on their own), but it needs no macro slot and no action bar space:
-- the "macro" lives on an invisible secure button.
--
-- The list is rebuilt as the player moves and is ordered so the rares most
-- likely to be up come first when the 255 character limit cuts it short.
local ADDON, ns = ...

local Scan = {}
ns.Scan = Scan

local Util, Rares, Respawn = ns.Util, ns.Rares, ns.Respawn

local MAX_LENGTH = 255
local MOVE_YARDS = 40

local button
local dirty = true
local lastMap, lastX, lastY
local scratchState = {}

BINDING_HEADER_BETTERRARESPAWNS = "BetterRareSpawns"
_G["BINDING_NAME_CLICK BetterRareSpawnsScan:LeftButton"] = "Scan for nearby rares"
BINDING_NAME_BETTERRARESPAWNS_TRACKER = "Show / hide rare list"

local function Settings()
	return ns.db.settings.scan
end

--- Names to try, best candidates first.
function Scan.Candidates()
	local mapID, px, py = Util.PlayerPosition()
	local list = mapID and Rares.OnMap(mapID)
	local found = {}
	if not list then
		return found, mapID, px, py
	end

	local range = Settings().range
	for _, entry in ipairs(list) do
		if not Rares.IsIgnored(entry.id) then
			local points = entry.spawns[mapID]
			local nearest
			if px then
				for i = 1, #points, 2 do
					local distance = Util.Distance(mapID, px, py, mapID, points[i], points[i + 1])
					if distance and (not nearest or distance < nearest) then
						nearest = distance
					end
				end
			end
			-- Without a usable position, every rare of the zone is a candidate.
			if not px or (nearest and nearest <= range) then
				local state = Respawn.GetState(entry.id, nil, scratchState).state
				found[#found + 1] = {
					name = Rares.Name(entry.id),
					distance = nearest or 0,
					-- Known-dead rares go last: they are the least likely hit.
					rank = (state == "dead" or state == "killed") and 2 or 1,
				}
			end
		end
	end

	table.sort(found, function(a, b)
		if a.rank ~= b.rank then
			return a.rank < b.rank
		end
		return a.distance < b.distance
	end)
	return found, mapID, px, py
end

function Scan.BuildMacro()
	local candidates = Scan.Candidates()
	local text, count = "", 0
	for _, candidate in ipairs(candidates) do
		local line = "/targetexact " .. candidate.name
		local joined = text == "" and line or (text .. "\n" .. line)
		if #joined > MAX_LENGTH then
			break
		end
		text = joined
		count = count + 1
	end
	return text, count, #candidates
end

function Scan.Update(force)
	if not button or InCombatLockdown() then
		return
	end
	local mapID, px, py = Util.PlayerPosition()
	if not force and not dirty and mapID == lastMap then
		local moved = px and lastX and Util.Distance(mapID, px, py, mapID, lastX, lastY)
		if not moved or moved < MOVE_YARDS then
			return
		end
	end
	dirty = false
	lastMap, lastX, lastY = mapID, px, py

	local text, count, total = Scan.BuildMacro()
	if not Settings().enabled then
		text, count = "", 0
	end
	if button.text ~= text then
		button.text = text
		button:SetAttribute("macrotext", text)
	end
	Scan.count, Scan.total = count, total
end

ns.Listen("READY", function()
	button = CreateFrame("Button", "BetterRareSpawnsScan", UIParent, "SecureActionButtonTemplate")
	button:RegisterForClicks("AnyUp", "AnyDown")
	button:SetAttribute("type", "macro")
	button:SetAttribute("macrotext", "")

	C_Timer.NewTicker(2, function()
		Scan.Update(false)
	end)
	Scan.Update(true)
end)

local function MarkDirty()
	dirty = true
end
ns.Listen("RARES_CHANGED", MarkDirty)
ns.Listen("SETTINGS_CHANGED", MarkDirty)
ns.Listen("RARE_UPDATED", MarkDirty)
ns.OnEvent("ZONE_CHANGED_NEW_AREA", MarkDirty)
ns.OnEvent("PLAYER_REGEN_ENABLED", MarkDirty)
