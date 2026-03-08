-- Hackers Battlegrounds | TriggerBot v3.7
--   • Hard velocity reset when horizontal dot < 0 (strafe reversal)
--   • 2-frame dead zone after reversal — no stale velocity leaks through
--   • Dynamic EMA alpha: 0.35 base → 0.85 on acceleration spikes
--   • Distance-scaled lead: 0 at point blank, full at 30+ studs
--   • Target ping estimator removed (unreliable in Roblox — confirmed)
--   • Triple re-validation at fire time: screen delta + vel change + visibility
-- v3.4 / v3.3 / v3.2 / v3.1 archived
--   • fireDeb no longer blocks during delay window — queued shots can't be eaten
--   • Removed stacked 20ms hard-rate-limit doubling with CFG.Delay
--   • Delay re-validation uses a tolerance check instead of strict re-raycast
--   • VIM mouse restore happens AFTER a micro-yield so click registers first
--   • ALPHA_FAST reduced 0.7 → 0.55 to reduce spike sensitivity
--   • ALPHA_SLOW reduced 0.12 → 0.09 for smoother baseline
--   • Prediction default changed to Off (0.0) — let the player dial in manually
--   • getPredictedPos clamps latency tighter (0 → 0.25s) to avoid overshooting
--   • getMouseTarget caches hum reference properly to avoid nil re-lookup cost
--   • Added shotQueued flag so delay window can't stack multiple pending shots

if not game:IsLoaded() then game.Loaded:Wait() end

local Players          = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService       = game:GetService("RunService")
local TweenService     = game:GetService("TweenService")

local LP        = Players.LocalPlayer
local PlayerGui = LP:WaitForChild("PlayerGui")
local Mouse     = LP:GetMouse()

-- Remove existing GUI if present (both locations)
if PlayerGui:FindFirstChild("HB_TriggerBot") then
    PlayerGui.HB_TriggerBot:Destroy()
end
local cg = game:GetService("CoreGui")
if cg:FindFirstChild("HB_TriggerBot") then
    cg.HB_TriggerBot:Destroy()
end

local CFG = {
    Enabled          = false,
    HoldMode         = false,
    ActivationKey    = Enum.KeyCode.CapsLock,
    HoldKey          = Enum.KeyCode.E,
    MenuKey          = Enum.KeyCode.RightControl,
    Delay            = 0.02,   -- universal delay (revolver, rifle, etc.)
    ShotgunDelay     = 0.060,  -- shotgun-only delay (applied when shotgun detected)
    TeamCheck        = true,
    KnockCheck       = true,
    KnifeCheck       = false,
    MaxDistance      = 9999,
    AimPart          = "ANY",
    -- FIX: Default prediction to Off (0.0). Normal (1.0) was causing overshooting
    -- on close-range targets. Players should tune this to their ping.
    PredictStrength  = 0.0,
    StreamerMode     = false,
    FpsBoost         = false,
}

-- ============================================================
-- COMBAT
-- ============================================================
-- FIX: Removed fireDeb entirely from the main check path.
--      Replaced with shotQueued (prevents stacking) + lastFireTime
--      (prevents hardware-level spam). This means a queued shot
--      is never silently dropped because fireDeb was still true.
local shotQueued    = false
local lastFireTime  = 0
local loopConn      = nil
local VIM           = game:GetService("VirtualInputManager")
local CAM           = workspace.CurrentCamera

local wsPlayers = workspace:FindFirstChild("Players")

local function getHitbox(p)
    if not wsPlayers then wsPlayers = workspace:FindFirstChild("Players") end
    if not wsPlayers then return nil end
    local folder = wsPlayers:FindFirstChild(p.Name)
    if not folder then return nil end
    local hbFolder = folder:FindFirstChild("Hitbox")
    if not hbFolder then return nil end
    return hbFolder:FindFirstChild("Middle")
        or hbFolder:FindFirstChildOfClass("BasePart")
end

local function hasKnife()
    local char = LP.Character
    if not char then return false end
    local tool = char:FindFirstChildOfClass("Tool")
    if not tool then return false end
    local n = tool.Name:lower()
    return n:find("knife") or n:find("blade") or n:find("shiv")
        or n:find("switch") or n:find("dagger") or n:find("cutter")
end

-- ── Part → enemy cache ────────────────────────────────────────
local partToEnemy = {}
local playerParts = {}

local function clearPlayer(p)
    local list = playerParts[p]
    if list then
        for i = 1, #list do partToEnemy[list[i]] = nil end
        playerParts[p] = nil
    end
end

