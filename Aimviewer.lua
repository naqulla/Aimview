-- ================================================================
-- Universal Da Hood  |  v1.7
-- ================================================================
if not game:IsLoaded() then game.Loaded:Wait() end

local Players          = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService       = game:GetService("RunService")

local LP        = Players.LocalPlayer
local PlayerGui = LP:WaitForChild("PlayerGui")
local CAM       = workspace.CurrentCamera

pcall(function() PlayerGui.UDH_Main:Destroy() end)
pcall(function() game:GetService("CoreGui").UDH_Main:Destroy() end)

-- ================================================================
-- CONFIG
-- ================================================================
local CFG = {
    AimbotEnabled = false,
    HoldMode      = false,
    TeamCheck     = true,
    WallCheck     = true,
    DeadCheck     = true,
    ToggleKey     = Enum.KeyCode.CapsLock,
    HoldKey       = Enum.KeyCode.E,
    MenuKey       = Enum.KeyCode.RightControl,
    Smoothness    = 50,      -- 0 = instant snap, 100 = very slow
    Prediction    = 0,       -- 0-100 scale
    FovVisible    = true,
    FovRadius     = 80,
    FovColor      = Color3.fromRGB(148, 0, 211),
    TargetPart    = "HumanoidRootPart",  -- which body part to aim at
}

-- Target part options (display name → character part name)
local TARGET_PARTS = {
    { label = "HumanoidRootPart", key = "HumanoidRootPart" },
    { label = "Head",             key = "Head"             },
    { label = "Torso",            key = "Torso"            },
    { label = "UpperTorso",       key = "UpperTorso"       },
    { label = "Left Arm",         key = "Left Arm"         },
    { label = "Right Arm",        key = "Right Arm"        },
    { label = "Left Leg",         key = "Left Leg"         },
    { label = "Right Leg",        key = "Right Leg"        },
}
local targetPartIdx = 1  -- current index into TARGET_PARTS

-- ================================================================
-- AIMBOT  —  velocity prediction via position-delta tracking
-- ================================================================
local aimbotActive  = false
local currentTarget = nil
local lpRoot        = nil

-- Per-player last-position cache for manual velocity calculation
-- We track position across frames because AssemblyLinearVelocity is
-- server-replicated and unreliable/zero on client for remote players
local prevPos   = {}   -- [player] = Vector3
local prevTick  = {}   -- [player] = tick()
local predVel   = {}   -- [player] = Vector3  smoothed velocity

LP.CharacterAdded:Connect(function(c)
    task.wait()
    lpRoot = c:FindFirstChild("HumanoidRootPart")
    currentTarget = nil
end)
LP.CharacterRemoving:Connect(function()
    lpRoot = nil; currentTarget = nil
end)
if LP.Character then lpRoot = LP.Character:FindFirstChild("HumanoidRootPart") end

local function isFreeCam()
    return CAM.CameraType == Enum.CameraType.Scriptable
end

-- Get the requested target part from a player's character
-- Priority: Da Hood hitbox folder → character body part → HumanoidRootPart fallback
local function getTargetPart(p)
    local char = p.Character
    if not char then return nil end

    local partKey = CFG.TargetPart

    -- For HumanoidRootPart always try the Da Hood hitbox first
    if partKey == "HumanoidRootPart" then
        local wsp = workspace:FindFirstChild("Players")
        if wsp then
            local pf = wsp:FindFirstChild(p.Name)
            if pf then
                local hb = pf:FindFirstChild("Hitbox")
                if hb then
                    return hb:FindFirstChild("Middle")
                        or hb:FindFirstChildOfClass("BasePart")
                end
            end
        end
    end

    -- Direct character lookup (handles both R6 and R15 naming)
    local part = char:FindFirstChild(partKey)
    if part then return part end

    -- R15/R6 fallback mappings
    local fallback = {
        Torso      = char:FindFirstChild("UpperTorso") or char:FindFirstChild("Torso"),
        UpperTorso = char:FindFirstChild("Torso")      or char:FindFirstChild("UpperTorso"),
        ["Left Arm"]  = char:FindFirstChild("LeftUpperArm")  or char:FindFirstChild("Left Arm"),
        ["Right Arm"] = char:FindFirstChild("RightUpperArm") or char:FindFirstChild("Right Arm"),
        ["Left Leg"]  = char:FindFirstChild("LeftUpperLeg")  or char:FindFirstChild("Left Leg"),
        ["Right Leg"] = char:FindFirstChild("RightUpperLeg") or char:FindFirstChild("Right Leg"),
    }
    if fallback[partKey] then return fallback[partKey] end

    -- Final fallback
    return char:FindFirstChild("HumanoidRootPart")
end

-- Update velocity prediction cache every frame for all players
local VEL_ALPHA = 0.35  -- EMA smoothing factor (higher = more responsive, noisier)
RunService.Heartbeat:Connect(function(dt)
    for _, p in ipairs(Players:GetPlayers()) do
        if p == LP then continue end
        local hrp = p.Character and p.Character:FindFirstChild("HumanoidRootPart")
        if hrp then
            local now = tick()
            local pos = hrp.Position
            if prevPos[p] then
                local elapsed = now - prevTick[p]
                if elapsed > 0 and elapsed < 0.5 then
                    local raw = (pos - prevPos[p]) / elapsed
                    -- Exponential moving average to smooth out jitter
                    local prev = predVel[p] or Vector3.zero
                    predVel[p] = prev + (raw - prev) * VEL_ALPHA
                end
            end
            prevPos[p]  = pos
            prevTick[p] = now
        else
            predVel[p]  = nil
            prevPos[p]  = nil
            prevTick[p] = nil
        end
    end
end)

local function isDead(p)
    local h = p.Character and p.Character:FindFirstChildWhichIsA("Humanoid")
    return not h or h.Health <= 0
end

local function isTeammate(p)
    return CFG.TeamCheck and LP.Team ~= nil and p.Team ~= nil and LP.Team == p.Team
end

