-- Slash commands and the addon compartment entry.
local ADDON, ns = ...

local Rares, Respawn, Status = ns.Rares, ns.Respawn, ns.Status

local HELP = {
	"/brs - open the rare journal",
	"/brs list - show or hide the zone list",
	"/brs config - options",
	"/brs test - fire a test alert",
	"/brs find <name> - waypoint to a rare by name",
	"/brs camp - camp bar for the nearest spawn point (again to close)",
	"/brs want <name> - add or remove a rare from the wanted list",
	"/brs sync - ask the guild for its timers now",
	"/brs kills - kill log summary",
	"/brs unhide - bring back every rare you hid",
	"/brs import - re-read rares from QuestieDB",
	"/brs forget - clear learned timers and sightings",
	"/brs stats - what the addon knows",
	"/brs setup - check what still needs setting up",
}

local commands = {}

function commands.config()
	ns.Options.Toggle()
end
commands.options = commands.config

function commands.list()
	ns.Tracker.Toggle()
end

function commands.journal(rest)
	local query = strlower(strtrim(rest or ""))
	if query == "" then
		ns.Journal.Toggle()
	else
		ns.Journal.Toggle(true)
		ns.Journal.SetSearch(query)
	end
end
commands.j = commands.journal
commands.book = commands.journal

function commands.test()
	ns.Alerts.Test()
end

function commands.unhide()
	wipe(ns.db.ignored)
	ns.Fire("RARES_CHANGED")
	ns.Print("All hidden rares are visible again.")
end

function commands.import()
	if not Rares.ImportQuestie(true) then
		ns.Print("QuestieDB is not installed (or an import is already running).")
	end
end

function commands.forget()
	Respawn.Reset()
	ns.Print("Timers and sightings cleared.")
end

function commands.debug()
	ns.db.settings.debug = not ns.db.settings.debug
	ns.Print("Debug " .. (ns.db.settings.debug and "on" or "off"))
end

function commands.stats()
	local learned, samples = 0, 0
	for _ in pairs(ns.db.learned) do
		learned = learned + 1
	end
	for _, rec in pairs(ns.db.timers) do
		samples = samples + #rec.samples
	end
	ns.Print(string.format("%d rares known, %d seen by you, %d respawn samples. Layer: %s",
		Rares.Count(), learned, samples, ns.currentShard or "unknown"))
	if ns.Scan.count then
		ns.Print(string.format("Scan key covers %d of %d nearby rares.", ns.Scan.count, ns.Scan.total or 0))
	end
end

function commands.find(rest)
	local query = strlower(strtrim(rest or ""))
	if query == "" then
		ns.Print("Usage: /brs find <part of a name>")
		return
	end
	local best
	for npcID in pairs(Rares.All()) do
		local name = strlower(Rares.Name(npcID))
		if name == query then
			best = npcID
			break
		elseif not best and strfind(name, query, 1, true) then
			best = npcID
		end
	end
	if best then
		Status.SetWaypoint(best)
	else
		ns.Print("No rare matches \"" .. query .. "\".")
	end
end

local function FindByName(rest)
	local query = strlower(strtrim(rest or ""))
	if query == "" then
		return nil
	end
	local best
	for npcID in pairs(Rares.All()) do
		local name = strlower(Rares.Name(npcID))
		if name == query then
			return npcID
		elseif not best and strfind(name, query, 1, true) then
			best = npcID
		end
	end
	return best
end

function commands.camp()
	ns.Camp.Toggle()
end

function commands.want(rest)
	local npcID = FindByName(rest)
	if not npcID then
		ns.Print("Usage: /brs want <part of a name>")
		return
	end
	local wanted = not ns.Hunt.IsStarred(npcID)
	ns.Hunt.SetWanted(npcID, wanted)
	ns.Print(Rares.Name(npcID) .. (wanted and " is now wanted." or " is no longer wanted."))
end

function commands.sync()
	local sent, why = ns.Share.RequestSync()
	if sent then
		ns.Print("Asked the guild for its timers.")
	elseif why == "receive" then
		ns.Print("Receiving shared data is turned off, so a sync would bring nothing in.")
	else
		ns.Print("You are not in a guild.")
	end
end


function commands.kills()
	local killed, total = ns.Hunt.Progress()
	local count = 0
	for _, kills in pairs(ns.db.kills) do
		count = count + kills.n
	end
	ns.Print(string.format("%d of %d rares killed, %d kills in all.", killed, total, count))
end

function commands.welcome()
	if ns.Welcome.Show(true) == 0 then
		ns.Print("Everything is set up.")
	end
end
commands.setup = commands.welcome

function commands.help()
	for _, line in ipairs(HELP) do
		ns.Print(line)
	end
end

SLASH_BETTERRARESPAWNS1 = "/brs"
SLASH_BETTERRARESPAWNS2 = "/betterrarespawns"
SlashCmdList.BETTERRARESPAWNS = function(message)
	local command, rest = strmatch(strtrim(message or ""), "^(%S*)%s*(.-)$")
	command = strlower(command or "")
	if command == "" then
		ns.Journal.Toggle()
	elseif commands[command] then
		commands[command](rest)
	else
		commands.help()
	end
end

-- Addon compartment (the minimap dropdown), when the client has one.
function BetterRareSpawns_OnCompartmentClick(_, button)
	if button == "RightButton" then
		ns.Options.Toggle()
	elseif IsShiftKeyDown() then
		ns.Tracker.Toggle()
	else
		ns.Journal.Toggle()
	end
end

function BetterRareSpawns_OnCompartmentEnter(_, menuButton)
	GameTooltip:SetOwner(menuButton, "ANCHOR_LEFT")
	GameTooltip:SetText("BetterRareSpawns")
	GameTooltip:AddLine("Click: rare journal", 1, 1, 1)
	GameTooltip:AddLine("Shift-click: zone list", 1, 1, 1)
	GameTooltip:AddLine("Right-click: options", 1, 1, 1)
	GameTooltip:Show()
end

function BetterRareSpawns_OnCompartmentLeave()
	GameTooltip:Hide()
end
