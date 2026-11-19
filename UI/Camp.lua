-- Camp bar: shown while the player waits at a rare's spawn point. One bar
-- that answers "how long until it can spawn", with a sound when the spawn
-- window opens and a reminder of the scan key.
--
-- It appears by itself after standing near a spawn point for a moment, or at
-- once with /brs camp. Closing it dismisses that rare until the player leaves.
local ADDON, ns = ...

local Camp = {}
ns.Camp = Camp

local Util, Rares, Respawn, Status, Style, Hunt = ns.Util, ns.Rares, ns.Respawn, ns.Status, ns.Style, ns.Hunt

local NEAR = 70 -- yards: close enough to count as camping
local FAR = 140 -- yards: far enough to count as having left
local DWELL = 12 -- seconds near a spawn point before the bar offers itself
local LEAVE = 8 -- seconds away before it goes
local MANUAL_RANGE = 400
local NOTICE_RANGE = 120 -- yards: "you are in its spawn area"
local NOTICE_GAP = 600 -- seconds before the same rare is mentioned again
local noticed = {} -- [npcID] = GetTime() of the last notice

local frame
local campID -- rare on the bar
local manual = false
local leaveDistance = FAR -- yards beyond which the player counts as gone
local candidate, candidateSince
local awaySince
local dismissed -- rare the player closed the bar for
local scratch = {}

local function Settings()
	return ns.db.settings.camp
end