local function hasWall(part)
    if not lpRoot then return false end

    -- Build exclusion list:
    -- We ALWAYS exclude every player character and every Da Hood workspace
    -- player folder unconditionally — NOT just the one that owns the target part.
    -- The old code only excluded them if IsAncestorOf(part) was true, which
    -- failed for Da Hood hitbox parts (they live in workspace.Players, not in
    -- the character model), so the ray was hitting the target's own body and
    -- returning true even with no wall present.
    local excl = {}

    -- Always exclude local player's character
    if LP.Character then table.insert(excl, LP.Character) end

    -- Da Hood stores player hitboxes in workspace.Players.NAME
    local wspPlayers = workspace:FindFirstChild("Players")

    for _, p in ipairs(Players:GetPlayers()) do
        if p == LP then continue end

        -- Always exclude every remote character model
        if p.Character then
            table.insert(excl, p.Character)
        end

        -- Always exclude their workspace hitbox folder if it exists
        if wspPlayers then
            local pf = wspPlayers:FindFirstChild(p.Name)
            if pf then table.insert(excl, pf) end
        end
    end

    local rp = RaycastParams.new()
    rp.FilterType = Enum.RaycastFilterType.Exclude
    rp.FilterDescendantsInstances = excl

    -- Cast from our root toward the target part
    local origin = lpRoot.Position
    local dir    = part.Position - origin
    local result = workspace:Raycast(origin, dir, rp)

    -- A hit means something solid (a wall/floor/object) is between us and target
    return result ~= nil
end

local function screenDist(part)
    local sp, vis = CAM:WorldToViewportPoint(part.Position)
    if not vis then return math.huge end
    local mp = UserInputService:GetMouseLocation()
    return math.sqrt((sp.X - mp.X)^2 + (sp.Y - mp.Y)^2)
end

local function getBest()
    local bPart, bDist, bPlayer = nil, math.huge, nil
    for _, p in ipairs(Players:GetPlayers()) do
        if p == LP then continue end
        if isTeammate(p) then continue end
        if CFG.DeadCheck and isDead(p) then continue end
        local part = getTargetPart(p)
        if not part then continue end
        if CFG.WallCheck and hasWall(part) then continue end
        local sd = screenDist(part)
        if sd < CFG.FovRadius and sd < bDist then
            bDist = sd; bPart = part; bPlayer = p
        end
    end
    return bPart and {part = bPart, player = bPlayer} or nil
end

-- Prediction: lead = smoothed_velocity × ping × strength_scale
-- Uses position-delta velocity tracked above — reliable on all executors
local function getPredPos(entry)
    local p    = entry.player
    local part = entry.part
    local base = part.Position

    if CFG.Prediction == 0 then return base end

    local vel = predVel[p]
    if not vel then return base end

    -- Ping in seconds (GetNetworkPing returns seconds on modern Roblox)
    local ping  = math.clamp(LP:GetNetworkPing(), 0, 0.4)
    -- strength: 0→0 lead,  100→full ping lead
    local scale = (CFG.Prediction / 100) * ping * 1.8
    -- Only apply XZ (horizontal) lead — vertical prediction causes overshooting
    return base + Vector3.new(vel.X * scale, 0, vel.Z * scale)
end

local function moveMouse(worldPos)
    local sp, vis = CAM:WorldToViewportPoint(worldPos)
    if not vis then return end
    local mp  = UserInputService:GetMouseLocation()
    local a   = math.clamp(1 - (CFG.Smoothness / 100) * 0.97, 0.03, 1)
    local nx  = mp.X + (sp.X - mp.X) * a
    local ny  = mp.Y + (sp.Y - mp.Y) * a
    if mousemoveto then
        mousemoveto(nx, ny)
    elseif mousemoverel then
        mousemoverel(nx - mp.X, ny - mp.Y)
    else
        pcall(function()
            game:GetService("VirtualInputManager"):SendMouseMoveEvent(nx, ny, game)
        end)
    end
end

-- Main aimbot loop (separate from the velocity-tracking Heartbeat above)
RunService.Heartbeat:Connect(function()
    local active
    if CFG.HoldMode then
        active = UserInputService:IsKeyDown(CFG.HoldKey)
    else
        active = aimbotActive
    end

    if not active or not CFG.AimbotEnabled or isFreeCam() then
        currentTarget = nil; return
    end

    if currentTarget then
        local p, hb = currentTarget.player, currentTarget.part
        if  not p or not p.Parent or not p.Character
            or (CFG.DeadCheck and isDead(p))
            or (CFG.WallCheck and hasWall(hb))
            or screenDist(hb) > CFG.FovRadius * 3
        then
            currentTarget = nil
        end
    end

    if not currentTarget then currentTarget = getBest() end
    if currentTarget      then moveMouse(getPredPos(currentTarget)) end
end)

