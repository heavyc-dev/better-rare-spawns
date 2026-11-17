-- The hunt: what the player has killed, what they are after, and telling
-- them (and, on request, others) when something worth the trip happens.
--
--   * kill log     - kills this account got credit for, with first/last date
--   * wanted list  - starred rares, plus every rare that drops a starred item
--   * window watch - a wanted rare's spawn window opening raises a notice,
--                    wherever the player is
--   * announce     - one click sends a sighting to group / guild / General.
--                    Only ever on a click; nothing is sent to chat on its own.
local ADDON, ns = ...

local Hunt = {}
ns.Hunt = Hunt

local Util, Rares, Respawn, Status = ns.Util, ns.Rares, ns.Respawn, ns.Status

local ANNOUNCE_GAP = 15 -- seconds between two announcements of one rare
local WATCH_INTERVAL = 5

-------------------------------------------------------------------------------
-- Kill log
-------------------------------------------------------------------------------

local credited = {} -- creature GUIDs already counted this session

--- Counts a kill the player got credit for (killing blow in the group, or
-- loot rights). Each creature counts once.
function Hunt.Credit(npcID, guid)
	if not npcID or not Rares.Get(npcID) then
		return false
	end
	if guid then
		if credited[guid] then
			return false
		end
		credited[guid] = true
	end
	local now = GetServerTime()
	local kills = ns.db.kills[npcID]
	if not kills then
		kills = { n = 0, first = now }
		ns.db.kills[npcID] = kills
	end
	kills.n = kills.n + 1
	kills.last = now
	ns.Fire("RARE_KILLED", npcID, kills.n)
	ns.Fire("RARE_UPDATED", npcID)
	return true
end

--- count, firstTime, lastTime
function Hunt.Kills(npcID)
	local kills = ns.db.kills[npcID]
	if kills then
		return kills.n, kills.first, kills.last
	end
	return 0
end

--- killedRares, knownRares
function Hunt.Progress()
	local killed = 0
	for npcID in pairs(ns.db.kills) do
		if Rares.Get(npcID) then
			killed = killed + 1
		end
	end
	return killed, Rares.Count()
end

-------------------------------------------------------------------------------
-- Wanted list
-------------------------------------------------------------------------------

local viaItem -- [npcID] = true for rares that drop a wanted item (cache)

local function ViaItem()
	if viaItem then
		return viaItem
	end
	viaItem = {}
	local items = ns.db.wantedItems
	if next(items) then
		local imported = ns.db.imported and ns.db.imported.drops
		if imported then
			for npcID, list in pairs(imported) do
				for _, itemID in ipairs(list) do
					if items[itemID] then
						viaItem[npcID] = true
						break
					end
				end
			end
		end
		for npcID, loot in pairs(ns.db.loot) do
			for itemID in pairs(loot) do
				if items[itemID] then
					viaItem[npcID] = true
					break
				end
			end
		end
	end
	return viaItem
end

local function WantedChanged()
	viaItem = nil
	ns.Fire("WANTED_CHANGED")
	ns.Fire("RARE_UPDATED")
end

--- True when the rare is starred, or drops a starred item.
function Hunt.IsWanted(npcID)
	return ns.db.wanted[npcID] == true or ViaItem()[npcID] == true
end

function Hunt.IsStarred(npcID)
	return ns.db.wanted[npcID] == true
end

function Hunt.SetWanted(npcID, wanted)
	ns.db.wanted[npcID] = wanted and true or nil
	WantedChanged()
end

function Hunt.IsWantedItem(itemID)
	return ns.db.wantedItems[itemID] == true
end

function Hunt.SetWantedItem(itemID, wanted)
	ns.db.wantedItems[itemID] = wanted and true or nil
	WantedChanged()
end

--- Calls fn(npcID) for every wanted rare that is known and not hidden.
function Hunt.EachWanted(fn)
	for npcID in pairs(ns.db.wanted) do
		if Rares.Get(npcID) and not Rares.IsIgnored(npcID) then
			fn(npcID)
		end
	end
	for npcID in pairs(ViaItem()) do
		if not ns.db.wanted[npcID] and Rares.Get(npcID) and not Rares.IsIgnored(npcID) then
			fn(npcID)
		end
	end
end

ns.Listen("RARES_CHANGED", function()
	viaItem = nil
end)

-------------------------------------------------------------------------------
-- Window watch
-------------------------------------------------------------------------------

local lastState = {}
local extraWatch = {} -- rares watched for another reason (camping)
local scratch = {}

--- Also watch a rare that is not on the wanted list (or stop, with false).
function Hunt.Watch(npcID, on)
	extraWatch[npcID] = on and true or nil
	if not on and not Hunt.IsWanted(npcID) then
		lastState[npcID] = nil
	end
end

