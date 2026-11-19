-- Minimap pins: state-coloured dots for nearby spawn points, plus an edge
-- marker for the tracked rare. Positioned with our own maths (no libraries).
local ADDON, ns = ...

local MinimapPins = {}
ns.MinimapPins = MinimapPins

local Util, Rares, Respawn, Status, Card = ns.Util, ns.Rares, ns.Respawn, ns.Status, ns.Card

local PIN_SIZE = 11
local CIRCLE_MASK = "Interface\\CharacterFrame\\TempPortraitAlphaMask"
-- View radius in yards per zoom level, for clients without C_Minimap.GetViewRadius.
local RADIUS = { [0] = 233.3, 200, 166.7, 133.3, 100, 66.7 }

local holder
local pins, active = {}, 0
local points = {} -- { id, x, y, state, rank } on the player's current map
local pointsMap
local pointsDirty = true
local scratchState = {}

local function Settings()
	return ns.db.settings.minimap
end

local function Circle(parent, layer, inset)
	local texture = parent:CreateTexture(nil, layer)
	texture:SetPoint("TOPLEFT", inset, -inset)
	texture:SetPoint("BOTTOMRIGHT", -inset, inset)
	texture:SetColorTexture(1, 1, 1, 1)
	if parent.CreateMaskTexture then
		local ok, mask = pcall(parent.CreateMaskTexture, parent)
		if ok and mask then
			mask:SetTexture(CIRCLE_MASK, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
			mask:SetAllPoints(texture)
			texture:AddMaskTexture(mask)
		end
	end
	return texture
end

local function CreatePin(index)
	local pin = CreateFrame("Frame", nil, holder)
	pin:SetSize(PIN_SIZE, PIN_SIZE)
	pin.border = Circle(pin, "BORDER", 0)
	pin.fill = Circle(pin, "ARTWORK", 1.5)

	-- Hover only: clicks keep going to the minimap.
	pin:EnableMouse(true)
	if pin.SetMouseClickEnabled then
		pcall(pin.SetMouseClickEnabled, pin, false)
	end
	pin:SetScript("OnEnter", function(self)
		Card.Show(self, { self.item }, "Shown on your map - click the map pin to track")
	end)
	pin:SetScript("OnLeave", function(self)
		Card.Hide(self)
	end)

	pins[index] = pin
	return pin
end

-- How far beyond the edge of the player's map (in map percent) a point of a
-- neighbouring zone is still kept. The minimap shows at most ~230 yards.
local EDGE = 25

--- Adds a point given on `zoneMap`. mx, my are its coordinates on the
-- player's map, which is what the minimap maths works in; map, x, y stay as
-- the rare's own for the hover card.
local function AddPoint(entry, state, zoneMap, x, y, playerMap)
	local tracked = ns.tracked
	if tracked and tracked.id == entry.id and tracked.map == zoneMap and tracked.x == x and tracked.y == y then
		return -- drawn as the tracked waypoint instead
	end
	local mx, my = x, y
	if zoneMap ~= playerMap then
		mx, my = Util.ToMap(zoneMap, x, y, playerMap)
		if not mx or mx < -EDGE or mx > 100 + EDGE or my < -EDGE or my > 100 + EDGE then
			return
		end
	end
	points[#points + 1] = { id = entry.id, map = zoneMap, x = x, y = y, mx = mx, my = my, state = state, rank = entry.rank }
end

local function AddZone(zoneMap, list, playerMap)
	for _, entry in ipairs(list) do
		if not Rares.IsIgnored(entry.id) then
			local state = Respawn.GetState(entry.id, nil, scratchState).state
			local liveX, liveY
			if state == "up" then
				liveX, liveY = Status.LivePoint(entry.id, zoneMap)
			end
			if liveX then
				AddPoint(entry, state, zoneMap, liveX, liveY, playerMap)
			else
				local spawn = entry.spawns[zoneMap]
				for i = 1, #spawn, 2 do
					AddPoint(entry, state, zoneMap, spawn[i], spawn[i + 1], playerMap)
				end
			end
		end
	end
end

--- Every point worth drawing: the player's zone, plus the parts of other
-- zones on the same continent that lie just across its border.
local function RebuildPoints(mapID)
	wipe(points)
	pointsMap = mapID
	pointsDirty = false
	local maps = mapID and Rares.Maps()
	if not maps then
		return
	end
	for zoneMap, list in pairs(maps) do
		if zoneMap == mapID or Util.ToMap(zoneMap, 50, 50, mapID) then
			AddZone(zoneMap, list, mapID)
		end
	end

	-- The tracked waypoint, wherever it is on this continent: it is the one
	-- point that stays on the rim when out of view.
	local tracked = ns.tracked
	local entry = tracked and tracked.map and tracked.x and Rares.Get(tracked.id)
	if entry then
		local mx, my = Util.ToMap(tracked.map, tracked.x, tracked.y, mapID)
		if mx then
			points[#points + 1] = {
				id = entry.id, map = tracked.map, x = tracked.x, y = tracked.y, mx = mx, my = my,
				state = Respawn.GetState(entry.id, nil, scratchState).state, rank = entry.rank, tracked = true,
			}
		end
	end
end

local function ViewRadius()
	if C_Minimap and C_Minimap.GetViewRadius then
		local ok, radius = pcall(C_Minimap.GetViewRadius)
		if ok and radius and radius > 0 then
			return radius
		end
	end
	return RADIUS[Minimap:GetZoom() or 0] or RADIUS[0]
end

local function HideAll()
	for i = 1, active do
		pins[i]:Hide()
	end
	active = 0
end

local function Update()
	local settings = Settings()
	local mapID, px, py = Util.PlayerPosition()
	if not settings.enabled or not px or not Minimap:IsVisible() then
		return HideAll()
	end
	if pointsDirty or mapID ~= pointsMap then
		RebuildPoints(mapID)
	end

	local radiusYards = ViewRadius()
	local radiusPixels = Minimap:GetWidth() / 2
	local square = GetMinimapShape and GetMinimapShape() == "SQUARE"
	local facing = (GetCVar("rotateMinimap") == "1") and GetPlayerFacing() or nil
	local sin, cos
	if facing then
		sin, cos = math.sin(facing), math.cos(facing)
	end
	local used = 0
	for _, point in ipairs(points) do
		local dx, dy = Util.Offset(mapID, px, py, point.mx, point.my)
		if dx then
			-- Map y grows southward; screen y grows upward.
			local sx, sy = dx, -dy
			if facing then
				-- Rotate by -facing so the player's heading points up.
				sx, sy = sx * cos + sy * sin, -sx * sin + sy * cos
			end
			local distance = math.sqrt(sx * sx + sy * sy)
			local inside
			if square then
				inside = math.abs(sx) <= radiusYards and math.abs(sy) <= radiusYards
			else
				inside = distance <= radiusYards
			end

			local isTracked = point.tracked == true

			if inside or isTracked then
				if not inside then
					-- Tracked rare beyond the edge: pin it to the rim.
					local factor = radiusYards / distance
					sx, sy = sx * factor, sy * factor
				end
				used = used + 1
				local pin = pins[used] or CreatePin(used)
				pin.item = point
				local color = Status.COLORS[point.state]
				pin.fill:SetVertexColor(color[1], color[2], color[3])
				if point.rank == "rareelite" then
					pin.border:SetVertexColor(1, 0.82, 0.2)
				else
					pin.border:SetVertexColor(0, 0, 0)
				end
				pin:SetScale(settings.scale * (isTracked and 1.4 or 1))
				local scale = pin:GetScale()
				pin:ClearAllPoints()
				pin:SetPoint("CENTER", Minimap, "CENTER", sx / radiusYards * radiusPixels / scale, sy / radiusYards * radiusPixels / scale)
				pin:SetAlpha((point.state == "unknown" or point.state == "killed" or point.state == "dead") and 0.65 or 1)
				pin:Show()
			end
		end
	end

	for i = used + 1, active do
		pins[i]:Hide()
	end
	active = used
end

local function MarkDirty()
	pointsDirty = true
end

ns.Listen("READY", function()
	if not Minimap then
		return
	end
	holder = CreateFrame("Frame", "BetterRareSpawnsMinimap", Minimap)
	holder:SetAllPoints(Minimap)
	holder:SetFrameLevel(Minimap:GetFrameLevel() + 6)

	local fast, slow = 0, 0
	holder:SetScript("OnUpdate", function(_, delta)
		fast = fast + delta
		slow = slow + delta
		if slow >= 5 then
			slow = 0
			pointsDirty = true -- states drift with time
		end
		if fast >= 0.12 then
			fast = 0
			Update()
		end
	end)
end)

ns.Listen("RARES_CHANGED", MarkDirty)
ns.Listen("RARE_UPDATED", MarkDirty)
ns.Listen("TRACK_CHANGED", MarkDirty)
ns.Listen("SETTINGS_CHANGED", MarkDirty)
