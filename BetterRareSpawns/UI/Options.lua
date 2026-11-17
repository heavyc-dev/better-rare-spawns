-- Options window: the classic dialog box with the game's own check boxes and
-- panel buttons.
local ADDON, ns = ...

local Options = {}
ns.Options = Options

local Util, Style = ns.Util, ns.Style

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
		{ "alerts", "nearby", "Tell me when I walk into a rare's spawn area" },
		{ "alerts", "instances", "Alert inside dungeons and raids" },
		{ "alerts", "mark", "Put a skull marker on a targeted rare" },
		{ "alerts", "wanted", "Louder alert for wanted rares" },
		{ "alerts", "windows", "Tell me when a wanted rare's window opens" },
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
		{ "map", "compact", "One pin per rare (hover shows the rest)" },
		{ "map", "scale", "Pin size", { 0.8, 1.0, 1.25, 1.5 }, "%.2fx" },
		{ "map", "minLevel", "Hide rares below level", { 0, 10, 20, 30, 40, 50 }, "%d" },
	},
	{
		title = "Minimap, sharing and list",
		{ "minimap", "enabled", "Show pins on the minimap" },
		{ "minimap", "scale", "Minimap pin size", { 0.8, 1.0, 1.25, 1.5 }, "%.2fx" },
		{ "minimap", "button", "Show the minimap button" },
		{ "share", "guild", "Share sightings with my guild" },
		{ "share", "group", "Share sightings with my group" },
		{ "share", "receive", "Use what others share" },
		{ "share", "sync", "Swap timers with the guild at login" },
		{ "camp", "enabled", "Camp bar when waiting at a spawn point" },
		{ "tracker", "activeOnly", "List: only rares with a timer or sighting" },
		{ "tracker", "locked", "List: lock position" },
		{ "tracker", "scale", "List size", { 0.8, 1.0, 1.2, 1.4 }, "%.1fx" },
	},
}

local ROW = 24
local COLUMN_WIDTH = 270

local widgets = {}
local CreateBinder

local function Changed()
	ns.Fire("SETTINGS_CHANGED")
end

local function CreateCheck(parent, section, key, label)
	local button = Style.Check(parent, label)
	function button.Update()
		button:SetChecked(ns.db.settings[section][key] and true or false)
	end
	button:SetScript("OnClick", function()
		ns.db.settings[section][key] = not ns.db.settings[section][key]
		Style.Sound("click")
		Changed()
	end)
	return button
end

--- A value button with its label to the left; click steps forward,
-- right-click back.
local function CreateCycle(parent, section, key, label, values, format)
	local button = Style.Button(parent, "", 64, 20)
	button.offsetX = COLUMN_WIDTH - 70

	local text = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	text:SetPoint("RIGHT", button, "LEFT", -6, 0)
	text:SetWidth(COLUMN_WIDTH - 82)
	text:SetJustifyH("LEFT")
	text:SetText(label)

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
		button:SetText(string.format(format, ns.db.settings[section][key]))
	end
	button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	button:SetScript("OnClick", function(_, mouseButton)
		local step = mouseButton == "RightButton" and -1 or 1
		local index = (Index() - 1 + step) % #values + 1
		ns.db.settings[section][key] = values[index]
		Style.Sound("click")
		Changed()
	end)
	return button
end

-------------------------------------------------------------------------------
-- Scan key binder: click, press a key, done. The same binding is also listed
-- under Key Bindings > AddOns.
-------------------------------------------------------------------------------

local SCAN_BINDING = "CLICK BetterRareSpawnsScan:LeftButton"
local MODIFIER_KEYS = {
	LSHIFT = true, RSHIFT = true, LCTRL = true, RCTRL = true, LALT = true, RALT = true,
	LMETA = true, RMETA = true, UNKNOWN = true,
}
local binder

local function SaveKeys()
	if SaveBindings and GetCurrentBindingSet then
		pcall(SaveBindings, GetCurrentBindingSet())
	end
end

local function ClearScanKeys()
	local keys = { GetBindingKey(SCAN_BINDING) }
	for _, key in ipairs(keys) do
		if type(key) == "string" then
			SetBinding(key) -- no command: unbinds the key
		end
	end
end

--- Binds `key` (already carrying its modifiers) to the scan button.
-- Returns true, or false and the reason.
function Options.BindScanKey(key)
	if InCombatLockdown() then
		return false, "Keys cannot be changed in combat."
	end
	if not (SetBinding and GetBindingKey) then
		return false, "This client does not let addons set key bindings."
	end
	local previous = GetBindingAction and GetBindingAction(key)
	ClearScanKeys()
	if not SetBinding(key, SCAN_BINDING) then
		return false, "The game refused " .. key .. "."
	end
	SaveKeys()
	if type(previous) == "string" and previous ~= "" and previous ~= SCAN_BINDING then
		local label = _G["BINDING_NAME_" .. previous] or previous
		ns.Print(key .. " was bound to '" .. tostring(label) .. "' - it now scans for rares.")
	else
		ns.Print("Scan key set to " .. key .. ".")
	end
	return true
end

function Options.UnbindScanKey()
	if InCombatLockdown() or not (SetBinding and GetBindingKey) then
		return false
	end
	ClearScanKeys()
	SaveKeys()
	ns.Print("Scan key unbound.")
	return true
