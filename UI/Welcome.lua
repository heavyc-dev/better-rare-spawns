-- Welcome: a few chat lines shortly after login that say what still needs
-- setting up. The greeting comes once per account; a line about a problem
-- (no rare data, scan key unbound) comes back until the problem is gone, but
-- at most once a day.
local ADDON, ns = ...

local Welcome = {}
ns.Welcome = Welcome

local DELAY = 8 -- seconds after login, so the lines are not lost in the login spam
local REMIND_EVERY = 24 * 60 * 60
local FEW_RARES = 25 -- fewer than this means there is no database behind the addon

local function Loaded(name)
	local isLoaded = (C_AddOns and C_AddOns.IsAddOnLoaded) or IsAddOnLoaded
	if not isLoaded then
		return false
	end
	local ok, loaded = pcall(isLoaded, name)
	return ok and loaded and true or false
end

--- What needs the player's attention, as a list of chat lines.
function Welcome.Problems()
	local lines = {}

	if type(_G.NpcDB) ~= "table" and ns.Rares.Count() < FEW_RARES then
		lines[#lines + 1] = "|cffff7f50No rare database found.|r Install the QuestieDB addon to get every rare, its spawn points and its drops. Without it only rares you meet yourself are known."
	end

	local key = GetBindingKey and GetBindingKey("CLICK BetterRareSpawnsScan:LeftButton")
	if not key and ns.db.settings.scan.enabled then
		lines[#lines + 1] = "The |cffffd24ascan key|r is not bound. It targets any rare near you with one press: /brs options, then Bind Scan Key."
	end

	if ns.db.settings.detect.nameplate and GetCVar and GetCVar("nameplateShowEnemies") == "0" then
		ns.nameplateHintGiven = true -- the camp notice need not repeat it
		lines[#lines + 1] = "Enemy nameplates are off, so rares are only noticed on mouseover, target or the scan key. Turn them on (V by default) to notice rares as you walk."
	end

	if Loaded("RareScanner") then
		lines[#lines + 1] = "RareScanner is also running: expect two alerts per rare until one of the two is disabled."
	end
	return lines
end

--- Prints the greeting (first time, or when `force`) and any open problems.
function Welcome.Show(force)
	local db = ns.db
	local now = GetServerTime()
	local first = not db.welcomed
	local problems = Welcome.Problems()

	if first or force then
		db.welcomed = now
		ns.Print("|cffffd24aBetterRareSpawns " .. ns.VERSION .. "|r - /brs opens the rare journal, /brs options the settings. Rares are pinned on the world map and minimap, coloured by their respawn timer.")
	elseif #problems == 0 or (db.reminded and now - db.reminded < REMIND_EVERY) then
		return 0
	end

	if #problems > 0 then
		db.reminded = now
	end
	for _, line in ipairs(problems) do
		ns.Print(line)
	end
	return #problems
end

ns.Listen("READY", function()
	C_Timer.After(DELAY, function()
		ns.SafeCall(Welcome.Show, false)
	end)
end)
