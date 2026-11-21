-- Minimap button. One small button, no events after load, and an OnUpdate only while dragging.

local ADDON, ns = ...
local ICON = "Interface\\Icons\\INV_Misc_Book_09"
local button

local function Place()
    local angle = math.rad(DungeonQuestHelperDB.minimap.angle or 200)
    local r = (Minimap:GetWidth() / 2) + 5
    button:ClearAllPoints()
    button:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * r, math.sin(angle) * r)
end

local function DragUpdate()
    local mx, my = Minimap:GetCenter()
    local scale = Minimap:GetEffectiveScale()
    local cx, cy = GetCursorPosition()
    DungeonQuestHelperDB.minimap.angle = math.deg(math.atan2(cy / scale - my, cx / scale - mx))
    Place()
end

local function Create()
    button = CreateFrame("Button", "DungeonQuestHelperMinimapButton", Minimap)
    button:SetSize(31, 31)
    button:SetFrameStrata("MEDIUM")
    button:SetFrameLevel(8)
    button:RegisterForClicks("LeftButtonUp")
    button:RegisterForDrag("LeftButton")
    button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    local bg = button:CreateTexture(nil, "BACKGROUND")
    bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
    bg:SetSize(20, 20)
    bg:SetPoint("TOPLEFT", 7, -5)
    local icon = button:CreateTexture(nil, "ARTWORK")
    icon:SetTexture(ICON)
    icon:SetSize(17, 17)
    icon:SetPoint("TOPLEFT", 7, -6)
    icon:SetTexCoord(0.05, 0.95, 0.05, 0.95)
    local border = button:CreateTexture(nil, "OVERLAY")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    border:SetSize(53, 53)
    border:SetPoint("TOPLEFT")

    button:SetScript("OnClick", function() ns.Toggle() end)
    button:SetScript("OnDragStart", function(self) self:SetScript("OnUpdate", DragUpdate) end)
    button:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
    button:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("Dungeon Quest Helper")
        GameTooltip:AddLine("Click: open or close", 0.8, 0.8, 0.8)
        GameTooltip:AddLine("Drag: move this button", 0.8, 0.8, 0.8)
        GameTooltip:AddLine("/dqh minimap: hide it", 0.6, 0.6, 0.6)
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", GameTooltip_Hide)
    Place()
end

-- Show or hide the button; with no argument, flips the saved setting.
function ns.SetMinimapButtonShown(show)
    local db = DungeonQuestHelperDB.minimap
    if show == nil then show = db.hide end
    db.hide = not show
    if show then
        if not button then Create() end
        button:Show()
    elseif button then
        button:Hide()
    end
end

-- SavedVariables aren't readable until ADDON_LOADED; handle it once and drop the event.
local loader = CreateFrame("Frame")
loader:RegisterEvent("ADDON_LOADED")
loader:SetScript("OnEvent", function(self, _, name)
    if name ~= ADDON then return end
    self:UnregisterAllEvents()
    self:SetScript("OnEvent", nil)
    DungeonQuestHelperDB = DungeonQuestHelperDB or {}
    DungeonQuestHelperDB.minimap = DungeonQuestHelperDB.minimap or { angle = 200, hide = false }
    if not DungeonQuestHelperDB.minimap.hide then ns.SetMinimapButtonShown(true) end
end)