--- Distance in yards from the player (on mapID at px, py) to the closest
-- spawn point of `entry`, on any map the player's position can be related
-- to (a cave or town has its own map; its rares are kept on the zone's).
local function EntryDistance(entry, mapID, px, py)
	local best
	for spawnMap, points in pairs(entry.spawns) do
		local qx, qy = px, py
		if spawnMap ~= mapID then
			qx, qy = Util.ToMap(mapID, px, py, spawnMap)
		end
		if qx then
			for i = 1, #points, 2 do
				local distance = Util.Distance(spawnMap, qx, qy, spawnMap, points[i], points[i + 1])
				if distance and (not best or distance < best) then
					best = distance
				end
			end
		end
	end
	return best
end

--- The player's map and the maps above it (zone of a cave, ...).
local function MapsAround(mapID)
	local list = {}
	local guard = 0
	while mapID and mapID ~= 0 and guard < 3 do
		list[#list + 1] = mapID
		local info = C_Map.GetMapInfo(mapID)
		mapID = info and info.parentMapID
		guard = guard + 1
	end
	return list
end

--- Nearest rare with a spawn point within `range` yards: npcID, distance.
-- Wanted rares win over closer ordinary ones.
local function Nearest(range)
	local mapID, px, py = Util.PlayerPosition()
	if not mapID or not px then
		return nil
	end
	local best, bestDistance, bestWanted
	local checked = {}
	for _, listMap in ipairs(MapsAround(mapID)) do
		for _, entry in ipairs(Rares.OnMap(listMap) or {}) do
			if not checked[entry.id] and not Rares.IsIgnored(entry.id) then
				checked[entry.id] = true
				local distance = EntryDistance(entry, mapID, px, py)
				if distance and distance <= range then
					local wanted = Hunt.IsWanted(entry.id)
					if not best or (wanted and not bestWanted) or (wanted == bestWanted and distance < bestDistance) then
						best, bestDistance, bestWanted = entry.id, distance, wanted
					end
				end
			end
		end
	end
	return best, bestDistance
end

--- Yards to the rare's nearest spawn point. Second value: false when the
-- player has no position at all (instances), so "nil" means unknown there,
-- but "too far to relate" anywhere else.
local function DistanceTo(npcID)
	local mapID, px, py = Util.PlayerPosition()
	local entry = Rares.Get(npcID)
	if not entry or not mapID or not px then
		return nil, false
	end
	return EntryDistance(entry, mapID, px, py), true
end

-------------------------------------------------------------------------------
-- Bar
-------------------------------------------------------------------------------

local function Create()
	frame = Style.Frame("Frame", "BetterRareSpawnsCamp", UIParent)
	frame:SetSize(250, 62)
	frame:SetPoint("TOP", UIParent, "TOP", 0, -230)
	frame:SetFrameStrata("MEDIUM")
	frame:Hide() -- new frames start shown
	Style.Tooltip(frame, 0.9)
	Util.MakeMovable(frame, "camp")

	frame.name = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	frame.name:SetPoint("TOPLEFT", 10, -9)
	frame.name:SetPoint("RIGHT", -26, 0)
	frame.name:SetJustifyH("LEFT")
	frame.name:SetWordWrap(false)

	local close = Style.Close(frame, function()
		Camp.Stop(true)
	end, 24)
	close:SetPoint("TOPRIGHT", 0, 0)

	local back = frame:CreateTexture(nil, "BACKGROUND")
	back:SetColorTexture(0, 0, 0, 0.6)
	back:SetPoint("TOPLEFT", 10, -26)
	back:SetPoint("RIGHT", -10, 0)
	back:SetHeight(14)

	frame.bar = CreateFrame("StatusBar", nil, frame)
	frame.bar:SetAllPoints(back)
	frame.bar:SetStatusBarTexture(Style.TEX.statusBar)
	frame.bar:SetMinMaxValues(0, 1)

	frame.text = frame.bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	frame.text:SetPoint("CENTER")

	frame.hint = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	frame.hint:SetPoint("BOTTOMLEFT", 10, 8)
	frame.hint:SetPoint("RIGHT", -10, 0)
	frame.hint:SetJustifyH("LEFT")
	frame.hint:SetWordWrap(false)
end

local function Render()
	if not frame or not campID then
		return
	end
	local info = Respawn.GetState(campID, nil, scratch)
	local state = info.state
	local color = Status.COLORS[state]
	local D = Util.Duration
	local value, text

	if state == "up" then
		value, text = 1, "Up now!"
	elseif state == "overdue" then
		value, text = 1, "Overdue " .. D(info.since) .. " - any moment"
	elseif state == "window" then
		value, text = info.progress or 0, "Window open - closes in ~" .. D(info.closesIn)
	elseif state == "dead" then
		local total = (info.since or 0) + (info.opensIn or 0)
		value = total > 0 and (info.since or 0) / total or 0
		text = "Window opens in ~" .. D(info.opensIn)
	elseif state == "killed" then
		value, text = 0, "Died " .. D(info.since) .. " ago - respawn not learned yet"
	elseif state == "seen" then
		value, text = 0, "Last seen " .. D(info.since) .. " ago"
	else
		value, text = 0, "No timer yet - it starts with the first kill"
	end

	frame.name:SetText(Rares.Name(campID))
	frame.bar:SetValue(math.max(0, math.min(1, value)))
	frame.bar:SetStatusBarColor(color[1], color[2], color[3])
	frame.text:SetText(text)

	local key = GetBindingKey and GetBindingKey("CLICK BetterRareSpawnsScan:LeftButton")
	if key then
		frame.hint:SetText("Scan key: " .. key)
	else
		frame.hint:SetText("Bind the scan key under Key Bindings > AddOns")
	end
end

-------------------------------------------------------------------------------
-- Starting and stopping
-------------------------------------------------------------------------------

--- Puts a rare on the bar. `byHand` keeps it up until the player walks away
-- or closes it.
function Camp.Start(npcID, byHand)
	if not npcID or not Rares.Get(npcID) then
		return false
	end
	if not frame then
		Create()
	end
	if campID and campID ~= npcID then
		Hunt.Watch(campID, false)
	end
	campID, manual, awaySince = npcID, byHand and true or false, nil
	dismissed = nil
	-- Started by hand from further out: leaving means walking further away
	-- than that, not just being beyond the automatic range.
	leaveDistance = FAR
	if byHand then
		local distance = DistanceTo(npcID)
		if distance then
			leaveDistance = math.max(FAR, distance + 60)
		end
	end
	Hunt.Watch(npcID, true) -- sound when its window opens
	Render()
	frame:Show()
	return true
end

--- Takes the bar down. `byPlayer`: do not offer this rare again until they leave.
function Camp.Stop(byPlayer)
	if campID then
		Hunt.Watch(campID, false)
		if byPlayer then
			dismissed = campID
		end
	end
	campID, manual, candidate, awaySince = nil, false, nil, nil
	if frame then
		frame:Hide()
	end
end

function Camp.Current()
	return campID
end

--- /brs camp: camp the nearest rare, or stop.
function Camp.Toggle()
	if campID then
		Camp.Stop(true)
		ns.Print("Camp bar closed.")
		return
	end
	local npcID = Nearest(MANUAL_RANGE)
	if npcID then
		Camp.Start(npcID, true)
		ns.Print("Camping " .. Rares.Name(npcID) .. ".")
	else
		ns.Print("No known spawn point within " .. MANUAL_RANGE .. " yards.")
	end
end

--- Says once, on screen and in chat, that the player has walked into a rare's
-- spawn area and what its timer says. Without this, arriving at a spawn point
-- whose rare is not up (or not yet noticed) shows nothing at all.
local function Notice(now)
	local alerts = ns.db.settings.alerts
	if not alerts.enabled or not alerts.nearby then
		return
	end
	local npcID = Nearest(NOTICE_RANGE)
	if not npcID or (noticed[npcID] and now - noticed[npcID] < NOTICE_GAP) then
		return
	end
	noticed[npcID] = now

	local name = Rares.Name(npcID)
	local status = Status.Describe(npcID)
	if UIErrorsFrame then
		UIErrorsFrame:AddMessage(name .. " spawns near here", 1, 0.82, 0.29)
	end
	if alerts.chat then
		ns.Print("|cffffd24a" .. name .. "|r spawns near here - " .. status .. ".")
	end

	-- Walking past a rare only notices it through its nameplate.
	if not ns.nameplateHintGiven and ns.db.settings.detect.nameplate and GetCVar and GetCVar("nameplateShowEnemies") == "0" then
		ns.nameplateHintGiven = true
		ns.Print("Enemy nameplates are off, so a rare is only noticed when you mouse over it, target it or press the scan key. Turn on enemy nameplates (V by default) to have it noticed as you walk up.")
	end
end

--- Once a second: offer, keep or drop the bar depending on where the player is.
function Camp.Tick()
	local now = GetTime()
	Notice(now)

	if campID then
		local distance, located = DistanceTo(campID)
		if located and (not distance or distance > leaveDistance) then
			awaySince = awaySince or now
			if now - awaySince >= LEAVE then
				Camp.Stop(false)
				return
			end
		else
			awaySince = nil
		end
		Render()
		return
	end

	if not Settings().enabled then
		return
	end
	local nearest = Nearest(NEAR)
	if dismissed then
		-- Walking away resets a dismissal.
		local distance, located = DistanceTo(dismissed)
		if located and (not distance or distance > FAR) then

			dismissed = nil
		end
	end
	if not nearest or nearest == dismissed then
		candidate = nil
		return
	end
	if candidate ~= nearest then
		candidate, candidateSince = nearest, now
	elseif now - candidateSince >= DWELL then
		Camp.Start(nearest, false)
	end
end

ns.Listen("READY", function()
	C_Timer.NewTicker(1, function()
		ns.SafeCall(Camp.Tick)
	end)
end)

ns.Listen("RARE_UPDATED", function(npcID)
	if campID and (npcID == nil or npcID == campID) then
		Render()
	end
end)

ns.Listen("SETTINGS_CHANGED", function()
	if campID and not manual and not Settings().enabled then
		Camp.Stop(false)
	end
end)
