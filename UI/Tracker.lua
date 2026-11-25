-- Tracker: a small list of the rares in the current zone, most promising
-- first, with live timers. Answers "what is worth checking right now".
local ADDON, ns = ...

local Tracker = {}
ns.Tracker = Tracker

local Util, Rares, Respawn, Status, Card, Style = ns.Util, ns.Rares, ns.Respawn, ns.Status, ns.Card, ns.Style

local WIDTH = 250
local ROW_HEIGHT = 18
local MAX_ROWS = 14
local HEADER = 28

local frame
local rows = {}
local ACTIVE = { up = true, overdue = true, window = true, seen = true, dead = true }

local function Settings()
	return ns.db.settings.tracker
end

local function RowOnClick(self)
	local item = self.item
	if not item then
		return
	end
	if IsControlKeyDown and IsControlKeyDown() then
		ns.Fire("OPEN_JOURNAL", item.id)
	elseif IsAltKeyDown() then
		Rares.SetIgnored(item.id, true)
		ns.Print(Rares.Name(item.id) .. " hidden. Undo with /brs unhide.")
	elseif IsShiftKeyDown() then
		Status.LinkToChat(item.id, item.map, item.x, item.y)
	else
		Status.ToggleWaypoint(item.id, item.map, item.x, item.y, true)
	end
end

local function CreateRow(index)
	local row = CreateFrame("Button", nil, frame)
	row:SetHeight(ROW_HEIGHT)
	row:SetPoint("TOPLEFT", 8, -HEADER - (index - 1) * ROW_HEIGHT)
	row:SetPoint("RIGHT", -8, 0)
	row:RegisterForClicks("LeftButtonUp")

	Style.RowHighlight(row)

	row.dot = row:CreateTexture(nil, "ARTWORK")
	row.dot:SetSize(14, 14)
	row.dot:SetPoint("LEFT", 0, 0)
	row.dot:SetTexture(Style.TEX.skull)

	row.status = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	row.status:SetPoint("RIGHT", -2, 0)
	row.status:SetJustifyH("RIGHT")

	row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	row.name:SetPoint("LEFT", row.dot, "RIGHT", 6, 0)
	row.name:SetPoint("RIGHT", row.status, "LEFT", -6, 0)
	row.name:SetJustifyH("LEFT")
	row.name:SetWordWrap(false)

	row:SetScript("OnEnter", function(self)
		if self.item then
			Card.Show(self, { self.item })
		end
	end)
	row:SetScript("OnLeave", function(self)
		Card.Hide(self)
	end)
	row:SetScript("OnClick", RowOnClick)

	rows[index] = row
	return row
end

local function Collect()
	local mapID, px, py = Util.PlayerPosition()
	local items = {}
	local list = mapID and Rares.OnMap(mapID)
	if not list then
		return items, mapID
	end
	local activeOnly = Settings().activeOnly
	local state = {}
	for _, entry in ipairs(list) do
		if not Rares.IsIgnored(entry.id) then
			local info = Respawn.GetState(entry.id, nil, state)
			if not activeOnly or ACTIVE[info.state] then
				local _, x, y = Status.BestPoint(entry.id, mapID)
				items[#items + 1] = {
					id = entry.id,
					map = mapID,
					x = x,
					y = y,
					state = info.state,
					rank = entry.rank,
					distance = (px and x) and Util.Distance(mapID, px, py, mapID, x, y) or 99999,
				}
			end
		end
	end
	table.sort(items, function(a, b)
		local pa, pb = Respawn.PRIORITY[a.state], Respawn.PRIORITY[b.state]
		if pa ~= pb then
			return pa < pb
		end
		return a.distance < b.distance
	end)
	return items, mapID
end

