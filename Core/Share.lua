-- Sharing over hidden addon messages (guild and group): live sightings,
-- deaths and learned respawn times. Nothing is ever typed into chat for you.
--
-- Wire format, ":" separated:
--   S:<npcID>:<mapID>:<x*10>:<y*10>:<shard>:<rank>:<name>   sighting
--   D:<npcID>:<shard>:<secondsAgo>                          death
--   R:<npcID>:<seconds>                                     respawn sample (measured)
--   W:<npcID>:<low>:<high>                                  learned window (sync answers only)
--   Q:1                                                     "what do you know?" (guild, at login)
--   Z:1:<requester>                                         "I am answering <requester>" (others stay quiet)
local ADDON, ns = ...

local Share = {}
ns.Share = Share

local Util, Rares, Respawn = ns.Util, ns.Rares, ns.Respawn

local PREFIX = "BRS1"
local SEND_GAP = 60 -- seconds between two messages about the same thing
local SAMPLE_GAP = 600 -- seconds between samples accepted from one sender per rare
local MAX_AGE = 6 * 3600 -- a death older than this says nothing useful
local SYNC_DEATHS = 15 -- most recent deaths sent in one answer
local SYNC_GAP = 120 -- seconds between two answers from this client
local LIVE_QUEUE = 10 -- live messages waiting at most
local SYNC_QUEUE = 60 -- sync messages waiting at most
local SENDER_BURST = 40 -- messages accepted from one sender per SENDER_WINDOW
local SENDER_WINDOW = 60
local LEARN_PER_SENDER = 5 -- unknown rares one sender may teach us per session
local MAX_ID = 2 ^ 31

-- Where a message may come from, and the setting that has to allow it.
local CHANNEL_SETTING = { GUILD = "guild", PARTY = "group", RAID = "group", INSTANCE_CHAT = "group" }

local lastSent = {}
local lastSample = {}
local liveQueue = {}
local syncQueue = {}
local budget = {} -- [sender] = { windowStart, count }
local taught = {} -- [sender] = unknown rares learned from them this session
local sender

local function Settings()
	return ns.db.settings.share
end

