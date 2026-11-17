-- World map pins.
--
-- Pins live on our own overlay frame above the map canvas instead of in the
-- game's pin system, which keeps addon code out of the secure map code path.
--
--   * pins keep a constant on-screen size and the whole visible dot is the
--     hit area
--   * pins that would overlap at the current zoom merge into one counted pin,
--     and split again when zooming in
--   * colour = state (up / window open / dead ...), so the map reads at a glance
--   * hovering a pin lights up every other spawn point of the same rare
--   * left click acts on release; right click still zooms the map out
local ADDON, ns = ...

local MapPins = {}
ns.MapPins = MapPins

local Util, Rares, Respawn, Status, Card, Style = ns.Util, ns.Rares, ns.Respawn, ns.Status, ns.Card, ns.Style

local PIN_SIZE = 24
local FOCUS_SECONDS = 20

local overlay, canvas
local pins, active = {}, 0
local dirty = true
local scratchState = {}
local hoverID, focusID, focusUntil

local function Settings()
	return ns.db.settings.map
end

-------------------------------------------------------------------------------
-- Pin frames
-------------------------------------------------------------------------------

--- Lights up every pin of the hovered rare, and of the rare the journal asked
-- to point out.
local function UpdateGlow()
	if focusID and GetTime() > focusUntil then
		focusID = nil
	end
	for i = 1, active do
		local pin = pins[i]
		local match = false
		if hoverID or focusID then
			for _, item in ipairs(pin.items) do
				if item.id == hoverID or item.id == focusID then
					match = true
					break
				end
			end
		end
		pin.glow:SetShown(match)
	end
end

local function PinOnEnter(self)
	Card.Show(self, self.items)
	hoverID = self.items[1].id
	UpdateGlow()
end

local function PinOnLeave(self)
	Card.Hide(self)
	hoverID = nil
	UpdateGlow()
end

local function PinOnClick(self)
	local item = self.items[1]
	if IsControlKeyDown and IsControlKeyDown() then
		ns.Fire("OPEN_JOURNAL", item.id)
	elseif IsAltKeyDown() then
		Rares.SetIgnored(item.id, true)
		ns.Print(Rares.Name(item.id) .. " hidden. Undo with /brs unhide.")
	elseif IsShiftKeyDown() then
		Status.LinkToChat(item.id, item.map, item.x, item.y)
	else
		Status.SetWaypoint(item.id, item.map, item.x, item.y)
	end
end

local function CreatePin(index)
	local pin = CreateFrame("Button", nil, overlay)
	Style.Medallion(pin, PIN_SIZE)
	pin:RegisterForClicks("LeftButtonUp")
	pin:SetScript("OnEnter", PinOnEnter)
	pin:SetScript("OnLeave", PinOnLeave)
	pin:SetScript("OnClick", PinOnClick)
	-- Right click keeps its map meaning (zoom out).
	if pin.SetPassThroughButtons and not InCombatLockdown() then
		pcall(pin.SetPassThroughButtons, pin, "RightButton")
	end

	pin.glow = pin:CreateTexture(nil, "BACKGROUND")
	pin.glow:SetTexture("Interface\\Minimap\\UI-Minimap-Ping-Expand")
	pin.glow:SetBlendMode("ADD")
	pin.glow:SetPoint("CENTER")
	pin.glow:SetSize(PIN_SIZE * 2.2, PIN_SIZE * 2.2)
	pin.glow:Hide()

	pin.count = pin:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	pin.count:SetPoint("CENTER", 0, 0)
	pin.count:SetTextColor(0, 0, 0)
	pin.count:SetShadowColor(0, 0, 0, 0)

	pin.label = pin:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	pin.label:SetPoint("TOP", pin, "BOTTOM", 0, -1)

	-- Slow pulse for rares that are up right now.
	local pulse = pin:CreateAnimationGroup()
	pulse:SetLooping("BOUNCE")
	local fade = pulse:CreateAnimation("Alpha")
	fade:SetFromAlpha(1)
	fade:SetToAlpha(0.45)
	fade:SetDuration(0.7)
	pin.pulse = pulse

	pins[index] = pin
	return pin
end

-------------------------------------------------------------------------------
-- Collecting what to show
-------------------------------------------------------------------------------

local function Passes(entry, settings)
	if Rares.IsIgnored(entry.id) then
		return false
	end
	if settings.minLevel > 0 and entry.level and entry.level < settings.minLevel then
		return false
	end
	return true
end

local function StateOf(npcID)
	local info = Respawn.GetState(npcID, nil, scratchState)
	return info.state
end

