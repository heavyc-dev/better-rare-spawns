-- Hover card: the info panel shown next to a map or minimap pin.
--
-- Design rules (each one answers a way map hovers usually go wrong):
--   * instant: built from cached data only, no item/tooltip scanning on hover
--   * never under the cursor: sits beside the pin with a gap and ignores the
--     mouse, so it cannot flicker or get "stuck"
--   * one level: no nested tooltips, no clickable cells
--   * stacked pins show as one card listing every rare under the cursor
--   * live: timers keep counting while the card is open
local ADDON, ns = ...

local Card = {}
ns.Card = Card

local Util, Rares, Respawn, Status, Style = ns.Util, ns.Rares, ns.Respawn, ns.Status, ns.Style
local Hunt = ns.Hunt

local WIDTH = 270
local PAD = 10
local MAX_BLOCKS = 5

local frame
local blocks = {}
local current -- { anchor = frame, items = { { id, map, x, y }, ... } }

local function Hex(r, g, b)
	return string.format("|cff%02x%02x%02x", r * 255, g * 255, b * 255)
end
local GREY = "|cff9a9a9a"
local WHITE = "|cffffffff"

local RANK_LABEL = { rare = "Rare", rareelite = "Rare Elite" }

local function CreateBlock(index)
	local block = CreateFrame("Frame", nil, frame)
	block:SetWidth(WIDTH - PAD * 2)

	block.name = block:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	block.name:SetPoint("TOPLEFT")
	block.name:SetJustifyH("LEFT")
	block.name:SetWordWrap(false)

	block.level = block:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	block.level:SetPoint("TOPRIGHT")
	block.level:SetJustifyH("RIGHT")
	block.name:SetPoint("RIGHT", block.level, "LEFT", -6, 0)

	block.status = block:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	block.status:SetPoint("TOPLEFT", block.name, "BOTTOMLEFT", 0, -3)
	block.status:SetPoint("RIGHT")
	block.status:SetJustifyH("LEFT")
	block.status:SetWordWrap(false)

	-- Progress through the spawn window.
	block.barBack = block:CreateTexture(nil, "ARTWORK")
	block.barBack:SetColorTexture(0, 0, 0, 0.6)
	block.barBack:SetHeight(5)
	block.barBack:SetPoint("TOPLEFT", block.status, "BOTTOMLEFT", 0, -3)
	block.barBack:SetPoint("RIGHT")
	block.bar = block:CreateTexture(nil, "OVERLAY")
	block.bar:SetHeight(5)
	block.bar:SetTexture(Style.TEX.statusBar)
	block.bar:SetPoint("TOPLEFT", block.barBack, "TOPLEFT")

	block.body = block:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	block.body:SetJustifyH("LEFT")
	block.body:SetWidth(WIDTH - PAD * 2)
	block.body:SetSpacing(2)

	block.divider = block:CreateTexture(nil, "ARTWORK")
	block.divider:SetColorTexture(1, 1, 1, 0.10)
	block.divider:SetHeight(1)
	block.divider:SetPoint("BOTTOMLEFT", 0, -5)
	block.divider:SetPoint("BOTTOMRIGHT", 0, -5)

	blocks[index] = block
	return block
end

local function EnsureFrame()
	if frame then
		return
	end
	frame = Style.Frame("Frame", "BetterRareSpawnsCard", UIParent)
	frame:SetFrameStrata("TOOLTIP")
	frame:SetWidth(WIDTH)
	frame:SetClampedToScreen(true)
	frame:EnableMouse(false) -- the cursor passes straight through
	frame:Hide()
	Style.Tooltip(frame)

	frame.hint = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	frame.hint:SetPoint("BOTTOMLEFT", PAD, PAD - 2)
	frame.hint:SetPoint("RIGHT", -PAD, 0)
	frame.hint:SetJustifyH("LEFT")

	local elapsed = 0
	frame:SetScript("OnUpdate", function(_, delta)
		elapsed = elapsed + delta
		if elapsed >= 1 then
			elapsed = 0
			Card.Refresh()
		end
	end)
end