function Tracker.Refresh()
	if not frame or not frame:IsShown() then
		return
	end
	local items, mapID = Collect()
	local shown = math.min(#items, MAX_ROWS)

	local title = mapID and Util.MapName(mapID) or "Rares"
	frame.title:SetText(title .. "  |cff9a9a9a" .. #items .. "|r")

	for i = 1, shown do
		local row = rows[i] or CreateRow(i)
		local item = items[i]
		local before = row.item
		row.item = item
		-- The list re-sorts under a resting cursor: keep the card on the row's
		-- new rare.
		if Card.IsShownFor(row) and (not before or before.id ~= item.id) then
			Card.Show(row, { item })
		end

		local text, r, g, b = Status.Describe(item.id, true)
		row.dot:SetVertexColor(r, g, b)
		row.status:SetText(text)
		row.status:SetTextColor(r, g, b)

		local color = Status.RANK_COLORS[item.rank or "rare"] or Status.RANK_COLORS.rare
		row.name:SetText(Rares.Name(item.id))
		row.name:SetTextColor(color[1], color[2], color[3])
		row:Show()
	end
	for i = shown + 1, #rows do
		rows[i].item = nil
		Card.Hide(rows[i])
		rows[i]:Hide()
	end

	local footer
	if #items == 0 then
		footer = mapID and "No rares known here yet.\nThey are added as you meet them." or "No map position here."
	elseif #items > shown then
		footer = "+" .. (#items - shown) .. " more"
	end
	frame.footer:SetText(footer or "")
	local extra = footer and (frame.footer:GetStringHeight() + 8) or 0
	frame:SetHeight(HEADER + shown * ROW_HEIGHT + extra + 10)
	frame.footer:ClearAllPoints()
	frame.footer:SetPoint("BOTTOMLEFT", 10, 9)
end

local function Create()
	frame = Style.Frame("Frame", "BetterRareSpawnsTracker", UIParent)
	frame:SetSize(WIDTH, 100)
	frame:SetPoint("RIGHT", UIParent, "RIGHT", -60, 60)
	frame:SetFrameStrata("MEDIUM")
	frame:Hide() -- new frames start shown
	Style.Tooltip(frame, 0.9)

	frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	frame.title:SetPoint("TOPLEFT", 10, -9)

	frame.footer = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	frame.footer:SetJustifyH("LEFT")
	frame.footer:SetWidth(WIDTH - 16)

	local close = Style.Close(frame, function()
		Tracker.Toggle(false)
	end, 24)
	close:SetPoint("TOPRIGHT", 0, 0)

	-- Header shortcuts: small icon buttons.
	local function HeaderIcon(texture, tip, message, anchor, gap)
		local button = CreateFrame("Button", nil, frame)
		button:SetSize(16, 16)
		button:SetPoint("RIGHT", anchor, "LEFT", gap, 0)
		button:SetNormalTexture(texture)
		button:SetHighlightTexture(Style.TEX.squareHighlight, "ADD")
		button:SetScript("OnClick", function()
			ns.Fire(message)
		end)
		button:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_TOP")
			GameTooltip:SetText(tip)
			GameTooltip:Show()
		end)
		button:SetScript("OnLeave", function()
			GameTooltip:Hide()
		end)
		return button
	end
	local gear = HeaderIcon("Interface\\Icons\\Trade_Engineering", "Options", "OPEN_OPTIONS", close, 0)
	HeaderIcon("Interface\\Icons\\INV_Misc_Book_09", "Rare journal", "OPEN_JOURNAL", gear, -4)

	Util.MakeMovable(frame, "tracker", function()
		return Settings().locked
	end)
	frame:SetScale(Settings().scale)

	local elapsed = 0
	frame:SetScript("OnUpdate", function(_, delta)
		elapsed = elapsed + delta
		if elapsed >= 1 then
			elapsed = 0
			Tracker.Refresh()
		end
	end)
end

--- Shows or hides the list. Pass nil to toggle.
function Tracker.Toggle(show)
	if not frame then
		Create()
	end
	if show == nil then
		show = not frame:IsShown()
	end
	Settings().shown = show
	frame:SetShown(show)
	Tracker.Refresh()
end

function BetterRareSpawns_ToggleTracker()
	Tracker.Toggle()
end

ns.Listen("READY", function()
	if Settings().shown then
		Tracker.Toggle(true)
	end
end)

ns.Listen("RARES_CHANGED", Tracker.Refresh)
ns.Listen("RARE_UPDATED", Tracker.Refresh)
ns.Listen("SETTINGS_CHANGED", function()
	if frame then
		frame:SetScale(Settings().scale)
		-- "Defaults" in the options can hide it.
		if frame:IsShown() ~= Settings().shown then
			frame:SetShown(Settings().shown)
		end
	end
	Tracker.Refresh()
end)

