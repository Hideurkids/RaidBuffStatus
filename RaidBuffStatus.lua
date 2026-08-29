------------------------------------------------------------------------------------------------------
-- RaidBuffStatus (TurtleWoW/OctoWoW) -- core buff tracking only
--
-- Shows, for every raid/party member, which key class buffs they're currently missing. A
-- from-scratch build inspired by the original WotLK RaidBuffStatus (embedded WotLK-era Ace3,
-- 13,000+ lines, level-80 buff/consumable/talent/AFK/repair tracking) -- NOT a line-for-line port of
-- it. That codebase is written in modern-Lua style (colon-calls on strings, varargs reused in a
-- function body, hex literals) that this Lua 5.0.2 client doesn't support, the same class of issue
-- that cost ~180 call sites porting RCLootCouncil; and its buff/consumable list targets level-80
-- Wrath raids, not vanilla level-60 content. Per the user's explicit scope (2026-08-26): buff
-- tracking only for now -- consumables, talent/spec checks, AFK detection, and repair/ammo
-- reminders are all deliberately deferred, not forgotten.
--
-- The buff-reading technique (UnitBuff + a hidden scanning tooltip to resolve the real aura name)
-- is the exact proven pattern from DopingControl (scan/aura.lua, already confirmed working on this
-- client for whole-raid buff auditing) -- this first pass only uses that tool's "Path A" (UnitBuff +
-- tooltip); Path B (GetUnitField's Nampower aura descriptor, keyed by GUID) is a documented
-- possible follow-up for extra robustness, not required to ship a working v1. The buff list itself
-- is adapted from DopingControl's own data/classbuffs.lua (already vanilla-scoped and vetted),
-- trimmed to the buffs a raid dashboard actually needs to flag as missing.
------------------------------------------------------------------------------------------------------

RaidBuffStatusConfig = RaidBuffStatusConfig or { Enabled = true }
-- Handles both a fresh install (no saved config yet) and an existing user's config saved before
-- this field existed (RaidBuffStatusConfig ~= nil but .IconSize is nil either way).
RaidBuffStatusConfig.IconSize = RaidBuffStatusConfig.IconSize or 28
RaidBuffStatusConfig.AutoInvite = RaidBuffStatusConfig.AutoInvite or false
RaidBuffStatusConfig.DeathWarnings = RaidBuffStatusConfig.DeathWarnings or false
RaidBuffStatusConfig.TauntWarnings = RaidBuffStatusConfig.TauntWarnings or false

-- Bumped on every meaningful rewrite so a load-message screenshot can confirm which build is
-- actually running, without having to ask the user to check -- also flags whether a stale/second
-- copy of this addon (e.g. a leftover install of the old reference folder reusing the same global
-- names) might be clobbering these functions after this file loads.
RBS_BUILD = "v31-uierrors-taunt-selfresist"

------------------------------------------------------------------------------------------------------
-- BUFF LIST
------------------------------------------------------------------------------------------------------

-- `match` = a single substring searched in the aura name (plain-text find, not a pattern).
-- `matches` = an array of alternative substrings, for buffs whose ranks don't share one common
-- substring (Divine Spirit vs. Prayer of Spirit). Both forms use plain string.find(..., 1, true).
-- `class` = the localized class name (as returned by UnitClass() on this client, English client
-- here) that can actually cast this buff -- used to show WHO in the group/raid is even capable of
-- providing it, separate from who currently has it active.
local RBS_BUFF_LIST = {
	{ id = "AI",       label = "Intellect",         icon = "Interface\\Icons\\Spell_Holy_MagicalSentry",     match = "Intellect",       class = "Mage" },
	{ id = "MOTW",     label = "Mark/Gift",         icon = "Interface\\Icons\\Spell_Nature_Regeneration",    match = "the Wild",        class = "Druid" },
	{ id = "PWF",      label = "Fortitude",         icon = "Interface\\Icons\\Spell_Holy_WordFortitude",     match = "Fortitude",       class = "Priest" },
	{ id = "SPIRIT",   label = "Divine Spirit",     icon = "Interface\\Icons\\Spell_Holy_DivineSpirit",      matches = { "Divine Spirit", "Prayer of Spirit" }, class = "Priest" },
	-- "Prayer of Shadow Protection" contains "Shadow Protection" as a substring, so a single
	-- plain-text `match` already covers both the single-target and raid-wide ranks.
	{ id = "SHADOWPROT", label = "Shadow Protection", icon = "Interface\\Icons\\Spell_Shadow_AntiShadow",    match = "Shadow Protection", class = "Priest" },
	-- Replaced Thorns per the user's request (2026-08-29): `special = "soulstone"` routes this entry
	-- to the dedicated RBS_ScanSoulstone/tooltip logic below instead of the normal "everyone should
	-- have this" missing-count semantics -- see that section's own comment for the full design and
	-- its confirmed limitations (no real cooldown read, approximated via this addon's own tracking).
	{ id = "SOULSTONE", label = "Soulstone", icon = "Interface\\Icons\\INV_Misc_Orb_04", match = "Soulstone Resurrection", class = "Warlock", special = "soulstone" },
	-- Split out per the user's request (2026-08-27): one icon per Paladin blessing instead of a
	-- single generic "Blessing" entry. Only the long-duration RAID buffs are tracked here (Might/
	-- Kings/Wisdom/Salvation/Sanctuary/Light) -- Freedom and Protection are deliberately excluded,
	-- since those are short single-target defensive cooldowns applied as-needed, not something a
	-- raid maintains on everyone the way it does the others. Icon paths confirmed against
	-- Babble-Spell-2.2's spell-to-icon table (Addons\MikScrollingBattleText\Libs\BabbleSpell-2.2).
	{ id = "BLESS_MIGHT",  label = "Bless: Might",     icon = "Interface\\Icons\\Spell_Holy_FistOfJustice",     match = "Blessing of Might",     class = "Paladin" },
	{ id = "BLESS_KINGS",  label = "Bless: Kings",     icon = "Interface\\Icons\\Spell_Magic_MageArmor",        match = "Blessing of Kings",     class = "Paladin" },
	{ id = "BLESS_WISDOM", label = "Bless: Wisdom",    icon = "Interface\\Icons\\Spell_Holy_SealOfWisdom",      match = "Blessing of Wisdom",    class = "Paladin" },
	{ id = "BLESS_SALV",   label = "Bless: Salvation", icon = "Interface\\Icons\\Spell_Holy_SealOfSalvation",   match = "Blessing of Salvation", class = "Paladin" },
	{ id = "BLESS_SANC",   label = "Bless: Sanctuary", icon = "Interface\\Icons\\Spell_Nature_LightningShield", match = "Blessing of Sanctuary", class = "Paladin" },
	{ id = "BLESS_LIGHT",  label = "Bless: Light",     icon = "Interface\\Icons\\Spell_Holy_PrayerOfHealing02", match = "Blessing of Light",     class = "Paladin" },
	-- Added per the user's request (2026-08-27): consumable checks. No `class` field -- these are
	-- self-applied, not cast by one player onto another, so RBS_ScanBuff / the tooltip skip the
	-- "Can provide" section entirely whenever `class` is nil (see both below).
	{ id = "WELLFED", label = "Well Fed", icon = "Interface\\Icons\\INV_Misc_Food_15", match = "Well Fed" },
	-- Every vanilla flask's aura name contains the literal word "Flask" (Flask of the Titans/
	-- Distilled Wisdom/Supreme Power/Chromatic Resistance/Petrification), so one substring match
	-- catches all of them -- icon shown is Flask of the Titans' (the most common raid flask).
	{ id = "FLASK", label = "Flask", icon = "Interface\\Icons\\INV_Potion_62", match = "Flask" },
}

local function RBS_NameMatches(auraName, def)
	if def.matches then
		for i = 1, table.getn(def.matches), 1 do
			if string.find(auraName, def.matches[i], 1, true) then
				return true
			end
		end
		return false
	end
	return string.find(auraName, def.match, 1, true) ~= nil
end

------------------------------------------------------------------------------------------------------
-- BUFF SCANNING -- mirrors pfUI's own GetUnbuffedRoster (api/api.lua) and buff.lua's Shift-hover
-- "who's missing this" tooltip exactly: the user found and confirmed that feature live in-game
-- (Shift-hover over the minimap buffs shows who's missing that buff), and it's built on the exact
-- same C_UnitAuras.GetAuraDataByIndex call.
--
-- REWRITTEN (2026-08-27) to match pfUI's flat, single-function, no-caching shape after the earlier
-- multi-function design (a separate scan-one-unit helper filling shared missing/provider tables
-- passed through pcall, then a further pass copying that into each icon's fields for the tooltip
-- to read later) hit a real, reproducible bug on this client: a plain local's value written by one
-- top-level function was not reliably visible to a sibling top-level function reading the same
-- local, even though nothing else could run in between. Collapsing the whole scan into ONE
-- function with a closure nested INSIDE it -- the same shape as pfUI's own working `check(unit)`
-- helper inside GetUnbuffedRoster -- sidesteps that bug class entirely instead of working around
-- it piecemeal, and the result is computed fresh on every call instead of cached across functions.
local function RBS_ScanBuff(def)
	local missing = {}
	local providers = {}

	local function checkUnit(unit)
		if not UnitExists(unit) then
			return
		end
		local name = UnitName(unit) or unit

		local okClass, class = pcall(UnitClass, unit)
		if def.class and okClass and class == def.class then
			table.insert(providers, name)
		end

		local has = false
		local index = 1
		while true do
			local ok, aura = pcall(C_UnitAuras.GetAuraDataByIndex, unit, index, "HELPFUL")
			if not ok or not aura then
				break
			end
			if aura.name and RBS_NameMatches(aura.name, def) then
				has = true
				break
			end
			index = index + 1
		end
		if not has then
			table.insert(missing, name)
		end
	end

	if GetNumRaidMembers() > 0 then
		for i = 1, GetNumRaidMembers(), 1 do
			checkUnit("raid" .. i)
		end
	else
		checkUnit("player")
		for i = 1, GetNumPartyMembers(), 1 do
			checkUnit("party" .. i)
		end
	end

	return missing, providers
end

local function RBS_JoinNames(list)
	if table.getn(list) == 0 then
		return "(none)"
	end
	local out = list[1]
	for i = 2, table.getn(list), 1 do
		out = out .. ", " .. list[i]
	end
	return out
end

------------------------------------------------------------------------------------------------------
-- SOULSTONE TRACKING -- special-cased (see RBS_BUFF_LIST's "SOULSTONE" entry): this isn't a buff
-- everyone should have, so it doesn't use RBS_ScanBuff's "missing" semantics. Shows who currently
-- carries an active Soulstone, and which raid Warlocks are free vs. on this addon's own approximate
-- cooldown.
--
-- CONFIRMED limitation (discussed with the user, 2026-08-29): WoW never exposes another player's
-- spell cooldowns through any API on any client -- a hard Blizzard restriction, not specific to this
-- client. Casting Soulstone also leaves no self-buff on the WARLOCK that could be scanned to infer
-- cooldown state. What IS detectable: (1) who currently carries an active Soulstone (ordinary aura
-- scanning, same as every other tracked buff), and (2) the MOMENT a Soulstone newly appears on
-- someone (comparing this scan's state to the previous one) -- combined with the aura tooltip's
-- "Cast by" line (confirmed present on this client for at least Fortitude, via pfUI's own action-bar
-- tooltip) to identify which warlock cast it, this lets the addon start its OWN 30-minute cooldown
-- timer for that warlock. This is an approximation, not a real cooldown read: a Soulstone already
-- active before this addon started watching (login, /reload, or before the target was in your group)
-- has no detectable "moment of cast", so that warlock reads as available until the next cast this
-- addon actually witnesses.
local RBS_SOULSTONE_COOLDOWN_SECONDS = 30 * 60
local RBS_SoulstoneHadIt = {}         -- [name] = true/false, this unit's state as of the last scan
local RBS_SoulstoneCooldownUntil = {} -- [warlockName] = GetTime() value when their cooldown ends

-- Hidden scanning tooltip, used ONLY for this one case -- C_UnitAuras.GetAuraDataByIndex (used
-- everywhere else in this addon) doesn't expose a caster name on this client, but a real GameTooltip
-- fed the same aura does show a "Cast by: <name>" line.
local RBS_SoulstoneTip = nil
local function RBS_SoulstoneTipCaster(unit, index)
	if not RBS_SoulstoneTip then
		RBS_SoulstoneTip = CreateFrame("GameTooltip", "RaidBuffStatusSoulstoneTip", nil, "GameTooltipTemplate")
		RBS_SoulstoneTip:SetOwner(WorldFrame, "ANCHOR_NONE")
	end
	RBS_SoulstoneTip:ClearLines()
	RBS_SoulstoneTip:SetUnitBuff(unit, index)
	for i = 1, 8, 1 do
		local line = getglobal("RaidBuffStatusSoulstoneTipTextLeft" .. i)
		if not line then
			break
		end
		local text = line:GetText()
		if text and string.find(text, "Cast by: ", 1, true) then
			return string.sub(text, string.len("Cast by: ") + 1)
		end
	end
	return nil
end

-- Returns: holders (names currently carrying an active Soulstone), warlocks (one entry per raid/
-- party Warlock: { name = ..., remaining = secondsLeftOnCooldown (0 if available) }).
local function RBS_ScanSoulstone()
	local holders = {}
	local warlocks = {}

	local function checkUnit(unit)
		if not UnitExists(unit) then
			return
		end
		local name = UnitName(unit) or unit

		local okClass, class = pcall(UnitClass, unit)
		if okClass and class == "Warlock" then
			local until_ = RBS_SoulstoneCooldownUntil[name]
			local remaining = 0
			if until_ then
				remaining = until_ - GetTime()
				if remaining < 0 then
					remaining = 0
				end
			end
			table.insert(warlocks, { name = name, remaining = remaining })
		end

		local hasIt = false
		local castByIndex = nil
		local index = 1
		while true do
			local ok, aura = pcall(C_UnitAuras.GetAuraDataByIndex, unit, index, "HELPFUL")
			if not ok or not aura then
				break
			end
			if aura.name and string.find(aura.name, "Soulstone Resurrection", 1, true) then
				hasIt = true
				castByIndex = index
				break
			end
			index = index + 1
		end

		if hasIt then
			table.insert(holders, name)
		end

		-- Transition detection: only start a cooldown if this is a NEW appearance since last scan.
		if hasIt and RBS_SoulstoneHadIt[name] == false and castByIndex then
			local okCaster, caster = pcall(RBS_SoulstoneTipCaster, unit, castByIndex)
			if okCaster and caster and caster ~= "" then
				RBS_SoulstoneCooldownUntil[caster] = GetTime() + RBS_SOULSTONE_COOLDOWN_SECONDS
			end
		end
		RBS_SoulstoneHadIt[name] = hasIt
	end

	if GetNumRaidMembers() > 0 then
		for i = 1, GetNumRaidMembers(), 1 do
			checkUnit("raid" .. i)
		end
	else
		checkUnit("player")
		for i = 1, GetNumPartyMembers(), 1 do
			checkUnit("party" .. i)
		end
	end

	return holders, warlocks
end

------------------------------------------------------------------------------------------------------
-- DASHBOARD UI -- one pooled row per roster slot, a fixed header row of buff icons across the top.
------------------------------------------------------------------------------------------------------

-- Redesigned (2026-08-26) to match the real RaidBuffStatus UI the user showed screenshots of: a
-- compact row of one icon PER BUFF (not per player), each carrying a count of how many raid/party
-- members are missing it, with the actual list of names shown on hover -- not the per-player grid
-- this first draft built instead.
-- Global, not local: RaidBuffStatusOptions.lua (a separate file/chunk -- locals can never cross
-- files) reads and writes this for the "Icon size" slider, and RBS_ApplyIconSize below needs to
-- change it at runtime.
RBS_ICON_SIZE = RaidBuffStatusConfig.IconSize
local RBS_ICON_GAP = 4
-- Reverted to -22 (2026-08-26): the "count above the icon" layout that needed the extra headroom
-- was explicitly rejected by the user in favor of the count centered INSIDE the icon, which fits
-- fine in the original spacing -- this was a leftover from that rejected experiment.
local RBS_ICON_TOP = -22
-- Vertical space reserved at the bottom of the window for the "Announce" button.
local RBS_ANNOUNCE_HEIGHT = 22
-- Above this many missing names for one buff, the announce message says "Too many!" instead of
-- listing them -- keeps a single chat line readable instead of it running off past the raid chat's
-- wrap width when almost nobody has a buff (very common for Flask/Well Fed).
local RBS_ANNOUNCE_MAX_NAMES = 5

-- Plain globals, not `local` -- a diagnostic trace confirmed a plain local here was not reliably
-- visible across different top-level functions on this client (RBS_BuffIcons[b] read as nil from
-- inside RBS_UpdateDashboard while the same index read correctly from another function in the same
-- run). Globals sidestep it since they always resolve through _G.
RBS_BuffIcons = {}
RBS_HeaderBuilt = false
-- True only while the resize grip is being dragged (see RBS_OnLoad/RBS_OnUpdate) -- global for the
-- same cross-function-visibility reason as the two above.
RBS_Resizing = false

-- Computed fresh on every hover via RBS_ScanBuff -- no cached fields read here at all, matching
-- pfUI's own buff.lua OnEnter (which calls GetUnbuffedRoster directly at hover time, not from a
-- periodically-refreshed cache). Shows (1) who in the group/raid can even cast this buff
-- (class-based, e.g. only Priests can throw Fortitude/Divine Spirit) and (2) who's missing it.
local function RBS_BuffIcon_OnEnter()
	GameTooltip:SetOwner(this, "ANCHOR_TOP")
	GameTooltip:AddLine(this.rbsDef.label, 1, 1, 1)

	-- Soulstone gets its own tooltip shape (who has one active + which warlocks are free/on this
	-- addon's approximate cooldown) instead of the normal "missing" list -- see RBS_ScanSoulstone.
	if this.rbsDef.special == "soulstone" then
		local holders, warlocks = RBS_ScanSoulstone()

		GameTooltip:AddLine(" ")
		GameTooltip:AddLine("Has Soulstone:", 0.3, 1, 0.3)
		GameTooltip:AddLine(RBS_JoinNames(holders), 1, 1, 1)

		GameTooltip:AddLine(" ")
		GameTooltip:AddLine("Warlocks:", 0.3, 0.7, 1)
		if table.getn(warlocks) == 0 then
			GameTooltip:AddLine("(none)", 0.6, 0.6, 0.6)
		else
			for i = 1, table.getn(warlocks), 1 do
				local w = warlocks[i]
				if w.remaining > 0 then
					local mins = math.floor(w.remaining / 60)
					GameTooltip:AddLine(w.name .. " -- ~" .. mins .. "m (approx.)", 1, 0.3, 0.3)
				else
					GameTooltip:AddLine(w.name .. " -- available", 0.3, 1, 0.3)
				end
			end
		end

		GameTooltip:Show()
		return
	end

	local missing, providers = RBS_ScanBuff(this.rbsDef)

	-- No "Can provide" section for self-applied buffs (Well Fed, Flask) -- there's no class that
	-- casts those onto someone else, so the question doesn't apply.
	if this.rbsDef.class then
		GameTooltip:AddLine(" ")
		GameTooltip:AddLine("Can provide (" .. this.rbsDef.class .. "):", 0.3, 0.7, 1)
		GameTooltip:AddLine(RBS_JoinNames(providers), 1, 1, 1)
	end

	GameTooltip:AddLine(" ")
	GameTooltip:AddLine("Missing:", 1, 0.3, 0.3)
	GameTooltip:AddLine(RBS_JoinNames(missing), 1, 1, 1)

	GameTooltip:Show()
end

local function RBS_BuffIcon_OnLeave()
	GameTooltip:Hide()
end

-- Builds one icon. Kept as its own function so it can be pcall-wrapped per icon below -- a single
-- icon erroring (bad texture path, whatever) used to abort the WHOLE header loop, and since
-- RBS_HeaderBuilt was already set to true before the loop started, it never got a chance to retry,
-- leaving every icon AFTER the failing one permanently nil -- confirmed in-game (2026-08-26):
-- repeated "attempt to index local 'btn' (a nil value)" for the rest of the session. One bad icon
-- must not be able to take the other six down with it.
local function RBS_BuildOneIcon(i)
	local def = RBS_BUFF_LIST[i]
	local btn = CreateFrame("Button", nil, RaidBuffStatusFrame)
	btn:SetWidth(RBS_ICON_SIZE)
	btn:SetHeight(RBS_ICON_SIZE)
	-- Position is set by RBS_ReflowIcons right after all icons are built, not here -- it depends on
	-- the frame's current width (for wrapping), which can also change later via the resize grip.

	local tex = btn:CreateTexture(nil, "ARTWORK")
	tex:SetAllPoints(btn)
	tex:SetTexture(def.icon)

	-- OUTLINE on top of the GameFontNormal template's own font/size (2026-08-27) -- the earlier
	-- suspicion that this broke the count's visibility was wrong; the real cause (confirmed via
	-- /rbs debug) was that RBS_BuffIcons[i] wasn't being set at all during OnLoad's build pass (see
	-- RBS_NeedsHeaderBuild). Now that that's fixed, the outline is safe to re-add -- needed because
	-- plain red/green text alone wasn't legible against every icon's own colors.
	local count = btn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	local countFont, countSize = count:GetFont()
	count:SetFont(countFont, countSize, "OUTLINE")
	count:SetPoint("CENTER", btn, "CENTER", 0, 0)
	btn.rbsCount = count
	btn.rbsDef = def

	btn:SetScript("OnEnter", RBS_BuffIcon_OnEnter)
	btn:SetScript("OnLeave", RBS_BuffIcon_OnLeave)

	RBS_BuffIcons[i] = btn
end

-- Repositions every built icon into a grid that wraps to fit the frame's CURRENT width -- does NOT
-- touch the frame's height. Split out from RBS_ReflowIcons (2026-08-27) because forcing the height
-- back to its exact computed value on every single frame WHILE dragging fought the user's own drag
-- for vertical size, making it feel like only horizontal resizing worked at all. This one is safe
-- to call continuously during a live drag; RBS_ReflowIcons (below) is for when the frame should
-- actually snap to fit, i.e. on mouse-up.
local function RBS_PositionIcons()
	local buffCount = table.getn(RBS_BUFF_LIST)
	local frameWidth = RaidBuffStatusFrame:GetWidth()
	local perRow = math.floor((frameWidth - 16 + RBS_ICON_GAP) / (RBS_ICON_SIZE + RBS_ICON_GAP))
	if perRow < 1 then
		perRow = 1
	end
	local rows = math.ceil(buffCount / perRow)

	for i = 1, buffCount, 1 do
		local btn = RBS_BuffIcons[i]
		if btn then
			local col = math.mod(i - 1, perRow)
			local row = math.floor((i - 1) / perRow)

			-- Centered (2026-08-27, per the user), not left-aligned -- and centered PER ROW on that
			-- row's own actual icon count, not the full per-row capacity: the earlier version always
			-- used `perRow` for the row's width, so a row with fewer icons than that (a ragged last
			-- row, or the only row when the window is wider than all icons need) still centered
			-- against a wider "phantom" row width, landing right back at the same look as
			-- left-aligned. This matches how "Center" alignment treats a short last line in a word
			-- processor -- each line centers on its own content.
			local iconsThisRow = perRow
			if row == rows - 1 then
				local remainder = math.mod(buffCount, perRow)
				if remainder > 0 then
					iconsThisRow = remainder
				end
			end
			local rowWidth = iconsThisRow * RBS_ICON_SIZE + (iconsThisRow - 1) * RBS_ICON_GAP
			local startX = (frameWidth - rowWidth) / 2

			btn:ClearAllPoints()
			btn:SetPoint(
				"TOPLEFT", RaidBuffStatusFrame, "TOPLEFT",
				startX + col * (RBS_ICON_SIZE + RBS_ICON_GAP),
				RBS_ICON_TOP - row * (RBS_ICON_SIZE + RBS_ICON_GAP)
			)
		end
	end

	return perRow
end

-- Repositions icons (see RBS_PositionIcons above) AND snaps the frame's height to fit however many
-- rows that took. Called once after the icons are first built, and again on resize-grip release --
-- "the frame snaps to an exact grid fit on release", matching Holyward's own tracker-grip comment.
local function RBS_ReflowIcons()
	local buffCount = table.getn(RBS_BUFF_LIST)
	local perRow = RBS_PositionIcons()
	local rows = math.ceil(buffCount / perRow)
	RaidBuffStatusFrame:SetHeight(RBS_ICON_TOP * -1 + rows * (RBS_ICON_SIZE + RBS_ICON_GAP) + 10 + RBS_ANNOUNCE_HEIGHT)
end

-- Called from the options window's "Icon size" slider (RaidBuffStatusOptions.lua). Global since
-- that's a separate file/chunk. Existing icon buttons were already sized at build time, so those
-- need an explicit SetWidth/SetHeight here -- changing RBS_ICON_SIZE alone wouldn't resize them.
function RBS_ApplyIconSize(newSize)
	RBS_ICON_SIZE = newSize
	RaidBuffStatusConfig.IconSize = newSize
	for i = 1, table.getn(RBS_BUFF_LIST), 1 do
		local btn = RBS_BuffIcons[i]
		if btn then
			btn:SetWidth(newSize)
			btn:SetHeight(newSize)
		end
	end
	RaidBuffStatusFrame:SetMinResize(RBS_ICON_SIZE + 16, RBS_ICON_TOP * -1 + RBS_ICON_SIZE + 10 + RBS_ANNOUNCE_HEIGHT)
	RaidBuffStatusFrame:SetMaxResize(16 + table.getn(RBS_BUFF_LIST) * (RBS_ICON_SIZE + RBS_ICON_GAP), 600)
	RBS_ReflowIcons()
end

-- Fires on the frame's native OnSizeChanged event (see the .xml) -- this is what actually keeps
-- the icon grid in sync with the window's real size while/after dragging the resize grip. Far more
-- reliable than polling GetWidth() on a timer: this only runs exactly when the engine says the
-- size genuinely changed, for ANY reason (drag, or a direct SetWidth/SetHeight call).
function RBS_OnSizeChanged()
	RBS_ReflowIcons()
end

-- Posts, for every buff currently missing at least one person, one line to raid/party chat (or
-- just the local chat window if solo) listing who's missing it -- e.g. "Fortitude = Nydeh". A buff
-- nobody is missing is skipped entirely rather than announcing "(nobody)" as spam.
local function RBS_AnnounceMissing()
	local channel = nil
	if GetNumRaidMembers() > 0 then
		channel = "RAID"
	elseif GetNumPartyMembers() > 0 then
		channel = "PARTY"
	end

	for b = 1, table.getn(RBS_BUFF_LIST), 1 do
		local def = RBS_BUFF_LIST[b]
		local missing = RBS_ScanBuff(def)
		local missingCount = table.getn(missing)
		if missingCount > 0 then
			local list
			if missingCount > RBS_ANNOUNCE_MAX_NAMES then
				list = "Too many!"
			else
				list = RBS_JoinNames(missing)
			end
			local line = def.label .. " = " .. list
			if channel then
				SendChatMessage(line, channel)
			else
				DEFAULT_CHAT_FRAME:AddMessage("|cFF00CCFFRaidBuffStatus:|r " .. line)
			end
		end
	end
end

local function RBS_BuildAnnounceButton()
	local btn = CreateFrame("Button", nil, RaidBuffStatusFrame)
	btn:EnableMouse(true)
	btn:SetHeight(RBS_ANNOUNCE_HEIGHT - 4)
	-- Left edge leaves room for the resize grip, which now lives in the BOTTOMLEFT corner (matching
	-- Holyward's own proven pattern) instead of the bottom-right.
	btn:SetPoint("BOTTOMLEFT", RaidBuffStatusFrame, "BOTTOMLEFT", 20, 4)
	btn:SetPoint("BOTTOMRIGHT", RaidBuffStatusFrame, "BOTTOMRIGHT", -6, 4)

	-- WHITE8X8-tinted flat button, same trick used elsewhere in this addon/CLAUDE.md's established
	-- pattern for a self-contained skin that doesn't depend on any other addon being installed.
	local bg = btn:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints(btn)
	bg:SetTexture("Interface\\Buttons\\WHITE8X8")
	bg:SetVertexColor(0.15, 0.15, 0.15, 1)

	local label = btn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	label:SetPoint("CENTER", btn, "CENTER", 0, 0)
	label:SetText("Announce")

	btn:SetScript("OnClick", RBS_AnnounceMissing)
	btn:SetScript("OnEnter", function()
		bg:SetVertexColor(0.3, 0.3, 0.3, 1)
	end)
	btn:SetScript("OnLeave", function()
		bg:SetVertexColor(0.15, 0.15, 0.15, 1)
	end)
end

local function RBS_BuildHeader()
	if RBS_HeaderBuilt then
		return
	end
	RBS_HeaderBuilt = true
	for i = 1, table.getn(RBS_BUFF_LIST), 1 do
		local ok, err = pcall(RBS_BuildOneIcon, i)
		if not ok then
			DEFAULT_CHAT_FRAME:AddMessage(
				"|cFF00CCFFRaidBuffStatus:|r |cFFFF0000error building icon " .. i .. ":|r " .. tostring(err)
			)
		end
	end
	RBS_BuildAnnounceButton()
	RBS_ReflowIcons()
end

-- Renamed from RaidBuffStatus_OnLoad/OnUpdate/UpdateDashboard (2026-08-27) to the addon-specific
-- RBS_ prefix as part of chasing the local-visibility bug described above.
--
-- Just refreshes each icon's missing-count number via RBS_ScanBuff -- the tooltip (RBS_BuffIcon_OnEnter)
-- computes its own fresh answer independently on hover, so this loop doesn't need to hand anything
-- to it.
function RBS_UpdateDashboard()
	for b = 1, table.getn(RBS_BUFF_LIST), 1 do
		local btn = RBS_BuffIcons[b]
		if btn then
			local def = RBS_BUFF_LIST[b]
			if def.special == "soulstone" then
				-- Count here is "warlocks currently available" (green if any, red if none) rather
				-- than a missing-count -- this call is also what drives the transition detection in
				-- RBS_ScanSoulstone, so it needs to run periodically even if nobody hovers the icon.
				local _, warlocks = RBS_ScanSoulstone()
				local available = 0
				for w = 1, table.getn(warlocks), 1 do
					if warlocks[w].remaining <= 0 then
						available = available + 1
					end
				end
				btn.rbsCount:SetText(tostring(available))
				if available > 0 then
					btn.rbsCount:SetTextColor(0.3, 1, 0.3)
				else
					btn.rbsCount:SetTextColor(1, 0.3, 0.3)
				end
			else
				local missing = RBS_ScanBuff(def)
				local missingCount = table.getn(missing)
				-- Explicit tostring() (2026-08-26): the number wasn't appearing at all with a raw
				-- number passed straight to SetText -- forcing a string conversion first fixed it.
				btn.rbsCount:SetText(tostring(missingCount))
				if missingCount > 0 then
					btn.rbsCount:SetTextColor(1, 0.3, 0.3)
				else
					btn.rbsCount:SetTextColor(0.3, 1, 0.3)
				end
			end
		end
	end
end

------------------------------------------------------------------------------------------------------
-- AUTO-INVITE (ported from Holyward's own Options -> General feature, same keyword whitelist)
------------------------------------------------------------------------------------------------------

-- Whispers whose whole (trimmed, lowercased) text matches one of these exactly trigger an invite --
-- an exact match, not "contains", so a real sentence that happens to include one of these words
-- ("I'm invited to...") doesn't trigger an invite by accident.
local RBS_AUTOINVITE_KEYWORDS = { ["inv"] = true, ["invite"] = true, ["123"] = true }

------------------------------------------------------------------------------------------------------
-- TAUNT WARNINGS (per the user's request, 2026-08-29 -- self-taunt-resist only for now)
------------------------------------------------------------------------------------------------------

-- COMBAT_LOG_EVENT_UNFILTERED is confirmed present on this client, firing with the classic/TBC-era
-- POSITIONAL-ARG signature (arg1=timestamp, arg2=subevent, arg3=sourceGUID, arg4=sourceName,
-- arg5=sourceFlags, arg6=destGUID, arg7=destName, arg8=destFlags, arg9=spellId, arg10=spellName,
-- arg11=spellSchool, then subevent-specific extras from arg12 on) -- NOT the modern
-- CombatLogGetCurrentEventInfo() table style. Confirmed via ShaguTweaks' own libpredict.lua, which
-- already reads arg2/arg4/arg10/arg12/arg13 successfully for a SPELL_HEAL subevent on this exact
-- client. What's NOT independently confirmed here yet is the exact subevent name and extra-arg
-- position for a MISSED cast specifically (expected: arg2 == "SPELL_MISSED", arg12 == the miss type
-- string "RESIST"/"IMMUNE"/etc, based on Blizzard's historical combat log layout) -- RBS_TauntDebug
-- prints the raw args for every "Taunt"-named event so this can be corrected from real testing if
-- the warning itself doesn't fire. Toggle with "/rbs tauntdebug".
RBS_TauntDebug = false

local RBS_MISS_PHRASES = {
	RESIST = "was resisted",
	IMMUNE = "failed -- target is immune",
	MISS = "missed",
	DODGE = "was dodged",
	PARRY = "was parried",
	EVADE = "was evaded",
}

local function RBS_OnCombatLog()
	if not (arg10 and string.find(arg10, "Taunt", 1, true) and arg4 == UnitName("player")) then
		return
	end

	if RBS_TauntDebug then
		DEFAULT_CHAT_FRAME:AddMessage(
			"|cFF00CCFFRaidBuffStatus taunt debug:|r arg2=" .. tostring(arg2) .. " arg4=" .. tostring(arg4)
				.. " arg7=" .. tostring(arg7) .. " arg9=" .. tostring(arg9) .. " arg10=" .. tostring(arg10)
				.. " arg11=" .. tostring(arg11) .. " arg12=" .. tostring(arg12) .. " arg13=" .. tostring(arg13)
		)
	end

	if arg2 == "SPELL_MISSED" and RaidBuffStatusConfig.TauntWarnings then
		local missType = arg12 or "?"
		local phrase = RBS_MISS_PHRASES[missType] or ("failed (" .. tostring(missType) .. ")")
		local msg = "Your Taunt " .. phrase .. " on " .. tostring(arg7 or "target") .. "!"
		RaidNotice_AddMessage(RaidWarningFrame, msg, ChatTypeInfo["RAID_WARNING"])
		PlaySound("RaidWarning")
	end
end

-- SetScript("OnEvent", ...) handler -- no parameters declared, reads `event`/`arg1`/`arg2`/etc as the
-- engine-supplied globals directly, per this client's convention.
function RBS_OnEvent()
	if event == "CHAT_MSG_WHISPER" then
		if RaidBuffStatusConfig.AutoInvite and arg1 and arg2 then
			local trimmed = string.gsub(string.lower(arg1), "^%s*(.-)%s*$", "%1")
			if RBS_AUTOINVITE_KEYWORDS[trimmed] then
				InviteByName(arg2)
			end
		end
	elseif event == "COMBAT_LOG_EVENT_UNFILTERED" then
		RBS_OnCombatLog()
	end
end

------------------------------------------------------------------------------------------------------
-- DEATH WARNINGS (per the user's request, 2026-08-29): a big on-screen banner + sound + raid chat
-- message when a raid/party member dies. Detected the same way as everything else in this addon --
-- comparing each member's UnitIsDeadOrGhost state to the previous scan and acting on the
-- alive -> dead transition, rather than combat-log parsing.
------------------------------------------------------------------------------------------------------

local RBS_DeathState = {} -- [name] = true (dead) / false (alive), last-seen state

local function RBS_CheckDeaths()
	if not RaidBuffStatusConfig.DeathWarnings then
		return
	end

	local roster = {}
	local inRaid = GetNumRaidMembers() > 0
	if inRaid then
		for i = 1, GetNumRaidMembers(), 1 do
			table.insert(roster, "raid" .. i)
		end
	else
		table.insert(roster, "player")
		for i = 1, GetNumPartyMembers(), 1 do
			table.insert(roster, "party" .. i)
		end
	end

	for i = 1, table.getn(roster), 1 do
		local unit = roster[i]
		if UnitExists(unit) then
			local name = UnitName(unit)
			if name then
				local isDead = UnitIsDeadOrGhost(unit) and true or false
				-- State is recorded BEFORE attempting the announcement, and the announcement itself
				-- is pcall-wrapped -- confirmed live (2026-08-29): RaidNotice_AddMessage doesn't
				-- exist on this client, and because that error unwound the whole function before
				-- reaching this state update, RBS_DeathState[name] never advanced past false, so the
				-- SAME death kept re-triggering (and re-erroring) on every 1-second check forever. A
				-- failed announcement must never be able to jam the death-transition tracking itself.
				local justDied = isDead and RBS_DeathState[name] == false
				RBS_DeathState[name] = isDead
				if justDied then
					local msg = name .. " has died!"
					-- UIErrorsFrame is the small red on-screen error text, universally present on
					-- this client (unlike RaidWarningFrame/RaidNotice_AddMessage, confirmed absent).
					local ok, err = pcall(UIErrorsFrame.AddMessage, UIErrorsFrame, msg, 1, 0.2, 0.2, 1, 6)
					if not ok then
						DEFAULT_CHAT_FRAME:AddMessage(
							"|cFF00CCFFRaidBuffStatus:|r |cFFFF0000death warning display failed:|r " .. tostring(err)
						)
					end
					pcall(PlaySound, "RaidWarning")
					if inRaid then
						pcall(SendChatMessage, msg, "RAID")
					elseif GetNumPartyMembers() > 0 then
						pcall(SendChatMessage, msg, "PARTY")
					end
				end
			end
		end
	end
end

------------------------------------------------------------------------------------------------------
-- LOAD / UPDATE / SLASH COMMAND
------------------------------------------------------------------------------------------------------

function RBS_OnLoad()
	this:RegisterForDrag("LeftButton")
	this:RegisterEvent("CHAT_MSG_WHISPER")
	this:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
	-- CONFIRMED via Holyward's own tracker-resize grip (Holyward.lua, proven working on this exact
	-- client): the XML `resizable="true"` attribute alone was NOT enough there either -- an explicit
	-- SetResizable(true) call is what actually flags the frame resizable on this client.
	this:SetResizable(true)
	this:SetMinResize(RBS_ICON_SIZE + 16, RBS_ICON_TOP * -1 + RBS_ICON_SIZE + 10 + RBS_ANNOUNCE_HEIGHT)
	this:SetMaxResize(16 + table.getn(RBS_BUFF_LIST) * (RBS_ICON_SIZE + RBS_ICON_GAP), 600)
	-- DEFERRED (2026-08-27): confirmed via /rbs debug that calling RBS_BuildHeader() synchronously
	-- here, during OnLoad's own execution, builds every icon visually (textures/positions all
	-- correct) but the final `RBS_BuffIcons[i] = btn` inside RBS_BuildOneIcon does not persist --
	-- RBS_BuffIcons read back as nil for every single index right after. Re-running the exact same
	-- pcall(RBS_BuildOneIcon, i) call LATER, triggered by a slash command instead of by OnLoad,
	-- worked immediately. Deferring the real build to the first RBS_OnUpdate tick sidesteps
	-- whatever is different about writing to this table during the OnLoad/ADDON_LOADED phase itself.
	RBS_NeedsHeaderBuild = true

	-- Resize grip -- manual cursor-tracking resize (2026-08-27), NOT native StartSizing/
	-- StopMovingOrSizing. Confirmed broken on this client: with StartSizing("BOTTOMRIGHT") only
	-- height ever changed; switching to StartSizing("BOTTOMLEFT") (Holyward's own corner) flipped it
	-- to only WIDTH ever changing -- neither corner let both dimensions resize together, so the
	-- native API itself is unreliable here, not just the choice of corner. This tracks the cursor
	-- directly instead: on mouse-down, the frame is re-anchored by its TOPRIGHT corner (a fixed
	-- screen position, replacing its original CENTER anchor) so growing/shrinking extends from the
	-- BOTTOM-LEFT where this grip sits; each frame while dragging, the new width/height are computed
	-- straight from how far the cursor has moved and clamped to sane bounds, then applied directly.
	local grip = CreateFrame("Button", nil, RaidBuffStatusFrame)
	grip:SetFrameLevel(RaidBuffStatusFrame:GetFrameLevel() + 5)
	grip:EnableMouse(true)
	grip:SetWidth(14)
	grip:SetHeight(14)
	grip:SetPoint("BOTTOMLEFT", RaidBuffStatusFrame, "BOTTOMLEFT", 2, 2)
	local gripTex = grip:CreateTexture(nil, "OVERLAY")
	gripTex:SetAllPoints(grip)
	gripTex:SetTexture("Interface\\Buttons\\WHITE8X8")
	gripTex:SetVertexColor(1, 1, 1, 0.35)
	grip:SetScript("OnMouseDown", function()
		RBS_Resizing = true
		local right = RaidBuffStatusFrame:GetRight()
		local top = RaidBuffStatusFrame:GetTop()
		RaidBuffStatusFrame:ClearAllPoints()
		RaidBuffStatusFrame:SetPoint("TOPRIGHT", UIParent, "BOTTOMLEFT", right, top)
		local scale = UIParent:GetEffectiveScale()
		local cx, cy = GetCursorPosition()
		RBS_ResizeCursorX = cx / scale
		RBS_ResizeCursorY = cy / scale
		RBS_ResizeStartWidth = RaidBuffStatusFrame:GetWidth()
		RBS_ResizeStartHeight = RaidBuffStatusFrame:GetHeight()
	end)
	grip:SetScript("OnMouseUp", function()
		RBS_Resizing = false
		RBS_ReflowIcons()
	end)

	SLASH_RAIDBUFFSTATUS1 = "/raidbuffstatus"
	SLASH_RAIDBUFFSTATUS2 = "/rbs"
	-- "/rbs debug" dumps a fresh RBS_ScanBuff() result per buff straight to chat.
	-- "/rbs options" (or "/rbs config") opens the AceConfig settings window (RaidBuffStatusOptions.lua).
	SlashCmdList["RAIDBUFFSTATUS"] = function(msg)
		if msg == "options" or msg == "config" then
			RaidBuffStatus_ShowOptions()
			return
		end
		if msg == "tauntdebug" then
			RBS_TauntDebug = not RBS_TauntDebug
			DEFAULT_CHAT_FRAME:AddMessage(
				"|cFF00CCFFRaidBuffStatus:|r Taunt debug " .. (RBS_TauntDebug and "ON -- taunt something and watch chat." or "off.")
			)
			return
		end
		if msg == "debug" then
			for b = 1, table.getn(RBS_BUFF_LIST), 1 do
				local def = RBS_BUFF_LIST[b]
				local missing, providers = RBS_ScanBuff(def)
				DEFAULT_CHAT_FRAME:AddMessage(
					"  " .. def.label .. " -- providers: " .. RBS_JoinNames(providers)
						.. " | missing: " .. RBS_JoinNames(missing)
				)
			end

			-- Forces RBS_UpdateDashboard right now (bypasses the 2s OnUpdate throttle entirely) and
			-- reports the raw state of icon 1's count FontString -- this checks whether the periodic
			-- update path even runs and whether SetText/visibility are actually taking effect,
			-- without depending on OnUpdate's own timing.
			RBS_UpdateDashboard()
			local nilCount, okCount = 0, 0
			for b = 1, table.getn(RBS_BUFF_LIST), 1 do
				if RBS_BuffIcons[b] then
					okCount = okCount + 1
				else
					nilCount = nilCount + 1
				end
			end
			DEFAULT_CHAT_FRAME:AddMessage("  [trace] RBS_BuffIcons: " .. okCount .. " ok, " .. nilCount .. " nil (of " .. table.getn(RBS_BUFF_LIST) .. ")")

			-- Re-run icon 1's build in isolation to surface whatever error pcall swallowed the
			-- first time (RBS_BuildHeader's own error message may have scrolled past at load time).
			local ok1, err1 = pcall(RBS_BuildOneIcon, 1)
			DEFAULT_CHAT_FRAME:AddMessage("  [trace] rebuild icon1: ok=" .. tostring(ok1) .. " err=" .. tostring(err1))
			return
		end

		RaidBuffStatusConfig.Enabled = not RaidBuffStatusConfig.Enabled
		if RaidBuffStatusConfig.Enabled then
			RaidBuffStatusFrame:Show()
		else
			RaidBuffStatusFrame:Hide()
		end
		DEFAULT_CHAT_FRAME:AddMessage(
			"|cFF00CCFFRaidBuffStatus:|r " .. (RaidBuffStatusConfig.Enabled and "Shown." or "Hidden.")
		)
	end

	if not RaidBuffStatusConfig.Enabled then
		RaidBuffStatusFrame:Hide()
	end

	DEFAULT_CHAT_FRAME:AddMessage("|cFF00CCFFRaidBuffStatus:|r Loaded (build " .. RBS_BUILD .. "). /rbs to toggle, /rbs options for settings, /rbs debug to diagnose.")
end

local RBS_LastScan = 0
local RBS_SCAN_INTERVAL = 2
local RBS_LastDeathCheck = 0
local RBS_DEATH_CHECK_INTERVAL = 1

function RBS_OnUpdate()
	-- Deferred icon build (see RBS_OnLoad) -- runs exactly once, on the very first tick.
	if RBS_NeedsHeaderBuild then
		RBS_NeedsHeaderBuild = false
		RBS_BuildHeader()
	end

	-- Manual resize while dragging the grip (see RBS_OnLoad) -- computes the new size directly from
	-- how far the cursor has moved since mouse-down and applies it every frame, then repositions
	-- icons to match (RBS_PositionIcons; height is intentionally left as computed here rather than
	-- re-snapped to the icon grid's exact fit until release, so the user's own drag stays in control
	-- while it's happening -- RBS_OnLoad's grip OnMouseUp does the exact-fit snap once it ends).
	if RBS_Resizing then
		local scale = UIParent:GetEffectiveScale()
		local cx, cy = GetCursorPosition()
		cx = cx / scale
		cy = cy / scale

		local newWidth = RBS_ResizeStartWidth + (RBS_ResizeCursorX - cx)
		local newHeight = RBS_ResizeStartHeight + (RBS_ResizeCursorY - cy)

		local minWidth = RBS_ICON_SIZE + 16
		local maxWidth = 16 + table.getn(RBS_BUFF_LIST) * (RBS_ICON_SIZE + RBS_ICON_GAP)
		local minHeight = RBS_ICON_TOP * -1 + RBS_ICON_SIZE + 10 + RBS_ANNOUNCE_HEIGHT
		local maxHeight = 600

		if newWidth < minWidth then
			newWidth = minWidth
		elseif newWidth > maxWidth then
			newWidth = maxWidth
		end
		if newHeight < minHeight then
			newHeight = minHeight
		elseif newHeight > maxHeight then
			newHeight = maxHeight
		end

		RaidBuffStatusFrame:SetWidth(newWidth)
		RaidBuffStatusFrame:SetHeight(newHeight)
		RBS_PositionIcons()
	end

	-- Independent of RaidBuffStatusConfig.Enabled (that only controls the window's visibility) --
	-- death warnings are a standalone raid-utility feature, checked on its own faster interval since
	-- responsiveness matters more here than for the buff counts.
	local curTime = GetTime()
	if (curTime - RBS_LastDeathCheck) >= RBS_DEATH_CHECK_INTERVAL then
		RBS_LastDeathCheck = curTime
		RBS_CheckDeaths()
	end

	if not RaidBuffStatusConfig.Enabled then
		return
	end
	if (curTime - RBS_LastScan) < RBS_SCAN_INTERVAL then
		return
	end
	RBS_LastScan = curTime
	RBS_UpdateDashboard()
end
