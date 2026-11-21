-- DungeonQuestHelper
-- Cost model: at load this file only defines functions and registers slash commands.
-- No frames exist until the window is first opened, and events are registered only
-- while the window is shown (OnShow/OnHide), so a closed window costs nothing.

local ADDON, ns = ...
local NPC, DUNGEONS = ns.npcs, ns.dungeons

-- Keep the dungeon list in sweet-spot order (stable: ties keep Data.lua order).
for i = 2, #DUNGEONS do
    local d, j = DUNGEONS[i], i - 1
    while j >= 1 and (DUNGEONS[j].sweetMin > d.sweetMin
            or (DUNGEONS[j].sweetMin == d.sweetMin and DUNGEONS[j].sweetMax > d.sweetMax)) do
        DUNGEONS[j + 1] = DUNGEONS[j]; j = j - 1
    end
    DUNGEONS[j + 1] = d
end

local WIDTH, PAD, ROW_GAP = 400, 14, 4
local TYPE_INFO = {
    [1] = { label = "Pick up at the dungeon",       color = "33c7b5" },
    [2] = { label = "Pick up elsewhere, shareable", color = "8fc46f" },
    [3] = { label = "Chains you can't share",       color = "e2ad4f" },
    [4] = { label = "Starts inside the dungeon",    color = "b598e6" },
    optional = { label = "Optional: probably skip", color = "999999" },
}
local SECTIONS = { 1, 2, 3, 4, "optional" }
local ICON = {
    ready   = "|TInterface\\RaidFrame\\ReadyCheck-Ready:14|t",
    missing = "|TInterface\\RaidFrame\\ReadyCheck-NotReady:14|t",
    waiting = "|TInterface\\RaidFrame\\ReadyCheck-Waiting:14|t",
    turnin  = "|TInterface\\GossipFrame\\ActiveQuestIcon:14|t",
    inside  = "|TInterface\\GossipFrame\\AvailableQuestIcon:14|t",
}
local GREY, WHITE, GOLD, GREEN, RED, ORANGE, BLUE =
    "|cff808080", "|cffffffff", "|cffffd100", "|cff40ff40", "|cffff5050", "|cffff9933", "|cff66bbff"

-- ---------------------------------------------------------------------------
-- Quest log helpers (guarded so a missing API degrades instead of erroring)
-- ---------------------------------------------------------------------------
local CQ = C_QuestLog or {}

local function IsDone(id)
    if CQ.IsQuestFlaggedCompleted then return CQ.IsQuestFlaggedCompleted(id) end
    return IsQuestFlaggedCompleted and IsQuestFlaggedCompleted(id) or false
end

local function LogIndex(id)
    if CQ.GetLogIndexForQuestID then return CQ.GetLogIndexForQuestID(id) end
    if GetQuestLogIndexByID then
        local i = GetQuestLogIndexByID(id)
        if i and i > 0 then return i end
    end
end

local function IsOn(id)
    if CQ.IsOnQuest then return CQ.IsOnQuest(id) end
    return LogIndex(id) ~= nil
end

