-- Rare registry. Two sources, merged at runtime:
--   * learned  - rares this account has actually seen (always available)
--   * imported - rares read from the QuestieDB addon when it is installed.
--                The data is read at runtime and cached in this account's
--                saved variables; it is never shipped with this addon.
local ADDON, ns = ...

local Rares = {}
ns.Rares = Rares

local MERGE_DISTANCE = 2.5 -- map percent: spawn points closer than this are one point
local MAX_POINTS = 12 -- per rare and map

local entries = {} -- [npcID] = entry
local byMap -- [mapID] = { entry, ... } (built on demand)

-- cmangos creature ranks used by QuestieDB
local RANK_NAMES = { [2] = "rareelite", [4] = "rare" }

-------------------------------------------------------------------------------
-- Entries
-------------------------------------------------------------------------------

local function AddPoint(points, x, y)
	for i = 1, #points, 2 do
		local dx, dy = points[i] - x, points[i + 1] - y
		if dx * dx + dy * dy < MERGE_DISTANCE * MERGE_DISTANCE then
			return false
		end
	end
	if #points >= MAX_POINTS * 2 then
		return false
	end
	points[#points + 1] = math.floor(x * 10 + 0.5) / 10
	points[#points + 1] = math.floor(y * 10 + 0.5) / 10
	return true
end
Rares.AddPoint = AddPoint

local function MergeInto(entry, source, origin)
	entry.name = entry.name or source.name
	entry.level = entry.level or source.level
	entry.rank = entry.rank or source.rank
	entry.type = entry.type or source.type
	entry.minLevel = entry.minLevel or source.minLevel
	entry.health = entry.health or source.health
	entry.sub = entry.sub or source.sub
	entry.friendly = entry.friendly or source.friendly
	entry.dungeon = entry.dungeon or source.dungeon
	entry.quests = entry.quests or source.quests
	entry.family = entry.family or source.family
	entry.skin = entry.skin or source.skin
	entry.dungeon = entry.dungeon or source.dungeon
	entry.quests = entry.quests or source.quests
	entry.family = entry.family or source.family
	entry.skin = entry.skin or source.skin
	entry[origin] = true
	if source.spawns then
		for mapID, points in pairs(source.spawns) do
			local target = entry.spawns[mapID]
			if not target then
				target = {}
				entry.spawns[mapID] = target
			end
			for i = 1, #points, 2 do
				AddPoint(target, points[i], points[i + 1])
			end
		end
	end
end

local function Rebuild()
	wipe(entries)
	byMap = nil
	local db = ns.db

	-- Learned data first: what the player saw wins over imported guesses.
	for _, origin in ipairs({ "learned", "imported" }) do
		local source = origin == "learned" and db.learned or (db.imported and db.imported.rares)
		if source then
			for npcID, data in pairs(source) do
				local entry = entries[npcID]
				if not entry then
					entry = { id = npcID, spawns = {} }
					entries[npcID] = entry
				end
				MergeInto(entry, data, origin)
			end
		end
	end
	ns.Fire("RARES_CHANGED")
end

function Rares.Get(npcID)
	return entries[npcID]
end

function Rares.All()
	return entries
end

function Rares.Count()
	local count = 0
	for _ in pairs(entries) do
		count = count + 1
	end
	return count
end

--- Localized name when the client has shown it to us, else the stored one.
function Rares.Name(npcID)
	local localized = ns.db.names[GetLocale()]
	local name = localized and localized[npcID]
	if name then
		return name
	end
	local entry = entries[npcID]
	return entry and entry.name or ("NPC " .. tostring(npcID))
end

function Rares.IsIgnored(npcID)
	return ns.db.ignored[npcID] == true
end

function Rares.SetIgnored(npcID, ignored)
	ns.db.ignored[npcID] = ignored and true or nil
	ns.Fire("RARES_CHANGED")
end

--- Rares with at least one spawn point on this map.
function Rares.OnMap(mapID)
	if not byMap then
		byMap = {}
		for _, entry in pairs(entries) do
			for spawnMap in pairs(entry.spawns) do
				local list = byMap[spawnMap]
				if not list then
					list = {}
					byMap[spawnMap] = list
				end
				list[#list + 1] = entry
			end
		end
	end
	return byMap[mapID]
end

--- Maps that have rares (for continent overviews).
function Rares.Maps()
	Rares.OnMap(0)
	return byMap
end

--- Nearest known spawn point of a rare on a map: x, y, distanceYards.
function Rares.NearestPoint(npcID, mapID, x, y)
	local entry = entries[npcID]
	local points = entry and entry.spawns[mapID]
	if not points or #points == 0 then
		return nil
	end
	local bestX, bestY, best
	for i = 1, #points, 2 do
		local dx, dy = points[i] - (x or points[i]), points[i + 1] - (y or points[i + 1])
		local d = dx * dx + dy * dy
		if not best or d < best then
			best, bestX, bestY = d, points[i], points[i + 1]
		end
	end
	return bestX, bestY
end

--- "23" or "21-23", or nil when the level is not known.
function Rares.LevelText(npcID)
	local entry = entries[npcID]
	if not entry or not entry.level then
		return nil
	end
	if entry.minLevel and entry.minLevel < entry.level then
		return entry.minLevel .. "-" .. entry.level
	end
	return tostring(entry.level)
end

--- Name of a quest the import met (started by a rare or by a drop), or nil.
function Rares.QuestName(questID)
	local names = ns.db.imported and ns.db.imported.questNames
	return names and names[questID] or nil
end

--- Quest id started by an item, or nil.
function Rares.QuestFromItem(itemID)
	local items = ns.db.imported and ns.db.imported.questItems
	return items and items[itemID] or nil
end

--- Name of a quest the import met (started by a rare or by a drop), or nil.
function Rares.QuestName(questID)
	local names = ns.db.imported and ns.db.imported.questNames
	return names and names[questID] or nil
end

--- Quest id started by an item, or nil.
function Rares.QuestFromItem(itemID)
	local items = ns.db.imported and ns.db.imported.questItems
	return items and items[itemID] or nil
end

--- Items this rare can drop: { { id = itemID, seen = timesLootedOrNil }, ... }.
-- What this account looted comes first, then the imported list.
function Rares.Drops(npcID)
	local list, have = {}, {}
	local own = ns.db.loot[npcID]
	if own then
		for itemID, count in pairs(own) do
			list[#list + 1] = { id = itemID, seen = type(count) == "number" and count or 1 }
			have[itemID] = true
		end
		table.sort(list, function(a, b)
			if a.seen ~= b.seen then
				return a.seen > b.seen
			end
			return a.id < b.id
		end)
	end
	local imported = ns.db.imported and ns.db.imported.drops and ns.db.imported.drops[npcID]
	if imported then
		for _, itemID in ipairs(imported) do
			if not have[itemID] then
				list[#list + 1] = { id = itemID }
			end
		end
	end
	return list
end

-------------------------------------------------------------------------------
-- Learning
-------------------------------------------------------------------------------

--- Remembers a rare seen in the world.
-- info: { name, level, rank ("rare"/"rareelite"), type, map, x, y }
-- Returns true when something new was stored.
function Rares.Learn(npcID, info)
	local db = ns.db
	local changed = false

	if info.name then
		local locale = GetLocale()
		db.names[locale] = db.names[locale] or {}
		db.names[locale][npcID] = info.name
	end

	local data = db.learned[npcID]
	if not data then
		data = { name = info.name, level = info.level, rank = info.rank, type = info.type, spawns = {} }
		db.learned[npcID] = data
		changed = true
	else
		data.level = info.level or data.level
		data.rank = info.rank or data.rank
		data.type = info.type or data.type
	end
	-- Things only the live creature (or its corpse) reveals.
	if info.family and data.family ~= info.family then
		data.family = info.family
		changed = true
	end
	if info.skin and data.skin ~= info.skin then
		data.skin = info.skin
		changed = true
	end
	-- Things only the live creature (or its corpse) reveals.
	if info.family and data.family ~= info.family then
		data.family = info.family
		changed = true
	end
	if info.skin and data.skin ~= info.skin then
		data.skin = info.skin
		changed = true
	end

	if info.map and info.x and info.y then
		-- Only add a point when the merged entry has nothing close to it.
		local entry = entries[npcID]
		local known = entry and entry.spawns[info.map]
		local probe = {}
		if known then
			for i = 1, #known do
				probe[i] = known[i]
			end
		end
		if AddPoint(probe, info.x, info.y) then
			data.spawns[info.map] = data.spawns[info.map] or {}
			if AddPoint(data.spawns[info.map], info.x, info.y) then
				changed = true
			end
		end
	end

	if changed then
		Rebuild()
	end
	return changed
end

-------------------------------------------------------------------------------
-- QuestieDB import (optional, runtime only)
-------------------------------------------------------------------------------

local IMPORT_FORMAT = 3 -- bump to make every account re-read after a change here
local MAX_DROPS = 60 -- per rare
local MAX_DROPPERS = 40 -- an item dropped by more creatures than this is a world drop, not this rare's loot

local function QuestieKey()
	local lib = _G.LibQuestieDB
	local version = C_AddOns and C_AddOns.GetAddOnMetadata and C_AddOns.GetAddOnMetadata("QuestieDB", "Version")
	return IMPORT_FORMAT .. "|" .. tostring(version) .. ":" .. tostring(lib and lib.contractVersion)
end

--- areaId -> uiMapId, from QuestieDB's zone table, with a name match fallback.
local function BuildAreaResolver()
	local table1, table2

	pcall(function()
		local zoneDB = _G.LibQuestieDB.Support.Get("ZoneDB")
		local raw = zoneDB.private.areaIdToUiMapId
		if type(raw) == "string" then
			raw = loadstring(raw)()
		end
		if type(raw) == "table" then
			table1 = raw
		end
		local override = zoneDB.private.areaIdToUiMapIdOverride
		if type(override) == "string" then
			override = loadstring(override)()
		end
		if type(override) == "table" then
			table2 = override
		end
	end)

	local byName
	local function NameLookup(areaID)
		if not byName then
			byName = {}
			pcall(function()
				local zoneType = Enum and Enum.UIMapType and Enum.UIMapType.Zone or 3
				for _, root in ipairs({ 947, 1414, 1415 }) do
					local children = C_Map.GetMapChildrenInfo(root, zoneType, true)
					if children then
						for _, info in ipairs(children) do
							byName[info.name] = byName[info.name] or info.mapID
						end
					end
				end
			end)
		end
		local name = C_Map.GetAreaInfo and C_Map.GetAreaInfo(areaID)
		return name and byName[name]
	end

	local cache = {}
	return function(areaID)
		local mapID = cache[areaID]
		if mapID == nil then
			mapID = (table2 and table2[areaID]) or (table1 and table1[areaID]) or NameLookup(areaID) or false
			-- Continent-level and world maps are useless for pins.
			if mapID then
				local info = C_Map.GetMapInfo(mapID)
				local zoneType = Enum and Enum.UIMapType and Enum.UIMapType.Zone or 3
				if not info or (info.mapType or 0) < zoneType then
					mapID = false
				end
			end
			cache[areaID] = mapID
		end
		return mapID or nil
	end
end

local importing = false

--- Reads every rare from QuestieDB in small batches (it decodes each row on
-- access, so doing 15k of them in one frame would hitch).
function Rares.ImportQuestie(force)
	local npcDB = _G.NpcDB
	if importing or type(npcDB) ~= "table" or type(npcDB.GetAllIds) ~= "function" or type(npcDB.Get) ~= "function" then
		return false
	end

	local key = QuestieKey()
	local db = ns.db
	if not force and db.imported and db.imported.key == key then
		return false
	end

	local ok, ids = pcall(npcDB.GetAllIds)
	if not ok or type(ids) ~= "table" then
		return false
	end

	importing = true
	local resolve = BuildAreaResolver()
	local result = {}
	local index, total, found = 1, #ids, 0
	local BATCH = 300

	local questNames = {} -- [questID] = name, for quests started by a rare or by its drops
	local questItems = {} -- [itemID] = questID the item starts

	local function QuestName(questID)
		if questNames[questID] == nil then
			local questDB = _G.QuestDB
			local name
			if type(questDB) == "table" and type(questDB.Get) == "function" then
				local ok, value = pcall(questDB.Get, questID, "name")
				name = ok and type(value) == "string" and value or nil
			end
			questNames[questID] = name or false
		end
	end

	local function Finish(drops, withDrops)
		importing = false
		db.imported = {
			key = key,
			rares = result,
			count = found,
			drops = drops,
			questNames = questNames,
			questItems = questItems,
		}
		Rebuild()
		if withDrops > 0 then
			ns.Print(string.format("Imported %d rares from QuestieDB (drops known for %d).", found, withDrops))
		else
			ns.Print(string.format("Imported %d rares from QuestieDB.", found))
		end
	end

	-- Second pass: QuestieDB lists droppers per item, so walk the items and
	-- keep the ones dropped by a rare.
	local function ImportDrops()
		local itemDB = _G.ItemDB
		local drops, withDrops = {}, 0
		local okIds, itemIds
		if type(itemDB) == "table" and type(itemDB.GetAllIds) == "function" and type(itemDB.Get) == "function" then
			okIds, itemIds = pcall(itemDB.GetAllIds)
		end
		if not okIds or type(itemIds) ~= "table" then
			return Finish(drops, 0)
		end

		local itemIndex, itemTotal = 1, #itemIds
		local function ItemStep()
			local stop = math.min(itemIndex + BATCH - 1, itemTotal)
			for i = itemIndex, stop do
				local itemID = itemIds[i]
				local ok, droppers = pcall(itemDB.Get, itemID, "npcDrops")
				if ok and type(droppers) == "table" and #droppers <= MAX_DROPPERS then
					for _, npcID in ipairs(droppers) do
						if result[npcID] then
							if questItems[itemID] == nil then
								local okQuest, questID = pcall(itemDB.Get, itemID, "startQuest")
								if okQuest and type(questID) == "number" and questID > 0 then
									questItems[itemID] = questID
									QuestName(questID)
								else
									questItems[itemID] = false
								end
							end
							if questItems[itemID] == nil then
								local okQuest, questID = pcall(itemDB.Get, itemID, "startQuest")
								if okQuest and type(questID) == "number" and questID > 0 then
									questItems[itemID] = questID
									QuestName(questID)
								else
									questItems[itemID] = false
								end
							end
							local list = drops[npcID]
							if not list then
								list = {}
								drops[npcID] = list
								withDrops = withDrops + 1
							end
							if #list < MAX_DROPS then
								list[#list + 1] = itemID
							end
						end
					end
				end
			end
			itemIndex = stop + 1
			if itemIndex <= itemTotal then
				C_Timer.After(0, function() ns.SafeCall(ItemStep) end)
			else
				for itemID, questID in pairs(questItems) do
					if not questID then
						questItems[itemID] = nil
					end
				end
				Finish(drops, withDrops)
			end
		end
		ItemStep()
	end

	local function Step()
		local stop = math.min(index + BATCH - 1, total)
		for i = index, stop do
			local npcID = ids[i]
			local okRank, rank = pcall(npcDB.Get, npcID, "rank")
			local rankName = okRank and RANK_NAMES[rank]
			if rankName then
				local _, name = pcall(npcDB.Get, npcID, "name")
				local _, level = pcall(npcDB.Get, npcID, "maxLevel")
				local _, spawns = pcall(npcDB.Get, npcID, "spawns")
				local _, minLevel = pcall(npcDB.Get, npcID, "minLevel")
				local _, health = pcall(npcDB.Get, npcID, "maxLevelHealth")
				local _, sub = pcall(npcDB.Get, npcID, "subName")
				local _, friendly = pcall(npcDB.Get, npcID, "friendlyToFaction")
				local _, questStarts = pcall(npcDB.Get, npcID, "questStarts")
				local _, questStarts = pcall(npcDB.Get, npcID, "questStarts")
				local data = {
					name = type(name) == "string" and name or nil,
					level = type(level) == "number" and level or nil,
					minLevel = type(minLevel) == "number" and minLevel or nil,
					health = (type(health) == "number" and health > 0) and health or nil,
					sub = (type(sub) == "string" and sub ~= "") and sub or nil,
					friendly = (type(friendly) == "string" and friendly ~= "") and friendly or nil,
					rank = rankName,
					spawns = {},
				}
				if type(questStarts) == "table" and #questStarts > 0 then
					data.quests = {}
					for i = 1, math.min(#questStarts, 4) do
						if type(questStarts[i]) == "number" then
							data.quests[#data.quests + 1] = questStarts[i]
							QuestName(questStarts[i])
						end
					end
				end
				if type(questStarts) == "table" and #questStarts > 0 then
					data.quests = {}
					for i = 1, math.min(#questStarts, 4) do
						if type(questStarts[i]) == "number" then
							data.quests[#data.quests + 1] = questStarts[i]
							QuestName(questStarts[i])
						end
					end
				end
				if type(spawns) == "table" then
					for areaID, points in pairs(spawns) do
						local mapID = resolve(areaID)
						if type(points) == "table" then
							for _, point in ipairs(points) do
								local x, y = point[1], point[2]
								if type(x) == "number" and type(y) == "number" and x > 0 and y > 0 and x <= 100 and y <= 100 then
									if mapID then
										local list = data.spawns[mapID]
										if not list then
											list = {}
											data.spawns[mapID] = list
										end
										AddPoint(list, x, y)
									end
								elseif x == -1 and not data.dungeon then
									-- -1/-1 marks "inside an instance" in the source data.
									data.dungeon = (C_Map.GetAreaInfo and C_Map.GetAreaInfo(areaID)) or "Dungeon"
								end
							end
						end
					end
				end
				if data.name then
					result[npcID] = data
					found = found + 1
				end
			end
		end

		index = stop + 1
		if index <= total then
			C_Timer.After(0, function() ns.SafeCall(Step) end)
		else
			ImportDrops()
		end
	end

	C_Timer.After(0, function() ns.SafeCall(Step) end)
	return true
end

--- Forgets what the player taught the addon about one rare.
function Rares.Forget(npcID)
	if ns.db.learned[npcID] then
		ns.db.learned[npcID] = nil
		Rebuild()
	end
end

--- Drops the imported cache (learned data is kept).
function Rares.ClearImported()
	ns.db.imported = nil
	Rebuild()
end

ns.Listen("READY", function()
	Rebuild()
	-- Give the other addon a moment to finish its own startup.
	C_Timer.After(3, function()
		Rares.ImportQuestie(false)
	end)
end)