local function WindowOpened(npcID)
	local name = Rares.Name(npcID)
	local mapID = Status.BestPoint(npcID)
	local where = mapID and (" (" .. Util.MapName(mapID) .. ")") or ""
	ns.Print("|cffffd24a" .. name .. "|r - spawn window just opened" .. where .. ".")
	if UIErrorsFrame then
		UIErrorsFrame:AddMessage(name .. ": spawn window open", 1, 0.82, 0.29)
	end
	local alerts = ns.db.settings.alerts
	if alerts.sound then
		pcall(PlaySound, (SOUNDKIT and SOUNDKIT.ALARM_CLOCK_WARNING_3) or 12889, "Master")
	end
	if alerts.flash and FlashClientIcon then
		FlashClientIcon()
	end
	ns.Fire("WINDOW_OPENED", npcID)
end

local function Check(npcID)
	local state = Respawn.GetState(npcID, nil, scratch).state
	local previous = lastState[npcID]
	lastState[npcID] = state
	if previous == "dead" and (state == "window" or state == "overdue") then
		WindowOpened(npcID)
	end
end

function Hunt.Tick()
	if not ns.db.settings.alerts.windows then
		return
	end
	Hunt.EachWanted(Check)
	for npcID in pairs(extraWatch) do
		if not Hunt.IsWanted(npcID) then
			Check(npcID)
		end
	end
end

-------------------------------------------------------------------------------
-- Summary (minimap button, broker text)
-------------------------------------------------------------------------------

local NEWSWORTHY = { up = true, overdue = true, window = true, dead = true }

--- Returns upCount, openWindowCount, and fills `list` (when given) with
-- { id, state } for rares that are up or on a timer, most urgent first.
function Hunt.Summary(list)
	local up, open = 0, 0
	if list then
		wipe(list)
	end
	for npcID in pairs(ns.db.timers) do
		if Rares.Get(npcID) and not Rares.IsIgnored(npcID) then
			local state = Respawn.GetState(npcID, nil, scratch).state
			if state == "up" then
				up = up + 1
			elseif state == "window" or state == "overdue" then
				open = open + 1
			end
			if list and NEWSWORTHY[state] then
				list[#list + 1] = { id = npcID, state = state }
			end
		end
	end
	if list then
		table.sort(list, function(a, b)
			local pa, pb = Respawn.PRIORITY[a.state], Respawn.PRIORITY[b.state]
			if pa ~= pb then
				return pa < pb
			end
			return a.id < b.id
		end)
	end
	return up, open
end

-------------------------------------------------------------------------------
-- Announce
-------------------------------------------------------------------------------

local lastAnnounce = {}

--- The plain-text line used for announcements.
function Hunt.AnnounceText(npcID)
	local entry = Rares.Get(npcID)
	local text = "Rare: " .. Rares.Name(npcID)
	local level = Rares.LevelText(npcID)
	if level then
		text = text .. " (" .. level .. (entry and entry.rank == "rareelite" and " elite" or "") .. ")"
	end
	local mapID, x, y = Status.BestPoint(npcID)
	if mapID and x then
		text = text .. string.format(" - %s %.1f, %.1f", Util.MapName(mapID), x, y)
	end
	local status, _, _, _, state = Status.Describe(npcID)
	if state ~= "unknown" then
		text = text .. " - " .. status
	end
	return text
end

local function GeneralChannel()
	if not GetChannelList then
		return nil
	end
	local list = { GetChannelList() }
	local wanted = strlower(_G.GENERAL or "General")
	for i = 1, #list, 3 do
		local id, name = list[i], list[i + 1]
		if type(name) == "string" and strfind(strlower(name), wanted, 1, true) == 1 then
			return id
		end
	end
	return nil
end

--- Sends the rare's line to chat. Must be called from a click.
--   where: nil    -> raid / party when grouped, else guild
--          "general" -> the zone's General channel
-- Returns the channel used, or nil (with a printed reason).
function Hunt.Announce(npcID, where)
	local now = GetTime()
	if lastAnnounce[npcID] and now - lastAnnounce[npcID] < ANNOUNCE_GAP then
		ns.Print("Already announced a moment ago.")
		return nil
	end

	local chatType, target
	if where == "general" then
		target = GeneralChannel()
		if not target then
			ns.Print("You are not in the General channel here.")
			return nil
		end
		chatType = "CHANNEL"
	elseif IsInRaid and IsInRaid() then
		chatType = "RAID"
	elseif IsInGroup and IsInGroup() then
		chatType = "PARTY"
	elseif IsInGuild and IsInGuild() then
		chatType = "GUILD"
	else
		ns.Print("No group or guild to tell. Shift-click announces in General.")
		return nil
	end

	local send = (C_ChatInfo and C_ChatInfo.SendChatMessage) or SendChatMessage
	if not send or not pcall(send, Hunt.AnnounceText(npcID), chatType, nil, target) then
		ns.Print("The message could not be sent.")
		return nil
	end
	lastAnnounce[npcID] = now
	return chatType
end

ns.Listen("READY", function()
	C_Timer.NewTicker(WATCH_INTERVAL, function()
		ns.SafeCall(Hunt.Tick)
	end)
end)
