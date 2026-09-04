------------------------------------------------------------------------------------------------------
-- RaidBuffStatus TurtleWoW
--
-- Settings window, cloned from Questie-Octo's proven architecture (UI/Options.lua there): a
-- declarative AceConfig options table fed through AceConfigDialog into a standalone AceGUI Frame,
-- plus Questie's ShaguTweaks-style dark pass over the resulting widget tree. All libraries are
-- vendored in Libs/ from Questie-Octo's own copies (Ace3 license, Libs/Ace3-LICENSE.txt), with
-- their LibStub major names renamed QuestieOcto-* -> RBS-* so both addons can coexist.
--
-- Earlier attempts hand-built this window (XML chrome, then raw AceGUI TabGroup calls) and each
-- came out broken in a different way; this file deliberately deviates from Questie's Options.lua
-- as little as possible.
------------------------------------------------------------------------------------------------------

-- Unconditional load canary (2026-08-27): the game reported "attempt to call global
-- `RaidBuffStatus_ShowOptions' (a nil value)" when the slash command tried to call it, which means
-- this ENTIRE FILE never executed -- that function is defined unconditionally at this file's top
-- level, so if it's nil, nothing in this file ran at all (not a bug inside one of its functions).
-- This print runs the instant the file is parsed, before anything else in it, to give a direct,
-- unambiguous answer at /reload time instead of only finding out indirectly when /rbs options fails
-- much later: if "RaidBuffStatusOptions.lua loaded" never appears in chat, this file (and likely the
-- whole Libs\ folder it depends on) simply is not present in the live AddOns install.
DEFAULT_CHAT_FRAME:AddMessage("|cFF00CCFFRaidBuffStatus:|r RaidBuffStatusOptions.lua loaded.")

local APP_NAME = "RaidBuffStatus"

local RaidBuffStatusOptions = {
	configFrame = nil,
	initialized = false,
}

------------------------------------------------------------------------------------------------------
-- DARK THEME (ported from Questie-Octo UI/Options.lua, always on -- no toggle)
------------------------------------------------------------------------------------------------------

local SHELL_R, SHELL_G, SHELL_B, SHELL_A = 0.30, 0.30, 0.30, 0.90
local INNER_R, INNER_G, INNER_B, INNER_A = 0.035, 0.035, 0.035, 0.84
local INNER_BORDER_R, INNER_BORDER_G, INNER_BORDER_B, INNER_BORDER_A = 0.20, 0.20, 0.20, 0.95
local TAB_R, TAB_G, TAB_B, TAB_A = 0.28, 0.28, 0.28, 1.0

local function ShouldSkipShellTexture(region)
	if not region or not region.GetTexture then
		return true
	end
	local texture = region:GetTexture()
	if not texture then
		return true
	end

	local name = region.GetName and region:GetName() or nil
	if name then
		if string.find(name, "Button", 1, true) or string.find(name, "Icon", 1, true) then
			return true
		end
	end

	if type(texture) == "string" then
		if
			string.find(texture, "Button", 1, true)
			or string.find(texture, "Icon", 1, true)
			or string.find(texture, "WHITE8X8", 1, true)
			or string.find(texture, "StatusBar", 1, true)
			or string.find(texture, "BarFill", 1, true)
			or string.find(texture, "Portrait", 1, true)
		then
			return true
		end
	end

	if region.GetBlendMode and region:GetBlendMode() == "ADD" then
		return true
	end
	return false
end

-- Only tint the physical AceGUI Frame itself -- its DialogFrame textures need vertex tinting,
-- while AceConfig's content containers look better with dark backdrops (below).
local function DarkenOuterShell(frame)
	if not frame then
		return
	end

	if frame.SetBackdropBorderColor then
		frame:SetBackdropBorderColor(SHELL_R, SHELL_G, SHELL_B, SHELL_A)
	end

	if frame.GetRegions then
		local regions = { frame:GetRegions() }
		for _, region in pairs(regions) do
			if
				region
				and region.GetObjectType
				and region:GetObjectType() == "Texture"
				and region.SetVertexColor
				and not ShouldSkipShellTexture(region)
			then
				region:SetVertexColor(SHELL_R, SHELL_G, SHELL_B, SHELL_A)
			end
		end
	end
end

local function IsTabTexture(region)
	if not region or not region.GetTexture then
		return false
	end
	local texture = region:GetTexture()
	return type(texture) == "string" and string.find(texture, "ChatFrameTab", 1, true) and true or false
end

-- AceGUI's ScrollFrame places a UIPanelScrollBarTemplate just outside the scrolling viewport (the
-- widget names it AceConfigDialogScrollFrame<N>ScrollBar regardless of which addon feeds it).
-- Keep that native Vanilla control above the dark content panels and never recolor it.
local function IsAceConfigScrollbar(frame)
	if not frame or not frame.GetName then
		return false
	end
	local name = frame:GetName()
	return name
		and string.find(name, "AceConfigDialogScrollFrame", 1, true)
		and string.find(name, "ScrollBar", 1, true)
		and true
		or false
end

local function RaiseScrollbar(frame)
	if not frame then
		return
	end

	if IsAceConfigScrollbar(frame) then
		local parent = frame.GetParent and frame:GetParent() or nil
		local base = (parent and parent.GetFrameLevel and parent:GetFrameLevel()) or 0
		if frame.SetFrameLevel then
			frame:SetFrameLevel(base + 20)
		end

		-- Vanilla's UIPanelScrollBarTemplate thumb artwork is wider than the 16px Slider frame
		-- AceGUI uses; give the slider its native visual width so the full thumb renders.
		if frame.SetWidth and not frame.rbsFullThumbWidth then
			frame:SetWidth(20)
			frame.rbsFullThumbWidth = true
		end

		if frame.GetChildren then
			local children = { frame:GetChildren() }
			for _, child in pairs(children) do
				if child and child.SetFrameLevel then
					child:SetFrameLevel(base + 21)
				end
			end
		end
		return
	end

	if frame.GetChildren then
		local children = { frame:GetChildren() }
		for _, child in pairs(children) do
			RaiseScrollbar(child)
		end
	end
end

-- Dark panels come from coloring frame backdrops (ShaguTweaks-style) rather than painting a gray
-- vertex wash over every child region -- backdrop-less controls (checkboxes, sliders, icons) keep
-- their crisp native artwork.
local function DarkenInnerContent(frame)
	if not frame then
		return
	end

	if IsAceConfigScrollbar(frame) then
		return
	end

	if frame.SetBackdropColor then
		frame:SetBackdropColor(INNER_R, INNER_G, INNER_B, INNER_A)
	end
	if frame.SetBackdropBorderColor then
		frame:SetBackdropBorderColor(INNER_BORDER_R, INNER_BORDER_G, INNER_BORDER_B, INNER_BORDER_A)
	end

	-- The top tabs use ChatFrameTab textures instead of a backdrop -- tint only those.
	if frame.GetRegions then
		local regions = { frame:GetRegions() }
		for _, region in pairs(regions) do
			if
				region
				and region.GetObjectType
				and region:GetObjectType() == "Texture"
				and region.SetVertexColor
				and IsTabTexture(region)
			then
				region:SetVertexColor(TAB_R, TAB_G, TAB_B, TAB_A)
			end
		end
	end

	if frame.GetChildren then
		local children = { frame:GetChildren() }
		for _, child in pairs(children) do
			DarkenInnerContent(child)
		end
	end
end

-- Global on purpose: the vendored AceConfigDialog re-invokes this after every widget refresh
-- (tab switches recreate all child widgets), mirroring Questie's own hook there.
function RaidBuffStatus_ApplyOptionsDarkTheme()
	local configFrame = RaidBuffStatusOptions.configFrame
	if not configFrame or not configFrame.frame then
		return
	end

	local shell = configFrame.frame
	DarkenOuterShell(shell)
	if shell.GetChildren then
		local children = { shell:GetChildren() }
		for _, child in pairs(children) do
			DarkenInnerContent(child)
		end
	end
	RaiseScrollbar(shell)
end

------------------------------------------------------------------------------------------------------
-- OPTIONS TABLE
------------------------------------------------------------------------------------------------------

local function CreateGeneralTab()
	return {
		name = "General",
		type = "group",
		args = {
			enabled = {
				type = "toggle", order = 1, width = "full",
				name = "Enabled",
				desc = "Shows or hides the RaidBuffStatus window. Same as /rbs.",
				get = function()
					return RaidBuffStatusConfig.Enabled
				end,
				set = function(info, value)
					RaidBuffStatusConfig.Enabled = value
					if value then
						RaidBuffStatusFrame:Show()
					else
						RaidBuffStatusFrame:Hide()
					end
				end,
			},
			iconSize = {
				type = "range", order = 2, width = "full",
				name = "Icon size",
				desc = "Size, in pixels, of each buff icon. The window and grid re-fit automatically.",
				min = 16, max = 48, step = 1,
				get = function()
					return RBS_ICON_SIZE
				end,
				set = function(info, value)
					RBS_ApplyIconSize(value)
				end,
			},
		},
	}
end

local function CreateRaidAssistTab()
	return {
		name = "RaidAssist",
		type = "group",
		args = {
			autoInvite = {
				type = "toggle", order = 1, width = "full",
				name = "Auto-invite on whisper",
				desc = "Automatically invites anyone who whispers you exactly \"inv\", \"invite\", or \"123\" (case-insensitive, whole message only -- a real sentence containing one of those words won't trigger it).",
				get = function()
					return RaidBuffStatusConfig.AutoInvite
				end,
				set = function(info, value)
					RaidBuffStatusConfig.AutoInvite = value
				end,
			},
			deathWarnings = {
				type = "toggle", order = 2, width = "full",
				name = "Death warnings",
				desc = "Shows a big on-screen banner, plays a sound, and announces to raid chat (or party chat when not in a raid) whenever a raid/party member dies.",
				get = function()
					return RaidBuffStatusConfig.DeathWarnings
				end,
				set = function(info, value)
					RaidBuffStatusConfig.DeathWarnings = value
				end,
			},
		},
	}
end

-- Placeholder tabs (2026-08-29, per the user) -- no settings assigned to either yet, just the tab
-- shells so options can be added here later without another restructure.
local function CreateHealersTab()
	return {
		name = "Healers",
		type = "group",
		args = {
			-- Ported from Holyward (2026-09-02, per the user).
			mouseoverCast = {
				type = "toggle", order = 1, width = "full",
				name = "Mouseover casting",
				desc = "Every spell/item used from ANY action bar targets whatever unit is under your mouse instead of your current target -- lets you heal off a raid frame without changing target.",
				get = function()
					return RaidBuffStatusConfig.MouseoverCast
				end,
				set = function(info, value)
					RaidBuffStatusConfig.MouseoverCast = value
				end,
			},
		},
	}
end

-- Mocking Blow / Salvation removal / fight-start misses (2026-08-31), per the user's own explicit
-- request: each is its OWN independent toggle, deliberately not bundled under one umbrella
-- "mode" switch.
local function CreateTanksTab()
	return {
		name = "Tanks",
		type = "group",
		args = {
			tauntWarnings = {
				type = "toggle", order = 1, width = "full",
				name = "Taunt resist warnings",
				desc = "On-screen alert and sound when YOUR OWN Taunt fails (resisted, immune, dodged, etc). Self only for now -- detecting other players' taunts would need combat-log tracking this addon doesn't do yet.",
				get = function()
					return RaidBuffStatusConfig.TauntWarnings
				end,
				set = function(info, value)
					RaidBuffStatusConfig.TauntWarnings = value
				end,
			},
			mockingBlowAnnounce = {
				type = "toggle", order = 2, width = "full",
				name = "Mocking Blow use-announce",
				desc = "Posts to raid/party chat whenever you use Mocking Blow, naming your current target (with its raid mark, if any).",
				get = function()
					return RaidBuffStatusConfig.MockingBlowAnnounce
				end,
				set = function(info, value)
					RaidBuffStatusConfig.MockingBlowAnnounce = value
				end,
			},
			autoRemoveSalvation = {
				type = "toggle", order = 3, width = "full",
				name = "Auto-remove Blessing of Salvation",
				desc = "Immediately cancels Blessing of Salvation / Greater Blessing of Salvation on yourself the moment it's detected -- it reduces threat generation, which a tank never wants.",
				get = function()
					return RaidBuffStatusConfig.AutoRemoveSalvation
				end,
				set = function(info, value)
					RaidBuffStatusConfig.AutoRemoveSalvation = value
				end,
			},
			fightStartMisses = {
				type = "toggle", order = 4, width = "full",
				name = "Announce misses at fight start",
				desc = "For a short window after entering combat, posts your own melee misses/dodges/parries against your target to raid/party chat -- an early warning that threat isn't established yet.",
				get = function()
					return RaidBuffStatusConfig.FightStartMisses
				end,
				set = function(info, value)
					RaidBuffStatusConfig.FightStartMisses = value
				end,
			},
			fightStartMissesDuration = {
				type = "range", order = 5, width = "full",
				name = "Fight-start window (seconds)",
				desc = "How many seconds after entering combat the miss/dodge/parry announce above stays active.",
				min = 3, max = 20, step = 1,
				get = function()
					return RaidBuffStatusConfig.FightStartMissesDuration
				end,
				set = function(info, value)
					RaidBuffStatusConfig.FightStartMissesDuration = value
				end,
			},
		},
	}
end

-- Raid ability cooldown tracker (2026-08-30) -- generated from RBS_CD_LIST (a global defined in
-- RaidBuffStatus.lua) so adding/removing a tracked ability there doesn't need a matching hand-edit
-- here.
local function CreateCooldownsTab()
	local args = {
		enabled = {
			type = "toggle", order = 1, width = "full",
			name = "Enabled",
			desc = "Shows the Cooldowns window and tracks the abilities below. Does NOT require anyone else to run this addon -- but it only knows about a cast this client actually witnessed while running, not one that happened before you logged in or joined the group.",
			get = function()
				return RaidBuffStatusConfig.CDEnabled
			end,
			set = function(info, value)
				RaidBuffStatusConfig.CDEnabled = value
			end,
		},
		iconSize = {
			type = "range", order = 2, width = "full",
			-- Renamed (2026-09-03, per the user): this used to only resize the icon graphic -- now
			-- it scales the whole row (icon, progress bar, text) together as one overall size.
			name = "Row size",
			desc = "Overall size of each row in the Cooldowns window -- icon, progress bar, and text all scale together.",
			min = 14, max = 32, step = 1,
			get = function()
				return RaidBuffStatusConfig.CDIconSize or 20
			end,
			set = function(info, value)
				RBS_ApplyCDIconSize(value)
			end,
		},
		-- "Show ability name" toggle removed (2026-08-31, per the user): rows now always show just
		-- the caster's name (no more "-- Ability" suffix) -- the row's own icon already identifies
		-- which ability it is, so the option had nothing left to toggle.
		rowLimit = {
			type = "select", order = 2.5, width = "full",
			name = "Rows before starting a new column",
			desc = "Once a column reaches this many rows, the Cooldowns window starts a new column to the right instead of growing straight down forever.",
			-- Numeric keys (2026-09-03): AceConfigDialog's Dropdown control sorts a select's values
			-- by KEY when no explicit order is given (table.sort over the keys) -- plain numbers sort
			-- correctly ascending, with 0 ("Sin limite") first, no separate ordering list needed.
			values = {
				[0] = "Sin limite",
				[10] = "10",
				[15] = "15",
				[20] = "20",
				[25] = "25",
				[30] = "30",
			},
			get = function()
				return RaidBuffStatusConfig.CDRowLimit or 0
			end,
			set = function(info, value)
				RaidBuffStatusConfig.CDRowLimit = value
			end,
		},
		resetPosition = {
			type = "execute", order = 2.8, width = "full",
			name = "Reset position",
			desc = "Puts the Cooldowns window back at its default position (center of the screen, slightly above center) -- for if it's been dragged off-screen or somewhere inconvenient.",
			func = function()
				RBS_ResetCDPosition()
			end,
		},
		talentHeader = {
			type = "header", order = 3,
			name = "Experimental",
		},
		talentScan = {
			type = "toggle", order = 3.5, width = "full",
			name = "Hide talent-gated rows for people without the talent",
			desc = "Ascendance, Bloodlust, Heroism and Spirit Link Totem are talent picks on this server, not baseline class abilities -- not every Priest/Shaman has them. When on, this inspects Priests/Shamans in your raid/party (one at a time, only while in range, cached per-person for the session) and hides that person's row for one of these four abilities if they're confirmed NOT to have the talent. Experimental: relies on the Inspect API and a name-match against their talent list, and a row stays visible until the scan actually confirms they lack it.",
			get = function()
				return RaidBuffStatusConfig.TalentScanEnabled
			end,
			set = function(info, value)
				RaidBuffStatusConfig.TalentScanEnabled = value
			end,
		},
		trackHeader = {
			type = "header", order = 4,
			name = "Track which abilities",
		},
	}

	for i = 1, table.getn(RBS_CD_LIST), 1 do
		local def = RBS_CD_LIST[i]
		args["track_" .. def.id] = {
			type = "toggle", order = 4 + i, width = "full",
			name = def.label .. " (" .. def.class .. ")",
			desc = "Track " .. def.label .. ".",
			-- Defensive nil-table guards (2026-08-30): the real fix for CDTrack coming back nil is
			-- RBS_OnAddonLoaded (RaidBuffStatus.lua) reacting to ADDON_LOADED, but these cost nothing
			-- and mean the options panel itself can never crash on this either.
			get = function()
				return RaidBuffStatusConfig.CDTrack and RaidBuffStatusConfig.CDTrack[def.id]
			end,
			set = function(info, value)
				RaidBuffStatusConfig.CDTrack = RaidBuffStatusConfig.CDTrack or {}
				RaidBuffStatusConfig.CDTrack[def.id] = value
			end,
		}
	end

	return {
		name = "Cooldowns",
		type = "group",
		args = args,
	}
end

local function CreateOptionsTable()
	return {
		name = "RaidBuffStatus Options",
		type = "group",
		childGroups = "tab",
		args = {
			general_tab = CreateGeneralTab(),
			raidassist_tab = CreateRaidAssistTab(),
			healers_tab = CreateHealersTab(),
			tanks_tab = CreateTanksTab(),
			cooldowns_tab = CreateCooldownsTab(),
		},
	}
end

------------------------------------------------------------------------------------------------------
-- FRAME LIFECYCLE (mirrors Questie-Octo's O:Initialize/Show/Hide/Toggle)
------------------------------------------------------------------------------------------------------

local function ClearSavedConfigPosition()
	local Dialog = LibStub and LibStub("RBS-AceConfigDialog-3.0", true)
	if not Dialog or not Dialog.GetStatusTable then
		return
	end
	local status = Dialog:GetStatusTable(APP_NAME)
	if status then
		status.top = nil
		status.left = nil
	end
end

local function RaidBuffStatusOptions_Initialize()
	if RaidBuffStatusOptions.initialized then
		return true
	end

	local AceGUI = LibStub and LibStub("AceGUI-3.0", true)
	local Registry = LibStub and LibStub("RBS-AceConfigRegistry-3.0", true)
	local Dialog = LibStub and LibStub("RBS-AceConfigDialog-3.0", true)
	if not AceGUI or not Registry or not Dialog then
		DEFAULT_CHAT_FRAME:AddMessage("|cFF00CCFFRaidBuffStatus:|r |cFFFF0000Options UI libraries failed to load.|r")
		return false
	end

	Registry:RegisterOptionsTable(APP_NAME, CreateOptionsTable())

	local configFrame = AceGUI:Create("Frame")
	configFrame:Hide()

	-- Taller (2026-09-02, per the user: the window read as too squat/cramped) -- still narrower than
	-- Holyward's own 625x700, but enough vertical room for the Tanks tab's 4 checkboxes + slider and
	-- the Cooldowns tab's long per-ability list without either one feeling cramped.
	Dialog:SetDefaultSize(APP_NAME, 420, 480)
	Dialog:Open(APP_NAME, configFrame)
	configFrame:SetLayout("Fill")

	-- AceConfigDialog calls SetStatusTable() on this custom root frame after every option
	-- activation, and AceGUI Frame's SetStatusTable immediately re-runs frame geometry, which can
	-- visibly jump the window on this 1.12 client (Questie hit and neutralized the same thing).
	-- Keep the status table for Ace3 semantics but skip the geometry re-apply.
	if configFrame.SetStatusTable then
		configFrame.SetStatusTable = function(self, status)
			if status then
				status.top = nil
				status.left = nil
				self.status = status
			end
		end
	end

	if configFrame.EnableResize then
		configFrame:EnableResize(false)
	end

	configFrame:Hide()
	RaidBuffStatusOptions.configFrame = configFrame

	-- ESC closes the window: the AceGUI widget table exposes IsShown()/Hide(), which is all
	-- UISpecialFrames needs on this client (same registration Questie uses).
	RaidBuffStatusConfigFrame = configFrame
	local registered = false
	for _, name in pairs(UISpecialFrames or {}) do
		if name == "RaidBuffStatusConfigFrame" then
			registered = true
			break
		end
	end
	if not registered then
		table.insert(UISpecialFrames, "RaidBuffStatusConfigFrame")
	end

	RaidBuffStatusOptions.initialized = true
	return true
end

local function RecenterConfigFrame(configFrame)
	ClearSavedConfigPosition()
	if not configFrame or not configFrame.frame then
		return
	end
	local frame = configFrame.frame
	if frame.ClearAllPoints then
		frame:ClearAllPoints()
	end
	if frame.SetPoint then
		frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
	end
end

function RaidBuffStatus_ShowOptions()
	if not RaidBuffStatusOptions_Initialize() then
		return
	end
	local Dialog = LibStub("RBS-AceConfigDialog-3.0")
	Dialog:Open(APP_NAME, RaidBuffStatusOptions.configFrame)
	RecenterConfigFrame(RaidBuffStatusOptions.configFrame)
	if RaidBuffStatusOptions.configFrame.SetStatusText then
		RaidBuffStatusOptions.configFrame:SetStatusText(nil)
	end
	RaidBuffStatus_ApplyOptionsDarkTheme()
end

function RaidBuffStatus_HideOptions()
	if RaidBuffStatusOptions.configFrame and RaidBuffStatusOptions.configFrame:IsShown() then
		RaidBuffStatusOptions.configFrame:Hide()
	end
end

function RaidBuffStatus_IsOptionsVisible()
	return RaidBuffStatusOptions.configFrame ~= nil and RaidBuffStatusOptions.configFrame:IsShown()
end
