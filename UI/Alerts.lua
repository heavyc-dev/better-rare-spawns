-- Alerts: sound, chat line and a clickable card that targets the rare.
--
-- The card is a secure button (targeting needs one), so it can only be shown,
-- hidden or re-aimed outside combat. Sound and chat always fire immediately;
-- the card follows as soon as combat ends.
local ADDON, ns = ...

local Alerts = {}
ns.Alerts = Alerts

local Util, Rares, Status, Style, Hunt = ns.Util, ns.Rares, ns.Status, ns.Style, ns.Hunt

local SOURCE_TEXT = {
	nameplate = "Nameplate",
	mouseover = "Mouseover",
	target = "Targeted",
	vignette = "Minimap",
	yell = "Heard",
	report = "Reported",
	scan = "Scan",
	test = "Test",
}

local card
local lastAlert = {} -- [npcID] = GetTime()
local shownID
local hideTimer

local function Settings()
	return ns.db.settings.alerts
end

-------------------------------------------------------------------------------
-- Card
-------------------------------------------------------------------------------

local function CreateCard()
	card = Style.Frame("Button", "BetterRareSpawnsAlert", UIParent, "SecureActionButtonTemplate")
	card:SetSize(330, 72)
	card:SetPoint("TOP", UIParent, "TOP", 0, -140)
	card:SetFrameStrata("HIGH")
	card:RegisterForClicks("AnyUp", "AnyDown")
	card:SetAttribute("type1", "macro")
	card:Hide()
	Style.Tooltip(card, 0.95)

	card.model = CreateFrame("PlayerModel", nil, card)
	card.model:SetSize(58, 58)
	card.model:SetPoint("LEFT", 8, 0)

	card.name = card:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	card.name:SetPoint("TOPLEFT", card.model, "TOPRIGHT", 8, -2)
	card.name:SetPoint("RIGHT", -26, 0)
	card.name:SetJustifyH("LEFT")
	card.name:SetWordWrap(false)

	card.where = card:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	card.where:SetPoint("TOPLEFT", card.name, "BOTTOMLEFT", 0, -3)
	card.where:SetPoint("RIGHT", -8, 0)
	card.where:SetJustifyH("LEFT")
	card.where:SetWordWrap(false)

	card.hint = card:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	card.hint:SetPoint("BOTTOMLEFT", card.model, "BOTTOMRIGHT", 8, 2)
	card.hint:SetText("Click to target")

	local close = Style.Close(card, function()
		Alerts.Dismiss()
	end, 24)
	close:SetPoint("TOPRIGHT", 0, 0)

	local way = Style.Button(card, "Waypoint", 74, 18, function()
		if shownID then
			Status.SetWaypoint(shownID)
		end
	end)
	way:SetPoint("BOTTOMRIGHT", -8, 8)

	local tell = Style.Button(card, "Announce", 74, 18)
	tell:SetPoint("RIGHT", way, "LEFT", -4, 0)
	tell:SetScript("OnClick", function()
		if shownID then
			local channel = Hunt.Announce(shownID, IsShiftKeyDown() and "general" or nil)
			if channel then
				ns.Print("Announced to " .. strlower(channel) .. ".")
			end
		end
	end)
	tell:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
		GameTooltip:SetText("Announce")
		GameTooltip:AddLine("Click: tell your group, or your guild when not grouped", 1, 1, 1)
		GameTooltip:AddLine("Shift-click: say it in General", 1, 1, 1)
		GameTooltip:Show()
	end)
	tell:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)

	card:SetScript("PostClick", function(_, button, down)
		if button == "RightButton" and not down then
			Alerts.Dismiss()
		end
	end)

	Util.MakeMovable(card, "alert", function()
		return InCombatLockdown()
	end)
end

--- Hides the card (after combat when necessary).
function Alerts.Dismiss()
	shownID = nil
	if hideTimer then
		hideTimer:Cancel()
		hideTimer = nil
	end
	ns.OutOfCombat("alert", function()
		if card then
			card:Hide()
		end
	end)
end