-- Returns readyToTurnIn, progressText
local function Progress(id)
    local parts, allDone, any = {}, true, false
    local objs = CQ.GetQuestObjectives and CQ.GetQuestObjectives(id)
    if objs then
        for _, o in ipairs(objs) do
            any = true
            if not o.finished then allDone = false end
            if o.text and o.text ~= "" then
                parts[#parts + 1] = (o.finished and GREY or WHITE) .. o.text .. "|r"
            end
        end
    end
    local complete = CQ.IsComplete and CQ.IsComplete(id)
    if complete == nil then complete = any and allDone end
    return complete and true or false, table.concat(parts, ", ")
end

local function NpcName(ref)
    local n = NPC[ref]
    return n and n.name or ref
end

local function NpcWhere(ref)
    local n = NPC[ref]
    if not n then return ref end
    return n.name .. " (" .. n.where .. ")"
end

-- "Brill, Tirisfal Glades" -> "Tirisfal Glades"
local function NpcZone(ref)
    local n = NPC[ref]
    if not n then return nil end
    return (n.where:match("([^,]+)$"):gsub("^%s+", ""))
end

local function PlayerLevel()
    -- PLAYER_LEVEL_UP fires before UnitLevel updates, so keep the higher of the two.
    return math.max(ns.levelOverride or 0, UnitLevel("player") or 1)
end

-- ---------------------------------------------------------------------------
-- Readiness
-- ---------------------------------------------------------------------------
-- Evaluate one entry. Returns a table:
--   icon, text (detail line), ready (bool|nil: nil = not a prep item), done,
--   target (npc key for a waypoint), shareID (quest id that can be shared now), xpLeft
local function Evaluate(entry, level, minReq)
    local steps = entry.steps
    local cur, dIdx, xpLeft = nil, nil, 0
    for i, s in ipairs(steps) do
        if s.dungeon and not dIdx then dIdx = i end
        if not IsDone(s.id) then
            cur = cur or i
            xpLeft = xpLeft + (s.xp or 0)
        end
    end
    -- Prep item = must be in the log before you zone in.
    local prep = dIdx and not steps[dIdx].inside
    local r = { xpLeft = xpLeft, prep = prep }

    if not cur then
        r.icon, r.done, r.text, r.ready = ICON.ready, true, GREY .. "Complete.|r", prep and true or nil
        return r
    end

    local s = steps[cur]
    local stepTag = #steps > 1 and string.format("Step %d/%d: ", cur, #steps) or ""
    local on = IsOn(s.id)
    local complete, prog = false, ""
    if on then complete, prog = Progress(s.id) end
    if on and s.share then r.shareID = s.id end
    -- Zone tag for the row title: where to pick up, or where to turn in once it's in the log.
    if on then
        r.zone = NpcZone(s.to) and ("turn in: " .. NpcZone(s.to))
    else
        r.zone = s.inside and "inside" or NpcZone(s.from)
    end

    -- A prep item is ready once you're past its dungeon step, or on that step with it in your log.
    if prep then r.ready = cur > dIdx or (cur == dIdx and on) end
    local afterDungeon = dIdx and cur > dIdx

    if on and complete then
        r.icon, r.target = ICON.turnin, s.to
        r.text = stepTag .. GOLD .. "Turn in to " .. NpcWhere(s.to) .. "|r"
    elseif on then
        r.target = s.to
        r.icon = (cur == dIdx) and ICON.ready or ICON.waiting
        r.text = stepTag .. (prog ~= "" and prog or s.obj)
    elseif level < (s.min or minReq) then
        r.icon = ICON.missing
        r.text = stepTag .. RED .. "Requires level " .. (s.min or minReq) .. "|r"
        if s.inside then
            r.text = r.text .. "  " .. GREY .. "(you can loot it sooner, but can't start it)|r"
        else
            r.target = s.from  -- still worth knowing where the giver is
        end
    elseif s.inside then
        r.icon = ICON.inside
        r.text = stepTag .. BLUE .. "Starts inside: " .. NpcName(s.from) .. "|r  " .. GREY .. s.obj .. "|r"
    else
        r.target = s.from
        r.icon = afterDungeon and ICON.waiting or ICON.missing
        r.text = stepTag .. ORANGE .. "Get from " .. NpcWhere(s.from) .. "|r"
        if cur ~= dIdx then r.text = r.text .. "  " .. GREY .. s.obj .. "|r" end
    end

    if not on then
        if entry.hint and cur == 1 then
            local met = false
            for _, hid in ipairs(entry.hint.ids) do if IsDone(hid) then met = true break end end
            if not met then
                r.text = r.text .. "\n" .. GOLD .. entry.hint.text .. "|r"
                r.hintTarget = entry.hint.npc
            end
        end
    end
    return r
end

local function LevelStatus(d, level)
    local top = d.req
    for _, e in ipairs(d.entries) do
        for _, s in ipairs(e.steps) do if s.min and s.min > top then top = s.min end end
    end
    if level < d.req then
        return RED .. "Level " .. level .. ": too low to accept these quests (need " .. d.req .. ").|r"
    elseif level < top then
        return ORANGE .. "Level " .. level .. ": some quests need " .. top .. ", run it at " .. d.sweetMin .. "-" .. d.sweetMax .. ".|r"
    elseif level < d.sweetMin then
        return ORANGE .. "Level " .. level .. ": collect quests now, run it at " .. d.sweetMin .. "-" .. d.sweetMax .. ".|r"
    elseif level <= d.sweetMax then
        return GREEN .. "Level " .. level .. ": sweet spot (" .. d.sweetMin .. "-" .. d.sweetMax .. ").|r"
    elseif level < d.xpDrop then
        return GREEN .. "Level " .. level .. ": a bit high, quests still pay full XP until about " .. d.xpDrop .. ".|r"
    end
    return ORANGE .. "Level " .. level .. ": quest XP is now reduced.|r"
end

local function PickDungeon(level)
    local best, bestDist
    for i, d in ipairs(DUNGEONS) do
        local dist = level < d.sweetMin and (d.sweetMin - level) or (level > d.sweetMax and (level - d.sweetMax) or 0)
        if not bestDist or dist < bestDist then best, bestDist = i, dist end
    end
    return best or 1
end

-- ---------------------------------------------------------------------------
-- Actions
-- ---------------------------------------------------------------------------
local function Say(msg) print(GOLD .. "Dungeon Quest Helper:|r " .. msg) end

local function MapName(map)
    local info = C_Map and C_Map.GetMapInfo and C_Map.GetMapInfo(map)
    return info and info.name
end

-- New Forever zones (Riverglades, Shen'dralas) have map IDs we don't know, so NPCs there
-- carry a zone name instead and we look it up on the two continents the first time.
local function FindZoneMap(name)
    if not (C_Map and C_Map.GetMapChildrenInfo) then return nil end
    for _, continent in ipairs({ 1415, 1414 }) do
        local kids = C_Map.GetMapChildrenInfo(continent, nil, true)
        for _, info in ipairs(kids or {}) do
            if info.name == name then return info.mapID end
        end
    end
end

-- Built-in map pin. City maps can refuse pins, so fall back to the zone around the city.
-- Returns the map the pin landed on, or nil.
local function NativePin(map, x, y)
    if not (C_Map and C_Map.SetUserWaypoint and UiMapPoint) then return nil end
    local can = C_Map.CanSetUserWaypointOnMap
    if can and not can(map) then
        local info = C_Map.GetMapInfo and C_Map.GetMapInfo(map)
        local parent = info and info.parentMapID
        if not (parent and parent > 0 and can(parent) and C_Map.GetWorldPosFromMapPos
                and C_Map.GetMapPosFromWorldPos and CreateVector2D) then
            return nil
        end
        local cont, world = C_Map.GetWorldPosFromMapPos(map, CreateVector2D(x, y))
        if not (cont and world) then return nil end
        local _, pos = C_Map.GetMapPosFromWorldPos(cont, world, parent)
        if not pos then return nil end
        map, x, y = parent, pos.x, pos.y
    end
    if not pcall(C_Map.SetUserWaypoint, UiMapPoint.CreateFromCoordinates(map, x, y)) then return nil end
    if C_SuperTrack and C_SuperTrack.SetSuperTrackedUserWaypoint then
        pcall(C_SuperTrack.SetSuperTrackedUserWaypoint, true)
    end
    return map
end

local function SetWaypoint(ref)
    local n = NPC[ref]
    if not n then
        Say(ref .. ": no waypoint for this one.")
        return
    end
    if not n.map and n.zone and n.x then n.map = FindZoneMap(n.zone) end
    if not n.map then
        Say(n.name .. " - " .. n.where .. (n.x and string.format(" (%.1f, %.1f)", n.x, n.y) or " (no coordinates yet)"))
        return
    end
    local way = string.format("/way %s %.1f %.1f", MapName(n.map) or n.where, n.x, n.y)
    -- TomTom first: it gives an arrow and works on city maps.
    if TomTom and TomTom.AddWaypoint and pcall(TomTom.AddWaypoint, TomTom, n.map, n.x / 100, n.y / 100,
            { title = n.name, from = "Dungeon Quest Helper" }) then
        Say("TomTom arrow set: " .. n.name .. " (" .. n.where .. ")")
        return
    end
    local landed = NativePin(n.map, n.x / 100, n.y / 100)
    if landed == n.map then
        Say("Map pin set: " .. n.name .. " (" .. n.where .. ")")
    elseif landed then
        Say("Map pin set in " .. (MapName(landed) or "the zone") .. " (the city map won't take pins). "
            .. n.name .. " is in " .. n.where .. ": " .. way)
    else
        Say("Couldn't place a pin. " .. n.name .. " (" .. n.where .. "): " .. way)
    end
end

-- The step a row is about: the first one not yet done, or the last one.
local function CurrentStep(entry)
    for _, s in ipairs(entry.steps) do
        if not IsDone(s.id) then return s end
    end
    return entry.steps[#entry.steps]
end

-- Ctrl-click: drop a quest link into an open chat box, or show the game's own quest tooltip.
local function LinkQuest(entry)
    local s = CurrentStep(entry)
    local ref = "quest:" .. s.id .. ":" .. (s.lvl or 0)
    local link = "|cffffff00|H" .. ref .. "|h[" .. entry.name .. "]|h|r"
    if ChatEdit_InsertLink and ChatEdit_InsertLink(link) then return end
    if SetItemRef then SetItemRef(ref, link, "LeftButton") end
end

local function ShareQuest(id)
    local idx = LogIndex(id)
    if not idx then return end
    if CQ.SetSelectedQuest then CQ.SetSelectedQuest(id) elseif SelectQuestLogEntry then SelectQuestLogEntry(idx) end
    if QuestLogPushQuest then QuestLogPushQuest() end
end

-- ---------------------------------------------------------------------------
-- UI (built on first open)
-- ---------------------------------------------------------------------------
local frame, content, rows, headers, dropdown
local current, manualPick
local refreshQueued = false

local function SavePosition()
    local p, _, rp, x, y = frame:GetPoint(1)
    DungeonQuestHelperDB.pos = { p, rp, x, y }
end

local function RowOnEnter(self)
    local e = self.entry
    if not e then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine(e.name)
    GameTooltip:AddLine(TYPE_INFO[e.type].label, 0.6, 0.6, 0.6)
    if e.optional then GameTooltip:AddLine("Optional: " .. e.optional, 1, 0.6, 0.2, true) end
    for i, s in ipairs(e.steps) do
        local state = IsDone(s.id) and "|cff808080done|r" or (IsOn(s.id) and "|cffffd100in log|r" or "|cffff9933not started|r")
        local tag = #e.steps > 1 and (i .. ". ") or ""
        GameTooltip:AddLine(" ")
        local qname = s.name or e.name
        -- Drop a leading "Quest Name:" (or "Quest Name 2:") since the heading already says it.
        local obj = s.obj
        if obj:sub(1, #qname) == qname then
            local rest = obj:sub(#qname + 1):match("^[%s%d]*:%s*(.+)$")
            if rest then obj = rest:gsub("^%l", string.upper) end
        end
        GameTooltip:AddDoubleLine(tag .. qname, state, 1, 1, 1)
        GameTooltip:AddLine(obj, 0.8, 0.8, 0.8, true)
        GameTooltip:AddDoubleLine("Pick up: " .. NpcWhere(s.from), "~" .. (s.xp or 0) .. " XP", 0.6, 0.6, 0.6, 0.6, 0.6, 0.6)
        GameTooltip:AddLine("Turn in: " .. NpcWhere(s.to), 0.6, 0.6, 0.6)
        local d = DUNGEONS[current]
        local need = s.min or (d and d.req)
        if s.lvl or need then
            GameTooltip:AddLine((s.lvl and ("Quest level " .. s.lvl) or "") .. (s.lvl and need and ", " or "")
                .. (need and ("accept at " .. need .. "+") or ""), 0.6, 0.6, 0.6)
        end
    end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Reward: " .. e.reward, 0.4, 1, 0.4, true)
    GameTooltip:AddLine(" ")
    if self.result and (self.result.target or self.result.hintTarget) then
        GameTooltip:AddLine("Click: waypoint to " .. NpcName(self.result.hintTarget or self.result.target), 0.5, 0.8, 1)
    end
    if self.result and self.result.shareID then
        GameTooltip:AddLine("Shift-click: share with your party", 0.5, 0.8, 1)
    end
    GameTooltip:AddLine("Ctrl-click: quest link (into chat if typing)", 0.5, 0.8, 1)
    GameTooltip:Show()
end

local function RowOnClick(self)
    local r = self.result
    if not r then return end
    local ok, err = pcall(function()
        if IsControlKeyDown() then
            LinkQuest(self.entry)
        elseif IsShiftKeyDown() and r.shareID then
            ShareQuest(r.shareID)
        elseif r.hintTarget then
            SetWaypoint(r.hintTarget)  -- the prerequisite comes first
        elseif r.target then
            SetWaypoint(r.target)
        elseif r.done then
            Say(self.entry.name .. " is done.")
        else
            Say(self.entry.name .. " starts inside the dungeon, nothing to point to yet.")
        end
    end)
    if not ok then Say(RED .. "error: " .. tostring(err) .. "|r") end
end

local function GetRow(i)
    local row = rows[i]
    if row then return row end
    row = CreateFrame("Button", nil, content)
    row:SetWidth(WIDTH - PAD * 2)
    row:RegisterForClicks("LeftButtonUp")
    row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    row.title = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    row.xp = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    row.xp:SetPoint("TOPRIGHT", -2, -3)
    row.title:SetPoint("TOPLEFT", 0, -2)
    row.title:SetPoint("RIGHT", row.xp, "LEFT", -6, 0)  -- long titles truncate instead of running under the XP
    row.title:SetJustifyH("LEFT")
    row.title:SetWordWrap(false)
    row.detail = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.detail:SetPoint("TOPLEFT", row.title, "BOTTOMLEFT", 18, -2)
    row.detail:SetWidth(WIDTH - PAD * 2 - 20)
    row.detail:SetJustifyH("LEFT")
    row.detail:SetWordWrap(true)
    row:SetScript("OnEnter", RowOnEnter)
    row:SetScript("OnLeave", GameTooltip_Hide)
    row:SetScript("OnClick", RowOnClick)
    rows[i] = row
    return row
end

local function GetHeader(i)
    local h = headers[i]
    if h then return h end
    h = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    h:SetJustifyH("LEFT")
    h:SetWidth(WIDTH - PAD * 2)
    headers[i] = h
    return h
end

local Refresh

-- "Wailing Caverns  (18-21)". With a level given, the range is colored for that level:
-- grey = past it, green = sweet spot, orange = quests open but not there yet, red = too low for the quests.
-- True when every non-optional quest line for the dungeon is turned in (its last step is done).
local function DungeonDone(d)
    local any = false
    for _, e in ipairs(d.entries) do
        if not e.optional then
            any = true
            if not IsDone(e.steps[#e.steps].id) then return false end
        end
    end
    return any
end

local function DungeonLabel(d, level)
    if not d.sweetMin then return d.name end
    local range = d.sweetMin .. "-" .. d.sweetMax
    if level then
        local color
        if level > d.sweetMax then color = GREY
        elseif level >= d.sweetMin then color = "|cff40ff40"
        elseif level >= (d.req or d.sweetMin) then color = ORANGE
        else color = RED end
        range = color .. range .. "|r"
    end
    return d.name .. "  (" .. range .. ")" .. (level and DungeonDone(d) and ("  " .. ICON.ready) or "")
end

local function SelectDungeon(i, manual)
    current = i
    if manual then manualPick = true; DungeonQuestHelperDB.last = DUNGEONS[i].key end
    UIDropDownMenu_SetText(dropdown, DungeonLabel(DUNGEONS[i]))
    Refresh()
end

function Refresh()
    if not frame or not frame:IsShown() then return end
    local d = DUNGEONS[current]
    local level = PlayerLevel()
    local nRow, nHead, y = 0, 0, 0
    local readyCount, prepCount, xpLeft = 0, 0, 0

    frame.dname:SetText(d.name .. GREY .. "  ·  " .. d.entrance .. "|r")
    frame.level:SetText(LevelStatus(d, level))
    if UnitFactionGroup("player") ~= "Horde" then
        frame.level:SetText(ORANGE .. "These lists are Horde quests.|r")
    end

    for _, t in ipairs(SECTIONS) do
        local function inSection(e)
            if t == "optional" then return e.optional ~= nil end
            return e.type == t and not e.optional
        end
        local info = TYPE_INFO[t]
        local any = false
        for _, e in ipairs(d.entries) do if inSection(e) then any = true break end end
        local empty = d.emptyTypes and d.emptyTypes[t]
        if any or empty then
            nHead = nHead + 1
            local h = GetHeader(nHead)
            h:ClearAllPoints()
            h:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -y)
            h:SetText("|cff" .. info.color .. info.label:upper() .. "|r" .. (empty and not any and (GREY .. "  " .. empty .. "|r") or ""))
            h:Show()
            y = y + h:GetStringHeight() + 4
            for _, e in ipairs(d.entries) do
                if inSection(e) then
                    local r = Evaluate(e, level, d.req)
                    if e.optional then
                        -- Not counted in the summary; say why it's down here until it's started.
                        r.prep = nil
                        local unlocked = false
                        for _, hid in ipairs(e.unlock or (e.hint and e.hint.ids) or {}) do if IsDone(hid) then unlocked = true end end
                        if not unlocked and not r.done and not IsOn(e.steps[1].id) and not IsDone(e.steps[1].id) then
                            r.text = r.text .. "\n" .. GREY .. e.optional .. "|r"
                        end
                    else
                        xpLeft = xpLeft + r.xpLeft
                    end
                    if r.prep then
                        prepCount = prepCount + 1
                        if r.ready then readyCount = readyCount + 1 end
                    end
                    nRow = nRow + 1
                    local row = GetRow(nRow)
                    row.entry, row.result = e, r
                    row:ClearAllPoints()
                    row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -y)
                    row.title:SetText(r.icon .. " " .. (r.done and GREY or "") .. e.name .. (r.done and "|r" or "")
                        .. ((r.zone and not r.done) and (GREY .. "  ·  " .. r.zone .. "|r") or ""))
                    row.xp:SetText(r.xpLeft > 0 and ("~" .. BreakUpLargeNumbers(r.xpLeft) .. " XP") or "")
                    row.detail:SetText(r.text)
                    local h2 = 2 + row.title:GetStringHeight() + 2 + row.detail:GetStringHeight() + 4
                    row:SetHeight(h2)
                    row:Show()
                    y = y + h2 + ROW_GAP
                end
            end
            y = y + 6
        end
    end
    for i = nRow + 1, #rows do rows[i]:Hide() end
    for i = nHead + 1, #headers do headers[i]:Hide() end

    local col = (prepCount > 0 and readyCount == prepCount) and GREEN or ORANGE
    frame.summary:SetText(string.format("%sReady to zone in: %d/%d prep quests|r%s   ~%s quest XP left",
        col, readyCount, prepCount, GREY, BreakUpLargeNumbers(xpLeft)) .. "|r")

    content:SetHeight(math.max(y, 1))
    frame:SetHeight(y + frame.topOffset + 34)
end

local function QueueRefresh()
    if refreshQueued then return end
    refreshQueued = true
    C_Timer.After(0.15, function()
        refreshQueued = false
        Refresh()
    end)
end

local EVENTS = { "QUEST_LOG_UPDATE", "QUEST_ACCEPTED", "QUEST_REMOVED", "QUEST_TURNED_IN", "PLAYER_LEVEL_UP" }

local function Build()
    DungeonQuestHelperDB = DungeonQuestHelperDB or {}
    rows, headers = {}, {}

    frame = CreateFrame("Frame", "DungeonQuestHelperFrame", UIParent, "BackdropTemplate")
    frame:Hide()
    frame:SetWidth(WIDTH)
    -- DIALOG keeps it above the battlefield (zone) map and other HIGH-strata windows.
    frame:SetFrameStrata("DIALOG")
    frame:SetToplevel(true)
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", function(self) self:StopMovingOrSizing(); SavePosition() end)
    frame:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    frame:SetBackdropBorderColor(0.6, 0.45, 0.3)
    local pos = DungeonQuestHelperDB.pos
    if pos then frame:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4]) else frame:SetPoint("CENTER", -300, 80) end
    tinsert(UISpecialFrames, "DungeonQuestHelperFrame")

    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", PAD, -12)
    title:SetText("Dungeon Quest Helper")

    local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", 0, 0)

    -- Dungeon picker. The list is filled only when it's opened.
    dropdown = CreateFrame("Frame", "DungeonQuestHelperDropDown", frame, "UIDropDownMenuTemplate")
    dropdown:SetPoint("TOPLEFT", PAD - 16, -28)
    UIDropDownMenu_SetWidth(dropdown, WIDTH - PAD * 2 - 30)
    UIDropDownMenu_Initialize(dropdown, function()
        local level = PlayerLevel()
        for i, d in ipairs(DUNGEONS) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = DungeonLabel(d, level)
            info.checked = (i == current)
            info.func = function() SelectDungeon(i, true); CloseDropDownMenus() end
            UIDropDownMenu_AddButton(info)
        end
    end)

    frame.dname = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    frame.dname:SetPoint("TOPLEFT", PAD, -60)
    frame.dname:SetWidth(WIDTH - PAD * 2)
    frame.dname:SetJustifyH("LEFT")
    frame.level = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    frame.level:SetPoint("TOPLEFT", frame.dname, "BOTTOMLEFT", 0, -4)
    frame.level:SetWidth(WIDTH - PAD * 2)
    frame.level:SetJustifyH("LEFT")
    frame.summary = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    frame.summary:SetPoint("TOPLEFT", frame.level, "BOTTOMLEFT", 0, -3)
    frame.summary:SetWidth(WIDTH - PAD * 2)
    frame.summary:SetJustifyH("LEFT")
    frame.topOffset = 112

    content = CreateFrame("Frame", nil, frame)
    content:SetPoint("TOPLEFT", PAD, -frame.topOffset)
    content:SetWidth(WIDTH - PAD * 2)
    content:SetHeight(1)

    local foot = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    foot:SetPoint("BOTTOMLEFT", PAD, 12)
    foot:SetText("Click: waypoint  ·  Shift: share  ·  Ctrl: quest link  ·  /dqh")

    frame:SetScript("OnEvent", function(_, event, arg1)
        if event == "PLAYER_LEVEL_UP" then ns.levelOverride = arg1 end
        QueueRefresh()
    end)
    frame:SetScript("OnShow", function(self)
        for _, ev in ipairs(EVENTS) do self:RegisterEvent(ev) end
        if not manualPick then
            local pick
            for i, d in ipairs(DUNGEONS) do if d.key == DungeonQuestHelperDB.last then pick = i end end
            current = pick or PickDungeon(PlayerLevel())
        end
        SelectDungeon(current)
    end)
    frame:SetScript("OnHide", function(self)
        self:UnregisterAllEvents()
        GameTooltip_Hide()
    end)
end

local function Toggle(key)
    if not frame then Build() end
    if key then
        for i, d in ipairs(DUNGEONS) do
            if d.key == key then
                manualPick = true
                DungeonQuestHelperDB.last = d.key
                current = i
                if frame:IsShown() then SelectDungeon(i, true) else frame:Show() end
                return
            end
        end
    end
    frame:SetShown(not frame:IsShown())
end
ns.Toggle = Toggle

SLASH_DUNGEONQUESTHELPER1 = "/dqh"
SLASH_DUNGEONQUESTHELPER2 = "/dungeonquests"
SlashCmdList.DUNGEONQUESTHELPER = function(msg)
    msg = (msg or ""):lower():match("^%s*(.-)%s*$")
    if msg == "reset" then
        DungeonQuestHelperDB = DungeonQuestHelperDB or {}
        DungeonQuestHelperDB.pos, DungeonQuestHelperDB.last = nil, nil
        manualPick = false
        if frame then frame:ClearAllPoints(); frame:SetPoint("CENTER", -300, 80) end
        print(GOLD .. "Dungeon Quest Helper:|r position and dungeon choice reset.")
        return
    elseif msg == "minimap" then
        if ns.SetMinimapButtonShown then ns.SetMinimapButtonShown() end
        return
    elseif msg == "help" then
        local keys = {}
        for _, d in ipairs(DUNGEONS) do keys[#keys + 1] = d.key end
        print(GOLD .. "Dungeon Quest Helper:|r /dqh  toggle   ·  /dqh " .. table.concat(keys, " | ")
            .. "  open a dungeon   ·  /dqh minimap  show/hide button   ·  /dqh reset")
        return
    end
    Toggle(msg ~= "" and msg or nil)
end