end

local function StopListening()
	binder.listening = false
	binder:EnableKeyboard(false)
	Options.Refresh()
end

CreateBinder = function()
	binder = Style.Button(frame, "", 150, 22)
	binder:SetPoint("BOTTOMLEFT", 22, 72)
	binder:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	binder:EnableKeyboard(false)

	binder.note = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	binder.note:SetPoint("LEFT", binder, "RIGHT", 8, 0)
	binder.note:SetPoint("RIGHT", frame, "RIGHT", -24, 0)
	binder.note:SetJustifyH("LEFT")
	binder.note:SetText("One key that targets any rare near you. Click to set, right-click to clear.")

	function binder.Update()
		if binder.listening then
			binder:SetText("Press a key...")
		else
			local key = GetBindingKey and GetBindingKey(SCAN_BINDING)
			binder:SetText(key and ("Scan key: " .. key) or "Bind Scan Key")
		end
	end

	binder:SetScript("OnClick", function(_, mouseButton)
		if mouseButton == "RightButton" then
			binder.listening = false
			binder:EnableKeyboard(false)
			Options.UnbindScanKey()
			Options.Refresh()
			return
		end
		if InCombatLockdown() then
			ns.Print("Keys cannot be changed in combat.")
			return
		end
		binder.listening = not binder.listening
		binder:EnableKeyboard(binder.listening)
		if binder.SetPropagateKeyboardInput then
			pcall(binder.SetPropagateKeyboardInput, binder, false)
		end
		binder.Update()
	end)
	binder:SetScript("OnKeyDown", function(_, key)
		if not binder.listening or MODIFIER_KEYS[key] then
			return
		end
		if key == "ESCAPE" then
			return StopListening()
		end
		local full = (IsAltKeyDown() and "ALT-" or "") .. (IsControlKeyDown() and "CTRL-" or "") .. (IsShiftKeyDown() and "SHIFT-" or "") .. key
		local ok, reason = Options.BindScanKey(full)
		if not ok then
			ns.Print(reason)
		end
		StopListening()
	end)
	binder:SetScript("OnHide", function()
		binder.listening = false
		binder:EnableKeyboard(false)
	end)
	widgets[#widgets + 1] = binder
end

local function Create()
	frame = Style.Frame("Frame", "BetterRareSpawnsOptions", UIParent)
	frame:SetSize(600, 640)
	frame:SetPoint("CENTER")
	frame:SetFrameStrata("DIALOG")
	frame:Hide() -- new frames start shown
	Style.Dialog(frame, "Rare Spawns")
	Util.MakeMovable(frame, "options")
	if UISpecialFrames then
		UISpecialFrames[#UISpecialFrames + 1] = "BetterRareSpawnsOptions" -- Escape closes it
	end

	local close = Style.Close(frame, function()
		frame:Hide()
	end)
	close:SetPoint("TOPRIGHT", -4, -4)

	-- Two columns, two sections each.
	local columnX = { 24, 310 }
	local columnY = { -36, -36 }
	for index, section in ipairs(LAYOUT) do
		local column = (index % 2 == 1) and 1 or 2
		local header = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		header:SetPoint("TOPLEFT", columnX[column], columnY[column])
		header:SetText(section.title)
		columnY[column] = columnY[column] - 18

		for _, row in ipairs(section) do
			local widget
			if row[4] then
				widget = CreateCycle(frame, row[1], row[2], row[3], row[4], row[5])
			else
				widget = CreateCheck(frame, row[1], row[2], row[3])
			end
			widget:SetPoint("TOPLEFT", columnX[column] + (widget.offsetX or 0), columnY[column])
			columnY[column] = columnY[column] - ROW
			widgets[#widgets + 1] = widget
		end
		columnY[column] = columnY[column] - 10
	end

	frame.info = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	frame.info:SetPoint("BOTTOMLEFT", 24, 50)
	frame.info:SetPoint("RIGHT", -24, 0)
	frame.info:SetJustifyH("LEFT")

	CreateBinder()

	local journal = Style.Button(frame, "Rare Journal", 104, 22, function()
		ns.Fire("OPEN_JOURNAL")
	end)
	journal:SetPoint("BOTTOMLEFT", 22, 20)

	local list = Style.Button(frame, "Zone List", 90, 22, function()
		ns.Tracker.Toggle()
	end)
	list:SetPoint("LEFT", journal, "RIGHT", 6, 0)

	local test = Style.Button(frame, "Test Alert", 90, 22, function()
		ns.Alerts.Test()
	end)
	test:SetPoint("LEFT", list, "RIGHT", 6, 0)

	local import = Style.Button(frame, "Re-read QuestieDB", 130, 22, function()
		if not ns.Rares.ImportQuestie(true) then
			ns.Print("QuestieDB is not installed (or an import is already running).")
		end
	end)
	import:SetPoint("LEFT", test, "RIGHT", 6, 0)

	local reset = Style.Button(frame, "Defaults", 90, 22, function()
		ns.DB.ResetSettings()
	end)
	reset:SetPoint("LEFT", import, "RIGHT", 6, 0)
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
	frame.info:SetText(string.format("%d rares known (%d seen by you, %d with a learned respawn).",
		ns.Rares.Count(), learned, timers))
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
