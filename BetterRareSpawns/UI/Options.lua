-- Options window. Built from plain frames so it does not depend on any
-- particular settings framework of the client.
local ADDON, ns = ...

local Options = {}
ns.Options = Options

local Util = ns.Util

local frame

-- { section, key, label }            -> checkbox
-- { section, key, label, values, fmt } -> click to cycle through values
local LAYOUT = {
	{
		title = "Alerts",
		{ "alerts", "enabled", "Alert when a rare is found" },
		{ "alerts", "sound", "Play a sound" },
		{ "alerts", "flash", "Flash the game icon in the taskbar" },
		{ "alerts", "chat", "Print a chat line" },
		{ "alerts", "reports", "Alert on reports from guild / group" },
		{ "alerts", "instances", "Alert inside dungeons and raids" },
		{ "alerts", "mark", "Put a skull marker on a targeted rare" },
		{ "alerts", "duration", "Alert stays for", { 15, 30, 45, 90 }, "%ds" },
		{ "alerts", "cooldown", "Same rare alerts again after", { 60, 300, 900, 1800 }, "%ds" },
	},
	{
		title = "Detection",
		{ "detect", "nameplate", "Nameplates" },
		{ "detect", "mouseover", "Mouseover" },
		{ "detect", "target", "Target (and the scan key)" },
		{ "detect", "vignette", "Minimap vignettes" },
		{ "detect", "yell", "Monster yells and emotes" },
		{ "detect", "learn", "Learn rares that are not known yet" },
		{ "scan", "enabled", "Scan key targets nearby rares" },
		{ "scan", "range", "Scan key range", { 100, 150, 250, 400 }, "%d yd" },
	},
	{
		title = "Map",
		{ "map", "enabled", "Show pins on the world map" },
		{ "map", "continent", "Show active rares on continent maps" },
		{ "map", "labels", "Show names under pins" },
		{ "map", "scale", "Pin size", { 0.8, 1.0, 1.25, 1.5 }, "%.2fx" },
		{ "map", "minLevel", "Hide rares below level", { 0, 10, 20, 30, 40, 50 }, "%d" },
		{ "minimap", "enabled", "Show pins on the minimap" },
		{ "minimap", "scale", "Minimap pin size", { 0.8, 1.0, 1.25, 1.5 }, "%.2fx" },
	},
	{
		title = "Sharing and list",
		{ "share", "guild", "Share sightings with my guild" },
		{ "share", "group", "Share sightings with my group" },
		{ "share", "receive", "Use what others share" },
		{ "tracker", "activeOnly", "List: only rares with a timer or sighting" },
		{ "tracker", "locked", "List: lock position" },
		{ "tracker", "scale", "List size", { 0.8, 1.0, 1.2, 1.4 }, "%.1fx" },
	},
}

local widgets = {}

local function Changed()
	ns.Fire("SETTINGS_CHANGED")
end

local function CreateCheck(parent, section, key, label)
	local button = CreateFrame("Button", nil, parent)
	button:SetSize(250, 20)

	local box = button:CreateTexture(nil, "ARTWORK")
	box:SetSize(14, 14)
	box:SetPoint("LEFT", 0, 0)
	box:SetColorTexture(1, 1, 1, 0.15)

	local tick = button:CreateTexture(nil, "OVERLAY")
	tick:SetSize(8, 8)
	tick:SetPoint("CENTER", box, "CENTER")
	tick:SetColorTexture(0.31, 0.76, 0.97, 1)

	local text = button:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	text:SetPoint("LEFT", box, "RIGHT", 6, 0)
	text:SetText(label)

	function button.Update()
		tick:SetShown(ns.db.settings[section][key] and true or false)
	end
	button:SetScript("OnClick", function()
		ns.db.settings[section][key] = not ns.db.settings[section][key]
		Changed()
	end)
	return button
end

local function CreateCycle(parent, section, key, label, values, format)
	local button = CreateFrame("Button", nil, parent)
	button:SetSize(250, 20)

	local text = button:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	text:SetPoint("LEFT", 0, 0)
	text:SetText(label)

	local value = button:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	value:SetPoint("RIGHT", 0, 0)

	local function Index()
		local current = ns.db.settings[section][key]
		for i, candidate in ipairs(values) do
			if candidate == current then
				return i
			end
		end
		return 0
	end

	function button.Update()
		value:SetText("[ " .. string.format(format, ns.db.settings[section][key]) .. " ]")
	end
	button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	button:SetScript("OnClick", function(_, mouseButton)
		local step = mouseButton == "RightButton" and -1 or 1
		local index = (Index() - 1 + step) % #values + 1
		ns.db.settings[section][key] = values[index]
		Changed()
	end)
	return button
