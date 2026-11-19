-- Respawn engine: remembers sightings and deaths per shard, learns respawn
-- windows from observed death -> next spawn pairs, and answers "what is the
-- state of this rare right now".
local ADDON, ns = ...

local Respawn = {}
ns.Respawn = Respawn

local MIN_SAMPLE = 60 -- seconds; anything shorter is a GUID/clock artefact
local MAX_SAMPLE = 7 * 86400
local MAX_SAMPLES = 30
local UP_TTL = 600 -- a sighting counts as "up now" for this long
local OUTLIER_FACTOR = 1.6 -- samples above median * factor are missed cycles
local OUTLIER_MIN_SAMPLES = 5
local MAX_SHARDS = 8 -- deaths kept per rare, one per layer, newest first
local LATE_REPORT = 15 -- seconds: a sighting this soon after a death is stale news
local REFRESH = 30 -- seconds: a repeat sighting re-announces RARE_UPDATED this often

Respawn.UP_TTL = UP_TTL

-- Sort priority of each state: lower is more interesting.
Respawn.PRIORITY = {
	up = 1,
	overdue = 2,
	window = 3,
	seen = 4,
	dead = 5,
	killed = 6,
	unknown = 7,
}

local function Now()
	return GetServerTime()
end

local function Record(npcID, create)
	local timers = ns.db.timers
	local rec = timers[npcID]
	if not rec and create then
		rec = { deaths = {}, samples = {}, kills = 0 }
		timers[npcID] = rec
	end
	return rec
end

function Respawn.GetRecord(npcID)
	return Record(npcID, false)
end

-------------------------------------------------------------------------------
-- Learning
-------------------------------------------------------------------------------