local function ShowCard(npcID, info)
	shownID = npcID
	ns.OutOfCombat("alert", function()
		if shownID ~= npcID then
			return
		end
		if not card then
			CreateCard()
		end

		local name = info.name or Rares.Name(npcID)
		-- /targetexact needs the name as this client spells it. A name from a
		-- unit here is; a name in someone else's report may not be.
		local targetName = (not info.by and info.name) or Rares.LocalName(npcID)
		card:SetAttribute("macrotext", targetName and ("/cleartarget\n/targetexact " .. targetName) or "")

		local entry = Rares.Get(npcID)
		local color = Status.RANK_COLORS[entry and entry.rank or "rare"] or Status.RANK_COLORS.rare
		local wanted = Hunt.IsWanted(npcID)
		card.name:SetText(wanted and ("|T" .. Style.TEX.star .. ":14|t " .. name) or name)
		card.name:SetTextColor(color[1], color[2], color[3])
		Style.BorderColor(card, color[1], color[2], color[3])

		local parts = { SOURCE_TEXT[info.src] or "Seen" }
		if info.by then
			parts[1] = "Reported by " .. info.by
		end
		if info.map and info.x then
			parts[#parts + 1] = string.format("%s %.1f, %.1f", Util.MapName(info.map), info.x, info.y)
		end
		card.where:SetText(table.concat(parts, "  |  "))

		card.model:ClearModel()
		-- The card may have waited for combat to end: by then the unit token
		-- can point at another creature.
		local unit = info.unit
		if unit and info.guid and ns.Clean(UnitGUID(unit)) ~= info.guid then
			unit = nil
		end
		if unit and ns.Clean(UnitExists(unit)) then

			pcall(card.model.SetUnit, card.model, unit)
		else
			pcall(card.model.SetCreature, card.model, npcID)
		end

		card:Show()

		if hideTimer then
			hideTimer:Cancel()
		end
		hideTimer = C_Timer.NewTimer(Settings().duration * (wanted and 2 or 1), function()
			hideTimer = nil
			if shownID == npcID then
				Alerts.Dismiss()
			end
		end)
	end)
end

-------------------------------------------------------------------------------
-- Raising an alert
-------------------------------------------------------------------------------

function Alerts.Raise(npcID, info)
	local settings = Settings()
	if not settings.enabled then
		return false
	end
	if info.by and not settings.reports then
		return false
	end
	if info.src ~= "test" and not settings.instances and IsInInstance() then
		return false
	end

	-- One alert per spawn: repeat only for a fresh spawn or after the cooldown.
	local now = GetTime()
	local last = lastAlert[npcID]
	if last and not info.newSpawn and (now - last) < settings.cooldown then
		return false
	end
	lastAlert[npcID] = now

	local name = info.name or Rares.Name(npcID)

	local wanted = settings.wanted and Hunt.IsWanted(npcID)
	if settings.sound then
		local kit = (SOUNDKIT and SOUNDKIT.RAID_WARNING) or 8959
		pcall(PlaySound, kit, "Master")
		if wanted then
			-- A second, different sound a moment later: this is one you are after.
			C_Timer.After(0.6, function()
				pcall(PlaySound, (SOUNDKIT and SOUNDKIT.ALARM_CLOCK_WARNING_3) or 12889, "Master")
			end)
		end
	end
	if wanted then
		local text = "WANTED: " .. name
		if RaidNotice_AddMessage and RaidWarningFrame and ChatTypeInfo and ChatTypeInfo.RAID_WARNING then
			pcall(RaidNotice_AddMessage, RaidWarningFrame, text, ChatTypeInfo.RAID_WARNING)
		elseif UIErrorsFrame then
			UIErrorsFrame:AddMessage(text, 1, 0.82, 0.29)
		end
	end
	if settings.flash and FlashClientIcon then
		FlashClientIcon()
	end
	if settings.chat then
		local line = "|cffffd24a" .. name .. "|r"
		if info.by then
			line = line .. " reported by " .. info.by
		else
			line = line .. " spotted (" .. strlower(SOURCE_TEXT[info.src] or "seen") .. ")"
		end
		if info.map and info.x then
			line = line .. string.format(" - %s %.1f, %.1f", Util.MapName(info.map), info.x, info.y)
		end
		ns.Print(line)
	end
	if InCombatLockdown() and UIErrorsFrame then
		-- The card has to wait for combat to end; say so on screen now.
		UIErrorsFrame:AddMessage("Rare: " .. name, 1, 0.82, 0.29)
	end

	ShowCard(npcID, info)
	return true
end

ns.Listen("RARE_SEEN", function(npcID, info)
	Alerts.Raise(npcID, info)
end)

-- The rare died: the card has nothing left to target.
ns.Listen("RARE_DIED", function(npcID)
	if shownID == npcID then
		Alerts.Dismiss()
	end
end)

function Alerts.Test()
	local mapID, x, y = Util.PlayerPosition()
	local npcID = next(Rares.All()) or 0
	lastAlert[npcID] = nil
	Alerts.Raise(npcID, { src = "test", name = Rares.Name(npcID), map = mapID, x = x, y = y, newSpawn = true })
end

-------------------------------------------------------------------------------
-- Optional raid marker on the targeted rare
-------------------------------------------------------------------------------

ns.OnEvent("PLAYER_TARGET_CHANGED", function()
	if not Settings().mark then
		return
	end
	local npcID = Util.ParseGUID(UnitGUID("target"))
	if not npcID or not Rares.Get(npcID) or ns.Clean(UnitIsDead("target")) ~= false then
		return
	end
	if GetRaidTargetIndex and not ns.Clean(GetRaidTargetIndex("target")) then
		pcall(SetRaidTarget, "target", 8)
	end
end)
