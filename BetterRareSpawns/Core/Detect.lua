-- Detection: turns game events into RARE_SEEN / RARE_DIED messages.
-- A unit counts as a rare when the registry knows it, or when the client
-- classifies it as rare / rare elite (which is how unknown rares get learned).
local ADDON, ns = ...

local Detect = {}
ns.Detect = Detect

local Clean, Util, Rares, Respawn, Hunt = ns.Clean, ns.Util, ns.Rares, ns.Respawn, ns.Hunt

local RARE_CLASS = { rare = "rare", rareelite = "rareelite" }

local function Setting(key)
	return ns.db.settings.detect[key]
end

-------------------------------------------------------------------------------
-- Units (nameplate, mouseover, target, soft target)
-------------------------------------------------------------------------------

-- Creature GUIDs of rares seen this session: a GUID that is not in here is a
-- fresh spawn (or the first look at an old one).
local seenGUIDs = {}

function Detect.IsNewGUID(guid)
	if not guid or seenGUIDs[guid] then
		return false
	end
	seenGUIDs[guid] = true
	return true
end

local function BreakWatch()
	Respawn.BreakWatch()
end
ns.OnEvent("ZONE_CHANGED_NEW_AREA", BreakWatch)
ns.OnEvent("SHARD_TRANSFER", BreakWatch)
ns.OnEvent("PLAYER_ENTERING_WORLD", BreakWatch)

local SKIN_LINES -- [tooltip text] = kind, built on first use

--- What the corpse under the cursor can be harvested for, read from the
-- tooltip the game already built ("Skinnable", "Requires Mining", ...).
local function CorpseHarvest(unit)
	if not (C_TooltipInfo and C_TooltipInfo.GetUnit) then
		return nil
	end
	if not SKIN_LINES then
		SKIN_LINES = {}
		for global, kind in pairs({
			UNIT_SKINNABLE_LEATHER = "Skinning",
			UNIT_SKINNABLE_HERB = "Herbalism",
			UNIT_SKINNABLE_ROCK = "Mining",
			UNIT_SKINNABLE_BOLTS = "Engineering",
		}) do
			if type(_G[global]) == "string" then
				SKIN_LINES[_G[global]] = kind
			end
		end
	end
	local ok, data = pcall(C_TooltipInfo.GetUnit, unit)
	if not ok or type(data) ~= "table" or type(data.lines) ~= "table" then
		return nil
	end
	for _, line in ipairs(data.lines) do
		local text = Clean(line.leftText)
		if type(text) == "string" and SKIN_LINES[text] then
			return SKIN_LINES[text]
		end
	end
	return nil
end

--- Inspects a unit token. Returns the npcID when it was handled as a rare.
function Detect.Unit(unit, source)
	local guid = Clean(UnitGUID(unit))
	if not guid then
		return nil
	end
	local npcID, shard, spawnUID = Util.ParseGUID(guid)
	if not npcID then
		return nil
	end

	-- Any creature tells us which shard (layer) the player is on.
	if ns.currentShard ~= shard then
		ns.currentShard = shard
		ns.Fire("SHARD_CHANGED", shard)
	end

	local known = Rares.Get(npcID)
	local class = RARE_CLASS[Clean(UnitClassification(unit)) or ""]
	if not known and not (class and Setting("learn")) then
		return nil
	end
	if Rares.IsIgnored(npcID) then
		return nil
	end
	-- Tamed or charmed creatures keep their npc id but are not spawns.
	if Clean(UnitPlayerControlled(unit)) then
		return nil
	end

	local dead = UnitIsDead(unit)
	if issecretvalue and issecretvalue(dead) then
		return nil
	end

	local now = GetServerTime()
	if dead then
		-- A corpse: it died at some point before now.
		if Respawn.RecordDeath(npcID, shard, now, true) then
			ns.Fire("RARE_DIED", npcID, shard, now, true)
		end
		if known then
			local harvest = CorpseHarvest(unit)
			if harvest then
				Rares.Learn(npcID, { skin = harvest })
			end
		end
		return npcID
	end

	local name = Clean(UnitName(unit))
	if name == UNKNOWNOBJECT then
		name = nil
	end
	local level = Clean(UnitLevel(unit))
	if level and level <= 0 then
		level = nil
	end
	local mapID, x, y = Util.PlayerPosition()

	Rares.Learn(npcID, {
		name = name,
		level = level,
		rank = class,
		type = Clean(UnitCreatureType(unit)),
		family = UnitCreatureFamily and Clean(UnitCreatureFamily(unit)) or nil,
		map = mapID,
		x = x,
		y = y,
	})

	local newSpawn = Detect.IsNewGUID(guid)
	Respawn.RecordSeen(npcID, {
		shard = shard,
		newSpawn = newSpawn,
		map = mapID,
		x = x,
		y = y,
		src = source,
		t = now,
	})

	ns.Fire("RARE_SEEN", npcID, {
		guid = guid,
		unit = unit,
		src = source,
		shard = shard,
		newSpawn = newSpawn,
		map = mapID,
		x = x,
		y = y,
		name = name or Rares.Name(npcID),
		t = now,
	})
	return npcID