--- Names of up to three items this account has seen the rare drop.
local function LootLine(npcID)
	local loot = ns.db.loot[npcID]
	if not loot then
		return nil
	end
	local names, extra = {}, 0
	local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
	for itemID in pairs(loot) do
		if #names < 3 then
			local name, link = getInfo(itemID) -- cached data only; never waits
			names[#names + 1] = link or name or ("item " .. itemID)
		else
			extra = extra + 1
		end
	end
	if #names == 0 then
		return nil
	end
	local text = table.concat(names, ", ")
	if extra > 0 then
		text = text .. " +" .. extra
	end
	return text
end

local function FillBlock(block, item)
	local npcID = item.id
	local entry = Rares.Get(npcID)

	local rankColor = Status.RANK_COLORS[entry and entry.rank or "rare"] or Status.RANK_COLORS.rare
	block.name:SetText(Hunt.IsWanted(npcID) and ("|T" .. Style.TEX.star .. ":12|t " .. Rares.Name(npcID)) or Rares.Name(npcID))
	block.name:SetTextColor(rankColor[1], rankColor[2], rankColor[3])

	local levelText = ""
	if entry then
		if entry.level then
			levelText = "Lv " .. (Rares.LevelText(npcID) or entry.level) .. " "
		end
		levelText = levelText .. (RANK_LABEL[entry.rank] or "Rare")
	end
	block.level:SetText(levelText)

	local text, r, g, b, state, info = Status.Describe(npcID)
	block.status:SetText(text)
	block.status:SetTextColor(r, g, b)

	local height = block.name:GetStringHeight() + 3 + block.status:GetStringHeight()

	local showBar = state == "window" and info.progress
	block.bar:SetShown(showBar and true or false)
	block.barBack:SetShown(showBar and true or false)
	block.body:ClearAllPoints()
	if showBar then
		block.bar:SetWidth(math.max(1, (WIDTH - PAD * 2) * math.min(1, info.progress)))
		block.bar:SetVertexColor(r, g, b)
		block.body:SetPoint("TOPLEFT", block.barBack, "BOTTOMLEFT", 0, -5)
		height = height + 13
	else
		block.body:SetPoint("TOPLEFT", block.status, "BOTTOMLEFT", 0, -4)
		height = height + 4
	end

	local lines = {}
	local window = Status.WindowText(npcID)
	if window then
		lines[#lines + 1] = GREY .. window .. "|r"
	end

	local rec = Respawn.GetRecord(npcID)
	local seen = rec and rec.seen
	if seen and seen.t and state ~= "up" and state ~= "seen" then
		lines[#lines + 1] = GREY .. "Last seen alive " .. Util.Duration(GetServerTime() - seen.t) .. " ago|r"
	end
	if seen and seen.by then
		lines[#lines + 1] = GREY .. "Reported by " .. WHITE .. seen.by .. "|r"
	end
	local kills = Hunt.Kills(npcID)
	if kills > 0 then
		lines[#lines + 1] = GREY .. "Killed by you: " .. WHITE .. kills .. "|r"
	elseif rec and (rec.kills or 0) > 0 then
		lines[#lines + 1] = GREY .. "Deaths witnessed: " .. WHITE .. rec.kills .. "|r"
	end
	if entry and entry.dungeon then
		lines[#lines + 1] = GREY .. "Inside " .. entry.dungeon .. "|r"
	end

	local where = {}
	if item.map and item.x then
		where[#where + 1] = string.format("%.1f, %.1f", item.x, item.y)
		local distance = Util.DistanceFromPlayer(item.map, item.x, item.y)
		if distance then
			where[#where + 1] = string.format("%d yd", distance)
		end
	end
	local points = entry and item.map and entry.spawns[item.map]
	if points and #points > 2 then
		where[#where + 1] = (#points / 2) .. " spawn points"
	end
	if #where > 0 then
		lines[#lines + 1] = GREY .. table.concat(where, "  |  ") .. "|r"
	end

	local loot = LootLine(npcID)
	if loot then
		lines[#lines + 1] = GREY .. "Dropped: |r" .. loot
	else
		local known = #Rares.Drops(npcID)
		if known > 0 then
			lines[#lines + 1] = GREY .. known .. " known drops - Ctrl-click for the journal|r"
		end
	end
	if entry and entry.type then
		lines[#lines + 1] = GREY .. entry.type .. "|r"
	end

	block.body:SetText(table.concat(lines, "\n"))
	if #lines > 0 then
		height = height + block.body:GetStringHeight()
	end
	block:SetHeight(height)
	return height
end

local function Layout()
	local items = current.items
	local shown = math.min(#items, MAX_BLOCKS)
	local y = -PAD

	for i = 1, shown do
		local block = blocks[i] or CreateBlock(i)
		local height = FillBlock(block, items[i])
		block:ClearAllPoints()
		block:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, y)
		block.divider:SetShown(i < shown)
		block:Show()
		y = y - height - 11
	end
	for i = shown + 1, #blocks do
		blocks[i]:Hide()
	end

	local hint = current.hint or "Click: waypoint   Ctrl: journal\nShift: link   Alt: hide"
	if #items > shown then
		hint = "+" .. (#items - shown) .. " more here - zoom in\n" .. hint
	end
	frame.hint:SetText(hint)
	frame:SetHeight(-y + frame.hint:GetStringHeight() + PAD - 4)
end

local function Anchor(anchor)
	local screenWidth, screenHeight = UIParent:GetWidth(), UIParent:GetHeight()
	local scale = anchor:GetEffectiveScale() / UIParent:GetEffectiveScale()
	local cx, cy = anchor:GetCenter()
	cx, cy = (cx or 0) * scale, (cy or 0) * scale

	-- Open toward the roomier side, with a gap so the pin stays visible.
	local right = cx < screenWidth * 0.6
	local down = cy > screenHeight * 0.45
	local point = (down and "TOP" or "BOTTOM") .. (right and "LEFT" or "RIGHT")
	local relative = (down and "TOP" or "BOTTOM") .. (right and "RIGHT" or "LEFT")

	frame:ClearAllPoints()
	frame:SetPoint(point, anchor, relative, right and 12 or -12, 0)
end

--- Shows the card beside `anchor` for a list of { id, map, x, y } items.
function Card.Show(anchor, items, hint)
	if not items or #items == 0 then
		return Card.Hide()
	end
	EnsureFrame()
	current = { anchor = anchor, items = items, hint = hint }
	Layout()
	Anchor(anchor)
	frame:Show()
end

function Card.Refresh()
	if frame and frame:IsShown() and current then
		Layout()
	end
end

--- Hides the card, but only if `anchor` (when given) is the one that opened it.
function Card.Hide(anchor)
	if frame and (not anchor or (current and current.anchor == anchor)) then
		frame:Hide()
		current = nil
	end
end

function Card.IsShownFor(anchor)
	return frame and frame:IsShown() and current and current.anchor == anchor
end