local function Channels()
	local settings = Settings()
	local list = {}
	if settings.guild and IsInGuild and IsInGuild() then
		list[#list + 1] = "GUILD"
	end
	if settings.group and IsInGroup and IsInGroup() then
		local home = not LE_PARTY_CATEGORY_HOME or IsInGroup(LE_PARTY_CATEGORY_HOME)
		if home then
			list[#list + 1] = (IsInRaid and IsInRaid()) and "RAID" or "PARTY"
		elseif LE_PARTY_CATEGORY_INSTANCE and IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then
			-- Dungeon finder / LFR group with no home group.
			list[#list + 1] = "INSTANCE_CHAT"
		end
	end
	return list
end

-- Live sightings and deaths go out before sync traffic, so a long sync
-- answer never delays or crowds out news.
local function Flush()
	sender = nil
	local message = table.remove(liveQueue, 1)
	if message then
		for _, channel in ipairs(Channels()) do
			-- Sending is refused in some restricted situations; that is fine.
			pcall(C_ChatInfo.SendAddonMessage, PREFIX, message, channel)
		end
	else
		message = table.remove(syncQueue, 1)
		if not message then
			return
		end
		-- Sync traffic: guild only.
		pcall(C_ChatInfo.SendAddonMessage, PREFIX, message, "GUILD")
	end
	if #liveQueue + #syncQueue > 0 then
		sender = C_Timer.NewTimer(1.2, Flush)
	end
end

local function Send(key, message)
	local now = GetTime()
	if lastSent[key] and now - lastSent[key] < SEND_GAP then
		return
	end
	if #Channels() == 0 or #liveQueue >= LIVE_QUEUE or #message > 240 then
		return
	end
	lastSent[key] = now
	liveQueue[#liveQueue + 1] = message
	if not sender then
		-- A short random delay keeps a whole group from answering at once.
		sender = C_Timer.NewTimer(0.5 + math.random() * 1.5, Flush)
	end
end

--- Queues a guild-only sync message (not subject to the per-topic gap).
local function SendGuild(message)
	if #syncQueue >= SYNC_QUEUE or not (IsInGuild and IsInGuild()) then
		return
	end
	syncQueue[#syncQueue + 1] = message
	if not sender then
		sender = C_Timer.NewTimer(0.5, Flush)
	end
end

-------------------------------------------------------------------------------
-- Outgoing
-------------------------------------------------------------------------------

ns.Listen("RARE_SEEN", function(npcID, info)
	if info.by or info.src == "test" or not info.map or not info.x then
		return
	end
	local entry = Rares.Get(npcID)
	-- A rare only guessed from a vignette stays local until confirmed.
	if entry and entry.unconfirmed then
		return
	end
	local name = gsub(info.name or Rares.Name(npcID), ":", "")
	Send("S" .. npcID, string.format("S:%d:%d:%d:%d:%s:%s:%s", npcID, info.map, info.x * 10, info.y * 10,
		info.shard or "?", entry and entry.rank or "rare", name))
end)

ns.Listen("RARE_DIED", function(npcID, shard, t, approximate, remote)
	if approximate or remote then
		return
	end
	Send("D" .. npcID, string.format("D:%d:%s:%d", npcID, shard or "?", math.max(0, GetServerTime() - t)))
end)

ns.Listen("RESPAWN_SAMPLE", function(npcID, seconds)
	Send("R" .. npcID .. ":" .. seconds, string.format("R:%d:%d", npcID, seconds))
end)

-------------------------------------------------------------------------------
-- Incoming
-------------------------------------------------------------------------------

local handlers = {}

--- A whole non-negative number below `max`, or nil. tonumber alone would
-- also accept "1e999" (inf), "0x10" and fractions.
local function Int(value, max)
	if type(value) ~= "string" or #value > 10 or not strfind(value, "^%d+$") then
		return nil
	end
	value = tonumber(value)
	if not value or value >= (max or MAX_ID) then
		return nil
	end
	return value
end

--- A shard as Util.ParseGUID builds it ("server-instance-zone"), or "?".
local function Shard(value)
	if value == "?" then
		return value
	end
	if type(value) == "string" and #value <= 32 and strfind(value, "^%d+%-%d+%-%d+$") then
		return value
	end
	return nil
end

function handlers.S(from, npcID, mapID, x, y, shard, rank, name)
	mapID, x, y, shard = Int(mapID), Int(x), Int(y), Shard(shard)
	if not mapID or not x or not y or not shard or x > 1000 or y > 1000 then
		return
	end
	if not C_Map.GetMapInfo(mapID) then
		return
	end
	x, y = x / 10, y / 10
	if rank ~= "rareelite" then
		rank = "rare"
	end
	if not Rares.Get(npcID) then
		-- Learning from others obeys the same switch as learning on sight, and
		-- one sender can only teach a handful of new rares per session.
		if not ns.db.settings.detect.learn or (taught[from] or 0) >= LEARN_PER_SENDER then
			return
		end
		-- "|" starts a UI escape (textures, colours, links): never from a peer.
		if not name or name == "" or #name > 60 or strfind(name, "|", 1, true) then
			return
		end
		taught[from] = (taught[from] or 0) + 1
		-- Somebody else's word only: kept as unconfirmed (and not passed on)
		-- until a creature here shows its own classification, which either
		-- confirms it or makes Detect forget it.
		Rares.Learn(npcID, { name = name, rank = rank, map = mapID, x = x, y = y, remote = true, unconfirmed = true })
	end
	if Rares.IsIgnored(npcID) then
		return
	end

	local info = { shard = shard, map = mapID, x = x, y = y, by = from, src = "report", t = GetServerTime() }
	Respawn.RecordSeen(npcID, info)
	info.name = Rares.Name(npcID)
	ns.Fire("RARE_SEEN", npcID, info)
end

function handlers.D(_, npcID, shard, age)
	age, shard = Int(age), Shard(shard)
	if not age or not shard or age > MAX_AGE or not Rares.Get(npcID) then
		return
	end
	local t = GetServerTime() - age
	if Respawn.RecordDeath(npcID, shard, t, false, true) then
		ns.Fire("RARE_DIED", npcID, shard, t, false, true)
	end
end

function handlers.R(from, npcID, seconds)
	seconds = Int(seconds)
	if not seconds or not Rares.Get(npcID) then
		return
	end
	-- One sender cannot flood the estimate for a rare.
	local key = from .. npcID
	local now = GetTime()
	if lastSample[key] and now - lastSample[key] < SAMPLE_GAP then
		return
	end
	lastSample[key] = now
	Respawn.AddSample(npcID, seconds)
	ns.Fire("RARE_UPDATED", npcID)
end

-- A window someone else learned. It is kept apart from measured samples and
-- only used while this client has measured nothing itself, so guild echoes
-- never wash out real data.
function handlers.W(_, npcID, low, high)
	low, high = Int(low), Int(high)
	if not low or not high or low > high or not Rares.Get(npcID) then
		return
	end
	if Respawn.SetSharedWindow(npcID, low, high) then
		ns.Fire("RARE_UPDATED", npcID)
	end
end

-------------------------------------------------------------------------------
-- Login sync: ask the guild once, one member answers
-------------------------------------------------------------------------------

local pendingAnswer = {} -- [requester] = timer
local lastAnswer

--- A sender as every client names them: "Name-Realm". Locally a player of
-- this realm is plain "Name", which would mean someone else elsewhere.
local function FullName(name)
	if strfind(name, "-", 1, true) then
		return name
	end
	local realm = GetNormalizedRealmName and GetNormalizedRealmName()
	return (realm and realm ~= "") and (name .. "-" .. realm) or name
end

local function Answer(requester)
	pendingAnswer[requester] = nil
	local now = GetTime()
	if lastAnswer and now - lastAnswer < SYNC_GAP then
		return
	end
	lastAnswer = now
	SendGuild("Z:1:" .. FullName(requester))

	-- The most recent deaths, newest first, each with what we learned about
	-- that rare's respawn.
	local serverNow = GetServerTime()
	local deaths = {}
	for npcID, rec in pairs(ns.db.timers) do
		if Rares.Get(npcID) then
			for shard, t in pairs(rec.deaths) do
				local age = serverNow - t
				if age >= 0 and age < MAX_AGE then
					deaths[#deaths + 1] = { id = npcID, shard = shard, age = age }
				end
			end
		end
	end
	table.sort(deaths, function(a, b)
		return a.age < b.age
	end)
	local sentWindow = {}
	for i = 1, math.min(#deaths, SYNC_DEATHS) do
		local death = deaths[i]
		SendGuild(string.format("D:%d:%s:%d", death.id, death.shard, death.age))
		if not sentWindow[death.id] then
			sentWindow[death.id] = true
			-- Only windows measured here: re-sending one heard from the guild
			-- would just echo it back.
			local low, high, count = Respawn.GetWindow(death.id)
			if low and count and count > 0 then
				SendGuild(string.format("W:%d:%d:%d", death.id, low, high))
			end
		end
	end
end

function handlers.Q(from)
	if not Settings().sync or pendingAnswer[from] then
		return
	end
	-- A random wait: whoever fires first answers, the rest hear the Z and stop.
	pendingAnswer[from] = C_Timer.NewTimer(2 + math.random() * 6, function()
		Answer(from)
	end)
end

function handlers.Z(_, _, requester)
	-- Back to the local form, the one the request was filed under.
	if requester and Ambiguate then
		requester = Ambiguate(requester, "none")
	end
	local timer = requester and pendingAnswer[requester]
	if timer then
		timer:Cancel()
		pendingAnswer[requester] = nil
	end
end

--- Asks the guild for its timers (once per login, also on /brs sync).
-- Returns true when sent, or false plus why not ("receive", "off" or "guild").
function Share.RequestSync()
	if not Settings().receive then
		return false, "receive"
	end
	-- With guild sharing off the answers would be thrown away on arrival.
	if not Settings().guild then
		return false, "off"
	end
	if not (IsInGuild and IsInGuild()) then
		return false, "guild"
	end
	SendGuild("Q:1")
	return true
end

function Share.OnMessage(prefix, message, channel, from)
	if prefix ~= PREFIX or not Settings().receive then
		return
	end
	message, from = ns.Clean(message), ns.Clean(from)
	if type(message) ~= "string" or type(from) ~= "string" then
		return
	end
	-- Only the channels sharing is about, each behind its own switch: a
	-- whisper must not be able to plant rares or trigger guild traffic.
	local setting = CHANNEL_SETTING[channel]
	if not setting or not Settings()[setting] then
		return
	end
	-- "none" drops the realm only for players of this realm, so a player of
	-- the same name on another realm stays somebody else.
	from = Ambiguate and Ambiguate(from, "none") or from
	if from == UnitName("player") then
		return
	end

	local kind, npcID, a, b, c, d, e, f = strsplit(":", message)
	local handler = handlers[kind]
	npcID = Int(npcID)
	if not handler or not npcID or npcID == 0 then
		return
	end
	-- Sync requests and answers belong to the guild.
	if (kind == "Q" or kind == "Z") and channel ~= "GUILD" then
		return
	end
	-- Per-sender budget, wide enough for one full sync answer.
	local now = GetTime()
	local spent = budget[from]
	if not spent or now - spent[1] >= SENDER_WINDOW then
		spent = { now, 0 }
		budget[from] = spent
	end
	spent[2] = spent[2] + 1
	if spent[2] > SENDER_BURST then
		return
	end
	handler(from, npcID, a, b, c, d, e, f)
end


ns.Listen("READY", function()
	if not C_ChatInfo or not C_ChatInfo.RegisterAddonMessagePrefix then
		return
	end
	C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
	ns.OnEvent("CHAT_MSG_ADDON", Share.OnMessage)
	-- Guild data is not ready at the very moment of login.
	C_Timer.After(15, function()
		if Settings().sync and Settings().receive then
			Share.RequestSync()
		end
	end)
end)
