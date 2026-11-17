-- Rare journal: a book of every known rare, built on the game's spellbook
-- frame art. Twelve rares to a page, tabs down the side, search and filters
-- on top; clicking a rare turns to its own page with a 3D model, where it
-- spawns, its timer and what it drops.
local ADDON, ns = ...

local Journal = {}
ns.Journal = Journal

local Util, Rares, Respawn, Status, Style, Card = ns.Util, ns.Rares, ns.Respawn, ns.Status, ns.Style, ns.Card

local PER_PAGE = 12
local DROPS_PER_ROW = 8
local DROP_ROWS = 2
local LEFT = 28 -- left edge of the page area inside the book art
local PAGE_WIDTH = 312

local TABS = {
	{ key = "all", title = "All rares", icon = "Interface\\Icons\\INV_Misc_Book_09", tip = "Every rare the addon knows." },
	{ key = "zone", title = "This zone", icon = "Interface\\Icons\\INV_Misc_Map_01", tip = "Rares in the zone you are standing in." },
	{ key = "active", title = "Active", icon = "Interface\\Icons\\INV_Misc_PocketWatch_01", tip = "Up now, recently seen, or with a running timer." },
	{ key = "mine", title = "Seen by you", icon = "Interface\\Icons\\INV_Misc_Eye_01", tip = "Rares this account has met in the world." },
	{ key = "hidden", title = "Hidden", icon = "Interface\\Icons\\Ability_Vanish", tip = "Rares you hid from the map and lists." },
}

local LEVELS = {
	{ value = "any", text = "Any level" },
	{ value = "mine", text = "My level" },
	{ value = "1-10", text = "1 - 10", 1, 10 },
	{ value = "11-20", text = "11 - 20", 11, 20 },
	{ value = "21-30", text = "21 - 30", 21, 30 },
	{ value = "31-40", text = "31 - 40", 31, 40 },
	{ value = "41-50", text = "41 - 50", 41, 50 },
	{ value = "51-60", text = "51 - 60", 51, 60 },
	{ value = "61+", text = "61+", 61, 999 },
}

local SORTS = {
	{ value = "level", text = "By level" },
	{ value = "name", text = "By name" },
	{ value = "status", text = "By status" },
}

local ACTIVE = { up = true, overdue = true, window = true, seen = true, dead = true, killed = true }
local RANK_LABEL = { rare = "Rare", rareelite = "Rare Elite" }

local filter = { tab = "all", zone = false, level = "any", sort = "level", search = "" }
local list = {} -- filtered, sorted: { id, name, level, state, map, rank }
local page = 1
local selected -- npcID shown on the detail page, or nil for the list
local stale = false

local frame, listView, detail
local rows, tabs, dropButtons = {}, {}, {}
local scratch = {}

-------------------------------------------------------------------------------
-- Items
-------------------------------------------------------------------------------

local itemNames = {}

local function ItemInfo(itemID)
	local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
	if not getInfo then
		return nil
	end
	local name, link, quality = getInfo(itemID) -- cached data only
	if name then
		itemNames[itemID] = strlower(name)
	end
	return name, link, quality
end

local function ItemIcon(itemID)
	local icon
	if C_Item and C_Item.GetItemIconByID then
		icon = C_Item.GetItemIconByID(itemID)
	elseif GetItemIcon then
		icon = GetItemIcon(itemID)
	end
	return icon or Style.TEX.questionMark
end

local function RequestItem(itemID)
	if C_Item and C_Item.RequestLoadItemDataByID then
		pcall(C_Item.RequestLoadItemDataByID, itemID)
	end
end

--- True when a cached drop name of this rare contains `query`.
local function DropMatches(npcID, query)
	local imported = ns.db.imported and ns.db.imported.drops and ns.db.imported.drops[npcID]
	if imported then
		for _, itemID in ipairs(imported) do
			local name = itemNames[itemID]
			if name == nil then
				ItemInfo(itemID)
				name = itemNames[itemID]
			end
			if name and strfind(name, query, 1, true) then
				return true
			end
		end
	end
	local own = ns.db.loot[npcID]
	if own then
		for itemID in pairs(own) do
			if itemNames[itemID] == nil then
				ItemInfo(itemID)
			end
			local name = itemNames[itemID]
			if name and strfind(name, query, 1, true) then
				return true
			end
		end
	end
	return false
end

-------------------------------------------------------------------------------
-- The list behind the pages
-------------------------------------------------------------------------------

local function PrimaryMap(entry, prefer)
	if prefer and entry.spawns[prefer] then
		return prefer
	end
	local best, bestCount
	for mapID, points in pairs(entry.spawns) do
		if not best or #points > bestCount or (#points == bestCount and mapID < best) then
			best, bestCount = mapID, #points
		end
	end
	return best
end