end

ns.OnEvent("NAME_PLATE_UNIT_ADDED", function(unit)
	if Setting("nameplate") and unit then
		Detect.Unit(unit, "nameplate")
	end
end)

ns.OnEvent("UPDATE_MOUSEOVER_UNIT", function()
	if Setting("mouseover") then
		Detect.Unit("mouseover", "mouseover")
	end
end)

ns.OnEvent("PLAYER_TARGET_CHANGED", function()
	if Setting("target") then
		Detect.Unit("target", "target")
	end
end)

-- Soft targeting is only read, never configured: the player's CVars are theirs.
ns.OnEvent("PLAYER_SOFT_ENEMY_CHANGED", function()
	if Setting("target") then
		Detect.Unit("softenemy", "target")
	end
end)

-------------------------------------------------------------------------------
-- Sightings without a unit token (vignettes, yells)
-------------------------------------------------------------------------------

local function SeenWithoutUnit(npcID, guid, source, mapID, x, y, name)
	local entry = Rares.Get(npcID)
	if not entry or Rares.IsIgnored(npcID) then
		return
	end

	local playerMap, px, py = Util.PlayerPosition()
	mapID = mapID or playerMap
	if mapID and not x then
		-- Best guess: the known spawn point closest to the player.
		x, y = Rares.NearestPoint(npcID, mapID, px, py)
	end

	local now = GetServerTime()
	local shard
	if guid then
		local _, guidShard = Util.ParseGUID(guid)
		shard = guidShard
	end
	shard = shard or ns.currentShard
	local newSpawn = Detect.IsNewGUID(guid)

	Respawn.RecordSeen(npcID, { shard = shard, newSpawn = newSpawn, map = mapID, x = x, y = y, src = source, t = now })
	ns.Fire("RARE_SEEN", npcID, {
		guid = guid,
		src = source,
		shard = shard,
		newSpawn = newSpawn,
		map = mapID,
		x = x,
		y = y,
		name = name or Rares.Name(npcID),
		t = now,
	})
end

local function CheckVignette(vignetteGUID)
	if not Setting("vignette") or not vignetteGUID then
		return
	end
	local info = C_VignetteInfo.GetVignetteInfo(vignetteGUID)
	if not info or info.isDead then
		return
	end
	local npcID = Util.ParseGUID(info.objectGUID)
	if not npcID then
		return
	end

	if not Rares.Get(npcID) then
		-- Unknown creature with a "kill" vignette: learn it as a rare.
		local atlas = Clean(info.atlasName)
		if not Setting("learn") or type(atlas) ~= "string" or not strfind(atlas, "VignetteKill", 1, true) then
			return
		end
		Rares.Learn(npcID, { name = Clean(info.name), rank = "rare" })
	end

	local mapID = C_Map.GetBestMapForUnit("player")
	local x, y
	if mapID then
		local pos = C_VignetteInfo.GetVignettePosition(vignetteGUID, mapID)
		if pos then
			x, y = pos:GetXY()
			x, y = Clean(x), Clean(y)
			if x and y then
				x, y = x * 100, y * 100
				Rares.Learn(npcID, { map = mapID, x = x, y = y })
			else
				x, y = nil, nil
			end
		end
	end
	SeenWithoutUnit(npcID, Clean(info.objectGUID), "vignette", mapID, x, y, Clean(info.name))
end

