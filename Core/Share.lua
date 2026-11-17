-- Sharing over hidden addon messages (guild and group): live sightings,
-- deaths and learned respawn times. Nothing is ever typed into chat for you.
--
-- Wire format, ":" separated:
--   S:<npcID>:<mapID>:<x*10>:<y*10>:<shard>:<rank>:<name>   sighting
--   D:<npcID>:<shard>:<secondsAgo>                          death
--   R:<npcID>:<seconds>                                     respawn sample
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

local lastSent = {}
local lastSample = {}
local queue = {}
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
		list[#list + 1] = (IsInRaid and IsInRaid()) and "RAID" or "PARTY"
	end
	return list
end

local function Flush()
	sender = nil
	local message = table.remove(queue, 1)
	if not message then
		return
	end
	if type(message) == "table" then
		-- Sync traffic: guild only.
		pcall(C_ChatInfo.SendAddonMessage, PREFIX, message[1], "GUILD")
	else
		for _, channel in ipairs(Channels()) do
			-- Sending is refused in some restricted situations; that is fine.
			pcall(C_ChatInfo.SendAddonMessage, PREFIX, message, channel)
		end
	end
	if #queue > 0 then
		sender = C_Timer.NewTimer(1.2, Flush)
	end
end

local function Send(key, message)
	local now = GetTime()
	if lastSent[key] and now - lastSent[key] < SEND_GAP then
		return
	end
	if #Channels() == 0 or #queue >= 10 or #message > 240 then
		return
	end
	lastSent[key] = now
	queue[#queue + 1] = message
	if not sender then
		-- A short random delay keeps a whole group from answering at once.
		sender = C_Timer.NewTimer(0.5 + math.random() * 1.5, Flush)
	end
end

--- Queues a guild-only sync message (not subject to the per-topic gap).
local function SendGuild(message)
	if #queue >= 60 or not (IsInGuild and IsInGuild()) then
		return
	end
	queue[#queue + 1] = { message }
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

function handlers.S(from, npcID, mapID, x, y, shard, rank, name)
	mapID, x, y = tonumber(mapID), tonumber(x), tonumber(y)
	if not mapID or not x or not y or x < 0 or x > 1000 or y < 0 or y > 1000 then
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
		if not name or name == "" or #name > 60 then
			return
		end
		Rares.Learn(npcID, { name = name, rank = rank, map = mapID, x = x, y = y })
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
	age = tonumber(age)
	if not age or age < 0 or age > MAX_AGE or not Rares.Get(npcID) then
		return
	end
	local t = GetServerTime() - age
	if Respawn.RecordDeath(npcID, shard, t, false, true) then
		ns.Fire("RARE_DIED", npcID, shard, t, false, true)
	end
end

function handlers.R(from, npcID, seconds)
	seconds = tonumber(seconds)
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

-------------------------------------------------------------------------------
-- Login sync: ask the guild once, one member answers
-------------------------------------------------------------------------------

local pendingAnswer = {} -- [requester] = timer
local lastAnswer

local function Answer(requester)
	pendingAnswer[requester] = nil
	local now = GetTime()
	if lastAnswer and now - lastAnswer < SYNC_GAP then
		return
	end
	lastAnswer = now
	SendGuild("Z:1:" .. requester)

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
			local low, high = Respawn.GetWindow(death.id)
			if low then
				SendGuild(string.format("R:%d:%d", death.id, math.floor((low + high) / 2)))
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
	local timer = requester and pendingAnswer[requester]
	if timer then
		timer:Cancel()
		pendingAnswer[requester] = nil
	end
end

--- Asks the guild for its timers (once per login, also on /brs sync).
function Share.RequestSync()
	if not (IsInGuild and IsInGuild()) then
		return false
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
	from = Ambiguate and Ambiguate(from, "short") or from
	if from == UnitName("player") then
		return
	end

	local kind, npcID, a, b, c, d, e, f = strsplit(":", message)
	npcID = tonumber(npcID)
	local handler = handlers[kind]
	if handler and npcID and npcID > 0 then
		handler(from, npcID, a, b, c, d, e, f)
	end
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
