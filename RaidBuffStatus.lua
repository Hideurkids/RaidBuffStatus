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
RaidBuffStatusConfig.CDEnabled = RaidBuffStatusConfig.CDEnabled or false
RaidBuffStatusConfig.CDIconSize = RaidBuffStatusConfig.CDIconSize or 20
if RaidBuffStatusConfig.CDShowLabels == nil then
	RaidBuffStatusConfig.CDShowLabels = true
end
RaidBuffStatusConfig.MockingBlowAnnounce = RaidBuffStatusConfig.MockingBlowAnnounce or false
RaidBuffStatusConfig.AutoRemoveSalvation = RaidBuffStatusConfig.AutoRemoveSalvation or false
-- Per the user (2026-08-31): kept as its own independent option rather than bundled into a single
-- umbrella "mode" switch, same as MockingBlowAnnounce/AutoRemoveSalvation above.
RaidBuffStatusConfig.FightStartMisses = RaidBuffStatusConfig.FightStartMisses or false
RaidBuffStatusConfig.FightStartMissesDuration = RaidBuffStatusConfig.FightStartMissesDuration or 8

-- Persisted debug trace (2026-08-31): every RBS_XXXDebug print (CD debug, Soulstone debug, taunt
-- debug, /rbs auradump) ALSO goes here, not just to chat -- this table lives inside
-- RaidBuffStatusConfig, so it gets written to disk (SavedVariables) at the next logout/reload, at
-- which point it can be read directly from the .lua file on disk without needing the user to
-- screenshot or paste live chat output. Capped (RBS_LogDebug below) so it can't grow forever.
RaidBuffStatusConfig.DebugLog = RaidBuffStatusConfig.DebugLog or {}
local RBS_DEBUG_LOG_MAX = 150

-- Global (not local) so every debug call site across this file can reach it regardless of
-- definition order, same reasoning as every other cross-section function here.
function RBS_LogDebug(msg)
	RaidBuffStatusConfig.DebugLog = RaidBuffStatusConfig.DebugLog or {}
	table.insert(RaidBuffStatusConfig.DebugLog, date("%H:%M:%S") .. " " .. tostring(msg))
	while table.getn(RaidBuffStatusConfig.DebugLog) > RBS_DEBUG_LOG_MAX do
		table.remove(RaidBuffStatusConfig.DebugLog, 1)
	end
end

-- Bumped on every meaningful rewrite so a load-message screenshot can confirm which build is
-- actually running, without having to ask the user to check -- also flags whether a stale/second
-- copy of this addon (e.g. a leftover install of the old reference folder reusing the same global
-- names) might be clobbering these functions after this file loads.
RBS_BUILD = "v53-persistent-debug-log"

