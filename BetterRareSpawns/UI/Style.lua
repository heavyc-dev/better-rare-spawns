-- Shared look. Everything here is built from the game's own art and frame
-- templates (tooltip borders, dialog boxes, panel buttons, the spellbook
-- frame), referenced by path. Nothing is shipped with the addon.
--
-- Templates are created through pcall with a plain fallback, so a client that
-- lacks one still gets a working (if plainer) widget.
local ADDON, ns = ...

local Style = {}
ns.Style = Style

local Util = ns.Util

Style.TEX = {
	tooltipBg = "Interface\\Tooltips\\UI-Tooltip-Background",
	tooltipBorder = "Interface\\Tooltips\\UI-Tooltip-Border",
	dialogBg = "Interface\\DialogFrame\\UI-DialogBox-Background",
	dialogBorder = "Interface\\DialogFrame\\UI-DialogBox-Border",
	dialogHeader = "Interface\\DialogFrame\\UI-DialogBox-Header",
	statusBar = "Interface\\TargetingFrame\\UI-StatusBar",
	rowHighlight = "Interface\\QuestFrame\\UI-QuestTitleHighlight",
	skull = "Interface\\TargetingFrame\\UI-TargetingFrame-Skull",
	ring = "Interface\\Minimap\\MiniMap-TrackingBorder",
	ringHighlight = "Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight",
	circleMask = "Interface\\CharacterFrame\\TempPortraitAlphaMask",
	slot = "Interface\\Buttons\\UI-Quickslot2",
	slotPushed = "Interface\\Buttons\\UI-Quickslot-Depress",
	squareHighlight = "Interface\\Buttons\\ButtonHilight-Square",
	checkHighlight = "Interface\\Buttons\\CheckButtonHilight",
	mouseHighlight = "Interface\\Buttons\\UI-Common-MouseHilight",
	pageArrow = "Interface\\Buttons\\UI-SpellbookIcon-", -- .. "PrevPage-Up" etc.
	bookPanel = "Interface\\Spellbook\\UI-SpellbookPanel-", -- .. "TopLeft" etc.
	bookIcon = "Interface\\Spellbook\\Spellbook-Icon",
	bookTab = "Interface\\SpellBook\\SpellBook-SkillLineTab",
	questionMark = "Interface\\Icons\\INV_Misc_QuestionMark",
	star = "Interface\\COMMON\\FavoritesIcon",
	check = "Interface\\Buttons\\UI-CheckBox-Check",
	questAvailable = "Interface\\GossipFrame\\AvailableQuestIcon",
}

-- Text colours for writing on the book's parchment, where the usual bright
-- state colours would wash out.
Style.INK = { 0.18, 0.12, 0.06 }
Style.INK_FAINT = { 0.38, 0.28, 0.16 }
Style.INK_STATE = {
	up = { 0.05, 0.42, 0.10 },
	overdue = { 0.70, 0.28, 0.00 },
	window = { 0.55, 0.38, 0.00 },
	seen = { 0.10, 0.28, 0.58 },
	dead = { 0.36, 0.30, 0.24 },
	killed = { 0.36, 0.30, 0.24 },
	unknown = { 0.36, 0.30, 0.24 },
}

-------------------------------------------------------------------------------
-- Frames and backdrops
-------------------------------------------------------------------------------

--- CreateFrame with a template that may not exist: returns frame, usedTemplate.
function Style.Template(kind, name, parent, template)
	if template then
		local ok, frame = pcall(CreateFrame, kind, name, parent, template)
		if ok and frame then
			return frame, true
		end
	end
	local ok, frame = pcall(CreateFrame, kind, name, parent)
	if not ok or not frame then
		frame = CreateFrame("Button", name, parent) -- the frame type itself is unknown
	end
	return frame, false
end

--- A frame that can carry a backdrop (plus an optional extra template).
function Style.Frame(kind, name, parent, template)
	local frame, ok = Style.Template(kind, name, parent, template and (template .. ",BackdropTemplate") or "BackdropTemplate")
	if not ok and template then
		frame = Style.Template(kind, name, parent, template)
	end
	return frame
end

local function Backdrop(frame, definition)
	if type(frame.SetBackdrop) ~= "function" then
		return false
	end
	return (pcall(frame.SetBackdrop, frame, definition))
end

--- The game tooltip's look: dark blue-black fill, thin rounded border.
function Style.Tooltip(frame, alpha)
	local ok = Backdrop(frame, {
		bgFile = Style.TEX.tooltipBg,
		edgeFile = Style.TEX.tooltipBorder,
		tile = true,
		tileSize = 16,
		edgeSize = 16,
		insets = { left = 4, right = 4, top = 4, bottom = 4 },
	})
	if ok then
		frame:SetBackdropColor(0.09, 0.09, 0.19, alpha or 0.95)
		frame:SetBackdropBorderColor(1, 1, 1, 1)
	else
		Util.Skin(frame, alpha)
	end
