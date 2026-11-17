-- Behaviour checks, run by tests/run.py after the addon is loaded.
-- Globals provided by the runner: T (stub controls), ns (addon namespace).

local passed, failed = 0, 0
local function check(label, condition, detail)
	if condition then
		passed = passed + 1
	else
		failed = failed + 1
		print("FAIL  " .. label .. (detail and ("  -> " .. tostring(detail)) or ""))
	end
end
local function section(name)
	print("-- " .. name)
end

local function Guid(npcID, spawn, zone)
	return string.format("Creature-0-4444-0-%s-%d-%s", zone or "77", npcID, spawn or "00001A2B3C")
end

-------------------------------------------------------------------------------
section("startup")
-- One event this client does not know: registering it must not break loading.
T.Fire("ADDON_LOADED", "BetterRareSpawns")
T.Fire("PLAYER_LOGIN")
check("saved variables created", type(BetterRareSpawnsDB) == "table" and ns.db == BetterRareSpawnsDB)
check("defaults applied", ns.db.settings.alerts.cooldown == 300)
check("slash command registered", type(SlashCmdList.BETTERRARESPAWNS) == "function")

-------------------------------------------------------------------------------
section("QuestieDB import")
local questie = {
	[100] = { name = "Old Rare", minLevel = 11, maxLevel = 12, maxLevelHealth = 420, subName = "The Ancient", rank = 4, spawns = { [12] = { { 40, 40 }, { 40.5, 40.2 }, { 70, 20 } } } },
	[101] = { name = "Elite Rare", maxLevel = 25, rank = 2, questStarts = { 501 }, spawns = { [44] = { { 30, 30 } }, [999] = { { 1, 1 } } } },
	[102] = { name = "Plain Wolf", maxLevel = 5, spawns = { [12] = { { 10, 10 } } } },
	[103] = { name = "Dungeon Rare", maxLevel = 20, rank = 4, spawns = { [12] = { { -1, -1 } } } },
}
NpcDB = {
	GetAllIds = function() return { 100, 101, 102, 103 } end,
	Get = function(id, key) return questie[id] and questie[id][key] end,
}
LibQuestieDB = { contractVersion = 4, Support = { Get = function()
	return { private = { areaIdToUiMapId = "return { [12] = 1429, [44] = 1433 }" } }
end } }
local questieItems = {
	[9001] = { npcDrops = { 100 } },
	[9002] = { npcDrops = { 100, 101, 102 }, startQuest = 502 },
	[9003] = { npcDrops = { 102 } }, -- only a normal mob drops it
	[9004] = {}, -- no droppers
}
ItemDB = {
	GetAllIds = function() return { 9001, 9002, 9003, 9004 } end,
	Get = function(id, key) return questieItems[id] and questieItems[id][key] end,
}
QuestDB = { Get = function(id, key)
	return key == "name" and ({ [501] = "The Elite Menace", [502] = "A Worn Pelt" })[id] or nil
end }
T.items[9001] = { "Ancient Fang", 3 }
T.items[9002] = { "Worn Pelt", 1 }
T.Advance(5)
check("rares imported, normal mobs skipped", ns.Rares.Count() == 3, ns.Rares.Count())
local old = ns.Rares.Get(100)
check("area id mapped to ui map", old and old.spawns[1429] ~= nil)
check("close spawn points merged", old and #old.spawns[1429] == 4, old and #old.spawns[1429])
check("rank translated", ns.Rares.Get(101).rank == "rareelite")
check("unmappable area dropped", ns.Rares.Get(101).spawns[999] == nil)
check("instance marker coords dropped", next(ns.Rares.Get(103).spawns) == nil or #ns.Rares.Get(103).spawns[1429] == 0)
check("extra creature details imported", old.minLevel == 11 and old.health == 420 and old.sub == "The Ancient")
check("level shown as a range", ns.Rares.LevelText(100) == "11-12" and ns.Rares.LevelText(101) == "25")
local drops = ns.Rares.Drops(100)
check("drops imported per rare", #drops == 2 and drops[1].id == 9001 and drops[2].id == 9002, #drops)
check("drops of normal mobs ignored", #ns.Rares.Drops(102) == 0 and ns.db.imported.drops[102] == nil)
check("dungeon rare flagged with its instance", ns.Rares.Get(103).dungeon == "Elwynn Forest", ns.Rares.Get(103).dungeon)
check("quests started by a rare imported", ns.Rares.Get(101).quests and ns.Rares.Get(101).quests[1] == 501
	and ns.Rares.QuestName(501) == "The Elite Menace")
check("quest-starting drops imported", ns.Rares.QuestFromItem(9002) == 502 and ns.Rares.QuestName(502) == "A Worn Pelt"
	and ns.Rares.QuestFromItem(9001) == nil)
local key = ns.db.imported.key
check("second import is skipped while the cache is current", ns.Rares.ImportQuestie(false) == false and ns.db.imported.key == key)

-------------------------------------------------------------------------------
section("detection and learning")
local seen = {}
ns.Listen("RARE_SEEN", function(npcID, info) seen[#seen + 1] = { id = npcID, info = info } end)

T.units.nameplate1 = { guid = Guid(555, "AAAAAAAAA1"), name = "Brand New Rare", level = 14, class = "rare", type = "Beast" }
T.player.x, T.player.y = 0.25, 0.75
T.Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
check("unknown rare learned from classification", ns.Rares.Get(555) ~= nil)
check("learned at player position", ns.Rares.Get(555) and ns.Rares.Get(555).spawns[1429][1] == 25)
check("sighting announced", #seen == 1 and seen[1].id == 555 and seen[1].info.newSpawn == true)
check("shard tracked", ns.currentShard == "4444-0-77")
check("alert sound played", T.sound == 8959)
check("alert card targets by exact name",
	BetterRareSpawnsAlert and BetterRareSpawnsAlert:GetAttribute("macrotext") == "/cleartarget\n/targetexact Brand New Rare")
check("alert card visible", BetterRareSpawnsAlert:IsShown())
check("sighting shared with guild", #T.sent == 0) -- queued, not sent yet
T.Advance(3)
check("sighting sent after the send delay", #T.sent == 1 and T.sent[1][3] == "GUILD" and T.sent[1][2]:find("^S:555:1429:250:750:"), T.sent[1] and T.sent[1][2])

T.units.nameplate2 = { guid = Guid(9001), name = "Boring Boar", level = 5, class = "normal" }
T.Fire("NAME_PLATE_UNIT_ADDED", "nameplate2")
check("normal creatures ignored", ns.Rares.Get(9001) == nil and #seen == 1)

T.Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
check("repeat sighting does not re-alert", #seen == 2 and seen[2].info.newSpawn == false)

T.units.mouseover = { secret = true }
T.Fire("UPDATE_MOUSEOVER_UNIT")
check("secret values are ignored without errors", #T.errors == 0, T.errors[1])
T.units.mouseover = nil

-------------------------------------------------------------------------------
section("respawn learning")
local R = ns.Respawn
check("state up after sighting", R.GetState(555).state == "up")

T.Fire("UNIT_DIED", Guid(555, "AAAAAAAAA1"))
check("death recorded", R.GetState(555).state == "killed", R.GetState(555).state)
check("alert dismissed on death", not BetterRareSpawnsAlert:IsShown())
T.Fire("PARTY_KILL", "Player-1", Guid(555, "AAAAAAAAA1"))
check("duplicate death not double counted", R.GetRecord(555).kills == 1)

T.Advance(1200)
T.units.nameplate1.guid = Guid(555, "BBBBBBBBB2")
T.Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
local low, high, count = R.GetWindow(555)
check("respawn sample learned from death -> new spawn", count == 1 and low and low <= 1200 and high >= 1200, tostring(low) .. "-" .. tostring(high))
check("up again", R.GetState(555).state == "up")

T.Fire("UNIT_DIED", Guid(555, "BBBBBBBBB2"))
T.Advance(600)
local state = R.GetState(555)
check("dead with countdown before the window", state.state == "dead" and state.opensIn and state.opensIn > 0, state.state)
T.Advance(600)
check("window open around the learned time", R.GetState(555).state == "window", R.GetState(555).state)
T.Advance(3000)
check("overdue past the window", R.GetState(555).state == "overdue", R.GetState(555).state)

-- A zone change in between must not produce a sample.
T.Fire("ZONE_CHANGED_NEW_AREA")
T.units.nameplate1.guid = Guid(555, "CCCCCCCCC3")
T.Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
check("no sample when the player left the zone", select(3, R.GetWindow(555)) == 1)

check("corpse counts as a death", (function()
	T.units.mouseover = { guid = Guid(100, "DDDDDDDDD4"), name = "Old Rare", class = "rare", dead = true }
	T.Fire("UPDATE_MOUSEOVER_UNIT")
	T.units.mouseover = nil
	return R.GetState(100).state == "killed"
end)())

check("outliers trimmed from the window", (function()
	for _, s in ipairs({ 1000, 1100, 1050, 1150, 1020, 5000 }) do R.AddSample(100, s) end
	local _, top = R.GetWindow(100)
	return top == 1150
end)())
check("absurd samples rejected", R.AddSample(100, 5) == false and R.AddSample(100, 9999999) == false)

-------------------------------------------------------------------------------
section("sharing")
local before = #seen
ns.Share.OnMessage("BRS1", "S:777:1433:300:300:4444-0-77:rareelite:Shared Rare", "GUILD", "Friend-Realm")
check("shared sighting learned and announced", ns.Rares.Get(777) and #seen == before + 1 and seen[#seen].info.by == "Friend")
check("shared rank kept", ns.Rares.Get(777).rank == "rareelite")
ns.Share.OnMessage("BRS1", "S:778:1433:99999:300:x:rare:Bad", "GUILD", "Friend-Realm")
check("out of range coordinates rejected", ns.Rares.Get(778) == nil)
ns.Share.OnMessage("BRS1", "S:777:1433:300:300:x:rare:Me", "GUILD", "Tester-Realm")
check("own messages ignored", #seen == before + 1)
ns.Share.OnMessage("BRS1", "D:777:4444-0-77:120", "GUILD", "Friend-Realm")
check("a death older than the last sighting does not hide it", R.GetState(777).state == "up")
T.Advance(300)
ns.Share.OnMessage("BRS1", "D:777:4444-0-77:120", "GUILD", "Friend-Realm")
check("shared death updates the timer", R.GetState(777).state == "killed" and R.GetRecord(777).kills == 0)
ns.Share.OnMessage("BRS1", "garbage", "GUILD", "Friend-Realm")
ns.Share.OnMessage("BRS1", T.SECRET, "GUILD", "Friend-Realm")
ns.db.settings.share.receive = false
ns.Share.OnMessage("BRS1", "S:779:1433:300:300:x:rare:Off", "GUILD", "Friend-Realm")
check("receive switch respected", ns.Rares.Get(779) == nil)
ns.db.settings.share.receive = true

-------------------------------------------------------------------------------
section("scan key")
T.player.x, T.player.y = 0.40, 0.40
local text, covered = ns.Scan.BuildMacro()
check("scan macro targets nearby rares", text:find("/targetexact Old Rare", 1, true) ~= nil, text)
check("far rares left out", text:find("Brand New Rare", 1, true) == nil, text)
check("scan macro within the length limit", #text <= 255 and covered >= 1)
T.Advance(3)
check("secure button carries the macro", BetterRareSpawnsScan:GetAttribute("macrotext") == text)

for i = 1, 40 do
	ns.Rares.Learn(2000 + i, { name = "Crowded Rare Number " .. i, rank = "rare", map = 1429, x = 40 + (i % 5), y = 40 + i })
end
ns.db.settings.scan.range = 400
text = ns.Scan.BuildMacro()
check("long lists are cut at a line boundary", #text <= 255 and not text:find("\n$") and text:find("^/targetexact "), #text)

-------------------------------------------------------------------------------
section("map pins")
T.mapShown = 1429
ns.MapPins.Refresh()
local function VisiblePins()
	local n = 0
	for _, frame in ipairs(T.frames) do
		if frame.items and frame.__parent == BetterRareSpawnsMapOverlay and frame:IsShown() then n = n + 1 end
	end
	return n
end
local zoomedOut = VisiblePins()
check("pins drawn on the zone map", zoomedOut > 0, zoomedOut)
T.canvasScale = 6
ns.MapPins.Refresh()
check("zooming in splits clustered pins", VisiblePins() >= zoomedOut, VisiblePins() .. " vs " .. zoomedOut)
T.canvasScale = 1

T.mapShown = 1415
ns.MapPins.Refresh()
check("continent map shows only active rares", VisiblePins() >= 1 and VisiblePins() < zoomedOut, VisiblePins())

ns.db.settings.map.enabled = false
ns.Fire("SETTINGS_CHANGED")
check("map toggle hides every pin", VisiblePins() == 0)
ns.db.settings.map.enabled = true
T.mapShown = 1429
ns.Fire("SETTINGS_CHANGED")

-- Hover and click a pin.
local pin
for _, frame in ipairs(T.frames) do
	if frame.items and frame.__parent == BetterRareSpawnsMapOverlay and frame:IsShown() then pin = frame break end
end
pin.__scripts.OnEnter(pin)
check("hover card opens", BetterRareSpawnsCard:IsShown())
T.Update(1.1)
pin.__scripts.OnLeave(pin)
check("hover card closes on leave", not BetterRareSpawnsCard:IsShown())
pin.__scripts.OnClick(pin)
check("click sets a waypoint and tracks", T.waypoint ~= nil and ns.tracked and ns.tracked.id == pin.items[1].id)
T.alt = true
local hiddenID = pin.items[1].id
pin.__scripts.OnClick(pin)
T.alt = false
check("alt-click hides the rare", ns.Rares.IsIgnored(hiddenID))

-------------------------------------------------------------------------------
section("commands and windows")
SlashCmdList.BETTERRARESPAWNS("list")
check("list opens", BetterRareSpawnsTracker and BetterRareSpawnsTracker:IsShown())
SlashCmdList.BETTERRARESPAWNS("config")
check("options open", BetterRareSpawnsOptions and BetterRareSpawnsOptions:IsShown())
SlashCmdList.BETTERRARESPAWNS("unhide")
check("unhide restores rares", not ns.Rares.IsIgnored(hiddenID))
SlashCmdList.BETTERRARESPAWNS("find old")
check("find tracks by partial name", ns.tracked and ns.tracked.id == 100)
SlashCmdList.BETTERRARESPAWNS("stats")
SlashCmdList.BETTERRARESPAWNS("test")
SlashCmdList.BETTERRARESPAWNS("help")
SlashCmdList.BETTERRARESPAWNS("nonsense")

-- Click through every option once.
for _, frame in ipairs(T.frames) do
	if frame.__parent == BetterRareSpawnsOptions and frame.Update and frame.__scripts.OnClick then
		frame.__scripts.OnClick(frame, "LeftButton")
		frame.__scripts.OnClick(frame, "RightButton")
	end
end
ns.DB.ResetSettings()
check("settings reset", ns.db.settings.alerts.enabled == true and ns.db.settings.map.scale == 1.0)

-------------------------------------------------------------------------------
section("journal")
local Journal = ns.Journal
Journal.Toggle(false) -- the options test above pressed its "Rare Journal" button
SlashCmdList.BETTERRARESPAWNS("")
check("journal opens", BetterRareSpawnsJournal and BetterRareSpawnsJournal:IsShown())
local function Ids()
	local ids = {}
	for _, item in ipairs(Journal.GetList()) do ids[#ids + 1] = item.id end
	return table.concat(ids, ",")
end
local total = #Journal.GetList()
check("journal lists every rare", total == ns.Rares.Count(), total)
check("sorted by level", Journal.GetList()[1].level <= Journal.GetList()[total].level, Ids())

Journal.SetSearch("old")
check("search by name", Ids() == "100", Ids())
Journal.SetSearch("redridge")
local function AllIn(mapID)
	if #Journal.GetList() == 0 then return false end
	for _, item in ipairs(Journal.GetList()) do
		if not ns.Rares.Get(item.id).spawns[mapID] then return false end
	end
	return true
end
check("search by zone", AllIn(1433) and Ids():find("101"), Ids())
Journal.SetSearch("25")
check("search by level", Ids():find("101") and #Journal.GetList() < total, Ids())
Journal.SetSearch("ancient fang")
check("search by drop", Ids() == "100", Ids())
Journal.SetSearch("")

Journal.SetFilter("zone", 1433)
check("zone filter", AllIn(1433) and Ids():find("101"), Ids())
Journal.SetFilter("zone", false)
Journal.SetFilter("level", "21-30")
check("level filter", Ids() == "101", Ids())
Journal.SetFilter("level", "any")

Journal.SetFilter("tab", "mine")
local mine = true
for _, item in ipairs(Journal.GetList()) do
	if not ns.Rares.Get(item.id).learned then mine = false end
end
check("seen-by-you tab", mine and #Journal.GetList() >= 1, Ids())
Journal.SetFilter("tab", "zone")
local here = true
for _, item in ipairs(Journal.GetList()) do
	if not ns.Rares.Get(item.id).spawns[1429] then here = false end
end
check("this-zone tab", here and #Journal.GetList() >= 1, Ids())
ns.Rares.SetIgnored(103, true)
Journal.SetFilter("tab", "hidden")
check("hidden tab", Ids() == "103", Ids())
ns.Rares.SetIgnored(103, false)
Journal.SetFilter("tab", "all")
Journal.SetFilter("sort", "name")
check("sort by name", Journal.GetList()[1].name <= Journal.GetList()[2].name, Ids())
Journal.SetFilter("sort", "status")
Journal.SetFilter("sort", "level")

Journal.Select(100)
check("detail page opens", Journal.Selected() == 100)
T.Update(1.1)
T.Fire("GET_ITEM_INFO_RECEIVED", 9001, true)
T.Advance(1)
-- Use every button on the detail page.
for _, frame in ipairs(T.frames) do
	if frame.__template == "UIPanelButtonTemplate" and frame.__scripts.OnClick and frame.__text
		and (frame.__text == "Show on Map" or frame.__text == "Waypoint" or frame.__text == "Link") then
		frame.__scripts.OnClick(frame, "LeftButton")
	end
end
check("journal waypoint tracks the rare", ns.tracked and ns.tracked.id == 100)
BetterRareSpawnsJournal.__scripts.OnMouseWheel(BetterRareSpawnsJournal, -1)
check("wheel steps to the next rare", Journal.Selected() ~= 100 and Journal.Selected() ~= nil, Journal.Selected())
Journal.Select(nil)
check("back returns to the list", Journal.Selected() == nil)
BetterRareSpawnsJournal.__scripts.OnMouseWheel(BetterRareSpawnsJournal, -1)
BetterRareSpawnsJournal.__scripts.OnMouseWheel(BetterRareSpawnsJournal, 1)

Journal.SetFilter("level", "61+")
check("empty result is fine", #Journal.GetList() == 0)
Journal.Open(101)
check("opening a rare clears filters that hide it", Journal.Selected() == 101 and Journal.GetFilter().level == "any")
T.ctrl = true
pin.__scripts.OnClick(pin)
T.ctrl = false
check("ctrl-click on a pin opens its page", Journal.Selected() == pin.items[1].id, Journal.Selected())
ns.MapPins.Focus(100)
Journal.Toggle(false)
check("journal closes", not BetterRareSpawnsJournal:IsShown())
check("no Lua errors in the journal", #T.errors == 0, T.errors[1])

-------------------------------------------------------------------------------
section("kill log")
local Hunt = ns.Hunt
local killsBefore = Hunt.Kills(100)
T.Fire("PARTY_KILL", "Player-1-0001", Guid(100, "KILL000001"))
check("group kill counts once", Hunt.Kills(100) == killsBefore + 1, Hunt.Kills(100))
T.Fire("PARTY_KILL", "Player-1-0001", Guid(100, "KILL000001"))
check("same creature is not counted twice", Hunt.Kills(100) == killsBefore + 1)
T.Fire("UNIT_DIED", Guid(101, "KILL000002"))
check("a death merely witnessed is not a kill", Hunt.Kills(101) == 0)
local killed, known = Hunt.Progress()
check("progress counts rares, not kills", killed >= 1 and killed < known and known == ns.Rares.Count(), killed .. "/" .. known)
Journal.Toggle(true)
Journal.SetFilter("level", "any")
Journal.SetFilter("tab", "todo")
check("not-killed tab leaves out killed rares", not Ids():find("100") and Ids():find("101"), Ids())

-------------------------------------------------------------------------------
section("wanted list")
check("nothing wanted at first", not Hunt.IsWanted(101))
Hunt.SetWanted(101, true)
Journal.SetFilter("tab", "wanted")
check("starred rare is wanted", Hunt.IsWanted(101) and Ids() == "101", Ids())
Hunt.SetWantedItem(9001, true)
Journal.Refresh()
check("a wanted drop makes its rare wanted", Hunt.IsWanted(100) and not Hunt.IsStarred(100) and Ids():find("100"), Ids())
Hunt.SetWantedItem(9001, false)
check("un-starring the drop releases the rare", not Hunt.IsWanted(100))
T.mapShown = 1415
ns.MapPins.Refresh()
local wantedOnContinent = false
for _, frame in ipairs(T.frames) do
	if frame.items and frame.__parent == BetterRareSpawnsMapOverlay and frame:IsShown() then
		for _, item in ipairs(frame.items) do
			if item.id == 101 then wantedOnContinent = true end
		end
	end
end
check("wanted rare stays on the continent map", wantedOnContinent)
T.mapShown = 1429

T.sound = nil
T.units.nameplate7 = { guid = Guid(101, "WANT000001"), name = "Elite Rare", level = 25, class = "rareelite" }
T.Fire("NAME_PLATE_UNIT_ADDED", "nameplate7")
T.Advance(1)
check("wanted rare plays the second alert sound", T.sound == 12889, T.sound)

-- Window watch: kill it, learn a 300 s respawn, wait for the window.
local R2 = ns.Respawn
R2.AddSample(101, 300)
T.Fire("UNIT_DIED", Guid(101, "WANT000001"))
T.Advance(10)
check("wanted rare is on its timer", R2.GetState(101).state == "dead", R2.GetState(101).state)
local chatBefore = #T.chat
T.sound = nil
T.Advance(400)
local opened = false
for i = chatBefore + 1, #T.chat do
	if tostring(T.chat[i]):find("spawn window just opened") then opened = true end
end
check("window opening is announced to the player", opened and T.sound == 12889, T.sound)
local repeats = 0
chatBefore = #T.chat
T.Advance(60)
for i = chatBefore + 1, #T.chat do
	if tostring(T.chat[i]):find("spawn window just opened") then repeats = repeats + 1 end
end
check("and only once", repeats == 0, repeats)

-------------------------------------------------------------------------------
section("announce")
local text = Hunt.AnnounceText(100)
check("announce line has name, level and place", text:find("^Rare: Old Rare %(11%-12%)") and text:find("Elwynn Forest"), text)
T.said = {}
check("goes to the guild when not grouped", Hunt.Announce(100) == "GUILD" and #T.said == 1 and T.said[1][2] == "GUILD")
check("no repeat within the gap", Hunt.Announce(100) == nil and #T.said == 1)
T.grouped = true
check("goes to the party when grouped", Hunt.Announce(101) == "PARTY" and T.said[2][2] == "PARTY")
T.grouped = false
check("general channel found by name", Hunt.Announce(555, "general") == "CHANNEL" and T.said[3][3] == 1, T.said[3] and T.said[3][3])

-------------------------------------------------------------------------------
section("guild sync")
T.sent = {}
T.Advance(3)
T.sent = {}
ns.Share.OnMessage("BRS1", "Q:1", "GUILD", "Newcomer-Realm")
T.Advance(60)
local sawZ, sawD, sawR = false, false, false
for _, message in ipairs(T.sent) do
	if message[3] == "GUILD" then
		if message[2] == "Z:1:Newcomer" then sawZ = true end
		if message[2]:find("^D:101:") then sawD = true end
		if message[2]:find("^R:101:") then sawR = true end
	end
end
check("a request is answered with recent deaths and windows", sawZ and sawD and sawR, #T.sent)
T.sent = {}
ns.Share.OnMessage("BRS1", "Q:1", "GUILD", "Other-Realm")
ns.Share.OnMessage("BRS1", "Z:1:Other", "GUILD", "Friend-Realm")
T.Advance(60)
check("stays quiet when someone else answers", #T.sent == 0, #T.sent)
ns.db.settings.share.sync = false
ns.Share.OnMessage("BRS1", "Q:1", "GUILD", "Third-Realm")
T.Advance(200)
check("sync can be turned off", #T.sent == 0, #T.sent)
ns.db.settings.share.sync = true
check("request goes out on demand", ns.Share.RequestSync() == true)
T.Advance(5)
check("request sent to the guild", T.sent[1] and T.sent[1][2] == "Q:1" and T.sent[1][3] == "GUILD")

-------------------------------------------------------------------------------
section("creature details learned on sight")
T.units.mouseover = { guid = Guid(100, "FAM0000001"), name = "Old Rare", level = 12, class = "rare", type = "Beast", family = "Wolf" }
T.Fire("UPDATE_MOUSEOVER_UNIT")
check("pet family learned from the living creature", ns.Rares.Get(100).family == "Wolf", ns.Rares.Get(100).family)
T.units.mouseover = { guid = Guid(100, "FAM0000001"), name = "Old Rare", dead = true, tooltip = "Skinnable" }
T.Fire("UPDATE_MOUSEOVER_UNIT")
check("skinnable learned from the corpse tooltip", ns.Rares.Get(100).skin == "Skinning", ns.Rares.Get(100).skin)
T.units.mouseover = nil
Journal.SetFilter("tab", "pets")
check("beast family tab", Ids() == "100", Ids())
Journal.SetFilter("tab", "dungeon")
check("dungeon tab", Ids() == "103", Ids())
Journal.SetFilter("tab", "all")
Journal.SetSearch("wolf")
check("search by pet family", Ids() == "100", Ids())
Journal.SetSearch("")
Journal.Select(100)
Journal.Select(101)
Journal.Select(103)
Journal.Toggle(false)

-------------------------------------------------------------------------------
section("camp bar")
local Camp = ns.Camp
Camp.Stop(false) -- earlier sections stood on spawn points long enough to raise it
T.player.map, T.player.x, T.player.y = 1433, 0.30, 0.30 -- on Elite Rare's spawn point
T.Advance(5)
check("no bar for someone passing through", Camp.Current() == nil)
T.Advance(15)
check("bar appears after standing at a spawn point", Camp.Current() ~= nil and BetterRareSpawnsCamp:IsShown(), Camp.Current())
check("wanted rare is preferred", Camp.Current() == 101, Camp.Current())
Camp.Stop(true)
T.Advance(30)
check("closing it dismisses that rare", Camp.Current() == nil)
T.player.x, T.player.y = 0.90, 0.90
T.Advance(5)
T.player.x, T.player.y = 0.30, 0.30
T.Advance(20)
check("coming back offers it again", Camp.Current() == 101)
T.player.x, T.player.y = 0.90, 0.90
T.Advance(15)
check("walking away takes the bar down", Camp.Current() == nil and not BetterRareSpawnsCamp:IsShown())
ns.db.settings.camp.enabled = false
T.player.x, T.player.y = 0.30, 0.30
T.Advance(20)
check("automatic bar can be turned off", Camp.Current() == nil)
SlashCmdList.BETTERRARESPAWNS("camp")
check("/brs camp still works by hand", Camp.Current() == 101)
SlashCmdList.BETTERRARESPAWNS("camp")
ns.db.settings.camp.enabled = true
T.player.map, T.player.x, T.player.y = 1429, 0.5, 0.5

-------------------------------------------------------------------------------
section("minimap button")
check("button exists", BetterRareSpawnsMinimapButton and BetterRareSpawnsMinimapButton:IsShown())
local up, open = ns.MinimapButton.Refresh()
check("summary counts are numbers", type(up) == "number" and type(open) == "number")
BetterRareSpawnsMinimapButton.__scripts.OnEnter(BetterRareSpawnsMinimapButton)
BetterRareSpawnsMinimapButton.__scripts.OnClick(BetterRareSpawnsMinimapButton, "LeftButton")
check("click opens the journal", BetterRareSpawnsJournal:IsShown())
Journal.Toggle(false)
ns.db.settings.minimap.button = false
ns.Fire("SETTINGS_CHANGED")
check("button can be hidden", not BetterRareSpawnsMinimapButton:IsShown())
ns.db.settings.minimap.button = true
ns.Fire("SETTINGS_CHANGED")
SlashCmdList.BETTERRARESPAWNS("kills")
SlashCmdList.BETTERRARESPAWNS("sync")
SlashCmdList.BETTERRARESPAWNS("want old")
check("/brs want stars a rare", Hunt.IsStarred(100))
SlashCmdList.BETTERRARESPAWNS("want old")
check("no Lua errors in the new features", #T.errors == 0, T.errors[1])

-------------------------------------------------------------------------------
section("combat and instances")
T.combat = true
T.units.nameplate3 = { guid = Guid(100, "EEEEEEEEE5"), name = "Old Rare", level = 12, class = "rare" }
BetterRareSpawnsAlert:Hide()
T.Fire("NAME_PLATE_UNIT_ADDED", "nameplate3")
check("card waits for combat to end", not BetterRareSpawnsAlert:IsShown())
T.combat = false
T.Fire("PLAYER_REGEN_ENABLED")
check("card appears after combat", BetterRareSpawnsAlert:IsShown()
	and BetterRareSpawnsAlert:GetAttribute("macrotext") == "/cleartarget\n/targetexact Old Rare")

check("dungeon and raid alerts are on by default", ns.DB.defaults.alerts.instances == true)
T.instance = true
T.units.nameplate4 = { guid = Guid(101, "INST000001"), name = "Elite Rare", level = 25, class = "rareelite" }
ns.db.timers[101] = nil
BetterRareSpawnsAlert:Hide()
T.Advance(400)
T.Fire("NAME_PLATE_UNIT_ADDED", "nameplate4")
T.Advance(1)
check("card appears inside an instance", BetterRareSpawnsAlert:IsShown())
T.instance = false
T.units.nameplate4 = nil

T.player.x, T.player.y = nil, nil
T.Update(1.1)
T.Update(11)
check("no position (instances) is handled", #T.errors == 0, T.errors[1])
T.player.x, T.player.y = 0.5, 0.5

T.Advance(120)
T.Update(1.1)
T.Update(11)

-------------------------------------------------------------------------------
check("no Lua errors anywhere", #T.errors == 0, table.concat(T.errors, "\n"))
print(string.format("%d passed, %d failed", passed, failed))
return failed