-- ================================================================
-- THEME
-- FIX #1: Background lifted to RGB(32,32,35) — clearly visible in dark scenes
-- FIX #2: Borders at RGB(62,62,68) — 3:1 contrast vs background
-- FIX #3: Three-tier color hierarchy: purple accent / gray interactive / dim inactive
-- FIX #4: Panel headers use a distinct slightly lighter hue than window bg
-- FIX #5: Row bg noticeably lighter than panel bg — hierarchy is readable
-- ================================================================
local C = {
    -- Backgrounds (graduated so every level is distinct)
    win      = Color3.fromRGB(32,  32,  36),   -- window
    panel    = Color3.fromRGB(38,  38,  42),   -- panel card
    hdr      = Color3.fromRGB(28,  28,  32),   -- panel header strip (darker = title feels "above")
    row      = Color3.fromRGB(46,  46,  51),   -- interactive row — clearly lighter than panel
    rowHov   = Color3.fromRGB(56,  56,  62),   -- hover state — clearly different from normal
    btn      = Color3.fromRGB(36,  36,  40),   -- keybind / mode button bg
    slBg     = Color3.fromRGB(24,  24,  28),   -- slider track (darkest — negative space)
    -- Borders — visible but not loud
    bdr      = Color3.fromRGB(62,  62,  68),   -- FIX: was 28 (invisible). Now 62 = readable edge
    bdrSub   = Color3.fromRGB(48,  48,  54),   -- slightly softer for inner dividers
    -- Accent hierarchy
    purple   = Color3.fromRGB(148,  0, 211),   -- primary: active/on states only
    purpleDim= Color3.fromRGB( 90,  0, 130),   -- secondary: slider fills, inactive accents
    purpleSep= Color3.fromRGB(110,  0, 165),   -- separator line
    -- Status colours
    green    = Color3.fromRGB( 50, 210,  90),  -- aimbot ON indicator
    red      = Color3.fromRGB(220,  55,  55),  -- aimbot OFF indicator
    -- Text hierarchy (FIX #3: three distinct levels)
    txtPrim  = Color3.fromRGB(222, 222, 226),  -- primary: labels, values
    txtSec   = Color3.fromRGB(155, 155, 162),  -- secondary: sub-labels, hints
    txtDim   = Color3.fromRGB( 90,  90,  96),  -- tertiary: disabled / section labels
    -- Checkbox
    cbOff    = Color3.fromRGB(28,  28,  32),
    cbBdr    = Color3.fromRGB(72,  72,  78),   -- FIX: was 55 (barely visible)
    -- Misc
    black    = Color3.fromRGB( 0,   0,   0),
}

-- FIX #4: Font size hierarchy — three distinct sizes for three distinct levels
local FONT      = Enum.Font.Arcade
local FS_HDR    = 12   -- panel titles
local FS_LABEL  = 11   -- row labels (was 10 — too small)
local FS_VALUE  = 10   -- values, hints, secondary text
local FS_DIM    = 9    -- section sub-headers

local ROW_H  = 24    -- FIX: unified row height (was mixed 22/36+14)
local SL_H   = ROW_H + 16  -- slider total height (label row + track row)
local GAP    = 5     -- FIX: slightly more breathing room between rows
local MARGIN = 9

-- ── Helpers ──────────────────────────────────────────────────────

local function cr(r, inst)
    Instance.new("UICorner", inst).CornerRadius = UDim.new(0, r)
end

local function mkFrame(parent, bg, bdrPx, bdrCol)
    local f = Instance.new("Frame", parent)
    f.BackgroundColor3 = bg     or C.row
    f.BorderSizePixel  = bdrPx  or 1
    f.BorderColor3     = bdrCol or C.bdr
    return f
end

-- FIX #4: text helper now takes explicit size
local function mkTxt(parent, text, color, size, xalign)
    local l = Instance.new("TextLabel", parent)
    l.BackgroundTransparency = 1
    l.BorderSizePixel        = 0
    l.Text                   = text
    l.TextColor3             = color  or C.txtPrim
    l.Font                   = FONT
    l.TextSize               = size   or FS_LABEL
    l.TextXAlignment         = xalign or Enum.TextXAlignment.Left
    l.TextYAlignment         = Enum.TextYAlignment.Center
    -- FIX #5: solid black outline — Minecraft style, readable on any bg
    l.TextStrokeColor3       = C.black
    l.TextStrokeTransparency = 0
    return l
end

-- ================================================================
-- COLOR PICKER (HSV wheel + value bar + hex input)
-- ================================================================
local function toHex(c)
    return string.format("%02X%02X%02X",
        math.floor(c.R*255+0.5), math.floor(c.G*255+0.5), math.floor(c.B*255+0.5))
end
local function fromHex(s)
    s = s:gsub("#",""):upper()
    if #s ~= 6 then return nil end
    local r,g,b = tonumber(s:sub(1,2),16), tonumber(s:sub(3,4),16), tonumber(s:sub(5,6),16)
    return (r and g and b) and Color3.fromRGB(r,g,b) or nil
end

local CP_W, CP_H = 220, 250

local function buildPicker(winRef, initCol, onApply)
    local backdrop = Instance.new("TextButton", winRef)
    backdrop.Size=UDim2.new(1,0,1,0); backdrop.BackgroundColor3=C.black
    backdrop.BackgroundTransparency=0.5; backdrop.BorderSizePixel=0
    backdrop.Text=""; backdrop.ZIndex=30

    local card = mkFrame(backdrop, C.panel, 1, C.bdr)
    card.Size=UDim2.new(0,CP_W,0,CP_H)
    card.Position=UDim2.new(0.5,-CP_W/2,0.5,-CP_H/2)
    card.ClipsDescendants=true; card.ZIndex=31; cr(6,card)

    local titleLbl = mkTxt(card,"color picker",C.txtSec,FS_VALUE)
    titleLbl.Size=UDim2.new(1,-30,0,22); titleLbl.Position=UDim2.new(0,8,0,0); titleLbl.ZIndex=32

    local closeBtn = Instance.new("TextButton",card)
    closeBtn.Size=UDim2.new(0,22,0,22); closeBtn.Position=UDim2.new(1,-24,0,0)
    closeBtn.BackgroundColor3=C.btn; closeBtn.BorderSizePixel=1; closeBtn.BorderColor3=C.bdr
    closeBtn.Text="x"; closeBtn.TextColor3=C.txtSec; closeBtn.Font=FONT
    closeBtn.TextSize=FS_LABEL; closeBtn.AutoButtonColor=false; closeBtn.ZIndex=32; cr(3,closeBtn)

    -- HSV wheel
    local WS = 140
    local wheel = Instance.new("ImageLabel",card)
    wheel.Size=UDim2.new(0,WS,0,WS); wheel.Position=UDim2.new(0.5,-WS/2,0,26)
    wheel.BackgroundTransparency=1; wheel.BorderSizePixel=0
    wheel.Image="rbxassetid://4155801252"; wheel.ZIndex=32

    local dimOv = mkFrame(wheel, C.black, 0)
    dimOv.Size=UDim2.new(1,0,1,0); dimOv.BackgroundTransparency=1; dimOv.ZIndex=33; cr(9999,dimOv)

    local dot = mkFrame(wheel, Color3.fromRGB(255,255,255), 1, C.black)
    dot.Size=UDim2.new(0,8,0,8); dot.ZIndex=34; cr(4,dot)

    -- Value bar
    local VAL_Y = 26 + WS + 8
    local valBar = mkFrame(card, C.black, 1, C.bdr)
    valBar.Size=UDim2.new(0,WS,0,12); valBar.Position=UDim2.new(0.5,-WS/2,0,VAL_Y); valBar.ZIndex=32; cr(3,valBar)
    local valGrad = Instance.new("UIGradient",valBar); valGrad.Rotation=90
    local valDot = mkFrame(valBar,Color3.fromRGB(255,255,255),1,C.black)
    valDot.Size=UDim2.new(0,6,1,4); valDot.ZIndex=33; cr(2,valDot)

    -- Preview + hex
    local PREV_Y = VAL_Y + 22
    local preview = mkFrame(card,initCol,1,C.bdr)
    preview.Size=UDim2.new(0,28,0,20); preview.Position=UDim2.new(0,8,0,PREV_Y); preview.ZIndex=32; cr(3,preview)

    local hexLbl = mkTxt(card,"#",C.txtDim,FS_VALUE)
    hexLbl.Size=UDim2.new(0,10,0,20); hexLbl.Position=UDim2.new(0,40,0,PREV_Y); hexLbl.ZIndex=32

    local hexBox = Instance.new("TextBox",card)
    hexBox.Size=UDim2.new(0,78,0,20); hexBox.Position=UDim2.new(0,52,0,PREV_Y)
    hexBox.BackgroundColor3=C.btn; hexBox.BorderSizePixel=1; hexBox.BorderColor3=C.bdr
    hexBox.Text=toHex(initCol); hexBox.TextColor3=C.txtPrim
    hexBox.Font=FONT; hexBox.TextSize=FS_VALUE; hexBox.ClearTextOnFocus=false
    hexBox.TextStrokeColor3=C.black; hexBox.TextStrokeTransparency=0
    hexBox.ZIndex=32; cr(3,hexBox)

    local okBtn = Instance.new("TextButton",card)
    okBtn.Size=UDim2.new(0,38,0,20); okBtn.Position=UDim2.new(1,-44,0,PREV_Y)
    okBtn.BackgroundColor3=C.purple; okBtn.BorderSizePixel=0
    okBtn.Text="ok"; okBtn.TextColor3=C.txtPrim
    okBtn.Font=FONT; okBtn.TextSize=FS_LABEL; okBtn.AutoButtonColor=false; okBtn.ZIndex=32; cr(3,okBtn)

    -- State
    local cH,cS,cV = Color3.toHSV(initCol)
    local function refresh()
        local col = Color3.fromHSV(cH,cS,cV)
        preview.BackgroundColor3 = col
        hexBox.Text = toHex(col)
        local pure = Color3.fromHSV(cH,1,1)
        valGrad.Color = ColorSequence.new({
            ColorSequenceKeypoint.new(0, Color3.fromRGB(0,0,0)),
            ColorSequenceKeypoint.new(1, pure)
        })
        valDot.Position = UDim2.new(cV,-3,0,-2)
        dimOv.BackgroundTransparency = cV
        local ang = cH * math.pi * 2
        local rad = cS * (WS/2 - 5)
        dot.Position = UDim2.new(0, WS/2 + rad*math.cos(ang) - 4, 0, WS/2 + rad*math.sin(ang) - 4)
    end
    refresh()

    -- Drag wheel
    local dW,dV = false,false
    local function setHS(mx,my)
        local wx = wheel.AbsolutePosition.X + WS/2
        local wy = wheel.AbsolutePosition.Y + WS/2
        local dx,dy = mx-wx, my-wy
        cH = (math.atan2(dy,dx)/(math.pi*2)) % 1
        cS = math.clamp(math.sqrt(dx*dx+dy*dy)/(WS/2),0,1)
        refresh()
    end
    local function setV(mx)
        cV = math.clamp((mx-valBar.AbsolutePosition.X)/math.max(valBar.AbsoluteSize.X,1),0,1)
        refresh()
    end
    wheel.InputBegan:Connect(function(i)
        if i.UserInputType==Enum.UserInputType.MouseButton1 then dW=true; setHS(i.Position.X,i.Position.Y) end
    end)
    valBar.InputBegan:Connect(function(i)
        if i.UserInputType==Enum.UserInputType.MouseButton1 then dV=true; setV(i.Position.X) end
    end)
    UserInputService.InputChanged:Connect(function(i)
        if i.UserInputType~=Enum.UserInputType.MouseMovement then return end
        if dW then setHS(i.Position.X,i.Position.Y) end
        if dV then setV(i.Position.X) end
    end)
    UserInputService.InputEnded:Connect(function(i)
        if i.UserInputType==Enum.UserInputType.MouseButton1 then dW=false; dV=false end
    end)
    hexBox.FocusLost:Connect(function()
        local c = fromHex(hexBox.Text)
        if c then cH,cS,cV = Color3.toHSV(c); refresh()
        else hexBox.Text = toHex(Color3.fromHSV(cH,cS,cV)) end
    end)
    okBtn.MouseButton1Click:Connect(function()
        if onApply then onApply(Color3.fromHSV(cH,cS,cV)) end
        backdrop:Destroy()
    end)
    closeBtn.MouseButton1Click:Connect(function() backdrop:Destroy() end)
    backdrop.MouseButton1Click:Connect(function() backdrop:Destroy() end)
    card.InputBegan:Connect(function(i) if i.UserInputType==Enum.UserInputType.MouseButton1 then end end)
end

-- ================================================================
-- SCREENGUI + WINDOW
-- ================================================================
local sg = Instance.new("ScreenGui")
sg.Name="UDH_Main"; sg.ResetOnSpawn=false
sg.ZIndexBehavior=Enum.ZIndexBehavior.Sibling; sg.DisplayOrder=9999; sg.IgnoreGuiInset=true
if not pcall(function() sg.Parent=game:GetService("CoreGui") end) then sg.Parent=PlayerGui end

local W,H = 510,500

local win = mkFrame(sg, C.win, 1, C.bdr)
win.Name="Window"; win.Size=UDim2.new(0,W,0,H)
win.Position=UDim2.new(0.5,-W/2,0.5,-H/2); win.ClipsDescendants=true; cr(7,win)

-- Title bar
local TITLE_H=22
local titleBar = mkFrame(win, C.hdr, 0)
titleBar.Size=UDim2.new(1,0,0,TITLE_H)
local titleTxt = mkTxt(titleBar,"obelus  |  Universal Da Hood",C.txtSec,FS_VALUE)
titleTxt.Size=UDim2.new(1,-10,1,0); titleTxt.Position=UDim2.new(0,8,0,0)

-- FIX: Status indicator dot — shows whether aimbot is active
-- Tiny coloured circle right side of title bar
local statusDot = mkFrame(titleBar, C.red, 0)
statusDot.Size=UDim2.new(0,7,0,7); statusDot.Position=UDim2.new(1,-14,0.5,-4); cr(4,statusDot)

-- Update dot colour every frame
RunService.RenderStepped:Connect(function()
    local active
    if CFG.HoldMode then
        active = CFG.AimbotEnabled and UserInputService:IsKeyDown(CFG.HoldKey)
    else
        active = CFG.AimbotEnabled and aimbotActive
    end
    statusDot.BackgroundColor3 = active and C.green or C.red
end)

-- Purple separator
local purpLine = mkFrame(win, C.purpleSep, 0)
purpLine.Size=UDim2.new(1,0,0,1); purpLine.Position=UDim2.new(0,0,0,TITLE_H)

-- Drag
do
    local dA,dS,wS=false,nil,nil
    titleBar.InputBegan:Connect(function(i)
        if i.UserInputType==Enum.UserInputType.MouseButton1 then dA=true;dS=i.Position;wS=win.Position end
    end)
    titleBar.InputEnded:Connect(function(i)
        if i.UserInputType==Enum.UserInputType.MouseButton1 then dA=false end
    end)
    UserInputService.InputChanged:Connect(function(i)
        if dA and i.UserInputType==Enum.UserInputType.MouseMovement then
            local d=i.Position-dS
            win.Position=UDim2.new(wS.X.Scale,wS.X.Offset+d.X,wS.Y.Scale,wS.Y.Offset+d.Y)
        end
    end)
end

-- Tab bar
local TAB_Y=TITLE_H+1; local TAB_H=24
local tabBar=mkFrame(win,C.hdr,0)
tabBar.Size=UDim2.new(1,0,0,TAB_H); tabBar.Position=UDim2.new(0,0,0,TAB_Y)
local tabLine=mkFrame(tabBar,C.bdr,0)
tabLine.Size=UDim2.new(1,0,0,1); tabLine.Position=UDim2.new(0,0,1,-1)

local TABS={"aimbot","visuals","misc","config"}
local tabBtns,tabPages={},{}
local TW=math.floor(W/#TABS)
for i,name in ipairs(TABS) do
    local b=Instance.new("TextButton",tabBar)
    b.Size=UDim2.new(0,TW,1,-1); b.Position=UDim2.new(0,(i-1)*TW,0,0)
    b.BackgroundColor3=i==1 and C.win or C.hdr
    b.BorderSizePixel=0; b.AutoButtonColor=false
    b.Font=FONT; b.TextSize=FS_LABEL; b.Text=name
    b.TextColor3=i==1 and C.purple or C.txtSec
    b.TextStrokeColor3=C.black; b.TextStrokeTransparency=0
    if i<#TABS then
        local dv=mkFrame(b,C.bdrSub,0)
        dv.Size=UDim2.new(0,1,0.55,0); dv.Position=UDim2.new(1,-1,0.225,0)
    end
    tabBtns[i]=b
end

local CONTENT_Y=TAB_Y+TAB_H+1
for i=1,#TABS do
    local f=Instance.new("Frame",win)
    f.Size=UDim2.new(1,0,1,-CONTENT_Y); f.Position=UDim2.new(0,0,0,CONTENT_Y)
    f.BackgroundTransparency=1; f.BorderSizePixel=0; f.Visible=(i==1); f.ClipsDescendants=true
    tabPages[i]=f
end

local function switchTab(idx)
    for i,b in ipairs(tabBtns) do
        b.TextColor3=i==idx and C.purple or C.txtSec
        b.BackgroundColor3=i==idx and C.win or C.hdr
        tabPages[i].Visible=i==idx
    end
end
for i,b in ipairs(tabBtns) do
    b.MouseButton1Click:Connect(function() switchTab(i) end)
    b.MouseEnter:Connect(function() if not tabPages[i].Visible then b.TextColor3=C.txtPrim end end)
    b.MouseLeave:Connect(function() if not tabPages[i].Visible then b.TextColor3=C.txtSec end end)
end

-- ================================================================
-- PANEL BUILDER
-- ================================================================
local function mkPanel(parent, title, x, y, pw, ph)
    local card=mkFrame(parent,C.panel,1,C.bdr)
    card.Size=UDim2.new(0,pw,0,ph); card.Position=UDim2.new(0,x,0,y)
    card.ClipsDescendants=true; cr(5,card)

    local HDR_H=ROW_H+2
    local hdr=mkFrame(card,C.hdr,0)
    hdr.Size=UDim2.new(1,0,0,HDR_H)
    -- FIX: panel title uses FS_HDR (12) — distinct from row labels (11) and values (10)
    local hl=mkTxt(hdr,title,C.txtPrim,FS_HDR)
    hl.Size=UDim2.new(1,-10,1,0); hl.Position=UDim2.new(0,8,0,0)

    local hs=mkFrame(card,C.bdrSub,0)
    hs.Size=UDim2.new(1,0,0,1); hs.Position=UDim2.new(0,0,0,HDR_H)

    local scroll=Instance.new("ScrollingFrame",card)
    scroll.Size=UDim2.new(1,0,1,-(HDR_H+1)); scroll.Position=UDim2.new(0,0,0,HDR_H+1)
    scroll.BackgroundTransparency=1; scroll.BorderSizePixel=0
    scroll.ScrollBarThickness=3; scroll.ScrollBarImageColor3=C.purple
    scroll.CanvasSize=UDim2.new(0,0,0,0); scroll.AutomaticCanvasSize=Enum.AutomaticSize.Y
    scroll.ElasticBehavior=Enum.ElasticBehavior.Never

    local pad=Instance.new("UIPadding",scroll)
    pad.PaddingLeft=UDim.new(0,6); pad.PaddingRight=UDim.new(0,6)
    pad.PaddingTop=UDim.new(0,6);  pad.PaddingBottom=UDim.new(0,6)
    local lay=Instance.new("UIListLayout",scroll)
    lay.SortOrder=Enum.SortOrder.LayoutOrder; lay.Padding=UDim.new(0,GAP)
    lay.FillDirection=Enum.FillDirection.Vertical
    return scroll
end

-- ================================================================
-- COMPONENT LIBRARY  (all fixes applied)
-- ================================================================

-- FIX: section separator line flush with rows
local function mkLine(sc,ord)
    local f=Instance.new("Frame",sc)
    f.Size=UDim2.new(1,0,0,10); f.BackgroundTransparency=1; f.BorderSizePixel=0; f.LayoutOrder=ord
    local l=mkFrame(f,C.bdrSub,0)
    l.Size=UDim2.new(1,-4,0,1); l.Position=UDim2.new(0,2,0.5,0)
end

-- FIX: sub-label uses txtDim (dimmer) + FS_DIM (9px) so it reads as metadata not content
local function mkSub(sc,text,ord)
    local f=Instance.new("Frame",sc)
    f.Size=UDim2.new(1,0,0,14); f.BackgroundTransparency=1; f.BorderSizePixel=0; f.LayoutOrder=ord
    local l=mkTxt(f,text,C.txtDim,FS_DIM)
    l.Size=UDim2.new(1,0,1,0); l.Position=UDim2.new(0,4,0,0)
end

-- FIX: unified ROW_H for ALL rows including checkbox
-- FIX: checkbox border at C.cbBdr (72) instead of 55 — clearly visible
local function mkCheck(sc,text,default,onChange,ord)
    local f=mkFrame(sc,C.row,1,C.bdr)
    f.Size=UDim2.new(1,0,0,ROW_H); f.LayoutOrder=ord; cr(4,f)

    local cb=mkFrame(f, default and C.purple or C.cbOff, 1,
        default and C.purple or C.cbBdr)
    cb.Size=UDim2.new(0,11,0,11); cb.Position=UDim2.new(0,6,0.5,-6); cr(2,cb)

    local lb=mkTxt(f,text,C.txtPrim,FS_LABEL)
    lb.Size=UDim2.new(1,-24,1,0); lb.Position=UDim2.new(0,23,0,0)

    local hit=Instance.new("TextButton",f)
    hit.Size=UDim2.new(1,0,1,0); hit.BackgroundTransparency=1; hit.Text=""
    hit.BorderSizePixel=0; hit.ZIndex=5

    local val=default
    hit.MouseButton1Click:Connect(function()
        val=not val
        cb.BackgroundColor3=val and C.purple or C.cbOff
        cb.BorderColor3    =val and C.purple or C.cbBdr
        if onChange then onChange(val) end
    end)
    hit.MouseEnter:Connect(function() f.BackgroundColor3=C.rowHov end)
    hit.MouseLeave:Connect(function() f.BackgroundColor3=C.row end)
    local function sync(v)
        val=v; cb.BackgroundColor3=v and C.purple or C.cbOff; cb.BorderColor3=v and C.purple or C.cbBdr
    end
    return f,sync
end

-- FIX: slider total height = SL_H (uniform), touch target extended to full row height
-- FIX: slider track is visually darker than row (negative space principle)
local function mkSlider(sc,text,mn,mx,init,suf,onChange,ord)
    local f=mkFrame(sc,C.row,1,C.bdr)
    f.Size=UDim2.new(1,0,0,SL_H); f.LayoutOrder=ord; cr(4,f)

    local lt=mkTxt(f,text,C.txtPrim,FS_LABEL)
    lt.Size=UDim2.new(0.58,0,0,ROW_H); lt.Position=UDim2.new(0,8,0,0)

    local vt=mkTxt(f,tostring(init)..(suf or ""),C.txtSec,FS_VALUE,Enum.TextXAlignment.Right)
    vt.Size=UDim2.new(0.36,0,0,ROW_H); vt.Position=UDim2.new(0.62,0,0,0)

    local track=mkFrame(f,C.slBg,1,C.bdr)
    track.Size=UDim2.new(1,-14,0,7); track.Position=UDim2.new(0,7,0,ROW_H+5); cr(3,track)

    local pct=(init-mn)/math.max(mx-mn,1)
    local fill=mkFrame(track,C.purple,0)
    fill.Size=UDim2.new(pct,0,1,0); cr(3,fill)

    local drag=false
    local function upd(ax)
        local t=math.clamp((ax-track.AbsolutePosition.X)/math.max(track.AbsoluteSize.X,1),0,1)
        local v=math.floor(mn+t*(mx-mn)+0.5)
        t=(v-mn)/math.max(mx-mn,1)
        fill.Size=UDim2.new(t,0,1,0); vt.Text=tostring(v)..(suf or "")
        if onChange then onChange(v) end
    end
    -- FIX: hit area covers ENTIRE row height for easy grabbing
    local ib=Instance.new("TextButton",f)
    ib.Size=UDim2.new(1,0,1,0); ib.Position=UDim2.new(0,0,0,0)
    ib.BackgroundTransparency=1; ib.Text=""; ib.BorderSizePixel=0; ib.ZIndex=4
    ib.MouseButton1Down:Connect(function(ax) drag=true; upd(ax) end)
    UserInputService.InputChanged:Connect(function(i)
        if drag and i.UserInputType==Enum.UserInputType.MouseMovement then upd(i.Position.X) end
    end)
    UserInputService.InputEnded:Connect(function(i)
        if i.UserInputType==Enum.UserInputType.MouseButton1 then drag=false end
    end)
    f.MouseEnter:Connect(function() f.BackgroundColor3=C.rowHov end)
    f.MouseLeave:Connect(function() f.BackgroundColor3=C.row end)
end

-- Keybind row
-- FIX: keybind box border at C.bdr (62) — visually clear edge
local function mkKeybind(sc,text,default,onChange,ord)
    local f=mkFrame(sc,C.row,1,C.bdr)
    f.Size=UDim2.new(1,0,0,ROW_H); f.LayoutOrder=ord; cr(4,f)
    local lt=mkTxt(f,text,C.txtPrim,FS_LABEL)
    lt.Size=UDim2.new(0.5,0,1,0); lt.Position=UDim2.new(0,8,0,0)
    local kb=mkFrame(f,C.btn,1,C.bdr)
    kb.Size=UDim2.new(0,90,0,16); kb.Position=UDim2.new(1,-96,0.5,-8); cr(3,kb)
    local kt=mkTxt(kb,tostring(default):gsub("Enum%.KeyCode%.",""),C.purple,FS_VALUE,Enum.TextXAlignment.Center)
    kt.Size=UDim2.new(1,0,1,0)
    local hit=Instance.new("TextButton",f)
    hit.Size=UDim2.new(1,0,1,0); hit.BackgroundTransparency=1; hit.Text=""; hit.BorderSizePixel=0; hit.ZIndex=6
    local waiting=false
    hit.MouseButton1Click:Connect(function()
        if waiting then return end; waiting=true
        kt.Text="..."; kt.TextColor3=C.txtSec
        local conn
        conn=UserInputService.InputBegan:Connect(function(i,gp)
            if gp or i.UserInputType~=Enum.UserInputType.Keyboard then return end
            kt.Text=tostring(i.KeyCode):gsub("Enum%.KeyCode%.","")
            kt.TextColor3=C.purple; waiting=false
            if onChange then onChange(i.KeyCode) end; conn:Disconnect()
        end)
    end)
    f.MouseEnter:Connect(function() f.BackgroundColor3=C.rowHov end)
    f.MouseLeave:Connect(function() f.BackgroundColor3=C.row end)
end

-- Mode row (toggle/hold)
local function mkMode(sc,ord)
    local f=mkFrame(sc,C.row,1,C.bdr)
    f.Size=UDim2.new(1,0,0,ROW_H); f.LayoutOrder=ord; cr(4,f)
    local lt=mkTxt(f,"activation mode",C.txtPrim,FS_LABEL)
    lt.Size=UDim2.new(0.5,0,1,0); lt.Position=UDim2.new(0,8,0,0)
    local kb=mkFrame(f,C.btn,1,C.bdr)
    kb.Size=UDim2.new(0,90,0,16); kb.Position=UDim2.new(1,-96,0.5,-8); cr(3,kb)
    local mt=mkTxt(kb,CFG.HoldMode and "hold" or "toggle",C.purple,FS_VALUE,Enum.TextXAlignment.Center)
    mt.Size=UDim2.new(1,0,1,0)
    local hit=Instance.new("TextButton",f)
    hit.Size=UDim2.new(1,0,1,0); hit.BackgroundTransparency=1; hit.Text=""; hit.BorderSizePixel=0; hit.ZIndex=6
    hit.MouseButton1Click:Connect(function()
        CFG.HoldMode=not CFG.HoldMode; mt.Text=CFG.HoldMode and "hold" or "toggle"
    end)
    f.MouseEnter:Connect(function() f.BackgroundColor3=C.rowHov end)
    f.MouseLeave:Connect(function() f.BackgroundColor3=C.row end)
end

-- Target part dropdown
-- Clicking the row opens a list of all parts anchored just below the row.
-- Clicking any item selects it and closes the list. Clicking outside closes it.
local dropdownOpen = false
local dropdownFrame = nil  -- reference so we can destroy it on close

local function mkPartSelector(sc, ord)
    local ITEM_H = 20  -- height of each dropdown list item

    local f = mkFrame(sc, C.row, 1, C.bdr)
    f.Size        = UDim2.new(1, 0, 0, ROW_H)
    f.LayoutOrder = ord
    cr(4, f)

    local lt = mkTxt(f, "target part", C.txtPrim, FS_LABEL)
    lt.Size     = UDim2.new(0.45, 0, 1, 0)
    lt.Position = UDim2.new(0, 8, 0, 0)

    -- The "button" showing the currently selected part  [ Head  ▼ ]
    local selBox = mkFrame(f, C.btn, 1, C.bdr)
    selBox.Size     = UDim2.new(0, 112, 0, 17)
    selBox.Position = UDim2.new(1, -118, 0.5, -9)
    cr(3, selBox)

    local selTxt = mkTxt(selBox, TARGET_PARTS[targetPartIdx].label,
        C.purple, FS_VALUE, Enum.TextXAlignment.Center)
    selTxt.Size = UDim2.new(0.82, 0, 1, 0)

    -- Tiny chevron ▼ on the right of the box
    local chevron = mkTxt(selBox, "v", C.txtSec, FS_VALUE, Enum.TextXAlignment.Center)
    chevron.Size     = UDim2.new(0.18, 0, 1, 0)
    chevron.Position = UDim2.new(0.82, 0, 0, 0)

    -- Close the dropdown (destroy the list frame)
    local function closeDropdown()
        if dropdownFrame then
            dropdownFrame:Destroy()
            dropdownFrame = nil
        end
        dropdownOpen = false
        chevron.Text = "v"
    end

    -- Open the dropdown: build a list panel anchored below the row,
    -- parented to `win` so it floats above all scroll frames and panels.
    local function openDropdown()
        if dropdownOpen then closeDropdown(); return end
        dropdownOpen = true
        chevron.Text = "^"

        -- Calculate position in window space
        local absPos  = selBox.AbsolutePosition
        local winPos  = win.AbsolutePosition
        local relX    = absPos.X - winPos.X
        local relY    = absPos.Y - winPos.Y + selBox.AbsoluteSize.Y + 2

        local listH   = #TARGET_PARTS * ITEM_H + 2
        local listW   = selBox.AbsoluteSize.X

        local list = mkFrame(win, C.panel, 1, C.bdr)
        list.Size        = UDim2.new(0, listW, 0, listH)
        list.Position    = UDim2.new(0, relX, 0, relY)
        list.ZIndex      = 50
        list.ClipsDescendants = true
        cr(4, list)
        dropdownFrame = list

        local pad = Instance.new("UIPadding", list)
        pad.PaddingTop    = UDim.new(0, 1)
        pad.PaddingBottom = UDim.new(0, 1)
        local lay = Instance.new("UIListLayout", list)
        lay.SortOrder     = Enum.SortOrder.LayoutOrder
        lay.FillDirection = Enum.FillDirection.Vertical

        for i, entry in ipairs(TARGET_PARTS) do
            local isSelected = (i == targetPartIdx)

            local item = Instance.new("TextButton", list)
            item.Size               = UDim2.new(1, 0, 0, ITEM_H)
            item.BackgroundColor3   = isSelected and C.hdr or C.panel
            item.BorderSizePixel    = 0
            item.AutoButtonColor    = false
            item.Text               = ""
            item.LayoutOrder        = i
            item.ZIndex             = 51

            local itxt = mkTxt(item, entry.label,
                isSelected and C.purple or C.txtSec,
                FS_VALUE, Enum.TextXAlignment.Center)
            itxt.Size   = UDim2.new(1, 0, 1, 0)
            itxt.ZIndex = 52

            -- Thin separator between items (skip last)
            if i < #TARGET_PARTS then
                local sep = mkFrame(item, C.bdrSub, 0)
                sep.Size     = UDim2.new(1, -8, 0, 1)
                sep.Position = UDim2.new(0, 4, 1, -1)
                sep.ZIndex   = 52
            end

            item.MouseEnter:Connect(function()
                if i ~= targetPartIdx then
                    item.BackgroundColor3 = C.rowHov
                end
            end)
            item.MouseLeave:Connect(function()
                item.BackgroundColor3 = isSelected and C.hdr or C.panel
            end)

            item.MouseButton1Click:Connect(function()
                targetPartIdx     = i
                CFG.TargetPart    = entry.key
                currentTarget     = nil
                selTxt.Text       = entry.label
                closeDropdown()
            end)
        end

        -- Clicking anywhere on the window backdrop closes the list
        -- We do this with a transparent overlay behind the list
        local overlay = Instance.new("TextButton", win)
        overlay.Size                = UDim2.new(1, 0, 1, 0)
        overlay.BackgroundTransparency = 1
        overlay.BorderSizePixel     = 0
        overlay.Text                = ""
        overlay.ZIndex              = 49
        overlay.MouseButton1Click:Connect(function()
            closeDropdown()
            overlay:Destroy()
        end)
        -- Make sure list renders above overlay
        list.ZIndex = 50
    end

    -- Clicking the row opens/closes the dropdown
    local hit = Instance.new("TextButton", f)
    hit.Size                = UDim2.new(1, 0, 1, 0)
    hit.BackgroundTransparency = 1
    hit.Text                = ""
    hit.BorderSizePixel     = 0
    hit.ZIndex              = 6
    hit.MouseButton1Click:Connect(openDropdown)

    f.MouseEnter:Connect(function() f.BackgroundColor3 = C.rowHov end)
    f.MouseLeave:Connect(function() f.BackgroundColor3 = C.row end)
    return f
end

-- Color picker row
local function mkColorPicker(sc,text,initCol,onChange,ord)
    local f=mkFrame(sc,C.row,1,C.bdr)
    f.Size=UDim2.new(1,0,0,ROW_H); f.LayoutOrder=ord; cr(4,f)

    local lt=mkTxt(f,text,C.txtPrim,FS_LABEL)
    lt.Size=UDim2.new(0.5,0,1,0); lt.Position=UDim2.new(0,8,0,0)

    local swatch=mkFrame(f,initCol,1,C.bdr)
    swatch.Size=UDim2.new(0,60,0,16); swatch.Position=UDim2.new(1,-66,0.5,-8); cr(3,swatch)
    -- FIX: hex text at FS_VALUE=10, not 8 — actually readable
    local hexDisp=mkTxt(swatch,"#"..toHex(initCol),C.txtPrim,FS_VALUE,Enum.TextXAlignment.Center)
    hexDisp.Size=UDim2.new(1,0,1,0)

    local hit=Instance.new("TextButton",f)
    hit.Size=UDim2.new(1,0,1,0); hit.BackgroundTransparency=1; hit.Text=""; hit.BorderSizePixel=0; hit.ZIndex=6
    hit.MouseButton1Click:Connect(function()
        buildPicker(win, initCol, function(col)
            initCol=col; swatch.BackgroundColor3=col; hexDisp.Text="#"..toHex(col)
            if onChange then onChange(col) end
        end)
    end)
    f.MouseEnter:Connect(function() f.BackgroundColor3=C.rowHov end)
    f.MouseLeave:Connect(function() f.BackgroundColor3=C.row end)
end

-- ================================================================
-- BUILD AIMBOT PAGE
-- ================================================================
local p1=tabPages[1]
local COL_W=math.floor((W-MARGIN*3)/2)
local PH=H-CONTENT_Y-MARGIN*2

local ls=mkPanel(p1,"aimbot",MARGIN,MARGIN,COL_W,PH)
local rs=mkPanel(p1,"activation & fov",COL_W+MARGIN*2,MARGIN,COL_W,PH)

-- LEFT: aimbot settings
mkCheck(ls,"enable aimbot",CFG.AimbotEnabled,function(v)
    CFG.AimbotEnabled=v
    if not v then aimbotActive=false; currentTarget=nil end
end,1)

mkLine(ls,2)
mkSub(ls,"targeting",3)
mkPartSelector(ls,4)

mkLine(ls,5)
mkSub(ls,"performance",6)
mkSlider(ls,"smoothness",0,100,CFG.Smoothness,"",function(v) CFG.Smoothness=v end,7)
mkSlider(ls,"prediction",0,100,CFG.Prediction,"",function(v) CFG.Prediction=v end,8)

mkLine(ls,9)
mkSub(ls,"checks",10)
mkCheck(ls,"team check",CFG.TeamCheck,function(v) CFG.TeamCheck=v end,11)
mkCheck(ls,"wall check",CFG.WallCheck,function(v) CFG.WallCheck=v end,12)
mkCheck(ls,"dead check",CFG.DeadCheck,function(v) CFG.DeadCheck=v end,13)

-- RIGHT: activation & fov
mkSub(rs,"mode",1)
mkMode(rs,2)
mkKeybind(rs,"toggle key",CFG.ToggleKey,function(k) CFG.ToggleKey=k end,3)
mkKeybind(rs,"hold key",CFG.HoldKey,function(k) CFG.HoldKey=k end,4)
mkKeybind(rs,"menu key",CFG.MenuKey,function(k) CFG.MenuKey=k end,5)

mkLine(rs,6)
mkSub(rs,"field of view",7)
mkSlider(rs,"fov radius",5,200,CFG.FovRadius," px",function(v) CFG.FovRadius=v end,8)
mkCheck(rs,"show fov",CFG.FovVisible,function(v) CFG.FovVisible=v end,9)
mkColorPicker(rs,"fov color",CFG.FovColor,function(c) CFG.FovColor=c end,10)

-- PLACEHOLDER TABS
for i=2,4 do
    local sc=mkPanel(tabPages[i],"coming soon",MARGIN,MARGIN,W-MARGIN*2,PH)
    mkSub(sc,"this tab is not yet built.",1)
end

-- ================================================================
-- FOV CIRCLE
-- ================================================================
local fovCircle=Drawing.new("Circle")
fovCircle.Visible=false; fovCircle.Filled=false
fovCircle.Thickness=1; fovCircle.NumSides=64

RunService.RenderStepped:Connect(function()
    local active
    if CFG.HoldMode then
        active = CFG.AimbotEnabled and UserInputService:IsKeyDown(CFG.HoldKey)
    else
        active = CFG.AimbotEnabled and aimbotActive
    end
    fovCircle.Visible = CFG.FovVisible and active and not isFreeCam()
    fovCircle.Color   = CFG.FovColor
    fovCircle.Radius  = CFG.FovRadius
    if fovCircle.Visible then
        local mp=UserInputService:GetMouseLocation()
        fovCircle.Position=Vector2.new(mp.X,mp.Y)
    end
end)

-- ================================================================
-- GLOBAL KEYBINDS
-- ================================================================
local guiVisible=true
UserInputService.InputBegan:Connect(function(i,gp)
    if gp then return end
    if i.KeyCode==CFG.MenuKey then
        guiVisible=not guiVisible; win.Visible=guiVisible; return
    end
    if not CFG.HoldMode and i.KeyCode==CFG.ToggleKey then
        if not CFG.AimbotEnabled then return end
        aimbotActive=not aimbotActive
        if not aimbotActive then currentTarget=nil end
    end
end)
UserInputService.InputEnded:Connect(function(i,gp)
    if gp then return end
    if CFG.HoldMode and i.KeyCode==CFG.HoldKey then currentTarget=nil end
end)

print("UDH v1.7  |  RCtrl=menu  CapsLock=toggle  E=hold")