end

function Style.BorderColor(frame, r, g, b)
	if type(frame.SetBackdropBorderColor) == "function" then
		pcall(frame.SetBackdropBorderColor, frame, r, g, b, 1)
	end
end

--- The classic dialog box: thick gold-trimmed border and a title plate.
function Style.Dialog(frame, title)
	local ok = Backdrop(frame, {
		bgFile = Style.TEX.dialogBg,
		edgeFile = Style.TEX.dialogBorder,
		tile = true,
		tileSize = 32,
		edgeSize = 32,
		insets = { left = 11, right = 12, top = 12, bottom = 11 },
	})
	if not ok then
		Util.Skin(frame, 0.96)
	end
	if title then
		local header = frame:CreateTexture(nil, "ARTWORK")
		header:SetTexture(Style.TEX.dialogHeader)
		header:SetSize(320, 64)
		header:SetPoint("TOP", 0, 12)
		local text = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		text:SetPoint("TOP", header, "TOP", 0, -14)
		text:SetText(title)
		frame.titleText = text
	end
end

-------------------------------------------------------------------------------
-- Widgets
-------------------------------------------------------------------------------

--- The red panel button.
function Style.Button(parent, label, width, height, onClick)
	local button, templated = Style.Template("Button", nil, parent, "UIPanelButtonTemplate")
	button:SetSize(width or 100, height or 22)
	if templated then
		button:SetText(label)
	else
		Util.Skin(button, 0.6)
		local text = button:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		text:SetPoint("CENTER")
		text:SetText(label)
		button.label = text
		function button:SetText(value)
			text:SetText(value)
		end
	end
	if onClick then
		button:SetScript("OnClick", onClick)
	end
	return button
end

--- The round red X.
function Style.Close(parent, onClick, size)
	local button, templated = Style.Template("Button", nil, parent, "UIPanelCloseButton")
	if size then
		button:SetSize(size, size)
	elseif not templated then
		button:SetSize(24, 24)
	end
	if not templated then
		local text = button:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
		text:SetPoint("CENTER")
		text:SetText("x")
	end
	button:SetScript("OnClick", onClick)
	return button
end

--- A check box with a label to its right. `button.label` is the font string.
function Style.Check(parent, label)
	local button, templated = Style.Template("CheckButton", nil, parent, "UICheckButtonTemplate")
	button:SetSize(22, 22)
	local text = button.Text
	if type(text) ~= "table" then
		text = button.text
	end
	if type(text) ~= "table" then
		text = button:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		text:SetPoint("LEFT", button, "RIGHT", 2, 0)
	end
	if text.SetFontObject and _G.GameFontHighlightSmall then
		text:SetFontObject(_G.GameFontHighlightSmall)
	end
	text:SetText(label)
	button.label = text
	if not templated then
		local box = button:CreateTexture(nil, "BACKGROUND")
		box:SetAllPoints()
		box:SetColorTexture(1, 1, 1, 0.15)
		local tick = button:CreateTexture(nil, "OVERLAY")
		tick:SetPoint("TOPLEFT", 5, -5)
		tick:SetPoint("BOTTOMRIGHT", -5, 5)
		tick:SetColorTexture(1, 0.82, 0, 1)
		function button:SetChecked(checked)
			tick:SetShown(checked and true or false)
		end
	end
	-- Let a click on the label count too.
	if button.SetHitRectInsets then
		button:SetHitRectInsets(0, -180, 0, 0)
	end
	return button
end

--- The golden highlight bar used by quest and trainer lists.
function Style.RowHighlight(button)
	local texture = button:CreateTexture(nil, "HIGHLIGHT")
	texture:SetTexture(Style.TEX.rowHighlight)
	texture:SetBlendMode("ADD")
	texture:SetAllPoints()
	texture:SetVertexColor(1, 0.82, 0, 0.6)
	return texture
end

