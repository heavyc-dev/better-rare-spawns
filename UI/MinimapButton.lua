-- Minimap button, in the game's round-button art, plus an optional data
-- broker feed ("2 up, 3 open") for bar addons that show those.
--
-- Click: journal. Shift-click: zone list. Right-click: options. Drag: move
-- it around the minimap.
local ADDON, ns = ...

local MinimapButton = {}
ns.MinimapButton = MinimapButton

local Rares, Status, Style, Hunt = ns.Rares, ns.Status, ns.Style, ns.Hunt

local MAX_LINES = 8

local button
local broker
local summary = {}

local function Settings()
	return ns.db.settings.minimap
end

local function SummaryText(up, open)
	if up == 0 and open == 0 then
		return "Rares"
	end
	local parts = {}
	if up > 0 then
		parts[#parts + 1] = "|cff4dff66" .. up .. " up|r"
	end
	if open > 0 then
		parts[#parts + 1] = "|cffffd933" .. open .. " open|r"
	end
	return table.concat(parts, ", ")
end

--- Fills a tooltip with what is going on right now.
local function FillTooltip(tooltip)
	tooltip:AddLine("Rare Spawns")
	local up, open = Hunt.Summary(summary)
	if #summary == 0 then
		tooltip:AddLine("Nothing up and no timers running.", 0.8, 0.8, 0.8)
	else
		for i = 1, math.min(#summary, MAX_LINES) do
			local item = summary[i]
			local text, r, g, b = Status.Describe(item.id, true)
			local star = Hunt.IsWanted(item.id) and "* " or ""
			tooltip:AddDoubleLine(star .. Rares.Name(item.id), text, 1, 1, 1, r, g, b)
		end
		if #summary > MAX_LINES then
			tooltip:AddLine("+" .. (#summary - MAX_LINES) .. " more", 0.6, 0.6, 0.6)
		end
	end
	local killed, total = Hunt.Progress()
	tooltip:AddLine(" ")
	tooltip:AddDoubleLine("Rares killed", killed .. " / " .. total, 0.8, 0.8, 0.8, 1, 0.82, 0)
	tooltip:AddLine("Click: journal   Shift-click: zone list", 0.6, 0.6, 0.6)
	tooltip:AddLine("Right-click: options   Drag: move", 0.6, 0.6, 0.6)
	return up, open
end

local function OnClick(_, mouseButton)
	if mouseButton == "RightButton" then
		ns.Fire("OPEN_OPTIONS")
	elseif IsShiftKeyDown() then
		ns.Tracker.Toggle()
	else
		ns.Journal.Toggle()
	end
end

-------------------------------------------------------------------------------
-- The button
-------------------------------------------------------------------------------

local function Place()
	local angle = math.rad(Settings().angle or 205)
	local radius = (Minimap:GetWidth() or 140) / 2 + 6
	button:ClearAllPoints()
	button:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * radius, math.sin(angle) * radius)
end

local function Create()
	button = CreateFrame("Button", "BetterRareSpawnsMinimapButton", Minimap)
	Style.Medallion(button, 31)
	button:SetFrameStrata("MEDIUM")
	button:SetFrameLevel((Minimap:GetFrameLevel() or 1) + 8)
	button:SetHighlightTexture(Style.TEX.ringHighlight, "ADD")
	button.fill:SetVertexColor(0.12, 0.10, 0.08)
	button.icon:SetSize(18, 18)

	-- How many rares are up, in the corner.
	button.badge = button:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
	button.badge:SetPoint("BOTTOMRIGHT", -2, 3)

	button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	button:RegisterForDrag("LeftButton")
	button:SetScript("OnClick", OnClick)
	button:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_LEFT")
		FillTooltip(GameTooltip)
		GameTooltip:Show()
	end)
	button:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)
	button:SetScript("OnDragStart", function(self)
		GameTooltip:Hide()
		self:SetScript("OnUpdate", function()
			local cx, cy = Minimap:GetCenter()
			local x, y = GetCursorPosition()
			local scale = Minimap:GetEffectiveScale()
			if cx and x and scale and scale > 0 then
				Settings().angle = math.deg(math.atan2(y / scale - cy, x / scale - cx))
				Place()
			end
		end)
	end)
	button:SetScript("OnDragStop", function(self)
		self:SetScript("OnUpdate", nil)
	end)
	Place()
end

function MinimapButton.Refresh()
	local showButton = Minimap and Settings().button
	if not showButton and not broker then
		-- Nothing shows the summary: skip the scan.
		if button then
			button:Hide()
		end
		return 0, 0
	end
	local up, open = Hunt.Summary()
	if showButton then
		if not button then
			Create()
		end
		button:Show()
		button.badge:SetText(up > 0 and up or "")
		if up > 0 then
			button.icon:SetVertexColor(0.30, 1.00, 0.40)
		elseif open > 0 then
			button.icon:SetVertexColor(1.00, 0.85, 0.20)
		else
			button.icon:SetVertexColor(1, 1, 1)
		end
	elseif button then
		button:Hide()
	end
	if broker then
		broker.text = SummaryText(up, open)
	end
	return up, open
end

-------------------------------------------------------------------------------
-- Data broker (only when some other addon brought the library)
-------------------------------------------------------------------------------

local function CreateBroker()
	local libStub = _G.LibStub
	if type(libStub) ~= "table" and type(libStub) ~= "function" then
		return
	end
	local ok, library = pcall(libStub, "LibDataBroker-1.1", true)
	if not ok or type(library) ~= "table" or type(library.NewDataObject) ~= "function" then
		return
	end
	local okObject, object = pcall(library.NewDataObject, library, "BetterRareSpawns", {
		type = "data source",
		label = "Rares",
		text = "Rares",
		icon = Style.TEX.skull,
		OnClick = OnClick,
		OnTooltipShow = FillTooltip,
	})
	if okObject then
		broker = object
	end
end

ns.Listen("READY", function()
	CreateBroker()
	MinimapButton.Refresh()
	C_Timer.NewTicker(5, function()
		ns.SafeCall(MinimapButton.Refresh)
	end)
end)

ns.Listen("SETTINGS_CHANGED", function()
	MinimapButton.Refresh()
	-- "Defaults" in the options also resets where the button sits.
	if button then
		Place()
	end
end)

-- Sightings and sync answers come in bursts: one refresh per burst.
local refreshPending = false
ns.Listen("RARE_UPDATED", function()
	if refreshPending then
		return
	end
	refreshPending = true
	C_Timer.After(0.5, function()
		refreshPending = false
		ns.SafeCall(MinimapButton.Refresh)
	end)
end)