--- Items for a zone map: every spawn point, plus the live position of rares
-- that are up.
local function CollectZone(mapID, items, settings)
	local list = Rares.OnMap(mapID)
	if not list then
		return
	end
	for _, entry in ipairs(list) do
		if Passes(entry, settings) then
			local state = StateOf(entry.id)
			local rec = Respawn.GetRecord(entry.id)
			local seen = rec and rec.seen
			local live = state == "up" and seen and seen.map == mapID and seen.x

			if live then
				-- It is up and we know where: one pin, at that spot.
				items[#items + 1] = { id = entry.id, map = mapID, x = seen.x, y = seen.y, px = seen.x, py = seen.y, state = state, rank = entry.rank }
			else
				local points = entry.spawns[mapID]
				for i = 1, #points, 2 do
					items[#items + 1] = { id = entry.id, map = mapID, x = points[i], y = points[i + 1], px = points[i], py = points[i + 1], state = state, rank = entry.rank }
				end
			end
		end
	end
end

local ACTIVE = { up = true, overdue = true, window = true }

--- Items for a continent map: only rares worth travelling for, one pin each.
local function CollectContinent(mapID, items, settings)
	local maps = Rares.Maps()
	if not maps then
		return
	end
	for zoneMap, list in pairs(maps) do
		if Util.Translate(zoneMap, 50, 50, mapID) then
			for _, entry in ipairs(list) do
				if Passes(entry, settings) then
					local state = StateOf(entry.id)
					if ACTIVE[state] then
						local _, x, y = Status.BestPoint(entry.id, zoneMap)
						local px, py
						if x then
							px, py = Util.Translate(zoneMap, x, y, mapID)
						end
						if px and px >= 0 and px <= 100 and py >= 0 and py <= 100 then
							items[#items + 1] = { id = entry.id, map = zoneMap, x = x, y = y, px = px, py = py, state = state, rank = entry.rank }
						end
					end
				end
			end
		end
	end
end

local function ByPriority(a, b)
	local pa, pb = Respawn.PRIORITY[a.state], Respawn.PRIORITY[b.state]
	if pa ~= pb then
		return pa < pb
	end
	return a.id < b.id
end

-------------------------------------------------------------------------------
-- Refresh
-------------------------------------------------------------------------------

local function CanvasScale()
	if WorldMapFrame.GetCanvasScale then
		local ok, scale = pcall(WorldMapFrame.GetCanvasScale, WorldMapFrame)
		if ok and scale and scale > 0 then
			return scale
		end
	end
	local scale = canvas:GetScale()
	return (scale and scale > 0) and scale or 1
end

local function HideAll()
	for i = 1, active do
		pins[i].pulse:Stop()
		pins[i]:Hide()
	end
	active = 0
	Card.Hide()
end

function MapPins.Refresh()
	dirty = false
	if not overlay then
		return
	end
	local settings = Settings()
	local mapID = WorldMapFrame:GetMapID()
	if not settings.enabled or not mapID or not WorldMapFrame:IsShown() then
		return HideAll()
	end

	local items = {}
	local info = C_Map.GetMapInfo(mapID)
	local continentType = Enum and Enum.UIMapType and Enum.UIMapType.Continent or 2
	if info and info.mapType == continentType then
		if settings.continent then
			CollectContinent(mapID, items, settings)
		end
	else
		CollectZone(mapID, items, settings)
	end
	table.sort(items, ByPriority)

	local width, height = overlay:GetWidth(), overlay:GetHeight()
	local canvasScale = CanvasScale()
	local pinScale = settings.scale / canvasScale
	-- Two pins merge when their centres are closer than ~80% of a pin.
	local reach = PIN_SIZE * pinScale * 0.8

	local clusters = {}
	for _, item in ipairs(items) do
		local cx, cy = width * item.px / 100, height * item.py / 100
		local home
		for _, cluster in ipairs(clusters) do
			if math.abs(cluster.cx - cx) < reach and math.abs(cluster.cy - cy) < reach then
				home = cluster
				break
			end
		end
		if home then
			-- The same rare twice in one cluster adds nothing.
			local duplicate = false
			for _, other in ipairs(home.items) do
				if other.id == item.id then
					duplicate = true
					break
				end
			end
			if not duplicate then
				home.items[#home.items + 1] = item
			end
		else
			clusters[#clusters + 1] = { cx = cx, cy = cy, items = { item } }
		end
	end

	local tracked = ns.tracked and ns.tracked.id
	local hovered
	local previous = active
	active = #clusters

	for i, cluster in ipairs(clusters) do
		local pin = pins[i] or CreatePin(i)
		local first = cluster.items[1] -- highest priority thanks to the sort
		pin.items = cluster.items

		local color = Status.COLORS[first.state]
		pin.fill:SetVertexColor(color[1], color[2], color[3])
		-- Dark skull on the state colour; a gold ring when a rare elite is here,
		-- silver otherwise (as on the target frame).
		pin.icon:SetVertexColor(0.1, 0.1, 0.1)
		local elite = false
		for _, item in ipairs(cluster.items) do
			if item.rank == "rareelite" then
				elite = true
				break
			end
		end
		Style.MedallionRank(pin, elite and "rareelite" or "rare")

		local many = #cluster.items > 1
		pin.count:SetText(many and #cluster.items or "")
		pin.icon:SetShown(not many)
		pin.label:SetText((settings.labels and not many) and Rares.Name(first.id) or "")

		local quiet = first.state == "unknown" or first.state == "killed" or first.state == "dead"
		pin:SetAlpha(settings.alpha * (quiet and 0.7 or 1))

		local scale = pinScale * ((tracked and tracked == first.id) and 1.35 or 1)
		pin:SetScale(scale)
		pin:ClearAllPoints()
		pin:SetPoint("CENTER", overlay, "TOPLEFT", cluster.cx / scale, -cluster.cy / scale)
		-- More interesting pins sit on top of less interesting ones.
		pin:SetFrameLevel(overlay:GetFrameLevel() + 20 - (Respawn.PRIORITY[first.state] or 7))
		pin:Show()

		if first.state == "up" then
			pin.pulse:Play()
		else
			pin.pulse:Stop()
		end

		if not hovered and pin:IsMouseOver() then
			hovered = pin
		end
	end

	for i = active + 1, previous do
		pins[i].pulse:Stop()
		pins[i]:Hide()
	end

	-- Pins were rebuilt under the cursor: keep the card consistent.
	if hovered then
		PinOnEnter(hovered)
	else
		hoverID = nil
		Card.Hide()
		UpdateGlow()
	end
end

--- Points a rare out on the map for a while (used by the journal).
function MapPins.Focus(npcID)
	focusID, focusUntil = npcID, GetTime() + FOCUS_SECONDS
	dirty = true
	if overlay then
		MapPins.Refresh()
	end
end

function MapPins.MarkDirty()
	dirty = true
end

-------------------------------------------------------------------------------
-- Setup
-------------------------------------------------------------------------------

local function CreateToggle()
	local parent = WorldMapFrame.ScrollContainer or WorldMapFrame
	local button = CreateFrame("Button", "BetterRareSpawnsMapToggle", parent)
	Style.Medallion(button, 31)
	button:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", 8, 8)
	button:SetFrameLevel(parent:GetFrameLevel() + 50)
	button:SetHighlightTexture(Style.TEX.ringHighlight, "ADD")
	button.icon:SetVertexColor(0.1, 0.1, 0.1)

	local function Update()
		if Settings().enabled then
			button.fill:SetVertexColor(1, 0.82, 0)
			button:SetAlpha(1)
		else
			button.fill:SetVertexColor(0.45, 0.45, 0.45)
			button:SetAlpha(0.7)
		end
	end

	button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	button:SetScript("OnClick", function(_, mouseButton)
		if mouseButton == "RightButton" then
			ns.Fire("OPEN_OPTIONS")
		elseif IsShiftKeyDown() then
			ns.Fire("OPEN_JOURNAL")
		else
			Settings().enabled = not Settings().enabled
			ns.Fire("SETTINGS_CHANGED")
		end
	end)
	button:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetText("Rare Spawns")
		GameTooltip:AddLine("Click: show / hide rare pins", 1, 1, 1)
		GameTooltip:AddLine("Shift-click: rare journal", 1, 1, 1)
		GameTooltip:AddLine("Right-click: options", 1, 1, 1)
		GameTooltip:Show()
	end)
	button:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)

	ns.Listen("SETTINGS_CHANGED", Update)
	Update()
end

local function Setup()
	if overlay or not WorldMapFrame then
		return
	end
	canvas = (WorldMapFrame.ScrollContainer and WorldMapFrame.ScrollContainer.Child)
		or (WorldMapFrame.GetCanvasContainer and WorldMapFrame:GetCanvasContainer())
	if not canvas then
		return
	end

	overlay = CreateFrame("Frame", "BetterRareSpawnsMapOverlay", canvas)
	overlay:SetAllPoints(canvas)
	overlay:SetFrameLevel(canvas:GetFrameLevel() + 10)

	-- Redraw at most twice a second, and only when something changed. A slow
	-- tick also keeps colours honest as timers run out.
	local elapsed, slow = 0, 0
	overlay:SetScript("OnUpdate", function(_, delta)
		elapsed = elapsed + delta
		slow = slow + delta
		if slow >= 10 then
			slow = 0
			dirty = true
		end
		if dirty and elapsed >= 0.5 then
			elapsed = 0
			MapPins.Refresh()
		end
	end)
	overlay:SetScript("OnShow", MapPins.Refresh)
	overlay:SetScript("OnHide", function()
		Card.Hide()
	end)

	if EventRegistry and EventRegistry.RegisterCallback then
		EventRegistry:RegisterCallback("MapCanvas.MapSet", function()
			MapPins.Refresh()
		end, MapPins)
	elseif WorldMapFrame.OnMapChanged then
		hooksecurefunc(WorldMapFrame, "OnMapChanged", MapPins.Refresh)
	end
	if WorldMapFrame.OnCanvasScaleChanged then
		hooksecurefunc(WorldMapFrame, "OnCanvasScaleChanged", MapPins.Refresh)
	end

	CreateToggle()
	MapPins.Refresh()
end

ns.Listen("READY", function()
	Setup()
	if not overlay then
		-- The map UI is not there yet on some clients: try again when it loads.
		ns.OnEvent("ADDON_LOADED", Setup)
	end
end)

ns.Listen("RARES_CHANGED", MapPins.MarkDirty)
ns.Listen("RARE_UPDATED", MapPins.MarkDirty)
ns.Listen("TRACK_CHANGED", MapPins.MarkDirty)
ns.Listen("SETTINGS_CHANGED", function()
	MapPins.Refresh()
end)
