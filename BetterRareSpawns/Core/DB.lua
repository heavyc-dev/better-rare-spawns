-- Saved variables: defaults, load, migration.
local ADDON, ns = ...

local DB = {}
ns.DB = DB

DB.SCHEMA = 1

local defaults = {
	debug = false,
	detect = {
		nameplate = true,
		mouseover = true,
		target = true,
		vignette = true,
		yell = true,
		learn = true, -- add rares that are not in the shipped data
	},
	alerts = {
		enabled = true,
		sound = true,
		flash = true,
		chat = true,
		duration = 45, -- seconds the alert card stays up
		cooldown = 300, -- seconds before the same rare alerts again
		reports = true, -- alert on sightings reported by other players
		instances = false,
		mark = false, -- put a raid marker on the rare when targeted
		windows = true, -- notice when a wanted rare's spawn window opens
		wanted = true, -- extra sound and screen message for wanted rares
		windows = true, -- notice when a wanted rare's spawn window opens
		wanted = true, -- extra sound and screen message for wanted rares
	},
	map = {
		enabled = true,
		scale = 1.0,
		alpha = 1.0,
		continent = true, -- show active rares on continent maps
		labels = false,
		minLevel = 0,
	},
	minimap = {
		enabled = true,
		scale = 1.0,
		button = true,
		angle = 205, -- degrees around the minimap
	},
	camp = {
		enabled = true, -- show the camp bar when waiting at a spawn point
	},
	share = {
		guild = true,
		group = true,
		receive = true,
		sync = true, -- ask the guild for its timers at login, and answer others
	},
	tracker = {
		shown = false,
		locked = false,
		scale = 1.0,
		activeOnly = false,
	},
	scan = {
		enabled = true,
		range = 150, -- yards around the player covered by the scan key
	},
}
DB.defaults = defaults

local function ApplyDefaults(target, source)
	for key, value in pairs(source) do
		if type(value) == "table" then
			if type(target[key]) ~= "table" then
				target[key] = {}
			end
			ApplyDefaults(target[key], value)
		elseif target[key] == nil then
			target[key] = value
		end
	end
end

function DB.Load()
	local db = _G.BetterRareSpawnsDB
	if type(db) ~= "table" then
		db = {}
		_G.BetterRareSpawnsDB = db
	end

	db.schema = db.schema or DB.SCHEMA
	db.settings = type(db.settings) == "table" and db.settings or {}
	ApplyDefaults(db.settings, defaults)

	db.learned = db.learned or {} -- [npcID] = { name, level, rank, type, spawns = { [mapID] = { x, y, x, y, ... } } }
	db.timers = db.timers or {} -- [npcID] = respawn record, see Respawn.lua
	db.loot = db.loot or {} -- [npcID] = { [itemID] = timesSeen }
	db.ignored = db.ignored or {} -- [npcID] = true
	db.kills = db.kills or {} -- [npcID] = { n, first, last } kills this account got credit for
	db.wanted = db.wanted or {} -- [npcID] = true
	db.wantedItems = db.wantedItems or {} -- [itemID] = true
	db.kills = db.kills or {} -- [npcID] = { n, first, last } kills this account got credit for
	db.wanted = db.wanted or {} -- [npcID] = true
	db.wantedItems = db.wantedItems or {} -- [itemID] = true
	db.names = db.names or {} -- [locale] = { [npcID] = localized name }
	db.windows = db.windows or {} -- saved frame positions

	ns.db = db
	return db
end

--- Restores every setting to its default value (data is kept).
function DB.ResetSettings()
	ns.db.settings = {}
	ApplyDefaults(ns.db.settings, defaults)
	ns.Fire("SETTINGS_CHANGED")
end