--- A white disc (a plain colour clipped by the portrait mask), for tinting.
function Style.Disc(parent, layer, inset)
	local texture = parent:CreateTexture(nil, layer or "ARTWORK")
	texture:SetPoint("TOPLEFT", inset or 0, -(inset or 0))
	texture:SetPoint("BOTTOMRIGHT", -(inset or 0), inset or 0)
	texture:SetColorTexture(1, 1, 1, 1)
	if parent.CreateMaskTexture then
		local ok, mask = pcall(parent.CreateMaskTexture, parent)
		if ok and mask then
			mask:SetTexture(Style.TEX.circleMask, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
			mask:SetAllPoints(texture)
			texture:AddMaskTexture(mask)
		end
	end
	return texture
end

--- Dresses `frame` as a minimap-style round button: tinted disc, icon and the
-- game's ring border. Sets frame.fill, frame.icon, frame.ring.
function Style.Medallion(frame, size, icon)
	frame:SetSize(size, size)
	local unit = size / 31 -- the ring art is drawn for a 31 px button

	frame.fill = Style.Disc(frame, "BACKGROUND", unit * 4.5)

	frame.icon = frame:CreateTexture(nil, "ARTWORK")
	frame.icon:SetTexture(icon or Style.TEX.skull)
	frame.icon:SetPoint("CENTER")
	frame.icon:SetSize(unit * 17, unit * 17)

	-- The ring sits in the top-left 31/53 of its texture, and its opening is
	-- not centred in that corner: it lies 1.5 px right of and 0.5 px above the
	-- middle. Shifting the texture back puts the opening on the frame's centre,
	-- so the disc and icon sit in the middle of the ring.
	frame.ring = frame:CreateTexture(nil, "OVERLAY")
	frame.ring:SetTexture(Style.TEX.ring)
	frame.ring:SetSize(unit * 53, unit * 53)
	frame.ring:SetPoint("TOPLEFT", -unit * 1.5, -unit * 0.5)
	return frame
end

--- Silver ring for rares, gold for rare elites (as on the target frame).
function Style.MedallionRank(frame, rank)
	if frame.ring.SetDesaturated then
		frame.ring:SetDesaturated(rank ~= "rareelite")
	end
end

--- An item slot: icon inside the action-button frame art.
function Style.ItemButton(parent, size)
	local button = CreateFrame("Button", nil, parent)
	button:SetSize(size, size)

	button.icon = button:CreateTexture(nil, "ARTWORK")
	button.icon:SetAllPoints()
	button.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

	local frame = button:CreateTexture(nil, "OVERLAY")
	frame:SetTexture(Style.TEX.slot)
	frame:SetSize(size * 64 / 37, size * 64 / 37)
	frame:SetPoint("CENTER", 0, -1)

	button.count = button:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
	button.count:SetPoint("BOTTOMRIGHT", -1, 2)

	button:SetHighlightTexture(Style.TEX.squareHighlight, "ADD")
	return button
end

--- Body text written straight on parchment: dark ink, no drop shadow.
function Style.Ink(fontString, faint)
	local color = faint and Style.INK_FAINT or Style.INK
	fontString:SetTextColor(color[1], color[2], color[3])
	fontString:SetShadowColor(0, 0, 0, 0)
	return fontString
end

-------------------------------------------------------------------------------
-- Dropdown
-------------------------------------------------------------------------------

--- A dropdown over a list of { value = ..., text = ... } options.
--   getOptions() -> list      current() -> value      choose(value)
-- Uses the game's dropdown when it has one, else a button that steps through
-- the options (right-click steps back).
function Style.Dropdown(parent, width, getOptions, current, choose)
	local dropdown, templated = Style.Template("DropdownButton", nil, parent, "WowStyle1DropdownTemplate")
	if templated and type(dropdown.SetupMenu) == "function" then
		dropdown:SetWidth(width)
		dropdown:SetupMenu(function(_, root)
			local options = getOptions()
			if #options > 14 and root.SetScrollMode then
				root:SetScrollMode(300)
			end
			for _, option in ipairs(options) do
				root:CreateRadio(option.text, function()
					return current() == option.value
				end, function()
					choose(option.value)
				end)
			end
		end)
		function dropdown.Update()
			if dropdown.GenerateMenu then
				pcall(dropdown.GenerateMenu, dropdown)
			end
		end
		return dropdown
	end

	if templated then
		dropdown:Hide()
	end
	local button = Style.Button(parent, "", width, 22)
	button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	function button.Update()
		local value = current()
		for _, option in ipairs(getOptions()) do
			if option.value == value then
				button:SetText(option.text)
				return
			end
		end
		button:SetText("")
	end
	button:SetScript("OnClick", function(_, mouseButton)
		local options = getOptions()
		local index = 0
		local value = current()
		for i, option in ipairs(options) do
			if option.value == value then
				index = i
				break
			end
		end
		local step = mouseButton == "RightButton" and -1 or 1
		local chosen = options[(index - 1 + step) % #options + 1]
		if chosen then
			choose(chosen.value)
		end
	end)
	return button
end

-------------------------------------------------------------------------------
-- Sounds
-------------------------------------------------------------------------------

local SOUNDS = {
	open = { "IG_SPELLBOOK_OPEN", 829 },
	close = { "IG_SPELLBOOK_CLOSE", 830 },
	page = { "IG_ABILITY_PAGE_TURN", 836 },
	click = { "IG_MAINMENU_OPTION_CHECKBOX_ON", 856 },
}

function Style.Sound(which)
	local sound = SOUNDS[which]
	if sound and PlaySound then
		pcall(PlaySound, (SOUNDKIT and SOUNDKIT[sound[1]]) or sound[2])
	end
end