end

local function CreateAction(parent, label, onClick)
	local button = CreateFrame("Button", nil, parent)
	button:SetSize(120, 22)
	Util.Skin(button, 0.6)
	local text = button:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	text:SetPoint("CENTER")
	text:SetText(label)
	button:SetScript("OnClick", onClick)
	return button
end

local function Create()
	frame = CreateFrame("Frame", "BetterRareSpawnsOptions", UIParent)
	frame:SetSize(580, 470)
	frame:SetPoint("CENTER")
	frame:SetFrameStrata("DIALOG")
	frame:Hide() -- new frames start shown
	Util.Skin(frame, 0.96)
	Util.MakeMovable(frame, "options")
	if UISpecialFrames then
		UISpecialFrames[#UISpecialFrames + 1] = "BetterRareSpawnsOptions" -- Escape closes it
	end

	local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", 16, -14)
	title:SetText("BetterRareSpawns |cff9a9a9a" .. ns.VERSION .. "|r")

	local close = CreateFrame("Button", nil, frame)
	close:SetSize(22, 22)
	close:SetPoint("TOPRIGHT", -8, -8)
	close.text = close:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
	close.text:SetPoint("CENTER")
	close.text:SetText("x")
	close:SetScript("OnClick", function()
		frame:Hide()
	end)

	-- Two columns, two sections each.
	local columnX = { 18, 302 }
	local columnY = { -48, -48 }
	for index, section in ipairs(LAYOUT) do
		local column = (index % 2 == 1) and 1 or 2
		local header = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		header:SetPoint("TOPLEFT", columnX[column], columnY[column])
		header:SetText(section.title)
		columnY[column] = columnY[column] - 20

		for _, row in ipairs(section) do
			local widget
			if row[4] then
				widget = CreateCycle(frame, row[1], row[2], row[3], row[4], row[5])
			else
				widget = CreateCheck(frame, row[1], row[2], row[3])
			end
			widget:SetPoint("TOPLEFT", columnX[column], columnY[column])
			columnY[column] = columnY[column] - 21
			widgets[#widgets + 1] = widget
		end
		columnY[column] = columnY[column] - 12
	end

	frame.info = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	frame.info:SetPoint("BOTTOMLEFT", 18, 44)
	frame.info:SetPoint("RIGHT", -18, 0)
	frame.info:SetJustifyH("LEFT")

	local test = CreateAction(frame, "Test alert", function()
		ns.Alerts.Test()
	end)
	test:SetPoint("BOTTOMLEFT", 16, 14)

	local list = CreateAction(frame, "Show / hide list", function()
		ns.Tracker.Toggle()
	end)
	list:SetPoint("LEFT", test, "RIGHT", 8, 0)

	local import = CreateAction(frame, "Re-read QuestieDB", function()
		if not ns.Rares.ImportQuestie(true) then
			ns.Print("QuestieDB is not installed (or an import is already running).")
		end
	end)
	import:SetPoint("LEFT", list, "RIGHT", 8, 0)

	local reset = CreateAction(frame, "Reset settings", function()
		ns.DB.ResetSettings()
	end)
	reset:SetPoint("LEFT", import, "RIGHT", 8, 0)
end

function Options.Refresh()
	if not frame or not frame:IsShown() then
		return
	end
	for _, widget in ipairs(widgets) do
		widget.Update()
	end

	local learned = 0
	for _ in pairs(ns.db.learned) do
		learned = learned + 1
	end
	local timers = 0
	for _, rec in pairs(ns.db.timers) do
		if #rec.samples > 0 then
			timers = timers + 1
		end
	end
	local key1 = GetBindingKey and GetBindingKey("CLICK BetterRareSpawnsScan:LeftButton")
	frame.info:SetText(string.format(
		"%d rares known (%d seen by you, %d with a learned respawn).  Scan key: %s",
		ns.Rares.Count(), learned, timers, key1 or "not bound - set it under Key Bindings > AddOns"))
end

function Options.Toggle()
	if not frame then
		Create()
	end
	frame:SetShown(not frame:IsShown())
	Options.Refresh()
end

ns.Listen("OPEN_OPTIONS", function()
	if not frame or not frame:IsShown() then
		Options.Toggle()
	end
end)
ns.Listen("SETTINGS_CHANGED", Options.Refresh)
ns.Listen("RARES_CHANGED", Options.Refresh)