--- Adds one observed respawn duration (seconds). Returns true when accepted.
function Respawn.AddSample(npcID, seconds)
	if type(seconds) ~= "number" or seconds < MIN_SAMPLE or seconds > MAX_SAMPLE then
		return false
	end
	local rec = Record(npcID, true)
	local samples = rec.samples
	samples[#samples + 1] = math.floor(seconds)
	while #samples > MAX_SAMPLES do
		table.remove(samples, 1)
	end
	rec.estimate = nil
	rec.shared = nil -- own measurements replace a window heard from others
	return true
end

--- Stores a window learned by someone else. It is only used while this
-- client has no samples of its own. Returns true when it changed anything.
function Respawn.SetSharedWindow(npcID, low, high)
	if type(low) ~= "number" or type(high) ~= "number" or low > high
		or low < MIN_SAMPLE or high > MAX_SAMPLE then
		return false
	end
	local rec = Record(npcID, true)
	if #rec.samples > 0 then
		return false
	end
	local shared = rec.shared
	if shared and shared[1] == low and shared[2] == high then
		return false
	end
	rec.shared = { low, high }
	return true
end

--- Returns min, max, sampleCount of the learned respawn window, or nil.
-- sampleCount is 0 for a window that only came from other players.
function Respawn.GetWindow(npcID)
	local rec = Record(npcID, false)
	if not rec then
		return nil
	end
	if #rec.samples == 0 then
		local shared = rec.shared
		if shared then
			return shared[1], shared[2], 0
		end
		return nil
	end

	local cached = rec.estimate
	if cached then
		return cached[1], cached[2], cached[3]
	end

	local sorted = {}
	for i, value in ipairs(rec.samples) do
		sorted[i] = value
	end
	table.sort(sorted)

	local count = #sorted
	if count >= OUTLIER_MIN_SAMPLES then
		-- A death that was not witnessed makes the next sample span two or
		-- more cycles; drop those before taking the maximum.
		local median = sorted[math.ceil(count / 2)]
		while #sorted > 1 and sorted[#sorted] > median * OUTLIER_FACTOR do
			sorted[#sorted] = nil
		end
	end

	local low, high = sorted[1], sorted[#sorted]
	if count < 3 then
		-- Too little data for a real range: widen it a little.
		low, high = math.floor(low * 0.9), math.ceil(high * 1.1)
	end

	rec.estimate = { low, high, count }
	return low, high, count
end

-- Deaths witnessed while the player stayed in the zone, this session only:
-- [npcID .. shard] = watch epoch. The client does not expose spawn times, so
-- a respawn is measured as "death -> first sighting of a new spawn", and that
-- is only meaningful when the player was around the whole time.
local witnessed = {}
local watchEpoch = 0

--- Call when the player leaves the area (zone change, shard transfer).
function Respawn.BreakWatch()
	watchEpoch = watchEpoch + 1
end

--- Records a living rare.
-- info: { shard, newSpawn, map, x, y, by, src, t }
-- newSpawn: this exact creature was not seen before in this session.
function Respawn.RecordSeen(npcID, info)
	local rec = Record(npcID, true)
	local now = info.t or Now()
	local shard = info.shard or "?"

	-- A report that is not a fresh spawn and lands right after a death on the
	-- same layer describes the creature before it died (a delayed share, a
	-- death yell): it must not bring the rare back to life.
	local death = rec.deaths[shard]
	if not info.newSpawn and death and now >= death and now - death < LATE_REPORT then
		return
	end

	if info.newSpawn then
		local key = npcID .. shard
		local death = rec.deaths[shard]
		if death and death < now and witnessed[key] == watchEpoch then
			if Respawn.AddSample(npcID, now - death) then
				ns.Fire("RESPAWN_SAMPLE", npcID, now - death, shard)
			end
		end
		witnessed[key] = nil
	end

	local seen = rec.seen
	if not seen then
		seen = {}
		rec.seen = seen
	end
	-- An older report must not overwrite a newer sighting.
	if not seen.t or now >= seen.t then
		-- Listeners redraw a lot; a repeat look at the same creature in the
		-- same place only needs to tell them now and then.
		local changed = info.newSpawn or not seen.t or now - seen.t >= REFRESH
			or seen.shard ~= shard or seen.map ~= (info.map or seen.map)
		seen.t = now
		seen.shard = shard
		seen.map = info.map or seen.map
		seen.x = info.x or seen.x
		seen.y = info.y or seen.y
		seen.by = info.by
		seen.src = info.src
		if changed then
			ns.Fire("RARE_UPDATED", npcID)
		end
	end
end

--- Drops the oldest layers of a death record beyond MAX_SHARDS, and deaths
-- too old to say anything about the next spawn.
local function PruneDeaths(rec, now)
	local count = 0
	for shard, t in pairs(rec.deaths) do
		if now - t > MAX_SAMPLE then
			rec.deaths[shard] = nil
		else
			count = count + 1
		end
	end
	while count > MAX_SHARDS do
		local oldest, oldestT
		for shard, t in pairs(rec.deaths) do
			if not oldestT or t < oldestT then
				oldest, oldestT = shard, t
			end
		end
		rec.deaths[oldest] = nil
		count = count - 1
	end
end

--- Records a death. Returns true when it was new information.
-- remote: reported by another player; it updates the timer but is not counted
-- as a death this player witnessed.
function Respawn.RecordDeath(npcID, shard, t, approximate, remote)
	local rec = Record(npcID, true)
	shard = shard or "?"
	t = t or Now()

	local known = rec.deaths[shard]
	if known and math.abs(known - t) < 30 then
		return false
	end
	-- A corpse only proves "died at some point before now": it may replace a
	-- known death only when the rare was seen alive on this layer since.
	if approximate and known then
		local seen = rec.seen
		local aliveSince = seen and seen.t and (seen.shard == shard or seen.shard == "?") and seen.t or 0
		if known >= aliveSince then
			return false
		end
	end
	if known and known > t then
		return false
	end

	rec.deaths[shard] = t
	if not approximate and not remote then
		rec.kills = (rec.kills or 0) + 1
		witnessed[npcID .. shard] = watchEpoch
	else
		-- The death time is no longer one this player saw happen.
		witnessed[npcID .. shard] = nil
	end
	PruneDeaths(rec, Now())
	ns.Fire("RARE_UPDATED", npcID)
	return true
end

--- Cleans up saved records once per login: unused fields, old layers.
function Respawn.Prune()
	local now = Now()
	for _, rec in pairs(ns.db.timers) do
		rec.spawnAt = nil
		if type(rec.deaths) == "table" then
			PruneDeaths(rec, now)
		end
	end
end

ns.Listen("READY", function()
	Respawn.Prune()
end)

-------------------------------------------------------------------------------
-- State
-------------------------------------------------------------------------------

--- Describes a rare right now.
-- Returns a table (reused per call site: copy what you keep):
--   state     up | overdue | window | seen | dead | killed | unknown
--   since     seconds since the event that defines the state
--   opensIn   seconds until the window opens (state "dead")
--   closesIn  seconds until the window closes (state "window")
--   progress  0..1 through the window (state "window")
--   min, max, samples   learned window, when known
--   otherShard  true when the data comes from a different shard/layer
function Respawn.GetState(npcID, shard, out)
	out = out or {}
	out.state, out.since, out.opensIn, out.closesIn, out.progress = "unknown", nil, nil, nil, nil
	out.min, out.max, out.samples, out.otherShard, out.seen = nil, nil, nil, nil, nil

	local rec = Record(npcID, false)
	if not rec then
		return out
	end

	local now = Now()
	local low, high, count = Respawn.GetWindow(npcID)
	out.min, out.max, out.samples = low, high, count
	out.seen = rec.seen

	shard = shard or ns.currentShard
	local death = shard and rec.deaths[shard]
	local ownDeath = death ~= nil
	if not death then
		-- Nothing for this shard: fall back to the most recent death anywhere.
		for otherShard, t in pairs(rec.deaths) do
			if not death or t > death then
				death = t
				out.otherShard = (shard ~= nil and otherShard ~= shard) or nil
			end
		end
	end

	-- A sighting beats a death only when it is newer and, when this layer has
	-- a death of its own, from this layer: a rare up on another layer says
	-- nothing about the timer here.
	local seen = rec.seen
	local sameLayer = seen and (seen.shard == shard or seen.shard == "?" or seen.shard == nil)
	if seen and seen.t and (not death or (seen.t > death and (not ownDeath or sameLayer))) then

		out.since = now - seen.t
		out.state = out.since <= UP_TTL and "up" or "seen"
		if shard and seen.shard and seen.shard ~= "?" and seen.shard ~= shard then
			out.otherShard = true
		end
		return out
	end

	if not death then
		return out
	end

	local elapsed = now - death
	out.since = elapsed
	if not low then
		out.state = "killed"
	elseif elapsed < low then
		out.state = "dead"
		out.opensIn = low - elapsed
	elseif elapsed <= high then
		out.state = "window"
		out.closesIn = high - elapsed
		out.progress = high > low and (elapsed - low) / (high - low) or 1
	else
		out.state = "overdue"
		out.since = elapsed - high
	end
	return out
end

--- Forgets everything learned about one rare (or all of them).
function Respawn.Reset(npcID)
	if npcID then
		ns.db.timers[npcID] = nil
		ns.Fire("RARE_UPDATED", npcID)
	else
		wipe(ns.db.timers)
		ns.Fire("RARE_UPDATED")
	end
end