local function LevelRange()
	if filter.level == "mine" then
		local level = ns.Clean(UnitLevel("player"))
		if type(level) == "number" and level > 0 then
			return level - 4, level + 4
		end
		return nil
	end
	for _, option in ipairs(LEVELS) do
		if option.value == filter.level then
			return option[1], option[2]
		end
	end
end

local function Sorter(a, b)
	if filter.sort == "status" then
		local pa, pb = Respawn.PRIORITY[a.state] or 9, Respawn.PRIORITY[b.state] or 9
		if pa ~= pb then
			return pa < pb
		end
	elseif filter.sort == "name" then
		if a.name ~= b.name then
			return a.name < b.name
		end
	end
	if a.level ~= b.level then
		return a.level < b.level
	end
	if a.name ~= b.name then
		return a.name < b.name
	end
	return a.id < b.id
end

--- Rebuilds the filtered list. Returns it (shared table, do not keep).
function Journal.Collect()
	wipe(list)
	local playerMap = Util.PlayerPosition()
	local low, high = LevelRange()
	local query = strlower(strtrim(filter.search or ""))
	local queryNumber = tonumber(query)
	local zone = filter.zone or (filter.tab == "zone" and playerMap) or nil

	for npcID, entry in pairs(Rares.All()) do
		local ignored = Rares.IsIgnored(npcID)
		local state = Respawn.GetState(npcID, nil, scratch).state
		local pass

		if filter.tab == "hidden" then
			pass = ignored
		elseif ignored then
			pass = false
		elseif filter.tab == "zone" then
			pass = playerMap ~= nil and entry.spawns[playerMap] ~= nil
		elseif filter.tab == "active" then
			pass = ACTIVE[state] == true
		elseif filter.tab == "mine" then
			pass = entry.learned == true
		else
			pass = true
		end

		if pass and filter.zone and not entry.spawns[filter.zone] then
			pass = false
		end
		if pass and low then
			local top = entry.level
			local bottom = entry.minLevel or top
			pass = top ~= nil and top >= low and bottom <= high
		end

		local name = Rares.Name(npcID)
		local mapID = PrimaryMap(entry, zone)
		if pass and query ~= "" then
			local hit = strfind(strlower(name), query, 1, true) ~= nil
			if not hit and queryNumber then
				hit = entry.level == queryNumber
			end
			if not hit then
				for spawnMap in pairs(entry.spawns) do
					if strfind(strlower(Util.MapName(spawnMap)), query, 1, true) then
						hit = true
						break
					end
				end
			end
			if not hit and #query >= 3 then
				hit = DropMatches(npcID, query)
			end
			pass = hit
		end

		if pass then
			list[#list + 1] = { id = npcID, name = name, level = entry.level or 0, state = state, map = mapID, rank = entry.rank }
		end
	end

	table.sort(list, Sorter)
	return list
end

function Journal.GetList()
	return list
end

local function PageCount()
	return math.max(1, math.ceil(#list / PER_PAGE))
end

local function IndexOf(npcID)
	for index, item in ipairs(list) do
		if item.id == npcID then
			return index
		end
	end
end

-------------------------------------------------------------------------------
-- Actions
-------------------------------------------------------------------------------

local function ShowOnMap(npcID)
	local mapID, x, y = Status.BestPoint(npcID, filter.zone or nil)
	if not mapID then
		ns.Print("No known position for " .. Rares.Name(npcID) .. ".")
		return
	end
	Status.SetWaypoint(npcID, mapID, x, y)
	if InCombatLockdown() then
		ns.Print("The map cannot be opened for you in combat. The waypoint is set.")
		return
	end
	if WorldMapFrame then
		if not WorldMapFrame:IsShown() then
			if ToggleWorldMap then
				pcall(ToggleWorldMap)
			elseif ShowUIPanel then
				pcall(ShowUIPanel, WorldMapFrame)
			end
		end
		if WorldMapFrame.SetMapID then
			pcall(WorldMapFrame.SetMapID, WorldMapFrame, mapID)
		end
	end
	if ns.MapPins and ns.MapPins.Focus then
		ns.MapPins.Focus(npcID)
	end
end

-------------------------------------------------------------------------------
-- List page
-------------------------------------------------------------------------------

local function RowOnClick(self)
	if not self.item then
		return
	end
	if IsShiftKeyDown() then
		Status.LinkToChat(self.item.id)
	else
		Journal.Select(self.item.id)
	end
end

local function SetPortraitModel(model, npcID)
	if model.shownID == npcID then
		return
	end
	model.shownID = npcID
	model:ClearModel()
	pcall(model.SetCreature, model, npcID)
	if model.SetPortraitZoom then
		pcall(model.SetPortraitZoom, model, 0.85)
	end
end

local function CreateRow(index)
	local row = CreateFrame("Button", nil, listView)
	local column, line = (index - 1) % 2, math.floor((index - 1) / 2)
	row:SetSize(152, 40)
	row:SetPoint("TOPLEFT", frame, "TOPLEFT", LEFT + column * 160, -110 - line * 46)
	row:RegisterForClicks("LeftButtonUp")

	-- Portrait slot: dark well, tinted skull as a fallback, then the creature's
	-- head when the client can draw it, then the slot's frame art on top.
	local well = row:CreateTexture(nil, "BACKGROUND")
	well:SetSize(36, 36)
	well:SetPoint("LEFT", 2, 0)
	well:SetColorTexture(0, 0, 0, 0.55)

	row.skull = row:CreateTexture(nil, "ARTWORK")
	row.skull:SetTexture(Style.TEX.skull)
	row.skull:SetSize(22, 22)
	row.skull:SetPoint("CENTER", well, "CENTER")

	row.model = CreateFrame("PlayerModel", nil, row)
	row.model:SetAllPoints(well)
	row.model:SetScript("OnModelLoaded", function(self)
		if self.SetPortraitZoom then
			pcall(self.SetPortraitZoom, self, 0.85)
		end
	end)

	local top = CreateFrame("Frame", nil, row)
	top:SetAllPoints(well)
	top:SetFrameLevel(row:GetFrameLevel() + 3)
	local art = top:CreateTexture(nil, "ARTWORK")
	art:SetTexture(Style.TEX.slot)
	art:SetSize(36 * 64 / 37, 36 * 64 / 37)
	art:SetPoint("CENTER", 0, -1)

	-- State pip in the slot's corner.
	local pip = CreateFrame("Frame", nil, top)
	pip:SetSize(12, 12)
	pip:SetPoint("BOTTOMRIGHT", 2, -2)
	local rim = Style.Disc(pip, "BACKGROUND", 0)
	rim:SetVertexColor(0, 0, 0)
	row.pip = Style.Disc(pip, "ARTWORK", 2)

	row.name = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	row.name:SetPoint("TOPLEFT", well, "TOPRIGHT", 6, 0)
	row.name:SetPoint("RIGHT", 0, 0)
	row.name:SetJustifyH("LEFT")
	row.name:SetWordWrap(false)

	row.sub = Style.Ink(row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"))
	row.sub:SetPoint("TOPLEFT", row.name, "BOTTOMLEFT", 0, -1)
	row.sub:SetPoint("RIGHT", 0, 0)
	row.sub:SetJustifyH("LEFT")
	row.sub:SetWordWrap(false)

	row.zone = Style.Ink(row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"), true)
	row.zone:SetPoint("TOPLEFT", row.sub, "BOTTOMLEFT", 0, -1)
	row.zone:SetPoint("RIGHT", 0, 0)
	row.zone:SetJustifyH("LEFT")
	row.zone:SetWordWrap(false)

	Style.RowHighlight(row)
	row:SetScript("OnClick", RowOnClick)
	row:SetScript("OnEnter", function(self)
		if self.item then
			Card.Show(self, { self.item }, "Click: open page   Shift: link")
		end
	end)
	row:SetScript("OnLeave", function(self)
		Card.Hide(self)
	end)

	rows[index] = row
	return row
end

local function RenderList()
	local pages = PageCount()
	page = math.max(1, math.min(page, pages))
	local first = (page - 1) * PER_PAGE

	for i = 1, PER_PAGE do
		local row = rows[i] or CreateRow(i)
		local item = list[first + i]
		row.item = item
		if item then
			row.name:SetText(item.name)
			local ink = Style.INK_STATE[item.state]
			local bright = Status.COLORS[item.state]
			row.pip:SetVertexColor(bright[1], bright[2], bright[3])
			row.skull:SetVertexColor(bright[1], bright[2], bright[3])

			local status = Status.Describe(item.id, true)
			local level = "Level " .. (Rares.LevelText(item.id) or "??")
			if item.rank == "rareelite" then
				level = level .. " Elite"
			end
			row.sub:SetText(level)
			if item.state ~= "unknown" then
				row.zone:SetText(status)
				row.zone:SetTextColor(ink[1], ink[2], ink[3])
			else
				row.zone:SetText(item.map and Util.MapName(item.map) or "Location unknown")
				row.zone:SetTextColor(Style.INK_FAINT[1], Style.INK_FAINT[2], Style.INK_FAINT[3])
			end
			SetPortraitModel(row.model, item.id)
			row:Show()
		else
			row:Hide()
		end
	end

	frame.pageText:SetText(string.format("Page %d / %d", page, pages))
	frame.prev:SetEnabled(page > 1)
	frame.next:SetEnabled(page < pages)

	local empty
	if #list == 0 then
		if Rares.Count() == 0 then
			empty = "No rares known yet.\n\nThey are added as you meet them in the world.\nInstall the QuestieDB addon to fill this book\nwith every rare and its drops."
		else
			empty = "No rares match."
		end
	end
	listView.empty:SetText(empty or "")
	listView.count:SetText(#list .. (#list == 1 and " rare" or " rares"))
end

-------------------------------------------------------------------------------
-- Detail page
-------------------------------------------------------------------------------

local dropList, dropOffset = {}, 0

local function SortDrops()
	for _, drop in ipairs(dropList) do
		local _, _, quality = ItemInfo(drop.id)
		drop.quality = quality or -1
	end
	table.sort(dropList, function(a, b)
		if (a.seen ~= nil) ~= (b.seen ~= nil) then
			return a.seen ~= nil
		end
		if a.quality ~= b.quality then
			return a.quality > b.quality
		end
		return a.id < b.id
	end)
end

local function RenderDrops()
	local visible = DROPS_PER_ROW * DROP_ROWS
	dropOffset = math.max(0, math.min(dropOffset, math.max(0, #dropList - visible)))
	for i = 1, visible do
		local button = dropButtons[i]
		local drop = dropList[dropOffset + i]
		button.drop = drop
		if drop then
			button.icon:SetTexture(ItemIcon(drop.id))
			button.count:SetText(drop.seen and ("x" .. drop.seen) or "")
			local color = drop.quality and drop.quality >= 2 and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[drop.quality]
			if color then
				button.glow:SetVertexColor(color.r, color.g, color.b)
				button.glow:Show()
			else
				button.glow:Hide()
			end
			button:Show()
		else
			button:Hide()
		end
	end

	local note
	if #dropList == 0 then
		note = "None known yet - loot it to record what it drops."
	elseif #dropList > visible then
		note = string.format("%d - %d of %d (scroll)", dropOffset + 1, math.min(dropOffset + visible, #dropList), #dropList)
	else
		note = #dropList .. (#dropList == 1 and " item" or " items")
	end
	detail.dropsNote:SetText(note)
end

local function RenderStatus()
	if not selected then
		return
	end
	local text, _, _, _, state = Status.Describe(selected)
	local ink = Style.INK_STATE[state]
	detail.status:SetText(text)
	detail.status:SetTextColor(ink[1], ink[2], ink[3])
end

local function RenderDetail()
	local npcID = selected
	local entry = Rares.Get(npcID)
	if not entry then
		return Journal.Select(nil)
	end

	local rankColor = Status.RANK_COLORS[entry.rank or "rare"] or Status.RANK_COLORS.rare
	detail.name:SetText(Rares.Name(npcID))
	detail.rank:SetText(string.format("Level %s %s", Rares.LevelText(npcID) or "??", RANK_LABEL[entry.rank] or "Rare"))
	detail.modelBox.rankBar:SetVertexColor(rankColor[1], rankColor[2], rankColor[3])
	RenderStatus()

	local lines = {}
	if entry.sub then
		lines[#lines + 1] = "<" .. entry.sub .. ">"
	end
	if entry.type then
		lines[#lines + 1] = entry.type
	end
	if entry.health then
		lines[#lines + 1] = "Health: " .. (BreakUpLargeNumbers and BreakUpLargeNumbers(entry.health) or entry.health)
	end
	lines[#lines + 1] = Status.WindowText(npcID) or "Respawn: not learned yet"
	local rec = Respawn.GetRecord(npcID)
	local seen = rec and rec.seen
	if seen and seen.t then
		local line = "Last seen " .. Util.Duration(GetServerTime() - seen.t) .. " ago"
		if seen.by then
			line = line .. " by " .. seen.by
		end
		lines[#lines + 1] = line
	end
	if rec and (rec.kills or 0) > 0 then
		lines[#lines + 1] = "Deaths witnessed: " .. rec.kills
	end
	if entry.friendly == "A" then
		lines[#lines + 1] = "Friendly to the Alliance"
	elseif entry.friendly == "H" then
		lines[#lines + 1] = "Friendly to the Horde"
	end
	if entry.learned then
		lines[#lines + 1] = "You have met this rare"
	end
	detail.info:SetText(table.concat(lines, "\n"))

	local zones = {}
	for mapID, points in pairs(entry.spawns) do
		zones[#zones + 1] = { name = Util.MapName(mapID), count = #points / 2 }
	end
	table.sort(zones, function(a, b)
		if a.count ~= b.count then
			return a.count > b.count
		end
		return a.name < b.name
	end)
	local zoneText = {}
	for _, zone in ipairs(zones) do
		zoneText[#zoneText + 1] = string.format("%s (%d spawn point%s)", zone.name, zone.count, zone.count == 1 and "" or "s")
	end
	detail.zones:SetText(#zoneText > 0 and table.concat(zoneText, ", ")
		or "Spawn location not known - inside a dungeon, or not met yet.")
	detail.map:SetEnabled(#zoneText > 0)
	detail.way:SetEnabled(#zoneText > 0)

	if detail.model.shownID ~= npcID then
		detail.model.shownID = npcID
		detail.model.facing = 0
		detail.model:ClearModel()
		pcall(detail.model.SetCreature, detail.model, npcID)
		if detail.model.SetFacing then
			detail.model:SetFacing(0)
		end

		dropList = Rares.Drops(npcID)
		dropOffset = 0
		for _, drop in ipairs(dropList) do
			RequestItem(drop.id)
		end
		SortDrops()
	end
	RenderDrops()

	detail.hide:SetText(Rares.IsIgnored(npcID) and "Unhide" or "Hide")

	local index = IndexOf(npcID)
	frame.pageText:SetText(index and string.format("%d / %d", index, #list) or "")
	frame.prev:SetEnabled(index ~= nil and index > 1)
	frame.next:SetEnabled(index ~= nil and index < #list)
end

-------------------------------------------------------------------------------
-- Rendering and navigation
-------------------------------------------------------------------------------

local function Render()
	if not frame or not frame:IsShown() then
		return
	end
	stale = false
	listView:SetShown(not selected)
	detail:SetShown(selected ~= nil)
	if selected then
		RenderDetail()
	else
		RenderList()
	end
	for _, tab in ipairs(tabs) do
		tab:SetChecked(tab.key == filter.tab)
	end
end

local function Rebuild()
	if not frame or not frame:IsShown() then
		return
	end
	Journal.Collect()
	Render()
end
Journal.Refresh = Rebuild

--- Turns pages in the list, or steps to the neighbouring rare on a detail page.
local function Turn(step)
	if selected then
		local index = IndexOf(selected)
		local target = index and list[index + step]
		if target then
			Style.Sound("page")
			Journal.Select(target.id)
		end
	else
		local target = math.max(1, math.min(page + step, PageCount()))
		if target ~= page then
			page = target
			Style.Sound("page")
			Render()
		end
	end
end

--- Opens a rare's page, or returns to the list with nil.
function Journal.Select(npcID)
	if npcID and not Rares.Get(npcID) then
		npcID = nil
	end
	if not npcID and selected then
		-- Back to the list: land on the page that holds the rare we left.
		local index = IndexOf(selected)
		if index then
			page = math.ceil(index / PER_PAGE)
		end
	end
	selected = npcID
	Card.Hide()
	Render()
end

function Journal.Selected()
	return selected
end

--- Changes one filter: tab, zone (mapID or false), level, sort.
function Journal.SetFilter(key, value)
	if filter[key] == value then
		return
	end
	filter[key] = value
	page = 1
	selected = nil
	Rebuild()
	if frame then
		for _, dropdown in ipairs(frame.dropdowns) do
			dropdown.Update()
		end
	end
end

function Journal.SetSearch(text)
	text = text or ""
	if filter.search == text then
		return
	end
	filter.search = text
	page = 1
	selected = nil
	Rebuild()
end

function Journal.GetFilter()
	return filter
end

-------------------------------------------------------------------------------
-- Construction
-------------------------------------------------------------------------------

local function ZoneOptions()
	local options = {}
	for mapID in pairs(Rares.Maps() or {}) do
		options[#options + 1] = { value = mapID, text = Util.MapName(mapID) }
	end
	table.sort(options, function(a, b)
		return a.text < b.text
	end)
	table.insert(options, 1, { value = false, text = "All zones" })
	return options
end

local function CreateArrow(direction, x)
	local art = Style.TEX.pageArrow .. direction .. "Page-"
	local button = CreateFrame("Button", nil, frame)
	button:SetSize(32, 32)
	button:SetPoint("CENTER", frame, "BOTTOMLEFT", x, 105)
	button:SetNormalTexture(art .. "Up")
	button:SetPushedTexture(art .. "Down")
	button:SetDisabledTexture(art .. "Disabled")
	button:SetHighlightTexture(Style.TEX.mouseHighlight, "ADD")
	button:SetScript("OnClick", function()
		Turn(direction == "Prev" and -1 or 1)
	end)
	return button
end

local function CreateTab(index, info)
	local tab = CreateFrame("CheckButton", nil, frame)
	tab:SetSize(32, 32)
	tab:SetPoint("TOPLEFT", frame, "TOPRIGHT", -32, -65 - (index - 1) * 49)
	tab.key = info.key

	local back = tab:CreateTexture(nil, "BACKGROUND")
	back:SetTexture(Style.TEX.bookTab)
	back:SetSize(64, 64)
	back:SetPoint("TOPLEFT", -3, 11)

	tab:SetNormalTexture(info.icon)
	tab:SetHighlightTexture(Style.TEX.squareHighlight, "ADD")
	tab:SetCheckedTexture(Style.TEX.checkHighlight)
	local checked = tab:GetCheckedTexture()
	if type(checked) == "table" and checked.SetBlendMode then
		checked:SetBlendMode("ADD")
	end

	tab:SetScript("OnClick", function(self)
		Style.Sound("page")
		Journal.SetFilter("tab", self.key)
		self:SetChecked(true)
	end)
	tab:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetText(info.title)
		GameTooltip:AddLine(info.tip, 1, 1, 1, true)
		GameTooltip:Show()
	end)
	tab:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)
	tabs[index] = tab
	return tab
end

local function CreateDropButton(index)
	local size = 32
	local column, line = (index - 1) % DROPS_PER_ROW, math.floor((index - 1) / DROPS_PER_ROW)
	local button = Style.ItemButton(detail, size)
	button:SetPoint("TOPLEFT", frame, "TOPLEFT", LEFT + 2 + column * 38, -298 - line * 36)
	button:RegisterForClicks("LeftButtonUp")

	button.glow = button:CreateTexture(nil, "OVERLAY")
	button.glow:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
	button.glow:SetBlendMode("ADD")
	button.glow:SetAlpha(0.7)
	button.glow:SetSize(size * 1.8, size * 1.8)
	button.glow:SetPoint("CENTER")
	button.glow:Hide()

	button:SetScript("OnEnter", function(self)
		local drop = self.drop
		if not drop then
			return
		end
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		if GameTooltip.SetItemByID then
			GameTooltip:SetItemByID(drop.id)
		else
			GameTooltip:SetHyperlink("item:" .. drop.id)
		end
		if drop.seen then
			GameTooltip:AddLine(string.format("You looted this %d time%s.", drop.seen, drop.seen == 1 and "" or "s"), 0.3, 1, 0.4)
		end
		GameTooltip:Show()
	end)
	button:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)
	button:SetScript("OnClick", function(self)
		local drop = self.drop
		if not drop then
			return
		end
		local _, link = ItemInfo(drop.id)
		if link and HandleModifiedItemClick then
			HandleModifiedItemClick(link)
		end
	end)
	dropButtons[index] = button
	return button
end

local function CreateListView()
	listView = CreateFrame("Frame", nil, frame)
	listView:SetAllPoints()

	local zone = Style.Dropdown(listView, 132, ZoneOptions, function()
		return filter.zone
	end, function(value)
		Journal.SetFilter("zone", value)
	end)
	zone:SetPoint("TOPLEFT", frame, "TOPLEFT", LEFT, -80)

	local level = Style.Dropdown(listView, 88, function()
		return LEVELS
	end, function()
		return filter.level
	end, function(value)
		Journal.SetFilter("level", value)
	end)
	level:SetPoint("LEFT", zone, "RIGHT", 4, 0)

	local sort = Style.Dropdown(listView, 84, function()
		return SORTS
	end, function()
		return filter.sort
	end, function(value)
		Journal.SetFilter("sort", value)
	end)
	sort:SetPoint("LEFT", level, "RIGHT", 4, 0)

	frame.dropdowns = { zone, level, sort }

	listView.empty = Style.Ink(listView:CreateFontString(nil, "OVERLAY", "GameFontHighlight"))
	listView.empty:SetPoint("TOP", frame, "TOPLEFT", LEFT + PAGE_WIDTH / 2, -170)
	listView.empty:SetWidth(PAGE_WIDTH - 20)

	listView.count = Style.Ink(listView:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"), true)
	listView.count:SetPoint("BOTTOMRIGHT", frame, "BOTTOMLEFT", LEFT + PAGE_WIDTH, 124)
end

local function CreateDetail()
	detail = CreateFrame("Frame", nil, frame)
	detail:SetAllPoints()
	detail:Hide()

	local back = Style.Button(detail, "Back", 64, 20, function()
		Style.Sound("page")
		Journal.Select(nil)
	end)
	back:SetPoint("TOPLEFT", frame, "TOPLEFT", LEFT, -80)

	-- Model in a dark well with a rank-coloured strip along the bottom.
	local box = Style.Frame("Frame", nil, detail)
	box:SetSize(120, 140)
	box:SetPoint("TOPLEFT", frame, "TOPLEFT", LEFT, -104)
	Style.Tooltip(box, 1)
	if type(box.SetBackdropColor) == "function" then
		pcall(box.SetBackdropColor, box, 0, 0, 0, 0.9)
	end
	box.rankBar = box:CreateTexture(nil, "ARTWORK")
	box.rankBar:SetTexture(Style.TEX.statusBar)
	box.rankBar:SetHeight(4)
	box.rankBar:SetPoint("BOTTOMLEFT", 5, 5)
	box.rankBar:SetPoint("BOTTOMRIGHT", -5, 5)
	detail.modelBox = box

	local model = CreateFrame("PlayerModel", nil, box)
	model:SetPoint("TOPLEFT", 5, -5)
	model:SetPoint("BOTTOMRIGHT", -5, 10)
	model:EnableMouse(true)
	model:SetScript("OnMouseDown", function(self)
		self.dragX = GetCursorPosition()
	end)
	model:SetScript("OnMouseUp", function(self)
		self.dragX = nil
	end)
	model:SetScript("OnUpdate", function(self)
		if self.dragX then
			local x = GetCursorPosition()
			self.facing = (self.facing or 0) + (x - self.dragX) * 0.02
			self:SetFacing(self.facing)
			self.dragX = x
		end
	end)
	detail.model = model

	detail.name = detail:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	detail.name:SetPoint("TOPLEFT", box, "TOPRIGHT", 10, -2)
	detail.name:SetWidth(PAGE_WIDTH - 130)
	detail.name:SetJustifyH("LEFT")

	detail.rank = Style.Ink(detail:CreateFontString(nil, "OVERLAY", "GameFontHighlight"))
	detail.rank:SetPoint("TOPLEFT", detail.name, "BOTTOMLEFT", 0, -3)
	detail.rank:SetWidth(PAGE_WIDTH - 130)
	detail.rank:SetJustifyH("LEFT")

	detail.status = detail:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	detail.status:SetShadowColor(0, 0, 0, 0)
	detail.status:SetPoint("TOPLEFT", detail.rank, "BOTTOMLEFT", 0, -5)
	detail.status:SetWidth(PAGE_WIDTH - 130)
	detail.status:SetJustifyH("LEFT")

	detail.info = Style.Ink(detail:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"))
	detail.info:SetPoint("TOPLEFT", detail.status, "BOTTOMLEFT", 0, -5)
	detail.info:SetWidth(PAGE_WIDTH - 130)
	detail.info:SetJustifyH("LEFT")
	detail.info:SetSpacing(2)

	detail.zones = Style.Ink(detail:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"))
	detail.zones:SetPoint("TOPLEFT", frame, "TOPLEFT", LEFT, -250)
	detail.zones:SetWidth(PAGE_WIDTH)
	detail.zones:SetJustifyH("LEFT")
	if detail.zones.SetMaxLines then
		detail.zones:SetMaxLines(2)
	end

	local dropsTitle = detail:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	dropsTitle:SetPoint("TOPLEFT", frame, "TOPLEFT", LEFT, -280)
	dropsTitle:SetText("Drops")
	detail.dropsNote = Style.Ink(detail:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"), true)
	detail.dropsNote:SetPoint("LEFT", dropsTitle, "RIGHT", 8, 0)

	local dropArea = CreateFrame("Frame", nil, detail)
	dropArea:SetPoint("TOPLEFT", frame, "TOPLEFT", LEFT, -296)
	dropArea:SetSize(PAGE_WIDTH, DROP_ROWS * 36)
	dropArea:EnableMouseWheel(true)
	dropArea:SetScript("OnMouseWheel", function(_, delta)
		dropOffset = dropOffset - delta * DROPS_PER_ROW
		RenderDrops()
	end)
	for i = 1, DROPS_PER_ROW * DROP_ROWS do
		CreateDropButton(i)
	end

	detail.map = Style.Button(detail, "Show on Map", 104, 20, function()
		if selected then
			ShowOnMap(selected)
		end
	end)
	detail.map:SetPoint("TOPLEFT", frame, "TOPLEFT", LEFT, -370)

	detail.way = Style.Button(detail, "Waypoint", 78, 20, function()
		if selected then
			Status.SetWaypoint(selected)
		end
	end)
	detail.way:SetPoint("LEFT", detail.map, "RIGHT", 4, 0)

	local link = Style.Button(detail, "Link", 56, 20, function()
		if selected then
			Status.LinkToChat(selected)
		end
	end)
	link:SetPoint("LEFT", detail.way, "RIGHT", 4, 0)

	detail.hide = Style.Button(detail, "Hide", 62, 20, function()
		if selected then
			Rares.SetIgnored(selected, not Rares.IsIgnored(selected))
		end
	end)
	detail.hide:SetPoint("LEFT", link, "RIGHT", 4, 0)
end

local function Create()
	frame = CreateFrame("Frame", "BetterRareSpawnsJournal", UIParent)
	frame:Hide() -- new frames start shown
	frame:SetSize(384, 512)
	frame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 16, -116)
	frame:SetFrameStrata("MEDIUM")
	frame:SetToplevel(true)
	frame:SetHitRectInsets(0, 30, 0, 70)
	Util.MakeMovable(frame, "journal")
	if UISpecialFrames then
		UISpecialFrames[#UISpecialFrames + 1] = "BetterRareSpawnsJournal" -- Escape closes it
	end

	-- The spellbook's own frame art.
	local portrait = frame:CreateTexture(nil, "BACKGROUND")
	portrait:SetTexture(Style.TEX.bookIcon)
	portrait:SetSize(58, 58)
	portrait:SetPoint("TOPLEFT", 10, -8)
	for _, part in ipairs({
		{ "TopLeft", "TOPLEFT", 256 },
		{ "TopRight", "TOPRIGHT", 128 },
		{ "BotLeft", "BOTTOMLEFT", 256 },
		{ "BotRight", "BOTTOMRIGHT", 128 },
	}) do
		local texture = frame:CreateTexture(nil, "ARTWORK")
		texture:SetTexture(Style.TEX.bookPanel .. part[1])
		texture:SetSize(part[3], 256)
		texture:SetPoint(part[2])
	end

	local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	title:SetPoint("CENTER", 6, 230)
	title:SetText("Rare Spawns")

	local close = Style.Close(frame, function()
		Journal.Toggle(false)
	end)
	close:SetPoint("CENTER", frame, "TOPRIGHT", -44, -25)

	local search, templated = Style.Template("EditBox", nil, frame, "SearchBoxTemplate")
	search:SetHeight(20)
	search:SetPoint("TOPLEFT", 84, -42)
	search:SetPoint("RIGHT", frame, "RIGHT", -50, 0)
	search:SetAutoFocus(false)
	if not templated then
		search:SetFontObject(_G.ChatFontNormal or _G.GameFontHighlight)
		Style.Tooltip(search, 0.8)
	end
	if type(search.Instructions) == "table" then
		search.Instructions:SetText("Name, zone, level or drop")
	end
	search:HookScript("OnTextChanged", function(self)
		Journal.SetSearch(self:GetText() or "")
	end)
	search:HookScript("OnEscapePressed", function(self)
		self:ClearFocus()
	end)
	search:HookScript("OnEnterPressed", function(self)
		self:ClearFocus()
	end)
	frame.search = search

	frame.prev = CreateArrow("Prev", 50)
	frame.next = CreateArrow("Next", 314)
	frame.pageText = Style.Ink(frame:CreateFontString(nil, "OVERLAY", "GameFontNormal"))
	frame.pageText:SetPoint("CENTER", frame, "BOTTOMLEFT", 182, 105)

	frame:EnableMouseWheel(true)
	frame:SetScript("OnMouseWheel", function(_, delta)
		Turn(delta > 0 and -1 or 1)
	end)

	for index, info in ipairs(TABS) do
		CreateTab(index, info)
	end

	CreateListView()
	CreateDetail()

	-- Timers on the open page keep counting; list changes are picked up at
	-- most once a second.
	local elapsed, slow = 0, 0
	frame:SetScript("OnUpdate", function(_, delta)
		elapsed = elapsed + delta
		if elapsed < 1 then
			return
		end
		slow = slow + elapsed
		elapsed = 0
		if stale or slow >= 10 then
			slow = 0
			Rebuild()
		elseif selected then
			RenderStatus()
		end
	end)
	frame:SetScript("OnShow", function()
		Style.Sound("open")
	end)
	frame:SetScript("OnHide", function()
		Style.Sound("close")
		Card.Hide()
	end)

	for _, dropdown in ipairs(frame.dropdowns) do
		dropdown.Update()
	end
end

--- Shows or hides the journal. Pass nil to toggle.
function Journal.Toggle(show)
	if not frame then
		Create()
	end
	if show == nil then
		show = not frame:IsShown()
	end
	frame:SetShown(show)
	if show then
		Rebuild()
	end
end

--- Opens the journal, on a rare's page when given one.
function Journal.Open(npcID)
	Journal.Toggle(true)
	if npcID and Rares.Get(npcID) then
		if not IndexOf(npcID) then
			-- The current filters would hide it: clear them.
			filter.tab, filter.zone, filter.level, filter.search = "all", false, "any", ""
			if type(frame.search.SetText) == "function" then
				frame.search:SetText("")
			end
			Journal.Collect()
			for _, dropdown in ipairs(frame.dropdowns) do
				dropdown.Update()
			end
		end
		Journal.Select(npcID)
	end
end

function Journal.IsShown()
	return frame ~= nil and frame:IsShown()
end

function BetterRareSpawns_ToggleJournal()
	Journal.Toggle()
end

-------------------------------------------------------------------------------
-- Staying current
-------------------------------------------------------------------------------

ns.Listen("OPEN_JOURNAL", function(npcID)
	Journal.Open(npcID)
end)
ns.Listen("RARES_CHANGED", function()
	stale = true
end)
ns.Listen("RARE_UPDATED", function()
	stale = true
end)

-- Item names and qualities arrive late: re-sort the open drop list once.
local itemTimer
ns.OnEvent("GET_ITEM_INFO_RECEIVED", function()
	if itemTimer or not selected or not Journal.IsShown() then
		return
	end
	itemTimer = C_Timer.NewTimer(0.5, function()
		itemTimer = nil
		if selected and Journal.IsShown() then
			SortDrops()
			RenderDrops()
		end
	end)
end)