local function buildPlayer(p)
    clearPlayer(p)
    if not p.Character then return end
    local hitbox = getHitbox(p)
    if not hitbox then return end
    local hrp = p.Character:FindFirstChild("HumanoidRootPart")
    if not hrp then return end

    local entry = { hitbox = hitbox, player = p, hrp = hrp }
    local list  = {}

    for _, v in ipairs(p.Character:GetDescendants()) do
        if v:IsA("BasePart") then
            partToEnemy[v] = entry
            list[#list+1]  = v
        end
    end
    partToEnemy[hitbox] = entry
    list[#list+1] = hitbox
    if hitbox.Parent then
        for _, v in ipairs(hitbox.Parent:GetDescendants()) do
            if v:IsA("BasePart") and not partToEnemy[v] then
                partToEnemy[v] = entry
                list[#list+1] = v
            end
        end
    end
    playerParts[p] = list
end

local cacheConns = {}
local charConns  = {}

local function hookCharacter(p, char)
    if charConns[p] then
        for _, c in ipairs(charConns[p]) do c:Disconnect() end
    end
    charConns[p] = {}

    local function getEntry()
        local hitbox = getHitbox(p)
        local hrp    = char:FindFirstChild("HumanoidRootPart")
        if not hitbox or not hrp then return nil end
        local existing = playerParts[p] and partToEnemy[playerParts[p][1]]
        if existing and existing.hitbox == hitbox then return existing end
        return { hitbox = hitbox, player = p, hrp = hrp }
    end

    table.insert(charConns[p], char.DescendantAdded:Connect(function(v)
        if not v:IsA("BasePart") then return end
        local entry = getEntry()
        if not entry then return end
        partToEnemy[v] = entry
        local list = playerParts[p]
        if list then list[#list+1] = v end
    end))

    table.insert(charConns[p], char.DescendantRemoving:Connect(function(v)
        if v:IsA("BasePart") then partToEnemy[v] = nil end
    end))

    if not wsPlayers then wsPlayers = workspace:FindFirstChild("Players") end
    local folder   = wsPlayers and wsPlayers:FindFirstChild(p.Name)
    local hbFolder = folder and folder:FindFirstChild("Hitbox")
    if hbFolder then
        table.insert(charConns[p], hbFolder.DescendantAdded:Connect(function(v)
            if not v:IsA("BasePart") then return end
            local entry = getEntry()
            if not entry then return end
            partToEnemy[v] = entry
            local list = playerParts[p]
            if list then list[#list+1] = v end
        end))
        table.insert(charConns[p], hbFolder.DescendantRemoving:Connect(function(v)
            if v:IsA("BasePart") then partToEnemy[v] = nil end
        end))
    end
end

local function hookPlayer(p)
    if cacheConns[p] then
        for _, c in ipairs(cacheConns[p]) do c:Disconnect() end
    end
    cacheConns[p] = {
        p.CharacterAdded:Connect(function(char)
            task.defer(function()
                buildPlayer(p)
                hookCharacter(p, char)
            end)
        end),
        p.CharacterRemoving:Connect(function()
            clearPlayer(p)
            if charConns[p] then
                for _, c in ipairs(charConns[p]) do c:Disconnect() end
                charConns[p] = nil
            end
        end),
    }
    if p.Character then
        task.defer(function()
            buildPlayer(p)
            hookCharacter(p, p.Character)
        end)
    end
end

for _, p in ipairs(Players:GetPlayers()) do
    if p ~= LP then hookPlayer(p) end
end
Players.PlayerAdded:Connect(hookPlayer)
Players.PlayerRemoving:Connect(function(p)
    clearPlayer(p)
    if cacheConns[p] then
        for _, c in ipairs(cacheConns[p]) do c:Disconnect() end
        cacheConns[p] = nil
    end
    if charConns[p] then
        for _, c in ipairs(charConns[p]) do c:Disconnect() end
        charConns[p] = nil
    end
end)

-- ══════════════════════════════════════════════════════════════
-- PREDICTION ENGINE v4
--
-- Implements all four fixes from ChatGPT analysis:
--
-- 1. HARD VELOCITY RESET on strafe reversal (dot < 0)
--    Weighted buffers bleed stale velocity across the reversal frame.
--    When horizontal dot flips negative we discard the buffer entirely
--    and snap velocity to the current raw reading. A 2-frame dead zone
--    then holds confidence at 0 so the stale frame can't leak through.
--
-- 2. DYNAMIC EMA ALPHA based on acceleration magnitude
--    Alpha rises when acceleration spikes (direction change, jump start)
--    so the estimate tracks fast changes, then settles back down.
--    Base alpha = 0.35 (stable cruise), max = 0.85 (high accel spike).
--
-- 3. DISTANCE-SCALED LEAD
--    At 5-15 studs, a 0.5-stud prediction error is larger than the
--    hitbox. Lead now ramps from 0 at 0 studs to full at 30+ studs.
--    Close range → prediction off. Far range → full lead applied.
--
-- 4. TARGET PING: dropped estimator, use 0
--    ChatGPT confirmed position jitter ≠ network latency in Roblox
--    (interpolation buffers, client-authoritative movement).
--    Lead is now purely: your_ping * PredictStrength.
-- ══════════════════════════════════════════════════════════════

-- Per-player state
local pVel       = {}  -- current EMA velocity
local pDeadZone  = {}  -- frames remaining in post-reversal dead zone

-- Your ping: 8-frame rolling average
local pingBuf = {}
local pingPtr = 0
local myPing  = 0.015

local function updatePing()
    pingPtr = (pingPtr % 8) + 1
    pingBuf[pingPtr] = LP:GetNetworkPing()
    local s = 0
    for i = 1, 8 do s = s + (pingBuf[i] or myPing) end
    myPing = s / 8
end

-- EMA velocity with dynamic alpha + hard reset on reversal
local EMA_BASE = 0.35   -- stable cruising alpha
local EMA_MAX  = 0.85   -- alpha during high-acceleration frames
local DEAD_ZONE_FRAMES = 2  -- frames to suppress prediction after reversal

local function samplePlayer(entry)
    local p   = entry.player
    local hrp = entry.hrp
    if not hrp or not hrp.Parent then return end

    local raw = hrp.AssemblyLinearVelocity
    local prev = pVel[p] or raw

    -- ── Reversal detection ───────────────────────────────────
    -- Check horizontal dot product of raw vs previous estimate
    local rawH  = Vector3.new(raw.X,  0, raw.Z)
    local prevH = Vector3.new(prev.X, 0, prev.Z)
    if rawH.Magnitude > 0.5 and prevH.Magnitude > 0.5 then
        local dot = rawH:Dot(prevH) / (rawH.Magnitude * prevH.Magnitude)
        if dot < 0 then
            -- Hard reset: discard smoothed estimate, snap to current reading
            pVel[p]      = raw
            pDeadZone[p] = DEAD_ZONE_FRAMES
            return  -- skip EMA update this frame — raw is our new baseline
        end
    end

    -- ── Dynamic alpha ────────────────────────────────────────
    -- Acceleration magnitude tells us how fast the velocity is changing.
    -- Scale alpha up when acceleration is high so we track fast turns.
    local accel = (raw - prev).Magnitude
    local alpha = EMA_BASE + (EMA_MAX - EMA_BASE) * math.clamp(accel / 30, 0, 1)

    pVel[p] = prev * (1 - alpha) + raw * alpha

    -- Tick down dead zone if active
    if (pDeadZone[p] or 0) > 0 then
        pDeadZone[p] = pDeadZone[p] - 1
    end
end

local _visited = {}
RunService.RenderStepped:Connect(function()
    updatePing()
    table.clear(_visited)
    for _, entry in pairs(partToEnemy) do
        if entry.hrp and entry.hrp.Parent and not _visited[entry.player] then
            _visited[entry.player] = true
            samplePlayer(entry)
        end
    end
end)

-- Confidence (0–1)
-- Dead zone overrides everything else to 0 for DEAD_ZONE_FRAMES after reversal
local function getConfidence(p, distToTarget)
    -- Dead zone: hold at 0 for N frames after hard reset
    if (pDeadZone[p] or 0) > 0 then return 0 end

    local vel = pVel[p]
    if not vel then return 0 end

    local spd = vel.Magnitude
    if spd < 3 then return 0 end

    -- Speed gate: 0 at 3 st/s → 1 at 12 st/s
    local spdConf = math.clamp((spd - 3) / 9, 0, 1)

    -- Air gate: penalise jumping/falling
    local airConf = 1 - math.clamp((math.abs(vel.Y) - 5) / 20, 0, 1)

    -- Distance gate: scale prediction down at close range
    -- 0 studs = 0 confidence, 30+ studs = full confidence
    local distConf = math.clamp(distToTarget / 30, 0, 1)

    return math.clamp(spdConf * airConf * distConf, 0, 1)
end

-- Main prediction function
local function getPredictedPos(entry)
    local p   = entry.player
    local vel = pVel[p]
    local hrp = entry.hrp
    if not vel or not hrp or not hrp.Parent then
        return entry.hitbox.Position
    end

    -- Distance to target (for distance-scaled lead)
    local dist = lpRoot
        and (hrp.Position - lpRoot.Position).Magnitude
        or  999

    -- Lead = your ping only, scaled by PredictStrength and confidence, capped at 75ms
    local lead = math.clamp(myPing * CFG.PredictStrength, 0, 0.075)
        * getConfidence(p, dist)

    -- Horizontal: full velocity × lead
    -- Vertical: only on clear upward jump, capped at 20% to avoid arc overshoot
    local offset =
        Vector3.new(vel.X, 0, vel.Z) * lead +
        Vector3.new(0, vel.Y, 0) * (lead * math.clamp((vel.Y - 5) / 20, 0, 0.2))

    return hrp.Position + offset + (entry.hitbox.Position - hrp.Position)
end

local lpRoot = nil
LP.CharacterAdded:Connect(function(c)
    lpRoot = c:WaitForChild("HumanoidRootPart", 5)
end)
LP.CharacterRemoving:Connect(function() lpRoot = nil end)
if LP.Character then
    lpRoot = LP.Character:FindFirstChild("HumanoidRootPart")
end

local function getMouseTarget()
    if not lpRoot then return nil end
    local target = Mouse.Target
    if not target then return nil end
    local entry = partToEnemy[target]
    if not entry then return nil end
    local p = entry.player
    if not p.Character then return nil end
    if CFG.TeamCheck and p.Team and LP.Team and p.Team == LP.Team then return nil end
    -- FIX: cache hum on the entry so we don't re-search every frame
    if not entry.hum or not entry.hum.Parent then
        entry.hum = p.Character:FindFirstChildWhichIsA("Humanoid")
    end
    if not entry.hum then return nil end
    if CFG.KnockCheck and entry.hum.Health <= 0 then return nil end
    if (entry.hrp.Position - lpRoot.Position).Magnitude > CFG.MaxDistance then return nil end
    return entry
end

local function isFreeCam()
    local ct = CAM.CameraType
    return ct ~= Enum.CameraType.Custom and ct ~= Enum.CameraType.Follow
end

local function isSafeToFire()
    if isFreeCam() then return false end
    if not lpRoot or not lpRoot.Parent then return false end
    return true
end

-- ══════════════════════════════════════════════════════════════
-- WEAPON DETECTION + CENTER-CHECK SYSTEM
--
-- Shotguns need the crosshair CENTERED on the target to land
-- enough pellets for meaningful damage. The old system fired
-- the instant Mouse.Target touched any edge of the hitbox —
-- fine for single-bullet weapons, terrible for spread weapons.
--
-- This system:
--   1. Detects equipped weapon each frame from tool name
--   2. Classifies it as SHOTGUN or OTHER
--   3. For shotguns: enforces a tight pixel center-check AND
--      a minimum settle delay so the crosshair is truly on-center
--      before the VIM click fires
--   4. For other weapons: uses a loose threshold (edge is fine)
-- ══════════════════════════════════════════════════════════════

-- Weapon classification — checks tool name against known shotgun names
-- Add more names here if the game adds new shotguns
local SHOTGUN_NAMES = {
    "double", "barrel", "tactical", "shotgun", "pump",
    "sawn", "sawnoff", "buckshot", "slug", "scatter"
}

-- Weapon class cache — refreshed every 10 frames in the main loop
local weaponCache      = "OTHER"  -- "SHOTGUN" | "OTHER"
local weaponCacheTimer = 0

local function getWeaponClass()
    local char = LP.Character
    if not char then return "OTHER" end
    local tool = char:FindFirstChildOfClass("Tool")
    if not tool then return "OTHER" end
    local n = tool.Name:lower()
    for _, kw in ipairs(SHOTGUN_NAMES) do
        if n:find(kw) then return "SHOTGUN" end
    end
    return "OTHER"
end

-- ── Fire ──────────────────────────────────────────────────────
local function doFire(entry)
    if not isSafeToFire() then return end
    local now = tick()
    if now - lastFireTime < 0.005 then return end
    lastFireTime = now

    local predictedPos = getPredictedPos(entry)
    local sp, onScreen = CAM:WorldToScreenPoint(predictedPos)
    if not onScreen then return end

    local mousePos = UserInputService:GetMouseLocation()
    pcall(VIM.SendMouseMoveEvent,   VIM, sp.X, sp.Y, game)
    pcall(VIM.SendMouseButtonEvent, VIM, sp.X, sp.Y, 0, true,  game, 1)
    pcall(VIM.SendMouseButtonEvent, VIM, sp.X, sp.Y, 0, false, game, 1)
    task.defer(function()
        pcall(VIM.SendMouseMoveEvent, VIM, mousePos.X, mousePos.Y, game)
    end)
end

local function isActive()
    if isFreeCam() then return false end
    if CFG.KnifeCheck and hasKnife() then return false end
    if CFG.HoldMode then
        return UserInputService:IsKeyDown(CFG.HoldKey)
    else
        return CFG.Enabled
    end
end

-- ── Main loop ────────────────────────────────────────────────
local function startLoop()
    if loopConn then loopConn:Disconnect() end
    loopConn = RunService.RenderStepped:Connect(function()
        if not isActive() then return end
        if shotQueued then return end

        -- Refresh weapon class every 10 frames
        weaponCacheTimer = weaponCacheTimer + 1
        if weaponCacheTimer >= 10 then
            weaponCacheTimer = 0
            weaponCache = getWeaponClass()
        end

        local entry = getMouseTarget()
        if not entry then return end

        -- Shotguns use CFG.ShotgunDelay, everything else uses CFG.Delay
        local effectiveDelay = weaponCache == "SHOTGUN"
            and CFG.ShotgunDelay
            or  CFG.Delay

        if effectiveDelay > 0 then
            shotQueued = true
            local snapPos    = entry.hitbox.Position
            local snapPlayer = entry.player
            -- Snapshot velocity at queue time for velocity-change check
            local snapVel    = pVel[snapPlayer] or Vector3.zero
            -- Snapshot screen position at queue time for screen-delta check
            local snapSP, _  = CAM:WorldToScreenPoint(snapPos)

            task.delay(effectiveDelay, function()
                shotQueued = false
                if not isActive() then return end
                if not snapPlayer.Character then return end

                local liveHitbox = getHitbox(snapPlayer)
                if not liveHitbox then return end

                local freshEntry = partToEnemy[liveHitbox] or {
                    hitbox = liveHitbox,
                    player = snapPlayer,
                    hrp    = snapPlayer.Character
                        and snapPlayer.Character:FindFirstChild("HumanoidRootPart")
                }
                if not freshEntry or not freshEntry.hrp then return end

                -- ── Triple re-validation (ChatGPT fix) ──────────────
                -- 1. Screen-space delta: predicted position must still be
                --    within 80px of where we aimed when the shot was queued.
                --    Measures aim alignment directly, not world displacement.
                local livePredPos     = getPredictedPos(freshEntry)
                local liveSP, onScreen = CAM:WorldToScreenPoint(livePredPos)
                if not onScreen then return end
                local screenDx = liveSP.X - snapSP.X
                local screenDy = liveSP.Y - snapSP.Y
                if (screenDx*screenDx + screenDy*screenDy) > 80*80 then return end

                -- 2. Velocity change: if target has significantly changed
                --    velocity since queue time, our prediction is stale.
                --    Threshold: 8 st/s change = likely strafe/stop.
                local liveVel = pVel[snapPlayer] or Vector3.zero
                if (liveVel - snapVel).Magnitude > 8 then return end

                -- 3. Still visible: target must still be under mouse
                --    (Mouse.Target cache check — free, already populated)
                local stillVisible = partToEnemy[Mouse.Target]
                    and partToEnemy[Mouse.Target].player == snapPlayer
                if not stillVisible then return end

                doFire(freshEntry)
            end)
        else
            doFire(entry)
        end
    end)
end

-- ============================================================
-- FPS BOOSTER
-- ============================================================
local fpsOriginals = {}

local function applyFpsBoost(on)
    local ls = game:GetService("Lighting")
    if on then
        fpsOriginals.shadows    = ls.GlobalShadows
        fpsOriginals.fogEnd     = ls.FogEnd
        fpsOriginals.fogStart   = ls.FogStart
        fpsOriginals.brightness = ls.Brightness
        fpsOriginals.ambient    = ls.Ambient
        fpsOriginals.outAmbient = ls.OutdoorAmbient

        pcall(function() settings().Rendering.QualityLevel = Enum.QualityLevel.Level01 end)
        ls.GlobalShadows = false
        ls.FogEnd   = 100000
        ls.FogStart = 99999

        for _, v in ipairs(ls:GetChildren()) do
            if v:IsA("PostEffect") or v:IsA("Sky") or v:IsA("Atmosphere") then
                fpsOriginals[v] = v.Parent
                v.Parent = nil
            end
        end

        for _, v in ipairs(workspace:GetDescendants()) do
            if v:IsA("Beam") or v:IsA("Trail") or v:IsA("ParticleEmitter")
                or v:IsA("Smoke") or v:IsA("Fire") or v:IsA("Sparkles") then
                pcall(function()
                    fpsOriginals[v] = v.Enabled ~= nil and v.Enabled or true
                    if v:IsA("Beam") or v:IsA("Trail") then
                        v.Enabled = false
                    elseif v.Parent then
                        v:Emit(0); v.Enabled = false
                    end
                end)
            end
        end

        fpsOriginals.descConn = workspace.DescendantAdded:Connect(function(v)
            if v:IsA("Beam") or v:IsA("Trail") or v:IsA("ParticleEmitter")
                or v:IsA("Smoke") or v:IsA("Fire") or v:IsA("Sparkles") then
                pcall(function() v.Enabled = false end)
            end
        end)
    else
        if fpsOriginals.descConn then
            fpsOriginals.descConn:Disconnect()
            fpsOriginals.descConn = nil
        end
        pcall(function() settings().Rendering.QualityLevel = Enum.QualityLevel.Automatic end)
        if fpsOriginals.shadows    ~= nil then ls.GlobalShadows  = fpsOriginals.shadows    end
        if fpsOriginals.fogEnd     ~= nil then ls.FogEnd         = fpsOriginals.fogEnd     end
        if fpsOriginals.fogStart   ~= nil then ls.FogStart       = fpsOriginals.fogStart   end
        if fpsOriginals.brightness ~= nil then ls.Brightness     = fpsOriginals.brightness end
        if fpsOriginals.ambient    ~= nil then ls.Ambient        = fpsOriginals.ambient    end
        if fpsOriginals.outAmbient ~= nil then ls.OutdoorAmbient = fpsOriginals.outAmbient end
        for k, parent in pairs(fpsOriginals) do
            if typeof(k) == "Instance" then
                pcall(function() k.Parent = parent end)
                fpsOriginals[k] = nil
            end
        end
        for _, v in ipairs(workspace:GetDescendants()) do
            if v:IsA("Beam") or v:IsA("Trail") or v:IsA("ParticleEmitter")
                or v:IsA("Smoke") or v:IsA("Fire") or v:IsA("Sparkles") then
                pcall(function() v.Enabled = true end)
            end
        end
        fpsOriginals = {}
    end
end

-- ============================================================
-- STREAMER MODE
-- ============================================================
local streamerActive = false
local closeMenuForStreamer = nil

local function applyStreamerMode(on)
    streamerActive   = on
    CFG.StreamerMode = on
    if on then
        if closeMenuForStreamer then closeMenuForStreamer() end
        titleL.Text = "Combat Tool"
        subL.Text   = "Private Client"
    else
        titleL.Text = "TriggerBot"
        subL.Text   = "11phhsware  |  v5.0"
    end
end

-- ============================================================
-- THEME  (v5 — refined dark UI)
-- ============================================================
-- Palette
local ACCENT  = Color3.fromRGB(100, 200, 255)   -- primary blue
local ACCENT2 = Color3.fromRGB(130, 100, 255)   -- purple accent
local ADIM    = Color3.fromRGB(30,  70, 120)    -- dimmed accent bg
local PANEL   = Color3.fromRGB(13,  15, 23)     -- window bg
local CARD    = Color3.fromRGB(19,  22, 34)     -- row/card bg
local CARD2   = Color3.fromRGB(25,  29, 45)     -- hovered card
local CARD3   = Color3.fromRGB(22,  26, 40)     -- alt card
local BORDER  = Color3.fromRGB(35,  42, 65)     -- subtle border
local RED     = Color3.fromRGB(255,  70,  70)
local GREEN   = Color3.fromRGB(50,  220, 120)
local YELLOW  = Color3.fromRGB(255, 195,  50)
local WHITE   = Color3.fromRGB(220, 228, 248)
local GREY    = Color3.fromRGB( 90, 100, 130)
local DIM     = Color3.fromRGB( 55,  65,  95)
local DIMTXT  = Color3.fromRGB( 70,  82, 115)

-- Shared TweenInfos
local FAST  = TweenInfo.new(0.12, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
local MED   = TweenInfo.new(0.22, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
local SLOW  = TweenInfo.new(0.35, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
local SINE  = TweenInfo.new(0.30, Enum.EasingStyle.Sine,  Enum.EasingDirection.Out)

local function tw(obj, props, ti)
    TweenService:Create(obj, ti or FAST, props):Play()
end

-- ============================================================
-- SCREENGUI + WINDOW
-- ============================================================
local sg = Instance.new("ScreenGui")
sg.Name           = "HB_TriggerBot"
sg.ResetOnSpawn   = false
sg.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
sg.DisplayOrder   = 9999
sg.IgnoreGuiInset = true

local guiParented = false
pcall(function() sg.Parent = game:GetService("CoreGui"); guiParented = true end)
if not guiParented then sg.Parent = PlayerGui end

local W, H = 344, 472

local win = Instance.new("Frame", sg)
win.Name             = "Window"
win.Size             = UDim2.new(0, W, 0, H)
win.Position         = UDim2.new(0.5, -W/2, 0.5, -H/2)
win.BackgroundColor3 = PANEL
win.BorderSizePixel  = 0
win.ClipsDescendants = true
win.BackgroundTransparency = 1   -- start invisible for open anim
Instance.new("UICorner", win).CornerRadius = UDim.new(0, 12)

-- Outer glow border
local wStroke = Instance.new("UIStroke", win)
wStroke.Color           = Color3.fromRGB(42, 52, 82)
wStroke.Thickness       = 1.2
wStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border

-- Subtle diagonal gradient
local wGrad = Instance.new("UIGradient", win)
wGrad.Color    = ColorSequence.new({
    ColorSequenceKeypoint.new(0,   Color3.fromRGB(17, 20, 32)),
    ColorSequenceKeypoint.new(1,   Color3.fromRGB(10, 12, 19)),
})
wGrad.Rotation = 135

-- Top accent line (gradient bar)
local bar = Instance.new("Frame", win)
bar.Name            = "AccentBar"
bar.Size            = UDim2.new(1, 0, 0, 2)
bar.BackgroundColor3 = ACCENT
bar.BorderSizePixel = 0
local barGrad = Instance.new("UIGradient", bar)
barGrad.Color = ColorSequence.new({
    ColorSequenceKeypoint.new(0,   ACCENT),
    ColorSequenceKeypoint.new(0.5, ACCENT2),
    ColorSequenceKeypoint.new(1,   ACCENT),
})
barGrad.Rotation = 0

win.Size     = UDim2.new(0, W, 0, H)
win.Position = UDim2.new(0.5, -W/2, 0.5, -H/2)
win.BackgroundTransparency = 0

-- ============================================================
-- HEADER
-- ============================================================
local HDR_H = 56
local hdr = Instance.new("Frame", win)
hdr.Name             = "Header"
hdr.Size             = UDim2.new(1, 0, 0, HDR_H)
hdr.Position         = UDim2.new(0, 0, 0, 2)
hdr.BackgroundColor3 = Color3.fromRGB(13, 16, 25)
hdr.BorderSizePixel  = 0

-- Thin separator line under header
local hdrSep = Instance.new("Frame", hdr)
hdrSep.Size             = UDim2.new(1, -24, 0, 1)
hdrSep.Position         = UDim2.new(0, 12, 1, -1)
hdrSep.BackgroundColor3 = BORDER
hdrSep.BorderSizePixel  = 0
local hdrSepGrad = Instance.new("UIGradient", hdrSep)
hdrSepGrad.Color = ColorSequence.new({
    ColorSequenceKeypoint.new(0,   Color3.fromRGB(0,0,0)),
    ColorSequenceKeypoint.new(0.2, BORDER),
    ColorSequenceKeypoint.new(0.8, BORDER),
    ColorSequenceKeypoint.new(1,   Color3.fromRGB(0,0,0)),
})
hdrSepGrad.Rotation = 0

-- Drag
local dragActive, dragStart, winStart = false, nil, nil
hdr.InputBegan:Connect(function(i)
    if i.UserInputType == Enum.UserInputType.MouseButton1 then
        dragActive = true; dragStart = i.Position; winStart = win.Position
    end
end)
hdr.InputEnded:Connect(function(i)
    if i.UserInputType == Enum.UserInputType.MouseButton1 then dragActive = false end
end)
UserInputService.InputChanged:Connect(function(i)
    if dragActive and i.UserInputType == Enum.UserInputType.MouseMovement then
        local d = i.Position - dragStart
        win.Position = UDim2.new(winStart.X.Scale, winStart.X.Offset + d.X,
                                  winStart.Y.Scale, winStart.Y.Offset + d.Y)
    end
end)

-- Icon badge (rounded square with "TB" monogram)
local iconBg = Instance.new("Frame", hdr)
iconBg.Size             = UDim2.new(0, 32, 0, 32)
iconBg.Position         = UDim2.new(0, 13, 0.5, -16)
iconBg.BackgroundColor3 = Color3.fromRGB(20, 50, 90)
iconBg.BorderSizePixel  = 0
Instance.new("UICorner", iconBg).CornerRadius = UDim.new(0, 7)
local iconStroke = Instance.new("UIStroke", iconBg)
iconStroke.Color = Color3.fromRGB(40, 90, 160); iconStroke.Thickness = 1
iconStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
local iconGrad = Instance.new("UIGradient", iconBg)
iconGrad.Color = ColorSequence.new({
    ColorSequenceKeypoint.new(0, Color3.fromRGB(28, 70, 130)),
    ColorSequenceKeypoint.new(1, Color3.fromRGB(14, 40, 80)),
})
iconGrad.Rotation = 135
local iconTxt = Instance.new("TextLabel", iconBg)
iconTxt.Size               = UDim2.new(1, 0, 1, 0)
iconTxt.BackgroundTransparency = 1
iconTxt.Text               = "TB"
iconTxt.TextColor3         = ACCENT
iconTxt.Font               = Enum.Font.GothamBold
iconTxt.TextSize           = 11

-- Title + subtitle
local titleL = Instance.new("TextLabel", hdr)
titleL.Size               = UDim2.new(0, 150, 0, 20)
titleL.Position           = UDim2.new(0, 54, 0, 8)
titleL.BackgroundTransparency = 1
titleL.Text               = "TriggerBot"
titleL.TextColor3         = WHITE
titleL.Font               = Enum.Font.GothamBold
titleL.TextSize           = 14
titleL.TextXAlignment     = Enum.TextXAlignment.Left

local subL = Instance.new("TextLabel", hdr)
subL.Size               = UDim2.new(0, 200, 0, 14)
subL.Position           = UDim2.new(0, 54, 0, 30)
subL.BackgroundTransparency = 1
subL.Text               = "11phhsware  |  v5.0"
subL.TextColor3         = GREY
subL.Font               = Enum.Font.GothamMedium
subL.TextSize           = 10
subL.TextXAlignment     = Enum.TextXAlignment.Left

-- Active/Inactive badge
local badgeBg = Instance.new("Frame", hdr)
badgeBg.Size             = UDim2.new(0, 84, 0, 24)
badgeBg.Position         = UDim2.new(1, -122, 0.5, -12)
badgeBg.BackgroundColor3 = Color3.fromRGB(42, 16, 16)
badgeBg.BorderSizePixel  = 0
Instance.new("UICorner", badgeBg).CornerRadius = UDim.new(0, 7)
local bStroke = Instance.new("UIStroke", badgeBg)
bStroke.Color = RED; bStroke.Thickness = 1
bStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border

local badgeDot = Instance.new("Frame", badgeBg)
badgeDot.Size             = UDim2.new(0, 6, 0, 6)
badgeDot.Position         = UDim2.new(0, 10, 0.5, -3)
badgeDot.BackgroundColor3 = RED
badgeDot.BorderSizePixel  = 0
Instance.new("UICorner", badgeDot).CornerRadius = UDim.new(1, 0)

local badgeTxt = Instance.new("TextLabel", badgeBg)
badgeTxt.Size               = UDim2.new(1, -24, 1, 0)
badgeTxt.Position           = UDim2.new(0, 22, 0, 0)
badgeTxt.BackgroundTransparency = 1
badgeTxt.Text               = "INACTIVE"
badgeTxt.TextColor3         = RED
badgeTxt.Font               = Enum.Font.GothamBold
badgeTxt.TextSize           = 9
badgeTxt.TextXAlignment     = Enum.TextXAlignment.Left

local pulseTw = TweenService:Create(badgeDot,
    TweenInfo.new(0.8, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
    {BackgroundTransparency = 0.7})

local function setBadge(on)
    if on then
        tw(badgeBg,  {BackgroundColor3 = Color3.fromRGB(14, 40, 26)}, MED)
        tw(badgeDot, {BackgroundColor3 = GREEN}, MED)
        tw(badgeTxt, {TextColor3 = GREEN}, MED)
        tw(bStroke,  {Color = GREEN}, MED)
        badgeTxt.Text = "ACTIVE"; pulseTw:Play()
    else
        pulseTw:Cancel()
        tw(badgeBg,  {BackgroundColor3 = Color3.fromRGB(42, 16, 16)}, MED)
        tw(badgeDot, {BackgroundColor3 = RED}, MED)
        tw(badgeTxt, {TextColor3 = RED}, MED)
        tw(bStroke,  {Color = RED}, MED)
        badgeTxt.Text = "INACTIVE"
    end
end

-- Close / hide button
local xBtn = Instance.new("TextButton", hdr)
xBtn.Size             = UDim2.new(0, 26, 0, 26)
xBtn.Position         = UDim2.new(1, -36, 0.5, -13)
xBtn.BackgroundColor3 = Color3.fromRGB(38, 16, 16)
xBtn.BackgroundTransparency = 0.2
xBtn.Text             = "✕"
xBtn.TextColor3       = Color3.fromRGB(180, 70, 70)
xBtn.TextSize         = 11
xBtn.Font             = Enum.Font.GothamBold
xBtn.BorderSizePixel  = 0
Instance.new("UICorner", xBtn).CornerRadius = UDim.new(0, 7)

local guiVisible = true
local function toggleGui()
    guiVisible = not guiVisible
    win.Visible = guiVisible
end

closeMenuForStreamer = function()
    if guiVisible then guiVisible = false; win.Visible = false end
end
if CFG.StreamerMode then closeMenuForStreamer() end

xBtn.MouseButton1Click:Connect(toggleGui)
xBtn.MouseEnter:Connect(function()
    tw(xBtn, {BackgroundColor3 = Color3.fromRGB(160, 30, 30),
              BackgroundTransparency = 0, TextColor3 = Color3.fromRGB(255, 100, 100)})
end)
xBtn.MouseLeave:Connect(function()
    tw(xBtn, {BackgroundColor3 = Color3.fromRGB(38, 16, 16),
              BackgroundTransparency = 0.2, TextColor3 = Color3.fromRGB(180, 70, 70)})
end)

-- ============================================================
-- TABS
-- ============================================================
local TAB_Y   = HDR_H + 2
local tabBar  = Instance.new("Frame", win)
tabBar.Size             = UDim2.new(1, 0, 0, 34)
tabBar.Position         = UDim2.new(0, 0, 0, TAB_Y)
tabBar.BackgroundColor3 = Color3.fromRGB(13, 16, 25)
tabBar.BorderSizePixel  = 0

-- Bottom border under tab bar
local tabSep = Instance.new("Frame", tabBar)
tabSep.Size             = UDim2.new(1, 0, 0, 1)
tabSep.Position         = UDim2.new(0, 0, 1, -1)
tabSep.BackgroundColor3 = BORDER
tabSep.BorderSizePixel  = 0

local TABS   = {"Combat", "Settings", "Info"}
local tBtns  = {}
local tPages = {}
local TW     = math.floor(W / #TABS)

-- Sliding indicator bar
local tabIndicator = Instance.new("Frame", tabBar)
tabIndicator.Size             = UDim2.new(0, TW - 20, 0, 2)
tabIndicator.Position         = UDim2.new(0, 10, 1, -2)
tabIndicator.BackgroundColor3 = ACCENT
tabIndicator.BorderSizePixel  = 0
Instance.new("UICorner", tabIndicator).CornerRadius = UDim.new(1, 0)
local tiGrad = Instance.new("UIGradient", tabIndicator)
tiGrad.Color = ColorSequence.new(ACCENT, ACCENT2)

for i, name in ipairs(TABS) do
    local b = Instance.new("TextButton", tabBar)
    b.Size             = UDim2.new(0, TW, 1, 0)
    b.Position         = UDim2.new(0, (i-1)*TW, 0, 0)
    b.BackgroundTransparency = 1
    b.Text             = name
    b.TextColor3       = i == 1 and ACCENT or GREY
    b.Font             = Enum.Font.GothamBold
    b.TextSize         = 11
    b.BorderSizePixel  = 0
    tBtns[i] = b
end

local function mkPage()
    local f = Instance.new("ScrollingFrame", win)
    f.Size                 = UDim2.new(1, 0, 1, -(TAB_Y + 36))
    f.Position             = UDim2.new(0, 0, 0, TAB_Y + 34)
    f.BackgroundTransparency = 1
    f.BorderSizePixel      = 0
    f.ScrollBarThickness   = 3
    f.ScrollBarImageColor3 = Color3.fromRGB(50, 65, 100)
    f.CanvasSize           = UDim2.new(0, 0, 0, 0)
    f.AutomaticCanvasSize  = Enum.AutomaticSize.Y
    f.Visible              = false
    local pad = Instance.new("UIPadding", f)
    pad.PaddingLeft   = UDim.new(0, 12)
    pad.PaddingRight  = UDim.new(0, 12)
    pad.PaddingTop    = UDim.new(0, 10)
    pad.PaddingBottom = UDim.new(0, 10)
    local layout = Instance.new("UIListLayout", f)
    layout.SortOrder        = Enum.SortOrder.LayoutOrder
    layout.Padding          = UDim.new(0, 5)
    layout.FillDirection    = Enum.FillDirection.Vertical
    layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
    return f
end

for i = 1, #TABS do tPages[i] = mkPage() end
tPages[1].Visible = true

local function switchTab(idx)
    for i, b in ipairs(tBtns) do
        local active = i == idx
        tw(b, {TextColor3 = active and ACCENT or GREY}, MED)
        tPages[i].Visible = active
    end
    -- Slide indicator to new tab
    tw(tabIndicator, {
        Position = UDim2.new(0, (idx-1)*TW + 10, 1, -2),
        Size     = UDim2.new(0, TW - 20, 0, 2),
        BackgroundColor3 = idx == 2 and ACCENT2 or ACCENT,
    }, SINE)
end
for i, b in ipairs(tBtns) do
    b.MouseButton1Click:Connect(function() switchTab(i) end)
end

-- ============================================================
-- COMPONENT HELPERS
-- ============================================================

-- Section header label
local function mkSec(page, txt, order)
    local row = Instance.new("Frame", page)
    row.Size             = UDim2.new(1, 0, 0, 22)
    row.BackgroundTransparency = 1
    row.LayoutOrder      = order
    local l = Instance.new("TextLabel", row)
    l.Size               = UDim2.new(1, -4, 1, 0)
    l.Position           = UDim2.new(0, 2, 0, 0)
    l.BackgroundTransparency = 1
    l.Text               = txt
    l.TextColor3         = DIMTXT
    l.Font               = Enum.Font.GothamBold
    l.TextSize           = 9
    l.TextXAlignment     = Enum.TextXAlignment.Left
    -- Divider line on right
    local div = Instance.new("Frame", row)
    div.Size             = UDim2.new(1, -50, 0, 1)
    div.Position         = UDim2.new(0, 46, 0.5, 0)
    div.BackgroundColor3 = BORDER
    div.BorderSizePixel  = 0
    local dg = Instance.new("UIGradient", div)
    dg.Color = ColorSequence.new({
        ColorSequenceKeypoint.new(0,   BORDER),
        ColorSequenceKeypoint.new(1,   Color3.fromRGB(0,0,0)),
    })
    return row
end

-- Toggle row with pill switch
local function mkToggle(page, text, default, onChange)
    local row = Instance.new("Frame", page)
    row.Size             = UDim2.new(1, 0, 0, 40)
    row.BackgroundColor3 = CARD
    row.BorderSizePixel  = 0
    Instance.new("UICorner", row).CornerRadius = UDim.new(0, 8)

    -- left colour accent strip
    local strip = Instance.new("Frame", row)
    strip.Size             = UDim2.new(0, 3, 0, 20)
    strip.Position         = UDim2.new(0, 0, 0.5, -10)
    strip.BackgroundColor3 = default and ACCENT or DIM
    strip.BorderSizePixel  = 0
    Instance.new("UICorner", strip).CornerRadius = UDim.new(1, 0)

    local l = Instance.new("TextLabel", row)
    l.Size               = UDim2.new(1, -58, 1, 0)
    l.Position           = UDim2.new(0, 14, 0, 0)
    l.BackgroundTransparency = 1
    l.Text               = text
    l.TextColor3         = WHITE
    l.Font               = Enum.Font.GothamMedium
    l.TextSize           = 12
    l.TextXAlignment     = Enum.TextXAlignment.Left

    -- Pill track
    local track = Instance.new("Frame", row)
    track.Size             = UDim2.new(0, 40, 0, 22)
    track.Position         = UDim2.new(1, -48, 0.5, -11)
    track.BackgroundColor3 = default and Color3.fromRGB(30, 80, 140) or Color3.fromRGB(28, 32, 50)
    track.BorderSizePixel  = 0
    Instance.new("UICorner", track).CornerRadius = UDim.new(1, 0)
    local ts = Instance.new("UIStroke", track)
    ts.Color = default and Color3.fromRGB(50, 130, 220) or BORDER
    ts.Thickness = 1; ts.ApplyStrokeMode = Enum.ApplyStrokeMode.Border

    -- Knob
    local knob = Instance.new("Frame", track)
    knob.Size             = UDim2.new(0, 16, 0, 16)
    knob.Position         = UDim2.new(default and 1 or 0, default and -19 or 3, 0.5, -8)
    knob.BackgroundColor3 = default and ACCENT or GREY
    knob.BorderSizePixel  = 0
    Instance.new("UICorner", knob).CornerRadius = UDim.new(1, 0)
    -- Knob inner glow
    local ks = Instance.new("UIStroke", knob)
    ks.Color = Color3.fromRGB(0, 0, 0); ks.Thickness = 1.5
    ks.ApplyStrokeMode = Enum.ApplyStrokeMode.Border

    local val = default
    local hit = Instance.new("TextButton", row)
    hit.Size              = UDim2.new(1, 0, 1, 0)
    hit.BackgroundTransparency = 1
    hit.Text              = ""
    hit.BorderSizePixel   = 0

    hit.MouseButton1Click:Connect(function()
        val = not val
        tw(track, {BackgroundColor3 = val and Color3.fromRGB(30, 80, 140) or Color3.fromRGB(28, 32, 50)}, MED)
        tw(ts,    {Color = val and Color3.fromRGB(50, 130, 220) or BORDER}, MED)
        tw(knob,  {BackgroundColor3 = val and ACCENT or GREY,
                   Position = UDim2.new(val and 1 or 0, val and -19 or 3, 0.5, -8)}, MED)
        tw(strip, {BackgroundColor3 = val and ACCENT or DIM}, MED)
        if onChange then onChange(val) end
    end)
    hit.MouseEnter:Connect(function() tw(row, {BackgroundColor3 = CARD2}, FAST) end)
    hit.MouseLeave:Connect(function() tw(row, {BackgroundColor3 = CARD},  FAST) end)

    local function sync(v)
        val = v
        tw(track, {BackgroundColor3 = v and Color3.fromRGB(30, 80, 140) or Color3.fromRGB(28, 32, 50)}, MED)
        tw(ts,    {Color = v and Color3.fromRGB(50, 130, 220) or BORDER}, MED)
        tw(knob,  {BackgroundColor3 = v and ACCENT or GREY,
                   Position = UDim2.new(v and 1 or 0, v and -19 or 3, 0.5, -8)}, MED)
        tw(strip, {BackgroundColor3 = v and ACCENT or DIM}, MED)
    end
    return row, sync
end

-- Slider row
local function mkSlider(page, text, mn, mx, init, suf, onChange)
    local row = Instance.new("Frame", page)
    row.Size             = UDim2.new(1, 0, 0, 56)
    row.BackgroundColor3 = CARD
    row.BorderSizePixel  = 0
    Instance.new("UICorner", row).CornerRadius = UDim.new(0, 8)

    local nl = Instance.new("TextLabel", row)
    nl.Size               = UDim2.new(0.58, 0, 0, 20)
    nl.Position           = UDim2.new(0, 13, 0, 8)
    nl.BackgroundTransparency = 1
    nl.Text               = text
    nl.TextColor3         = WHITE
    nl.Font               = Enum.Font.GothamMedium
    nl.TextSize           = 12
    nl.TextXAlignment     = Enum.TextXAlignment.Left

    local vl = Instance.new("TextLabel", row)
    vl.Size               = UDim2.new(0.38, 0, 0, 20)
    vl.Position           = UDim2.new(0.6, 0, 0, 8)
    vl.BackgroundTransparency = 1
    vl.Text               = tostring(init)..(suf or "")
    vl.TextColor3         = ACCENT
    vl.Font               = Enum.Font.RobotoMono
    vl.TextSize           = 11
    vl.TextXAlignment     = Enum.TextXAlignment.Right

    -- Track bg
    local bg = Instance.new("Frame", row)
    bg.Size             = UDim2.new(1, -26, 0, 4)
    bg.Position         = UDim2.new(0, 13, 1, -15)
    bg.BackgroundColor3 = Color3.fromRGB(28, 33, 52)
    bg.BorderSizePixel  = 0
    Instance.new("UICorner", bg).CornerRadius = UDim.new(1, 0)

    local pct  = (init - mn) / math.max(mx - mn, 1)

    -- Filled portion
    local fill = Instance.new("Frame", bg)
    fill.Size             = UDim2.new(pct, 0, 1, 0)
    fill.BackgroundColor3 = ACCENT
    fill.BorderSizePixel  = 0
    Instance.new("UICorner", fill).CornerRadius = UDim.new(1, 0)
    local fg = Instance.new("UIGradient", fill)
    fg.Color    = ColorSequence.new(ACCENT, ACCENT2)
    fg.Rotation = 0

    -- Thumb
    local thumb = Instance.new("Frame", bg)
    thumb.Size             = UDim2.new(0, 13, 0, 13)
    thumb.Position         = UDim2.new(pct, -6, 0.5, -6)
    thumb.BackgroundColor3 = WHITE
    thumb.BorderSizePixel  = 0
    Instance.new("UICorner", thumb).CornerRadius = UDim.new(1, 0)
    local tStroke = Instance.new("UIStroke", thumb)
    tStroke.Color           = ACCENT
    tStroke.Thickness       = 1.5
    tStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border

    local dragging = false
    local function upd(ax)
        local w  = bg.AbsoluteSize.X
        local x  = bg.AbsolutePosition.X
        local t  = math.clamp((ax - x) / w, 0, 1)
        local v  = math.floor(mn + t * (mx - mn) + 0.5)
        t = (v - mn) / math.max(mx - mn, 1)
        tw(fill,  {Size     = UDim2.new(t, 0, 1, 0)}, FAST)
        tw(thumb, {Position = UDim2.new(t, -6, 0.5, -6)}, FAST)
        vl.Text = tostring(v)..(suf or "")
        if onChange then onChange(v) end
    end

    local ib = Instance.new("TextButton", bg)
    ib.Size              = UDim2.new(1, 0, 1, 16)
    ib.Position          = UDim2.new(0, 0, 0, -8)
    ib.BackgroundTransparency = 1
    ib.Text              = ""
    ib.BorderSizePixel   = 0
    ib.MouseButton1Down:Connect(function(ax) dragging = true; upd(ax) end)
    UserInputService.InputChanged:Connect(function(i)
        if dragging and i.UserInputType == Enum.UserInputType.MouseMovement then upd(i.Position.X) end
    end)
    UserInputService.InputEnded:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1 then dragging = false end
    end)

    row.MouseEnter:Connect(function()
        tw(row,   {BackgroundColor3 = CARD2}, FAST)
        tw(thumb, {BackgroundColor3 = ACCENT}, FAST)
    end)
    row.MouseLeave:Connect(function()
        tw(row,   {BackgroundColor3 = CARD}, FAST)
        if not dragging then tw(thumb, {BackgroundColor3 = WHITE}, FAST) end
    end)
    return row
end

-- Keybind row
local function mkKeybind(page, text, default, onChange, order)
    local row = Instance.new("Frame", page)
    row.Size             = UDim2.new(1, 0, 0, 44)
    row.BackgroundColor3 = CARD
    row.BorderSizePixel  = 0
    row.LayoutOrder      = order
    Instance.new("UICorner", row).CornerRadius = UDim.new(0, 8)

    local l = Instance.new("TextLabel", row)
    l.Size               = UDim2.new(0.55, 0, 1, 0)
    l.Position           = UDim2.new(0, 13, 0, 0)
    l.BackgroundTransparency = 1
    l.Text               = text
    l.TextColor3         = WHITE
    l.Font               = Enum.Font.GothamMedium
    l.TextSize           = 12
    l.TextXAlignment     = Enum.TextXAlignment.Left

    local btn = Instance.new("TextButton", row)
    btn.Size             = UDim2.new(0, 108, 0, 28)
    btn.Position         = UDim2.new(1, -116, 0.5, -14)
    btn.BackgroundColor3 = Color3.fromRGB(20, 50, 90)
    btn.Text             = tostring(default):gsub("Enum%.KeyCode%.","")
    btn.TextColor3       = ACCENT
    btn.Font             = Enum.Font.RobotoMono
    btn.TextSize         = 11
    btn.BorderSizePixel  = 0
    Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 7)
    local ks = Instance.new("UIStroke", btn)
    ks.Color = Color3.fromRGB(40, 90, 160); ks.Thickness = 1
    ks.ApplyStrokeMode = Enum.ApplyStrokeMode.Border

    local waiting = false
    btn.MouseButton1Click:Connect(function()
        if waiting then return end
        waiting = true
        btn.Text      = "Press key..."
        btn.TextColor3 = GREY
        tw(btn, {BackgroundColor3 = CARD}, FAST)
        local conn
        conn = UserInputService.InputBegan:Connect(function(i, gp)
            if gp or i.UserInputType ~= Enum.UserInputType.Keyboard then return end
            btn.Text       = tostring(i.KeyCode):gsub("Enum%.KeyCode%.","")
            btn.TextColor3 = ACCENT
            tw(btn, {BackgroundColor3 = Color3.fromRGB(20, 50, 90)}, MED)
            waiting = false
            if onChange then onChange(i.KeyCode) end
            conn:Disconnect()
        end)
    end)
    btn.MouseEnter:Connect(function()
        if not waiting then tw(btn, {BackgroundColor3 = Color3.fromRGB(30, 70, 130)}, FAST) end
    end)
    btn.MouseLeave:Connect(function()
        if not waiting then tw(btn, {BackgroundColor3 = Color3.fromRGB(20, 50, 90)}, FAST) end
    end)
    row.MouseEnter:Connect(function() tw(row, {BackgroundColor3 = CARD2}, FAST) end)
    row.MouseLeave:Connect(function() tw(row, {BackgroundColor3 = CARD},  FAST) end)
    return row
end

-- ============================================================
-- PAGE 1: COMBAT
-- ============================================================
local p1 = tPages[1]

mkSec(p1, "DETECTION", 1)

local rowEnabled, syncEnabled = mkToggle(p1, "Enable TriggerBot", CFG.Enabled, function(v)
    CFG.Enabled = v; setBadge(v)
end)
rowEnabled.LayoutOrder = 2

local rowTeam = mkToggle(p1, "Team Check", CFG.TeamCheck, function(v) CFG.TeamCheck = v end)
rowTeam.LayoutOrder = 3

local rowKnock = mkToggle(p1, "Knock Check (skip downed)", CFG.KnockCheck, function(v) CFG.KnockCheck = v end)
rowKnock.LayoutOrder = 4

local rowKnife = mkToggle(p1, "Knife Block (disable while knife out)", CFG.KnifeCheck, function(v) CFG.KnifeCheck = v end)
rowKnife.LayoutOrder = 5

mkSec(p1, "PARAMETERS", 6).LayoutOrder = 6

local sd = mkSlider(p1, "Fire Delay", 0, 300, math.floor(CFG.Delay*1000), " ms",
    function(v) CFG.Delay = v/1000 end)
sd.LayoutOrder = 7

local ssg = mkSlider(p1, "Shotgun Delay", 0, 300, math.floor(CFG.ShotgunDelay*1000), " ms",
    function(v) CFG.ShotgunDelay = v/1000 end)
ssg.LayoutOrder = 8

local sm = mkSlider(p1, "Max Distance", 100, 9999, CFG.MaxDistance, " st",
    function(v) CFG.MaxDistance = v end)
sm.LayoutOrder = 9

mkSec(p1, "PREDICTION", 10).LayoutOrder = 10

-- Prediction presets for server-sided hitscan at sub-30ms ping.
-- PredictStrength now scales the CORRECT lead time (ping + target ping * 0.5).
-- At strength=1.0 the engine applies exactly what physics says you need.
-- Off = aim at current hitbox (use if misses feel like overshoots)
-- Normal = exact calculated lead (recommended for sub-30ms)
-- Aggressive = 2x lead (use if targets are lagging / high target ping)
local PRED_PRESETS = {
    { label = "Off",        val = 0.0, desc = "No prediction — aim at current hitbox"           },
    { label = "Normal",     val = 1.0, desc = "Exact lead — recommended for sub-30ms ping"      },
    { label = "Aggressive", val = 2.0, desc = "2x lead — use when targets have high ping"       },
}
local predActive = 2  -- default Normal

local predRow = Instance.new("Frame", p1)
predRow.Name = "PredRow"; predRow.Size = UDim2.new(1,0,0,58)
predRow.BackgroundColor3 = CARD; predRow.BorderSizePixel = 0; predRow.LayoutOrder = 11
Instance.new("UICorner", predRow).CornerRadius = UDim.new(0,6)

local predDescLbl = Instance.new("TextLabel", predRow)
predDescLbl.Size = UDim2.new(1,-12,0,16); predDescLbl.Position = UDim2.new(0,8,0,4)
predDescLbl.BackgroundTransparency = 1; predDescLbl.Text = PRED_PRESETS[predActive].desc
predDescLbl.TextColor3 = Color3.fromRGB(100,120,160)
predDescLbl.Font = Enum.Font.Gotham; predDescLbl.TextSize = 10
predDescLbl.TextXAlignment = Enum.TextXAlignment.Left

local predBtnHolder = Instance.new("Frame", predRow)
predBtnHolder.Size = UDim2.new(1,-12,0,28); predBtnHolder.Position = UDim2.new(0,6,0,24)
predBtnHolder.BackgroundTransparency = 1
local predBtnLayout = Instance.new("UIListLayout", predBtnHolder)
predBtnLayout.FillDirection = Enum.FillDirection.Horizontal
predBtnLayout.SortOrder = Enum.SortOrder.LayoutOrder; predBtnLayout.Padding = UDim.new(0,4)

local predBtns = {}
local function setPred(idx)
    predActive = idx; CFG.PredictStrength = PRED_PRESETS[idx].val
    predDescLbl.Text = PRED_PRESETS[idx].desc
    for i, btn in ipairs(predBtns) do
        if i == idx then
            btn.BackgroundColor3 = Color3.fromRGB(60,120,220)
            btn.TextColor3       = Color3.fromRGB(255,255,255)
        else
            btn.BackgroundColor3 = Color3.fromRGB(22,26,40)
            btn.TextColor3       = Color3.fromRGB(100,120,160)
        end
    end
end

for i, preset in ipairs(PRED_PRESETS) do
    local btn = Instance.new("TextButton", predBtnHolder)
    btn.Size = UDim2.new(0.33,-3,1,0); btn.BackgroundColor3 = Color3.fromRGB(22,26,40)
    btn.BorderSizePixel = 0; btn.Text = preset.label
    btn.TextColor3 = Color3.fromRGB(100,120,160); btn.Font = Enum.Font.GothamBold
    btn.TextSize = 11; btn.LayoutOrder = i
    Instance.new("UICorner", btn).CornerRadius = UDim.new(0,5)
    btn.MouseButton1Click:Connect(function() setPred(i) end)
    table.insert(predBtns, btn)
end
setPred(predActive)


-- ============================================================
-- PAGE 2: SETTINGS
-- ============================================================
local p2 = tPages[2]
mkSec(p2, "ACTIVATION MODE", 1)

local modeRow = Instance.new("Frame", p2)
modeRow.Size = UDim2.new(1,0,0,44); modeRow.BackgroundColor3 = CARD
modeRow.BorderSizePixel = 0; modeRow.LayoutOrder = 2
Instance.new("UICorner", modeRow).CornerRadius = UDim.new(0,6)
local modeLbl = Instance.new("TextLabel", modeRow)
modeLbl.Size = UDim2.new(0.5,0,1,0); modeLbl.Position = UDim2.new(0,12,0,0)
modeLbl.BackgroundTransparency = 1; modeLbl.Text = "Mode"; modeLbl.TextColor3 = WHITE
modeLbl.Font = Enum.Font.GothamMedium; modeLbl.TextSize = 12
modeLbl.TextXAlignment = Enum.TextXAlignment.Left
local modeBtn = Instance.new("TextButton", modeRow)
modeBtn.Size = UDim2.new(0,100,0,28); modeBtn.Position = UDim2.new(1,-108,0.5,-14)
modeBtn.BackgroundColor3 = ADIM; modeBtn.Text = "TOGGLE"; modeBtn.TextColor3 = ACCENT
modeBtn.Font = Enum.Font.GothamBold; modeBtn.TextSize = 11; modeBtn.BorderSizePixel = 0
Instance.new("UICorner", modeBtn).CornerRadius = UDim.new(0,6)
local mStroke = Instance.new("UIStroke", modeBtn)
mStroke.Color = ADIM; mStroke.Thickness = 1; mStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
modeBtn.MouseButton1Click:Connect(function()
    CFG.HoldMode = not CFG.HoldMode
    if CFG.HoldMode then
        modeBtn.Text = "HOLD"; modeBtn.TextColor3 = YELLOW
        tw(modeBtn, {BackgroundColor3 = Color3.fromRGB(80,58,10)})
    else
        modeBtn.Text = "TOGGLE"; modeBtn.TextColor3 = ACCENT
        tw(modeBtn, {BackgroundColor3 = ADIM})
    end
end)
modeBtn.MouseEnter:Connect(function() tw(modeBtn,{BackgroundColor3=Color3.fromRGB(50,110,170)}) end)
modeBtn.MouseLeave:Connect(function() tw(modeBtn,{BackgroundColor3=CFG.HoldMode and Color3.fromRGB(80,58,10) or ADIM}) end)
modeRow.MouseEnter:Connect(function() tw(modeRow,{BackgroundColor3=CARD2}) end)
modeRow.MouseLeave:Connect(function() tw(modeRow,{BackgroundColor3=CARD}) end)

mkSec(p2, "KEYBINDS", 3).LayoutOrder = 3
mkKeybind(p2, "Toggle Key (Toggle mode)", CFG.ActivationKey, function(k) CFG.ActivationKey = k end, 4)
mkKeybind(p2, "Hold Key (Hold mode)", CFG.HoldKey, function(k) CFG.HoldKey = k end, 5)
mkKeybind(p2, "Show/Hide Menu", CFG.MenuKey, function(k) CFG.MenuKey = k end, 6)

mkSec(p2, "AIM BODY PART", 7).LayoutOrder = 7

local AIMS   = {"ANY", "HumanoidRootPart", "Head", "Torso", "UpperTorso", "LowerTorso"}
local aimIdx = 1

local aimRow = Instance.new("Frame", p2)
aimRow.Size = UDim2.new(1,0,0,44); aimRow.BackgroundColor3 = CARD
aimRow.BorderSizePixel = 0; aimRow.LayoutOrder = 8
Instance.new("UICorner", aimRow).CornerRadius = UDim.new(0,6)
local aimLbl = Instance.new("TextLabel", aimRow)
aimLbl.Size = UDim2.new(0.45,0,1,0); aimLbl.Position = UDim2.new(0,12,0,0)
aimLbl.BackgroundTransparency = 1; aimLbl.Text = "Aim Part"; aimLbl.TextColor3 = WHITE
aimLbl.Font = Enum.Font.GothamMedium; aimLbl.TextSize = 12; aimLbl.TextXAlignment = Enum.TextXAlignment.Left
local aimLeft = Instance.new("TextButton", aimRow)
aimLeft.Size = UDim2.new(0,24,0,28); aimLeft.Position = UDim2.new(1,-150,0.5,-14)
aimLeft.BackgroundColor3 = DIM; aimLeft.Text = "<"; aimLeft.TextColor3 = WHITE
aimLeft.Font = Enum.Font.GothamBold; aimLeft.TextSize = 13; aimLeft.BorderSizePixel = 0
Instance.new("UICorner", aimLeft).CornerRadius = UDim.new(0,5)
local aimVal = Instance.new("TextLabel", aimRow)
aimVal.Size = UDim2.new(0,94,0,28); aimVal.Position = UDim2.new(1,-124,0.5,-14)
aimVal.BackgroundColor3 = Color3.fromRGB(11,13,22); aimVal.Text = AIMS[aimIdx]
aimVal.TextColor3 = ACCENT; aimVal.Font = Enum.Font.RobotoMono; aimVal.TextSize = 10
aimVal.TextXAlignment = Enum.TextXAlignment.Center; aimVal.BorderSizePixel = 0
Instance.new("UICorner", aimVal).CornerRadius = UDim.new(0,5)
local aimRight = Instance.new("TextButton", aimRow)
aimRight.Size = UDim2.new(0,24,0,28); aimRight.Position = UDim2.new(1,-28,0.5,-14)
aimRight.BackgroundColor3 = DIM; aimRight.Text = ">"; aimRight.TextColor3 = WHITE
aimRight.Font = Enum.Font.GothamBold; aimRight.TextSize = 13; aimRight.BorderSizePixel = 0
Instance.new("UICorner", aimRight).CornerRadius = UDim.new(0,5)
local function updateAim(dir)
    aimIdx = ((aimIdx-1+dir) % #AIMS) + 1; CFG.AimPart = AIMS[aimIdx]; aimVal.Text = AIMS[aimIdx]
    tw(aimVal,{TextColor3=WHITE}); task.delay(0.1,function() tw(aimVal,{TextColor3=ACCENT}) end)
end
aimLeft.MouseButton1Click:Connect(function()  updateAim(-1) end)
aimRight.MouseButton1Click:Connect(function() updateAim(1)  end)
aimLeft.MouseEnter:Connect(function()  tw(aimLeft, {BackgroundColor3=ADIM}) end)
aimLeft.MouseLeave:Connect(function()  tw(aimLeft, {BackgroundColor3=DIM})  end)
aimRight.MouseEnter:Connect(function() tw(aimRight,{BackgroundColor3=ADIM}) end)
aimRight.MouseLeave:Connect(function() tw(aimRight,{BackgroundColor3=DIM})  end)
aimRow.MouseEnter:Connect(function() tw(aimRow,{BackgroundColor3=CARD2}) end)
aimRow.MouseLeave:Connect(function() tw(aimRow,{BackgroundColor3=CARD})  end)

mkSec(p2, "PERFORMANCE & PRIVACY", 9).LayoutOrder = 9

local rowFps = mkToggle(p2, "FPS Booster (low-end PC)", CFG.FpsBoost, function(v)
    CFG.FpsBoost = v; applyFpsBoost(v)
end)
rowFps.LayoutOrder = 10

local rowStreamer = mkToggle(p2, "Streamer Mode  [F5]", CFG.StreamerMode, function(v)
    CFG.StreamerMode = v; applyStreamerMode(v)
end)
rowStreamer.LayoutOrder = 11


local streamerSync = function(v)
    CFG.StreamerMode = v; applyStreamerMode(v)
    local hit = rowStreamer:FindFirstChildOfClass("TextButton")
    if hit then hit.MouseButton1Click:Fire() end
end

-- ============================================================
-- PAGE 3: INFO
-- ============================================================
local p3 = tPages[3]
mkSec(p3, "SYSTEM INFO", 1)

local infos = {
    {"Version",     "3.3.0"},
    {"Game",        "Da Hills"},
    {"Detection",   "Raycast + Mouse"},
    {"Aim",         "ANY body part"},
    {"Distance",    "Up to 9999 st"},
    {"Modes",       "Toggle / Hold"},
    {"Menu Key",    "RightCtrl (rebind)"},
    {"Fire Logic",  "shotQueued (no drop)"},
    {"Prediction",  "Server-sided v2"},
    {"Weapon",      "Auto-detected"},
    {"Shotgun px",  "55px center check"},
    {"Other px",    "140px loose check"},
    {"SG min delay","40ms settle"},
    {"Lead cap",    "80ms max"},
}
for i, pair in ipairs(infos) do
    local row = Instance.new("Frame", p3)
    row.Size = UDim2.new(1,0,0,32)
    row.BackgroundColor3 = i%2==0 and CARD or Color3.fromRGB(19,22,34)
    row.BorderSizePixel = 0; row.LayoutOrder = i+1
    Instance.new("UICorner", row).CornerRadius = UDim.new(0,5)
    local k = Instance.new("TextLabel", row)
    k.Size = UDim2.new(0.5,0,1,0); k.Position = UDim2.new(0,12,0,0)
    k.BackgroundTransparency = 1; k.Text = pair[1]; k.TextColor3 = GREY
    k.Font = Enum.Font.GothamMedium; k.TextSize = 11; k.TextXAlignment = Enum.TextXAlignment.Left
    local v = Instance.new("TextLabel", row)
    v.Size = UDim2.new(0.45,0,1,0); v.Position = UDim2.new(0.52,-6,0,0)
    v.BackgroundTransparency = 1; v.Text = pair[2]; v.TextColor3 = WHITE
    v.Font = Enum.Font.RobotoMono; v.TextSize = 10; v.TextXAlignment = Enum.TextXAlignment.Right
end

-- ============================================================
-- GLOBAL KEYBINDS
-- ============================================================
local function syncStreamerToggle(v)
    local track = rowStreamer:FindFirstChildOfClass("Frame")
    if not track then return end
    local knob = track:FindFirstChildOfClass("Frame")
    tw(track, {BackgroundColor3 = v and ADIM or BORDER})
    if knob then
        tw(knob, {BackgroundColor3 = v and ACCENT or DIM,
                   Position = UDim2.new(v and 1 or 0, v and -18 or 2, 0.5,-8)})
    end
end

UserInputService.InputBegan:Connect(function(i, gp)
    if gp then return end
    if i.KeyCode == Enum.KeyCode.F5 then
        CFG.StreamerMode = not CFG.StreamerMode
        applyStreamerMode(CFG.StreamerMode)
        syncStreamerToggle(CFG.StreamerMode)
        return
    end
    if CFG.HoldMode then
        if i.KeyCode == CFG.HoldKey then setBadge(true) end
    else
        if i.KeyCode == CFG.ActivationKey then
            CFG.Enabled = not CFG.Enabled
            setBadge(CFG.Enabled)
            syncEnabled(CFG.Enabled)
        end
    end
end)

local LAYER = "aimviewer"

UserInputService.InputBegan:Connect(function(i)
    if i.KeyCode ~= CFG.MenuKey then return end
    if CFG.StreamerMode then return end
    if LAYER == "triggerbot" then toggleGui() end
end)

UserInputService.InputEnded:Connect(function(i, gp)
    if gp then return end
    if CFG.HoldMode and i.KeyCode == CFG.HoldKey then setBadge(false) end
end)

-- ============================================================
-- AIMVIEWER (unchanged from v3.0 — only TriggerBot core was modified)
-- ============================================================
local avConn      = nil
local avContainer = nil
local spectating  = nil
local mouseHitCache = {}
local _dumpDone   = {}

local function getReplicatedMousePos(plr)
    if not plr or not plr.Character then return nil end
    local char = plr.Character
    local hrp  = char:FindFirstChild("HumanoidRootPart")
    local attr = plr:GetAttribute("MousePos") or plr:GetAttribute("AimPos")
        or plr:GetAttribute("TargetPos") or plr:GetAttribute("MouseHit")
    if typeof(attr) == "Vector3" then return attr end
    local aimNames = {"MousePos","AimPos","TargetPos","MouseHit","AimPart","AimAttachment","Target","LookAt"}
    for _, name in ipairs(aimNames) do
        local obj = char:FindFirstChild(name, true)
        if obj then
            if obj:IsA("Vector3Value") then return obj.Value end
            if obj:IsA("CFrameValue")  then return obj.Value.Position end
            if obj:IsA("Attachment")   then return obj.WorldPosition end
            if obj:IsA("Part") or obj:IsA("BasePart") then return obj.Position end
        end
    end
    local wpPlrs = workspace:FindFirstChild("Players")
    if wpPlrs then
        local wpPlr = wpPlrs:FindFirstChild(plr.Name)
        if wpPlr then
            for _, obj in ipairs(wpPlr:GetDescendants()) do
                if obj:IsA("Vector3Value") then return obj.Value end
                if obj:IsA("Attachment") then return obj.WorldPosition end
            end
        end
    end
    if hrp then
        for _, obj in ipairs(char:GetDescendants()) do
            if (obj:IsA("Attachment") or obj:IsA("Part"))
                and obj.Name ~= "HumanoidRootPart" and obj.Name ~= "Head"
                and obj.Name ~= "Torso" and obj.Name ~= "UpperTorso" and obj.Name ~= "LowerTorso" then
                local pos = obj:IsA("Attachment") and obj.WorldPosition or obj.Position
                if (pos - hrp.Position).Magnitude > 5 then return pos end
            end
        end
    end
    return nil
end

win.Visible = false
win.Size    = UDim2.new(0, W, 0, H)
win.BackgroundTransparency = 0

local function destroyAimViewer()
    if avConn then avConn:Disconnect(); avConn = nil end
    spectating = nil
    pcall(function() CAM.CameraType = Enum.CameraType.Custom end)
    local rb = sg:FindFirstChild("AV_ReopenBtn")
    if rb then rb:Destroy() end
    local sh = sg:FindFirstChild("AV_StopHud")
    if sh then sh:Destroy() end
    local ap = workspace:FindFirstChild("AV_AimPart")
    if ap then ap:Destroy() end
    if avContainer and avContainer.Parent then
        avContainer:Destroy(); avContainer = nil
    end
end

local function destroyTriggerBot()
    win.Visible = false
end

local returnToAimViewer = nil

local function buildAimViewer()
    destroyAimViewer()
    LAYER = "aimviewer"

    local AV_W, AV_H = 420, 530
    local av = Instance.new("Frame", sg)
    av.Name = "AimViewer"; av.Size = UDim2.new(0,AV_W,0,AV_H)
    av.Position = UDim2.new(0.5,-AV_W/2,0.5,-AV_H/2)
    av.BackgroundColor3 = Color3.fromRGB(10,12,20)
    av.BorderSizePixel = 0; av.ZIndex = 100; av.ClipsDescendants = true
    avContainer = av
    Instance.new("UICorner", av).CornerRadius = UDim.new(0,10)
    local avStk = Instance.new("UIStroke", av)
    avStk.Color = Color3.fromRGB(35,42,62); avStk.Thickness = 1
    avStk.ApplyStrokeMode = Enum.ApplyStrokeMode.Border

    local avBar = Instance.new("Frame", av)
    avBar.Size = UDim2.new(1,0,0,3); avBar.BackgroundColor3 = Color3.fromRGB(70,130,220)
    avBar.BorderSizePixel = 0; avBar.ZIndex = 101
    local avBarG = Instance.new("UIGradient", avBar)
    avBarG.Color = ColorSequence.new(Color3.fromRGB(70,130,220), Color3.fromRGB(30,70,160))

    local avHdr = Instance.new("Frame", av)
    avHdr.Size = UDim2.new(1,0,0,56); avHdr.Position = UDim2.new(0,0,0,3)
    avHdr.BackgroundColor3 = Color3.fromRGB(13,16,26); avHdr.BorderSizePixel = 0; avHdr.ZIndex = 101

    local avIcon = Instance.new("Frame", avHdr)
    avIcon.Size = UDim2.new(0,34,0,34); avIcon.Position = UDim2.new(0,12,0.5,-17)
    avIcon.BackgroundColor3 = Color3.fromRGB(30,60,130); avIcon.BorderSizePixel = 0; avIcon.ZIndex = 102
    Instance.new("UICorner", avIcon).CornerRadius = UDim.new(0,8)
    local avIconTxt = Instance.new("TextLabel", avIcon)
    avIconTxt.Size = UDim2.new(1,0,1,0); avIconTxt.BackgroundTransparency = 1
    avIconTxt.Text = "AV"; avIconTxt.TextColor3 = Color3.fromRGB(100,170,255)
    avIconTxt.Font = Enum.Font.GothamBold; avIconTxt.TextSize = 12; avIconTxt.ZIndex = 103

    local avTitle = Instance.new("TextLabel", avHdr)
    avTitle.Size = UDim2.new(0,200,0,20); avTitle.Position = UDim2.new(0,54,0,8)
    avTitle.BackgroundTransparency = 1; avTitle.Text = "AimViewer"
    avTitle.TextColor3 = Color3.fromRGB(225,232,248); avTitle.Font = Enum.Font.GothamBold
    avTitle.TextSize = 15; avTitle.TextXAlignment = Enum.TextXAlignment.Left; avTitle.ZIndex = 102

    local avSub = Instance.new("TextLabel", avHdr)
    avSub.Size = UDim2.new(0,240,0,14); avSub.Position = UDim2.new(0,54,0,30)
    avSub.BackgroundTransparency = 1; avSub.Text = "Player Aim Inspector  |  v1.2"
    avSub.TextColor3 = Color3.fromRGB(90,100,130); avSub.Font = Enum.Font.GothamMedium
    avSub.TextSize = 10; avSub.TextXAlignment = Enum.TextXAlignment.Left; avSub.ZIndex = 102

    local avCloseBtn = Instance.new("TextButton", avHdr)
    avCloseBtn.Size = UDim2.new(0,28,0,28); avCloseBtn.Position = UDim2.new(1,-36,0.5,-14)
    avCloseBtn.BackgroundColor3 = Color3.fromRGB(50,16,16); avCloseBtn.BackgroundTransparency = 0.3
    avCloseBtn.Text = "X"; avCloseBtn.TextColor3 = Color3.fromRGB(255,80,80)
    avCloseBtn.TextSize = 12; avCloseBtn.Font = Enum.Font.GothamBold
    avCloseBtn.BorderSizePixel = 0; avCloseBtn.ZIndex = 103
    Instance.new("UICorner", avCloseBtn).CornerRadius = UDim.new(0,6)

    local reopenBtn = Instance.new("TextButton", sg)
    reopenBtn.Name = "AV_ReopenBtn"; reopenBtn.Size = UDim2.new(0,110,0,30)
    reopenBtn.Position = UDim2.new(0,8,0,8); reopenBtn.BackgroundColor3 = Color3.fromRGB(20,50,120)
    reopenBtn.Text = "▶  AimViewer"; reopenBtn.TextColor3 = Color3.fromRGB(100,170,255)
    reopenBtn.Font = Enum.Font.GothamBold; reopenBtn.TextSize = 11
    reopenBtn.BorderSizePixel = 0; reopenBtn.ZIndex = 300; reopenBtn.Visible = false
    Instance.new("UICorner", reopenBtn).CornerRadius = UDim.new(0,6)
    local rkStroke = Instance.new("UIStroke", reopenBtn)
    rkStroke.Color = Color3.fromRGB(50,100,200); rkStroke.Thickness = 1
    rkStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border

    reopenBtn.MouseButton1Click:Connect(function() reopenBtn.Visible = false; av.Visible = true end)
    avCloseBtn.MouseButton1Click:Connect(function() av.Visible = false; reopenBtn.Visible = true end)

    local avDragActive, avDragStart, avWinStart = false, nil, nil
    avHdr.InputBegan:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1 then
            avDragActive = true; avDragStart = i.Position; avWinStart = av.Position
        end
    end)
    avHdr.InputEnded:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1 then avDragActive = false end
    end)
    UserInputService.InputChanged:Connect(function(i)
        if avDragActive and i.UserInputType == Enum.UserInputType.MouseMovement then
            local d = i.Position - avDragStart
            av.Position = UDim2.new(avWinStart.X.Scale, avWinStart.X.Offset+d.X,
                                     avWinStart.Y.Scale, avWinStart.Y.Offset+d.Y)
        end
    end)

    local avSearchBg = Instance.new("Frame", av)
    avSearchBg.Size = UDim2.new(1,-24,0,36); avSearchBg.Position = UDim2.new(0,12,0,68)
    avSearchBg.BackgroundColor3 = Color3.fromRGB(18,22,36); avSearchBg.BorderSizePixel = 0; avSearchBg.ZIndex = 101
    Instance.new("UICorner", avSearchBg).CornerRadius = UDim.new(0,7)
    local avSSk = Instance.new("UIStroke", avSearchBg)
    avSSk.Color = Color3.fromRGB(40,50,75); avSSk.Thickness = 1; avSSk.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
    local avSIcon = Instance.new("TextLabel", avSearchBg)
    avSIcon.Size = UDim2.new(0,28,1,0); avSIcon.BackgroundTransparency = 1
    avSIcon.Text = "🔍"; avSIcon.TextSize = 13; avSIcon.ZIndex = 102
    local avSearch = Instance.new("TextBox", avSearchBg)
    avSearch.Size = UDim2.new(1,-32,1,0); avSearch.Position = UDim2.new(0,28,0,0)
    avSearch.BackgroundTransparency = 1; avSearch.PlaceholderText = "Search players..."
    avSearch.PlaceholderColor3 = Color3.fromRGB(60,70,100); avSearch.Text = ""
    avSearch.TextColor3 = Color3.fromRGB(200,210,230); avSearch.Font = Enum.Font.GothamMedium
    avSearch.TextSize = 12; avSearch.TextXAlignment = Enum.TextXAlignment.Left
    avSearch.ClearTextOnFocus = false; avSearch.ZIndex = 102

    local avDiv = Instance.new("Frame", av)
    avDiv.Size = UDim2.new(1,-20,0,1); avDiv.Position = UDim2.new(0,10,0,112)
    avDiv.BackgroundColor3 = Color3.fromRGB(35,42,62); avDiv.BorderSizePixel = 0; avDiv.ZIndex = 101

    local avList = Instance.new("ScrollingFrame", av)
    avList.Size = UDim2.new(1,0,0,AV_H-120); avList.Position = UDim2.new(0,0,0,118)
    avList.BackgroundTransparency = 1; avList.BorderSizePixel = 0
    avList.ScrollBarThickness = 3; avList.ScrollBarImageColor3 = Color3.fromRGB(40,60,120)
    avList.CanvasSize = UDim2.new(0,0,0,0); avList.AutomaticCanvasSize = Enum.AutomaticSize.Y; avList.ZIndex = 101
    local avPad = Instance.new("UIPadding", avList)
    avPad.PaddingLeft = UDim.new(0,10); avPad.PaddingRight = UDim.new(0,10); avPad.PaddingTop = UDim.new(0,6)
    local avLayout = Instance.new("UIListLayout", avList)
    avLayout.Padding = UDim.new(0,4); avLayout.SortOrder = Enum.SortOrder.LayoutOrder
    local listHdr = Instance.new("TextLabel", avList)
    listHdr.Size = UDim2.new(1,0,0,16); listHdr.BackgroundTransparency = 1
    listHdr.Text = "PLAYERS IN SERVER"; listHdr.LayoutOrder = 0
    listHdr.TextColor3 = Color3.fromRGB(50,60,90); listHdr.Font = Enum.Font.GothamBold
    listHdr.TextSize = 9; listHdr.TextXAlignment = Enum.TextXAlignment.Left; listHdr.ZIndex = 102

    local aimPart = Instance.new("Part")
    aimPart.Name = "AV_AimPart"; aimPart.Anchored = true; aimPart.CanCollide = false
    aimPart.CanQuery = false; aimPart.CanTouch = false; aimPart.CastShadow = false
    aimPart.Material = Enum.Material.Neon; aimPart.BrickColor = BrickColor.new("Bright red")
    aimPart.Size = Vector3.new(0.05,0.05,0.05); aimPart.Parent = workspace

    local stopHud = Instance.new("Frame", sg)
    stopHud.Name = "AV_StopHud"; stopHud.Size = UDim2.new(0,260,0,36)
    stopHud.Position = UDim2.new(0.5,-130,0,10); stopHud.BackgroundColor3 = Color3.fromRGB(8,10,20)
    stopHud.BackgroundTransparency = 0.15; stopHud.BorderSizePixel = 0; stopHud.ZIndex = 501; stopHud.Visible = false
    Instance.new("UICorner", stopHud).CornerRadius = UDim.new(0,8)
    local stopHudTxt = Instance.new("TextLabel", stopHud)
    stopHudTxt.Size = UDim2.new(1,-80,1,0); stopHudTxt.Position = UDim2.new(0,10,0,0)
    stopHudTxt.BackgroundTransparency = 1; stopHudTxt.Text = "SPECTATING: ?"
    stopHudTxt.TextColor3 = Color3.fromRGB(100,170,255); stopHudTxt.Font = Enum.Font.GothamBold
    stopHudTxt.TextSize = 11; stopHudTxt.TextXAlignment = Enum.TextXAlignment.Left; stopHudTxt.ZIndex = 502
    local stopBtn = Instance.new("TextButton", stopHud)
    stopBtn.Size = UDim2.new(0,60,0,24); stopBtn.Position = UDim2.new(1,-68,0.5,-12)
    stopBtn.BackgroundColor3 = Color3.fromRGB(160,30,30); stopBtn.Text = "STOP"
    stopBtn.TextColor3 = Color3.fromRGB(255,255,255); stopBtn.Font = Enum.Font.GothamBold
    stopBtn.TextSize = 11; stopBtn.BorderSizePixel = 0; stopBtn.ZIndex = 502
    Instance.new("UICorner", stopBtn).CornerRadius = UDim.new(0,5)

    local SBW, SBH = 215, 80
    local statBox = Instance.new("Frame", sg)
    statBox.Name = "AV_StatBox"; statBox.Size = UDim2.new(0,SBW,0,SBH)
    statBox.Position = UDim2.new(1,-SBW-8,0,54); statBox.BackgroundColor3 = Color3.fromRGB(8,10,20)
    statBox.BackgroundTransparency = 0.1; statBox.BorderSizePixel = 0; statBox.ZIndex = 502; statBox.Visible = false
    Instance.new("UICorner", statBox).CornerRadius = UDim.new(0,8)
    local sbStroke = Instance.new("UIStroke", statBox)
    sbStroke.Color = Color3.fromRGB(35,42,62); sbStroke.Thickness = 1; sbStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
    local sbHdr = Instance.new("Frame", statBox)
    sbHdr.Size = UDim2.new(1,0,0,24); sbHdr.BackgroundColor3 = Color3.fromRGB(15,20,40)
    sbHdr.BorderSizePixel = 0; sbHdr.ZIndex = 503
    Instance.new("UICorner", sbHdr).CornerRadius = UDim.new(0,8)
    local sbHdrTxt = Instance.new("TextLabel", sbHdr)
    sbHdrTxt.Size = UDim2.new(1,-8,1,0); sbHdrTxt.Position = UDim2.new(0,8,0,0)
    sbHdrTxt.BackgroundTransparency = 1; sbHdrTxt.Text = "PLAYER STATS"
    sbHdrTxt.TextColor3 = Color3.fromRGB(100,160,255); sbHdrTxt.Font = Enum.Font.GothamBold
    sbHdrTxt.TextSize = 10; sbHdrTxt.TextXAlignment = Enum.TextXAlignment.Left; sbHdrTxt.ZIndex = 504

    local function mkRow(labelTxt, yPos)
        local lbl = Instance.new("TextLabel", statBox)
        lbl.Size = UDim2.new(0,72,0,16); lbl.Position = UDim2.new(0,8,0,yPos)
        lbl.BackgroundTransparency = 1; lbl.Text = labelTxt
        lbl.TextColor3 = Color3.fromRGB(80,100,140); lbl.Font = Enum.Font.GothamBold
        lbl.TextSize = 10; lbl.TextXAlignment = Enum.TextXAlignment.Left; lbl.ZIndex = 503
        local val = Instance.new("TextLabel", statBox)
        val.Size = UDim2.new(0,125,0,16); val.Position = UDim2.new(0,82,0,yPos)
        val.BackgroundTransparency = 1; val.Text = "—"
        val.TextColor3 = Color3.fromRGB(220,230,255); val.Font = Enum.Font.GothamBold
        val.TextSize = 10; val.TextXAlignment = Enum.TextXAlignment.Left; val.ZIndex = 503
        return val
    end
    local function mkBar(yPos, color)
        local bg = Instance.new("Frame", statBox)
        bg.Size = UDim2.new(1,-16,0,7); bg.Position = UDim2.new(0,8,0,yPos)
        bg.BackgroundColor3 = Color3.fromRGB(30,35,50); bg.BorderSizePixel = 0; bg.ZIndex = 503
        Instance.new("UICorner", bg).CornerRadius = UDim.new(0,3)
        local fill = Instance.new("Frame", bg)
        fill.Size = UDim2.new(0,0,1,0); fill.BackgroundColor3 = color
        fill.BorderSizePixel = 0; fill.ZIndex = 504
        Instance.new("UICorner", fill).CornerRadius = UDim.new(0,3)
        return fill
    end
    local valHP  = mkRow("❤ Health", 28)
    local hpBar  = mkBar(46, Color3.fromRGB(80,220,100))
    local valSpd = mkRow("⚡ Speed",  60)

    local shotsHit = 0; local shotsFired = 0; local shotConns = {}
    local SHOT_DEBOUNCE = 0.15; local lastFlashTime = 0; local lastShotTime = 0

    local function rebuildShotTracking()
        for _, c in ipairs(shotConns) do pcall(function() c:Disconnect() end) end
        shotConns = {}
        if not spectating or not spectating.Character then return end
        local sChar = spectating.Character
        local function watchTool(tool)
            if not tool then return end
            table.insert(shotConns, tool.ChildAdded:Connect(function(child)
                local n = child.Name:lower()
                if n:find("flash") or n:find("muzzle") or n:find("fire") or n:find("bullet") or n:find("shot") then
                    local now = tick()
                    if now - lastFlashTime > SHOT_DEBOUNCE then lastFlashTime = now; shotsFired = shotsFired+1 end
                end
            end))
        end
        watchTool(sChar:FindFirstChildOfClass("Tool"))
        table.insert(shotConns, sChar.ChildAdded:Connect(function(child)
            if child:IsA("Tool") then task.defer(function() watchTool(child) end) end
        end))
        for _, op in ipairs(Players:GetPlayers()) do
            if op ~= spectating and op ~= LP and op.Character then
                local opHum = op.Character:FindFirstChildOfClass("Humanoid")
                if opHum then
                    table.insert(shotConns, opHum:GetPropertyChangedSignal("Health"):Connect(function()
                        local now2 = tick()
                        if opHum.Health < opHum.MaxHealth and (now2-lastShotTime) < 1.5 then
                            shotsHit = shotsHit+1
                        end
                        lastShotTime = now2
                    end))
                end
            end
        end
    end

    local function stopSpectating()
        spectating = nil; stopHud.Visible = false; av.Visible = true
        shotsHit=0; shotsFired=0; lastShotTime=0; lastFlashTime=0
        for _, c in ipairs(shotConns) do pcall(function() c:Disconnect() end) end
        shotConns = {}; statBox.Visible = false; aimPart.Size = Vector3.zero
        task.defer(function()
            local myHum = LP.Character and LP.Character:FindFirstChildOfClass("Humanoid")
            if myHum then CAM.CameraSubject = myHum end
            CAM.CameraType = Enum.CameraType.Custom
        end)
    end

    local function selectPlayer(p)
        spectating = p; stopHudTxt.Text = "SPECTATING: "..p.Name
        stopHud.Visible = true; av.Visible = false
        shotsHit=0; shotsFired=0; lastShotTime=0; lastFlashTime=0
        valHP.Text="—"; valSpd.Text="—"; hpBar.Size=UDim2.new(0,0,1,0)
        statBox.Visible = true; task.defer(rebuildShotTracking)
        if not _dumpDone[p] then
            _dumpDone[p] = true
            task.delay(1, function() end)  -- dump removed for release
        end
    end

    stopBtn.MouseButton1Click:Connect(stopSpectating)

    local listConns = {}
    local function rebuildList()
        for _, c in ipairs(listConns) do pcall(function() c:Disconnect() end) end
        listConns = {}
        for _, child in ipairs(avList:GetChildren()) do
            if child:IsA("TextButton") then child:Destroy() end
        end
        local order = 1
        for _, p in ipairs(Players:GetPlayers()) do
            if p ~= LP then
                local rowColor = order%2==0 and Color3.fromRGB(18,22,36) or Color3.fromRGB(14,17,27)
                local row = Instance.new("TextButton", avList)
                row.Size = UDim2.new(1,0,0,42); row.BackgroundColor3 = rowColor
                row.BorderSizePixel = 0; row.LayoutOrder = order; row.ZIndex = 102
                row.Text = ""; row.AutoButtonColor = false
                Instance.new("UICorner", row).CornerRadius = UDim.new(0,6)
                local dot = Instance.new("Frame", row)
                dot.Size = UDim2.new(0,8,0,8); dot.Position = UDim2.new(0,10,0.5,-4)
                dot.BackgroundColor3 = Color3.fromRGB(55,215,125); dot.BorderSizePixel = 0; dot.ZIndex = 103
                Instance.new("UICorner", dot).CornerRadius = UDim.new(1,0)
                local nm = Instance.new("TextLabel", row)
                nm.Size = UDim2.new(0,180,1,0); nm.Position = UDim2.new(0,26,0,0)
                nm.BackgroundTransparency = 1; nm.Text = p.Name
                nm.TextColor3 = Color3.fromRGB(210,220,240); nm.Font = Enum.Font.GothamMedium
                nm.TextSize = 12; nm.TextXAlignment = Enum.TextXAlignment.Left; nm.ZIndex = 103
                local specBtn = Instance.new("TextButton", row)
                specBtn.Size = UDim2.new(0,72,0,26); specBtn.Position = UDim2.new(1,-80,0.5,-13)
                specBtn.BackgroundColor3 = Color3.fromRGB(25,55,110); specBtn.Text = "SPECTATE"
                specBtn.TextColor3 = Color3.fromRGB(100,170,255); specBtn.Font = Enum.Font.GothamBold
                specBtn.TextSize = 9; specBtn.BorderSizePixel = 0; specBtn.ZIndex = 103
                Instance.new("UICorner", specBtn).CornerRadius = UDim.new(0,5)
                table.insert(listConns, specBtn.MouseButton1Click:Connect(function() selectPlayer(p) end))
                table.insert(listConns, row.MouseEnter:Connect(function()
                    TweenService:Create(row, TweenInfo.new(0.12), {BackgroundColor3=Color3.fromRGB(28,35,58)}):Play()
                end))
                table.insert(listConns, row.MouseLeave:Connect(function()
                    TweenService:Create(row, TweenInfo.new(0.12), {BackgroundColor3=rowColor}):Play()
                end))
                order = order+1
            end
        end
        if order == 1 then
            local empty = Instance.new("TextLabel", avList)
            empty.Size = UDim2.new(1,0,0,40); empty.LayoutOrder = 1
            empty.BackgroundTransparency = 1; empty.Text = "No other players in server"
            empty.TextColor3 = Color3.fromRGB(60,70,100); empty.Font = Enum.Font.Gotham
            empty.TextSize = 11; empty.ZIndex = 102
        end
    end
    rebuildList()

    local paConn = Players.PlayerAdded:Connect(function() task.wait(1); if LAYER=="aimviewer" and av.Parent then rebuildList() end end)
    local prConn = Players.PlayerRemoving:Connect(function() task.wait(0.1); if LAYER=="aimviewer" and av.Parent then rebuildList() end end)
    local refreshTimer = 0
    local timerConn = RunService.Heartbeat:Connect(function(dt)
        if LAYER ~= "aimviewer" or not av.Parent then return end
        refreshTimer = refreshTimer + dt
        if refreshTimer >= 30 then refreshTimer = 0; rebuildList() end
    end)
    local _oldDestroy = destroyAimViewer
    destroyAimViewer = function()
        pcall(function() paConn:Disconnect() end)
        pcall(function() prConn:Disconnect() end)
        pcall(function() timerConn:Disconnect() end)
        for _, c in ipairs(listConns) do pcall(function() c:Disconnect() end) end
        _oldDestroy()
    end

    local origSubject = CAM.CameraSubject
    local origType    = CAM.CameraType

    local function applySpectateCamera()
        if not spectating or not spectating.Character then return end
        local char = spectating.Character
        local hum  = char:FindFirstChildOfClass("Humanoid")
        local hrp  = char:FindFirstChild("HumanoidRootPart")
        if not hum then return end
        CAM.CameraSubject = hum; CAM.CameraType = Enum.CameraType.Custom
        if hrp then
            local rightOffset = hrp.CFrame.RightVector * 8
            local backOffset  = hrp.CFrame.LookVector  * (-4)
            local upOffset    = Vector3.new(0,3,0)
            local camPos      = hrp.Position + rightOffset + backOffset + upOffset
            CAM.CFrame = CFrame.new(camPos, hrp.Position + Vector3.new(0,1,0))
        end
    end

    avConn = RunService.RenderStepped:Connect(function()
        if not spectating or not spectating.Character then aimPart.Size = Vector3.zero; return end
        local hum = spectating.Character:FindFirstChildOfClass("Humanoid")
        if hum and CAM.CameraSubject ~= hum then
            CAM.CameraType = Enum.CameraType.Custom; CAM.CameraSubject = hum
        end
        local char = spectating.Character
        local hrp  = char:FindFirstChild("HumanoidRootPart")
        if not hrp then aimPart.Size = Vector3.zero; return end
        local rh = char:FindFirstChild("RightHand") or char:FindFirstChild("Right Arm")
        local lineStart = rh and rh.Position
            or (hrp.Position + hrp.CFrame.RightVector * 0.6 + Vector3.new(0,0.5,0))
        local lineEnd
        local replicatedPos = getReplicatedMousePos(spectating)
        if replicatedPos then
            lineEnd = replicatedPos
        else
            local aimDir = hrp.CFrame.LookVector
            local rp = RaycastParams.new()
            rp.FilterDescendantsInstances = {char}; rp.FilterType = Enum.RaycastFilterType.Exclude
            local hit = workspace:Raycast(lineStart, aimDir*500, rp)
            lineEnd = hit and hit.Position or (lineStart + aimDir*500)
        end
        local length = (lineEnd-lineStart).Magnitude
        aimPart.Size   = Vector3.new(0.06, 0.06, length)
        aimPart.CFrame = CFrame.new((lineStart+lineEnd)*0.5, lineEnd)
        local hum2 = char:FindFirstChildOfClass("Humanoid")
        if hum2 and statBox.Visible then
            local hp    = math.floor(hum2.Health)
            local maxHp = math.max(math.floor(hum2.MaxHealth),1)
            local hpPct = hp/maxHp
            valHP.Text = hp.." / "..maxHp
            valHP.TextColor3 = hpPct>0.6 and Color3.fromRGB(80,220,100)
                or hpPct>0.3 and Color3.fromRGB(255,200,50) or Color3.fromRGB(255,70,70)
            hpBar.Size = UDim2.new(hpPct,0,1,0); hpBar.BackgroundColor3 = valHP.TextColor3
            local spd = math.floor(hrp.AssemblyLinearVelocity.Magnitude)
            valSpd.Text = spd.." u/s"
            valSpd.TextColor3 = spd>24 and Color3.fromRGB(255,160,40) or Color3.fromRGB(180,200,255)
        end
    end)

    local _origSelect = selectPlayer
    selectPlayer = function(p) _origSelect(p); applySpectateCamera() end

    local origDestroyAV = destroyAimViewer
    destroyAimViewer = function()
        CAM.CameraSubject = origSubject; CAM.CameraType = origType
        task.defer(function() CAM.CameraType = Enum.CameraType.Custom end)
        pcall(function() aimPart:Destroy() end)
        pcall(function() stopHud:Destroy() end)
        pcall(function() statBox:Destroy() end)
        mouseHitCache = {}; origDestroyAV()
    end

    avSearch:GetPropertyChangedSignal("Text"):Connect(function()
        if avSearch.Text == "Triggerbot" then
            destroyAimViewer(); LAYER = "triggerbot"
            win.Size = UDim2.new(0,W,0,0); win.BackgroundTransparency = 1; win.Visible = true
            tw(win, {Size=UDim2.new(0,W,0,H), BackgroundTransparency=0}, MED)
        end
    end)
end

returnToAimViewer = function()
    destroyTriggerBot(); buildAimViewer()
end

-- Settings page "AimViewer" button
local avBtnRow = Instance.new("Frame", p2)
avBtnRow.Size = UDim2.new(1,0,0,44); avBtnRow.BackgroundColor3 = Color3.fromRGB(22,26,40)
avBtnRow.BorderSizePixel = 0; avBtnRow.LayoutOrder = 13
Instance.new("UICorner", avBtnRow).CornerRadius = UDim.new(0,6)
local avBtnStroke = Instance.new("UIStroke", avBtnRow)
avBtnStroke.Color = Color3.fromRGB(30,60,130); avBtnStroke.Thickness = 1; avBtnStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
local avBtnLbl = Instance.new("TextLabel", avBtnRow)
avBtnLbl.Size = UDim2.new(0.55,0,1,0); avBtnLbl.Position = UDim2.new(0,12,0,0)
avBtnLbl.BackgroundTransparency = 1; avBtnLbl.Text = "AimViewer"
avBtnLbl.TextColor3 = Color3.fromRGB(225,232,248); avBtnLbl.Font = Enum.Font.GothamMedium
avBtnLbl.TextSize = 12; avBtnLbl.TextXAlignment = Enum.TextXAlignment.Left
local avBtn = Instance.new("TextButton", avBtnRow)
avBtn.Size = UDim2.new(0,100,0,28); avBtn.Position = UDim2.new(1,-108,0.5,-14)
avBtn.BackgroundColor3 = Color3.fromRGB(30,60,130); avBtn.Text = "SHOW"
avBtn.TextColor3 = Color3.fromRGB(100,170,255); avBtn.Font = Enum.Font.GothamBold
avBtn.TextSize = 11; avBtn.BorderSizePixel = 0
Instance.new("UICorner", avBtn).CornerRadius = UDim.new(0,6)
avBtn.MouseButton1Click:Connect(function() if returnToAimViewer then returnToAimViewer() end end)

buildAimViewer()
startLoop()
print("HB TriggerBot v5.0 loaded.")