if C_VignetteInfo then
	ns.OnEvent("VIGNETTE_MINIMAP_UPDATED", function(vignetteGUID, onMinimap)
		if onMinimap ~= false then
			CheckVignette(vignetteGUID)
		end
	end)

	local lastSweep = 0
	ns.OnEvent("VIGNETTES_UPDATED", function()
		local now = GetTime()
		if now - lastSweep < 5 then
			return
		end
		lastSweep = now
		local list = C_VignetteInfo.GetVignettes()
		if list then
			for _, vignetteGUID in ipairs(list) do
				CheckVignette(vignetteGUID)
			end
		end
	end)
end

local function OnMonsterChat(message, name, ...)
	if not Setting("yell") then
		return
	end
	local guid = Clean((select(10, ...)))
	local npcID = Util.ParseGUID(guid)
	if npcID and Rares.Get(npcID) then
		SeenWithoutUnit(npcID, guid, "yell", nil, nil, nil, Clean(name))
		return
	end

	-- No usable GUID: match the speaker's name against rares of this zone.
	name = Clean(name)
	local mapID = C_Map.GetBestMapForUnit("player")
	local list = name and mapID and Rares.OnMap(mapID)
	if list then
		for _, entry in ipairs(list) do
			if Rares.Name(entry.id) == name then
				SeenWithoutUnit(entry.id, nil, "yell", mapID, nil, nil, name)
				return
			end
		end
	end
end

ns.OnEvent("CHAT_MSG_MONSTER_YELL", OnMonsterChat)
ns.OnEvent("CHAT_MSG_MONSTER_EMOTE", OnMonsterChat)

-------------------------------------------------------------------------------
-- Deaths
-------------------------------------------------------------------------------

local function OnDeath(guid)
	local npcID, shard = Util.ParseGUID(guid)
	if not npcID or not Rares.Get(npcID) then
		return
	end
	local now = GetServerTime()
	if Respawn.RecordDeath(npcID, shard, now, false) then
		ns.Fire("RARE_DIED", npcID, shard, now, false)
	end
end

local hasUnitDied = ns.OnEvent("UNIT_DIED", function(guid)
	OnDeath(guid)
end)

-- A kill by the player or their group: that one counts for the kill log.
ns.OnEvent("PARTY_KILL", function(_, targetGUID)
	targetGUID = Clean(targetGUID)
	OnDeath(targetGUID)
	Hunt.Credit((Util.ParseGUID(targetGUID)), targetGUID)
end)

-- Older clients report deaths only through the combat log.
if not hasUnitDied and CombatLogGetCurrentEventInfo then
	ns.OnEvent("COMBAT_LOG_EVENT_UNFILTERED", function()
		local _, subEvent, _, _, _, _, _, destGUID = CombatLogGetCurrentEventInfo()
		if subEvent == "UNIT_DIED" or subEvent == "PARTY_KILL" then
			OnDeath(destGUID)
		end
		if subEvent == "PARTY_KILL" then
			Hunt.Credit((Util.ParseGUID(destGUID)), destGUID)
		end
	end)
end

-------------------------------------------------------------------------------
-- Loot: remember what each rare has dropped for this account
-------------------------------------------------------------------------------

local lootedCorpses = {}

ns.OnEvent("LOOT_OPENED", function()
	local count = GetNumLootItems and GetNumLootItems() or 0
	for slot = 1, count do
		local guid = GetLootSourceInfo and Clean((GetLootSourceInfo(slot)))
		local npcID, shard = Util.ParseGUID(guid)
		if npcID and Rares.Get(npcID) then
			if Respawn.RecordDeath(npcID, shard, GetServerTime(), true) then
				ns.Fire("RARE_DIED", npcID, shard, GetServerTime(), true)
			end
			Hunt.Credit(npcID, guid) -- loot rights are kill credit

			local key = guid .. ":" .. slot
			local link = GetLootSlotLink(slot)
			local itemID = type(link) == "string" and tonumber(strmatch(link, "item:(%d+)"))
			local _, _, _, _, quality = GetLootSlotInfo(slot)
			quality = Clean(quality)
			if itemID and not lootedCorpses[key] and quality and quality >= 2 then
				lootedCorpses[key] = true
				local loot = ns.db.loot[npcID]
				if not loot then
					loot = {}
					ns.db.loot[npcID] = loot
				end
				loot[itemID] = (loot[itemID] or 0) + 1
			end
		end
	end
end)