-- CONFIRMED via real raid testing (2026-08-31): right after a disconnect/reconnect (server kick,
-- zone in, etc.), C_UnitAuras.GetAuraDataByIndex can return NOTHING for a window of several
-- seconds -- not just for other raid members, but for the LOCAL PLAYER's own buffs too (a tester's
-- own Intellect showed as "missing" on themselves, at the same moment Well Fed and Flask both
-- showed "missing: [the entire raid]" in the same /rbs debug dump -- ruling out a per-buff matching
-- bug, since three unrelated buffs all failed identically at once). This is a client data-
-- availability quirk, not something a smarter aura scan can work around. RBS_ScanSuppressUntil is a
-- GetTime() deadline set on PLAYER_ENTERING_WORLD (login, reconnect, zoning) -- every scan-driven
-- display (dashboard, tooltip, Announce, the CD tracker's aura-scan half) checks it and shows a
-- neutral "still syncing" state instead of a real (and likely wrong) scan result until it passes.
RBS_ScanSuppressUntil = 0
local RBS_SCAN_SUPPRESS_SECONDS = 8

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
--
-- SUSPECTED (2026-08-30, per the user: a warlock who used Soulstone never shows on cooldown, stays
-- "available" forever) that this "Cast by:" line only exists on THIS client when hovering a buff on
-- the LOCAL PLAYER's own tooltip -- the original confirmation for this line's existence (pfUI's
-- action-bar tooltip, Fortitude) may have only ever been tested that way. If it's simply absent when
-- scanning ANOTHER raid member's aura via SetUnitBuff on a non-"player" unit, RBS_SoulstoneTipCaster
-- silently returns nil every time and the cooldown never starts -- indistinguishable from working
-- code without seeing the raw tooltip content. RBS_SSDebug ("/rbs ssdebug") dumps every line so this
-- can be confirmed instead of guessed at.
RBS_SSDebug = false
local RBS_SoulstoneTip = nil
local function RBS_SoulstoneTipCaster(unit, index)
	if not RBS_SoulstoneTip then
		RBS_SoulstoneTip = CreateFrame("GameTooltip", "RaidBuffStatusSoulstoneTip", nil, "GameTooltipTemplate")
		RBS_SoulstoneTip:SetOwner(WorldFrame, "ANCHOR_NONE")
	end
	RBS_SoulstoneTip:ClearLines()
	RBS_SoulstoneTip:SetUnitBuff(unit, index)
	local found = nil
	for i = 1, 8, 1 do
		local line = getglobal("RaidBuffStatusSoulstoneTipTextLeft" .. i)
		if not line then
			break
		end
		local text = line:GetText()
		if RBS_SSDebug and text then
			local dbgMsg = "SS debug: line " .. i .. " = \"" .. text .. "\""
			DEFAULT_CHAT_FRAME:AddMessage("|cFF00CCFFRaidBuffStatus:|r " .. dbgMsg)
			RBS_LogDebug(dbgMsg)
		end
		if not found and text and string.find(text, "Cast by: ", 1, true) then
			found = string.sub(text, string.len("Cast by: ") + 1)
			if not RBS_SSDebug then
				return found
			end
		end
	end
	return found
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

	-- See RBS_ScanSuppressUntil's own comment (near RBS_BUILD, top of file) -- right after a
	-- reconnect, a live scan here would very likely just show a false "everyone is missing this"
	-- reading, since the client's own aura data isn't ready yet at that point.
	if GetTime() < RBS_ScanSuppressUntil then
		GameTooltip:AddLine(" ")
		GameTooltip:AddLine("Still syncing with the server -- try again in a few seconds.", 0.7, 0.7, 0.7)
		GameTooltip:Show()
		return
	end

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
	-- See RBS_ScanSuppressUntil's own comment (top of file) -- refuse to announce at all right after
	-- a reconnect, rather than blasting the whole raid with a false "everyone is missing everything"
	-- reading while the client's aura data is still catching up.
	if GetTime() < RBS_ScanSuppressUntil then
		DEFAULT_CHAT_FRAME:AddMessage(
			"|cFF00CCFFRaidBuffStatus:|r Still syncing with the server -- try Announce again in a few seconds."
		)
		return
	end

	local channel = nil
	if GetNumRaidMembers() > 0 then
		channel = "RAID"
	elseif GetNumPartyMembers() > 0 then
		channel = "PARTY"
	end

	for b = 1, table.getn(RBS_BUFF_LIST), 1 do
		local def = RBS_BUFF_LIST[b]
		if def.special == "soulstone" then
			-- Soulstone gets its own announce shape (2026-08-30, per the user): RBS_ScanBuff's
			-- ordinary "missing" semantics don't apply (not everyone is supposed to have one), but
			-- "how many warlocks are free and haven't thrown theirs yet" is genuinely useful raid
			-- info, so it gets a dedicated line instead of being skipped outright.
			local _, warlocks = RBS_ScanSoulstone()
			local availableNames = {}
			for w = 1, table.getn(warlocks), 1 do
				if warlocks[w].remaining <= 0 then
					table.insert(availableNames, warlocks[w].name)
				end
			end
			local availableCount = table.getn(availableNames)
			if availableCount > 0 then
				local list
				if availableCount > RBS_ANNOUNCE_MAX_NAMES then
					list = "Too many!"
				else
					list = RBS_JoinNames(availableNames)
				end
				local plural = ""
				if availableCount > 1 then
					plural = "s"
				end
				local line = availableCount .. " Soulstone" .. plural .. " not assigned yet: " .. list
				if channel then
					SendChatMessage(line, channel)
				else
					DEFAULT_CHAT_FRAME:AddMessage("|cFF00CCFFRaidBuffStatus:|r " .. line)
				end
			end
		else
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
	-- See RBS_ScanSuppressUntil's own comment (top of file) -- skip refreshing the missing-counts
	-- entirely right after a reconnect rather than showing a false "everyone missing" reading; the
	-- icons just keep showing whatever they last showed until real data is available again.
	if GetTime() < RBS_ScanSuppressUntil then
		return
	end
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

-- Shared by BOTH taunt-fail detection paths below (2026-08-31, per the user: "pero si las 2
-- funcionan? Van a dispararse 2 veces?") -- the combat-log path and the chat-text path are
-- redundant by design (see the chat-text path's own comment), so the SAME real taunt failure could
-- get caught by both within the same instant. A short debounce means only the first one to notice
-- actually shows the alert/plays the sound; the second one within the window is silently dropped.
local RBS_LastTauntFailAlert = 0
local RBS_TAUNT_FAIL_DEBOUNCE = 2

local function RBS_AnnounceTauntFail(target)
	local now = GetTime()
	if (now - RBS_LastTauntFailAlert) < RBS_TAUNT_FAIL_DEBOUNCE then
		return
	end
	RBS_LastTauntFailAlert = now
	local msg = "Your Taunt failed on " .. tostring(target or "target") .. "!"
	-- CONFIRMED (2026-08-29, death warnings): RaidNotice_AddMessage/RaidWarningFrame don't exist on
	-- this client -- UIErrorsFrame is the universally-present substitute.
	pcall(UIErrorsFrame.AddMessage, UIErrorsFrame, msg, 1, 0.2, 0.2, 1, 6)
	pcall(PlaySound, "RaidWarning")
end

local function RBS_OnCombatLog()
	if not (arg10 and string.find(arg10, "Taunt", 1, true) and arg4 == UnitName("player")) then
		return
	end

	if RBS_TauntDebug then
		local dbgMsg = "taunt debug: arg2=" .. tostring(arg2) .. " arg4=" .. tostring(arg4)
			.. " arg7=" .. tostring(arg7) .. " arg9=" .. tostring(arg9) .. " arg10=" .. tostring(arg10)
			.. " arg11=" .. tostring(arg11) .. " arg12=" .. tostring(arg12) .. " arg13=" .. tostring(arg13)
		DEFAULT_CHAT_FRAME:AddMessage("|cFF00CCFFRaidBuffStatus:|r " .. dbgMsg)
		RBS_LogDebug(dbgMsg)
	end

	if arg2 == "SPELL_MISSED" and RaidBuffStatusConfig.TauntWarnings then
		RBS_AnnounceTauntFail(arg7)
	end
end

-- Second, independent detection path (2026-08-31): does NOT use COMBAT_LOG_EVENT_UNFILTERED for
-- taunt-fail detection at all -- it uses the much older, universally-available
-- CHAT_MSG_SPELL_SELF_DAMAGE chat-text event and plain Lua pattern matching against confirmed real
-- game text ("Your Taunt failed. Chromatic Dragonspawn is immune." / "Your Taunt was resisted by
-- Chromatic Dragonspawn."). Given the taunt-only, COMBAT_LOG_EVENT_UNFILTERED-based path above was
-- NEVER actually confirmed to fire (taunt testing was deferred all last session), this chat-text
-- path is likely the one that actually works in practice -- kept alongside the other rather than
-- replacing it, same "redundant detection paths, whichever fires first wins" approach already used
-- for Soulstone/cooldowns.
local RBS_TAUNT_FAIL_PATTERNS = {
	"Your Taunt was resisted by (.+)",
	"(.+) is immune to your Taunt%.",
	"Your Taunt failed%. (.+) is immune%.",
	"Your Taunt missed (.+)", -- a real taunt-miss case is rare/unconfirmed -- kept anyway, harmless.
}

-- Native WoW chat icon escape sequences ({rt1}..{rt8}) -- render as the actual raid-target icon in
-- chat, universally supported, no addon-side texture work needed. Index = GetRaidTargetIndex(unit).
--
-- Deliberately PLAIN escape sequences, no |cFFxxxxxx..|r color codes -- confirmed (2026-08-31,
-- reported specifically on TurtleWoW by another addon's users) that SendChatMessage silently fails
-- to send AT ALL when the message contains a hex color code AND the target has a raid mark set.
-- Never add color codes to any string passed to SendChatMessage in this addon
-- (DEFAULT_CHAT_FRAME:AddMessage, local-only, is unaffected).
local RBS_RAID_MARK_ICONS = { "{rt1} ", "{rt2} ", "{rt3} ", "{rt4} ", "{rt5} ", "{rt6} ", "{rt7} ", "{rt8} " }

-- Mocking Blow use-announce (2026-08-31, per the user): posts to raid/party chat when you use
-- Mocking Blow, mentioning your current target's raid mark if it has one. Detects that the ability
-- was USED (not a specific hit/miss outcome) via a plain substring match on the chat text, then
-- separately reads whatever's currently targeted for the name/mark -- plus a short debounce since a
-- single Mocking Blow use can generate more than one CHAT_MSG_SPELL_SELF_DAMAGE line (its own
-- damage tick alongside any resist/miss text).
local RBS_LastMockingBlowAnnounce = 0
local RBS_MOCKING_BLOW_DEBOUNCE = 2

local function RBS_AnnounceMockingBlow()
	local now = GetTime()
	if (now - RBS_LastMockingBlowAnnounce) < RBS_MOCKING_BLOW_DEBOUNCE then
		return
	end
	RBS_LastMockingBlowAnnounce = now

	local targetName = UnitName("target") or "target"
	local markIndex = GetRaidTargetIndex("target")
	local mark = (markIndex and RBS_RAID_MARK_ICONS[markIndex]) or ""
	local msg = "Mocking Blow used on " .. mark .. targetName

	local channel = nil
	if GetNumRaidMembers() > 0 then
		channel = "RAID"
	elseif GetNumPartyMembers() > 0 then
		channel = "PARTY"
	end
	if channel then
		pcall(SendChatMessage, msg, channel)
	else
		DEFAULT_CHAT_FRAME:AddMessage("|cFF00CCFFRaidBuffStatus:|r " .. msg)
	end
end

local function RBS_OnTauntChatMsg()
	if not arg1 then
		return
	end

	if RaidBuffStatusConfig.MockingBlowAnnounce and string.find(arg1, "Mocking Blow", 1, true) then
		RBS_AnnounceMockingBlow()
	end

	for i = 1, table.getn(RBS_TAUNT_FAIL_PATTERNS), 1 do
		local _, _, target = string.find(arg1, RBS_TAUNT_FAIL_PATTERNS[i])
		if target then
			-- Strip a trailing period some of these patterns leave attached to the captured name.
			if string.find(target, "%.$") then
				target = string.sub(target, 1, string.len(target) - 1)
			end
			if RBS_TauntDebug then
				local dbgMsg = "taunt debug (chat): matched pattern " .. i .. ", target=" .. target
				DEFAULT_CHAT_FRAME:AddMessage("|cFF00CCFFRaidBuffStatus:|r " .. dbgMsg)
				RBS_LogDebug(dbgMsg)
			end
			if RaidBuffStatusConfig.TauntWarnings then
				RBS_AnnounceTauntFail(target)
			end
			return
		end
	end

	if RBS_TauntDebug and string.find(arg1, "Taunt", 1, true) then
		local dbgMsg = "taunt debug (chat): unmatched: \"" .. arg1 .. "\""
		DEFAULT_CHAT_FRAME:AddMessage("|cFF00CCFFRaidBuffStatus:|r " .. dbgMsg)
		RBS_LogDebug(dbgMsg)
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
		RBS_OnCombatLogCooldowns()
		RBS_OnCombatLogSoulstone()
	elseif event == "ADDON_LOADED" then
		if arg1 == "RaidBuffStatus" then
			RBS_OnAddonLoaded()
		end
	elseif event == "PLAYER_ENTERING_WORLD" then
		RBS_ScanSuppressUntil = GetTime() + RBS_SCAN_SUPPRESS_SECONDS
	elseif event == "CHAT_MSG_SPELL_SELF_DAMAGE" then
		RBS_OnTauntChatMsg()
	elseif event == "PLAYER_REGEN_DISABLED" then
		if RaidBuffStatusConfig.FightStartMisses then
			RBS_FightStartWindowUntil = GetTime() + (RaidBuffStatusConfig.FightStartMissesDuration or 8)
		end
	elseif event == "CHAT_MSG_COMBAT_SELF_MISSES" then
		RBS_OnCombatSelfMiss()
	end
end

------------------------------------------------------------------------------------------------------
-- TANK UTILITIES (per the user, 2026-08-31): Salvation auto-removal and an early-fight miss/dodge/
-- parry announce -- both independently toggleable, deliberately NOT bundled (along with the Mocking
-- Blow announce above) under a single umbrella "mode" switch -- the user specifically asked for
-- each function to be its own separate option.
------------------------------------------------------------------------------------------------------

-- Blessing of Salvation (1038) / Greater Blessing of Salvation (25895) -- confirmed spell IDs.
-- Reduces threat generation, which is exactly what a tank does NOT want, so this cancels it the
-- moment it's found on the local player. Deliberately does NOT gate on stance/talents first
-- (Defensive Stance, Bear Form, Righteous Fury, Defensive Tactics+Shield, Rockbiter) -- it just
-- removes Salvation outright whenever the option is on, since a full stance-aware decision tree is
-- out of scope for a first pass, and the option itself is opt-in (turning it on already means
-- "never put this on me").
local RBS_SALVATION_IDS = { [1038] = true, [25895] = true }

local function RBS_CheckSalvationRemoval()
	if not RaidBuffStatusConfig.AutoRemoveSalvation then
		return
	end
	local c = 0
	while true do
		local id = GetPlayerBuffID(c)
		if not id then
			break
		end
		if RBS_SALVATION_IDS[id] then
			pcall(CancelPlayerBuff, c)
			break
		end
		c = c + 1
	end
end

-- For a short window after entering combat, the local player's own melee swing results against
-- their target are announced to raid/party chat -- lets the raid know threat might not be
-- established yet (several dodges/parries/misses right at pull) without anyone needing to watch the
-- tank's own combat log. Patterns are confirmed real game text read via CHAT_MSG_COMBAT_SELF_MISSES.
local RBS_FIGHT_START_MISS_PATTERNS = {
	"You miss (.+)%.",
	"You attack%. (.+) dodges%.",
	"You attack%. (.+) parries%.",
	"You attack but (.+) is immune%.",
}
local RBS_FIGHT_START_MISS_PHRASES = {
	"Miss on %s!",
	"%s dodged!",
	"%s parried!",
	"%s is immune!",
}
RBS_FightStartWindowUntil = 0

-- Global, NOT local (2026-08-31): dispatched from RBS_OnEvent, which is defined EARLIER in this
-- file -- same ordering rule as RBS_OnCombatLogCooldowns/RBS_OnCombatLogSoulstone above.
function RBS_OnCombatSelfMiss()
	if not RaidBuffStatusConfig.FightStartMisses then
		return
	end
	if GetTime() > RBS_FightStartWindowUntil then
		return
	end
	if not arg1 then
		return
	end

	for i = 1, table.getn(RBS_FIGHT_START_MISS_PATTERNS), 1 do
		local _, _, target = string.find(arg1, RBS_FIGHT_START_MISS_PATTERNS[i])
		if target then
			local msg = string.format(RBS_FIGHT_START_MISS_PHRASES[i], target)
			local channel = nil
			if GetNumRaidMembers() > 0 then
				channel = "RAID"
			elseif GetNumPartyMembers() > 0 then
				channel = "PARTY"
			end
			if channel then
				pcall(SendChatMessage, msg, channel)
			else
				DEFAULT_CHAT_FRAME:AddMessage("|cFF00CCFFRaidBuffStatus:|r " .. msg)
			end
			return
		end
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
				-- CONFIRMED (2026-08-31, per the user): a Hunter using Feign Death got announced as
				-- dead. UnitIsDeadOrGhost() is fooled by Feign Death on this client (a known vanilla
				-- API quirk, not specific to this addon) -- UnitIsFeignDeath(unit) is the real vanilla
				-- API that exists specifically to tell the two apart, so it's excluded here.
				local isDead = (UnitIsDeadOrGhost(unit) and not UnitIsFeignDeath(unit)) and true or false
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
-- RAID COOLDOWN TRACKER (per the user's request, 2026-08-30) -- Innervate, Battle Rez,
-- Bloodlust/Heroism, Spirit Link Totem, Ascendance, etc.
--
-- Explicitly does NOT require anyone else in the raid to run this addon. The reference addon RAT
-- (C:\Users\Felix\Desktop\HolyWrath\RAT-master\Rat.lua) only works raid-wide because every relevant
-- class member runs it themselves and reads their OWN spellbook cooldown via GetSpellCooldown(),
-- then broadcasts it with SendAddonMessage("RATSYNC...") -- confirmed by reading its getSpells()/
-- sendCds()/Rat:AddCd() functions. That's the same "no API exposes another player's cooldown" wall
-- already hit and accepted for Soulstone tracking above, and it's exactly the dependency the user
-- asked to avoid.
--
-- Detection is the Soulstone technique generalized: watch COMBAT_LOG_EVENT_UNFILTERED for a
-- SPELL_CAST_SUCCESS whose spell name (arg10) exactly matches a tracked ability and whose caster
-- (arg4) is a CURRENT raid/party member of the right class, then start THIS ADDON'S OWN cooldown
-- timer for that (ability, caster) pair. Same accepted limitation as Soulstone: only casts this
-- client actually witnesses this session are tracked -- a cooldown already in progress before
-- login/joining the group reads as "ready" until the next real cast.
--
-- NOT YET CONFIRMED on this client: whether "SPELL_CAST_SUCCESS" is the right subevent name for a
-- beneficial, non-damage cast like Innervate (only SPELL_HEAL, via ShaguTweaks, and tentatively
-- SPELL_MISSED for the taunt feature above, are confirmed so far). Several spellName/cooldown
-- values below are also placeholders, not verified against this exact server's tooltips -- see the
-- per-entry comments. "/rbs cddebug" prints the raw combat-log args for anything matching a tracked
-- spell name so both can be corrected from real in-game testing.
------------------------------------------------------------------------------------------------------

-- Global (not local): RaidBuffStatusOptions.lua reads this to build one checkbox per ability.
--
-- `buffName` (2026-08-30): CONFIRMED that COMBAT_LOG_EVENT_UNFILTERED does NOT reliably fire for a
-- plain self-buff cast on this client -- Nydeh casting Evasion produced zero combat-log events at
-- all (verified with the broadened /rbs cddebug, which prints EVERY event where the local player is
-- the source, not just ones matching a guessed spell name), even though it clearly landed (visible
-- in the default Combat Log chat tab as "Nydeh gains Evasion."). Any ability whose cast leaves a
-- scannable AURA is now detected the same proven way Soulstone already is above: RBS_ScanCDBuffs
-- walks the raid/party roster's own buffs via C_UnitAuras.GetAuraDataByIndex (exactly like
-- RBS_ScanBuff), and reacts to the "wasn't there last scan, is there now" transition. `buffName` is
-- the aura's own name if it's set (defaults to `spellName` would be wrong for e.g. Vanish, so it's
-- always spelled out explicitly here, never inferred). `selfOnly = true` means the buff can only
-- ever appear on the person who cast it (Evasion, Berserker Rage, Divine Shield, Shield Wall), so
-- the caster IS just whoever the buff appeared on -- no further lookup needed. Without
-- `selfOnly`, the buff can land on someone OTHER than the caster (Innervate on your target,
-- Blessing of Protection on an ally, Bloodlust/Heroism/Mana Tide/Spirit Link on the whole raid), so
-- the caster is resolved via the aura tooltip's "Cast by" line -- the same trick already proven for
-- Soulstone (RBS_SoulstoneTipCaster), generalized here as RBS_CDTipCaster. Combat log detection
-- (RBS_OnCombatLogCooldowns above) is NOT removed for entries that also have a `buffName` -- it's
-- effectively a no-op for those given today's finding, but harmless to leave running in case it
-- turns out to work for some subevent/ability combination not yet tested. Abilities with NO
-- `buffName` here (Rebirth, Ascendance, Lightwell, taunts, interrupts, Lay on Hands, Divine
-- Intervention, Reincarnation, Tranquilizing Shot) either don't leave a clean scannable aura at all,
-- or (Vanish specifically) leave one ("Stealth") that's indistinguishable from an unrelated, far
-- more common ability (plain Stealth) -- see VANISH's own comment below.
RBS_CD_LIST = {
	-- Confirmed vanilla spell name + icon (mined from RAT's own cdtbl); 6 min is vanilla's real base
	-- cooldown.
	{ id = "INNERVATE",  label = "Innervate",         icon = "Interface\\Icons\\Spell_Nature_Lightning",     class = "Druid",  spellName = "Innervate",         buffName = "Innervate",         cooldown = 6 * 60 },
	-- UNCONFIRMED: vanilla Rebirth has no real spell cooldown, only a reagent requirement -- a
	-- distinct timed "Battle Rez" is likely a TWoW/OctoWoW-specific talent/spell change. spellName
	-- and cooldown here are placeholders pending an in-game tooltip check. Icon reused from RAT's
	-- own Rebirth/Reincarnation entry. No buffName -- a resurrection doesn't leave a clean aura to
	-- scan for on either the caster or the target.
	{ id = "BATTLEREZ",  label = "Battle Rez",        icon = "Interface\\Icons\\Spell_Nature_Reincarnation", class = "Druid",  spellName = "Rebirth",           cooldown = 30 * 60 },
	-- Bloodlust (Horde) / Heroism (Alliance, a TWoW cross-faction addition) share the same icon in
	-- every era of Blizzard's own data.
	{ id = "BLOODLUST",  label = "Bloodlust",         icon = "Interface\\Icons\\Spell_Nature_BloodLust",     class = "Shaman", spellName = "Bloodlust",         buffName = "Bloodlust",         cooldown = 10 * 60 },
	{ id = "HEROISM",    label = "Heroism",           icon = "Interface\\Icons\\Spell_Nature_BloodLust",     class = "Shaman", spellName = "Heroism",           buffName = "Heroism",           cooldown = 10 * 60 },
	-- UNCONFIRMED: not a vanilla-era ability (added in Wrath) -- spellName/cooldown/icon/buffName are
	-- all placeholders for whatever TWoW/OctoWoW's own version of this is.
	{ id = "SPIRITLINK", label = "Spirit Link Totem", icon = "Interface\\Icons\\Spell_Nature_SpiritLink",    class = "Shaman", spellName = "Spirit Link Totem", buffName = "Spirit Link Totem", cooldown = 3 * 60 },
	-- UNCONFIRMED: "Ascendance" isn't a vanilla Priest ability -- almost certainly a TWoW/OctoWoW
	-- class-change talent. spellName/cooldown/icon are all placeholders.
	{ id = "ASCENDANCE", label = "Ascendance",        icon = "Interface\\Icons\\Spell_Shadow_Shadowform",    class = "Priest", spellName = "Ascendance",        cooldown = 3 * 60 },
	-- Lightwell isn't a vanilla-era ability (added in TBC) -- likely present here via a TWoW/OctoWoW
	-- class change, like Ascendance above. spellName and spellId=724 are now CONFIRMED (2026-08-31,
	-- from the Lightwell object's own in-game tooltip: "SpellID: 724") -- cooldown is still a
	-- placeholder (real retail cooldown is 3 min base, reduced by the Tranquil Spirit talent --
	-- used as the estimate here since there's nothing more specific to go on for this server).
	-- CONFIRMED (2026-08-31, corrected after misreading the buff tooltip screenshot as a world
	-- object's): casting Lightwell DOES put a real "Lightwell" buff on the priest -- "You gain
	-- Lightwell." / "Lightwell fades from you." (CHAT_MSG_SPELL_SELF_BUFF / CHAT_MSG_SPELL_AURA_GONE_SELF,
	-- a different, older chat-message system than COMBAT_LOG_EVENT_UNFILTERED -- both just happen to
	-- show up in the same default "Combat Log" chat tab). So aura-scan detection (buffName, the same
	-- proven technique already working for Evasion) applies here after all.
	{ id = "LIGHTWELL",  label = "Lightwell",         icon = "Interface\\Icons\\Spell_Holy_SummonLightwell", class = "Priest", spellName = "Lightwell",         buffName = "Lightwell", selfOnly = true, spellId = 724, cooldown = 3 * 60 },

	-- Everything below is mined from RAT (C:\Users\Felix\Desktop\HolyWrath\RAT-master\Rat.lua) --
	-- per the user (2026-08-30), RAT itself is a TurtleWoW addon, not generic vanilla, so these exact
	-- spellName strings and icon paths are confirmed real/castable on this server (RAT's own
	-- per-class checkbox list, mined via its CreateFrame("CheckButton", "<Name>", self.<Class>, ...)
	-- calls). What RAT does NOT confirm is any of the cooldown DURATIONS below -- it never hardcodes
	-- them, it reads each one live from the local player's own GetSpellCooldown() at the moment they
	-- open their own options panel, so it works regardless of this server's actual values. Every
	-- `cooldown` field here is still my own vanilla-baseline estimate, unconfirmed against an actual
	-- in-game tooltip on this server -- use /rbs cddebug to check the real numbers once tested.
	{ id = "SHIELDWALL",        label = "Shield Wall",           icon = "Interface\\Icons\\Ability_Warrior_ShieldWall",     class = "Warrior", spellName = "Shield Wall",           buffName = "Shield Wall", selfOnly = true, cooldown = 30 * 60 },
	{ id = "CHALLENGINGSHOUT",  label = "Challenging Shout",     icon = "Interface\\Icons\\Ability_BullRush",               class = "Warrior", spellName = "Challenging Shout",     cooldown = 10 * 60 },
	{ id = "BERSERKERRAGE",     label = "Berserker Rage",        icon = "Interface\\Icons\\Spell_Nature_AncestralGuardian", class = "Warrior", spellName = "Berserker Rage",        buffName = "Berserker Rage", selfOnly = true, cooldown = 30 },
	{ id = "PUMMEL",            label = "Pummel",                icon = "Interface\\Icons\\INV_Gauntlets_04",               class = "Warrior", spellName = "Pummel",                cooldown = 10 },
	{ id = "DISARM",            label = "Disarm",                icon = "Interface\\Icons\\Ability_Warrior_Disarm",         class = "Warrior", spellName = "Disarm",                cooldown = 60 },
	{ id = "LAYONHANDS",        label = "Lay on Hands",          icon = "Interface\\Icons\\Spell_Holy_LayOnHands",          class = "Paladin", spellName = "Lay on Hands",          cooldown = 60 * 60 },
	{ id = "BOP",               label = "Blessing of Protection",icon = "Interface\\Icons\\Spell_Holy_SealOfProtection",    class = "Paladin", spellName = "Blessing of Protection",buffName = "Blessing of Protection", cooldown = 5 * 60 },
	-- Icon paths for these two are exactly as RAT itself has them (Divine Shield -> the
	-- "DivineIntervention" texture, Divine Intervention -> the "TimeStop" texture) -- an odd-looking
	-- swap, but taken verbatim from a working, server-specific reference rather than "corrected"
	-- from memory.
	{ id = "DIVINESHIELD",      label = "Divine Shield",         icon = "Interface\\Icons\\Spell_Holy_DivineIntervention",  class = "Paladin", spellName = "Divine Shield",         buffName = "Divine Shield", selfOnly = true, cooldown = 5 * 60 },
	{ id = "DIVINEINTERVENTION",label = "Divine Intervention",   icon = "Interface\\Icons\\Spell_Nature_TimeStop",          class = "Paladin", spellName = "Divine Intervention",   cooldown = 60 * 60 },
	{ id = "CHALLENGINGROAR",   label = "Challenging Roar",      icon = "Interface\\Icons\\Ability_Druid_ChallangingRoar",  class = "Druid",   spellName = "Challenging Roar",      cooldown = 10 * 60 },
	{ id = "MANATIDE",          label = "Mana Tide Totem",       icon = "Interface\\Icons\\Spell_Frost_SummonWaterElemental",class = "Shaman",  spellName = "Mana Tide Totem",       buffName = "Mana Tide Totem", cooldown = 5 * 60 },
	{ id = "REINCARNATION",     label = "Reincarnation",         icon = "Interface\\Icons\\Spell_Nature_Reincarnation",     class = "Shaman",  spellName = "Reincarnation",         cooldown = 30 * 60 },
	-- UNCONFIRMED even that this HAS a meaningful spell cooldown at all in vanilla-era data (it may
	-- just be gated by the hunter's normal ranged attack timer, not a real cooldown) -- RAT tracked
	-- it anyway via the same generic GetSpellCooldown() call, so included for parity; likely the
	-- first one to just show "0:00"/never trigger if it turns out to have no real cooldown here.
	{ id = "TRANQSHOT",         label = "Tranquilizing Shot",    icon = "Interface\\Icons\\Spell_Nature_Drowsy",            class = "Hunter",  spellName = "Tranquilizing Shot",    cooldown = 6 },
	{ id = "KICK",              label = "Kick",                  icon = "Interface\\Icons\\Ability_Kick",                   class = "Rogue",   spellName = "Kick",                  cooldown = 10 },
	-- Not from RAT or the user's original list -- added 2026-08-30 specifically so Nydeh (a Rogue)
	-- can be used to test the whole detection pipeline end-to-end, since Vanish is a real, unchanged
	-- vanilla ability (unlike Ascendance/Lightwell/Spirit Link/Battle Rez above, which are all
	-- guesses because they aren't vanilla at all) -- spellName and icon should both be exact.
	-- Deliberately NO buffName: Vanish grants the "Stealth" buff, but that's the exact same buff the
	-- ordinary (no-cooldown, spammable in and out of combat) Stealth ability grants -- aura-scanning
	-- for "Stealth" would treat every routine stealth as a Vanish cast, which is worse than not
	-- tracking Vanish at all. Combat log is genuinely the only clean option here, confirmed-broken
	-- as that currently is for a plain self-buff.
	{ id = "VANISH",            label = "Vanish",                icon = "Interface\\Icons\\Ability_Vanish",                 class = "Rogue",   spellName = "Vanish",                cooldown = 5 * 60 },
	-- Same reasoning as Vanish above -- a real, unchanged vanilla ability, added for testing with
	-- Nydeh. Vanilla base cooldown is 5 min. Unlike Vanish, Evasion's own buff name doesn't collide
	-- with anything else, so aura-scan detection works cleanly here.
	{ id = "EVASION",           label = "Evasion",               icon = "Interface\\Icons\\Ability_Evasion",                class = "Rogue",   spellName = "Evasion",               buffName = "Evasion", selfOnly = true, cooldown = 5 * 60 },
	-- Major Soulstone is deliberately NOT duplicated here -- it's already tracked above in
	-- RBS_BUFF_LIST (the "SOULSTONE" special entry), via aura-scan + the aura tooltip's "Cast by"
	-- line, which is more accurate than a bare cast-name match would be here.
}

-- RaidBuffStatusConfig.CDTrack[id] = true/false, one per-ability checkbox on the Cooldowns options
-- tab. Backfills any id missing from an existing saved config (fresh install or a config saved
-- before this feature existed).
RaidBuffStatusConfig.CDTrack = RaidBuffStatusConfig.CDTrack or {}
for RBS_cdInit = 1, table.getn(RBS_CD_LIST), 1 do
	local RBS_cdInitId = RBS_CD_LIST[RBS_cdInit].id
	if RaidBuffStatusConfig.CDTrack[RBS_cdInitId] == nil then
		RaidBuffStatusConfig.CDTrack[RBS_cdInitId] = true
	end
end

RBS_CDDebug = false

-- ["ID|CasterName"] = GetTime() value the cooldown ends. Global for the same cross-function-
-- visibility reason as RBS_BuffIcons/RBS_HeaderBuilt above.
RBS_CDState = {}
RBS_CDRows = {}
RBS_CDNeedsBuild = false
-- Bumped from 12 (2026-08-31): the static roster-based list can now show one row per (ability,
-- eligible class member) pair instead of only per active cooldown -- a 25-person raid with several
-- tracked abilities enabled can easily need more than a dozen rows at once.
local RBS_CD_MAX_ROWS = 60
local RBS_CD_ROW_GAP = 2
-- Renamed in spirit but not in name to keep this diff small: with no title bar anymore (see
-- RBS_CreateCDFrame), this is just a small top padding instead of "room for the title text".
local RBS_CD_TITLE_H = 2

-- Returns the class of a CURRENT raid/party member with this exact name, or nil if nobody in the
-- group has that name -- both "is this actually someone in my group" and "what class are they"
-- (an extra guard against a same-named NPC/mob spell) come from one roster walk.
local function RBS_GroupMemberClass(name)
	if not name then
		return nil
	end
	if name == UnitName("player") then
		local ok, class = pcall(UnitClass, "player")
		if ok then
			return class
		end
		return nil
	end
	if GetNumRaidMembers() > 0 then
		for i = 1, GetNumRaidMembers(), 1 do
			local unit = "raid" .. i
			if UnitName(unit) == name then
				local ok, class = pcall(UnitClass, unit)
				if ok then
					return class
				end
			end
		end
	else
		for i = 1, GetNumPartyMembers(), 1 do
			local unit = "party" .. i
			if UnitName(unit) == name then
				local ok, class = pcall(UnitClass, unit)
				if ok then
					return class
				end
			end
		end
	end
	return nil
end

-- Added 2026-08-30 after real raid testing confirmed the bug: a warlock who threw a Soulstone kept
-- showing as "available" indefinitely, never entering the addon's own 30-minute cooldown. The
-- existing detection (RBS_ScanSoulstone below) relies entirely on the aura tooltip's "Cast by:"
-- line, which was only ever independently confirmed present when hovering a buff on the LOCAL
-- PLAYER's own tooltip (pfUI's action-bar tooltip, for Fortitude) -- it may simply not exist at all
-- when scanning ANOTHER raid member's aura via SetUnitBuff on a non-"player" unit, which is exactly
-- how Soulstone is scanned. This adds a SECOND, independent detection path that doesn't need that
-- line at all: Soulstone Resurrection targets another player (unlike a pure self-buff), and the
-- combat log has been separately confirmed to fire reliably for that category of cast (SPELL_HEAL,
-- via ShaguTweaks) even though it's confirmed NOT to fire for plain self-buffs (Evasion). The two
-- paths are redundant by design, not a replacement for one another -- whichever notices the cast
-- first sets the same RBS_SoulstoneCooldownUntil table.
function RBS_OnCombatLogSoulstone()
	if arg2 == "SPELL_CAST_SUCCESS" and arg10 == "Soulstone Resurrection" then
		if RBS_GroupMemberClass(arg4) == "Warlock" then
			RBS_SoulstoneCooldownUntil[arg4] = GetTime() + RBS_SOULSTONE_COOLDOWN_SECONDS
		end
	end
end

-- Starts a cooldown in BOTH clock domains at once (2026-08-30, per the user): `RBS_CDState` (this
-- session's live display, keyed the same way, valued in GetTime() -- required by
-- CooldownFrame_SetTimer's own radial-swipe math, and already correct across a plain /reload since
-- GetTime() keeps counting through one) and `RaidBuffStatusConfig.CDSaved` (persisted to disk via
-- this addon's own SavedVariables, valued in time() -- real wall-clock epoch seconds, the ONLY clock
-- that still means anything after the game process itself restarts, since GetTime() resets to ~0 on
-- every fresh client launch). Without the second one, closing and reopening the game would forget
-- an in-progress cooldown entirely and show everyone as "ready" again, which is exactly the bug the
-- user reported (their Druid's Innervate looked available after a crash/relog when it was actually
-- still on cooldown). RBS_OnAddonLoaded converts CDSaved back into a fresh RBS_CDState entry for the
-- new session on login/reload; RBS_UpdateCooldowns clears BOTH tables together once a cooldown
-- actually expires.
function RBS_SetCDReady(key, cooldownSeconds)
	RBS_CDState[key] = GetTime() + cooldownSeconds
	RaidBuffStatusConfig.CDSaved = RaidBuffStatusConfig.CDSaved or {}
	RaidBuffStatusConfig.CDSaved[key] = time() + cooldownSeconds
end

-- Global, NOT local (2026-08-30): RBS_OnEvent, which calls this, is defined EARLIER in this file --
-- per this project's own confirmed Lua-ordering gotcha (see CLAUDE.md), a `local function` declared
-- further down resolves as a nil global at an earlier call site even though that call only actually
-- runs later, at event time. Every other cross-section function in this file already sidesteps this
-- the same way (RBS_OnEvent/RBS_OnLoad/RBS_OnUpdate/RBS_UpdateDashboard are all plain globals too).
function RBS_OnCombatLogCooldowns()
	if not arg10 then
		return
	end

	-- Broadened (2026-08-30): originally this only printed when arg10 ALREADY matched one of our
	-- guessed spellName strings -- useless for the actual question "is our guessed name wrong", which
	-- is exactly what happened with Lightwell (zero debug output at all when cast, meaning either the
	-- guessed name never matched anything, or this event never fires for it in the first place). Now
	-- prints EVERY combat log event where the LOCAL PLAYER is the source, regardless of spell name, so
	-- a real cast's actual arg2/arg10 layout can be read directly instead of guessed at.
	if RBS_CDDebug and arg4 == UnitName("player") then
		local dbgMsg = "CD debug: arg2=" .. tostring(arg2) .. " arg4=" .. tostring(arg4)
			.. " arg9=" .. tostring(arg9) .. " arg10=" .. tostring(arg10)
		DEFAULT_CHAT_FRAME:AddMessage("|cFF00CCFFRaidBuffStatus:|r " .. dbgMsg)
		RBS_LogDebug(dbgMsg)
	end

	if arg2 ~= "SPELL_CAST_SUCCESS" then
		return
	end

	local track = RaidBuffStatusConfig.CDTrack or {}
	for i = 1, table.getn(RBS_CD_LIST), 1 do
		local def = RBS_CD_LIST[i]
		-- Matches by spellId (arg9) too when an entry has one -- more robust than a bare name
		-- string compare (rank suffixes, stray whitespace, etc). Currently only Lightwell has a
		-- confirmed spellId (724, read off its own in-game tooltip); harmless no-op for every other
		-- entry, which just falls back to the name-only match.
		if track[def.id] and (arg10 == def.spellName or (def.spellId and arg9 == def.spellId)) then
			if RBS_GroupMemberClass(arg4) == def.class then
				RBS_SetCDReady(def.id .. "|" .. arg4, def.cooldown)
			end
			break
		end
	end
end

-- Hidden scanning tooltip, dedicated to CD-buff caster resolution (kept separate from
-- RBS_SoulstoneTip above rather than sharing one -- cheap to duplicate, and keeps this section
-- independent of the Soulstone one). Same "Cast by: <name>" line technique.
local RBS_CDTip = nil
local function RBS_CDTipCaster(unit, index)
	if not RBS_CDTip then
		RBS_CDTip = CreateFrame("GameTooltip", "RaidBuffStatusCDTip", nil, "GameTooltipTemplate")
		RBS_CDTip:SetOwner(WorldFrame, "ANCHOR_NONE")
	end
	RBS_CDTip:ClearLines()
	RBS_CDTip:SetUnitBuff(unit, index)
	for i = 1, 8, 1 do
		local line = getglobal("RaidBuffStatusCDTipTextLeft" .. i)
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

-- [unit .. "|" .. abilityId] = true/false, this unit's last-seen state for that ability's buff.
-- Global for the same cross-function-visibility reason as RBS_SoulstoneHadIt/RBS_BuffIcons above.
RBS_CDBuffHadIt = {}

-- Generalizes the Soulstone transition-detection technique (see that section's own comment) to any
-- RBS_CD_LIST entry that has a `buffName`. Walks the raid/party roster once, and for each tracked
-- ability with a buffName, reacts to that buff newly appearing on a unit by starting a cooldown for
-- whoever cast it -- immediately for `selfOnly` entries (the buffed unit IS the caster), otherwise
-- via the aura tooltip's "Cast by" line.
function RBS_ScanCDBuffs()
	-- See RBS_ScanSuppressUntil's own comment (top of file) -- same reasoning as RBS_UpdateDashboard.
	if GetTime() < RBS_ScanSuppressUntil then
		return
	end

	local track = RaidBuffStatusConfig.CDTrack or {}

	local function checkUnit(unit)
		if not UnitExists(unit) then
			return
		end
		local name = UnitName(unit) or unit

		for i = 1, table.getn(RBS_CD_LIST), 1 do
			local def = RBS_CD_LIST[i]
			if def.buffName and track[def.id] then
				local hasIt = false
				local castByIndex = nil
				local index = 1
				while true do
					local ok, aura = pcall(C_UnitAuras.GetAuraDataByIndex, unit, index, "HELPFUL")
					if not ok or not aura then
						break
					end
					if aura.name == def.buffName then
						hasIt = true
						castByIndex = index
						break
					end
					index = index + 1
				end

				local stateKey = unit .. "|" .. def.id
				if hasIt and RBS_CDBuffHadIt[stateKey] == false then
					local caster = name
					if not def.selfOnly then
						local okCaster, tipCaster = pcall(RBS_CDTipCaster, unit, castByIndex)
						if okCaster and tipCaster and tipCaster ~= "" then
							caster = tipCaster
						else
							caster = nil
						end
					end
					if caster then
						RBS_SetCDReady(def.id .. "|" .. caster, def.cooldown)
					end
				end
				RBS_CDBuffHadIt[stateKey] = hasIt
			end
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
end

local function RBS_BuildOneCDRow(i)
	-- Defensive fallback (2026-08-30): RBS_OnAddonLoaded is what actually fixes CDIconSize coming
	-- back nil (see its own comment), but this `or 20` costs nothing and means a row can never fail
	-- to build even if some future code path calls this before that handler has run.
	local iconSize = RaidBuffStatusConfig.CDIconSize or 20
	local row = CreateFrame("Frame", nil, RaidBuffStatusCDFrame)
	-- Explicit width (2026-08-30): this was never set at all before, defaulting to 0 -- almost
	-- certainly harmless on its own (children position from their own anchors regardless), but cheap
	-- to fix while chasing the "literally nothing renders, even the fake /rbs cdtest entry" report.
	row:SetWidth(200)
	row:SetHeight(iconSize)

	local icon = row:CreateTexture(nil, "ARTWORK")
	icon:SetPoint("LEFT", row, "LEFT", 0, 0)
	icon:SetWidth(iconSize)
	icon:SetHeight(iconSize)
	row.icon = icon

	-- REMOVED (2026-08-30): the native radial swipe (CreateFrame("Model", ..., "CooldownFrameTemplate"),
	-- mirroring Holyward's own Serenity_GetOrCreateCooldown). Pulled out entirely while chasing "the
	-- whole row renders as literally nothing, not even a plain icon" -- this was the one genuinely
	-- unverified, untested-in-THIS-addon piece (unlike the icon+text pattern below, which is the exact
	-- same one already proven working in the main dashboard's own buff icons all session). Holyward's
	-- own version also calls SetScale(size/36) on it, which this port never did -- a real, concrete
	-- difference from the proven reference, and plausible enough as a cause (an unscaled swipe from a
	-- template sized for a ~36px button could render oversized/misplaced) that it's not worth
	-- debugging blind. Worth re-adding later as its own isolated step once the basic row is confirmed
	-- visible, matching the scale fix this time.
	row.cooldown = nil

	-- Background bar behind the text (2026-08-31, per the user's reference screenshots): plain
	-- WHITE8X8-tinted texture, the same flat-panel trick documented in this project's CLAUDE.md and
	-- used elsewhere in this addon, just applied to one row instead of a whole window. On the
	-- "BACKGROUND" layer so it draws behind timerText/text below regardless of creation order (WoW
	-- layers, not z-order by creation, decide draw order for sibling regions). Color is set per-tick
	-- in RBS_UpdateCooldowns (green-tinted when ready, red-tinted when on cooldown) -- fixed width
	-- rather than hugging the text exactly, so every row reads as a uniform bar like the reference.
	local bg = row:CreateTexture(nil, "BACKGROUND")
	bg:SetPoint("LEFT", icon, "RIGHT", 2, 0)
	bg:SetPoint("TOP", row, "TOP", 0, 0)
	bg:SetPoint("BOTTOM", row, "BOTTOM", 0, 0)
	bg:SetWidth(168)
	bg:SetTexture("Interface\\Buttons\\WHITE8X8")
	row.bg = bg

	-- Big yellow countdown right next to the icon -- the same RGB Holyward's own
	-- SerenityGraphicalTimer.lua uses for its countdown label, matching the screenshot the user gave
	-- (icon + native swipe + a bold yellow "0:13", no boxed panel around any of it).
	local timerText = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	timerText:SetPoint("LEFT", icon, "RIGHT", 8, 0)
	timerText:SetJustifyH("Left")
	timerText:SetTextColor(1, 0.82, 0)
	row.timerText = timerText

	-- Caster + ability name -- smaller and secondary, trailing after the countdown, since Holyward's
	-- own single-target timer doesn't need this at all (it only ever tracks the local player's own
	-- ability) but this addon tracks a whole raid, so SOME identifying text has to stay somewhere.
	local text = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	text:SetPoint("LEFT", timerText, "RIGHT", 6, 0)
	text:SetJustifyH("Left")
	row.text = text

	row:Hide()
	RBS_CDRows[i] = row
end

-- Deferred the same way RBS_BuildHeader is (see RBS_OnLoad/RBS_NeedsHeaderBuild above): building
-- this row pool synchronously during OnLoad would hit the identical table-write-doesn't-persist bug
-- confirmed there. Built on the CD frame's own first OnUpdate tick instead.
local function RBS_BuildCDRows()
	for i = 1, RBS_CD_MAX_ROWS, 1 do
		local ok, err = pcall(RBS_BuildOneCDRow, i)
		if not ok then
			DEFAULT_CHAT_FRAME:AddMessage(
				"|cFF00CCFFRaidBuffStatus:|r |cFFFF0000error building CD row " .. i .. ":|r " .. tostring(err)
			)
		end
	end
end

-- Called from the options window's "Icon size" slider for the Cooldowns tab. Existing pooled rows
-- were already sized at build time, so those need an explicit resize here.
function RBS_ApplyCDIconSize(newSize)
	RaidBuffStatusConfig.CDIconSize = newSize
	for i = 1, RBS_CD_MAX_ROWS, 1 do
		local row = RBS_CDRows[i]
		if row then
			row:SetHeight(newSize)
			row.icon:SetWidth(newSize)
			row.icon:SetHeight(newSize)
		end
	end
end

-- Rebuilds a STATIC, roster-based row list every tick (2026-08-31, per the user, who wants the same
-- always-visible "who's up / who's on cooldown" style other raid-cooldown addons use, screenshotted
-- for reference -- NOT the previous behavior, where a row only ever appeared once a cooldown was
-- actually witnessed and disappeared again once it expired). For every ENABLED tracked ability,
-- every CURRENT raid/party member of the matching class gets a permanent row: "Ready" (green) if no
-- cooldown is known for them right now, or a red countdown if RBS_CDState has one. Expired
-- RBS_CDState/CDSaved entries are still pruned first, same as before (safe to clear the CURRENT key
-- of a table mid-`pairs()` traversal per the Lua manual -- only adding a NEW key during traversal is
-- undefined).
local function RBS_UpdateCooldowns()
	if not RaidBuffStatusConfig.CDEnabled then
		-- The CONTAINER is never hidden (see RBS_CreateCDFrame's comment) -- only the rows, so any
		-- leftover ones from before CDEnabled got turned off don't stay stuck on screen.
		for i = 1, RBS_CD_MAX_ROWS, 1 do
			if RBS_CDRows[i] then
				RBS_CDRows[i]:Hide()
			end
		end
		return
	end

	if RBS_CDNeedsBuild then
		RBS_CDNeedsBuild = false
		RBS_BuildCDRows()
	end

	-- Defensive fallbacks (2026-08-30, see RBS_OnAddonLoaded's comment for the actual root-cause
	-- fix) -- computed once per tick instead of trusting every raw RaidBuffStatusConfig field read
	-- below to already be non-nil.
	local iconSize = RaidBuffStatusConfig.CDIconSize or 20
	local track = RaidBuffStatusConfig.CDTrack or {}
	local now = GetTime()

	for key, readyAt in pairs(RBS_CDState) do
		if (readyAt - now) <= 0 then
			RBS_CDState[key] = nil
			if RaidBuffStatusConfig.CDSaved then
				RaidBuffStatusConfig.CDSaved[key] = nil
			end
		end
	end

	local roster = {}
	if GetNumRaidMembers() > 0 then
		for i = 1, GetNumRaidMembers(), 1 do
			local unit = "raid" .. i
			if UnitExists(unit) then
				local name = UnitName(unit)
				local okClass, class = pcall(UnitClass, unit)
				if name and okClass then
					table.insert(roster, { name = name, class = class })
				end
			end
		end
	else
		local okSelf, selfClass = pcall(UnitClass, "player")
		if okSelf then
			table.insert(roster, { name = UnitName("player"), class = selfClass })
		end
		for i = 1, GetNumPartyMembers(), 1 do
			local unit = "party" .. i
			if UnitExists(unit) then
				local name = UnitName(unit)
				local okClass, class = pcall(UnitClass, unit)
				if name and okClass then
					table.insert(roster, { name = name, class = class })
				end
			end
		end
	end

	local activeRows = 0
	for a = 1, table.getn(RBS_CD_LIST), 1 do
		local def = RBS_CD_LIST[a]
		if track[def.id] then
			for p = 1, table.getn(roster), 1 do
				local person = roster[p]
				if person.class == def.class and activeRows < RBS_CD_MAX_ROWS then
					activeRows = activeRows + 1
					local row = RBS_CDRows[activeRows]
					if row then
						local readyAt = RBS_CDState[def.id .. "|" .. person.name]
						local remaining = 0
						if readyAt then
							remaining = readyAt - now
						end

						row.icon:SetTexture(def.icon)
						if RaidBuffStatusConfig.CDShowLabels then
							row.text:SetText(person.name .. " -- " .. def.label)
						else
							row.text:SetText(person.name)
						end

						if remaining > 0 then
							if row.cooldown and CooldownFrame_SetTimer then
								-- start = the moment the cast actually happened (readyAt minus the
								-- full cooldown length), duration = the full cooldown.
								pcall(CooldownFrame_SetTimer, row.cooldown, readyAt - def.cooldown, def.cooldown, 1)
							end
							local mins = math.floor(remaining / 60)
							local secs = math.floor(math.mod(remaining, 60))
							row.timerText:SetTextColor(1, 0.3, 0.3)
							row.timerText:SetText(string.format("%d:%02d", mins, secs))
							row.bg:SetVertexColor(0.35, 0.08, 0.08, 0.75)
						else
							row.timerText:SetTextColor(0.3, 1, 0.3)
							row.timerText:SetText("Ready")
							row.bg:SetVertexColor(0.08, 0.3, 0.1, 0.75)
						end

						row:ClearAllPoints()
						row:SetPoint(
							"TOPLEFT", RaidBuffStatusCDFrame, "TOPLEFT", 0,
							-RBS_CD_TITLE_H - (activeRows - 1) * (iconSize + RBS_CD_ROW_GAP)
						)
						row:Show()
					end
				end
			end
		end
	end

	for i = activeRows + 1, RBS_CD_MAX_ROWS, 1 do
		if RBS_CDRows[i] then
			RBS_CDRows[i]:Hide()
		end
	end

	-- No empty-state text anymore -- matching the borderless Holyward look, the frame should show
	-- literally nothing when there's nothing to list (e.g. no tracked ability's class is present in
	-- the group), not a placeholder message. The container itself is never hidden/shown here at all
	-- (see RBS_CreateCDFrame).
	RaidBuffStatusCDFrame:SetHeight(RBS_CD_TITLE_H + math.max(activeRows, 1) * (iconSize + RBS_CD_ROW_GAP) + 4)
end

-- Built entirely in Lua (no XML) -- same self-contained WHITE8X8 flat-dark-panel trick documented in
-- this project's CLAUDE.md, already used elsewhere in this file. Movable but not resizable for this
-- first version (unlike the main window's hand-tuned manual-resize grip) -- row count/height already
-- auto-fits the content, and the main window's resize code took many iterations to get right; a
-- second, different (vertical-list, not wrapping-grid) layout mode isn't worth that same risk yet.
-- Position isn't saved across /reload for the same reason -- an accepted v1 limitation, not an
-- oversight.
-- Borderless, no title, no backdrop (2026-08-30, per the user's own Holyward screenshot) -- Holyward's
-- own cooldown display (serenity-twow\SerenityGraphicalTimer.lua) is just a bare icon with the native
-- radial swipe and a yellow countdown number floating directly over the game world, NOT a dark boxed
-- panel with a title bar -- the WHITE8X8 flat-dark-panel look used for the main RaidBuffStatus window
-- and the resize grip elsewhere in this file doesn't apply here, that's a different UI element with
-- different intent. EnableMouse(true) + a real width/height still gives this an invisible, draggable
-- click-region even with nothing drawn for it -- no backdrop is needed for dragging to work.
local RBS_CDFrameLastCheck = 0
local RBS_CD_TICK_INTERVAL = 1

-- Drives Cooldowns entirely on its own -- see RBS_CreateCDFrame's comment below for why this can no
-- longer ride the main dashboard's OnUpdate. Global (not local) purely for consistency with every
-- other SetScript handler in this file; nothing outside RBS_CreateCDFrame calls it directly.
function RBS_CDFrameOnUpdate()
	local curTime = GetTime()
	if (curTime - RBS_CDFrameLastCheck) < RBS_CD_TICK_INTERVAL then
		return
	end
	RBS_CDFrameLastCheck = curTime
	RBS_ScanCDBuffs()
	RBS_UpdateCooldowns()
end

-- CONFIRMED root cause (2026-08-30) of "cdtest still shows nothing": this frame's ticking used to be
-- piggybacked on the MAIN RaidBuffStatusFrame's OnUpdate script -- but OnUpdate does NOT fire at all
-- while its owning frame is hidden, on this or any WoW client. Whenever the main dashboard window
-- was disabled/hidden, Cooldowns (and Death Warnings, and Soulstone tracking, which ride the same
-- OnUpdate) silently stopped running entirely, no matter what RBS_CDState held -- injecting a fake
-- entry via /rbs cdtest couldn't help either, since the code that would ever call :Show() on this
-- frame simply never ran. Fixed by giving this frame its OWN OnUpdate (RBS_CDFrameOnUpdate, defined
-- below) and NEVER hiding the frame itself -- CDEnabled / "nothing active" is expressed by hiding
-- the individual ROWS only, specifically so this frame's own OnUpdate keeps ticking forever and can
-- notice CDEnabled being turned back on later, rather than getting stuck hidden with no way to wake
-- itself back up.
local function RBS_CreateCDFrame()
	local f = CreateFrame("Frame", "RaidBuffStatusCDFrame", UIParent)
	f:SetWidth(160)
	f:SetHeight(24)
	f:SetPoint("CENTER", UIParent, "CENTER", 0, 80)
	f:SetFrameStrata("MEDIUM")
	f:EnableMouse(true)
	f:SetMovable(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", function()
		this:StartMoving()
	end)
	f:SetScript("OnDragStop", function()
		this:StopMovingOrSizing()
	end)
	f:SetScript("OnUpdate", RBS_CDFrameOnUpdate)

	RBS_CDNeedsBuild = true
end

-- Re-applies every RaidBuffStatusConfig default AND refreshes the RBS_ICON_SIZE global mirror
-- derived from it -- called from the ADDON_LOADED branch of RBS_OnEvent (registered in RBS_OnLoad),
-- gated on arg1 == "RaidBuffStatus" so it only reacts to THIS addon finishing its own load, not any
-- other addon's.
--
-- CONFIRMED root cause (2026-08-30) of "attempt to index field `CDTrack' (a nil value)" / "attempt
-- to perform arithmetic on field `CDIconSize' (a nil value)" on an existing character: a real,
-- well-documented WoW SavedVariables gotcha, not specific to this client. The engine restores an
-- addon's `## SavedVariablesPerCharacter` global from disk (a full table REASSIGNMENT, not a merge)
-- only AFTER that addon's own TOC-listed files finish executing -- right when it fires ADDON_LOADED
-- for that addon. On an existing character whose saved file predates a field added THIS session
-- (CDEnabled/CDIconSize/CDShowLabels/CDTrack all didn't exist in any save made before today), that
-- restore overwrites RaidBuffStatusConfig with the OLD saved table, which simply doesn't have the
-- new fields -- wiping out the fresh defaults this file's own top-level code had just set moments
-- earlier. Every OLDER field (Enabled/IconSize/AutoInvite/DeathWarnings/TauntWarnings) was invisible
-- to this exact bug purely by luck: Enabled/IconSize were already present in every prior save
-- (nothing new to wipe), and the three booleans are only ever read via `if RaidBuffStatusConfig.X
-- then` checks, where a nil silently reads as false instead of crashing -- CDIconSize/CDTrack are
-- used in arithmetic/table-indexing instead, where nil actually throws.
function RBS_OnAddonLoaded()
	RaidBuffStatusConfig.IconSize = RaidBuffStatusConfig.IconSize or 28
	RaidBuffStatusConfig.AutoInvite = RaidBuffStatusConfig.AutoInvite or false
	RaidBuffStatusConfig.DeathWarnings = RaidBuffStatusConfig.DeathWarnings or false
	RaidBuffStatusConfig.TauntWarnings = RaidBuffStatusConfig.TauntWarnings or false
	RaidBuffStatusConfig.CDEnabled = RaidBuffStatusConfig.CDEnabled or false
	RaidBuffStatusConfig.CDIconSize = RaidBuffStatusConfig.CDIconSize or 20
	if RaidBuffStatusConfig.CDShowLabels == nil then
		RaidBuffStatusConfig.CDShowLabels = true
	end
	RaidBuffStatusConfig.MockingBlowAnnounce = RaidBuffStatusConfig.MockingBlowAnnounce or false
	RaidBuffStatusConfig.AutoRemoveSalvation = RaidBuffStatusConfig.AutoRemoveSalvation or false
	RaidBuffStatusConfig.FightStartMisses = RaidBuffStatusConfig.FightStartMisses or false
	RaidBuffStatusConfig.FightStartMissesDuration = RaidBuffStatusConfig.FightStartMissesDuration or 8
	RaidBuffStatusConfig.DebugLog = RaidBuffStatusConfig.DebugLog or {}
	RaidBuffStatusConfig.CDTrack = RaidBuffStatusConfig.CDTrack or {}
	for i = 1, table.getn(RBS_CD_LIST), 1 do
		local id = RBS_CD_LIST[i].id
		if RaidBuffStatusConfig.CDTrack[id] == nil then
			RaidBuffStatusConfig.CDTrack[id] = true
		end
	end
	RBS_ICON_SIZE = RaidBuffStatusConfig.IconSize

	-- Restores any cooldown still in progress from BEFORE this login (per the user, 2026-08-30):
	-- converts each saved time() epoch value back into a fresh GetTime()-based RBS_CDState entry for
	-- THIS session, using the real wall-clock gap between when it was saved and right now -- correct
	-- whether that gap was a two-second /reload or the game having been fully closed and reopened.
	-- See RBS_SetCDReady's own comment for why two separate clocks are needed at all.
	RaidBuffStatusConfig.CDSaved = RaidBuffStatusConfig.CDSaved or {}
	local nowEpoch = time()
	for key, readyAtEpoch in pairs(RaidBuffStatusConfig.CDSaved) do
		local remaining = readyAtEpoch - nowEpoch
		if remaining > 0 then
			RBS_CDState[key] = GetTime() + remaining
		else
			RaidBuffStatusConfig.CDSaved[key] = nil
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
	this:RegisterEvent("ADDON_LOADED")
	this:RegisterEvent("PLAYER_ENTERING_WORLD")
	this:RegisterEvent("CHAT_MSG_SPELL_SELF_DAMAGE")
	this:RegisterEvent("CHAT_MSG_COMBAT_SELF_MISSES")
	this:RegisterEvent("PLAYER_REGEN_DISABLED")
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

	RBS_CreateCDFrame()

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
		if msg == "ssdebug" then
			RBS_SSDebug = not RBS_SSDebug
			DEFAULT_CHAT_FRAME:AddMessage(
				"|cFF00CCFFRaidBuffStatus:|r Soulstone debug " .. (RBS_SSDebug and "ON -- have a warlock soulstone someone and watch chat." or "off.")
			)
			return
		end
		if msg == "cddebug" then
			RBS_CDDebug = not RBS_CDDebug
			DEFAULT_CHAT_FRAME:AddMessage(
				"|cFF00CCFFRaidBuffStatus:|r Cooldown debug " .. (RBS_CDDebug and "ON -- have a tracked ability cast near you and watch chat." or "off.")
			)
			return
		end
		-- "/rbs cdstate" -- separates "the Cooldowns window/feature isn't on" from "it's on but this
		-- specific ability isn't being detected", by dumping the exact state RBS_UpdateCooldowns
		-- itself reads from, instead of only ever being able to look at the visual result.
		if msg == "cdstate" then
			DEFAULT_CHAT_FRAME:AddMessage(
				"|cFF00CCFFRaidBuffStatus:|r CDEnabled=" .. tostring(RaidBuffStatusConfig.CDEnabled)
					.. " CDFrame shown=" .. tostring(RaidBuffStatusCDFrame and RaidBuffStatusCDFrame:IsShown())
			)
			local count = 0
			for key, readyAt in pairs(RBS_CDState) do
				count = count + 1
				local remaining = readyAt - GetTime()
				DEFAULT_CHAT_FRAME:AddMessage("  " .. key .. " -- " .. math.floor(remaining) .. "s left")
			end
			if count == 0 then
				DEFAULT_CHAT_FRAME:AddMessage("  RBS_CDState is empty -- nothing has been detected as cast yet.")
			end
			return
		end
		-- "/rbs cdtest" -- the Cooldowns frame has no visible backdrop/title at all anymore (matching
		-- Holyward's own borderless look), so when it's empty there's genuinely NOTHING to see, which
		-- makes it impossible to tell "detection isn't working" apart from "I don't even know where
		-- this window is on my screen". This forces one fake 30-second entry so the window is
		-- guaranteed to render, independent of whether real detection works at all -- it defaults to
		-- the middle of the screen, slightly above center (RBS_CreateCDFrame's own default position).
		if msg == "cdtest" then
			RaidBuffStatusConfig.CDEnabled = true
			RBS_CDState["INNERVATE|TestDruid"] = GetTime() + 30
			DEFAULT_CHAT_FRAME:AddMessage(
				"|cFF00CCFFRaidBuffStatus:|r Injected a fake 30s Innervate cooldown -- look near the "
					.. "middle of your screen, slightly above center. Drag it to reposition."
			)
			return
		end
		-- "/rbs auradump <name>" (2026-08-30, after real raid testing found Flask.Missing wrongly
		-- listing people who confirmed they had one active): dumps EVERY aura C_UnitAuras.
		-- GetAuraDataByIndex reports for that exact raid/party member, in order, straight to chat.
		-- RBS_ScanBuff's "Flask" match is a plain substring against every aura's name, so if the
		-- flask genuinely isn't in this dump, the bug is upstream of this addon (the API itself not
		-- exposing that far into another unit's aura list yet) rather than a matching-logic bug here.
		if string.find(msg, "^auradump", 1) then
			local name = string.gsub(msg, "^auradump%s*", "")
			local unit = nil
			if name == "" then
				unit = "target"
			elseif name == UnitName("player") then
				unit = "player"
			elseif GetNumRaidMembers() > 0 then
				for i = 1, GetNumRaidMembers(), 1 do
					if UnitName("raid" .. i) == name then
						unit = "raid" .. i
						break
					end
				end
			else
				for i = 1, GetNumPartyMembers(), 1 do
					if UnitName("party" .. i) == name then
						unit = "party" .. i
						break
					end
				end
			end
			if not unit or not UnitExists(unit) then
				DEFAULT_CHAT_FRAME:AddMessage(
					"|cFF00CCFFRaidBuffStatus:|r no current raid/party member named \"" .. name .. "\" (or no target, if no name given)."
				)
				return
			end
			DEFAULT_CHAT_FRAME:AddMessage(
				"|cFF00CCFFRaidBuffStatus:|r auras on " .. tostring(UnitName(unit)) .. " (" .. unit .. "):"
			)
			RBS_LogDebug("auradump: auras on " .. tostring(UnitName(unit)) .. " (" .. unit .. "):")
			local index = 1
			local count = 0
			while true do
				local ok, aura = pcall(C_UnitAuras.GetAuraDataByIndex, unit, index, "HELPFUL")
				if not ok or not aura then
					break
				end
				count = count + 1
				DEFAULT_CHAT_FRAME:AddMessage("  " .. index .. ": " .. tostring(aura.name))
				RBS_LogDebug("  " .. index .. ": " .. tostring(aura.name))
				index = index + 1
			end
			DEFAULT_CHAT_FRAME:AddMessage("  (" .. count .. " total)")
			RBS_LogDebug("  (" .. count .. " total)")
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
		-- Salvation removal rides the same 1s cadence -- also independent of Enabled, since it's a
		-- tank safety feature that should keep working whether or not the dashboard window is shown.
		RBS_CheckSalvationRemoval()
	end

	-- Cooldowns no longer ticks from here (2026-08-30) -- it has its own OnUpdate on
	-- RaidBuffStatusCDFrame now (RBS_CDFrameOnUpdate), specifically so it keeps working even while
	-- THIS frame (the main dashboard) is hidden/disabled -- see that function's own comment.

	if not RaidBuffStatusConfig.Enabled then
		return
	end
	if (curTime - RBS_LastScan) < RBS_SCAN_INTERVAL then
		return
	end
	RBS_LastScan = curTime
	RBS_UpdateDashboard()
end
