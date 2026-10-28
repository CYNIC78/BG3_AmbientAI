-- ============================================================================
-- Script: Ambient AI - Build 04.3.2: Multi-Engine Light Ignition, Grouped Lock & Navmesh Fix (v1.4.3.2)
-- Original Author: ExcelsiorOne
-- Build 04.3.2 Hotfix Upgrades:
--   - Multi-Engine Light Ignition: Ignites Constellation lights (Lamp, Light,
--     Torch, BurningItem, StatusDrivenLight) via idempotent input socket
--     ConstellationTriggerInputSocket("TurnOn") alongside DOS2_Torch "BURNING"
--     status for wax candles & candle clusters («Свечи»), sconces, candelabras,
--     wall bowls & braziers — zero self-poisoning and zero item pickup!
--   - Grouped Action Tether Lock: Holds temporary PartyBlockFollowComponent
--     (SetNoFollowFlag) across multi-step off-leash ActionQueues so BG3's
--     DefaultPartyMember (PauseFollow = 200ms) never yanks grouped companions
--     away mid-turn before LightIt / SitOnSeat / AdmireArt / Inspect executes!
--   - Fast Multi-Elevation Navmesh & 2D Reach: Eliminates the 667ms surface
--     floodfill stall on stepped floors (GOB_Temple) and fixes wall-sconce /
--     wall-art vertical distance checks so companions never stall at 2.8m 3D!
-- ============================================================================

PersistentVars = PersistentVars or {}

local MyModUUID = ModuleUUID or "7d2e1b4a-9c8f-4a1d-b5e2-6f3a9c8b1d4e"
local ActionVoiceChannel = (Ext and Ext.Net and Ext.Net.CreateChannel)
    and Ext.Net.CreateChannel(MyModUUID, "ActionVoice")
    or nil

local LOCA_HANDLES = {
    StatusOn        = "h7d2e1b4ag0005g4a1dgb5e2g6f3a9c8b0005",
    StatusOff       = "h7d2e1b4ag0006g4a1dgb5e2g6f3a9c8b0006",
    CalloutTrap     = "h7d2e1b4ag0060g4a1dgb5e2g6f3a9c8b0060",
    CalloutGear     = "h7d2e1b4ag0061g4a1dgb5e2g6f3a9c8b0061",
    CalloutConsum   = "h7d2e1b4ag0062g4a1dgb5e2g6f3a9c8b0062",
    CalloutBookKey  = "h7d2e1b4ag0063g4a1dgb5e2g6f3a9c8b0063",
    CalloutRare     = "h7d2e1b4ag0064g4a1dgb5e2g6f3a9c8b0064",
    CalloutSoldFmt  = "h7d2e1b4ag0065g4a1dgb5e2g6f3a9c8b0065",
    CalloutSupply   = "h7d2e1b4ag0066g4a1dgb5e2g6f3a9c8b0066",
}

Ext.Utils.Print("--- AMBIENT AI: BUILD 04.3.2 - MULTI-ENGINE LIGHTS, GROUPED LOCK & NAVMESH FIX (v1.4.3.2) ---")

-- ============================================================================
-- 1. CONFIGURATION MANAGER (MCM + EVENT-DRIVEN CACHE)
-- ============================================================================

local ConfigValues = {
    Debug               = false,
    AllowGrouped        = true,
    GroupedIdleDelay    = 6,   -- 04.3.12: was 12 (wake offsets stack on top of this)
    IdleAnchorRadius    = 3.5,
    SearchRadius        = 12.0,
    FlavorCooldown      = 20000,
    AnimFrequency       = 0.30,
    Personalities       = true,
    BardSync            = true,
    ContextAware        = true,
    PostCombatBreather  = true,
    SocialPets          = true,
    ReactiveVoices      = true,
    VoiceShare          = 80,
    ActionVoices        = true,
    ActionVoiceCooldown = 24,
    SmartScavenger      = true,
    AutoSellTrader      = true,
    MinSellValue        = 10,
    TrapReflex          = true,
    AutoWash            = true,
    FieldTorch          = true,
    LightSources        = true,
    LootMode            = 2, -- 0 = All, 1 = GoldOnly, 2 = Disabled
    AttackWalls         = false,
    BedRegen            = true,
    ReadingXP           = false,
    RegenAmount         = 1,
    CheckInterval       = 600,
    WatchdogInterval    = 150,
}

local LastConfigSync = 0

local function ParseLootMode(val)
    if val == "All" or val == 0 then return 0 end
    if val == "GoldOnly" or val == 1 then return 1 end
    if val == "Disabled" or val == 2 then return 2 end
    local num = tonumber(val)
    if num == 0 or num == 1 or num == 2 then return num end
    return 2
end

local function RawMCMGet(settingId)
    if MCM and type(MCM.Get) == "function" then
        local ok, val = pcall(MCM.Get, settingId)
        if ok and val ~= nil then return val end
    end
    if Mods and Mods.BG3MCM and Mods.BG3MCM.MCMAPI and Mods.BG3MCM.MCMAPI.GetSettingValue then
        local ok, val = pcall(function()
            return Mods.BG3MCM.MCMAPI:GetSettingValue(settingId, MyModUUID)
        end)
        if ok and val ~= nil then return val end
    end
    return nil
end

local function ApplySingleSetting(settingId, value)
    if value == nil then return end
    if settingId == "AmbientAI_Debug" then
        ConfigValues.Debug = (value == true)
    elseif settingId == "AmbientAI_AllowGrouped" then
        ConfigValues.AllowGrouped = (value == true)
    elseif settingId == "AmbientAI_GroupedIdleDelay" then
        ConfigValues.GroupedIdleDelay = math.max(3, tonumber(value) or 6)
    elseif settingId == "AmbientAI_AnchorRadius" then
        ConfigValues.IdleAnchorRadius = math.max(0.0, math.min(8.0, tonumber(value) or 3.5))
    elseif settingId == "AmbientAI_SearchRadius" then
        ConfigValues.SearchRadius = math.max(3.0, tonumber(value) or 12.0)
    elseif settingId == "AmbientAI_FlavorCooldown" then
        ConfigValues.FlavorCooldown = math.max(1000, tonumber(value) or 20000)
    elseif settingId == "AmbientAI_AnimFreq" then
        ConfigValues.AnimFrequency = math.max(0.0, math.min(1.0, tonumber(value) or 0.30))
    elseif settingId == "AmbientAI_Personalities" then
        ConfigValues.Personalities = (value == true)
    elseif settingId == "AmbientAI_BardSync" then
        ConfigValues.BardSync = (value == true)
    elseif settingId == "AmbientAI_ContextAware" then
        ConfigValues.ContextAware = (value == true)
    elseif settingId == "AmbientAI_PostCombatBreather" then
        ConfigValues.PostCombatBreather = (value == true)
    elseif settingId == "AmbientAI_SocialPets" then
        ConfigValues.SocialPets = (value == true)
    elseif settingId == "AmbientAI_ReactiveVoices" then
        ConfigValues.ReactiveVoices = (value == true)
    elseif settingId == "AmbientAI_VoiceShare" then
        ConfigValues.VoiceShare = math.max(0, math.min(100, math.floor((tonumber(value) or 80) + 0.5)))
    elseif settingId == "AmbientAI_ActionVoices" then
        ConfigValues.ActionVoices = (value == true)
    elseif settingId == "AmbientAI_ActionVoiceCooldown" then
        ConfigValues.ActionVoiceCooldown = math.max(5, math.min(180, math.floor((tonumber(value) or 24) + 0.5)))
    elseif settingId == "AmbientAI_SmartScavenger" then
        ConfigValues.SmartScavenger = (value == true)
    elseif settingId == "AmbientAI_AutoSellTrader" then
        ConfigValues.AutoSellTrader = (value == true)
    elseif settingId == "AmbientAI_MinSellValue" then
        ConfigValues.MinSellValue = math.max(1, math.min(200, math.floor((tonumber(value) or 10) + 0.5)))
    elseif settingId == "AmbientAI_TrapReflex" then
        ConfigValues.TrapReflex = (value == true)
    elseif settingId == "AmbientAI_AutoWash" then
        ConfigValues.AutoWash = (value == true)
    elseif settingId == "AmbientAI_FieldTorch" then
        ConfigValues.FieldTorch = (value == true)
        if not ConfigValues.FieldTorch and FieldTorchSystem and FieldTorchSystem.restoreAll then
            FieldTorchSystem.restoreAll("mcm_disabled", false)
        end
    elseif settingId == "AmbientAI_LightSources" then
        ConfigValues.LightSources = (value == true)
    elseif settingId == "AmbientAI_LootMode" then
        ConfigValues.LootMode = ParseLootMode(value)
    elseif settingId == "AmbientAI_AttackWalls" then
        ConfigValues.AttackWalls = (value == true)
    elseif settingId == "AmbientAI_BedRegen" then
        ConfigValues.BedRegen = (value == true)
    elseif settingId == "AmbientAI_ReadingXP" then
        ConfigValues.ReadingXP = (value == true)
    end
end

local ALL_SETTING_IDS = {
    "AmbientAI_Debug",
    "AmbientAI_AllowGrouped",
    "AmbientAI_GroupedIdleDelay",
    "AmbientAI_AnchorRadius",
    "AmbientAI_SearchRadius",
    "AmbientAI_FlavorCooldown",
    "AmbientAI_AnimFreq",
    "AmbientAI_Personalities",
    "AmbientAI_BardSync",
    "AmbientAI_ContextAware",
    "AmbientAI_PostCombatBreather",
    "AmbientAI_SocialPets",
    "AmbientAI_ReactiveVoices",
    "AmbientAI_VoiceShare",
    "AmbientAI_ActionVoices",
    "AmbientAI_ActionVoiceCooldown",
    "AmbientAI_SmartScavenger",
    "AmbientAI_AutoSellTrader",
    "AmbientAI_MinSellValue",
    "AmbientAI_TrapReflex",
    "AmbientAI_AutoWash",
    "AmbientAI_FieldTorch",
    "AmbientAI_LightSources",
    "AmbientAI_LootMode",
    "AmbientAI_AttackWalls",
    "AmbientAI_BedRegen",
    "AmbientAI_ReadingXP",
}

local function SyncAllMCMSettings(force)
    local now = Ext.Utils.MonotonicTime()
    if not force and (now - LastConfigSync < 5000) then return end
    LastConfigSync = now
    for _, id in ipairs(ALL_SETTING_IDS) do
        local v = RawMCMGet(id)
        if v ~= nil then ApplySingleSetting(id, v) end
    end
end

local Config = setmetatable({}, {
    __index = function(_, key)
        SyncAllMCMSettings(false)
        return ConfigValues[key]
    end
})

local function Log(msg)
    if ConfigValues.Debug then
        Ext.Utils.Print("[AmbientAI] " .. tostring(msg))
    end
end

if Ext.Events and Ext.Events.SessionLoaded then
    Ext.Events.SessionLoaded:Subscribe(function()
        SyncAllMCMSettings(true)
        pcall(function()
            if Ext.ModEvents and Ext.ModEvents.BG3MCM then
                if Ext.ModEvents.BG3MCM["MCM_Setting_Saved"] then
                    Ext.ModEvents.BG3MCM["MCM_Setting_Saved"]:Subscribe(function(payload)
                        if payload and payload.modUUID == MyModUUID and payload.settingId then
                            ApplySingleSetting(payload.settingId, payload.value)
                            Log("MCM updated " .. tostring(payload.settingId) .. " = " .. tostring(payload.value))
                        end
                    end)
                end
                if Ext.ModEvents.BG3MCM["MCM_Setting_Reset"] then
                    Ext.ModEvents.BG3MCM["MCM_Setting_Reset"]:Subscribe(function(payload)
                        if payload and payload.modUUID == MyModUUID and payload.settingId then
                            ApplySingleSetting(payload.settingId, payload.defaultValue)
                        end
                    end)
                end
                if Ext.ModEvents.BG3MCM["MCM_Profile_Activated"] then
                    Ext.ModEvents.BG3MCM["MCM_Profile_Activated"]:Subscribe(function()
                        SyncAllMCMSettings(true)
                    end)
                end
            end
        end)
    end)
end

-- ============================================================================
-- 2. GLOBAL RUNTIME STATE & OSIRIS LIFECYCLE GUARD
-- ============================================================================

local ActiveDialogs = {}          -- map[instanceId] = true
local ForceTurnBasedObjects = {}  -- map[uuid] = true
local ActivePerformers = {}       -- map[performerUuid] = statusCount / true
local ActiveQueues = {}           -- map[charUuid] = ActionQueue
local ReservedTargets = {}        -- map[targetUuid] = charUuid
local Blacklist = {}              -- map[targetUuid] = expiryTimestampMs
local CurrentReader = nil         -- charUuid currently performing exclusive book read
local InitializedForHost = nil    -- last host UUID checked for passive
local SuppressPopupUntil = 0
local NextSocialTime = 0          -- global cooldown between companion-to-companion chats
local IsServerRunning = false     -- true ONLY when server GameState == "Running"

-- Reactive Companion Voices state
local RedirectGuard = {}          -- map[dialogResource] = expiryTimestampMs (re-entrancy guard)
local VoiceBusyUntil = {}         -- map[cleanUuid] = expiryTimestampMs while speaking bark
local GlobalReactiveBarkUntil = 0 -- party-wide expiryTimestampMs while any _PAD_/_VB_ bark is playing
local LastVoiceSpeaker = nil      -- cleanUuid of most recent companion who spoke a bark
local VoiceRedirectCount = 0      -- session diagnostic counter: successful companion redirects
local VoiceFallbackCount = 0      -- session diagnostic counter: restored to Avatar when no branch

-- Build 03.6: Real Spoken Overhead Lines, World Party Banter & 3D Vocal state
local NextGlobalActionVoiceTime = 0
local GlobalActionVoiceBusyUntil = 0
local CompanionActionVoiceCooldown = {}   -- map[cleanUuid] = expiryTimestampMs
local LastActionVoiceSpeaker = nil        -- cleanUuid of most recent action-voice speaker
local ActionVoiceStats = {
    played               = 0,
    important            = 0,
    replies              = 0,
    gossips              = 0,
    spokenPads           = 0,
    vocals3d             = 0,
    originDelegations    = 0,
    breathers            = 0,
    ownDialogWindowUntil = 0,
    lastVoiceAt          = 0,
    padFail              = 0,
    vocalOnly            = 0,
    nextWorldGossipTime  = 0,
    nextImportantTime    = 0,
    spokenPadCooldown    = {},
}
local VocalResourceCache = {
    complete  = false,
    handles   = nil,
    cursor    = 1,
    total     = 0,
    matched   = 0,
    byEvent   = {}, -- map[soundEventName] = ResourceSoundResource Guid
}

-- Build 03: Smart Explorer runtime state
local KnownDiscoveredTraps = {}   -- map[cleanTrapUuid] = true (one-shot brake memory per trap)
local AlertedObjects = {}         -- map[cleanUuid] = true (prevents repeat callout spam)
local NextAlertTime = 0           -- global anti-spam cooldown between discovery callouts
local LastTrapBrakeTime = 0       -- debounce timestamp for emergency party brake
local PendingAutoWashTime = 0     -- scheduled post-combat soap cleanse timestamp (0 = none)
local LastAutoWashTime = 0        -- periodic peaceful/camp cleanse timestamp
local LastTradeSellKey = nil      -- prevents double-trigger on same RequestTrade/TradeGenerationEnded pair
local LastTradeSellTime = 0
local ScavengeStats = {
    essentials            = 0,
    supplies              = 0,
    campValuables         = 0,
    alerts                = 0,
    soldItems             = 0,
    soldGold              = 0,
    trapStops             = 0,
    washes                = 0,
    lightsLit             = 0,
    litSet                = {},
    pendingBreatherTime   = 0,
    lastBreatherTime      = -999999,
    lastShortRestHintTime = -999999,
}

-- Build 04.3: Smart Field Torchbearer single-table module (preserves top-level local budget!)
local FieldTorchSystem = {
    internalEquipGuard  = false,
    lastEnvCheckAt      = -999999,
    lastEnemyCheckAt    = -999999,
    cachedEnemyNear     = false,
    darkSince           = 0,
    brightSince         = 0,
    cooldownUntil       = 0,
    swaps               = 0,
    lastStatusReason    = "init",
    lastHostObs         = "unknown",
    lastLitLights       = 0,
}

-- Build 03.1: Natural Asynchronous Human Pacing state
local CompanionWakeOffsets = {}   -- map[cleanUuid] = staggered wake-up offset (ms) after Host stops
local WakeOffsetsStopStamp = -1   -- HostLastActiveTime stamp for which offsets were rolled
local CompanionRestUntil = {}     -- map[cleanUuid] = post-action breather timestamp (ms)
local ScavengeStreak = {}         -- map[cleanUuid] = consecutive scavenge count before roleplay break

-- Build 03.2: Sub-ms Chunked Spatial Indexer + Stuck Companion Recovery state
local NeedsInitialPartyUnstick = true
local HostWasIdleAllowed = false
local CompanionLagSince = {}      -- map[cleanUuid] = timestamp when grouped companion lagged stationary behind moving host
local CompanionUnstickCooldown = {} -- map[cleanUuid] = cooldown to avoid spamming PurgeOsirisQueue
local LocalSpatialIndex = {
    ready         = false,
    sweeping      = false,
    phase         = "items",
    handles       = nil,
    cursor        = 1,
    total         = 0,
    hx            = 0,
    hy            = 0,
    hz            = 0,
    sweepItems    = {},
    sweepTraps    = {},
    sweepChars    = {},
    items         = {},
    traps         = {},
    chars         = {},
    corpses       = {},
    pets          = {},
    enemyNearby   = false,
    enemyCoords   = {},
    lastCompleted = -999999,
    lastPetScan   = -999999,
}

local HostLastPos = { x = nil, y = nil, z = nil }
local HostLastActiveTime = Ext.Utils.MonotonicTime()

local function RefreshRunningState()
    if Ext and Ext.Utils and Ext.Utils.GetGameState then
        local ok, st = pcall(Ext.Utils.GetGameState)
        if ok and st ~= nil then
            IsServerRunning = (tostring(st) == "Running")
            return IsServerRunning
        end
    end
    return IsServerRunning
end

local function IsOsirisReady()
    if not IsServerRunning and not RefreshRunningState() then
        return false
    end
    if Ext and Ext.Osiris and Ext.Osiris.IsCallable then
        local ok, callable = pcall(Ext.Osiris.IsCallable)
        if ok and not callable then
            return false
        end
    end
    return Osi ~= nil
end

local WorldScanCache = {
    timestamp = 0,
    hx = 0,
    hy = 0,
    hz = 0,
    radius = 0,
    targets = nil,
    zone = nil,
}

-- ============================================================================
-- 3. SAFE OSIRIS / ECS HELPERS & PROTECTION CHECKS
-- ============================================================================

local function CleanUuid(guid)
    if type(guid) ~= "string" then return guid end
    return guid:match("(%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x)$") or guid
end

local function SameEntity(a, b)
    if not a or not b then return false end
    if a == b then return true end
    return CleanUuid(a) == CleanUuid(b)
end

local function GetLocalizedText(handle, fallback)
    if Ext and Ext.Loca and Ext.Loca.GetTranslatedString then
        local ok, txt = pcall(Ext.Loca.GetTranslatedString, handle, fallback)
        if ok and type(txt) == "string" and txt ~= "" and txt ~= handle then
            return txt
        end
    end
    return fallback
end

local function SafeSay(char, text)
    pcall(function()
        if Osi.ShowOverheadText then
            Osi.ShowOverheadText(char, text)
        elseif Osi.CharacterStatusText then
            Osi.CharacterStatusText(char, text)
        end
    end)
end

local function SafeGiveXP(char, amount)
    if Config.ReadingXP then
        pcall(function()
            if Osi.AddExplorationExperience then
                Osi.AddExplorationExperience(char, amount)
            elseif Osi.AddExperience then
                Osi.AddExperience(char, amount)
            end
        end)
    end
end

local function PurgeCharacterOsiris(char)
    if not char then return end
    pcall(function()
        if Osi.PurgeOsirisQueue then
            Osi.PurgeOsirisQueue(char, 1)
        elseif Osi.FlushOsirisQueue then
            Osi.FlushOsirisQueue(char)
        end
    end)
end

local function StopCustomAnimation(char, graceful)
    if not char then return end
    pcall(function()
        if Osi.StopAnimation then
            -- abort = 0 plays _End clip & cross-fades smoothly; abort = 1 is hard cut for combat/traps only!
            Osi.StopAnimation(char, graceful and 0 or 1)
        end
    end)
end

local function StopInteraction(char, hardCut)
    StopCustomAnimation(char, not hardCut)
    if hardCut then
        PurgeCharacterOsiris(char)
    end
end

local function SetSeatFollowFlagRaw(char, locked)
    if not char then return end
    PersistentVars = PersistentVars or {}
    if type(PersistentVars.SeatFollowLocked) ~= "table" then
        PersistentVars.SeatFollowLocked = {}
    end
    local key = CleanUuid(char) or char
    if locked then
        if PersistentVars.SeatFollowLocked[key] ~= true then
            PersistentVars.SeatFollowLocked[key] = true
            if Osi.SetNoFollowFlag then
                pcall(Osi.SetNoFollowFlag, char, 1)
            end
        end
    else
        local hadLock = (PersistentVars.SeatFollowLocked[key] == true)
        PersistentVars.SeatFollowLocked[key] = nil
        if hadLock and Osi.SetNoFollowFlag then
            pcall(Osi.SetNoFollowFlag, char, 0)
        end
    end
end

-- ============================================================================
-- 3B. SEAT DISMOUNT GATE (Build 04.3.5)
--
-- BG3's repose (Osi.SitOnEntity / Osi.LieOnEntity) welds the character to a socket of
-- the furniture. A party member that is *following* while still welded gets resolved by
-- the engine with a catch-up teleport to the leader - exactly the "companions teleport
-- instead of standing up" bug. Therefore the follow block must stay ON until the engine
-- confirms the repose ended (ReposeRemoved event, with a polling fallback).
-- ============================================================================
AmbientSeat = {
    pendingRelease = {},   -- cleanUuid -> reason
    inFlight = {},         -- cleanUuid -> true while a stand-up cascade is running
    hardBlacklist = {},    -- map[targetUuid] = true: NOT cleared by an unrelated queue abort
    releaseLog = {},
    pollMs = 150,
    maxPolls = 24,
}

function AmbientSeat.isSeated(char)
    if not char then return false end
    local ok, seated = pcall(function()
        if Osi.IsReposed and Osi.IsReposed(char) == 1 then return true end
        if Osi.IsReposedSitting and Osi.IsReposedSitting(char) == 1 then return true end
        if Osi.IsReposedLying and Osi.IsReposedLying(char) == 1 then return true end
        return false
    end)
    return ok and seated == true
end

function AmbientSeat.seatName(char)
    local ok, name = pcall(function()
        local e = Ext.Entity.Get(char)
        local sc = e and e.ServerCharacter or nil
        return tostring(sc and sc.Template and sc.Template.Name or char)
    end)
    return ok and name or tostring(char)
end

-- Final, unconditional release (engine already confirmed the character is standing)
function AmbientSeat.releaseNow(char, reason)
    SetSeatFollowFlagRaw(char, false)
    local key = CleanUuid(char) or char
    AmbientSeat.pendingRelease[key] = nil
    AmbientSeat.inFlight[key] = nil
    Log(string.format("[SEAT] %s follow released (%s)", AmbientSeat.seatName(char), tostring(reason or "standing")))
end

-- Called by the ReposeRemoved Osiris event: this is the authoritative "character stood up"
function AmbientSeat.onReposeRemoved(char)
    if not char then return end
    local key = CleanUuid(char) or char
    if AmbientSeat.pendingRelease[key] then
        AmbientSeat.releaseNow(char, "repose_removed")
    end
end

-- Keep the follow block, end the repose, release only when the character is out of the pose
function AmbientSeat.standUp(char, reason, attempt)
    if not char then return end
    attempt = attempt or 0
    local key = CleanUuid(char) or char

    -- abort() calls the action's onAbort AND the seat branch; only run the cascade once
    if attempt == 0 and AmbientSeat.inFlight[key] then return end
    if attempt == 0 then AmbientSeat.inFlight[key] = true end

    if not AmbientSeat.isSeated(char) then
        if attempt == 0 then
            AmbientSeat.releaseNow(char, reason or "not_seated")
        else
            AmbientSeat.releaseNow(char, "stood_up")
        end
        return
    end

    -- Still seated: make sure the follow block is ON so the engine cannot teleport them
    SetSeatFollowFlagRaw(char, true)
    AmbientSeat.pendingRelease[key] = reason or "stand_up"

    local shouldAsk = (attempt == 0) or (attempt % 6 == 0)
    if shouldAsk then
        if attempt == 0 then
            Log(string.format("[SEAT] %s is reposed -> EndRepose, holding follow block until it stands",
                AmbientSeat.seatName(char)))
        end
        if Osi.EndRepose then pcall(Osi.EndRepose, char) end
    end

    -- Fallback: if a pending sit task keeps re-seating the character, drop it once
    if attempt == 8 and PurgeCharacterOsiris then
        pcall(PurgeCharacterOsiris, char)
    end

    if attempt >= AmbientSeat.maxPolls then
        Log(string.format("[SEAT] %s never reported ReposeRemoved - releasing follow anyway", AmbientSeat.seatName(char)))
        AmbientSeat.releaseNow(char, "timeout")
        return
    end

    Ext.Timer.WaitFor(AmbientSeat.pollMs, function()
        if not IsOsirisReady() then return end
        if AmbientSeat.pendingRelease[key] == nil then return end   -- already released by the event
        AmbientSeat.standUp(char, reason, attempt + 1)
    end)
end

-- ---------------------------------------------------------------------------
-- Build 04.3.6: seat picking / sitting with verification
-- ---------------------------------------------------------------------------
AmbientSeat.SIT_MAX_H = 2.2      -- m: never call SitOnEntity from further away (it snaps!)
AmbientSeat.SIT_MAX_V = 1.4
AmbientSeat.SEAT_HOST_RADIUS = 6.0  -- m: only sit on seats near the player's anchor
AmbientSeat.lastSit = {}         -- cleanUuid -> { result, tpl, dist, at }

-- A character that is in a dialog / overhead PAD can NOT enter Repose. The engine does not
-- answer with an error, it silently does nothing - which looked exactly like "the bench is
-- broken". Check it explicitly before asking for a pose.
function AmbientSeat.isTalking(char)
    if not char then return false end
    local busy = false
    pcall(function()
        if Osi.SpeakerGetDialog then
            local d = Osi.SpeakerGetDialog(char, 1)
            if type(d) == "string" and d ~= ""
                and not string.find(d, "00000000-0000-0000-0000-000000000000", 1, true) then
                busy = true
            end
        end
        if (not busy) and Osi.IsInDialog and Osi.IsInDialog(char, 0) == 1 then
            busy = true
        end
    end)
    return busy
end

function AmbientSeat.tplName(uuid)
    local ok, tpl = pcall(function()
        local e = Ext.Entity.Get(uuid)
        local si = e and e.ServerItem or nil
        return tostring(si and si.Template and si.Template.Name or "?")
    end)
    return ok and tpl or "?"
end

-- nil = engine has no opinion, true/false = engine answer
function AmbientSeat.canSitOn(chairUuid)
    local answer = nil
    pcall(function()
        if Osi.CanSitOn then
            local r = Osi.CanSitOn(chairUuid)
            if r ~= nil then answer = (r == 1) end
        end
        if answer == nil and Osi.TemplateCanSitOn then
            local r2 = Osi.TemplateCanSitOn(chairUuid)
            if r2 ~= nil then answer = (r2 == 1) end
        end
    end)
    return answer
end

function AmbientSeat.metrics(char, target)
    local cx, cy, cz = Osi.GetPosition(char)
    local tx, ty, tz = Osi.GetPosition(target)
    if not cx or not tx then return nil, nil end
    local dx, dz = cx - tx, cz - tz
    return math.sqrt(dx * dx + dz * dz), math.abs((cy or 0) - (ty or 0))
end

-- The only place that may start a repose. Returns true if the sit was started.
function AmbientSeat.sit(char, chairUuid)
    if not char or not chairUuid then return false end
    local key = CleanUuid(char) or char
    local tpl = AmbientSeat.tplName(chairUuid)
    local now = Ext.Utils.MonotonicTime()

    local sittable = AmbientSeat.canSitOn(chairUuid)
    if sittable == false then
        AmbientSeat.lastSit[key] = { result = "not_sittable", tpl = tpl, at = now }
        Blacklist[chairUuid] = now + 300000
        Log(string.format("[SEAT] %s refused %s: engine says this prop has no sit socket", tostring(char), tpl))
        return false
    end

    local h, v = AmbientSeat.metrics(char, chairUuid)
    local moving = (Osi.IsMoving and Osi.IsMoving(char) == 1) or false
    if (not h) or h > AmbientSeat.SIT_MAX_H or v > AmbientSeat.SIT_MAX_V or moving then
        AmbientSeat.lastSit[key] = {
            result = "too_far", tpl = tpl, dist = h, at = now,
        }
        Blacklist[chairUuid] = now + 60000
        Log(string.format("[SEAT] %s NOT sitting on %s: dist=%s dy=%s moving=%s (repose would snap him there)",
            tostring(char), tpl,
            h and string.format("%.2f", h) or "?", v and string.format("%.2f", v) or "?", tostring(moving)))
        return false
    end

    -- 04.3.8: do not ask for a pose while the character is still finishing a bark/PAD or a step
    AmbientSeat.beginSit(char, chairUuid, tpl, h, 0)
    return true
end

-- Waits (bounded) until the character is free, then starts the repose and verifies it.
function AmbientSeat.beginSit(char, chairUuid, tpl, h, attempt)
    if not char then return end
    local key = CleanUuid(char) or char
    attempt = attempt or 0

    if attempt > 14 then
        AmbientSeat.lastSit[key] = { result = "busy_too_long", tpl = tpl, dist = h, at = Ext.Utils.MonotonicTime() }
        Log(string.format("[SEAT] %s is still busy (dialog/animation) -> dropping %s for now", tostring(char), tpl))
        Blacklist[chairUuid] = Ext.Utils.MonotonicTime() + 60000
        AmbientSeat.hardBlacklist[chairUuid] = nil
        SetSeatFollowFlagRaw(char, false)
        return
    end

    if AmbientSeat.isTalking(char) then
        AmbientSeat.lastSit[key] = { result = "waiting_dialog_end", tpl = tpl, dist = h, at = Ext.Utils.MonotonicTime() }
        Ext.Timer.WaitFor(350, function()
            if not IsOsirisReady() then return end
            AmbientSeat.beginSit(char, chairUuid, tpl, h, attempt + 1)
        end)
        return
    end

    -- 04.3.9: Osi.IsMoving does not see AI-driven CharacterMoveToPosition walks on every
    -- engine build (the playtest log shows moving=false while the companion is walking).
    -- Give it a short, bounded benefit of the doubt instead of a hard gate.
    if attempt < 4 and Osi.IsMoving and Osi.IsMoving(char) == 1 then
        Ext.Timer.WaitFor(250, function()
            if not IsOsirisReady() then return end
            AmbientSeat.beginSit(char, chairUuid, tpl, h, attempt + 1)
        end)
        return
    end

    -- Re-check the distance: the wait above may have let the character drift
    local h2, v2 = AmbientSeat.metrics(char, chairUuid)
    if (not h2) or h2 > AmbientSeat.SIT_MAX_H or v2 > AmbientSeat.SIT_MAX_V then
        AmbientSeat.lastSit[key] = { result = "drifted_away", tpl = tpl, dist = h2, at = Ext.Utils.MonotonicTime() }
        Log(string.format("[SEAT] %s drifted to %.2fm while waiting -> not sitting on %s",
            tostring(char), h2 or -1, tpl))
        SetSeatFollowFlagRaw(char, false)
        return
    end

    SetSeatFollowFlagRaw(char, true)
    if Osi.SitOnEntity then
        pcall(Osi.SitOnEntity, char, chairUuid)
    elseif Osi.Use then
        pcall(Osi.Use, char, chairUuid, "")
    end
    AmbientSeat.lastSit[key] = { result = "started", tpl = tpl, dist = h2, at = Ext.Utils.MonotonicTime() }
    Log(string.format("[SEAT] %s sits on %s (dist=%.2f, waited=%d)", tostring(char), tpl, h2, attempt))
    AmbientSeat.verifySit(char, chairUuid, tpl, h2)
end

-- The repose transition is not instant. Look several times instead of once: a single 1.2 s
-- look used to declare failure (and stand the companion back up) while the clip was still
-- blending on a slower frame.
function AmbientSeat.verifySit(char, chairUuid, tpl, h)
    local key = CleanUuid(char) or char
    local delays = { 500, 1200, 2200, 3200 }
    local finished = false

    for _, delay in ipairs(delays) do
        local isLast = (delay == delays[#delays])
        Ext.Timer.WaitFor(delay, function()
            if finished or not IsOsirisReady() then return end
            if Osi.Exists(char) ~= 1 then return end
            if AmbientSeat.isSeated(char) then
                finished = true
                AmbientSeat.lastSit[key] = { result = "seated", tpl = tpl, dist = h, at = Ext.Utils.MonotonicTime() }
                if AmbientSeat.hardBlacklist then AmbientSeat.hardBlacklist[chairUuid] = nil end
                return
            end
            if not isLast then return end
            finished = true

            local last = AmbientSeat.lastSit[key]
            if last and last.result == "seated" then return end

            -- Explain the failure instead of just giving up
            local why = {}
            local dh, dv = AmbientSeat.metrics(char, chairUuid)
            why[#why + 1] = string.format("dist=%s dy=%s", dh and string.format("%.2f", dh) or "?",
                dv and string.format("%.2f", dv) or "?")
            if AmbientSeat.isTalking(char) then why[#why + 1] = "talking" end
            if Osi.IsMoving and Osi.IsMoving(char) == 1 then why[#why + 1] = "moving" end
            local canSit = AmbientSeat.canSitOn(chairUuid)
            why[#why + 1] = "engineCanSitOn=" .. tostring(canSit)
            if Osi.HasLineOfSight then
                local okLos, los = pcall(Osi.HasLineOfSight, char, chairUuid)
                why[#why + 1] = "los=" .. tostring(okLos and los or "?")
            end

            AmbientSeat.lastSit[key] = {
                result = "no_repose", tpl = tpl, dist = dh, at = Ext.Utils.MonotonicTime(),
                why = table.concat(why, " "),
            }
            Blacklist[chairUuid] = Ext.Utils.MonotonicTime() + 300000
            AmbientSeat.hardBlacklist[chairUuid] = nil
            Log(string.format("[SEAT] %s did NOT enter repose on %s after 3.2s [%s] -> standing back up, seat avoided",
                tostring(char), tpl, table.concat(why, " ")))

            -- Never leave a companion half-sat with the follow block on (invisible / unresponsive).
            pcall(function() if Osi.EndRepose then Osi.EndRepose(char) end end)
            SetSeatFollowFlagRaw(char, false)
            AmbientSeat.pendingRelease[key] = nil
            AmbientSeat.inFlight[key] = nil
            local q = ActiveQueues[char]
            if q then q.queue = {} end
        end)
    end
end

-- Public gate: every "unlock" request in the mod goes through here
function SetAmbientSeatFollowLock(char, locked)
    if not char then return end
    if locked then
        SetSeatFollowFlagRaw(char, true)
    else
        if AmbientSeat.isSeated(char) then
            AmbientSeat.standUp(char, "unlock_request")
        else
            SetSeatFollowFlagRaw(char, false)
        end
    end
end

local function StandUpFromFurniture(char)
    if not char then return end
    -- Build 04.3.5: the follow block is released by AmbientSeat ONLY after ReposeRemoved,
    -- otherwise BG3 snap-teleports a still-seated follower to the party leader.
    pcall(function()
        if Osi.IsInCombat and Osi.IsInCombat(char) == 1 then
            -- In combat we cannot wait: hard release, the engine needs them mobile now
            SetSeatFollowFlagRaw(char, false)
            return
        end
        if AmbientSeat.isSeated(char) then
            AmbientSeat.standUp(char, "sequence")
        else
            AmbientSeat.releaseNow(char, "already_standing")
        end
    end)
end

local function FaceTarget(char, targetUuid)
    if not char or not targetUuid then return end
    pcall(function()
        if Osi.SteerTo then
            -- snapToTarget = 0 -> smooth step-turn instead of 1-frame rotation snap!
            Osi.SteerTo(char, targetUuid, 0)
        elseif Osi.LookAtEntity then
            Osi.LookAtEntity(char, targetUuid, 3.0)
        end
    end)
end

local function IsCharacterInDialog(char)
    if not char then return false end
    if Osi.IsInDialog then
        -- Second arg 0 = interactive cinematic dialogs ONLY (excludes overhead AutomatedDialogs / PADs / Gossip!)
        local ok, res = pcall(Osi.IsInDialog, char, 0)
        if ok then
            return res == 1
        end
    end
    local dbOk, dbRes = pcall(function()
        if Osi.DB_DialogPlayers then
            local rows = Osi.DB_DialogPlayers:Get(nil, char, nil)
            if rows then
                for _, row in ipairs(rows) do
                    local inst = row[1]
                    local isAuto = false
                    if inst and Osi.DB_AutomatedDialog then
                        local aRows = Osi.DB_AutomatedDialog:Get(inst)
                        isAuto = (aRows and #aRows > 0) or false
                    end
                    if not isAuto then return true end
                end
            end
        end
        return false
    end)
    return dbOk and dbRes or false
end

local function IsAnyDialogActive()
    -- 04.3.7: the instance id used to be validated with a single pcall. If the engine
    -- stopped resolving it (force-stopped dialog, save/load, mod-forced stop) the call
    -- failed and this function kept answering "a dialog is active" forever - which
    -- silently muted every companion bark for the rest of the session.
    local nowMs = Ext.Utils.MonotonicTime()
    for inst, stamp in pairs(ActiveDialogs) do
        if Osi.DialogGetNumberOfInvolvedPlayers then
            local ok, count = pcall(Osi.DialogGetNumberOfInvolvedPlayers, inst)
            local age = (type(stamp) == "number") and (nowMs - stamp) or 0
            if (not ok) or type(count) ~= "number" then
                if age > 20000 then
                    ActiveDialogs[inst] = nil   -- unresolvable instance, give it a grace window first
                else
                    return true
                end
            elseif count <= 0 then
                ActiveDialogs[inst] = nil
            else
                return true
            end
        else
            return true
        end
    end
    local host = Osi.GetHostCharacter and Osi.GetHostCharacter() or nil
    if host and IsCharacterInDialog(host) then return true end
    return false
end

local function IsInTurnBased(char)
    if not char then return false end
    local clean = CleanUuid(char)
    if ForceTurnBasedObjects[char] or ForceTurnBasedObjects[clean] then
        return true
    end
    local ok, res = pcall(function()
        if Osi.IsInForceTurnBasedMode and Osi.IsInForceTurnBasedMode(char) == 1 then
            return true
        end
        local e = Ext.Entity.Get(char)
        if not e then return false end
        -- IMPORTANT: Do NOT check e.FTBParticipant ~= nil! Every party member permanently
        -- carries FTBParticipant in real-time mode; only IsInFTB / IsInTurnBasedMode marks active FTB!
        if e.IsInFTB ~= nil or e.IsInTurnBasedMode ~= nil then return true end
        return false
    end)
    return ok and res or false
end

local function IsSneakingOrInvisible(char)
    if not char then return false end
    local ok, res = pcall(function()
        if Osi.HasActiveStatus(char, "SNEAKING") == 1 then return true end
        if Osi.HasActiveStatus(char, "INVISIBILITY") == 1 then return true end
        if Osi.HasActiveStatus(char, "GREATER_INVISIBILITY") == 1 then return true end
        if Osi.HasActiveStatus(char, "SHROUD_SELF") == 1 then return true end
        return false
    end)
    return ok and res or false
end

local function IsPolymorphedOrIncapacitated(char)
    if not char then return true end
    local ok, res = pcall(function()
        if Osi.IsDead(char) == 1 then return true end
        if Osi.HasActiveStatus(char, "DOWNED") == 1 then return true end
        if Osi.HasAppliedStatusOfType then
            if Osi.HasAppliedStatusOfType(char, "POLYMORPHED") == 1 then return true end
            if Osi.HasAppliedStatusOfType(char, "INCAPACITATED") == 1 then return true end
            if Osi.HasAppliedStatusOfType(char, "KNOCKED_DOWN") == 1 then return true end
        end
        local e = Ext.Entity.Get(char)
        if e and e.ShapeshiftReplicatedChanges and e.ShapeshiftReplicatedChanges.HasWildShapeHotBar then
            return true
        end
        return false
    end)
    return ok and res or false
end

local function IsCharacterSpeakingBark(char, ignoreTimer)
    if not char then return false end
    if not ignoreTimer then
        local clean = CleanUuid(char)
        if clean and (VoiceBusyUntil[clean] or 0) > Ext.Utils.MonotonicTime() then
            return true
        end
    end
    if Osi.SpeakerGetDialog then
        local ok, dlg = pcall(Osi.SpeakerGetDialog, char, 1)
        if ok and type(dlg) == "string" and dlg ~= "" and not string.find(dlg, "00000000-0000-0000-0000-000000000000", 1, true) then
            return true
        end
    end
    return false
end

local function IsInCamp(char)
    if not char then return false end
    local ok, res = pcall(function()
        if Osi.DB_InCamp then
            local rows = Osi.DB_InCamp:Get(char)
            if rows and #rows > 0 then return true end
            local all = Osi.DB_InCamp:Get(nil)
            if all then
                for _, r in pairs(all) do
                    if r[1] and SameEntity(r[1], char) then return true end
                end
            end
        end
        return false
    end)
    return ok and res or false
end

local function IsRealPartyCompanion(char)
    if not char then return false end
    local ok, res = pcall(function()
        if Osi.IsSummon and Osi.IsSummon(char) == 1 then return false end
        if Osi.IsPartyFollower and Osi.IsPartyFollower(char) == 1 then return false end
        if Osi.IsPartyMember then
            return Osi.IsPartyMember(char, 0) == 1
        end
        return true
    end)
    return ok and res or false
end

local function GetPartyCompanions()
    local list = {}
    local seen = {}
    local function tryAdd(guid)
        if not guid then return end
        local key = CleanUuid(guid) or guid
        if not seen[key] and IsRealPartyCompanion(guid) then
            seen[key] = true
            table.insert(list, guid)
        end
    end

    -- 1. Primary source: DB_PartyMembers holds ALL active party companions + avatars!
    --    (DB_Players only holds human-created avatars, which caused #list == 1 in b02.1!)
    pcall(function()
        if Osi.DB_PartyMembers then
            local members = Osi.DB_PartyMembers:Get(nil)
            if members then
                for _, row in pairs(members) do tryAdd(row[1]) end
            end
        end
    end)

    -- 2. Also merge DB_Players (co-op / multi-avatar safety)
    pcall(function()
        if Osi.DB_Players then
            local players = Osi.DB_Players:Get(nil)
            if players then
                for _, row in pairs(players) do tryAdd(row[1]) end
            end
        end
    end)

    -- 3. ECS PartyMember component fallback if Osiris DBs ever differ
    if #list <= 1 then
        pcall(function()
            local entities = Ext.Entity.GetAllEntitiesWithComponent("PartyMember")
            if entities then
                for _, h in pairs(entities) do
                    local e = (type(h) == "string") and Ext.Entity.Get(h) or h
                    if e and e.Uuid and e.Uuid.EntityUuid then
                        tryAdd(tostring(e.Uuid.EntityUuid))
                    end
                end
            end
        end)
    end

    return list
end

local function IsPartyOwnedOrUnowned(uuid)
    if not uuid then return false end
    local ok, safe = pcall(function()
        if Osi.GetOwner then
            local owner = Osi.GetOwner(uuid)
            if owner and owner ~= "" and owner ~= "NULL_00000000-0000-0000-0000-000000000000" then
                if IsRealPartyCompanion(owner) then return true end
                local eOwner = Ext.Entity.Get(owner)
                if eOwner and eOwner.PartyMember then return true end
                return false
            end
        end
        local e = Ext.Entity.Get(uuid)
        if e and e.OwneeCurrent and e.OwneeCurrent.Ownee then
            local ownee = e.OwneeCurrent.Ownee
            if ownee and ownee.PartyMember == nil then
                return false
            end
        end
        return true
    end)
    return ok and safe or false
end

-- Triple-Lock Camp Rest & Teleport Trigger Guard (GLO_Camp DB_Camp + DB_CampBed)
-- In BG3, calling Osi.Use on DB_Camp (_Campfire) or DB_CampBed (_DayBed / _NightBed) triggers
-- CAMP_EndTheDay, CAMP_TakeALongRest, or CAMP_LeaveCamp (teleporting the party out of Camp!).
local CampTriggerGuard = {
    uuids     = {},
    updatedAt = -999999,
}

function CampTriggerGuard.refresh(now)
    local t = now or (Ext and Ext.Utils and Ext.Utils.MonotonicTime() or 0)
    if (t - CampTriggerGuard.updatedAt) < 15000 then
        return
    end
    CampTriggerGuard.updatedAt = t
    local map = {}
    pcall(function()
        if Osi.DB_Camp and Osi.DB_Camp.Get then
            local rows = Osi.DB_Camp:Get(nil, nil, nil, nil)
            if rows then
                for _, row in ipairs(rows) do
                    local cf = CleanUuid(row[2])
                    if cf then map[cf] = true end
                end
            end
        end
        if Osi.DB_CampBed and Osi.DB_CampBed.Get then
            local rows = Osi.DB_CampBed:Get(nil, nil, nil, nil, nil, nil, nil)
            if rows then
                for _, row in ipairs(rows) do
                    local dayBed = CleanUuid(row[3])
                    local nightBed = CleanUuid(row[4])
                    if dayBed then map[dayBed] = true end
                    if nightBed then map[nightBed] = true end
                end
            end
        end
    end)
    CampTriggerGuard.uuids = map
end

function CampTriggerGuard.isProtected(uuid)
    if not uuid then return false end
    CampTriggerGuard.refresh()
    local clean = CleanUuid(uuid)
    if clean and CampTriggerGuard.uuids[clean] == true then
        return true
    end
    local ok, isProtectedName = pcall(function()
        local host = Osi.GetHostCharacter and Osi.GetHostCharacter() or nil
        if not host or not IsInCamp(host) then return false end
        local e = Ext.Entity.Get(uuid)
        local tpl = e and e.ServerItem and e.ServerItem.Template or nil
        local lower = string.lower(tostring(tpl and tpl.Name or ""))
        if lower == "" then return false end
        return string.find(lower, "bedroll", 1, true) ~= nil
            or string.find(lower, "campfire", 1, true) ~= nil
            or string.find(lower, "camp_fire", 1, true) ~= nil
            or string.find(lower, "bonfire", 1, true) ~= nil
            or string.find(lower, "waypoint", 1, true) ~= nil
            or string.find(lower, "portal", 1, true) ~= nil
    end)
    return ok and isProtectedName == true
end

local function IsSafeWorldObject(uuid, mode)
    if not uuid then return false end
    local ok, valid = pcall(function()
        if Osi.Exists and Osi.Exists(uuid) == 0 then return false end
        if Osi.IsInInventory and Osi.IsInInventory(uuid) == 1 then return false end
        if Osi.IsEquipped and Osi.IsEquipped(uuid) == 1 then return false end
        if Osi.IsTrapArmed and Osi.IsTrapArmed(uuid) == 1 then return false end

        -- Never interact via Osi.Use / light / bed / seat with GLO_Camp rest/teleport triggers!
        if (mode == "use" or mode == "bed" or mode == "light" or mode == "seat")
            and CampTriggerGuard.isProtected(uuid)
        then
            return false
        end

        if mode == "bed" then
            local host = Osi.GetHostCharacter and Osi.GetHostCharacter() or nil
            if host and IsInCamp(host) then
                return false
            end
        end

        -- Public seats (benches/stools/chairs) and interactive light fixtures (candles/sconces/braziers)
        -- are safe to sit on / ignite in public areas as long as not owner/story-locked!
        if mode == "seat" or mode == "light" then
            if Osi.IsDestroyed and Osi.IsDestroyed(uuid) == 1 then return false end
            local e = Ext.Entity.Get(uuid)
            local si = e and e.ServerItem or nil
            if mode == "light" then
                if Osi.IsStoryItem and Osi.IsStoryItem(uuid) == 1 then return false end
                if not IsPartyOwnedOrUnowned(uuid) then return false end
                if si then
                    if si.CanOnlyBeUsedByOwner == true and not IsPartyOwnedOrUnowned(uuid) then
                        return false
                    end
                    local tplName = tostring(si.Template and si.Template.Name or "")
                    local tplLower = string.lower(tplName)
                    if string.find(tplLower, "campfire", 1, true)
                        or string.find(tplLower, "bonfire", 1, true)
                        or string.find(tplLower, "firepit", 1, true)
                        or string.find(tplLower, "chandelier", 1, true)
                        or string.find(tplLower, "hanging_bowl", 1, true)
                        or string.find(tplLower, "broken", 1, true)
                        or string.find(tplLower, "destruct", 1, true)
                        or string.find(tplLower, "ruined", 1, true)
                        or string.find(tplLower, "shattered", 1, true)
                        or string.find(tplLower, "melted", 1, true)
                        or string.find(tplLower, "snuffer", 1, true)
                        or string.find(tplLower, "empty", 1, true)
                        or string.find(tplLower, "moonlantern", 1, true)
                        or string.find(tplLower, "pixie", 1, true)
                    then
                        return false
                    end
                    local isWaxCandle = string.find(tplLower, "candle", 1, true) ~= nil
                        and not string.find(tplLower, "torch", 1, true)
                        and not string.find(tplLower, "candelabr", 1, true)
                    if si.CanBePickedUp == true and not isWaxCandle then
                        return false
                    end
                    local isDedicatedFixture = string.find(tplName, "LTS_", 1, true) ~= nil
                        or string.find(tplLower, "candle", 1, true) ~= nil
                        or string.find(tplLower, "candelabr", 1, true) ~= nil
                        or string.find(tplLower, "candlestick", 1, true) ~= nil
                        or string.find(tplLower, "sconce", 1, true) ~= nil
                        or string.find(tplLower, "brazier", 1, true) ~= nil
                        or string.find(tplLower, "wall_bowl", 1, true) ~= nil
                        or string.find(tplLower, "standing_bowl", 1, true) ~= nil
                    if not isDedicatedFixture and si.CanUse ~= true then
                        return false
                    end
                end
                return true
            end
            if si then
                if si.CanUse ~= true then return false end
                if si.CanOnlyBeUsedByOwner == true and not IsPartyOwnedOrUnowned(uuid) then
                    return false
                end
            end
            return true
        end

        if not IsPartyOwnedOrUnowned(uuid) then return false end

        if mode == "container" then
            if Osi.IsLocked and Osi.IsLocked(uuid) == 1 then return false end
        elseif mode == "pickup" then
            if Osi.IsStoryItem and Osi.IsStoryItem(uuid) == 1 then return false end
            if Osi.IsMovable and Osi.IsMovable(uuid) == 0 then return false end
            if Osi.CanPickUp and Osi.CanPickUp(uuid) == 0 then return false end
        elseif mode == "wall" then
            if Osi.IsDestroyed and Osi.IsDestroyed(uuid) == 1 then return false end
            local hp = Osi.GetHitpoints and Osi.GetHitpoints(uuid) or nil
            if hp ~= nil and hp <= 0 then return false end
        end
        return true
    end)
    return ok and valid or false
end

local function GetSmartApproachPositionUncached(sourceUuid, targetUuid, distance)
    local x1, y1, z1 = Osi.GetPosition(sourceUuid)
    local x2, y2, z2 = Osi.GetPosition(targetUuid)
    if not x1 or not x2 then return nil end

    local dx = x1 - x2
    local dz = z1 - z2
    local len = math.sqrt(dx * dx + dz * dz)
    local dy = math.abs((y2 or y1) - y1)
    -- Stepped floors / platforms (<= 1.65m): prefer target elevation y2 first so points on stairs/dais
    -- never project underground inside stone! High wall props (> 1.65m sconces/paintings): project to floor y1!
    local primaryY = (dy <= 1.65) and (y2 or y1) or y1
    local altY     = (dy <= 1.65) and y1 or (y2 or y1)

    local rawX, rawZ
    if len < 0.001 then
        rawX, rawZ = x1, z1
    else
        local nx = dx / len
        local nz = dz / len
        rawX, rawZ = x2 + (nx * distance), z2 + (nz * distance)
    end

    -- Fast AI-grid navmesh snap (avoidDangerousSurfaces = 0 prevents 600ms+ surface-floodfill stalls
    -- inside multi-tier temple stone geometry; hazards & traps are already filtered in Lua!).
    if Osi.FindValidPosition then
        local ok1, vx1, vy1, vz1 = pcall(Osi.FindValidPosition, rawX, primaryY, rawZ, 2.5, sourceUuid, 0)
        if ok1 and vx1 ~= nil then
            return vx1, vy1, vz1
        end
        if math.abs(altY - primaryY) > 0.15 then
            local ok2, vx2, vy2, vz2 = pcall(Osi.FindValidPosition, rawX, altY, rawZ, 2.6, sourceUuid, 0)
            if ok2 and vx2 ~= nil then
                return vx2, vy2, vz2
            end
        end
        local ok3, vx3, vy3, vz3 = pcall(Osi.FindValidPosition, x2, primaryY, z2, 2.9, sourceUuid, 0)
        if ok3 and vx3 ~= nil then
            return vx3, vy3, vz3
        end
        if ok1 then
            Blacklist[targetUuid] = Ext.Utils.MonotonicTime() + 1800000
            return nil
        end
    end
    return rawX, primaryY, rawZ
end

-- 04.3.11: Osi.FindValidPosition is a navmesh query - up to three snap attempts per call, and in
-- fragmented stone geometry (dungeon benches, stairs, multi-tier temples) a single one can cost
-- hundreds of ms. Callers ask for the same (character, target) pair again and again on every poll
-- tick, so cache the answer for 2 s; the cache dies as soon as the character really moves.
local ApproachCache = {}
local ApproachCacheCount = 0
local function GetSmartApproachPosition(sourceUuid, targetUuid, distance)
    if not sourceUuid or not targetUuid then return nil end
    local skey = CleanUuid(sourceUuid) or tostring(sourceUuid)
    local tkey = CleanUuid(targetUuid) or tostring(targetUuid)
    local key = skey .. "|" .. tkey .. "|" .. string.format("%.2f", tonumber(distance) or 1.0)
    local sx, sy, sz = Osi.GetPosition(sourceUuid)
    local now = Ext.Utils.MonotonicTime()
    local c = ApproachCache[key]
    if c and sx and (now - c.at) < 2000 then
        local dx, dz = sx - c.sx, sz - c.sz
        if (dx * dx + dz * dz) <= 1.0 then
            return c.x, c.y, c.z
        end
    end
    local x, y, z = GetSmartApproachPositionUncached(sourceUuid, targetUuid, distance)
    if ApproachCacheCount > 400 then
        ApproachCache = {}
        ApproachCacheCount = 0
    end
    ApproachCache[key] = { at = now, sx = sx or 0, sz = sz or 0, x = x, y = y, z = z }
    ApproachCacheCount = ApproachCacheCount + 1
    return x, y, z
end

-- ============================================================================
-- 4. PERSONALITY MATRIX & CONTEXT-SEPARATED ANIMATION POOLS
-- ============================================================================

-- Companion UUID Constants
local COMP = {
    Gale        = "ad9af97d-75da-406a-ae13-7071c563f604",
    Minsc       = "0de603c5-42e2-4811-9dad-f652de080eba",
    Wyll        = "c774d764-4a17-48dc-b470-32ace9ce447d",
    Shadowheart = "3ed74f06-3c60-42dc-83f6-f034cb47c679",
    Jaheira     = "91b6b200-7d00-4d62-8dc9-99e8339dfa1a",
    Halsin      = "7628bc0e-52b8-42a7-856a-13a6fd413323",
    Astarion    = "c7c13742-bacd-460a-8f65-f864fe41f255",
    Minthara    = "25721313-0c15-4935-8176-9f134385451b",
    Laezel      = "58a69333-40bf-8358-1d17-fff240d7fb12",
    Karlach     = "2c76687d-93a2-477b-8b18-8a14b549304c",
}

local ORIGIN_COMPANION_SET = {}
for _, uuid in pairs(COMP) do
    ORIGIN_COMPANION_SET[uuid] = true
end

local AVATAR_TAG = "306b9b05-1057-4770-aa17-01af21acd650"

-- Trait multipliers per companion (1.0 = neutral) — Build 04 enriched signature habits
local PERSONALITY_WEIGHTS = {
    [COMP.Gale]        = { books = 3.6, curiosity = 3.2, art = 2.0, chair = 1.4, fire = 1.5, dummy = 0.10, pet = 1.2, bed = 1.1, social = 1.6, scavenge = 0.65, light = 1.2, perimeter = 0.5 },
    [COMP.Laezel]      = { books = 0.45, curiosity = 1.1, art = 0.5, chair = 0.35, fire = 0.8, dummy = 4.00, pet = 0.4, bed = 0.25, social = 0.7, scavenge = 0.8, light = 1.1, perimeter = 2.9 },
    [COMP.Karlach]     = { books = 0.30, curiosity = 1.2, art = 0.9, chair = 1.0, fire = 0.25, dummy = 3.50, pet = 2.5, bed = 0.9, social = 2.0, scavenge = 1.5, light = 0.8, perimeter = 2.6 },
    [COMP.Astarion]    = { books = 1.4, curiosity = 2.6, art = 3.4, chair = 2.1, fire = 1.0, dummy = 0.25, pet = 0.8, bed = 1.5, social = 1.3, scavenge = 2.3, light = 0.9, perimeter = 0.9 },
    [COMP.Shadowheart] = { books = 1.5, curiosity = 1.7, art = 2.2, chair = 1.5, fire = 1.6, dummy = 0.70, pet = 3.8, bed = 1.2, social = 1.4, scavenge = 1.2, light = 3.4, perimeter = 1.0 },
    [COMP.Wyll]        = { books = 1.4, curiosity = 1.5, art = 1.6, chair = 1.3, fire = 2.3, dummy = 2.30, pet = 2.0, bed = 1.0, social = 2.3, scavenge = 1.0, light = 1.6, perimeter = 1.7 },
    [COMP.Jaheira]     = { books = 1.6, curiosity = 2.0, art = 1.3, chair = 1.4, fire = 1.9, dummy = 1.60, pet = 1.9, bed = 1.0, social = 1.6, scavenge = 1.2, light = 1.5, perimeter = 2.0 },
    [COMP.Halsin]      = { books = 1.3, curiosity = 1.5, art = 1.2, chair = 1.1, fire = 2.3, dummy = 0.65, pet = 3.5, bed = 1.0, social = 1.8, scavenge = 0.8, light = 1.3, perimeter = 1.4 },
    [COMP.Minthara]    = { books = 2.3, curiosity = 1.8, art = 1.9, chair = 2.5, fire = 1.2, dummy = 1.80, pet = 0.35, bed = 0.9, social = 0.8, scavenge = 0.7, light = 1.2, perimeter = 2.2 },
    [COMP.Minsc]       = { books = 0.20, curiosity = 1.9, art = 1.1, chair = 0.8, fire = 1.5, dummy = 3.00, pet = 3.3, bed = 0.8, social = 2.0, scavenge = 1.4, light = 1.1, perimeter = 2.1 },
}

local function GetTraitWeight(character, category)
    if not Config.Personalities then return 1.0 end
    local clean = CleanUuid(character)
    local profile = clean and PERSONALITY_WEIGHTS[clean] or nil
    if profile and profile[category] then
        return profile[category]
    end
    return 1.0
end

-- 4. Smooth Start -> Loop -> End Pose Blending System (Larian CAMP_Idle Architecture)
local AnimSystem = {}
local GetContextIdleAnimations
local GetMusicReactionAnimations
local GetGroundRestAnimations

do
    -- Verified Start / Loop / End animation triplets from BG3 Anubis scripts (CAMP_* & EPI_*):
    local LOOP_TO_TRIPLET = {
        -- Universal Action & Calm Poses
        ["CUST_Pondering_01_Loop_a47454a1-05a2-4153-bdfe-7a0500fa62d0"] = {
            start  = "CUST_Pondering_01_Start_2d14e6a9-d3a3-4f98-9031-22831546c392",
            loop   = "CUST_Pondering_01_Loop_a47454a1-05a2-4153-bdfe-7a0500fa62d0",
            stop   = "CUST_Pondering_01_End_e15cc480-7f1a-4ed4-8a3c-36355a37c644",
            exitMs = 2700,
        },
        ["CUST_Reading_Book_01_Loop_d8db9dc7-c6dd-4b6f-8af0-620c7473d8f8"] = {
            start  = "CUST_Reading_Book_01_Start_16107c0f-dbf6-47c4-9596-4c8cca8a683d",
            loop   = "CUST_Reading_Book_01_Loop_d8db9dc7-c6dd-4b6f-8af0-620c7473d8f8",
            stop   = "CUST_Reading_Book_01_End_6fda7690-15e7-4668-acc0-1025692de049",
            exitMs = 2600,
        },
        ["CUST_Reading_Old_Tome_01_7ce9c8f5-a969-4e66-a5c5-9a8c0d51d937"] = {
            start  = "CUST_Reading_Old_Tome_01_Start_c773f46b-b7bf-46ff-9532-d3a174999c87",
            loop   = "CUST_Reading_Old_Tome_01_7ce9c8f5-a969-4e66-a5c5-9a8c0d51d937",
            stop   = "CUST_Reading_Old_Tome_01_End_a5d237f3-8da8-49f5-a86a-864ee8f028a9",
            exitMs = 2200,
        },
        ["CUST_WarmingByFire_01_Loop_e2d0b8f4-00ae-49a4-a878-a9841fd78a96"] = {
            start  = "CUST_WarmingByFire_01_Start_901742e2-f648-42cb-bfa1-4b5e55e58479",
            loop   = "CUST_WarmingByFire_01_Loop_e2d0b8f4-00ae-49a4-a878-a9841fd78a96",
            stop   = "CUST_WarmingByFire_01_End_bcbfc7ca-11b4-44ad-b73e-f3d4862e86c5",
            exitMs = 2600,
        },
        ["CUST_ArmsCrossed_01_Loop_e6c49668-99b1-41d6-8daa-7ed6864b4e71"] = {
            start  = "CUST_ArmsCrossed_01_Start_dafd0bbc-012a-403c-aabe-4963aca9cf25",
            loop   = "CUST_ArmsCrossed_01_Loop_e6c49668-99b1-41d6-8daa-7ed6864b4e71",
            stop   = "CUST_ArmsCrossed_01_End_ae43ea68-fc1b-456a-88ce-0e1d504e1d40",
            exitMs = 2700,
        },
        ["CUST_Bored_01_Loop_23588ba8-fafb-438c-9bc5-660ff6650aef"] = {
            start  = "CUST_Bored_01_Start_8a7d1eef-f09a-4520-b277-37ddcf5aebb8",
            loop   = "CUST_Bored_01_Loop_23588ba8-fafb-438c-9bc5-660ff6650aef",
            stop   = "CUST_Bored_01_End_80547143-a038-449f-bc38-993e216b804a",
            exitMs = 2500,
        },
        ["CUST_Writing_02_Loop_896b83fb-27c3-41e0-924c-7ebf8473154b"] = {
            start  = "CUST_Writing_02_Start_cf445db4-01a3-4833-ab14-a66b19c439fe",
            loop   = "CUST_Writing_02_Loop_896b83fb-27c3-41e0-924c-7ebf8473154b",
            stop   = "CUST_Writing_02_End_dab89293-d140-4345-bfcd-41be7a739665",
            exitMs = 2800,
        },
        -- Social Chatting Poses
        ["CUST_EPI_Gale_Chatting_01_Loop_c49d9988-44f0-47ec-8afb-7c08857f7852"] = {
            start  = "CUST_EPI_Gale_Chatting_01_Start_0dbd1f4b-6e97-4c96-9e87-c33c2d970cb0",
            loop   = "CUST_EPI_Gale_Chatting_01_Loop_c49d9988-44f0-47ec-8afb-7c08857f7852",
            stop   = "CUST_EPI_Gale_Chatting_01_End_28e5aa84-76fc-48ba-b129-2b8338a1cb99",
            exitMs = 2500,
        },
        ["CUST_TellStory_01_Loop_cc763951-1ae0-4b04-9c27-0261d8eef3fd"] = {
            start  = "CUST_TellStory_01_Start_50e94e00-fa55-431d-9d8b-e3d97a37c0b0",
            loop   = "CUST_TellStory_01_Loop_cc763951-1ae0-4b04-9c27-0261d8eef3fd",
            stop   = "CUST_TellStory_01_End_21293a06-b892-4c13-b119-1e2dfcf5d581",
            exitMs = 2500,
        },
        -- Ground-Sitting Poses (Genuine mocapped sit-down & stand-up — replaces static PhotoMode poses!)
        ["CUST_SittingGroundListening_01_Loop_e3dca236-9064-4613-8d5f-2b8b40f3294d"] = {
            start  = "CUST_SittingGroundListening_01_Start_8c390bf1-f95d-40c3-a13e-0d30a74d8608",
            loop   = "CUST_SittingGroundListening_01_Loop_e3dca236-9064-4613-8d5f-2b8b40f3294d",
            stop   = "CUST_SittingGroundListening_01_End_245f1cbf-22c2-4103-bd35-50e2e803a5f4",
            exitMs = 3800,
        },
        ["CUST_Jaheira_RelaxedSitting_01_Loop_91e6773d-cfa2-4fe9-90c0-938acb314e2d"] = {
            start  = "CUST_Jaheira_RelaxedSitting_01_Start_9aa14cf9-1094-4465-8ade-af335216dec8",
            loop   = "CUST_Jaheira_RelaxedSitting_01_Loop_91e6773d-cfa2-4fe9-90c0-938acb314e2d",
            stop   = "CUST_Jaheira_RelaxedSitting_01_End_f9948253-64d5-4b02-863a-01eff0812e5e",
            exitMs = 4000,
        },
        ["CUST_EPI_Karlach_StargazingSit_01_Loop_43384cb6-9fab-4c91-ac9b-5ecde0e8d61c"] = {
            start  = "CUST_EPI_Karlach_StargazingSit_01_Start_7387d2a8-b99a-496f-bee3-1e65c15bab24",
            loop   = "CUST_EPI_Karlach_StargazingSit_01_Loop_43384cb6-9fab-4c91-ac9b-5ecde0e8d61c",
            stop   = "CUST_EPI_Karlach_StargazingSit_01_End_1caf9b7a-4acb-4017-af36-4a4ebdd80a35",
            exitMs = 3800,
        },
        ["CUST_Meditating_01_45b1a54b-b127-46d2-bfe6-daa8963398ea"] = {
            start  = "CUST_Meditating_01_Start_12c9c463-0762-4ef3-a24e-29b5254f580f",
            loop   = "CUST_Meditating_01_45b1a54b-b127-46d2-bfe6-daa8963398ea",
            stop   = "CUST_Meditating_01_End_ad0be56c-63b4-4b24-9859-ebcd282ba9f8",
            exitMs = 3500,
        },
        ["CUST_EPI_AvernusWyll_SittingOnFloorDrink_01_Loop_40d59dd0-1364-46c2-ba02-e0b4f52bad98"] = {
            start  = "CUST_EPI_AvernusWyll_SittingOnFloorDrink_01_Start_7d3c036e-16aa-4f01-80b8-d4e0ccf34892",
            loop   = "CUST_EPI_AvernusWyll_SittingOnFloorDrink_01_Loop_40d59dd0-1364-46c2-ba02-e0b4f52bad98",
            stop   = "CUST_EPI_AvernusWyll_SittingOnFloorDrink_01_End_59e2574a-75dd-4476-9512-bcaa3ecc68fa",
            exitMs = 3800,
        },
        -- Companion-Specific Personal & Sky Triplets
        ["CUST_EPI_DukeWyll_Reading_01_Loop_e7047375-2edf-4c19-a408-e1f507020e78"] = {
            start  = "CUST_EPI_DukeWyll_Reading_01_Start_65522081-2663-4da3-9966-fa5f9832dde2",
            loop   = "CUST_EPI_DukeWyll_Reading_01_Loop_e7047375-2edf-4c19-a408-e1f507020e78",
            stop   = "CUST_EPI_DukeWyll_Reading_01_End_88df4a29-cd31-411e-9b40-b8979647a5f4",
            exitMs = 2600,
        },
        ["CUST_Jaheira_Whittling_01_Loop_96344f40-2814-4267-99c4-2c30b57fd970"] = {
            start  = "CUST_Jaheira_Whittling_01_Start_acdb767d-ba3e-4455-a016-d62da16091f9",
            loop   = "CUST_Jaheira_Whittling_01_Loop_96344f40-2814-4267-99c4-2c30b57fd970",
            stop   = "CUST_Jaheira_Whittling_01_End_540f8604-171c-402a-9b18-ca80ed24bdb8",
            exitMs = 3200,
        },
        ["CUST_CleaningNails_01_Loop_22d33fbc-f920-4c44-9488-afc6bd9e0e9c"] = {
            start  = "CUST_CleaningNails_01_Start_2e00ea8f-5bb2-4062-9bc8-08e35f9ae1de",
            loop   = "CUST_CleaningNails_01_Loop_22d33fbc-f920-4c44-9488-afc6bd9e0e9c",
            stop   = "CUST_CleaningNails_01_End_1db1f13b-2a6a-4596-b1b7-6f03e7b69ca5",
            exitMs = 3000,
        },
        ["CUST_WarmingUp_01_Loop_8208eccb-2c27-4d87-bbe0-41d0b2760faf"] = {
            start  = "CUST_WarmingUp_01_Start_519d985b-0511-4d25-bd36-233f84d038b5",
            loop   = "CUST_WarmingUp_01_Loop_8208eccb-2c27-4d87-bbe0-41d0b2760faf",
            stop   = "CUST_WarmingUp_01_End_ee20ab7f-ad08-454f-b9ef-1f64ee8aa956",
            exitMs = 3000,
        },
        ["CUST_EPI_Gale_Drinking_01_Loop_ac8eb7ae-4e86-4f82-8586-ea152572f8c6"] = {
            start  = "CUST_EPI_Gale_Drinking_01_Start_b97491aa-c5f5-42ce-aec0-78043892ce39",
            loop   = "CUST_EPI_Gale_Drinking_01_Loop_ac8eb7ae-4e86-4f82-8586-ea152572f8c6",
            stop   = "CUST_EPI_Gale_Drinking_01_End_8814dff3-7b1f-4252-8f40-76e8e6a09698",
            exitMs = 2600,
        },
        ["CUST_EPI_Wyll_Drinking_01_Loop_3dd86f4a-a63a-4e90-92d5-de5a14da6474"] = {
            start  = "CUST_EPI_Wyll_Drinking_01_Start_eb9184ef-7488-4c1a-8d0e-4975c1a79493",
            loop   = "CUST_EPI_Wyll_Drinking_01_Loop_3dd86f4a-a63a-4e90-92d5-de5a14da6474",
            stop   = "CUST_EPI_Wyll_Drinking_01_End_65ad6956-53b4-4eb0-88ba-ada3548be6d1",
            exitMs = 2600,
        },
        ["CUST_EPI_Shadowheart_Stargazing_01_Loop_3d2ad8b1-f894-4ecb-ac07-de2c482e537a"] = {
            start  = "CUST_EPI_Shadowheart_Stargazing_01_Start_223fb421-5f87-47e8-bd8e-2c3a305f5c1a",
            loop   = "CUST_EPI_Shadowheart_Stargazing_01_Loop_3d2ad8b1-f894-4ecb-ac07-de2c482e537a",
            stop   = "CUST_EPI_Shadowheart_Stargazing_01_End_3edd1f43-5de9-40e4-850e-655e25ad9998",
            exitMs = 2800,
        },
        ["CUST_EPI_Shadowheart_LookingAtFlower_01_Loop_a481a91e-d3f1-4247-bbbd-6c33d39eff15"] = {
            start  = "CUST_EPI_Shadowheart_LookingAtFlower_01_Start_923079df-b2c4-4741-b5fc-665a8d144665",
            loop   = "CUST_EPI_Shadowheart_LookingAtFlower_01_Loop_a481a91e-d3f1-4247-bbbd-6c33d39eff15",
            stop   = "CUST_EPI_Shadowheart_LookingAtFlower_01_End_51964b27-d112-4ab5-88da-a22e273a9b6f",
            exitMs = 2600,
        },
        ["CUST_EPI_Karlach_StargazingStand_01_Loop_f80235d8-5c96-4dfc-a9a6-cc928606b156"] = {
            start  = "CUST_EPI_Karlach_StargazingStand_01_Start_cddbdbec-a07b-43c6-843a-905308687e76",
            loop   = "CUST_EPI_Karlach_StargazingStand_01_Loop_f80235d8-5c96-4dfc-a9a6-cc928606b156",
            stop   = "CUST_EPI_Karlach_StargazingStand_01_End_14eb5f0e-aa5c-4e89-87f3-215bd675609a",
            exitMs = 2600,
        },
        ["CUST_Stargazing_01_Loop_355a7a54-dbff-4bde-a203-a7c107917631"] = {
            start  = "CUST_Stargazing_01_Start_d9e8e590-0e24-4a1b-a5e9-6036f6287d65",
            loop   = "CUST_Stargazing_01_Loop_355a7a54-dbff-4bde-a203-a7c107917631",
            stop   = "CUST_Stargazing_01_End_095b0a1e-bdce-4940-8d44-850b42cf1b02",
            exitMs = 2600,
        },
        -- Music & Bard Reaction Triplets
        ["CUST_EPI_Wyll_Clap_01_Loop_923fd6d1-7ff6-4cdd-ae46-7ae0d1ee043b"] = {
            start  = "CUST_EPI_Wyll_Clap_01_Start_ae069332-a374-47d7-93c4-c7347b75ba73",
            loop   = "CUST_EPI_Wyll_Clap_01_Loop_923fd6d1-7ff6-4cdd-ae46-7ae0d1ee043b",
            stop   = "CUST_EPI_Wyll_Clap_01_End_e6bee909-54ea-40bf-9a66-c29ade4c60c7",
            exitMs = 2200,
        },
        ["CUST_EPI_DukeWyll_EnjoyingTheMusic_01_Loop_63221d04-2ae3-4d7e-a626-a86c0c717222"] = {
            start  = "CUST_EPI_DukeWyll_EnjoyingTheMusic_01_Start_53a8a375-7270-4e3d-ad9c-5a319c10085f",
            loop   = "CUST_EPI_DukeWyll_EnjoyingTheMusic_01_Loop_63221d04-2ae3-4d7e-a626-a86c0c717222",
            stop   = "CUST_EPI_DukeWyll_EnjoyingTheMusic_01_End_c0c4f4d0-b7df-4500-8313-77b30a1a7b2a",
            exitMs = 2400,
        },
        ["CUST_EPI_Shadowheart_Dance_01_Loop_2a82690c-f334-4f0d-964f-0161f9efd9e6"] = {
            start  = "CUST_EPI_Shadowheart_Dance_01_Start_9dc6faf8-95d3-45dc-bdde-5eb514a180c6",
            loop   = "CUST_EPI_Shadowheart_Dance_01_Loop_2a82690c-f334-4f0d-964f-0161f9efd9e6",
            stop   = "CUST_EPI_Shadowheart_Dance_01_End_2a9a295a-6f54-481b-8c4d-79f59735d40b",
            exitMs = 2600,
        },
        ["CUST_EPI_Karlach_Dance_01_Loop_0939135a-a08c-4025-9bcd-1d53b2758474"] = {
            start  = "CUST_EPI_Karlach_Dance_01_Start_b86cc985-88df-4e21-ac0f-1b63329338e7",
            loop   = "CUST_EPI_Karlach_Dance_01_Loop_0939135a-a08c-4025-9bcd-1d53b2758474",
            stop   = "CUST_EPI_Karlach_Dance_01_End_40bac793-0d03-4418-a7ba-db2972790f1a",
            exitMs = 2600,
        },
        ["CUST_EPI_Karlach_Jamming_01_Loop_3c70c66b-1d9a-4d4d-a2bb-9f1cd31d1727"] = {
            start  = "CUST_EPI_Karlach_Jamming_01_Start_1367c13c-107d-41ff-89b5-f67308a3a5c5",
            loop   = "CUST_EPI_Karlach_Jamming_01_Loop_3c70c66b-1d9a-4d4d-a2bb-9f1cd31d1727",
            stop   = "CUST_EPI_Karlach_Jamming_01_End_79a73ef9-662e-42f7-8077-65f5a6554c53",
            exitMs = 2600,
        },
        ["CUST_EPI_Halsin_Dance_01_Loop_e0bbddb0-4e03-4f74-8fd4-dc172026de66"] = {
            start  = "CUST_EPI_Halsin_Dance_01_Start_d8d4df38-794e-45ca-b950-4cb89da83d3d",
            loop   = "CUST_EPI_Halsin_Dance_01_Loop_e0bbddb0-4e03-4f74-8fd4-dc172026de66",
            stop   = "CUST_EPI_Halsin_Dance_01_End_bcbbdc90-da72-4f41-a4cf-3cec3564e355",
            exitMs = 2600,
        },
    }

    local CALM_ANIMS = {
        ["any"] = {
            "CUST_Bored_01_Loop_23588ba8-fafb-438c-9bc5-660ff6650aef",
            "CUST_ArmsCrossed_01_Loop_e6c49668-99b1-41d6-8daa-7ed6864b4e71",
            "CUST_Pondering_01_Loop_a47454a1-05a2-4153-bdfe-7a0500fa62d0",
            "CUST_Bored_02_7892cb3b-2935-4aa3-b65c-64d9664cbe75",
            "CUST_LookingAround_63bcacef-5631-4ab3-9400-81b23cb18ca7",
            "CUST_Investigating_LookingAround_02_ab739447-e85f-4fca-b1d4-fb783d61fa9c",
        },
        ["think"] = {
            "CUST_Thinking_01_97588786-d9bf-4d18-879b-1bd3dcaa62ba",
        },
        [COMP.Gale] = {
            "CUST_Thinking_01_97588786-d9bf-4d18-879b-1bd3dcaa62ba",
            -- 04.3.18: CUST_Reading_Old_Tome_01 removed - played with empty hands in
            -- every mode (verified on the host), so it read as "reading thin air".
            "CUST_Writing_02_Loop_896b83fb-27c3-41e0-924c-7ebf8473154b",
        },
        [COMP.Shadowheart] = {
            "CUST_EPI_Shadowheart_LookingAtFlower_01_Loop_a481a91e-d3f1-4247-bbbd-6c33d39eff15",
        },
        [COMP.Karlach] = {
            "CUST_CleaningNails_01_Loop_22d33fbc-f920-4c44-9488-afc6bd9e0e9c",
            "CUST_WarmingUp_01_Loop_8208eccb-2c27-4d87-bbe0-41d0b2760faf",
        },
        [COMP.Minsc] = {
            "CUST_EPI_Minsc_FlexingMuscle_01_6d1732cd-761d-4cab-973c-17e03ba4ee2f",
        },
        [COMP.Wyll] = {
            "CUST_EPI_DukeWyll_Reading_01_Loop_e7047375-2edf-4c19-a408-e1f507020e78",
        },
        [COMP.Jaheira] = {
            "CUST_Jaheira_Whittling_01_Loop_96344f40-2814-4267-99c4-2c30b57fd970",
        },
        [COMP.Astarion] = {
            "CUST_CleaningNails_01_Loop_22d33fbc-f920-4c44-9488-afc6bd9e0e9c",
            "CUST_EPI_CazAstarion_SharpensDagger_01_8642de6d-1377-4ba8-a32d-e90c236b5ef5",
            "CUST_EPI_Astarion_KnifeTricks_01_3946137b-d703-492b-a916-09912d3bf867",
            "CUST_EPI_Astarion_DustSelf_01_9b8f3897-bb74-4a83-ac5e-d95bd0b0e9f4",
            "CUST_EPI_Astarion_CombHair_01_b9a9cc36-4159-441e-bc9c-a85b3ae09873",
        },
        [COMP.Minthara] = {
            "CUST_Minthara_AdjustingOutfit_01_19bbe55d-e338-4fe3-8900-e17977949ff7",
            "CUST_EPI_Minthara_Bored_01_8fdbac5c-f4a9-4d25-b7ea-bbbae6147753",
            "CUST_EPI_Minthara_LookAround_01_e957120e-e00d-4a47-8c7b-f58e12f83f7f",
        },
        [COMP.Laezel] = {
            "CUST_EPI_Laezel_LookingAround_01_564143d2-e7dc-4eae-9eca-e8ddf1ae71b8",
        },
    }

    local RELAXED_ANIMS = {
        [COMP.Gale] = {
            "CUST_EPI_Gale_Drinking_01_Loop_ac8eb7ae-4e86-4f82-8586-ea152572f8c6",
            "CUST_EPI_Gale_Eating_01_ac88a100-cd5e-48bc-9a3e-eb3da16b2f9b",
        },
        [COMP.Wyll] = {
            "CUST_EPI_Wyll_Drinking_01_Loop_3dd86f4a-a63a-4e90-92d5-de5a14da6474",
        },
        [COMP.Minthara] = {
            "CUST_EPI_Minthara_Eating_01_ffcf5fd1-862b-4765-8645-3cbc0f96432c",
        },
        [COMP.Minsc] = {
            "CUST_EPI_Minsc_StuffFoods_01_6a821ed2-15d4-4814-b607-c639a962095a",
            "CUST_EPI_Minsc_ShaveHead_01_dea9b80f-6e67-461d-a292-91075be50438",
        },
        [COMP.Jaheira] = {
            "CUST_EPI_Jaheira_FlutePlaying_01_b6673e38-04d2-47df-ae4a-a70ad2861d22",
        },
    }

    local SKY_ANIMS = {
        [COMP.Shadowheart] = {
            "CUST_EPI_Shadowheart_Stargazing_01_Loop_3d2ad8b1-f894-4ecb-ac07-de2c482e537a",
        },
        [COMP.Karlach] = {
            "CUST_EPI_Karlach_StargazingStand_01_Loop_f80235d8-5c96-4dfc-a9a6-cc928606b156",
            "CUST_Stargazing_01_Loop_355a7a54-dbff-4bde-a203-a7c107917631",
        },
        [COMP.Laezel] = {
            "CUST_EPI_Laezel_LookingUp_01_b571f848-91d4-4777-b551-0e60e1973f61",
            "CUST_EPI_Laezel_LookingUp_02_4cb2583a-3213-41dd-ba2d-884496da4146",
        },
        [COMP.Minthara] = {
            "CUST_Minthara_BotheredbySun_01_4f4b0dba-d426-4a05-a7af-0ef614dfd091",
        },
    }

    local MUSIC_ANIMS = {
        ["any"] = {
            "CUST_EPI_Wyll_Clap_01_Loop_923fd6d1-7ff6-4cdd-ae46-7ae0d1ee043b",
            "CUST_EPI_DukeWyll_EnjoyingTheMusic_01_Loop_63221d04-2ae3-4d7e-a626-a86c0c717222",
        },
        [COMP.Wyll] = {
            "CUST_EPI_DukeWyll_EnjoyingTheMusic_01_Loop_63221d04-2ae3-4d7e-a626-a86c0c717222",
            "CUST_EPI_Wyll_Clap_01_Loop_923fd6d1-7ff6-4cdd-ae46-7ae0d1ee043b",
        },
        [COMP.Shadowheart] = {
            "CUST_EPI_Shadowheart_Dance_01_Loop_2a82690c-f334-4f0d-964f-0161f9efd9e6",
            "CUST_EPI_Wyll_Clap_01_Loop_923fd6d1-7ff6-4cdd-ae46-7ae0d1ee043b",
        },
        [COMP.Karlach] = {
            "CUST_EPI_Karlach_Dance_01_Loop_0939135a-a08c-4025-9bcd-1d53b2758474",
            "CUST_EPI_Karlach_Jamming_01_Loop_3c70c66b-1d9a-4d4d-a2bb-9f1cd31d1727",
        },
        [COMP.Halsin] = {
            "CUST_EPI_Halsin_Dance_01_Loop_e0bbddb0-4e03-4f74-8fd4-dc172026de66",
            "CUST_EPI_Wyll_Clap_01_Loop_923fd6d1-7ff6-4cdd-ae46-7ae0d1ee043b",
        },
        [COMP.Jaheira] = {
            "CUST_EPI_Jaheira_ListeningtoMusic_01_315bb6e9-01ea-4fff-adb8-8a5b7ed9527b",
        },
        [COMP.Laezel] = {
            "CUST_EPI_Laezel_ListeningToMusic_01_5c426fd3-76ec-4165-ab9b-f2582c046743",
        },
        [COMP.Minsc] = {
            "CUST_Minsc_PlayingDrum_01_e7f761fc-8441-4424-9bf5-b43daca47f18",
            "CUST_EPI_Wyll_Clap_01_Loop_923fd6d1-7ff6-4cdd-ae46-7ae0d1ee043b",
        },
        [COMP.Astarion] = {
            "CUST_EPI_DukeWyll_EnjoyingTheMusic_01_Loop_63221d04-2ae3-4d7e-a626-a86c0c717222",
        },
        [COMP.Gale] = {
            "CUST_EPI_Wyll_Clap_01_Loop_923fd6d1-7ff6-4cdd-ae46-7ae0d1ee043b",
            "CUST_EPI_DukeWyll_EnjoyingTheMusic_01_Loop_63221d04-2ae3-4d7e-a626-a86c0c717222",
        },
    }

    local SOCIAL_ANIMS = {
        "CUST_EPI_Gale_Chatting_01_Loop_c49d9988-44f0-47ec-8afb-7c08857f7852",
        "CUST_TellStory_01_Loop_cc763951-1ae0-4b04-9c27-0261d8eef3fd",
        "CUST_Pondering_01_Loop_a47454a1-05a2-4153-bdfe-7a0500fa62d0",
    }

    -- Genuine mocapped ground-sitting poses with full _Start sit-down & _End stand-up transitions!
    local GROUND_REST_ANIMS = {
        "CUST_SittingGroundListening_01_Loop_e3dca236-9064-4613-8d5f-2b8b40f3294d",
        "CUST_Jaheira_RelaxedSitting_01_Loop_91e6773d-cfa2-4fe9-90c0-938acb314e2d",
        "CUST_EPI_Karlach_StargazingSit_01_Loop_43384cb6-9fab-4c91-ac9b-5ecde0e8d61c",
        "CUST_Meditating_01_45b1a54b-b127-46d2-bfe6-daa8963398ea",
    }

    local RACETAG_SMALL_FEM = {
        ["b99b6a5d-8445-44e4-ac58-81b2ee88aab1"] = true, -- Halfling
        ["1f0551f3-d769-47a9-b02b-5d3a8c51978c"] = true, -- Gnome
    }

    local function AppendAll(dst, src)
        if not src then return end
        for i = 1, #src do dst[#dst + 1] = src[i] end
    end

    local function IsThinkingAnimSupported(character)
        local ok, allowed = pcall(function()
            local entity = Ext.Entity.Get(character)
            if not entity then return true end
            local bt = entity.BodyType and entity.BodyType.BodyType or 0
            local bs = (entity.CharacterCreationStats and entity.CharacterCreationStats.BodyShape) or 0
            if bt == 1 and bs == 0 and entity.ServerRaceTag and entity.ServerRaceTag.Tags then
                for _, tag in pairs(entity.ServerRaceTag.Tags) do
                    if RACETAG_SMALL_FEM[tostring(tag)] then
                        return false
                    end
                end
            end
            return true
        end)
        return (not ok) or allowed
    end

    GetContextIdleAnimations = function(character, zone)
        local pool = {}
        AppendAll(pool, CALM_ANIMS["any"])
        local clean = CleanUuid(character)
        if clean and CALM_ANIMS[clean] then
            AppendAll(pool, CALM_ANIMS[clean])
        end
        if IsThinkingAnimSupported(character) then
            AppendAll(pool, CALM_ANIMS["think"])
        end

        local useContext = Config.ContextAware
        local isRelaxed = (not useContext) or (zone and zone.isRelaxed)
        local isDungeon = useContext and (zone and zone.isDungeon)

        if isRelaxed and clean and RELAXED_ANIMS[clean] then
            AppendAll(pool, RELAXED_ANIMS[clean])
        end
        if (not isDungeon) and clean and SKY_ANIMS[clean] then
            AppendAll(pool, SKY_ANIMS[clean])
        end
        if not Config.BardSync and clean and MUSIC_ANIMS[clean] then
            AppendAll(pool, MUSIC_ANIMS[clean])
        end
        return pool
    end

    GetMusicReactionAnimations = function(character)
        local clean = CleanUuid(character)
        if clean and MUSIC_ANIMS[clean] and #MUSIC_ANIMS[clean] > 0 then
            return MUSIC_ANIMS[clean]
        end
        return MUSIC_ANIMS["any"]
    end

    GetGroundRestAnimations = function(character)
        if not character or not Config.Personalities then
            return GROUND_REST_ANIMS
        end
        local clean = CleanUuid(character)
        if clean == COMP.Halsin or clean == COMP.Laezel or clean == COMP.Minthara then
            return {
                "CUST_Meditating_01_45b1a54b-b127-46d2-bfe6-daa8963398ea",
                "CUST_Meditating_01_45b1a54b-b127-46d2-bfe6-daa8963398ea",
                "CUST_SittingGroundListening_01_Loop_e3dca236-9064-4613-8d5f-2b8b40f3294d",
            }
        elseif clean == COMP.Jaheira then
            return {
                "CUST_Jaheira_RelaxedSitting_01_Loop_91e6773d-cfa2-4fe9-90c0-938acb314e2d",
                "CUST_Jaheira_RelaxedSitting_01_Loop_91e6773d-cfa2-4fe9-90c0-938acb314e2d",
                "CUST_SittingGroundListening_01_Loop_e3dca236-9064-4613-8d5f-2b8b40f3294d",
            }
        elseif clean == COMP.Karlach then
            return {
                "CUST_EPI_Karlach_StargazingSit_01_Loop_43384cb6-9fab-4c91-ac9b-5ecde0e8d61c",
                "CUST_EPI_Karlach_StargazingSit_01_Loop_43384cb6-9fab-4c91-ac9b-5ecde0e8d61c",
                "CUST_Jaheira_RelaxedSitting_01_Loop_91e6773d-cfa2-4fe9-90c0-938acb314e2d",
            }
        end
        return GROUND_REST_ANIMS
    end

    AnimSystem.READ_BOOK    = "CUST_Reading_Book_01_Loop_d8db9dc7-c6dd-4b6f-8af0-620c7473d8f8"
    AnimSystem.READ_TOME    = "CUST_Reading_Old_Tome_01_7ce9c8f5-a969-4e66-a5c5-9a8c0d51d937"
    AnimSystem.PONDER       = "CUST_Pondering_01_Loop_a47454a1-05a2-4153-bdfe-7a0500fa62d0"
    AnimSystem.WARM_FIRE    = "CUST_WarmingByFire_01_Loop_e2d0b8f4-00ae-49a4-a878-a9841fd78a96"
    AnimSystem.CALL_PET     = "CUST_CallingPet_01_faf30563-36c3-46d9-998d-86d37a0a7483"
    AnimSystem.INSPECT_NEAR = "CUST_InspectClose_01_25631e14-916d-4d91-8b59-094122d78cd0"
    AnimSystem.USE_ITEM     = "CUST_Use_Item_01_3f473062-23c2-482f-bf2a-9e731454a844"

    function AnimSystem.isOriginCompanion(char)
        local c = CleanUuid(char)
        return (c ~= nil and ORIGIN_COMPANION_SET[c] == true)
    end

    function AnimSystem.pickReadAnim(char)
        -- 04.3.18: the old tome clip never spawns its prop (bare and triplet both verified
        -- empty-handed in game), while the plain book clip does. So everybody reads a book.
        -- READ_TOME stays below for the day a working Start GUID turns up.
        return AnimSystem.READ_BOOK
    end

    function AnimSystem.getSignatureScore(char, category, propNameLower)
        local w = GetTraitWeight(char, category)
        if not Config.Personalities then return w end
        local c = CleanUuid(char)
        if not c then return w end
        local low = propNameLower or ""

        if category == "curiosity" then
            if c == COMP.Gale and (string.find(low, "telescope", 1, true) or string.find(low, "spyglass", 1, true) or string.find(low, "globe", 1, true) or string.find(low, "astrolabe", 1, true) or string.find(low, "plaque", 1, true) or string.find(low, "pedestal", 1, true)) then
                w = w * 1.65
            elseif c == COMP.Astarion and (string.find(low, "mirror", 1, true) or string.find(low, "vanity", 1, true)) then
                w = w * 2.10
            elseif c == COMP.Shadowheart and (string.find(low, "stuffedbear", 1, true) or string.find(low, "teddy", 1, true) or string.find(low, "shrine", 1, true) or string.find(low, "altar", 1, true)) then
                w = w * 1.90
            end
        elseif category == "art" then
            if c == COMP.Astarion and (string.find(low, "painting", 1, true) or string.find(low, "portrait", 1, true)) then
                w = w * 1.45
            elseif c == COMP.Shadowheart and (string.find(low, "statue", 1, true) or string.find(low, "selune", 1, true) or string.find(low, "shar", 1, true)) then
                w = w * 1.45
            end
        elseif category == "light" then
            if c == COMP.Shadowheart and (string.find(low, "candle", 1, true) or string.find(low, "candelabr", 1, true) or string.find(low, "brazier", 1, true)) then
                w = w * 1.35
            end
        end
        return w
    end

    function AnimSystem.lookAt(char, targetUuid, durationSec)
        if not char or not targetUuid then return end
        pcall(function()
            if Osi.LookAtEntity then
                Osi.LookAtEntity(char, targetUuid, durationSec or 3.5)
            end
        end)
    end

    function AnimSystem.enqueueSmoothTurn(queue, stepName, targetUuid, onAbortFn)
        if not queue or not targetUuid then return end
        queue:enqueue({
            name = stepName or "SmoothTurn",
            execute = function(char)
                FaceTarget(char, targetUuid)
            end,
            duration = 460,
            onAbort = onAbortFn,
        })
    end

    function AnimSystem.pickSocialAnim()
        return SOCIAL_ANIMS[math.random(#SOCIAL_ANIMS)]
    end

    function AnimSystem.getExitMs(animKey)
        local t = animKey and LOOP_TO_TRIPLET[animKey] or nil
        return (t and t.exitMs) or 750
    end

    function AnimSystem.isTriplet(animKey)
        return (animKey and LOOP_TO_TRIPLET[animKey] ~= nil) or false
    end

    -- 04.3.17: console A/B test needs read access to the triplet table
    function AnimSystem.getTriplet(animKey)
        if not animKey then return nil end
        return LOOP_TO_TRIPLET[animKey]
    end

    function AnimSystem.play(char, animKey)
        if not char or not animKey or animKey == "" then return 900 end
        local t = LOOP_TO_TRIPLET[animKey]
        if t and Osi.PlayLoopingAnimation then
            pcall(Osi.PlayLoopingAnimation, char, t.start or "", t.loop, t.stop or "", "", "", "", "")
            return t.exitMs or 2500
        end
        pcall(Osi.PlayAnimation, char, animKey, "")
        return 750
    end

    function AnimSystem.gracefulStop(char)
        StopCustomAnimation(char, true) -- abort = 0 -> triggers _End clip & smooth blend!
    end

    function AnimSystem.enqueueGracefulExit(queue, stepName, animKey, extraFn)
        if not queue then return end
        local isTrip = AnimSystem.isTriplet(animKey)
        local exitMs = AnimSystem.getExitMs(animKey)
        queue:enqueue({
            name = stepName or "SmoothExitPose",
            execute = function(char)
                if extraFn then pcall(extraFn, char) end
                -- Only call StopAnimation(char, 0) on looping triplets! Non-triplet one-shot clips
                -- (CALL_PET, INSPECT_NEAR, USE_ITEM) naturally blend back to idle on their own!
                if isTrip then
                    AnimSystem.gracefulStop(char)
                end
            end,
            duration = exitMs,
        })
    end
end

-- ============================================================================
-- 5. PARTY, GROUPED IDLE & BARD DETECTION
-- ============================================================================

local StateChecks = {}

function StateChecks.isGrouped(character, leader)
    if not leader or not character then return false end
    if SameEntity(character, leader) then return true end
    local ok, grouped = pcall(function()
        local ce = Ext.Entity.Get(character)
        local le = Ext.Entity.Get(leader)
        if ce and ce.PartyMember and le and le.PartyMember then
            if ce.PartyMember.ViewUuid and le.PartyMember.ViewUuid then
                return tostring(ce.PartyMember.ViewUuid) == tostring(le.PartyMember.ViewUuid)
            end
        end
        return false
    end)
    return ok and grouped or false
end

function StateChecks.isWithinReach(char, targetUuid, maxHoriz, maxVert)
    if not char or not targetUuid then return false end
    local x1, y1, z1 = Osi.GetPosition(char)
    local x2, y2, z2 = Osi.GetPosition(targetUuid)
    if x1 and x2 then
        local dx = x1 - x2
        local dz = z1 - z2
        local dy = math.abs((y1 or 0) - (y2 or 0))
        if (dx * dx + dz * dz) <= (maxHoriz * maxHoriz) and dy <= (maxVert or 3.0) then
            return true
        end
    end
    local d = Osi.GetDistanceTo and Osi.GetDistanceTo(char, targetUuid) or nil
    return d ~= nil and d <= maxHoriz
end

StateChecks.anchorActive = false
StateChecks.anchorX = 0.0
StateChecks.anchorY = 0.0
StateChecks.anchorZ = 0.0

function StateChecks.resetIdleAnchor()
    StateChecks.anchorActive = false
end

function StateChecks.updateHostActivity(now)
    local host = Osi.GetHostCharacter and Osi.GetHostCharacter() or nil
    if not host then
        StateChecks.anchorActive = false
        HostLastActiveTime = now
        return nil
    end

    local hx, hy, hz = Osi.GetPosition(host)
    local moved = false
    if hx and HostLastPos.x == nil then
        moved = true
    elseif hx and HostLastPos.x then
        local dx = hx - HostLastPos.x
        local dy = hy - HostLastPos.y
        local dz = hz - HostLastPos.z
        if (dx * dx + dy * dy + dz * dz) > 0.04 then
            moved = true
        end
    end
    if hx then
        HostLastPos.x, HostLastPos.y, HostLastPos.z = hx, hy, hz
    end

    local hardBreak = (Osi.IsInCombat(host) == 1)
        or IsAnyDialogActive()
        or IsSneakingOrInvisible(host)
        or IsInTurnBased(host)

    if hardBreak or not hx then
        StateChecks.anchorActive = false
        HostLastActiveTime = now
        ScavengeStreak = {}
        return host
    end

    local anchorR = tonumber(Config.IdleAnchorRadius) or 3.5
    if StateChecks.anchorActive and Config.AllowGrouped and anchorR > 0 then
        local adx = hx - StateChecks.anchorX
        local adz = hz - StateChecks.anchorZ
        local ady = math.abs(hy - StateChecks.anchorY)
        -- Build 04.1 Room Idle Anchor: ignore small steps within anchorR (default 3.5m)
        -- unless climbing a ladder / jumping a ledge / riding an elevator (|dy| > 1.6m)!
        if (adx * adx + adz * adz) <= (anchorR * anchorR) and ady <= 1.6 then
            return host
        end
        StateChecks.anchorActive = false
        HostLastActiveTime = now
        ScavengeStreak = {}
        return host
    end

    if moved or Osi.IsMoving(host) == 1 then
        StateChecks.anchorActive = false
        HostLastActiveTime = now
        ScavengeStreak = {}
    elseif Config.AllowGrouped and anchorR > 0 then
        local requiredMs = (Config.GroupedIdleDelay or 6) * 1000
        if (now - HostLastActiveTime) >= requiredMs then
            StateChecks.anchorActive = true
            StateChecks.anchorX = hx
            StateChecks.anchorY = hy
            StateChecks.anchorZ = hz
        end
    end

    return host
end

local function EnsureWakeOffsetsRolled(host)
    if WakeOffsetsStopStamp == HostLastActiveTime then return end
    WakeOffsetsStopStamp = HostLastActiveTime
    CompanionWakeOffsets = {}

    local comps = {}
    for _, c in ipairs(GetPartyCompanions()) do
        if not SameEntity(c, host) then
            table.insert(comps, CleanUuid(c) or c)
        end
    end
    -- Randomize who wakes up 1st, 2nd, 3rd every time the party stops!
    for i = #comps, 2, -1 do
        local j = math.random(i)
        comps[i], comps[j] = comps[j], comps[i]
    end
    for idx, key in ipairs(comps) do
        if idx == 1 then
            CompanionWakeOffsets[key] = math.random(0, 300)     -- 04.3.13: was 200..1200
        elseif idx == 2 then
            CompanionWakeOffsets[key] = math.random(400, 800)   -- 04.3.13: was 2200..4300
        elseif idx == 3 then
            CompanionWakeOffsets[key] = math.random(800, 1300)  -- 04.3.13: was 4600..7400
        else
            CompanionWakeOffsets[key] = (idx - 1) * 500 + math.random(0, 300)  -- 04.3.13
        end
    end
end

function StateChecks.isGroupedAllowedNow(now)
    if not Config.AllowGrouped then return false end
    local requiredMs = (Config.GroupedIdleDelay or 6) * 1000
    return (now - HostLastActiveTime) >= requiredMs
end

function StateChecks.isReadyForNewTask(character, host, now)
    if Osi.IsMoving(character) == 1 then
        return false
    end
    if not StateChecks.canCompanionAct(character, host, now) then
        return false
    end
    local key = CleanUuid(character) or character
    if now < (CompanionRestUntil[key] or 0) then
        return false
    end
    if StateChecks.isGrouped(character, host) then
        EnsureWakeOffsetsRolled(host)
        local requiredMs = (Config.GroupedIdleDelay or 6) * 1000 + (CompanionWakeOffsets[key] or 0)
        if (now - HostLastActiveTime) < requiredMs then
            return false
        end
    end
    return true
end

function StateChecks.canCompanionAct(character, host, now)
    if not character or not host then return false end
    if SameEntity(character, host) then return false end
    if Osi.IsControlled(character) == 1 then return false end
    if Osi.IsInCombat(character) == 1 or Osi.IsInCombat(host) == 1 then return false end
    if IsAnyDialogActive() or IsCharacterInDialog(character) or IsCharacterSpeakingBark(character) then return false end
    if IsPolymorphedOrIncapacitated(character) then return false end
    if IsSneakingOrInvisible(character) or IsSneakingOrInvisible(host) then return false end
    if IsInTurnBased(character) or IsInTurnBased(host) then return false end
    -- Don't hijack a companion who is themselves playing an instrument!
    if ActivePerformers[character] or ActivePerformers[CleanUuid(character)] then return false end

    if StateChecks.isGrouped(character, host) then
        if not StateChecks.isGroupedAllowedNow(now) then
            return false
        end
    end
    return true
end

function StateChecks.isIdle(character)
    if Osi.IsMoving(character) == 1 then return false end
    local host = Osi.GetHostCharacter and Osi.GetHostCharacter() or nil
    return StateChecks.canCompanionAct(character, host, Ext.Utils.MonotonicTime())
end

local function IsMusicStatus(status)
    if type(status) ~= "string" then return false end
    return string.find(status, "PERFORM_", 1, true) == 1
        or string.find(status, "BARD_PERFORM", 1, true) ~= nil
        or status == "PERFORM"
end

local function IsEntityStillPerforming(uuid)
    if not uuid then return false end
    if ActivePerformers[uuid] and ActivePerformers[uuid] > 0 then
        local ok, alive = pcall(function()
            if Osi.Exists and Osi.Exists(uuid) == 0 then return false end
            if Osi.IsDead and Osi.IsDead(uuid) == 1 then return false end
            if Osi.IsInCombat and Osi.IsInCombat(uuid) == 1 then return false end
            return true
        end)
        if ok and alive then return true end
        ActivePerformers[uuid] = nil
    end
    return false
end

local function FindNearbyBardPerformer(host, companions)
    if not Config.BardSync then return nil end

    -- Check event-tracked performers first
    for perfUuid, count in pairs(ActivePerformers) do
        if count and count > 0 and IsEntityStillPerforming(perfUuid) then
            local d = Osi.GetDistanceTo(host, perfUuid)
            if d and d <= math.max(14.0, Config.SearchRadius) then
                return perfUuid
            end
        end
    end

    -- Fallback check on party members for standard BG3 perform statuses
    for _, member in ipairs(companions) do
        local ok, playing = pcall(function()
            return Osi.HasActiveStatus(member, "PERFORM_POSITIVE") == 1
                or Osi.HasActiveStatus(member, "PERFORM_NEGATIVE") == 1
                or Osi.HasActiveStatus(member, "PERFORM_STARPOWER") == 1
        end)
        if ok and playing then
            ActivePerformers[member] = 1
            return member
        end
    end

    return nil
end

local UserExplicitlyToggledOff = false
local LastDiagLogTime = 0

local function IsAmbientEnabled(host, partyList)
    if UserExplicitlyToggledOff then return false end
    if host and Osi.HasActiveStatus(host, "AMBIENT_AI_STATUS") == 1 then
        return true
    end
    local members = partyList or GetPartyCompanions()
    for _, m in ipairs(members) do
        if Osi.HasActiveStatus(m, "AMBIENT_AI_STATUS") == 1 then
            return true
        end
    end
    return false
end

-- ============================================================================
-- 6. ROBUST ACTION QUEUE SYSTEM
-- ============================================================================

local ActionQueue = {}
ActionQueue.__index = ActionQueue

function ActionQueue:new(character)
    local instance = {
        character = character,
        queue = {},
        currentAction = nil,
        currentTarget = nil,
        activityTag = nil,
        isProcessing = false,
        playingCustomAnim = false,
        pollInterval = 200,
        maxRetries = 50,
        currentRetries = 0,
        timerId = nil,
    }
    setmetatable(instance, ActionQueue)
    return instance
end

function ActionQueue:shouldAbort(now)
    if not IsOsirisReady() then return true, "not_running" end
    now = now or Ext.Utils.MonotonicTime()
    local host = Osi.GetHostCharacter and Osi.GetHostCharacter() or nil
    if not host then return true, "no_host" end
    if not IsAmbientEnabled(host) then return true, "toggled_off" end
    if IsAnyDialogActive() or IsCharacterInDialog(self.character) then return true, "dialog" end
    if Osi.IsInCombat(self.character) == 1 or Osi.IsInCombat(host) == 1 then return true, "combat" end
    if SameEntity(self.character, host) or Osi.IsControlled(self.character) == 1 then return true, "controlled" end
    if IsPolymorphedOrIncapacitated(self.character) then return true, "incapacitated" end
    if IsSneakingOrInvisible(self.character) or IsSneakingOrInvisible(host) then return true, "stealth" end
    if IsInTurnBased(self.character) or IsInTurnBased(host) then return true, "turn_based" end
    if ActivePerformers[self.character] or ActivePerformers[CleanUuid(self.character)] then
        return true, "self_performing"
    end

    if StateChecks.isGrouped(self.character, host) and not StateChecks.isGroupedAllowedNow(now) then
        return true, "grouped_active"
    end

    return false, nil
end

function ActionQueue:abort(reason)
    if ConfigValues.Debug then
        Log(tostring(self.character) .. " aborting sequence (" .. tostring(reason or "abort") .. ").")
    end

    if self.timerId then
        local tid = self.timerId
        self.timerId = nil
        pcall(Ext.Timer.Cancel, tid)
    end

    local abortedAction = self.currentAction
    local abortedTag = self.activityTag
    local abortedTarget = self.currentTarget
    local abortedClusters = self.clusterTargets
    local wasCustomAnim = self.playingCustomAnim
    self.queue = {}
    self.currentAction = nil
    self.currentTarget = nil
    self.clusterTargets = nil
    self.activityTag = nil
    self.isProcessing = false
    self.playingCustomAnim = false

    -- If interrupted while still walking to the prop (before actually sitting/lighting/admiring),
    -- release the dispatch cooldown (< 900s) while keeping 30-min (1800s) unreachable-navmesh blacklists!
    local abortedName = abortedAction and tostring(abortedAction.name or "") or ""
    if (string.find(abortedName, "^Walk") or string.find(abortedName, "^GoTo")) and Ext and Ext.Utils then
        local tNow = Ext.Utils.MonotonicTime()
        -- 04.3.8: do not wipe a "could not reach this seat" mark when the walk was aborted for an
        -- unrelated reason - that is how the party kept re-trying a bench nobody could path to.
        local function keepBlacklist(u)
            return (AmbientSeat and AmbientSeat.hardBlacklist and AmbientSeat.hardBlacklist[u]) == true
        end
        if abortedTarget and Blacklist[abortedTarget] and (Blacklist[abortedTarget] - tNow) < 900000
            and not keepBlacklist(abortedTarget) then
            Blacklist[abortedTarget] = nil
        end
        if abortedClusters then
            for _, cu in ipairs(abortedClusters) do
                if Blacklist[cu] and (Blacklist[cu] - tNow) < 900000 and not keepBlacklist(cu) then
                    Blacklist[cu] = nil
                end
            end
        end
    end

    -- Never touch Osi.* during session/level transitions when Osiris is not running
    if not IsOsirisReady() or reason == "not_running" or reason == "level_reset" then
        return
    end

    if abortedAction and abortedAction.onAbort then
        pcall(abortedAction.onAbort, self.character)
    end

    local isUrgentCut = (reason == "combat" or reason == "turn_based" or reason == "trap_spotted" or reason == "dialog" or reason == "toggled_off" or reason == "manual_unstick")

    -- Purge Osiris tasks so BG3's native Anubis party-follow AI regains control cleanly,
    -- while using abort=0 graceful animation blend-out on normal movement/idle transitions!
    if abortedTag == "chair" or abortedTag == "bed" then
        -- Build 04.3.5: stand up FIRST (follow block held), release it afterwards.
        -- Releasing first is what made seated companions teleport to the player.
        Log(string.format("[SEAT] %s abort (%s) -> standing up before following",
            AmbientSeat.seatName(self.character), tostring(reason or "abort")))
        StandUpFromFurniture(self.character)
        if isUrgentCut then
            SetSeatFollowFlagRaw(self.character, false)
        end
    else
        SetAmbientSeatFollowLock(self.character, false)
        if isUrgentCut or (wasCustomAnim and not IsCharacterSpeakingBark(self.character)) then
            StopCustomAnimation(self.character, not isUrgentCut)
        end
        PurgeCharacterOsiris(self.character)
    end
end

function ActionQueue:enqueue(action)
    table.insert(self.queue, action)
    if not self.isProcessing then
        self.isProcessing = true
        self.timerId = Ext.Timer.WaitFor(16, function()
            self:processNext()
        end)
    end
end

-- 04.3.9: BG3SE warns about a single timer callback taking hundreds of ms
-- ("Dispatching user function call ... took 846.76 ms"). Measure the poll phases so the
-- next log says exactly which part is slow instead of guessing.
-- 04.3.11: declared BEFORE processNext/executeWithGuard, which now call it as well (a local
-- declared further down would silently resolve to a nil global inside timer callbacks).
ActionQueue.stats = ActionQueue.stats or { slow = 0, worst = 0, worstPhase = "-" }
-- 04.3.19: per-step console logging can be muted at runtime (!ambient_quiet).
ActionQueue.quietSteps = ActionQueue.quietSteps or false

local function TickPhase(t0, phase, actionName)
    local dt = Ext.Utils.MonotonicTime() - t0
    local key = tostring(phase)
    ActionQueue.stats.byPhase = ActionQueue.stats.byPhase or {}
    local row = ActionQueue.stats.byPhase[key]
    if not row then
        row = { worst = 0, n = 0 }
        ActionQueue.stats.byPhase[key] = row
    end
    if dt > row.worst then row.worst = dt end
    if dt >= 40 then row.n = row.n + 1 end
    -- 04.3.19: aggregate per kind as well, so a 30+ row per-action table collapses into
    -- ~10 rows and a quiet phase can no longer fall off the printed list.
    local kind = string.match(key, "^[^%(]+") or key
    ActionQueue.stats.byKind = ActionQueue.stats.byKind or {}
    local krow = ActionQueue.stats.byKind[kind]
    if not krow then
        krow = { worst = 0, n = 0, sum = 0, count = 0 }
        ActionQueue.stats.byKind[kind] = krow
    end
    if dt > krow.worst then krow.worst = dt end
    if dt >= 40 then krow.n = krow.n + 1 end
    krow.sum = krow.sum + dt
    krow.count = krow.count + 1
    if dt >= 120 then
        ActionQueue.stats.slow = ActionQueue.stats.slow + 1
        if dt > (ActionQueue.stats.worst or 0) then
            ActionQueue.stats.worst = dt
            ActionQueue.stats.worstPhase = phase
        end
        -- 04.3.20: rate-limit this line. Printing it inline on every slow phase turns a slow
        -- console into a feedback loop (the print itself makes the next phase slower).
        local nowMs = Ext.Utils.MonotonicTime()
        ActionQueue.perfLog = ActionQueue.perfLog or { last = 0, skipped = 0 }
        if (nowMs - ActionQueue.perfLog.last) >= 3000 then
            ActionQueue.perfLog.last = nowMs
            local full = string.format("[PERF] slow queue tick: %s took %dms (action=%s, slowTicks=%d, %d more suppressed)",
                tostring(phase), math.floor(dt), tostring(actionName or "-"), ActionQueue.stats.slow,
                ActionQueue.perfLog.skipped)
            -- also deferred: printing this inline made a slow console inflate the very tick it reports
            if ActionQueue.queueStepLog then
                ActionQueue.queueStepLog(full)
            else
                Log(full)
            end
            ActionQueue.perfLog.skipped = 0
        else
            ActionQueue.perfLog.skipped = ActionQueue.perfLog.skipped + 1
        end
    end
    return dt
end

-- 04.3.20: the per-step "started: <action>" line used to be printed INLINE in the queue tick.
-- In game that single Ext.Utils.Print costs 34 ms on average and up to 3.9 s, freezing the
-- companion mid-action. Now the tick only enqueues the string; a separate timer drains it.
ActionQueue.stepLog = ActionQueue.stepLog or { queue = {}, size = 0, timerId = nil, perSlice = 4,
                                               lastCostMs = 0, warned = false, dropped = 0 }
-- 04.3.21: a console can be catastrophically slow (831 ms per line, 11 s per flush in the
-- field). Keep a ring buffer of the lines, bound every flush in wall-clock time, and mute
-- ourselves automatically instead of freezing the game.
ActionQueue.stepBudgetMs = ActionQueue.stepBudgetMs or 120
ActionQueue.stepAutoQuietMs = ActionQueue.stepAutoQuietMs or 200
ActionQueue.stepRing = ActionQueue.stepRing or { lines = {}, size = 0, max = 60 }
ActionQueue.stepSuppressed = ActionQueue.stepSuppressed or 0
-- 04.3.22: Debug stays usable on a slow console - filter step lines by action-name substring.
ActionQueue.stepFilter = ActionQueue.stepFilter or nil
ActionQueue.stepsEnqueued = ActionQueue.stepsEnqueued or 0
ActionQueue.stepsFilteredOut = ActionQueue.stepsFilteredOut or 0

function ActionQueue.rememberStep(line)
    local ring = ActionQueue.stepRing
    ring.lines[#ring.lines + 1] = tostring(line)
    while #ring.lines > ring.max do table.remove(ring.lines, 1) end
    ring.size = #ring.lines
end

function ActionQueue.queueStepLog(line)
    local log = ActionQueue.stepLog
    -- 04.3.22: a filter makes Debug affordable (and the log readable): count, don't print.
    local filter = ActionQueue.stepFilter
    if filter and not string.find(string.lower(tostring(line)), filter, 1, true) then
        ActionQueue.stepsFilteredOut = ActionQueue.stepsFilteredOut + 1
        ActionQueue.rememberStep(line)
        return
    end
    ActionQueue.stepsEnqueued = ActionQueue.stepsEnqueued + 1
    log.size = log.size + 1
    if log.size > 400 then           -- hard cap: never let the queue grow unbounded
        log.dropped = log.dropped + 1
        return
    end
    log.queue[#log.queue + 1] = line
    ActionQueue.rememberStep(line)
    if ActionQueue.quietSteps then ActionQueue.stepSuppressed = ActionQueue.stepSuppressed + 1 end
    if log.timerId == nil and Ext and Ext.Timer and Ext.Timer.WaitFor then
        log.timerId = Ext.Timer.WaitFor(80, ActionQueue.drainStepLog)
    end
end

function ActionQueue.drainStepLog()
    local log = ActionQueue.stepLog
    log.timerId = nil
    local t0 = Ext.Utils.MonotonicTime()
    local n = 0
    while #log.queue > 0 and n < (log.perSlice or 4) do
        local line = table.remove(log.queue, 1)
        log.size = log.size - 1
        if ConfigValues.Debug then
            Ext.Utils.Print("[AmbientAI] " .. tostring(line))
        end
        n = n + 1
        -- 04.3.21: never spend more than the budget in one callback, even if the console
        -- crawls; the rest of the queue waits for the next slice.
        if (Ext.Utils.MonotonicTime() - t0) > (ActionQueue.stepBudgetMs or 120) then
            break
        end
    end
    local dt = TickPhase(t0, "log-flush", "step-log")
    -- a single line slower than 200 ms makes every future flush a freeze -> mute ourselves
    if n > 0 and (dt / n) > (ActionQueue.stepAutoQuietMs or 200) and not ActionQueue.quietSteps then
        ActionQueue.quietSteps = true
        ActionQueue.stepLog.warned = true
        log.queue = {}
        log.size = 0
        if log.timerId then
            local tid = log.timerId
            log.timerId = nil
            pcall(Ext.Timer.Cancel, tid)
        end
        Ext.Utils.Print(string.format(
            "[AmbientAI] console write costs %.0f ms per line - per-step logging switched OFF automatically "
            .. "(the last %d lines are kept in memory: !ambient_steps). Gameplay is unaffected.",
            dt / n, ActionQueue.stepRing.size))
        return
    end
    if n > 0 then
        log.lastCostMs = dt / n
        -- a console that slow must not eat the frame budget: one line per slice, warn once
        if dt > 100 and (log.perSlice or 4) > 1 then
            log.perSlice = 1
            if not log.warned then
                log.warned = true
                Ext.Utils.Print(string.format(
                    "[AmbientAI] console I/O is slow (%.0f ms per line) - step logging throttled to 1 line/slice. Use !ambient_quiet to mute it entirely.",
                    dt / n))
            end
        elseif dt < 8 and (log.perSlice or 1) < 4 then
            log.perSlice = math.min(4, (log.perSlice or 1) + 1)
        end
    end
    if log.dropped > 0 then
        Ext.Utils.Print(string.format("[AmbientAI] step log: %d line(s) dropped (queue cap)", log.dropped))
        log.dropped = 0
    end
    if #log.queue > 0 and Ext and Ext.Timer and Ext.Timer.WaitFor then
        -- 04.3.21: on a slow console give the engine room between slices
        local delay = ((log.lastCostMs or 0) > 50) and 500 or 80
        log.timerId = Ext.Timer.WaitFor(delay, ActionQueue.drainStepLog)
    end
end

function ActionQueue.flushStepLog(count)
    local log = ActionQueue.stepLog
    local n = 0
    while #log.queue > 0 and n < (count or 200) do
        local line = table.remove(log.queue, 1)
        log.size = log.size - 1
        if ConfigValues.Debug then
            Ext.Utils.Print("[AmbientAI] " .. tostring(line))
        end
        n = n + 1
    end
    return n
end

function ActionQueue:processNext()
    if #self.queue == 0 then
        self.isProcessing = false
        self.currentAction = nil
        self.currentTarget = nil
        self.clusterTargets = nil
        self.activityTag = nil
        SetAmbientSeatFollowLock(self.character, false)
        -- Natural human breather (2.2s - 5.6s) after finishing any sequence so companions never look robotic
        local key = CleanUuid(self.character) or self.character
        CompanionRestUntil[key] = Ext.Utils.MonotonicTime() + math.random(2200, 5600)
        return
    end
    self.isProcessing = true
    self.currentAction = table.remove(self.queue, 1)
    self.currentRetries = 0
    -- Hold temporary PartyBlockFollowComponent (SetNoFollowFlag = 1) while executing any
    -- multi-step off-leash sequence so BG3's DefaultPartyMember (PauseFollow = 200ms) never
    -- yanks grouped companions back toward the Host mid-turn (TurnToSconce / LightIt /
    -- SeatTiredRemark / AdmireArt / Inspect). Automatically released on empty queue,
    -- StandUp/WakeUp dismount, ActionQueue:abort(), !ambient_unstick, and reload!
    local stepName = self.currentAction and self.currentAction.name or ""
    local stepNameForPerf = self.currentAction.name
    -- 04.3.19: engine call, previously unprofiled
    local tLock = Ext.Utils.MonotonicTime()
    if self.activityTag ~= nil and stepName ~= "StandUp" and stepName ~= "WakeUp" then
        SetAmbientSeatFollowLock(self.character, true)
    end
    TickPhase(tLock, "follow-lock(" .. tostring(stepNameForPerf) .. ")", stepNameForPerf)
    -- 04.3.20: enqueue only - the actual console write happens in ActionQueue.drainStepLog
    -- (34 ms per line inline was freezing companions mid-action).
    if stepNameForPerf and ConfigValues.Debug and not ActionQueue.quietSteps then
        local tLog = Ext.Utils.MonotonicTime()
        ActionQueue.queueStepLog(tostring(self.character) .. " started: " .. tostring(stepNameForPerf))
        TickPhase(tLog, "log-enqueue(" .. tostring(stepNameForPerf) .. ")", stepNameForPerf)
    end
    -- 04.3.11: the body of an action is where the engine calls live (CharacterMoveToPosition,
    -- SitOnEntity, Use, ToInventory, FindValidPosition...). Measure it too.
    local tBody = Ext.Utils.MonotonicTime()
    self:executeWithGuard()
    TickPhase(tBody, "body(" .. tostring(stepNameForPerf) .. ")", stepNameForPerf)
end

-- 04.3.19: wrap the whole tick. BG3SE reports "Dispatching user function call
-- (BootstrapServer.lua:<line>) took N ms" for this callback; whatever is NOT inside one
-- of the profiled phases (GC, engine stalls, console I/O, timer scheduling) shows up here.
local _processNextInner = ActionQueue.processNext
function ActionQueue:processNext()
    local tWhole = Ext.Utils.MonotonicTime()
    local ok, err = pcall(_processNextInner, self)
    TickPhase(tWhole, "tick-total", self.currentAction and self.currentAction.name)
    if not ok then error(err) end
end

function ActionQueue:executeWithGuard()
    self.timerId = nil
    local tStart = Ext.Utils.MonotonicTime()
    local abortNow, reason = self:shouldAbort()
    -- 04.3.19: the abort gate runs ~15 engine queries on every poll tick and used to be
    -- invisible in the profile.
    TickPhase(tStart, "shouldAbort-next", self.currentAction and self.currentAction.name)
    if abortNow then
        self:abort(reason)
        return
    end

    local action = self.currentAction
    if not action then
        self:processNext()
        return
    end
    TickPhase(tStart, "start-prep(" .. tostring(action.name) .. ")", action.name)

    if action.precondition then
        local preOk, preRes = pcall(action.precondition, self.character)
        if not preOk or not preRes then
            if self.currentRetries < self.maxRetries then
                self.currentRetries = self.currentRetries + 1
                self.timerId = Ext.Timer.WaitFor(self.pollInterval, function()
                    self:executeWithGuard()
                end)
                return
            else
                if action.onTimeout then pcall(action.onTimeout, self.character) end
                self:processNext()
                return
            end
        end
    end

    if action.customAnim then
        self.playingCustomAnim = true
    end

    if action.execute then
        local tExec = Ext.Utils.MonotonicTime()
        local ok, err = pcall(action.execute, self.character)
        TickPhase(tExec, "execute(" .. tostring(action.name) .. ")", action.name)
        if not ok then
            Log("ERROR executing " .. tostring(action.name or "Unknown") .. ": " .. tostring(err))
            if action.onAbort then pcall(action.onAbort, self.character) end
            self:processNext()
            return
        end
    end

    if action.duration and not action.startTime then
        action.startTime = Ext.Utils.MonotonicTime()
    end
    self.timerId = Ext.Timer.WaitFor(60, function()
        self:waitForCompletion()
    end)
end

-- 04.3.11: actions that are SUPPOSED to stand still. Sitting is one of them: the companion stops at
-- the approach point and the repose blends, so "no movement for 2.8s" is the normal state, not a
-- stuck path. The watchdog used to treat it as a stall - the bench was blacklisted for 30 MINUTES,
-- the character was purged and the queue emptied (i.e. exactly "не сел, и скамья теперь плохая").
local STALL_WATCHDOG_EXEMPT = {
    SitOnSeat = true,
}

function ActionQueue:waitForCompletion()
    self.timerId = nil
    local tPhase = Ext.Utils.MonotonicTime()
    local abortNow, reason = self:shouldAbort()
    TickPhase(tPhase, "shouldAbort", self.currentAction and self.currentAction.name)
    if abortNow then
        self:abort(reason)
        return
    end

    local action = self.currentAction
    if not action then
        self:processNext()
        return
    end

    if action.onTick then
        pcall(action.onTick, self.character)
    end

    if action.duration then
        local now = Ext.Utils.MonotonicTime()
        if not action.startTime then action.startTime = now end
        local earlyDone = false
        local tComp = Ext.Utils.MonotonicTime()
        if action.completion then
            local cOk, cRes = pcall(action.completion, self.character)
            if cOk and cRes then earlyDone = true end
        end
        -- 04.3.11: measure the completion EVERY time (it used to be measured only while the action
        -- kept running), otherwise a slow completion that finished the action stayed invisible.
        TickPhase(tComp, "completion(" .. tostring(action.name) .. ")", action.name)
        if not earlyDone and (now - action.startTime < action.duration) then
            self.timerId = Ext.Timer.WaitFor(200, function()
                self:waitForCompletion()
            end)
            return
        else
            if action.customAnim then
                self.playingCustomAnim = false
            end
            if not earlyDone and action.completion and action.onTimeout then
                local tTo = Ext.Utils.MonotonicTime()
                pcall(action.onTimeout, self.character)
                TickPhase(tTo, "onTimeout(" .. tostring(action.name) .. ")", action.name)
            elseif action.onComplete then
                local tOc = Ext.Utils.MonotonicTime()
                pcall(action.onComplete, self.character)
                TickPhase(tOc, "onComplete(" .. tostring(action.name) .. ")", action.name)
            end
            local tNext = Ext.Utils.MonotonicTime()
            self:processNext()
            TickPhase(tNext, "next-after(" .. tostring(action.name) .. ")", action.name)
            return
        end
    end

    if not action.completion then
        local tNoComp = Ext.Utils.MonotonicTime()
        if action.onComplete then pcall(action.onComplete, self.character) end
        self:processNext()
        TickPhase(tNoComp, "no-completion(" .. tostring(action.name) .. ") next", action.name)
        return
    end

    local compOk, compRes = pcall(action.completion, self.character)
    TickPhase(tPhase, "completion(" .. tostring(action.name) .. ")", action.name)
    if compOk and compRes then
        if action.onComplete then pcall(action.onComplete, self.character) end
        self:processNext()
    else
        -- Movement Stall Watchdog: if companion fails to make >0.18m progress for 2.8s (e.g. blocked by cart/NPC),
        -- purge Osiris immediately instead of staying stuck against obstacle!
        local now = Ext.Utils.MonotonicTime()
        local cx, _, cz = Osi.GetPosition(self.character)
        if cx then
            if not action._lastX then
                action._lastX = cx
                action._lastZ = cz
                action._lastMoveMs = now
            else
                local mdx = cx - action._lastX
                local mdz = cz - action._lastZ
                if (mdx * mdx + mdz * mdz) > 0.0324 then
                    action._lastX = cx
                    action._lastZ = cz
                    action._lastMoveMs = now
                elseif (now - action._lastMoveMs) >= 2800
                    and not STALL_WATCHDOG_EXEMPT[action.name] then
                    TickPhase(tPhase, "stall-watchdog(" .. tostring(action.name) .. ")", action.name)
                    local isLightSeq = (self.activityTag == "light")
                    local cd = isLightSeq and LIGHT_TARGET_COOLDOWN or 1800000
                    if self.currentTarget then
                        Blacklist[self.currentTarget] = now + cd
                    end
                    if isLightSeq then
                        local okR, hD, vD = LightTrace.metrics(self.character, self.currentTarget)
                        LightTrace.line("stall", "%s made no progress for 2.8s during '%s' -> %s (dist=%.2f dy=%.2f, cooldown %ds)",
                            tostring(self.character), tostring(action.name),
                            tostring(LightTrace.tpl(self.currentTarget or "")),
                            okR and hD or -1, okR and vD or -1, math.floor(cd / 1000))
                    end
                    PurgeCharacterOsiris(self.character)
                    self.queue = {}
                    self:processNext()
                    return
                end
            end
        end

        if self.currentRetries < self.maxRetries then
            self.currentRetries = self.currentRetries + 1
            self.timerId = Ext.Timer.WaitFor(self.pollInterval, function()
                self:waitForCompletion()
            end)
        else
            if self.currentTarget then
                Blacklist[self.currentTarget] = Ext.Utils.MonotonicTime() + 1800000
            end
            if action.onTimeout then pcall(action.onTimeout, self.character) end
            PurgeCharacterOsiris(self.character)
            self:processNext()
        end
    end
end

local function AbortAllQueues(reason)
    for _, q in pairs(ActiveQueues) do
        if q.isProcessing then
            q:abort(reason)
        end
    end
end

-- ============================================================================
-- 6B. BUILD 03.3: NATIVE COMPANION ACTION & ROLEPLAY VOICE ENGINE
-- ============================================================================

local EMPTY_GUID = "00000000-0000-0000-0000-000000000000"

local TARGET_VOCAL_EVENTS = {
    BGClickReaction_Action_InteractWith          = true,
    BGClickReaction_Action_OpenContainer         = true,
    BGClickReaction_Action_ItemPickup            = true,
    BGClickReaction_RelationPrototype_Rest       = true,
    BGClickReaction_Action_SpeakTo               = true,
    BGClickReaction_RelationPrototype_SetPositive = true,
    BGClickReaction_ReptAction_PortraitClick     = true,
    BGClickReaction_Action_Attack                = true,
    BGClickReaction_Action_Utility               = true,
    BGClickReaction_Action_OpenLock              = true,
}
local TARGET_VOCAL_EVENT_TOTAL = 10

local function StepVocalResourceCache(maxBudget)
    if VocalResourceCache.complete then return end
    if not Ext or not Ext.Resource or not Ext.Resource.GetAll or not Ext.Resource.Get then
        VocalResourceCache.complete = true
        return
    end

    local okInit = true
    if not VocalResourceCache.handles then
        local okAll, list = pcall(Ext.Resource.GetAll, "Sound")
        if not okAll or type(list) ~= "table" or #list == 0 then
            VocalResourceCache.complete = true
            return
        end
        VocalResourceCache.handles = list
        VocalResourceCache.cursor = 1
        VocalResourceCache.total = #list
    end

    local budget = maxBudget or 450
    local handles = VocalResourceCache.handles
    local total = VocalResourceCache.total
    local stopIdx = math.min(total, VocalResourceCache.cursor + budget - 1)

    pcall(function()
        for idx = VocalResourceCache.cursor, stopIdx do
            local resGuid = handles[idx]
            if resGuid then
                local res = Ext.Resource.Get(resGuid, "Sound")
                if res and res.SoundEvent then
                    local ev = tostring(res.SoundEvent)
                    if TARGET_VOCAL_EVENTS[ev] then
                        local src = (res.SourceFile and tostring(res.SourceFile)) or ""
                        local isVocalsPkg = string.find(src, "Vocal", 1, true) ~= nil
                        if not VocalResourceCache.byEvent[ev] or isVocalsPkg then
                            local g = (res.Guid and tostring(res.Guid)) or tostring(resGuid)
                            if g ~= "" and g ~= EMPTY_GUID then
                                if not VocalResourceCache.byEvent[ev] then
                                    VocalResourceCache.matched = VocalResourceCache.matched + 1
                                end
                                VocalResourceCache.byEvent[ev] = g
                                if VocalResourceCache.matched >= TARGET_VOCAL_EVENT_TOTAL and isVocalsPkg then
                                    VocalResourceCache.complete = true
                                    VocalResourceCache.handles = nil
                                    Log("VocalResourceCache indexed all " .. tostring(VocalResourceCache.matched) .. " BGClickReaction SoundResources.")
                                    return
                                end
                            end
                        end
                    end
                end
            end
        end
    end)

    if not VocalResourceCache.complete then
        if stopIdx >= total or not okInit then
            VocalResourceCache.complete = true
            VocalResourceCache.handles = nil
            Log("VocalResourceCache sweep completed (matched=" .. tostring(VocalResourceCache.matched) .. ").")
        else
            VocalResourceCache.cursor = stopIdx + 1
        end
    end
end

local AmbientVoice = {}   -- Build 04.3.7: voice health context + self-driven chatter tick
local ACTION_VOICE_PROFILES
local TryTriggerWorldPartyBanter
local TryPlayCompanionActionVoice

do
    -- Scoped inside `do ... end` to keep Lua 5.4 top-level local register count well below 200!
    -- Full Osiris DIALOGRESOURCE identifiers ("Name_<uuid>") — bare UUIDs fail COsiStringTable lookup
    -- unless pre-interned! Every PAD below is verified automated=True, checkflags=empty, setflags=empty.
    local PAD_PERCEPTION    = { id = "GLO_PerceptionSuccess_48825dbe-a320-7c4c-fe3e-372b717d5bc9",               timeline = false }
    local PAD_INVESTIGATION = { id = "GLO_InvestigationSuccess_6f56969d-fb35-38f1-26ff-5b6c4db3ea68",            timeline = true  }
    local PAD_CRATE_EMPTY   = { id = "GLO_PAD_Crate_Wood_Open_Interact_8f1099dc-16ec-1f96-6959-7666c804aa8f",    timeline = true  }
    -- 04.3.7: restHint pads talk about being tired / resting. They are dropped from the
    -- candidate list unless the party oracle says there is a reason (HP or spell slots).
    local PAD_REST_TIRED    = { id = "CAMP_RestReminder_PAD_c08e3366-ac86-586a-2065-59317be3e012",               timeline = true, restHint = true }
    local PAD_REST_RESPITE  = { id = "GLO_PAD_PartyCommentsAfterShortRest_d08505e7-9c2d-7fc4-95ab-1a340692ac84", timeline = true, restHint = true }
    local PAD_MIRROR_CLEAN  = { id = "GEN_PAD_Mirror_57a87d95-5303-e7d9-2ec2-b40ec8f90f72",                      timeline = true  }
    local PAD_TELESCOPE     = { id = "GLO_Telescope_PAD_54d193f6-92c6-cc15-637d-2819ac6405f2",                   timeline = true  }
    local PAD_GLOBE         = { id = "GLO_WorldGlobe_B_PAD_b225e148-3102-affe-7983-5fafa7b80a51",                timeline = true  }
    local PAD_STUFFED_BEAR  = { id = "GLO_StuffedBear_Standing_PAD_5f6978f6-e6a0-6e56-3774-bd0234c69bda",        timeline = true  }
    local PAD_TRAP_PERC     = { id = "GLO_PerceptionSuccess_Trap_8aae78c8-a937-e386-0a0e-66e1046e8577",          timeline = false }
    local PAD_TRAP_INV      = { id = "GLO_InvestigationSuccess_Trap_174f5c13-764b-26f6-83cd-4ea72b50abd9",       timeline = true  }
    local PAD_SH_CALL_PET   = { id = "CAMP_Shadowheart_PAD_CallPet_8c951c6b-bb62-09f4-8fab-937300799d70",        timeline = true, onlyComp = COMP.Shadowheart }

    local SND_VOCAL_LAUGHTER = "2b3255d8-a94d-4ae7-8915-c7236d275543" -- Player_Races_Voice_Gen_Laughter
    local SND_VOCAL_RECOVER  = "a8d9d28d-2248-a1c0-93ae-8a0626cfcdda" -- Player_Races_Voice_Gen_Recover
    local SND_VOCAL_VICTORY  = "4733fa3b-43d1-977b-ad32-611e0408d2ad" -- Player_Races_Voice_Gen_Victory
    local SND_VOCAL_EFFORTS  = "14319f88-14a1-844d-a200-a90cd778262c" -- Player_Races_Voice_Gen_ClosedMouthEfforts

    -- ========================================================================
    -- 04.3.7 VOICE HEALTH - party rest-state oracle
    --   Companions used to complain "I am tired / we should rest" while the party
    --   sat at 100% HP with every spell slot full. Now that line is only allowed
    --   when the party actually looks spent (and then it doubles as a soft hint).
    --   Read-only, cached for 1.5 s, every engine call behind pcall.
    -- ========================================================================
    local VC = {
        at = -999999, ttl = 1500,
        minHp = 100, avgHp = 100, lowHp = 0, criticalHp = 0, worst = nil,
        slotsUsed = 0, slotsMax = 0, slotsKnown = false, slotsPct = 0, slotsSrc = "none",
        restsLeft = 0, needsRest = false, fresh = true, reason = "no_data",
        baseline = {}, dump = {},
    }
    AmbientVoice.context = VC

    local SLOT_RESOURCES = { "SpellSlot", "WarlockSpellSlot", "ShadowSpellSlot" }

    local function SlotNameLooksLikeSpellSlot(name)
        if not name then return false end
        local low = string.lower(tostring(name))
        if string.find(low, "stunted", 1, true) then return false end
        return string.find(low, "spellslot", 1, true) ~= nil
            or string.find(low, "spell_slot", 1, true) ~= nil
    end

    -- Leveled action-resource entries (Amount / MaxAmount / Level) straight from the entity.
    -- BG3SE does not always expose a human readable resource name, so we also collect
    -- unnamed entries and pair them with Osiris values by level + amount below.
    local function CollectLeveledResources(char)
        local out = {}
        local ok = pcall(function()
            local e = Ext.Entity.Get(char)
            local ar = e and e.ActionResources
            local tbl = ar and (ar.Resources or ar.ActionResources)
            if type(tbl) ~= "table" then return end
            for key, val in pairs(tbl) do
                local entries = {}
                if type(val) == "table" then
                    if type(val.Amount) == "number" then
                        entries[1] = val
                    else
                        for _, v in pairs(val) do
                            if type(v) == "table" and type(v.Amount) == "number" then
                                entries[#entries + 1] = v
                            end
                        end
                    end
                end
                for _, ent in ipairs(entries) do
                    local lvl = tonumber(ent.Level) or 0
                    local mx = tonumber(ent.MaxAmount) or tonumber(ent.Max) or 0
                    local am = tonumber(ent.Amount) or 0
                    local nm = ent.Name or ent.ResourceName
                        or (type(key) == "string" and key or nil)
                    if lvl >= 1 and lvl <= 6 and mx > 0 then
                        out[#out + 1] = { level = lvl, max = mx, amount = am, name = nm }
                    end
                end
            end
        end)
        if not ok then return out end
        return out
    end

    -- Layer A: named spell-slot resources (Amount + MaxAmount in the component).
    local function ScanSlotsFromEntity(char, entries)
        local used, total, known = 0, 0, 0
        for _, ent in ipairs(entries or {}) do
            if SlotNameLooksLikeSpellSlot(ent.name) then
                used = used + math.max(0, ent.max - ent.amount)
                total = total + ent.max
                known = known + 1
            end
        end
        if known > 0 then return used, total, known end
        return nil
    end

    -- Layer B: Osiris current values paired with unnamed leveled entries (level + amount match).
    local function ScanSlotsFromOsi(char, entries)
        local used, total, known = 0, 0, 0
        local unnamed = {}
        for _, ent in ipairs(entries or {}) do
            if not SlotNameLooksLikeSpellSlot(ent.name) then
                unnamed[#unnamed + 1] = ent
            end
        end
        local taken = {}
        for _, res in ipairs(SLOT_RESOURCES) do
            for lvl = 1, 6 do
                local ok, cur = pcall(Osi.GetActionResourceValuePersonal, char, res, lvl)
                if ok and type(cur) == "number" and cur >= 0 then
                    local mx = nil
                    -- one entry can only explain one resource (Warlock/Shadow/Stunted slots may
                    -- all answer with the same number when the engine aliases them)
                    for idx, ent in ipairs(unnamed) do
                        if not taken[idx] and ent.level == lvl and ent.amount == cur then
                            mx = ent.max
                            taken[idx] = true
                            break
                        end
                    end
                    if mx then
                        used = used + math.max(0, mx - cur)
                        total = total + mx
                        known = known + 1
                    end
                end
            end
        end
        if known > 0 then return used, total, known end
        return nil
    end

    -- Layer C: last resort - remember the highest value ever seen per character/level.
    -- Only used when the component is not readable at all; never reports "spent"
    -- on the very first observation (so it can not invent a reason to rest).
    local function ScanSlotsFromBaseline(char)
        local clean = CleanUuid(char) or tostring(char)
        local base = VC.baseline[clean]
        if not base then
            base = {}
            VC.baseline[clean] = base
        end
        local used, total, known = 0, 0, 0
        for _, res in ipairs(SLOT_RESOURCES) do
            for lvl = 1, 6 do
                local ok, cur = pcall(Osi.GetActionResourceValuePersonal, char, res, lvl)
                if ok and type(cur) == "number" and cur >= 0 then
                    local key = res .. "_" .. tostring(lvl)
                    if (base[key] or -1) < cur then base[key] = cur end
                    local mx = base[key] or 0
                    if mx > 0 then
                        used = used + math.max(0, mx - cur)
                        total = total + mx
                        known = known + 1
                    end
                end
            end
        end
        if known > 0 then return used, total, known end
        return nil
    end

    function VC.Refresh(now, force)
        now = now or Ext.Utils.MonotonicTime()
        if not force and (now - VC.at) < VC.ttl then return VC end
        VC.at = now

        local members = GetPartyCompanions()
        VC.minHp, VC.avgHp, VC.lowHp, VC.criticalHp, VC.worst = 100, 100, 0, 0, nil
        local sumHp, counted = 0, 0
        for _, m in ipairs(members or {}) do
            local okM, hp = pcall(function()
                if Osi.Exists(m) == 0 or Osi.IsDead(m) == 1 then return nil end
                return StateChecks.getMemberHpPercent(m)
            end)
            if okM and type(hp) == "number" then
                counted = counted + 1
                sumHp = sumHp + hp
                if hp < VC.minHp then
                    VC.minHp = hp
                    VC.worst = m
                end
                if hp <= 75 then VC.lowHp = VC.lowHp + 1 end
                if hp <= 45 then VC.criticalHp = VC.criticalHp + 1 end
            end
        end
        if counted > 0 then
            VC.avgHp = math.floor((sumHp / counted) + 0.5)
        else
            VC.minHp, VC.avgHp = 100, 100
        end

        -- Spell slots: freshest party member is enough to say "somebody still has magic".
        local usedTotal, maxTotal, knownLevels = 0, 0, 0
        local src = "none"
        for _, m in ipairs(members or {}) do
            local okM, isOk = pcall(function()
                return Osi.Exists(m) == 1 and Osi.IsDead(m) == 0
            end)
            if okM and isOk then
                local entries = CollectLeveledResources(m)
                local u, t, k = ScanSlotsFromEntity(m, entries)
                local s = "entity"
                if not u then
                    u, t, k = ScanSlotsFromOsi(m, entries)
                    s = "osi"
                end
                if not u then
                    u, t, k = ScanSlotsFromBaseline(m)
                    s = "baseline"
                end
                if u then
                    usedTotal = usedTotal + u
                    maxTotal = maxTotal + t
                    knownLevels = knownLevels + k
                    if src == "none" or s == "entity" then src = s end
                end
            end
        end
        if knownLevels > 0 and maxTotal > 0 then
            VC.slotsKnown = true
            VC.slotsUsed = usedTotal
            VC.slotsMax = maxTotal
            VC.slotsPct = math.floor((usedTotal * 100.0) / maxTotal + 0.5)
            VC.slotsSrc = src
        else
            VC.slotsKnown = false
            VC.slotsUsed, VC.slotsMax, VC.slotsPct = 0, 0, 0
            VC.slotsSrc = "none"
        end

        local host = Osi.GetHostCharacter and Osi.GetHostCharacter() or nil
        if host and StateChecks.getAvailableShortRests then
            local okR, rests = pcall(StateChecks.getAvailableShortRests, host)
            VC.restsLeft = (okR and type(rests) == "number") and rests or 0
        end

        -- "Tired enough to mention it": wounded bodies OR spent magic.
        local slotsSpent = VC.slotsKnown and VC.slotsPct >= 20
        VC.needsRest = (VC.criticalHp >= 1) or (VC.lowHp >= 1) or (VC.minHp <= 75) or slotsSpent
        -- Positive freshness: full health band and no slot spent at all.
        VC.fresh = (VC.minHp >= 90) and (not VC.slotsKnown or VC.slotsUsed == 0)

        if VC.needsRest then
            local parts = {}
            if VC.minHp <= 75 then parts[#parts + 1] = "hp=" .. tostring(VC.minHp) .. "%" end
            if slotsSpent then parts[#parts + 1] = "slots=" .. tostring(VC.slotsUsed) .. "/" .. tostring(VC.slotsMax) end
            if VC.criticalHp >= 1 then parts[#parts + 1] = "wounded=" .. tostring(VC.criticalHp) end
            VC.reason = (#parts > 0) and table.concat(parts, " ") or "tired"
        elseif VC.fresh then
            VC.reason = "fresh"
        else
            VC.reason = "neutral"
        end

        VC.dump = {
            hpMin = VC.minHp, hpAvg = VC.avgHp, low = VC.lowHp, crit = VC.criticalHp,
            slotsUsed = VC.slotsUsed, slotsMax = VC.slotsMax, slotsKnown = VC.slotsKnown,
            slotsSrc = VC.slotsSrc, rests = VC.restsLeft, needsRest = VC.needsRest,
            reason = VC.reason,
        }
        return VC
    end

    -- May a companion say "I am tired / we should rest" right now?
    local function AllowsRestTalk(now)
        local ok, vc = pcall(function() return VC.Refresh(now) end)
        if not ok or not vc then return false end
        return vc.needsRest == true
    end
    AmbientVoice.context.allowsRestTalk = AllowsRestTalk

    local function GetCharacterVocalResource(char, fieldName)
        if not char or not fieldName then return nil end
        local foundGuid = nil
        pcall(function()
            local e = Ext.Entity.Get(char)
            local sc = e and e.ServerCharacter or nil
            local roots = { sc and sc.Template or nil, sc and sc.OriginalTemplate or nil }
            for _, startTpl in ipairs(roots) do
                local tpl = startTpl
                local depth = 0
                while tpl and depth < 8 do
                    depth = depth + 1
                    local raw = tpl[fieldName]
                    if raw then
                        local s = tostring(raw)
                        if s ~= "" and s ~= EMPTY_GUID and not string.find(s, EMPTY_GUID, 1, true) then
                            foundGuid = s
                            return
                        end
                    end
                    local parentId = tpl.ParentTemplateId and tostring(tpl.ParentTemplateId) or nil
                    if parentId and parentId ~= "" and parentId ~= EMPTY_GUID and Ext.Template and Ext.Template.GetRootTemplate then
                        tpl = Ext.Template.GetRootTemplate(parentId)
                    else
                        tpl = nil
                    end
                end
            end
        end)
        return foundGuid
    end

    local function IsAnyPartyMemberSpeakingBark()
        local comps = GetPartyCompanions()
        for _, c in ipairs(comps) do
            if IsCharacterSpeakingBark(c, true) then
                return true
            end
        end
        return false
    end

    local function ResolveCuriosityPads(targetUuid, fallbackPads)
        if not targetUuid then return fallbackPads end
        local low = string.lower(GetTemplateNameSafe(targetUuid) or tostring(targetUuid) or "")
        if string.find(low, "mirror", 1, true) then
            return { PAD_MIRROR_CLEAN, PAD_PERCEPTION }
        elseif string.find(low, "telescope", 1, true) or string.find(low, "spyglass", 1, true) then
            return { PAD_TELESCOPE, PAD_INVESTIGATION }
        elseif string.find(low, "globe", 1, true) then
            return { PAD_GLOBE, PAD_INVESTIGATION }
        elseif string.find(low, "stuffedbear", 1, true) or string.find(low, "teddy", 1, true) then
            return { PAD_STUFFED_BEAR, PAD_PERCEPTION }
        end
        return fallbackPads
    end

    local function LaunchSingleOverheadPad(char, padId)
        -- Step 1: QRY_StartDialogCustom_Fixed with _AllowCrimeIntercept=0 & _AllowLowAttitudeIntercept=0
        --         (bypasses QRY_StartOverrideDialog's BusyOverride while preserving speaker availability checks!)
        if Osi.QRY_StartDialogCustom_Fixed then
            local ok1, r1 = pcall(
                Osi.QRY_StartDialogCustom_Fixed,
                padId, char, EMPTY_GUID, EMPTY_GUID, EMPTY_GUID, EMPTY_GUID, EMPTY_GUID,
                0, 0, -1, 0
            )
            if ok1 and (r1 == true or r1 == 1) then
                return true
            end
        end

        -- Step 2: Standard QRY_StartDialog_Fixed
        if Osi.QRY_StartDialog_Fixed then
            local ok2, r2 = pcall(Osi.QRY_StartDialog_Fixed, padId, char)
            if ok2 and (r2 == true or r2 == 1) then
                return true
            end
        end

        -- Step 3: Direct engine StartDialog_Internal fallback if speaker is completely free
        if Osi.StartDialog_Internal
            and not IsCharacterInDialog(char)
            and not IsCharacterSpeakingBark(char, true)
            and (not Osi.IsSpeakerReserved or Osi.IsSpeakerReserved(char) == 0)
        then
            local ok3, s3, inst3 = pcall(
                Osi.StartDialog_Internal,
                padId, 0, char, EMPTY_GUID, EMPTY_GUID, EMPTY_GUID, EMPTY_GUID, EMPTY_GUID, 1
            )
            if ok3 and (s3 == 1 or s3 == true or (type(inst3) == "number" and inst3 > 0) or IsCharacterSpeakingBark(char, true)) then
                return true
            end
        end

        return false
    end

    local function TryStartSpokenOverheadPad(char, padList, now, forceTest, noTimelinePad, allowRestTalk)
        if not padList or #padList == 0 then return false, nil end
        if IsAnyDialogActive() or IsAnyPartyMemberSpeakingBark() then return false, nil end

        local cleanChar = CleanUuid(char)
        local eligible = {}
        for i = 1, #padList do
            local entry = padList[i]
            if entry and entry.id then
                local compOk = (not entry.onlyComp) or (cleanChar == entry.onlyComp)
                local tlOk   = (not noTimelinePad) or (entry.timeline == false)
                local cdOk   = forceTest or ((ActionVoiceStats.spokenPadCooldown[entry.id] or 0) <= now)
                -- 04.3.7: "I am tired / we should rest" only when the party has a reason.
                local stateOk = true
                if entry.restHint and not allowRestTalk and not forceTest then
                    stateOk = false
                    if ConfigValues.Debug then
                        Log(string.format("[VOICE] %s skipped a rest-reminder line (%s) - party looks fresh",
                            tostring(CleanUuid(char) or char), tostring(entry.id)))
                    end
                end
                if compOk and tlOk and cdOk and stateOk then
                    -- Prefer companion-specific PADs first when matched (e.g. Shadowheart CallPet)
                    if entry.onlyComp then
                        table.insert(eligible, 1, entry)
                    else
                        eligible[#eligible + 1] = entry
                    end
                end
            end
        end
        if #eligible == 0 then return false, nil end

        -- Keep companion-exclusive PAD at index 1 if present; randomize generic entries
        local startIdx = (eligible[1] and eligible[1].onlyComp) and 1 or math.random(1, #eligible)
        for offset = 0, #eligible - 1 do
            local idx = ((startIdx + offset - 1) % #eligible) + 1
            local entry = eligible[idx]
            local padId = entry.id
            local cleanPad = CleanUuid(padId)
            RedirectGuard[padId] = now + 4500
            if cleanPad then RedirectGuard[cleanPad] = now + 4500 end
            ActionVoiceStats.ownDialogWindowUntil = now + 3500

            if LaunchSingleOverheadPad(char, padId) then
                ActionVoiceStats.spokenPadCooldown[padId] = now + 36000
                ActionVoiceStats.spokenPads = ActionVoiceStats.spokenPads + 1
                return true, padId
            end
            -- launch failed: do not keep the re-entrancy guard armed, it would mute
            -- reactive barks for the next 4.5 s for nothing
            ActionVoiceStats.padFail = (ActionVoiceStats.padFail or 0) + 1
            RedirectGuard[padId] = nil
            if cleanPad then RedirectGuard[cleanPad] = nil end
        end
        return false, nil
    end

    TryTriggerWorldPartyBanter = function(charA, charB, forceTest)
        if not Config.ActionVoices or not charA or not IsOsirisReady() then return false, nil end
        if not Osi.PROC_StartWorldGossip then return false, nil end
        if IsAnyDialogActive() or IsAnyPartyMemberSpeakingBark() then return false, nil end

        local now = Ext.Utils.MonotonicTime()
        if not forceTest then
            if now < ActionVoiceStats.nextWorldGossipTime or now < GlobalActionVoiceBusyUntil or now < GlobalReactiveBarkUntil then
                return false, nil
            end
        end

        -- Vanilla GLO_WorldGossip sets DB_BlockWorldGossip for 20s after ANY automated overhead bark;
        -- clear stale block rows when nobody in the party is currently speaking!
        if Osi.DB_BlockWorldGossip and not IsAnyPartyMemberSpeakingBark() then
            pcall(function() Osi.DB_BlockWorldGossip:Delete(nil) end)
        end

        if Osi.SetCanGossip then
            pcall(Osi.SetCanGossip, charA, 1)
            if charB then pcall(Osi.SetCanGossip, charB, 1) end
        end

        local candidates = { charA }
        if charB and not SameEntity(charA, charB) then
            candidates[#candidates + 1] = charB
        end

        for _, anchor in ipairs(candidates) do
            ActionVoiceStats.ownDialogWindowUntil = now + 4500
            -- PROC_StartWorldGossip sets DB_WorldGossip_RegionTrigger flags FIRST and then calls FindGossipWorld!
            local okStart = pcall(Osi.PROC_StartWorldGossip, anchor)
            if okStart and IsAnyPartyMemberSpeakingBark() then
                local startedDlg = (Osi.SpeakerGetDialog and Osi.SpeakerGetDialog(anchor, 1)) or "WorldPartyBanter"
                local baseCdMs = math.max(5000, (tonumber(Config.ActionVoiceCooldown) or 24) * 1000)
                ActionVoiceStats.nextWorldGossipTime = now + 110000
                GlobalActionVoiceBusyUntil = now + 9500
                NextGlobalActionVoiceTime = math.max(NextGlobalActionVoiceTime, now + baseCdMs)
                local cleanA = CleanUuid(anchor) or tostring(anchor)
                VoiceBusyUntil[cleanA] = math.max(VoiceBusyUntil[cleanA] or 0, now + 8500)
                CompanionActionVoiceCooldown[cleanA] = now + math.max(32000, math.floor(baseCdMs * 1.4))
                if charB then
                    local cleanB = CleanUuid(charB) or tostring(charB)
                    VoiceBusyUntil[cleanB] = math.max(VoiceBusyUntil[cleanB] or 0, now + 8500)
                end
                ActionVoiceStats.gossips = ActionVoiceStats.gossips + 1
                ActionVoiceStats.played = ActionVoiceStats.played + 1
                Log(string.format("WorldGossip PartyBanter started [%s] via %s", tostring(startedDlg), tostring(anchor)))
                return true, startedDlg
            end
        end

        return false, nil
    end

    local function BroadcastClientActionVoice(char, soundEvent, alt3dEvent, preferAlt3d, isDebug, forceTarget, onlyAlt3d, skipAlt3d)
        if not ActionVoiceChannel then return false end
        local cleanChar = CleanUuid(char) or tostring(char)
        local host = Osi.GetHostCharacter and Osi.GetHostCharacter() or nil
        local cleanHost = host and (CleanUuid(host) or tostring(host)) or nil

        local payloadTbl = {
            char        = cleanChar,
            host        = cleanHost,
            event       = soundEvent,
            alt3d       = alt3dEvent,
            preferAlt3d = preferAlt3d == true,
            onlyAlt3d   = onlyAlt3d == true,
            skipAlt3d   = skipAlt3d == true,
            debug       = isDebug == true,
            target      = forceTarget,
        }

        local okSend = pcall(function()
            ActionVoiceChannel:Broadcast(payloadTbl)
        end)
        return okSend == true
    end

    local function DispatchCharacterVocal(char, soundEvent, templateVocalField, alt3dEvent, vocalGuid, preferAlt3d, isDebug, forceTarget)
        if not char or not IsOsirisReady() then return false, "none" end

        if forceTarget and forceTarget ~= "" and forceTarget ~= "pad" and forceTarget ~= "server3d" then
            local sentForced = BroadcastClientActionVoice(char, soundEvent, alt3dEvent, preferAlt3d, isDebug, forceTarget, false, false)
            if sentForced then return true, "client_" .. tostring(forceTarget) end
        end

        -- IMPORTANT: Osi.PlaySoundResource is a void Osiris Call (0 return values), so pcall ALWAYS
        -- returns true! Never let Osi.PlaySoundResource short-circuit BroadcastClientActionVoice!
        local sentToClient = false
        if forceTarget ~= "server3d" then
            sentToClient = BroadcastClientActionVoice(char, soundEvent, alt3dEvent, preferAlt3d, isDebug, forceTarget, false, false)
        end

        local playedServer3d = false
        if Osi.PlaySoundResource and (preferAlt3d or templateVocalField ~= nil or not sentToClient or forceTarget == "server3d") then
            if templateVocalField then
                local tplVocalGuid = GetCharacterVocalResource(char, templateVocalField)
                if tplVocalGuid then
                    local okTpl = pcall(Osi.PlaySoundResource, char, tplVocalGuid)
                    if okTpl then playedServer3d = true end
                end
            end
            if not playedServer3d and vocalGuid and vocalGuid ~= "" and (preferAlt3d or not sentToClient or forceTarget == "server3d") then
                local okVoc = pcall(Osi.PlaySoundResource, char, vocalGuid)
                if okVoc then playedServer3d = true end
            end
        end

        if playedServer3d then
            ActionVoiceStats.vocals3d = ActionVoiceStats.vocals3d + 1
        end

        if sentToClient then
            return true, playedServer3d and "client+3d" or "net_client"
        end
        if playedServer3d then
            return true, "server3d"
        end

        if soundEvent and soundEvent ~= "" and Osi.PlaySound then
            local okSnd = pcall(Osi.PlaySound, char, soundEvent)
            if okSnd then return true, "osi_sound" end
        end

        return false, "none"
    end

    ACTION_VOICE_PROFILES = {
        read             = { chance = 0.90, pads = { PAD_INVESTIGATION, PAD_PERCEPTION }, vocalGuid = SND_VOCAL_EFFORTS, event = "BGClickReaction_Action_InteractWith", alt3d = "Player_Races_Voice_Gen_ClosedMouthEfforts" },
        inspect          = { chance = 0.88, pads = { PAD_INVESTIGATION, PAD_PERCEPTION, PAD_MIRROR_CLEAN }, curiosityHint = true, vocalGuid = SND_VOCAL_EFFORTS, event = "BGClickReaction_Action_InteractWith", alt3d = "Player_Races_Voice_Gen_ClosedMouthEfforts" },
        scavenge_found   = { chance = 0.85, pads = { PAD_INVESTIGATION, PAD_PERCEPTION }, vocalGuid = SND_VOCAL_VICTORY, event = "BGClickReaction_Action_OpenContainer", alt3d = "Player_Races_Voice_Gen_Victory" },
        scavenge_empty   = { chance = 0.55, pads = { PAD_CRATE_EMPTY }, vocalGuid = SND_VOCAL_EFFORTS, event = "BGClickReaction_Action_OpenContainer", alt3d = "Player_Races_Voice_Gen_ClosedMouthEfforts" },
        pickup           = { chance = 0.82, pads = { PAD_PERCEPTION, PAD_INVESTIGATION }, vocalGuid = SND_VOCAL_VICTORY, event = "BGClickReaction_Action_ItemPickup",    alt3d = "Player_Races_Voice_Gen_Victory" },
        alert_gear       = { chance = 1.00, pads = { PAD_PERCEPTION, PAD_INVESTIGATION }, vocalGuid = SND_VOCAL_VICTORY, event = "BGClickReaction_Action_ItemPickup",    alt3d = "Player_Races_Voice_Gen_Victory", important = true },
        alert_consumable = { chance = 1.00, pads = { PAD_INVESTIGATION, PAD_PERCEPTION }, vocalGuid = SND_VOCAL_EFFORTS, event = "BGClickReaction_Action_ItemPickup",    alt3d = "Player_Races_Voice_Gen_ClosedMouthEfforts", important = true },
        alert_rare       = { chance = 1.00, pads = { PAD_PERCEPTION, PAD_INVESTIGATION }, vocalGuid = SND_VOCAL_VICTORY, event = "BGClickReaction_Action_ItemPickup",    alt3d = "Player_Races_Voice_Gen_Victory", important = true },
        alert_book_key   = { chance = 1.00, pads = { PAD_INVESTIGATION, PAD_PERCEPTION }, vocalGuid = SND_VOCAL_EFFORTS, event = "BGClickReaction_Action_InteractWith",  alt3d = "Player_Races_Voice_Gen_ClosedMouthEfforts", important = true },
        trap_spot        = { chance = 1.00, pads = { PAD_TRAP_PERC, PAD_TRAP_INV },       vocalGuid = SND_VOCAL_EFFORTS, event = "BGClickReaction_Action_Utility",       alt3d = "Player_Races_Voice_Gen_ClosedMouthEfforts", tplField = "VocalAlertResourceID", important = true },
        wash_clean       = { chance = 0.90, pads = { PAD_MIRROR_CLEAN }, vocalGuid = SND_VOCAL_RECOVER, event = "BGClickReaction_RelationPrototype_Rest", alt3d = "Player_Races_Voice_Gen_Recover" },
        rest_sit         = { chance = 0.85, pads = { PAD_REST_TIRED },    vocalGuid = SND_VOCAL_RECOVER, event = "BGClickReaction_RelationPrototype_Rest", alt3d = "Player_Races_Voice_Gen_Recover" },
        rest_sit_done    = { chance = 0.85, restContext = true, pads = { PAD_REST_RESPITE },  vocalGuid = SND_VOCAL_RECOVER, event = "BGClickReaction_RelationPrototype_Rest", alt3d = "Player_Races_Voice_Gen_Recover" },
        rest_ground      = { chance = 0.92, pads = { PAD_REST_TIRED, PAD_REST_RESPITE }, vocalGuid = SND_VOCAL_RECOVER, event = "BGClickReaction_RelationPrototype_Rest", alt3d = "Player_Races_Voice_Gen_Recover" },
        rest_fire        = { chance = 0.88, pads = { PAD_REST_RESPITE, PAD_REST_TIRED }, vocalGuid = SND_VOCAL_RECOVER, event = "BGClickReaction_RelationPrototype_Rest", alt3d = "Player_Races_Voice_Gen_Recover" },
        rest_bed         = { chance = 0.85, pads = { PAD_REST_TIRED },    vocalGuid = SND_VOCAL_RECOVER, event = "BGClickReaction_RelationPrototype_Rest", alt3d = "Player_Races_Voice_Gen_Recover" },
        wake_bed         = { chance = 0.85, restContext = true, pads = { PAD_REST_RESPITE },  vocalGuid = SND_VOCAL_RECOVER, event = "BGClickReaction_RelationPrototype_Rest", alt3d = "Player_Races_Voice_Gen_Recover", tplField = "VocalAwakeResourceID", tplChance = 0.50 },
        social_init      = { chance = 0.95, pads = { PAD_INVESTIGATION, PAD_PERCEPTION }, vocalGuid = SND_VOCAL_LAUGHTER, event = "BGClickReaction_Action_SpeakTo", alt3d = "Player_Races_Voice_Gen_Laughter" },
        social_reply     = { chance = 0.92, pads = { PAD_MIRROR_CLEAN }, vocalGuid = SND_VOCAL_LAUGHTER, tplField = "VocalLaughterResourceID", tplChance = 1.0, event = "BGClickReaction_RelationPrototype_SetPositive", alt3d = "Player_Races_Voice_Gen_Laughter", preferAltChance = 1.0 },
        pet_greet        = { chance = 0.92, pads = { PAD_SH_CALL_PET },  vocalGuid = SND_VOCAL_LAUGHTER, tplField = "VocalLaughterResourceID", tplChance = 1.0, event = "BGClickReaction_RelationPrototype_SetPositive", alt3d = "Player_Races_Voice_Gen_Laughter", preferAltChance = 1.0 },
        bard_cheer       = { chance = 0.82, vocalGuid = SND_VOCAL_LAUGHTER, tplField = "VocalLaughterResourceID", tplChance = 0.85, event = "BGClickReaction_RelationPrototype_SetPositive", alt3d = "Player_Races_Voice_Gen_Laughter", preferAltChance = 0.70 },
        light             = { chance = 0.78, pads = { PAD_PERCEPTION },    vocalGuid = SND_VOCAL_EFFORTS, event = "BGClickReaction_Action_Utility",       alt3d = "Player_Races_Voice_Gen_ClosedMouthEfforts" },
        dummy             = { chance = 0.70, vocalGuid = SND_VOCAL_EFFORTS, tplField = "VocalEffortsResourceID", tplChance = 0.85, event = "BGClickReaction_Action_Attack", alt3d = "Player_Races_Voice_Gen_ClosedMouthEfforts" },
        personal_idle     = { chance = 0.80, pads = { PAD_REST_TIRED, PAD_MIRROR_CLEAN, PAD_PERCEPTION }, vocalGuid = SND_VOCAL_RECOVER, event = "BGClickReaction_ReptAction_PortraitClick", alt3d = "Player_Races_Voice_Gen_Recover" },
        idle_chatter      = { chance = 0.90, pads = { PAD_PERCEPTION, PAD_INVESTIGATION, PAD_MIRROR_CLEAN, PAD_REST_TIRED }, vocalGuid = SND_VOCAL_RECOVER, event = "BGClickReaction_ReptAction_PortraitClick", alt3d = "Player_Races_Voice_Gen_Recover" },
        post_combat_tired = { chance = 1.00, restContext = true, pads = { PAD_REST_TIRED, PAD_REST_RESPITE }, vocalGuid = SND_VOCAL_RECOVER, tplField = "VocalExhaustedResourceID", tplChance = 0.75, event = "BGClickReaction_RelationPrototype_Rest", alt3d = "Player_Races_Voice_Gen_Recover", important = true },
    }

    local function CountEligibleOtherSpeakers(selfChar, selfClean, partyNow)
        local otherOrigins = 0
        local otherAny = 0
        local selfCamp = IsInCamp(selfChar)
        for _, c in ipairs(partyNow) do
            local cc = CleanUuid(c)
            if cc and cc ~= selfClean then
                local okElig, isElig = pcall(function()
                    if Osi.IsControlled and Osi.IsControlled(c) == 1 then return false end
                    if Osi.Exists(c) == 0 or Osi.IsDead(c) == 1 or Osi.IsInCombat(c) == 1 then return false end
                    if IsSneakingOrInvisible(c) or IsPolymorphedOrIncapacitated(c) then return false end
                    if Osi.HasActiveStatus and Osi.HasActiveStatus(c, "SILENCED") == 1 then return false end
                    if IsCharacterInDialog(c) or IsCharacterSpeakingBark(c, true) then return false end
                    if IsInCamp(c) ~= selfCamp then return false end
                    local d = Osi.GetDistanceTo(selfChar, c)
                    return (not d) or d <= 22.0
                end)
                if okElig and isElig then
                    otherAny = otherAny + 1
                    if ORIGIN_COMPANION_SET[cc] == true then
                        otherOrigins = otherOrigins + 1
                    end
                end
            end
        end
        return otherOrigins, otherAny
    end

    local function FindNearbyOriginDelegate(sourceChar, partyNow)
        local srcCamp = IsInCamp(sourceChar)
        local srcClean = CleanUuid(sourceChar)
        local candidates = {}
        for _, c in ipairs(partyNow) do
            local cc = CleanUuid(c)
            if cc and cc ~= srcClean and ORIGIN_COMPANION_SET[cc] == true then
                local okW, weight = pcall(function()
                    if Osi.IsControlled and Osi.IsControlled(c) == 1 then return nil end
                    if Osi.Exists(c) == 0 or Osi.IsDead(c) == 1 or Osi.IsInCombat(c) == 1 then return nil end
                    if IsSneakingOrInvisible(c) or IsPolymorphedOrIncapacitated(c) then return nil end
                    if Osi.HasActiveStatus and Osi.HasActiveStatus(c, "SILENCED") == 1 then return nil end
                    if IsCharacterInDialog(c) or IsCharacterSpeakingBark(c, true) then return nil end
                    if IsInCamp(c) ~= srcCamp then return nil end
                    local d = Osi.GetDistanceTo(sourceChar, c)
                    if d and d > 18.5 then return nil end
                    local w = 1.0 + math.max(0.0, (18.5 - (d or 5.0)) / 25.0)
                    w = w * (0.5 * GetTraitWeight(c, "curiosity") + 0.5 * GetTraitWeight(c, "social"))
                    -- Strongly rotate away from whoever spoke last!
                    if cc ~= LastActionVoiceSpeaker and cc ~= LastVoiceSpeaker then
                        w = w * 6.0
                    else
                        w = w * 0.20
                    end
                    return math.max(0.05, w)
                end)
                if okW and weight and weight > 0 then
                    candidates[#candidates + 1] = { char = c, weight = weight }
                end
            end
        end
        if #candidates == 0 then return nil end
        local totalW = 0.0
        for i = 1, #candidates do
            totalW = totalW + candidates[i].weight
        end
        if totalW <= 0 then return candidates[1].char end
        local roll = math.random() * totalW
        local acc = 0.0
        for i = 1, #candidates do
            acc = acc + candidates[i].weight
            if roll <= acc then
                return candidates[i].char
            end
        end
        return candidates[#candidates].char
    end

    TryPlayCompanionActionVoice = function(char, category, opts)
        if not Config.ActionVoices or not char or not IsOsirisReady() then return false, nil end
        local profile = ACTION_VOICE_PROFILES[category]
        if not profile then return false, nil end

        if IsAnyDialogActive() then return false, nil end
        if Osi.Exists(char) == 0 or Osi.IsDead(char) == 1 or Osi.IsInCombat(char) == 1 then return false, nil end
        if IsSneakingOrInvisible(char) or IsInTurnBased(char) or IsCharacterInDialog(char) then return false, nil end

        local now = Ext.Utils.MonotonicTime()
        local clean = CleanUuid(char) or tostring(char)
        local isOrigin = (ORIGIN_COMPANION_SET[clean] == true)

        local isImportant = (opts and opts.important) or profile.important or false
        local isPartnerReply = (opts and opts.partnerReply) or false
        local forceTest = (opts and opts.force) or false
        local forceTarget = opts and opts.target or nil
        local noTimelinePad = (opts and opts.noTimelinePad == true) or false
        local resumeAnim = opts and opts.resumeAnim or nil

        local partyNow = GetPartyCompanions()
        local otherOrigins, otherAny = CountEligibleOtherSpeakers(char, clean, partyNow)

        if not forceTest then
            if isPartnerReply then
                if now < (GlobalActionVoiceBusyUntil - 1400) then
                    return false, nil
                end
                if not isOrigin and otherOrigins >= 1 and math.random() > 0.25 then
                    return false, nil
                end
            elseif isImportant then
                if now < GlobalActionVoiceBusyUntil then
                    return false, nil
                end
                -- Prevent burst-callout spam when opening multiple crates in one room!
                if category ~= "trap_spot" and category ~= "post_combat_tired" and now < ActionVoiceStats.nextImportantTime then
                    return false, nil
                end
                -- Build 04: If a Hireling spotted the find OR this companion just spoke last,
                -- hand the vocal reaction off to a nearby Origin companion with bespoke voice acting!
                if (not isOrigin or LastActionVoiceSpeaker == clean) and otherOrigins >= 1 then
                    local delegate = FindNearbyOriginDelegate(char, partyNow)
                    if delegate and not SameEntity(delegate, char) then
                        char = delegate
                        clean = CleanUuid(delegate) or tostring(delegate)
                        isOrigin = true
                        resumeAnim = nil -- Do not alter the finder's animation on the delegated speaker
                        ActionVoiceStats.originDelegations = ActionVoiceStats.originDelegations + 1
                    elseif not isOrigin then
                        -- Still avoid Hireling monologue if all Origin speakers are momentarily mid-bark
                        return false, nil
                    end
                end
            else
                if now < NextGlobalActionVoiceTime or now < GlobalActionVoiceBusyUntil then
                    return false, nil
                end
                if (CompanionActionVoiceCooldown[clean] or 0) > now then
                    return false, nil
                end
                -- Build 04 Hireling "Quiet Professional" rule: when Origin companions are in the party,
                -- Hirelings stay 92% quiet on routine scavenging/idles so Origin actors carry the dialogue!
                if not isOrigin and otherOrigins >= 1 then
                    if math.random() > 0.08 then
                        return false, nil
                    end
                end
                -- Build 04 Strict Fair Microphone Rotation: never let the same speaker grab two consecutive
                -- ambient voice turns when another companion is right there with them!
                if (LastActionVoiceSpeaker == clean or LastVoiceSpeaker == clean) and otherAny >= 1 then
                    if otherOrigins >= 1 or (now - (ActionVoiceStats.lastVoiceAt or 0)) < 55000 then
                        return false, nil
                    end
                end
            end

            local chance = (opts and opts.chance) or profile.chance or 0.75
            if math.random() > chance then
                return false, nil
            end
        end

        if IsCharacterSpeakingBark(char, true) then
            return false, nil
        end
        if not forceTest and (now < GlobalReactiveBarkUntil or (VoiceBusyUntil[clean] or 0) > now) then
            return false, nil
        end

        local playedMode = nil
        local playedDetail = nil

        local padCandidates = profile.pads
        if profile.curiosityHint and opts and opts.targetUuid then
            padCandidates = ResolveCuriosityPads(opts.targetUuid, padCandidates)
        end
        -- 04.3.7: a PAD is a real dialog - it cancels a Repose pose. A companion who is
        -- sitting on a bench keeps the 3D vocal route instead (04.3.5 seat fix stays intact).
        local isSeated = false
        pcall(function()
            if Osi.IsReposedSitting then isSeated = (Osi.IsReposedSitting(char) == 1) end
        end)
        local allowRestTalk = (profile.restContext == true) or AllowsRestTalk(now)
        -- Reserve overhead PAD dialogs for Origin companions whenever Origin companions are in the party!
        local allowSpokenPad = (padCandidates ~= nil)
            and (isOrigin or otherOrigins == 0 or forceTest)
            and (not forceTarget or forceTarget == "" or forceTarget == "pad")
            and not isSeated
        if allowSpokenPad then
            local startedPad, usedPadId = TryStartSpokenOverheadPad(char, padCandidates, now, forceTest, noTimelinePad, allowRestTalk)
            if startedPad then
                playedMode = "pad"
                playedDetail = usedPadId

                if resumeAnim and Ext and Ext.Timer and Ext.Timer.WaitFor then
                    local qRef = ActiveQueues[char]
                    local savedAct = qRef and qRef.currentAction or nil
                    if savedAct then
                        local function tryResumePose(attempt)
                            pcall(function()
                                local qNow = ActiveQueues[char]
                                if not (qNow and qNow.isProcessing and qNow.currentAction == savedAct and not IsCharacterInDialog(char) and Osi.IsInCombat(char) == 0) then
                                    return
                                end
                                if attempt < 2 and IsCharacterSpeakingBark(char, true) then
                                    Ext.Timer.WaitFor(950, function() tryResumePose(attempt + 1) end)
                                    return
                                end
                                AnimSystem.play(char, resumeAnim)
                            end)
                        end
                        Ext.Timer.WaitFor(2650, function() tryResumePose(1) end)
                    end
                end
            end
        end

        if not playedMode then
            local chosenEvent = profile.event
            if profile.altEvent and profile.altChance and math.random() < profile.altChance then
                chosenEvent = profile.altEvent
            end

            local chosenTplField = nil
            if profile.tplField then
                if not profile.tplChance or math.random() < profile.tplChance then
                    chosenTplField = profile.tplField
                end
            end

            local alt3dEvent = profile.alt3d
            local preferAlt3d = false
            if alt3dEvent and profile.preferAltChance and math.random() < profile.preferAltChance then
                preferAlt3d = true
            end
            local debugVoice = (opts and opts.debug == true) or (ConfigValues.Debug == true)

            local okVoc, vocRoute = DispatchCharacterVocal(
                char, chosenEvent, chosenTplField, alt3dEvent, profile.vocalGuid, preferAlt3d, debugVoice, forceTarget
            )
            if not okVoc then
                return false, nil
            end
            playedMode = vocRoute
            playedDetail = chosenTplField or profile.vocalGuid or chosenEvent
            ActionVoiceStats.vocalOnly = ActionVoiceStats.vocalOnly + 1   -- no PAD: grunt/sigh only
        end

        local baseCdMs = math.max(5000, (tonumber(Config.ActionVoiceCooldown) or 24) * 1000)
        local jitterFactor = 0.85 + (math.random() * 0.30)
        local hirelingMult = isOrigin and 1.0 or 2.2
        -- 04.3.7 Voice density: a party that has been silent for a while earns a shorter
        -- pause. Long silence used to snowball (each quiet minute made the next line rarer).
        local quietFor = now - (ActionVoiceStats.lastVoiceAt or 0)
        local density = 1.0
        if quietFor > 45000 then density = 1.35 end
        if quietFor > 90000 then density = 1.75 end
        if isImportant then density = 1.0 end
        local partyWaitMs = math.floor((baseCdMs / density) * jitterFactor)

        local busyMs = (playedMode == "pad") and 3800 or 3000
        GlobalActionVoiceBusyUntil = now + busyMs
        VoiceBusyUntil[clean] = math.max(VoiceBusyUntil[clean] or 0, now + busyMs)

        if isPartnerReply then
            NextGlobalActionVoiceTime = math.max(NextGlobalActionVoiceTime, now + math.floor((baseCdMs * 0.85) / density))
            CompanionActionVoiceCooldown[clean] = now + math.floor(math.max(16000, math.floor(baseCdMs * 0.90 / density)) * hirelingMult)
            ActionVoiceStats.replies = ActionVoiceStats.replies + 1
        elseif isImportant then
            NextGlobalActionVoiceTime = math.max(NextGlobalActionVoiceTime, now + math.floor(baseCdMs * 0.55))
            CompanionActionVoiceCooldown[clean] = now + math.floor(math.max(18000, math.floor(baseCdMs * 0.80)) * hirelingMult)
            ActionVoiceStats.nextImportantTime = math.max(ActionVoiceStats.nextImportantTime, now + 6500)
            ActionVoiceStats.important = ActionVoiceStats.important + 1
        else
            NextGlobalActionVoiceTime = now + partyWaitMs
            CompanionActionVoiceCooldown[clean] = now + math.floor(math.max(15000, math.floor(baseCdMs * 0.70 / density)) * hirelingMult)
        end

        LastActionVoiceSpeaker = clean
        ActionVoiceStats.lastVoiceAt = now
        ActionVoiceStats.played = ActionVoiceStats.played + 1
        Log(string.format(
            "ActionVoice [%s] on %s (mode=%s, ref=%s, total=%d, nextParty=%.1fs)",
            tostring(category),
            tostring(char),
            tostring(playedMode),
            tostring(playedDetail),
            ActionVoiceStats.played,
            math.max(0, (NextGlobalActionVoiceTime - now) / 1000.0)
        ))
        return true, playedMode
    end

    -- ========================================================================
    -- 04.3.7 CHATTER TICK
    --   Action voices only existed as a side effect of an activity (idle anim,
    --   social chat, warming hands...). A party busy with lights, looting and
    --   walking could stay silent for minutes. This tick gives the party its own
    --   voice slot: after a long silence somebody says a short ambient line.
    --   Hard limits: >= 55 s of silence, global cooldowns, one speaker at a time.
    -- ========================================================================
    AmbientVoice.chatterTick = function(now)
        if not Config.ActionVoices then return end
        if IsAnyDialogActive() then return end
        local quietFor = now - (ActionVoiceStats.lastVoiceAt or 0)
        if quietFor < 40000 then return end
        if now < NextGlobalActionVoiceTime or now < GlobalActionVoiceBusyUntil then return end
        if now < GlobalReactiveBarkUntil then return end
        if IsAnyPartyMemberSpeakingBark() then return end

        local host = Osi.GetHostCharacter and Osi.GetHostCharacter() or nil
        if not host then return end
        if Osi.IsInCombat(host) == 1 or IsSneakingOrInvisible(host) or IsInTurnBased(host) then return end

        local vc = VC.Refresh(now)
        local pool, totalW = {}, 0.0
        for _, c in ipairs(GetPartyCompanions()) do
            local clean = CleanUuid(c)
            if clean and not SameEntity(c, host) then
                local ok, w = pcall(function()
                    if Osi.Exists(c) == 0 or Osi.IsDead(c) == 1 or Osi.IsInCombat(c) == 1 then return nil end
                    if Osi.IsControlled and Osi.IsControlled(c) == 1 then return nil end
                    if IsSneakingOrInvisible(c) or IsPolymorphedOrIncapacitated(c) then return nil end
                    if Osi.HasActiveStatus and Osi.HasActiveStatus(c, "SILENCED") == 1 then return nil end
                    if IsCharacterInDialog(c) or IsCharacterSpeakingBark(c, true) then return nil end
                    if (CompanionActionVoiceCooldown[clean] or 0) > now then return nil end
                    local d = Osi.GetDistanceTo(host, c)
                    if d and d > 18.0 then return nil end
                    local weight = 1.0
                    if ORIGIN_COMPANION_SET[clean] == true then weight = weight * 2.5 end
                    if clean == LastActionVoiceSpeaker or clean == LastVoiceSpeaker then weight = weight * 0.20 end
                    -- Let the most tired companion carry the "we should rest" hint.
                    if vc and vc.needsRest then
                        local hp = StateChecks.getMemberHpPercent(c) or 100
                        if hp <= 75 then weight = weight * 2.0 end
                    end
                    return math.max(0.05, weight)
                end)
                if ok and w then
                    pool[#pool + 1] = { char = c, weight = w }
                    totalW = totalW + w
                end
            end
        end
        if #pool == 0 then return end

        local roll = math.random() * totalW
        local acc, picked = 0.0, pool[#pool]
        for _, cand in ipairs(pool) do
            acc = acc + cand.weight
            if roll <= acc then
                picked = cand
                break
            end
        end

        local chance = (quietFor > 120000) and 1.0 or 0.75
        local okPlay = TryPlayCompanionActionVoice(picked.char, "idle_chatter", { chance = chance })
        if okPlay and ConfigValues.Debug then
            Log(string.format("[VOICE] chatter after %.1fs of silence on %s (party: %s)",
                quietFor / 1000.0, tostring(CleanUuid(picked.char) or picked.char), tostring(vc and vc.reason or "?")))
        end
    end
end

-- ============================================================================
-- 7. BEHAVIOR SEQUENCES (IMMERSION + LIVING PARTY)
-- ============================================================================

local function CreateBardAudienceSequence(character, performerUuid)
    local queue = ActiveQueues[character]
    if not queue then return end
    queue.activityTag = "music"

    local dNow = Osi.GetDistanceTo(character, performerUuid) or 0
    if dNow > 4.5 or dNow < 1.8 then
        queue:enqueue({
            name = "GatherNearBard",
            execute = function(char)
                local spread = 2.6 + math.random() * 1.4
                local tx, ty, tz = GetSmartApproachPosition(char, performerUuid, spread)
                if tx then Osi.CharacterMoveToPosition(char, tx, ty, tz, "Walk", "") end
            end,
            completion = function(char)
                local d = Osi.GetDistanceTo(char, performerUuid)
                return d and d <= 4.8 and Osi.IsMoving(char) == 0
            end,
            duration = 4500,
        })
    end

    AnimSystem.enqueueSmoothTurn(queue, "TurnToBard", performerUuid)

    local anims = GetMusicReactionAnimations(character)
    local chosenAnim = anims[math.random(#anims)]

    queue:enqueue({
        name = "EnjoyBardMusic_" .. chosenAnim,
        customAnim = true,
        execute = function(char)
            AnimSystem.lookAt(char, performerUuid, 5.0)
            AnimSystem.play(char, chosenAnim)
            local cheerDelay = math.random(1600, 3200)
            Ext.Timer.WaitFor(cheerDelay, function()
                if not IsOsirisReady() then return end
                local qNow = ActiveQueues[char]
                if qNow and qNow.isProcessing and qNow.activityTag == "music" then
                    TryPlayCompanionActionVoice(char, "bard_cheer", { noTimelinePad = true })
                end
            end)
        end,
        completion = function()
            return not IsEntityStillPerforming(performerUuid)
        end,
        duration = math.random(9000, 16000),
    })

    AnimSystem.enqueueGracefulExit(queue, "FinishMusicReaction", chosenAnim)
end

local function CreatePetGreetSequence(character, petUuid)
    local queue = ActiveQueues[character]
    if not queue then return end
    queue.activityTag = "pet"

    queue:enqueue({
        name = "WalkToPet",
        execute = function(char)
            local tx, ty, tz = GetSmartApproachPosition(char, petUuid, 1.5)
            if tx then Osi.CharacterMoveToPosition(char, tx, ty, tz, "Walk", "") end
        end,
        completion = function(char)
            local d = Osi.GetDistanceTo(char, petUuid)
            return d and d < 2.4 and Osi.IsMoving(char) == 0
        end,
    })

    AnimSystem.enqueueSmoothTurn(queue, "TurnToPet", petUuid)

    queue:enqueue({
        name = "GreetPet",
        customAnim = true,
        execute = function(char)
            AnimSystem.lookAt(char, petUuid, 4.0)
            local _, vMode = TryPlayCompanionActionVoice(char, "pet_greet", { resumeAnim = AnimSystem.CALL_PET })
            if vMode ~= "pad" then
                AnimSystem.play(char, AnimSystem.CALL_PET)
            end
        end,
        duration = math.random(5200, 7800),
    })

    AnimSystem.enqueueGracefulExit(queue, "FinishGreetingPet", AnimSystem.CALL_PET)
end

local function CreateSocialChatSequence(character, partnerUuid)
    local queue = ActiveQueues[character]
    if not queue then return end
    queue.activityTag = "social"

    queue:enqueue({
        name = "WalkToCompanion",
        execute = function(char)
            local tx, ty, tz = GetSmartApproachPosition(char, partnerUuid, 1.7)
            if tx then Osi.CharacterMoveToPosition(char, tx, ty, tz, "Walk", "") end
        end,
        completion = function(char)
            local d = Osi.GetDistanceTo(char, partnerUuid)
            return d and d < 2.5 and Osi.IsMoving(char) == 0
        end,
    })

    queue:enqueue({
        name = "TurnToChatPartner",
        execute = function(char)
            FaceTarget(char, partnerUuid)
            local pq = ActiveQueues[partnerUuid]
            if not pq or not pq.currentTarget then
                FaceTarget(partnerUuid, char)
            end
        end,
        duration = 480,
    })

    local chosenChatAnim = AnimSystem.pickSocialAnim()

    queue:enqueue({
        name = "SocialChatting",
        customAnim = true,
        execute = function(char)
            AnimSystem.lookAt(char, partnerUuid, 6.0)
            local pq = ActiveQueues[partnerUuid]
            if not pq or not pq.currentTarget then
                AnimSystem.lookAt(partnerUuid, char, 6.0)
            end

            -- Layer A: Try genuine multi-companion BG3 World PartyBanter (Voice.pak + localized subtitles) first!
            local startedGossip = TryTriggerWorldPartyBanter(char, partnerUuid, false)
            if startedGossip then
                AnimSystem.play(char, chosenChatAnim)
            else
                -- Layer B + C fallback: Spoken overhead remark from speaker 1 + spoken/laughter reply from speaker 2
                local okInit, initMode = TryPlayCompanionActionVoice(char, "social_init", { resumeAnim = chosenChatAnim })
                if initMode ~= "pad" then
                    AnimSystem.play(char, chosenChatAnim)
                end
                if okInit and partnerUuid then
                    local replyDelay = math.random(3000, 3800)
                    Ext.Timer.WaitFor(replyDelay, function()
                        if not IsOsirisReady() then return end
                        local qNow = ActiveQueues[char]
                        if qNow and qNow.isProcessing and qNow.activityTag == "social" then
                            TryPlayCompanionActionVoice(partnerUuid, "social_reply", { partnerReply = true })
                        end
                    end)
                end
            end
        end,
        duration = math.random(8500, 12000),
    })

    AnimSystem.enqueueGracefulExit(queue, "FinishSocialChat", chosenChatAnim)
end

-- ============================================================================
-- 7C. LIGHT IGNITION REPAIR KIT (Build 04.3.3)
--
-- Investigated failures this module fixes:
--   1. "Already lit" FALSE POSITIVES. The old check treated
--        * any BURNING / MAG_LIGHT / LAMP / TORCH status, or
--        * our own session litSet,
--      as proof that a fixture is lit. A save made by an older build can hold a
--      BURNING status on a fixture whose visible light is OFF, so the companion
--      walked up, saw "already lit", and silently skipped it -> the room stayed
--      dark and the fixture was never retried in that save.
--      Fix: the entity's own GameplayLight component is authoritative. If the
--      engine exposes GameplayLight and it is NOT Active, the fixture is dark no
--      matter which statuses or bookkeeping claim otherwise.
--   2. FIRE-AND-FORGET IGNITION. Every engine call was wrapped in pcall and the
--      outcome was never verified; a fixture that refused to react (typical for
--      Constellation Lamp/Lantern props where BURNING is skipped on purpose) was
--      still written into litSet, so it was never tried again.
--      Fix: strike() -> verify -> fallback engine (Osi.Use) -> verify -> record or
--      short cooldown.
--   3. BLACKLIST POISONING. 30-minute blacklist entries were written BEFORE the
--      attempt, so one bad frame hid a fixture for half an hour.
--      Fix: cooldowns are only written after a verified failure, and are short.
--   4. SAVE/LOAD DRIFT. Fixtures lit in a previous session are remembered in
--      PersistentVars.LitByAmbientAI and re-armed a few seconds after a save is
--      loaded, so "old" saves light up again instead of staying dark forever.
-- ============================================================================
AmbientLightRepair = {
    NULL_GUID     = "00000000-0000-0000-0000-000000000000",
    verifyDelay   = 320,     -- ms: give the engine a couple of frames to switch the light on
    fallbackDelay = 900,     -- ms: Osi.Use fallback + second verification pass
    failCooldown  = 120000,  -- ms: back off from a fixture that refused to light
    failCooldownMax = 600000,
    okCooldown    = 1800000, -- ms: normal "do not touch it again" window once lit
    fails         = {},      -- uuid -> consecutive failed attempts
}

-- Returns true / false / nil (nil = engine exposes no GameplayLight component)
function AmbientLightRepair.gameplayLightActive(uuid)
    local ok, res = pcall(function()
        local e = Ext.Entity.Get(uuid)
        if e ~= nil and e.GameplayLight ~= nil then
            return e.GameplayLight.Active == true
        end
        return nil
    end)
    if ok then return res end
    return nil
end

function AmbientLightRepair.hasLitStatus(uuid)
    local ok, res = pcall(function()
        return Osi.HasActiveStatus(uuid, "BURNING") == 1
            or Osi.HasActiveStatus(uuid, "MAG_LIGHT") == 1
            or Osi.HasActiveStatus(uuid, "LAMP") == 1
            or Osi.HasActiveStatus(uuid, "TORCH") == 1
    end)
    return ok and res == true
end

-- Returns lit(boolean), reason(string) - reason is printed by !ambient_lights
function AmbientLightRepair.state(uuid)
    if not uuid then return false, "no_uuid" end
    local clean = CleanUuid(uuid) or uuid
    local gpl = AmbientLightRepair.gameplayLightActive(uuid)
    if gpl == true then return true, "gameplaylight_on" end
    if gpl == false then return false, "gameplaylight_off" end
    -- No GameplayLight component at all (dos2-style torch/candle props): statuses are the only signal
    if AmbientLightRepair.hasLitStatus(uuid) then return true, "status" end
    if ScavengeStats.litSet and ScavengeStats.litSet[clean] == true then
        return true, "session_memory"
    end
    return false, "dark"
end

function AmbientLightRepair.isLit(uuid)
    local lit = AmbientLightRepair.state(uuid)
    return lit
end

function AmbientLightRepair.markLit(uuid)
    if not uuid then return end
    local clean = CleanUuid(uuid) or uuid
    ScavengeStats.litSet = ScavengeStats.litSet or {}
    ScavengeStats.litSet[clean] = true
    ScavengeStats.lightsLit = (ScavengeStats.lightsLit or 0) + 1
    AmbientLightRepair.fails[clean] = nil
    Blacklist[uuid] = Ext.Utils.MonotonicTime() + AmbientLightRepair.okCooldown
    -- Remember across saves so a reloaded game can re-arm fixtures that loaded dark
    PersistentVars = PersistentVars or {}
    if type(PersistentVars.LitByAmbientAI) ~= "table" then PersistentVars.LitByAmbientAI = {} end
    PersistentVars.LitByAmbientAI[clean] = true
    local n = 0
    for _ in pairs(PersistentVars.LitByAmbientAI) do n = n + 1 end
    if n > 800 then PersistentVars.LitByAmbientAI = { [clean] = true } end
end

function AmbientLightRepair.forget(uuid)
    if not uuid then return end
    local clean = CleanUuid(uuid) or uuid
    if ScavengeStats.litSet then ScavengeStats.litSet[clean] = nil end
    if PersistentVars and type(PersistentVars.LitByAmbientAI) == "table" then
        PersistentVars.LitByAmbientAI[clean] = nil
    end
end

function AmbientLightRepair.penalize(uuid)
    local clean = CleanUuid(uuid) or uuid
    local n = (AmbientLightRepair.fails[clean] or 0) + 1
    AmbientLightRepair.fails[clean] = n
    local cd = AmbientLightRepair.failCooldown
    if n >= 3 then cd = AmbientLightRepair.failCooldownMax end
    Blacklist[uuid] = Ext.Utils.MonotonicTime() + cd
    Blacklist[clean] = Blacklist[uuid]
    return cd
end

-- Fires every ignition engine we have and VERIFIES asynchronously.
-- info fields: tplLabel, canPickUp, canUse, hasConstellation, isLampOnly, isCandleSound, isWaxCandle
function AmbientLightRepair.strike(char, uuid, info)
    if not uuid or not char or not IsOsirisReady() then return end
    info = info or {}
    -- We are standing next to it: cleared here instead of being blacklisted before the attempt
    Blacklist[uuid] = nil
    Blacklist[CleanUuid(uuid) or uuid] = nil
    if AmbientLightRepair.isLit(uuid) then return end

    local skipBurning = (info.hasConstellation == true and info.isLampOnly == true)

    -- Engine 1: Constellation input socket (native path for interactive light props).
    -- SetForceUpdate makes the client re-evaluate the constellation graph, so the light
    -- actually appears instead of only changing server-side state.
    if Osi.ConstellationTriggerInputSocket then
        pcall(Osi.ConstellationTriggerInputSocket, uuid, "TurnOn", char, AmbientLightRepair.NULL_GUID)
        if Osi.SetForceUpdate then pcall(Osi.SetForceUpdate, uuid, 0) end
    end

    -- Engine 2: DOS2_Torch style BURNING status (wax candles, clusters, sconces,
    -- candelabras, wall bowls, braziers).
    if not skipBurning then
        pcall(Osi.ApplyStatus, uuid, "BURNING", -1.0, 1, char)
    end

    if info.isCandleSound then
        pcall(Osi.PlaySound, uuid, "DEC_Interactive_Lightsources_Candle_On")
    end

    Ext.Timer.WaitFor(AmbientLightRepair.verifyDelay, function()
        if not IsOsirisReady() then return end
        if Osi.Exists(uuid) ~= 1 then return end
        if AmbientLightRepair.isLit(uuid) then
            AmbientLightRepair.markLit(uuid)
            Log("Fixture lit & verified (socket/status): " .. tostring(info.tplLabel ~= "" and info.tplLabel or uuid))
            return
        end

        -- Engine 3: the game's own "Use" interaction - exactly what a player click does.
        -- This drives constellation graphs that expose no working "TurnOn" socket.
        local useAllowed = (info.canPickUp ~= true) or (info.canUse == true)
        if useAllowed and Osi.Use then
            pcall(Osi.Use, char, uuid, "")
            if Osi.SetForceUpdate then pcall(Osi.SetForceUpdate, uuid, 0) end
        end

        Ext.Timer.WaitFor(AmbientLightRepair.fallbackDelay, function()
            if not IsOsirisReady() then return end
            if Osi.Exists(uuid) ~= 1 then return end
            if AmbientLightRepair.isLit(uuid) then
                AmbientLightRepair.markLit(uuid)
                Log("Fixture lit & verified (Osi.Use fallback): " .. tostring(info.tplLabel ~= "" and info.tplLabel or uuid))
                return
            end
            -- Engine 4 (Build 04.3.3): last resort for the lamp/lantern class where the
            -- first BURNING pass is skipped on purpose. If the constellation socket and the
            -- Use interaction both did nothing, a permanent BURNING is the only engine left -
            -- without it these fixtures could never light at all.
            if skipBurning then
                pcall(Osi.ApplyStatus, uuid, "BURNING", -1.0, 1, char)
                if AmbientLightRepair.isLit(uuid) then
                    AmbientLightRepair.markLit(uuid)
                    Log("Fixture lit & verified (BURNING last resort): " .. tostring(info.tplLabel ~= "" and info.tplLabel or uuid))
                    return
                end
            end
            AmbientLightRepair.forget(uuid)
            local cd = AmbientLightRepair.penalize(uuid)
            Log(string.format(
                "Fixture refused every ignition engine: %s (%s) | useAllowed=%s skipBurning=%s -> retry in %ds",
                tostring(info.tplLabel ~= "" and info.tplLabel or "light"),
                tostring(uuid), tostring(useAllowed), tostring(skipBurning), math.floor(cd / 1000)
            ))
        end)
    end)
end

-- Re-ignites fixtures this mod lit in an earlier session that loaded dark (old saves!)
function AmbientLightRepair.rearm(radius)
    if not IsOsirisReady() then return 0 end
    local mem = PersistentVars and PersistentVars.LitByAmbientAI
    if type(mem) ~= "table" then return 0 end
    local host = Osi.GetHostCharacter and Osi.GetHostCharacter() or nil
    local maxDist = radius or 60.0
    local fixed = 0
    for clean, _ in pairs(mem) do
        if Osi.Exists(clean) ~= 1 then
            mem[clean] = nil
        elseif not AmbientLightRepair.isLit(clean) then
            local d = host and Osi.GetDistanceTo(host, clean) or nil
            if d == nil or d <= maxDist then
                if Osi.ConstellationTriggerInputSocket then
                    pcall(Osi.ConstellationTriggerInputSocket, clean, "TurnOn", host or clean, AmbientLightRepair.NULL_GUID)
                end
                pcall(Osi.ApplyStatus, clean, "BURNING", -1.0, 1, host or clean)
                if Osi.SetForceUpdate then pcall(Osi.SetForceUpdate, clean, 0) end
                fixed = fixed + 1
            end
        end
    end
    if fixed > 0 then
        Log("Save re-arm: re-ignited " .. tostring(fixed) .. " fixture(s) that were saved lit but loaded dark.")
    end
    return fixed
end

function AmbientLightRepair.scheduleRearm(delay)
    if not (Ext and Ext.Timer and Ext.Timer.WaitFor) then return end
    Ext.Timer.WaitFor(delay or 6000, function()
        if not IsOsirisReady() then return end
        AmbientLightRepair.rearm()
    end)
end

-- Human readable fixture report (used by the !ambient_lights console command)
function AmbientLightRepair.describe(uuid)
    local clean = CleanUuid(uuid) or uuid
    local tpl = "?"
    pcall(function()
        local e = Ext.Entity.Get(uuid)
        local si = e and e.ServerItem or nil
        tpl = tostring(si and si.Template and si.Template.Name or "?")
    end)
    local lit, reason = AmbientLightRepair.state(uuid)
    local gpl = AmbientLightRepair.gameplayLightActive(uuid)
    local bl = Blacklist[uuid] or Blacklist[clean] or 0
    local now = Ext.Utils.MonotonicTime()
    return string.format(
        "%-38s lit=%-5s (%s) GPL=%-5s BURNING=%s blacklist=%s safe=%s",
        tpl, tostring(lit), reason,
        tostring(gpl),
        tostring(AmbientLightRepair.hasLitStatus(uuid)),
        (bl > now) and string.format("%.0fs", (bl - now) / 1000) or "-",
        tostring(IsSafeWorldObject(uuid, "light"))
    )
end

function AmbientLightRepair.diagnose(radius)
    local host = Osi.GetHostCharacter and Osi.GetHostCharacter() or nil
    if not host then return end
    local r = radius or 20.0
    local rSq = r * r
    local hx, hy, hz = Osi.GetPosition(host)
    Ext.Utils.Print("=== [AmbientAI] Light fixture diagnostics (radius " .. tostring(r) .. "m) ===")
    local shown = 0
    local items = (LocalSpatialIndex and LocalSpatialIndex.items) or {}
    for _, item in ipairs(items) do
        local nm = tostring(item.name or "")
        local low = string.lower(nm)
        local isLightish = string.find(nm, "LTS_", 1, true) ~= nil
            or string.find(low, "candle", 1, true) ~= nil
            or string.find(low, "candelabr", 1, true) ~= nil
            or string.find(low, "sconce", 1, true) ~= nil
            or string.find(low, "lamp", 1, true) ~= nil
            or string.find(low, "lantern", 1, true) ~= nil
            or string.find(low, "brazier", 1, true) ~= nil
            or string.find(low, "bowl", 1, true) ~= nil
        if isLightish and item.x then
            local dx, dz = item.x - hx, item.z - hz
            if (dx * dx + dz * dz) <= rSq then
                shown = shown + 1
                local los = "?"
                pcall(function() los = tostring(Osi.HasLineOfSight(host, item.u)) end)
                Ext.Utils.Print(string.format(" [%d] %s", shown, AmbientLightRepair.describe(item.u)))
                Ext.Utils.Print(string.format("     dist=%.2f dy=%.2f LoS=%s canUse=%s canPickUp=%s",
                    math.sqrt(dx * dx + dz * dz + (item.y - hy) * (item.y - hy)),
                    (item.y or 0) - (hy or 0), los,
                    tostring(item.canUse), tostring(item.canPickUp)))
            end
        end
    end
    if shown == 0 then
        Ext.Utils.Print("  no light fixtures indexed around the host (LocalSpatialIndex empty or no matches)")
    end
    Ext.Utils.Print("  remembered-as-lit entries for save re-arm: " ..
        tostring((function()
            local n = 0
            if PersistentVars and type(PersistentVars.LitByAmbientAI) == "table" then
                for _ in pairs(PersistentVars.LitByAmbientAI) do n = n + 1 end
            end
            return n
        end)()))
    Ext.Utils.Print("=== end ===")
end

local function IsLightSourceAlreadyLit(uuid)
    return AmbientLightRepair.isLit(uuid)
end

-- ============================================================================
-- 7D. LIGHT WALK TRACER + APPROACH BUILDER (Build 04.3.4)
--
-- Why: with Debug on, a light sequence used to produce exactly one line
-- ("started: GoToSconce") followed by silence - the queue died inside one of the
-- silent exits (no approach point / movement stall watchdog / 10 s retry timeout)
-- and the fixture landed on a 30 minute blacklist. Nothing was logged, so the
-- only visible symptom was "companion walks up and does nothing".
-- ============================================================================
LIGHT_ARRIVE_H = 3.9   -- m: how close is "close enough" to light it (ignition allows 4.2)
LIGHT_ARRIVE_V = 3.3
LIGHT_IGNITE_H = 4.2
LIGHT_IGNITE_V = 3.4
LIGHT_TARGET_COOLDOWN = 90000   -- ms: light-specific cooldown (was 1800000 in the shared watchdog)

LightTrace = {
    force = false,          -- !ambient_light_trace on
    seq = 0,
    lastProgress = {},      -- uuid -> timestamp of last progress line
}

function LightTrace.enabled()
    return LightTrace.force or ConfigValues.Debug == true
end

function LightTrace.line(tag, fmt, ...)
    if not LightTrace.enabled() then return end
    local msg = select('#', ...) > 0 and string.format(fmt, ...) or tostring(fmt)
    Ext.Utils.Print(string.format("[AmbientAI][LIGHT] %s | %s", tostring(tag), msg))
end

function LightTrace.tpl(uuid)
    local ok, tpl = pcall(function()
        local e = Ext.Entity.Get(uuid)
        local si = e and e.ServerItem or nil
        return tostring(si and si.Template and si.Template.Name or "?")
    end)
    return ok and tpl or "?"
end

function LightTrace.pos(uuid)
    local ok, x, y, z = pcall(Osi.GetPosition, uuid)
    if ok and x then return x, y, z end
    return nil
end

function LightTrace.dist3(a, x, y, z)
    local ax, ay, az = LightTrace.pos(a)
    if not ax or not x then return nil end
    local dx, dy, dz = ax - x, ay - y, az - z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- Returns withinReach(bool), horizDist, vertDelta
function LightTrace.metrics(char, target)
    local cx, cy, cz = LightTrace.pos(char)
    local tx, ty, tz = LightTrace.pos(target)
    if not cx or not tx then return false, 999, 999 end
    local dx, dz = cx - tx, cz - tz
    return true, math.sqrt(dx * dx + dz * dz), math.abs((cy or 0) - (ty or 0))
end

-- Up to 9 candidate standing points: 3 distances x (direct + 2 rotated sides).
-- Each one is validated on the AI grid via FindValidPosition, so we never order a
-- companion to walk into a table/wall.
function GetLightApproachPoints(char, targetUuid)
    local pts = {}
    local cx, cy, cz = LightTrace.pos(char)
    local tx, ty, tz = LightTrace.pos(targetUuid)
    if not cx or not tx then return pts end

    local dx, dz = cx - tx, cz - tz
    local len = math.sqrt(dx * dx + dz * dz)
    local dirs = {}
    if len > 0.01 then
        local nx, nz = dx / len, dz / len
        dirs[#dirs + 1] = { nx, nz }
        for _, ang in ipairs({ math.rad(60), math.rad(-60) }) do
            local c, s = math.cos(ang), math.sin(ang)
            dirs[#dirs + 1] = { nx * c - nz * s, nx * s + nz * c }
        end
    else
        dirs[#dirs + 1] = { 1, 0 }
        dirs[#dirs + 1] = { -1, 0 }
        dirs[#dirs + 1] = { 0, 1 }
    end

    -- Tall props (wall sconces, high braziers): stand on the floor, not at prop height
    local standY = ((ty or cy) - (cy or 0) > 1.65) and cy or (ty or cy)

    for _, dist in ipairs({ 1.0, 1.8, 2.6 }) do
        for _, dir in ipairs(dirs) do
            local px, pz = tx + dir[1] * dist, tz + dir[2] * dist
            local added = false
            if Osi.FindValidPosition then
                local ok, vx, vy, vz = pcall(Osi.FindValidPosition, px, standY, pz, 2.5, char, 0)
                if ok and vx then
                    pts[#pts + 1] = { x = vx, y = vy, z = vz, want = dist }
                    added = true
                end
            end
            if not added then
                pts[#pts + 1] = { x = px, y = standY, z = pz, want = dist, raw = true }
            end
        end
    end
    return pts
end

function LightTrace.pickApproach(char, targetUuid)
    local pts = GetLightApproachPoints(char, targetUuid)
    if #pts == 0 then return nil, pts end
    -- Prefer points the AI grid actually accepted; raw (unvalidated) points are only a
    -- last resort - the engine itself then clamps the blocked destination.
    local pool = {}
    for _, p in ipairs(pts) do
        if not p.raw then pool[#pool + 1] = p end
    end
    local usedRaw = false
    if #pool == 0 then pool = pts; usedRaw = true end
    local best, bestD = nil, nil
    for _, p in ipairs(pool) do
        local d = LightTrace.dist3(char, p.x, p.y, p.z)
        if d and (not bestD or d < bestD) then best, bestD = p, d end
    end
    best = best or pool[1]
    best.charDist = bestD
    best.usedRaw = usedRaw
    return best, pts
end

local function CreateTorchbearerSequence(character, sconceUuid, extraClusterUuids)
    local queue = ActiveQueues[character]
    if not queue then return end
    queue.activityTag = "light"

    local function IgniteSingleFixture(char, targetUuid, playVoice)
        if not targetUuid then return false end
        local nowTs = Ext.Utils.MonotonicTime()

        -- Never blacklist before the attempt (old bug: one bad frame hid a fixture for 30 minutes)
        local okReach, hDist, vDelta = LightTrace.metrics(char, targetUuid)
        if not (okReach and hDist <= LIGHT_IGNITE_H and vDelta <= LIGHT_IGNITE_V) then
            Blacklist[targetUuid] = nowTs + math.random(8000, 15000)
            LightTrace.line("LightIt", "skipped %s: out of reach (dist=%.2f dy=%.2f, limit %.1f/%.1f)",
                LightTrace.tpl(targetUuid), hDist, vDelta, LIGHT_IGNITE_H, LIGHT_IGNITE_V)
            return false
        end
        LightTrace.line("LightIt", "igniting %s (%s) from dist=%.2f dy=%.2f",
            LightTrace.tpl(targetUuid), tostring(targetUuid), hDist, vDelta)
        if not IsSafeWorldObject(targetUuid, "light") then
            Blacklist[targetUuid] = nowTs + 120000
            Log("LightIt skipped: unsafe/decor target " .. tostring(targetUuid))
            return false
        end
        if IsLightSourceAlreadyLit(targetUuid) then
            Log("LightIt skipped: fixture is already emitting light " .. tostring(targetUuid))
            return false
        end

        AnimSystem.lookAt(char, targetUuid, 2.2)
        local vMode = nil
        if playVoice then
            local _, m = TryPlayCompanionActionVoice(char, "light", { noTimelinePad = true })
            vMode = m
        end
        if vMode ~= "pad" then
            AnimSystem.play(char, AnimSystem.USE_ITEM)
        end

        -- Inspect the fixture so the ignition cascade can pick the right engine
        local info = {
            tplLabel         = "",
            canPickUp        = false,
            canUse           = false,
            hasConstellation = false,
            isCandleSound    = false,
            isWaxCandle      = false,
            isLampOnly       = false,
        }
        pcall(function()
            local e = Ext.Entity.Get(targetUuid)
            if e and e.Constellation ~= nil then
                info.hasConstellation = true
            end
            local si = e and e.ServerItem or nil
            if si then
                info.canPickUp = (si.CanBePickedUp == true)
                info.canUse = (si.CanUse == true)
                info.tplLabel = tostring(si.Template and si.Template.Name or "")
                local tplLower = string.lower(info.tplLabel)
                info.isCandleSound = string.find(tplLower, "candle", 1, true) ~= nil
                    or string.find(tplLower, "candelabr", 1, true) ~= nil
                    or string.find(tplLower, "candlestick", 1, true) ~= nil
                info.isWaxCandle = string.find(tplLower, "candle", 1, true) ~= nil
                    and not string.find(tplLower, "torch", 1, true)
                    and not string.find(tplLower, "candelabr", 1, true)
                info.isLampOnly = (string.find(tplLower, "lamp", 1, true) ~= nil
                    or string.find(tplLower, "lantern", 1, true) ~= nil)
                    and not info.isCandleSound
                    and not string.find(tplLower, "torch", 1, true)
                    and not string.find(tplLower, "brazier", 1, true)
                    and not string.find(tplLower, "bowl", 1, true)
                    and not string.find(tplLower, "sconce", 1, true)
            end
        end)

        -- Multi-engine ignition with verification (see AmbientLightRepair at the top of the file)
        AmbientLightRepair.strike(char, targetUuid, info)
        return true
    end

    queue:enqueue({
        name = "GoToSconce",
        precondition = function(char) return StateChecks.isIdle(char) end,
        execute = function(char)
            local nowT = Ext.Utils.MonotonicTime()
            local tpl = LightTrace.tpl(sconceUuid)
            if not IsSafeWorldObject(sconceUuid, "light") then
                BinLight.unsafe(sconceUuid, tpl)
                queue.queue = {}
                return
            end
            local best, all = LightTrace.pickApproach(char, sconceUuid)
            if not best then
                LightTrace.line("GoToSconce", "%s (%s): no approach point at all -> cool down %ds",
                    tpl, tostring(sconceUuid), math.floor(LIGHT_TARGET_COOLDOWN / 1000))
                Blacklist[sconceUuid] = nowT + LIGHT_TARGET_COOLDOWN
                queue.queue = {}
                return
            end
            local okReach, hDist, vDelta = LightTrace.metrics(char, sconceUuid)
            if best.usedRaw then
                LightTrace.line("GoToSconce", "no AI-grid-approved point for %s - relying on engine clamp", tpl)
            end
            LightTrace.line("GoToSconce", "%s (%s) | dist=%.2f dy=%.2f | points=%d | chosen=(%.2f,%.2f,%.2f) want=%.1f charDist=%s raw=%s",
                tpl, tostring(sconceUuid), hDist, vDelta, #all,
                best.x, best.y, best.z, best.want,
                best.charDist and string.format("%.2f", best.charDist) or "?",
                tostring(best.raw == true))
            queue._lightApproach = best
            Osi.CharacterMoveToPosition(char, best.x, best.y, best.z, "Walk", "")
        end,
        completion = function(char)
            if #queue.queue == 0 then return true end
            local okReach, hDist, vDelta = LightTrace.metrics(char, sconceUuid)
            if not okReach then return true end
            local moving = (Osi.IsMoving(char) == 1)
            local arrived = (hDist <= LIGHT_ARRIVE_H) and (vDelta <= LIGHT_ARRIVE_V) and not moving
            local action = queue.currentAction
            local stillMs = action and action._lastMoveMs and (Ext.Utils.MonotonicTime() - action._lastMoveMs) or 0
            -- Stalled but close enough to light it anyway (ignition radius is what matters!)
            local stalledClose = (hDist <= LIGHT_IGNITE_H) and (vDelta <= LIGHT_IGNITE_V) and stillMs >= 1200
            local key = CleanUuid(char) or char
            local nowT = Ext.Utils.MonotonicTime()
            if (nowT - (LightTrace.lastProgress[key] or 0)) >= 700 then
                LightTrace.lastProgress[key] = nowT
                LightTrace.line("walk", "%s -> %s | dist=%.2f dy=%.2f moving=%s still=%.1fs | arrived=%s stalledClose=%s",
                    tostring(char), LightTrace.tpl(sconceUuid), hDist, vDelta,
                    tostring(moving), stillMs / 1000.0, tostring(arrived), tostring(stalledClose))
            end
            if stalledClose and not arrived then
                LightTrace.line("walk", "%s could not close the last %.1fm -> lighting from where it stands",
                    tostring(char), hDist)
            end
            return arrived or stalledClose
        end,
        onTimeout = function(char)
            LightTrace.line("GoToSconce", "timeout for %s (%s) - retrying later",
                LightTrace.tpl(sconceUuid), tostring(sconceUuid))
            Blacklist[sconceUuid] = Ext.Utils.MonotonicTime() + LIGHT_TARGET_COOLDOWN
        end,
    })

    AnimSystem.enqueueSmoothTurn(queue, "TurnToSconce", sconceUuid)

    queue:enqueue({
        name = "LightIt",
        customAnim = true,
        execute = function(char)
            IgniteSingleFixture(char, sconceUuid, true)
        end,
        duration = 1850,
    })

    if extraClusterUuids then
        for idx, extraUuid in ipairs(extraClusterUuids) do
            AnimSystem.enqueueSmoothTurn(queue, "TurnToClusterCandle_" .. tostring(idx), extraUuid)
            queue:enqueue({
                name = "LightClusterCandle_" .. tostring(idx),
                customAnim = true,
                execute = function(char)
                    IgniteSingleFixture(char, extraUuid, false)
                end,
                duration = 1150,
            })
        end
    end

    AnimSystem.enqueueGracefulExit(queue, "DoneLighting", AnimSystem.USE_ITEM)
end

local function CreateBedNapSequence(character, bedUuid)
    local queue = ActiveQueues[character]
    if not queue then return end
    queue.activityTag = "bed"
    local regenTimer = 0

    queue:enqueue({
        name = "WalkNearBed",
        execute = function(char)
            local tx, ty, tz = GetSmartApproachPosition(char, bedUuid, 1.3)
            if tx and (not IsInCamp(char)) and IsSafeWorldObject(bedUuid, "bed") then
                Osi.CharacterMoveToPosition(char, tx, ty, tz, "Walk", "")
            else
                queue.queue = {}
            end
        end,
        completion = function(char)
            if #queue.queue == 0 then return true end
            return StateChecks.isWithinReach(char, bedUuid, 2.55, 2.2) and Osi.IsMoving(char) == 0
        end,
    })
    queue:enqueue({
        name = "BedTiredRemark",
        execute = function(char)
            FaceTarget(char, bedUuid)
            TryPlayCompanionActionVoice(char, "rest_bed")
        end,
        completion = function(char)
            return not IsCharacterSpeakingBark(char, true)
        end,
        duration = 2600,
    })
    queue:enqueue({
        name = "GoToBed",
        execute = function(char)
            if (not IsInCamp(char)) and IsSafeWorldObject(bedUuid, "bed") then
                SetAmbientSeatFollowLock(char, true)
                Osi.Use(char, bedUuid, "")
            else
                queue.queue = {}
            end
        end,
        completion = function(char)
            if #queue.queue == 0 then return true end
            if Osi.IsReposed and Osi.IsReposed(char) == 1 then return true end
            local d = Osi.GetDistanceTo(char, bedUuid)
            return d and d < 1.9 and Osi.IsMoving(char) == 0
        end,
        onAbort = function(char)
            SetAmbientSeatFollowLock(char, false)
        end,
    })
    queue:enqueue({
        name = "Napping",
        duration = 12500,
        onAbort = function(char)
            SetAmbientSeatFollowLock(char, false)
        end,
        onTick = function(char)
            if not Config.BedRegen then return end
            local now = Ext.Utils.MonotonicTime()
            if now > regenTimer then
                local pct = Osi.GetHitpointsPercentage(char)
                if pct and pct < 100 then
                    Osi.SetHitpointsPercentage(char, math.min(100, pct + Config.RegenAmount))
                end
                regenTimer = now + 4000
            end
        end,
    })
    queue:enqueue({
        name = "WakeUp",
        execute = function(char)
            StandUpFromFurniture(char)
            pcall(Osi.PlaySound, char, "UI_HUD_ShortRest_Click")
            Ext.Timer.WaitFor(950, function()
                if IsOsirisReady() then
                    TryPlayCompanionActionVoice(char, "wake_bed")
                end
            end)
        end,
        duration = 2900,
    })
end

local function CreateSitSequence(character, chairUuid)
    local queue = ActiveQueues[character]
    if not queue then return end
    queue.activityTag = "chair"

    -- Build 04.3.6: say out loud which seat was chosen and how far it is, so a companion
    -- "vanishing" to a bench across the room is immediately visible in the log.
    do
        local h, v = AmbientSeat.metrics(character, chairUuid)
        local host = Osi.GetHostCharacter and Osi.GetHostCharacter() or nil
        local hostDist = host and Osi.GetDistanceTo(host, chairUuid) or nil
        Log(string.format("[SEAT] %s picked %s (%s) | dist=%.2f dy=%.2f hostDist=%s",
            tostring(character), AmbientSeat.tplName(chairUuid), tostring(chairUuid),
            h or -1, v or -1, hostDist and string.format("%.2f", hostDist) or "?"))
    end

    -- 04.3.11: arrival bookkeeping for the walk below
    local walkIssuedAt = 0
    local walkReissues = 0
    local stillX, stillZ, stillSince = nil, nil, 0

    queue:enqueue({
        name = "WalkNearSeat",
        execute = function(char)
            local tx, ty, tz = GetSmartApproachPosition(char, chairUuid, 1.1)
            if tx and IsSafeWorldObject(chairUuid, "seat") then
                Osi.CharacterMoveToPosition(char, tx, ty, tz, "Walk", "")
                walkIssuedAt = Ext.Utils.MonotonicTime()
                stillX, stillZ, stillSince = nil, nil, 0
            else
                Log("[SEAT] no approach point for " .. AmbientSeat.tplName(chairUuid) .. " -> seat dropped for now")
                Blacklist[chairUuid] = Ext.Utils.MonotonicTime() + 300000
                AmbientSeat.hardBlacklist[chairUuid] = true
                queue.queue = {}
            end
        end,
        completion = function(char)
            if #queue.queue == 0 then return true end
            local nowW = Ext.Utils.MonotonicTime()
            if not StateChecks.isWithinReach(char, chairUuid, 2.2, 1.6) then
                stillX, stillZ, stillSince = nil, nil, 0
                -- Still far away after 8 s: a party pull (or a follow-block toggle) can cancel the
                -- AI move silently and the companion then just stands there until the 25 s timeout.
                if walkIssuedAt > 0 and walkReissues < 2 and (nowW - walkIssuedAt) > 8000 then
                    local tx, ty, tz = GetSmartApproachPosition(char, chairUuid, 1.1)
                    if tx then
                        walkReissues = walkReissues + 1
                        walkIssuedAt = nowW
                        pcall(Osi.CharacterMoveToPosition, char, tx, ty, tz, "Walk", "")
                        Log(string.format("[SEAT] walk to %s restarted (%d/2) - %.1fm to go",
                            AmbientSeat.tplName(chairUuid), walkReissues,
                            Osi.GetDistanceTo and Osi.GetDistanceTo(char, chairUuid) or -1))
                    end
                end
                return false
            end
            if Osi.IsMoving(char) == 0 then return true end
            -- 04.3.11: Osi.IsMoving stays at 1 while the AI move order is still active, even after
            -- the companion has arrived. In reach + a standstill position for ~700 ms = arrived.
            local cx, cy, cz = Osi.GetPosition(char)
            if not cx then return false end
            if not stillX or (math.abs(cx - stillX) + math.abs(cz - stillZ)) > 0.12 then
                stillX, stillZ, stillSince = cx, cz, nowW
                return false
            end
            return (nowW - stillSince) >= 700
        end,
        onTimeout = function(char)
            -- 04.3.9: the walk action can run out of its 25 s while the companion is already
            -- standing right next to the bench (blocked approach point, party pull, a fight of
            -- two queues for the same seat). Banning that seat for 5 minutes was wrong - the
            -- pose itself is the only thing that can judge it.
            if StateChecks.isWithinReach(char, chairUuid, 2.8, 1.9) then
                Log("[SEAT] late arrival at " .. AmbientSeat.tplName(chairUuid)
                    .. " (walk timed out but the companion is in reach) -> trying to sit, no cooldown")
                return
            end
            Blacklist[chairUuid] = Ext.Utils.MonotonicTime() + 300000
            AmbientSeat.hardBlacklist[chairUuid] = true
            Log("[SEAT] could not reach " .. AmbientSeat.tplName(chairUuid) .. " -> cooldown 300s (kept)")
            StandUpFromFurniture(char)
        end,
        duration = 25000,
    })
    local startedAt = 0
    local relaxStartedAt = 0
    queue:enqueue({
        name = "SitOnSeat",
        execute = function(char)
            startedAt = Ext.Utils.MonotonicTime()
            if not IsSafeWorldObject(chairUuid, "seat") then
                queue.queue = {}
                return
            end
            -- Build 04.3.6: proximity-gated, engine-verified repose (no silent socket snap)
            if not AmbientSeat.sit(char, chairUuid) then
                queue.queue = {}
            end
        end,
        completion = function(char)
            if #queue.queue == 0 then return true end
            local elapsed = Ext.Utils.MonotonicTime() - startedAt
            if elapsed < 900 then return false end
            -- Only an actual repose counts as a successful sit (the old "close enough" test
            -- let a failed sit continue into RelaxingOnSeat with the follow block still on).
            return AmbientSeat.isSeated(char)
        end,
        onAbort = function(char)
            -- Build 04.3.5: stand up first; the follow block is released on ReposeRemoved
            StandUpFromFurniture(char)
        end,
    })
    -- 04.3.8: the tired remark now comes AFTER the pose is confirmed. Before, the remark could
    -- open an overhead PAD dialog and the engine then refused to repose a talking character -
    -- the companion walked to a perfectly good bench, failed to sit and blacklisted it.
    -- While seated a companion keeps the 3D vocal route only (no dialog can cancel the pose).
    queue:enqueue({
        name = "SeatTiredRemark",
        execute = function(char)
            if not AmbientSeat.isSeated(char) then return end
            TryPlayCompanionActionVoice(char, "rest_sit")
        end,
        completion = function(char)
            return not IsCharacterSpeakingBark(char, true)
        end,
        duration = 2600,
    })
    queue:enqueue({
        name = "RelaxingOnSeat",
        execute = function()
            relaxStartedAt = Ext.Utils.MonotonicTime()
        end,
        completion = function(char)
            -- If the bench geometry was blocked and the character never actually entered Repose,
            -- release after 3.5s instead of standing idle beside the bench for 25s.
            if relaxStartedAt > 0 and (Ext.Utils.MonotonicTime() - relaxStartedAt) > 3500 then
                if Osi.IsReposed and Osi.IsReposed(char) == 0 then
                    return true
                end
            end
            return false
        end,
        onAbort = function(char)
            StandUpFromFurniture(char)
        end,
        duration = math.random(18000, 32000),
    })
    queue:enqueue({
        name = "StandUp",
        execute = function(char)
            StandUpFromFurniture(char)
            Ext.Timer.WaitFor(950, function()
                if IsOsirisReady() then
                    TryPlayCompanionActionVoice(char, "rest_sit_done")
                end
            end)
        end,
        duration = 2700,
    })
end

local function CreateGroundRestSequence(character, host)
    local queue = ActiveQueues[character]
    if not queue then return end
    queue.activityTag = "ground_rest"

    if host then
        local dHost = Osi.GetDistanceTo(character, host)
        if dHost and dHost < 1.6 then
            queue:enqueue({
                name = "StepAsideForGroundRest",
                execute = function(char)
                    local cx, cy, cz = Osi.GetPosition(char)
                    if not cx then return end
                    local angle = math.random() * 6.2831853
                    local r = 1.6 + math.random() * 1.1
                    local rx = cx + math.cos(angle) * r
                    local rz = cz + math.sin(angle) * r
                    if Osi.FindValidPosition then
                        local ok, vx, vy, vz = pcall(Osi.FindValidPosition, rx, cy, rz, 2.2, char, 0)
                        if ok and vx then
                            Osi.CharacterMoveToPosition(char, vx, vy, vz, "Walk", "")
                        end
                    end
                end,
                completion = function(char)
                    return Osi.IsMoving(char) == 0
                end,
                duration = 2600,
            })
        end
    end

    local pool = GetGroundRestAnimations(character)
    local chosenAnim = pool[math.random(#pool)]

    -- Speak respite remark right before sitting down so Timeline lip-sync plays cleanly first!
    queue:enqueue({
        name = "GroundRestRemark",
        execute = function(char)
            TryPlayCompanionActionVoice(char, "rest_ground")
        end,
        completion = function(char)
            return not IsCharacterSpeakingBark(char, true)
        end,
        duration = 2700,
    })

    queue:enqueue({
        name = "GroundRest_" .. chosenAnim,
        customAnim = true,
        execute = function(char)
            AnimSystem.play(char, chosenAnim)
        end,
        duration = math.random(15000, 25000),
    })

    -- Smoothly play _End stand-up clip via StopAnimation(char, 0) + ~3.8s settle window!
    AnimSystem.enqueueGracefulExit(queue, "StandUpFromGround", chosenAnim)
end

local function CreateReadSequence(character, bookshelfUuid)
    local queue = ActiveQueues[character]
    if not queue then return end

    if CurrentReader ~= nil and CurrentReader ~= character then
        return
    end
    CurrentReader = character
    queue.activityTag = "books"

    local function unlockReader()
        if CurrentReader == character then
            CurrentReader = nil
        end
    end

    if bookshelfUuid then
        queue:enqueue({
            name = "GoToBookshelf",
            execute = function(char)
                local tx, ty, tz = GetSmartApproachPosition(char, bookshelfUuid, 1.1)
                if tx then
                    Osi.CharacterMoveToPosition(char, tx, ty, tz, "Walk", "")
                else
                    unlockReader()
                    queue.queue = {}
                end
            end,
            completion = function(char)
                if #queue.queue == 0 then return true end
                return StateChecks.isWithinReach(char, bookshelfUuid, 2.45, 2.8) and Osi.IsMoving(char) == 0
            end,
            onTimeout = unlockReader,
            onAbort = unlockReader,
        })
        queue:enqueue({
            name = "FaceBookshelf",
            execute = function(char)
                FaceTarget(char, bookshelfUuid)
            end,
            duration = 450,
            onAbort = unlockReader,
        })
    end

    local xpCount = 0
    local nextXpTime = 0
    local readAnim = AnimSystem.pickReadAnim(character)

    queue:enqueue({
        name = "ReadingBook",
        customAnim = true,
        duration = 12000,
        execute = function(char)
            if bookshelfUuid then AnimSystem.lookAt(char, bookshelfUuid, 6.0) end
            local _, vMode = TryPlayCompanionActionVoice(char, "read", { resumeAnim = readAnim })
            if vMode ~= "pad" then
                AnimSystem.play(char, readAnim)
            end
        end,
        onTick = function(char)
            local now = Ext.Utils.MonotonicTime()
            if xpCount < 5 and now > nextXpTime then
                SafeGiveXP(char, 2)
                xpCount = xpCount + 1
                nextXpTime = now + 2000
            end
        end,
        onTimeout = unlockReader,
        onAbort = unlockReader,
    })

    AnimSystem.enqueueGracefulExit(queue, "FinishReading", readAnim, unlockReader)
end

local function CreateCuriositySequence(character, objectUuid, allowSafeUse)
    local queue = ActiveQueues[character]
    if not queue then return end
    queue.activityTag = "curiosity"

    queue:enqueue({
        name = "GoToCuriosity",
        execute = function(char)
            local tx, ty, tz = GetSmartApproachPosition(char, objectUuid, 1.3)
            if tx then
                Osi.CharacterMoveToPosition(char, tx, ty, tz, "Walk", "")
            else
                queue.queue = {}
            end
        end,
        completion = function(char)
            if #queue.queue == 0 then return true end
            return StateChecks.isWithinReach(char, objectUuid, 2.65, 2.8) and Osi.IsMoving(char) == 0
        end,
    })

    AnimSystem.enqueueSmoothTurn(queue, "TurnToCuriosity", objectUuid)

    local ponderAnim = AnimSystem.PONDER

    queue:enqueue({
        name = "InspectCuriosity",
        customAnim = not allowSafeUse,
        execute = function(char)
            AnimSystem.lookAt(char, objectUuid, 5.0)
            local d = Osi.GetDistanceTo(char, objectUuid)
            local usedWorldProp = false
            if allowSafeUse and d and d < 3.0 and IsSafeWorldObject(objectUuid, "use") then
                Osi.Use(char, objectUuid, "")
                usedWorldProp = true
            end
            local _, vMode = TryPlayCompanionActionVoice(char, "inspect", {
                targetUuid = objectUuid,
                noTimelinePad = usedWorldProp,
                resumeAnim = (not usedWorldProp) and ponderAnim or nil,
            })
            if not usedWorldProp and vMode ~= "pad" then
                AnimSystem.play(char, ponderAnim)
            end
        end,
        duration = 7500,
    })

    if not allowSafeUse then
        AnimSystem.enqueueGracefulExit(queue, "DoneInspecting", ponderAnim)
    end
end

local function CreateDummyPracticeSequence(character, dummyUuid)
    local queue = ActiveQueues[character]
    if not queue then return end
    queue.activityTag = "dummy"

    queue:enqueue({
        name = "GoToDummy",
        execute = function(char)
            local tx, ty, tz = GetSmartApproachPosition(char, dummyUuid, 1.4)
            if tx then
                Osi.CharacterMoveToPosition(char, tx, ty, tz, "Walk", "")
            else
                queue.queue = {}
            end
        end,
        completion = function(char)
            if #queue.queue == 0 then return true end
            return StateChecks.isWithinReach(char, dummyUuid, 2.6, 2.5) and Osi.IsMoving(char) == 0
        end,
    })

    AnimSystem.enqueueSmoothTurn(queue, "TurnToDummy", dummyUuid)

    queue:enqueue({
        name = "PracticeAtDummy",
        customAnim = true,
        execute = function(char)
            AnimSystem.lookAt(char, dummyUuid, 3.5)
            if IsInCamp(char) and IsSafeWorldObject(dummyUuid, "wall") then
                Osi.UseSpell(char, dummyUuid, "Target_MainHandAttack")
            else
                AnimSystem.play(char, AnimSystem.USE_ITEM)
            end
            TryPlayCompanionActionVoice(char, "dummy", { noTimelinePad = true })
        end,
        duration = math.random(3000, 4800),
    })

    AnimSystem.enqueueGracefulExit(queue, "FinishPractice", AnimSystem.USE_ITEM)
end

local function CreateAttackWallSequence(character, wallUuid)
    local queue = ActiveQueues[character]
    if not queue then return end
    queue.activityTag = "wall"
    local hpBefore = nil

    queue:enqueue({
        name = "GoToWall",
        execute = function(char)
            local tx, ty, tz = GetSmartApproachPosition(char, wallUuid, 1.5)
            if tx then Osi.CharacterMoveToPosition(char, tx, ty, tz, "Run", "") end
        end,
        completion = function(char)
            local d = Osi.GetDistanceTo(char, wallUuid)
            return d and d < 2.6
        end,
    })

    queue:enqueue({
        name = "AttackWall",
        execute = function(char)
            if IsSafeWorldObject(wallUuid, "wall") then
                FaceTarget(char, wallUuid)
                hpBefore = Osi.GetHitpoints and Osi.GetHitpoints(wallUuid) or nil
                Osi.UseSpell(char, wallUuid, "Target_MainHandAttack")
            end
        end,
        duration = 2200,
        onComplete = function()
            local hpAfter = Osi.GetHitpoints and Osi.GetHitpoints(wallUuid) or nil
            if hpBefore and hpAfter and hpAfter >= hpBefore then
                Blacklist[wallUuid] = Ext.Utils.MonotonicTime() + 1800000
                Log("Wall resisted damage; blacklisting " .. tostring(wallUuid))
            else
                Blacklist[wallUuid] = Ext.Utils.MonotonicTime() + 5000
            end
        end,
    })
end

local function CreateArtSequence(character, artUuid)
    local queue = ActiveQueues[character]
    if not queue then return end
    queue.activityTag = "art"

    queue:enqueue({
        name = "GoToArt",
        execute = function(char)
            local tx, ty, tz = GetSmartApproachPosition(char, artUuid, 1.8)
            if tx then
                Osi.CharacterMoveToPosition(char, tx, ty, tz, "Walk", "")
            else
                queue.queue = {}
            end
        end,
        completion = function(char)
            if #queue.queue == 0 then return true end
            return StateChecks.isWithinReach(char, artUuid, 3.2, 3.0) and Osi.IsMoving(char) == 0
        end,
    })

    AnimSystem.enqueueSmoothTurn(queue, "TurnToArt", artUuid)

    local ponderAnim = AnimSystem.PONDER

    queue:enqueue({
        name = "LookAtArt",
        customAnim = true,
        execute = function(char)
            AnimSystem.lookAt(char, artUuid, 5.0)
            local _, vMode = TryPlayCompanionActionVoice(char, "inspect", {
                targetUuid = artUuid,
                resumeAnim = ponderAnim,
            })
            if vMode ~= "pad" then
                AnimSystem.play(char, ponderAnim)
            end
        end,
        duration = math.random(6500, 10500),
    })

    AnimSystem.enqueueGracefulExit(queue, "DoneAdmiring", ponderAnim)
end

local function CreateRummageSequence(character, containerUuid, isCorpse)
    local queue = ActiveQueues[character]
    if not queue then return end
    queue.activityTag = "rummage"

    queue:enqueue({
        name = "GoToContainer",
        execute = function(char)
            local tx, ty, tz = GetSmartApproachPosition(char, containerUuid, 1.1)
            if tx then
                Osi.CharacterMoveToPosition(char, tx, ty, tz, "Walk", "")
            else
                queue.queue = {}
            end
        end,
        completion = function(char)
            if #queue.queue == 0 then return true end
            return StateChecks.isWithinReach(char, containerUuid, 2.45, 2.2) and Osi.IsMoving(char) == 0
        end,
    })

    AnimSystem.enqueueSmoothTurn(queue, "TurnToContainer", containerUuid)

    queue:enqueue({
        name = "InspectContainer",
        customAnim = true,
        execute = function(char)
            AnimSystem.lookAt(char, containerUuid, 3.0)
            pcall(Osi.PlaySound, char, "UI_HUD_Item_PickUp")
            local _, vMode = TryPlayCompanionActionVoice(char, "scavenge_empty")
            if vMode ~= "pad" then
                AnimSystem.play(char, AnimSystem.INSPECT_NEAR)
            end
        end,
        duration = isCorpse and 3000 or 2700,
    })

    AnimSystem.enqueueGracefulExit(queue, "DoneRummaging", AnimSystem.INSPECT_NEAR)
end

local function CreatePickupSequence(character, itemUuid)
    local queue = ActiveQueues[character]
    if not queue then return end
    queue.activityTag = "pickup"

    queue:enqueue({
        name = "GoToItem",
        execute = function(char)
            local tx, ty, tz = GetSmartApproachPosition(char, itemUuid, 1.0)
            if tx then
                Osi.CharacterMoveToPosition(char, tx, ty, tz, "Walk", "")
            else
                queue.queue = {}
            end
        end,
        completion = function(char)
            local txCheck = Blacklist[itemUuid]
            if txCheck and txCheck > Ext.Utils.MonotonicTime() + 1700000 and #queue.queue == 0 then return true end
            local d = Osi.GetDistanceTo(char, itemUuid)
            return d and d < 2.2 and Osi.IsMoving(char) == 0
        end,
        onTimeout = function(char) AnimSystem.gracefulStop(char) end,
    })

    queue:enqueue({
        name = "PickupItem",
        execute = function(char)
            if not IsSafeWorldObject(itemUuid, "pickup") then return end
            FaceTarget(char, itemUuid)
            pcall(Osi.PlaySound, char, "UI_HUD_Item_PickUp")
            TryPlayCompanionActionVoice(char, "pickup")
            local amount = 1
            local okStack, stack = pcall(Osi.GetStackAmount, itemUuid)
            if okStack and stack and stack > 1 then amount = stack end
            pcall(Osi.ToInventory, itemUuid, char, amount, 1, 0)
            Ext.Timer.WaitFor(250, function()
                pcall(function()
                    if Osi.Exists and Osi.Exists(itemUuid) == 1 and Osi.IsEquipped and Osi.IsEquipped(itemUuid) == 1 then
                        Osi.Unequip(char, itemUuid)
                    end
                end)
            end)
        end,
        duration = 1400,
    })
end

-- ============================================================================
-- 7B. BUILD 03: SMART EXPLORER ENGINE (SCAVENGER, AUTO-SELL, TRAP STOP, WASH)
-- ============================================================================

local function GetEntityWorldPos(entity, uuid)
    if entity and entity.Transform and entity.Transform.Transform and entity.Transform.Transform.Translate then
        local tr = entity.Transform.Transform.Translate
        local x, y, z = tr[1], tr[2], tr[3]
        if x and y and z then return x, y, z end
    end
    if Osi.GetPosition then
        local ok, x, y, z = pcall(Osi.GetPosition, uuid)
        if ok and x then return x, y, z end
    end
    return nil, nil, nil
end

local function ResolveEntity(h)
    if not h then return nil end
    if type(h) == "string" then
        local ok, e = pcall(Ext.Entity.Get, h)
        return ok and e or nil
    end
    local okGet, resolved = pcall(Ext.Entity.Get, h)
    if okGet and resolved ~= nil then
        return resolved
    end
    if type(h) == "userdata" or type(h) == "table" then
        return h
    end
    return nil
end

local function EnsureAutoSellStorage()
    PersistentVars = PersistentVars or {}
    if type(PersistentVars.AutoSellLedger) ~= "table" then
        PersistentVars.AutoSellLedger = {}
    end
    if type(PersistentVars.AutoSellTemplates) ~= "table" then
        PersistentVars.AutoSellTemplates = {}
    end
end

local MINOR_CONTAINER_ALLOW = {
    "vase", "urn", "jar", "amphora", "crate", "barrel", "cask",
    "sack", "burlap", "basket", "box_wood", "pouch_loot",
}

local MINOR_CONTAINER_DENY = {
    "chest", "coffin", "sarcophagus", "reliquary", "safe", "strongbox",
    "altar", "shrine", "pedestal", "corpse", "skeleton", "buried",
    "gilded", "ornate", "heavy", "mimic", "wardrobe", "desk", "bookcase",
    "bookshelf", "firewine", "kobold", "smokepowder", "gunpowder",
    "runepowder", "oil", "water", "acid", "brine", "explosive", "caustic",
}

local function IsMinorScavengeContainerName(name, lower)
    local l = lower or string.lower(tostring(name or ""))
    for i = 1, #MINOR_CONTAINER_DENY do
        if string.find(l, MINOR_CONTAINER_DENY[i], 1, true) ~= nil then
            return false
        end
    end
    for i = 1, #MINOR_CONTAINER_ALLOW do
        if string.find(l, MINOR_CONTAINER_ALLOW[i], 1, true) ~= nil then
            return true
        end
    end
    return false
end

local function IsSafeScavengeContainer(uuid)
    if not uuid then return false end
    local ok, safe = pcall(function()
        if Osi.Exists and Osi.Exists(uuid) == 0 then return false end
        if Osi.IsLocked and Osi.IsLocked(uuid) == 1 then return false end
        if Osi.IsTrapArmed and Osi.IsTrapArmed(uuid) == 1 then return false end
        if Osi.IsTrap and Osi.IsTrap(uuid) == 1 then return false end
        if Osi.IsStoryItem and Osi.IsStoryItem(uuid) == 1 then return false end
        if not IsPartyOwnedOrUnowned(uuid) then return false end

        local e = Ext.Entity.Get(uuid)
        if e then
            if e.ServerCharacter ~= nil then return false end -- Never touch a Mimic/creature!
            if e.ServerItem then
                if e.ServerItem.StoryItem or e.ServerItem.InteractionDisabled then return false end
                local tpl = e.ServerItem.Template
                if tpl then
                    if tpl.IsTrap or tpl.IsStoryItem then return false end
                    if not IsMinorScavengeContainerName(tpl.Name, nil) then return false end
                end
            end
        end
        return true
    end)
    return ok and safe or false
end

local ROTTEN_TOKENS = {
    "rotten", "spoiled", "moldy", "ruined_food", "poisoned_apple", "putrid", "wormy",
}

local SPECIAL_RARE_TOKENS = {
    "infernal", "mithral", "adamantine", "soulcoin", "soul_coin",
    "noblestalk", "tadpole", "sussur", "orphic", "ironflask", "iron_flask",
    "musicbox", "idol_", "_idol", "dye_", "ledger", "diary", "journal",
    "artifact", "artefact", "moonlantern", "pixie", "grym", "karsus",
    "necromancy", "blood_of_lathander", "crest", "rune_slate",
}

local BOOK_KEY_TOKENS = {
    "key_", "_key", "keyring", "book_", "_book", "note_", "_note",
    "letter_", "_letter", "parchment", "placard", "map_", "_map",
}

local GEAR_TOKENS = {
    "wpn_", "arm_", "mag_", "shield_", "ring_", "_ring", "amu_", "amulet",
    "cloak_", "boots_", "gloves_", "helmet_", "circlet", "hat_", "robe_",
    "instrument", "musical",
}

local CONSUMABLE_ALERT_TOKENS = {
    "potion", "scroll", "elixir", "alch_solution", "grenade", "arrow_",
    "toxin", "coating", "oil_of_", "poison_", "antitoxin", "revivify",
}

local JUNK_CLUTTER_TOKENS = {
    "bucket", "broom", "mop", "rag_", "_rag", "rags", "bone", "skull",
    "bottle", "flask", "vial", "mug", "tankard", "jug_ceramic", "pitcher_clay",
    "cup_clay", "cup_wood", "cup_tin", "plate_wood", "plate_ceramic", "plate_tin",
    "bowl_wood", "bowl_ceramic", "spoon_wood", "fork_iron", "knife_table",
    "pan_", "pot_cook", "cauldron", "kettle", "tongs", "scissors", "shears",
    "inkpot", "quill", "rope", "bedroll", "burlap", "torch", "candle",
    "soap", "sponge", "shovel", "pickaxe", "hammer_tool", "saw_tool",
    "pliers", "paintbrush", "yarn", "spool", "comb_", "brush_", "mirror_hand",
    "chamberpot", "spittoon", "ash_pile", "charcoal", "rotten", "empty",
}

local VALUABLE_TRADE_TOKENS = {
    "gem_", "_gem", "ingot", "silver", "chalice", "goblet", "gold_cup",
    "gold_plate", "plate_rich", "cup_rich", "carafe_rich", "decanter_rich",
    "candelabra_rich", "statuette", "pearl", "ruby", "sapphire", "emerald",
    "diamond", "amethyst", "onyx", "jade", "malachite", "agate", "topaz",
    "amber", "peridot", "jacinth", "aquamarine", "turquoise", "incense",
    "painting_",
}

local function ContainsAnyToken(str, list)
    for i = 1, #list do
        if string.find(str, list[i], 1, true) ~= nil then
            return true
        end
    end
    return false
end

local function GetItemInspectionMetadata(itemUuid)
    local meta = {
        name = "",
        statsId = "",
        templateId = "",
        rarity = 0,
        unique = false,
        unitValue = 0,
        weightGrams = 500,
        supplyValue = 0,
        isStory = false,
        isKey = false,
        isBook = false,
        isEquipable = false,
        isConsumable = false,
        isAlchemy = false,
        nonTradable = false,
        canPickUp = true,
        stackAmount = 1,
    }

    pcall(function()
        if Osi.CanPickUp and Osi.CanPickUp(itemUuid) == 0 then meta.canPickUp = false end
        if Osi.IsMovable and Osi.IsMovable(itemUuid) == 0 then meta.canPickUp = false end
        if Osi.IsStoryItem and Osi.IsStoryItem(itemUuid) == 1 then meta.isStory = true end
        if Osi.IsEquipable and Osi.IsEquipable(itemUuid) == 1 then meta.isEquipable = true end
        if Osi.IsConsumable and Osi.IsConsumable(itemUuid) == 1 then meta.isConsumable = true end
        if Osi.GetTemplate then
            local t = Osi.GetTemplate(itemUuid)
            if type(t) == "string" and t ~= "" then
                meta.templateId = t
                meta.name = t
            end
        end
        if Osi.GetStackAmount then
            local st = Osi.GetStackAmount(itemUuid)
            if type(st) == "number" and st > 1 then meta.stackAmount = st end
        end
        if Osi.ItemGetGoldValue then
            local gv = Osi.ItemGetGoldValue(itemUuid)
            if type(gv) == "number" and gv > 0 then meta.unitValue = gv end
        end
    end)

    pcall(function()
        local e = Ext.Entity.Get(itemUuid)
        if not e then return end

        if e.InventoryNonTradable ~= nil then
            meta.nonTradable = true
        end
        if e.Value then
            if type(e.Value.Value) == "number" then meta.unitValue = e.Value.Value end
            if type(e.Value.Rarity) == "number" then meta.rarity = e.Value.Rarity end
            if e.Value.Unique == true then meta.unique = true end
        end
        if e.Data then
            if type(e.Data.Weight) == "number" and e.Data.Weight >= 0 then
                meta.weightGrams = e.Data.Weight
            end
            if e.Data.StatsId and tostring(e.Data.StatsId) ~= "" then
                meta.statsId = tostring(e.Data.StatsId)
            end
        end
        if e.CampSupply and type(e.CampSupply.Amount) == "number" and e.CampSupply.Amount > 0 then
            meta.supplyValue = e.CampSupply.Amount
        end
        if e.ServerItem then
            if e.ServerItem.StoryItem == true then meta.isStory = true end
            if e.ServerItem.CanBePickedUp == false then meta.canPickUp = false end
            if meta.statsId == "" and e.ServerItem.Stats and tostring(e.ServerItem.Stats) ~= "" then
                meta.statsId = tostring(e.ServerItem.Stats)
            end
            local tpl = e.ServerItem.Template
            if tpl then
                if tpl.Name and tostring(tpl.Name) ~= "" then
                    meta.name = tostring(tpl.Name)
                    if meta.templateId == "" then meta.templateId = meta.name end
                end
                if tpl.IsKey == true then meta.isKey = true end
                if type(tpl.BookType) == "number" and tpl.BookType > 0 then meta.isBook = true end
                if tpl.CanBePickedUp == false then meta.canPickUp = false end
                if tpl.EquipmentTypeID then
                    local eqId = tostring(tpl.EquipmentTypeID)
                    if eqId ~= "" and not string.find(eqId, "00000000-0000-0000-0000-000000000000", 1, true) then
                        meta.isEquipable = true
                    end
                end
                if tpl.DisplayNameAlchemy and tpl.DisplayNameAlchemy.Handle and tpl.DisplayNameAlchemy.Handle.Handle then
                    local ah = tostring(tpl.DisplayNameAlchemy.Handle.Handle)
                    if ah ~= "" and not string.find(ah, "00000000", 1, true) then
                        meta.isAlchemy = true
                    end
                end
            end
        end

        if meta.statsId ~= "" and meta.supplyValue == 0 and Ext.Stats and Ext.Stats.Get then
            local stObj = Ext.Stats.Get(meta.statsId)
            if stObj and type(stObj.SupplyValue) == "number" and stObj.SupplyValue > 0 then
                meta.supplyValue = stObj.SupplyValue
            end
        end
    end)

    return meta
end

-- Returns: actionCategory, subType, meta
-- Categories:
--   "SKIP_JUNK"        : ignore completely (buckets, empty bottles, rotten food, immovable props)
--   "TAKE_ESSENTIAL"   : transfer straight to Host (gold, thieves' tools, disarm kits, alchemy herbs)
--   "SEND_CAMP_SUPPLY" : teleport fresh food/drink straight to Traveller's Chest (0 kg party weight)
--   "CAMP_AUTOSELL"    : teleport non-quest trade valuables to Traveller's Chest & queue for trader auto-sell
--   "ALERT_PLAYER"     : leave untouched & call out to player (gear, scrolls, potions, books, keys, rares)
local function ClassifyScavengeItem(itemUuid, looseOnWorld)
    if not itemUuid then return "SKIP_JUNK", "invalid", nil end
    if Osi.Exists and Osi.Exists(itemUuid) == 0 then return "SKIP_JUNK", "missing", nil end

    local meta = GetItemInspectionMetadata(itemUuid)
    if not meta.canPickUp then
        return "SKIP_JUNK", "immovable", meta
    end

    local combined = string.lower(meta.name .. " " .. meta.statsId .. " " .. meta.templateId)

    -- Step 1: Rotten / spoiled food is always worthless clutter
    if ContainsAnyToken(combined, ROTTEN_TOKENS) then
        return "SKIP_JUNK", "rotten", meta
    end

    -- Step 2: Gold, Lockpicks & Trap Disarm Toolkits -> directly to Host wallet/inventory
    if string.find(combined, "loot_gold", 1, true)
        or string.find(combined, "goldcoin", 1, true)
        or string.find(combined, "obj_gold", 1, true)
        or meta.name == "Gold"
        or string.find(combined, "thievestools", 1, true)
        or string.find(combined, "thieves_tools", 1, true)
        or string.find(combined, "tool_thieves", 1, true)
        or string.find(combined, "trapdisarm", 1, true)
        or string.find(combined, "trap_disarm", 1, true)
    then
        return "TAKE_ESSENTIAL", "gold_or_tool", meta
    end

    -- Step 3: Story items, Uniques, Uncommon+ Rarity, and Special Quest/Crafting Materials -> Alert Player!
    if meta.isStory or meta.unique or meta.rarity >= 1 or ContainsAnyToken(combined, SPECIAL_RARE_TOKENS) then
        return "ALERT_PLAYER", "rare", meta
    end

    -- Step 4: Keys, Books, Notes, Letters, Maps -> Alert Player!
    if meta.isKey or meta.isBook or ContainsAnyToken(combined, BOOK_KEY_TOKENS) then
        return "ALERT_PLAYER", "book_key", meta
    end

    -- Step 5: Weapons, Armor, Rings, Amulets, Shields, Clothing, Instruments -> Alert Player!
    if meta.isEquipable or ContainsAnyToken(combined, GEAR_TOKENS) then
        return "ALERT_PLAYER", "gear", meta
    end

    -- Step 6: Fresh Camp Supplies (Food & Drink with SupplyValue > 0) -> Send straight to Camp Chest!
    if meta.supplyValue > 0
        or string.find(combined, "cons_food_", 1, true)
        or string.find(combined, "cons_drink_", 1, true)
        or string.find(combined, "supplypack", 1, true)
        or string.find(combined, "camp_supply", 1, true)
    then
        return "SEND_CAMP_SUPPLY", "supply", meta
    end

    -- Step 7: Pure Alchemy Ingredients -> directly to Host (auto-sorted into Alchemy Pouch!)
    if meta.isAlchemy
        or string.find(combined, "alch_ingred", 1, true)
        or string.find(combined, "alch_extract", 1, true)
        or (string.find(combined, "alch_", 1, true)
            and not string.find(combined, "solution", 1, true)
            and not string.find(combined, "grenade", 1, true)
            and not string.find(combined, "potion", 1, true)
            and not string.find(combined, "elixir", 1, true))
    then
        return "TAKE_ESSENTIAL", "alchemy", meta
    end

    -- Step 8: Combat Consumables (Potions, Scrolls, Elixirs, Arrows, Grenades, Coatings) -> Alert Player!
    if ContainsAnyToken(combined, CONSUMABLE_ALERT_TOKENS)
        or (meta.isConsumable
            and not string.find(combined, "soap", 1, true)
            and not string.find(combined, "sponge", 1, true))
    then
        return "ALERT_PLAYER", "consumable", meta
    end

    -- Step 9: Household Clutter Blacklist (buckets, empty bottles/flasks, rags, bones, cheap plates/mugs)
    -- Also do not strip wall paintings hanging in the world (paintings inside containers ARE trade goods!)
    if looseOnWorld and string.find(combined, "painting", 1, true) then
        return "SKIP_JUNK", "wall_art", meta
    end
    if ContainsAnyToken(combined, JUNK_CLUTTER_TOKENS) then
        return "SKIP_JUNK", "clutter", meta
    end

    -- Step 10: Valuable Non-Quest Trade Goods -> Camp Chest Auto-Sell Queue
    if meta.nonTradable then
        return "SKIP_JUNK", "nontradable", meta
    end

    local minVal = tonumber(Config.MinSellValue) or 10
    local weightKg = math.max(0.05, (meta.weightGrams or 500) / 1000.0)
    local valPerKg = (meta.unitValue or 0) / weightKg

    if ContainsAnyToken(combined, VALUABLE_TRADE_TOKENS) and (meta.unitValue or 0) >= math.min(5, minVal) then
        return "CAMP_AUTOSELL", "valuable", meta
    end

    if (meta.unitValue or 0) >= minVal and (valPerKg >= 10.0 or (meta.unitValue or 0) >= 25) then
        return "CAMP_AUTOSELL", "trade_good", meta
    end

    return "SKIP_JUNK", "low_value", meta
end

local function QueueItemForCampAutoSell(itemUuid, host, meta)
    EnsureAutoSellStorage()
    local clean = CleanUuid(itemUuid)
    local tplKey = (meta and meta.templateId ~= "" and meta.templateId) or (meta and meta.name) or nil
    local qty = (meta and meta.stackAmount) or 1

    local okSend = pcall(Osi.SendToCampChest, itemUuid, host)
    if not okSend then return false end

    if clean then
        PersistentVars.AutoSellLedger[clean] = true
    end
    if tplKey and tplKey ~= "" then
        PersistentVars.AutoSellTemplates[tplKey] = (PersistentVars.AutoSellTemplates[tplKey] or 0) + qty
    end
    ScavengeStats.campValuables = ScavengeStats.campValuables + qty
    Log(string.format("SmartScavenger -> Camp Chest (auto-sell queued): %s x%d (unit=%dg)", tostring(tplKey or itemUuid), qty, meta and meta.unitValue or 0))
    return true
end

local function AlertPlayerAboutFind(char, targetUuid, subType)
    local now = Ext.Utils.MonotonicTime()
    local cleanTarget = CleanUuid(targetUuid) or tostring(targetUuid)
    if AlertedObjects[cleanTarget] then return end
    AlertedObjects[cleanTarget] = true

    if now < NextAlertTime then return end
    NextAlertTime = now + 15000

    local handle = LOCA_HANDLES.CalloutRare
    local fallback = "Something special right here!"
    local voiceCat = "alert_rare"
    if subType == "gear" then
        handle = LOCA_HANDLES.CalloutGear
        fallback = "Found equipment here — take a look!"
        voiceCat = "alert_gear"
    elseif subType == "consumable" then
        handle = LOCA_HANDLES.CalloutConsum
        fallback = "Potion or scroll over here!"
        voiceCat = "alert_consumable"
    elseif subType == "book_key" then
        handle = LOCA_HANDLES.CalloutBookKey
        fallback = "Key or writings here — check this!"
        voiceCat = "alert_book_key"
    end

    ScavengeStats.alerts = ScavengeStats.alerts + 1
    FaceTarget(char, targetUuid)
    pcall(Osi.PlaySound, char, "UI_HUD_Item_Map_Ping")
    local _, vMode = TryPlayCompanionActionVoice(char, voiceCat)
    local msgText = GetLocalizedText(handle, fallback)
    if vMode == "pad" and Ext and Ext.Timer and Ext.Timer.WaitFor then
        -- Let the companion's spoken overhead line finish before showing the item-category callout!
        Ext.Timer.WaitFor(2900, function()
            if IsOsirisReady() and Osi.Exists(char) == 1 and Osi.IsDead(char) == 0 then
                SafeSay(char, msgText)
            end
        end)
    else
        SafeSay(char, msgText)
    end
    Log(string.format("SmartScavenger callout (%s) by %s on %s", tostring(subType), tostring(char), tostring(targetUuid)))
    return vMode
end

local function GetItemsInsideContainer(containerUuid, finderChar)
    local items = {}
    local seen = {}
    local function pushUuid(u)
        if not u then return end
        local k = CleanUuid(u) or u
        if not seen[k] then
            seen[k] = true
            table.insert(items, u)
        end
    end

    pcall(function()
        local ce = Ext.Entity.Get(containerUuid)
        if ce and ce.ServerItem and not ce.ServerItem.TreasureGenerated then
            if Osi.GenerateItems then
                pcall(Osi.GenerateItems, finderChar, containerUuid)
            end
            if not ce.ServerItem.TreasureGenerated and ce.ServerItem.Template and ce.ServerItem.Template.InventoryList and Osi.GenerateTreasure then
                for _, tId in pairs(ce.ServerItem.Template.InventoryList) do
                    if tId and tostring(tId) ~= "" then
                        pcall(Osi.GenerateTreasure, containerUuid, tostring(tId), -1, finderChar)
                    end
                end
            end
        end

        if ce and ce.InventoryOwner and ce.InventoryOwner.Inventories then
            for _, invHandle in pairs(ce.InventoryOwner.Inventories) do
                local invEnt = ResolveEntity(invHandle)
                if invEnt and invEnt.InventoryContainer and invEnt.InventoryContainer.Items then
                    for _, slotData in pairs(invEnt.InventoryContainer.Items) do
                        local itemEnt = slotData and ResolveEntity(slotData.Item) or nil
                        if itemEnt and itemEnt.Uuid and itemEnt.Uuid.EntityUuid then
                            pushUuid(tostring(itemEnt.Uuid.EntityUuid))
                        end
                    end
                end
            end
        end
    end)

    return items
end

local function InspectAndScavengeContainer(char, host, containerUuid)
    if not IsSafeScavengeContainer(containerUuid) then return nil end

    local items = GetItemsInsideContainer(containerUuid, char)
    if #items == 0 then
        local _, vMode = TryPlayCompanionActionVoice(char, "scavenge_empty")
        Blacklist[containerUuid] = Ext.Utils.MonotonicTime() + 1800000 -- 30m: empty minor container
        return vMode
    end

    local bestAlertType = nil
    local tookAny = false

    for _, itemUuid in ipairs(items) do
        if Osi.Exists(itemUuid) == 1 and IsPartyOwnedOrUnowned(itemUuid) then
            local action, subType, meta = ClassifyScavengeItem(itemUuid, false)
            local qty = (meta and meta.stackAmount) or 1

            if action == "TAKE_ESSENTIAL" then
                pcall(Osi.ToInventory, itemUuid, host, qty, 1, 0)
                ScavengeStats.essentials = ScavengeStats.essentials + qty
                tookAny = true
                Log("SmartScavenger -> Host essential (" .. tostring(subType) .. "): " .. tostring(meta and meta.name or itemUuid))
            elseif action == "SEND_CAMP_SUPPLY" then
                if pcall(Osi.SendToCampChest, itemUuid, host) then
                    ScavengeStats.supplies = ScavengeStats.supplies + qty
                    tookAny = true
                    Log("SmartScavenger -> Camp Chest supply: " .. tostring(meta and meta.name or itemUuid))
                end
            elseif action == "CAMP_AUTOSELL" then
                if Config.AutoSellTrader then
                    if QueueItemForCampAutoSell(itemUuid, host, meta) then
                        tookAny = true
                    end
                end
            elseif action == "ALERT_PLAYER" then
                -- Priority: rare > gear > book_key > consumable
                if bestAlertType == nil
                    or subType == "rare"
                    or (subType == "gear" and bestAlertType ~= "rare")
                then
                    bestAlertType = subType
                end
            end
        end
    end

    if tookAny then
        pcall(Osi.PlaySound, char, "UI_HUD_Item_PickUp")
    end
    local vMode = nil
    if bestAlertType ~= nil then
        vMode = AlertPlayerAboutFind(char, containerUuid, bestAlertType)
    elseif tookAny then
        local _, m = TryPlayCompanionActionVoice(char, "scavenge_found")
        vMode = m
    else
        local _, m = TryPlayCompanionActionVoice(char, "scavenge_empty")
        vMode = m
    end

    Blacklist[containerUuid] = Ext.Utils.MonotonicTime() + 1800000
    return vMode
end

local function CreateSmartScavengeContainerSequence(character, host, containerUuid)
    local queue = ActiveQueues[character]
    if not queue then return end
    queue.activityTag = "smart_scavenge"

    queue:enqueue({
        name = "GoToMinorContainer",
        execute = function(char)
            local tx, ty, tz = GetSmartApproachPosition(char, containerUuid, 1.1)
            if tx then
                Osi.CharacterMoveToPosition(char, tx, ty, tz, "Walk", "")
            else
                queue.queue = {}
            end
        end,
        completion = function(char)
            if #queue.queue == 0 then return true end
            return StateChecks.isWithinReach(char, containerUuid, 2.45, 2.2) and Osi.IsMoving(char) == 0
        end,
        onTimeout = function(char) AnimSystem.gracefulStop(char) end,
    })

    AnimSystem.enqueueSmoothTurn(queue, "TurnToMinorContainer", containerUuid)

    queue:enqueue({
        name = "ScavengeContainer",
        customAnim = true,
        execute = function(char)
            AnimSystem.lookAt(char, containerUuid, 3.0)
            local vMode = InspectAndScavengeContainer(char, host, containerUuid)
            if vMode ~= "pad" then
                AnimSystem.play(char, AnimSystem.INSPECT_NEAR)
            end
        end,
        duration = math.random(2500, 3400),
    })

    AnimSystem.enqueueGracefulExit(queue, "FinishScavenge", AnimSystem.INSPECT_NEAR)
end

local function CreateSmartLooseItemSequence(character, host, itemUuid)
    local queue = ActiveQueues[character]
    if not queue then return end
    queue.activityTag = "smart_pickup"

    queue:enqueue({
        name = "GoToSmartItem",
        execute = function(char)
            local tx, ty, tz = GetSmartApproachPosition(char, itemUuid, 1.0)
            if tx then
                Osi.CharacterMoveToPosition(char, tx, ty, tz, "Walk", "")
            else
                queue.queue = {}
            end
        end,
        completion = function(char)
            if #queue.queue == 0 then return true end
            return StateChecks.isWithinReach(char, itemUuid, 2.3, 2.2) and Osi.IsMoving(char) == 0
        end,
        onTimeout = function(char) AnimSystem.gracefulStop(char) end,
    })

    queue:enqueue({
        name = "ProcessSmartItem",
        execute = function(char)
            if Osi.Exists(itemUuid) == 0 then return end
            if Osi.IsInInventory and Osi.IsInInventory(itemUuid) == 1 then return end
            if Osi.IsTrapArmed and Osi.IsTrapArmed(itemUuid) == 1 then return end
            if not IsPartyOwnedOrUnowned(itemUuid) then return end

            FaceTarget(char, itemUuid)

            local action, subType, meta = ClassifyScavengeItem(itemUuid, true)
            local qty = (meta and meta.stackAmount) or 1

            if action == "TAKE_ESSENTIAL" then
                pcall(Osi.PlaySound, char, "UI_HUD_Item_PickUp")
                pcall(Osi.ToInventory, itemUuid, host, qty, 1, 0)
                ScavengeStats.essentials = ScavengeStats.essentials + qty
                TryPlayCompanionActionVoice(char, "pickup")
            elseif action == "SEND_CAMP_SUPPLY" then
                pcall(Osi.PlaySound, char, "UI_HUD_Item_PickUp")
                if pcall(Osi.SendToCampChest, itemUuid, host) then
                    ScavengeStats.supplies = ScavengeStats.supplies + qty
                end
                TryPlayCompanionActionVoice(char, "pickup")
            elseif action == "CAMP_AUTOSELL" then
                if Config.AutoSellTrader then
                    pcall(Osi.PlaySound, char, "UI_HUD_Item_PickUp")
                    QueueItemForCampAutoSell(itemUuid, host, meta)
                    TryPlayCompanionActionVoice(char, "pickup")
                end
            elseif action == "ALERT_PLAYER" then
                AlertPlayerAboutFind(char, itemUuid, subType)
            end
            Blacklist[itemUuid] = Ext.Utils.MonotonicTime() + 3600000
        end,
        duration = math.random(1200, 1900),
    })
end

local function GetCampChestUuids()
    local chests = {}
    local seen = {}
    local function addChest(u)
        if not u then return end
        local k = CleanUuid(u) or u
        if not seen[k] then
            seen[k] = true
            table.insert(chests, u)
        end
    end

    pcall(function()
        if Osi.DB_Camp_UserCampChest then
            local rows = Osi.DB_Camp_UserCampChest:Get(nil, nil)
            if rows then
                for _, r in pairs(rows) do
                    if r[2] then addChest(r[2]) end
                end
            end
        end
    end)

    pcall(function()
        local campEnts = Ext.Entity.GetAllEntitiesWithComponent("CampChest")
        if campEnts then
            for _, h in pairs(campEnts) do
                local ce = ResolveEntity(h)
                if ce and ce.Uuid and ce.Uuid.EntityUuid then
                    addChest(tostring(ce.Uuid.EntityUuid))
                end
            end
        end
    end)

    return chests
end

local function CollectCampChestItems(chests)
    local itemList = {}
    local seen = {}
    local function push(u)
        if not u then return end
        local k = CleanUuid(u) or u
        if not seen[k] then
            seen[k] = true
            table.insert(itemList, u)
        end
    end

    for _, chestUuid in ipairs(chests) do
        pcall(function()
            local ce = Ext.Entity.Get(chestUuid)
            if ce and ce.InventoryOwner and ce.InventoryOwner.Inventories then
                for _, invH in pairs(ce.InventoryOwner.Inventories) do
                    local invE = ResolveEntity(invH)
                    if invE and invE.InventoryContainer and invE.InventoryContainer.Items then
                        for _, slotData in pairs(invE.InventoryContainer.Items) do
                            local itemE = slotData and ResolveEntity(slotData.Item) or nil
                            if itemE and itemE.Uuid and itemE.Uuid.EntityUuid then
                                push(tostring(itemE.Uuid.EntityUuid))
                            end
                        end
                    end
                end
            end
        end)
    end

    -- Also check direct ledger UUIDs via IsInInventoryOf (supports pure Osiris & nested pouches in Camp Chest)
    if PersistentVars and PersistentVars.AutoSellLedger and Osi.IsInInventoryOf then
        for cleanUuid, _ in pairs(PersistentVars.AutoSellLedger) do
            for _, chestUuid in ipairs(chests) do
                local okIn, isIn = pcall(Osi.IsInInventoryOf, cleanUuid, chestUuid)
                if okIn and isIn == 1 then
                    push(cleanUuid)
                    break
                end
            end
        end
    end

    return itemList
end

local function ExecuteAutoSellAtTrader(player, trader)
    if not IsOsirisReady() then return end
    if not Config.AutoSellTrader then return end
    if not player or not trader then return end

    EnsureAutoSellStorage()
    if next(PersistentVars.AutoSellLedger) == nil and next(PersistentVars.AutoSellTemplates) == nil then
        return
    end

    local now = Ext.Utils.MonotonicTime()
    local tradeKey = tostring(CleanUuid(player)) .. ":" .. tostring(CleanUuid(trader))
    if LastTradeSellKey == tradeKey and (now - LastTradeSellTime) < 2500 then
        return
    end
    LastTradeSellKey = tradeKey
    LastTradeSellTime = now

    local okGold, traderGold = pcall(Osi.GetGold, trader)
    if not okGold or type(traderGold) ~= "number" or traderGold <= 0 then
        return
    end

    local chests = GetCampChestUuids()
    if #chests == 0 then return end

    local chestItems = CollectCampChestItems(chests)
    local soldCount = 0
    local totalEarned = 0

    for _, itemUuid in ipairs(chestItems) do
        if traderGold <= 0 then break end
        if Osi.Exists(itemUuid) == 1 then
            local clean = CleanUuid(itemUuid)
            local meta = GetItemInspectionMetadata(itemUuid)
            local tplKey = (meta.templateId ~= "" and meta.templateId) or meta.name or ""

            local inLedger = clean and PersistentVars.AutoSellLedger[clean] == true
            local tplQueued = (tplKey ~= "" and PersistentVars.AutoSellTemplates[tplKey]) or 0

            if (inLedger or tplQueued > 0)
                and not meta.isStory
                and not meta.isEquipable
                and not meta.isKey
                and not meta.isBook
                and meta.supplyValue == 0
                and not meta.nonTradable
            then
                local stackAmt = math.max(1, meta.stackAmount or 1)
                local desiredQty = inLedger and stackAmt or math.min(stackAmt, tplQueued)
                local unitBase = math.max(1, tonumber(meta.unitValue) or 10)
                -- Honest BG3 merchant buyback rate (~45% of base value)
                local unitSellPrice = math.max(1, math.floor(unitBase * 0.45 + 0.5))
                local affordableQty = math.min(desiredQty, math.floor(traderGold / unitSellPrice))

                if affordableQty >= 1 then
                    local payout = affordableQty * unitSellPrice
                    local okMove = pcall(Osi.ToInventory, itemUuid, trader, affordableQty, 0, 1)
                    if okMove then
                        pcall(Osi.AddGold, trader, -payout)
                        pcall(Osi.AddGold, player, payout)
                        traderGold = traderGold - payout
                        soldCount = soldCount + affordableQty
                        totalEarned = totalEarned + payout

                        if clean and affordableQty >= stackAmt then
                            PersistentVars.AutoSellLedger[clean] = nil
                        end
                        if tplKey ~= "" and PersistentVars.AutoSellTemplates[tplKey] then
                            local rem = PersistentVars.AutoSellTemplates[tplKey] - affordableQty
                            PersistentVars.AutoSellTemplates[tplKey] = (rem > 0) and rem or nil
                        end
                    end
                end
            end
        end
    end

    -- Prune stale UUIDs that no longer exist or were moved out of Camp Chest by the player
    local chestSet = {}
    for _, u in ipairs(chestItems) do
        local c = CleanUuid(u)
        if c then chestSet[c] = true end
    end
    for cleanUuid, _ in pairs(PersistentVars.AutoSellLedger) do
        if not chestSet[cleanUuid] then
            PersistentVars.AutoSellLedger[cleanUuid] = nil
        end
    end

    if soldCount > 0 and totalEarned > 0 then
        ScavengeStats.soldItems = ScavengeStats.soldItems + soldCount
        ScavengeStats.soldGold = ScavengeStats.soldGold + totalEarned
        pcall(Osi.PlaySound, player, "UI_HUD_Gold_PickUp")
        local fmt = GetLocalizedText(LOCA_HANDLES.CalloutSoldFmt, "Sold from camp: %d items (+%d gold)")
        local okMsg, msg = pcall(string.format, fmt, soldCount, totalEarned)
        SafeSay(player, (okMsg and msg) or ("+" .. tostring(totalEarned) .. " gold"))
        Log(string.format("AutoSellAtTrader sold %d camp items to %s for %d gold", soldCount, tostring(trader), totalEarned))
    end
end

local function EmergencyBrakeParty(spotter, trapUuid)
    if not IsOsirisReady() or not Config.TrapReflex then return end
    local now = Ext.Utils.MonotonicTime()
    if (now - LastTrapBrakeTime) < 1200 then return end
    LastTrapBrakeTime = now

    if trapUuid then
        local ct = CleanUuid(trapUuid) or tostring(trapUuid)
        KnownDiscoveredTraps[ct] = true
    end

    AbortAllQueues("trap_spotted")

    local members = GetPartyCompanions()
    local stoppedAny = false
    for _, member in ipairs(members) do
        pcall(function()
            if Osi.IsDead(member) == 0 and Osi.IsInCombat(member) == 0 then
                PurgeCharacterOsiris(member)
                if Osi.IsMoving(member) == 1 then
                    stoppedAny = true
                end
                Osi.CharacterMoveTo(member, member, "Walk", "")
            end
        end)
    end
    -- Release temporary brake orders 300ms later so Anubis party-following is 100% free!
    Ext.Timer.WaitFor(300, function()
        if not IsOsirisReady() then return end
        for _, member in ipairs(members) do
            PurgeCharacterOsiris(member)
        end
    end)

    ScavengeStats.trapStops = ScavengeStats.trapStops + 1
    StateChecks.resetIdleAnchor()
    HostLastActiveTime = now

    local speaker = spotter or (Osi.GetHostCharacter and Osi.GetHostCharacter()) or members[1]
    if speaker then
        if trapUuid then FaceTarget(speaker, trapUuid) end
        pcall(Osi.PlaySound, speaker, "UI_HUD_Item_Map_Ping")
        TryPlayCompanionActionVoice(speaker, "trap_spot")
        SafeSay(speaker, GetLocalizedText(LOCA_HANDLES.CalloutTrap, "Careful, a trap! Hold!"))
    end
    Log(string.format("TrapReflex halted party! Spotter=%s | Trap=%s | WasMoving=%s", tostring(speaker), tostring(trapUuid), tostring(stoppedAny)))
end

local function CheckNearbyTrapsWatchdog(host, _now)
    if not Config.TrapReflex or not host then return end
    if Osi.IsInCombat(host) == 1 or IsInTurnBased(host) or IsAnyDialogActive() then return end
    if not LocalSpatialIndex.ready or #LocalSpatialIndex.traps == 0 then return end

    local hx, hy, hz = Osi.GetPosition(host)
    if not hx then return end

    -- Sub-0.01ms check over pre-filtered nearby trap candidates ONLY (never scans all 20,000 ServerItems!)
    pcall(function()
        for _, tr in ipairs(LocalSpatialIndex.traps) do
            local u = tr.u
            local cleanU = CleanUuid(u) or u
            if not KnownDiscoveredTraps[cleanU] then
                local dx = tr.x - hx
                local dy = tr.y - hy
                local dz = tr.z - hz
                if (dx * dx + dz * dz) <= 81.0 and math.abs(dy) <= 3.5 then
                    if Osi.Exists(u) == 1
                        and Osi.IsTrapArmed and Osi.IsTrapArmed(u) == 1
                        and Osi.IsTrapDiscovered and Osi.IsTrapDiscovered(u) == 1
                    then
                        local partyMoving = (Osi.IsMoving(host) == 1)
                        if not partyMoving then
                            for _, c in ipairs(GetPartyCompanions()) do
                                if Osi.IsMoving(c) == 1 then
                                    partyMoving = true
                                    break
                                end
                            end
                        end
                        KnownDiscoveredTraps[cleanU] = true
                        if partyMoving then
                            EmergencyBrakeParty(host, u)
                            return
                        end
                    end
                end
            end
        end
    end)
end

function StateChecks.isInDangerZone(char)
    if not char then return false end
    local ok, inDanger = pcall(function()
        if Osi.DB_InDangerZone then
            local rows = Osi.DB_InDangerZone:Get(nil, nil)
            if rows then
                for _, row in pairs(rows) do
                    if row[1] and SameEntity(row[1], char) then
                        return true
                    end
                end
            end
        end
        return false
    end)
    return ok and inDanger == true
end

function StateChecks.getMemberHpPercent(char)
    if not char then return 100 end
    local pct = 100
    pcall(function()
        -- Ignore temporary Wild Shape beast health just like Larian's Act1_Tutorials_AfterTUT
        if Osi.HasActiveStatus and (Osi.HasActiveStatus(char, "WILDSHAPE") == 1 or Osi.HasActiveStatus(char, "POLYMORPHED") == 1) then
            return
        end
        local e = Ext.Entity.Get(char)
        if e and e.ServerShapeshiftStates and e.ServerShapeshiftStates.States and #e.ServerShapeshiftStates.States > 0 then
            return
        end
        if Osi.GetHitpointsPercentage then
            local okP, p = pcall(Osi.GetHitpointsPercentage, char)
            if okP and type(p) == "number" and p >= 0 then
                pct = p
                return
            end
        end
        if e and e.Health and e.Health.MaxHp and e.Health.MaxHp > 0 and e.Health.Hp then
            pct = math.floor((e.Health.Hp * 100.0) / e.Health.MaxHp + 0.5)
        end
    end)
    return pct
end

function StateChecks.getAvailableShortRests(host)
    if not host then return 0 end
    if IsInCamp(host) or StateChecks.isInDangerZone(host) then return 0 end
    local count = 0
    pcall(function()
        local e = Ext.Entity.Get(host)
        if e and (e.StoryShortRestDisabled ~= nil or e.GlobalShortRestDisabled ~= nil) then
            count = 0
            return
        end
        if Osi.PartyGetActionResourceValue then
            local ok1, v1 = pcall(Osi.PartyGetActionResourceValue, host, "ShortRestPoint")
            if ok1 and type(v1) == "number" and v1 >= 0 then
                count = math.floor(v1 + 0.001)
                return
            end
        end
        if Osi.GetActionResourceValuePersonal then
            local ok2, v2 = pcall(Osi.GetActionResourceValuePersonal, host, "ShortRestPoint", 0)
            if ok2 and type(v2) == "number" and v2 >= 0 then
                count = math.floor(v2 + 0.001)
                return
            end
        end
        if e and e.ActionResources and e.ActionResources.Resources then
            local entries = e.ActionResources.Resources["a24ca5e2-01e1-48fd-a4c8-79b8817f0a18"]
            if entries then
                local sum = 0
                for _, entry in pairs(entries) do
                    if entry and type(entry.Amount) == "number" then
                        sum = sum + entry.Amount
                    end
                end
                count = math.floor(sum + 0.001)
            end
        end
    end)
    return count
end

function StateChecks.processPostCombatBreather(host, now)
    ScavengeStats.pendingBreatherTime = 0
    if not Config.PostCombatBreather or not host then return end
    if Osi.IsInCombat(host) == 1 or IsAnyDialogActive() or IsSneakingOrInvisible(host) or IsInTurnBased(host) then
        return
    end
    if (now - ScavengeStats.lastBreatherTime) < 110000 then
        return
    end

    local members = GetPartyCompanions()
    local bruisedCount = 0
    local badlyWoundedCount = 0
    local bestOrigin = nil
    local bestOriginHp = 999
    local fallbackSpeaker = nil
    local fallbackHp = 999

    for _, m in ipairs(members) do
        pcall(function()
            if Osi.Exists(m) == 1 and Osi.IsDead(m) == 0 and Osi.IsInCombat(m) == 0 and not IsCharacterInDialog(m) then
                local hpPct = StateChecks.getMemberHpPercent(m)
                if hpPct <= 55 then bruisedCount = bruisedCount + 1 end
                if hpPct <= 40 then badlyWoundedCount = badlyWoundedCount + 1 end

                if not SameEntity(m, host) and (not Osi.IsControlled or Osi.IsControlled(m) == 0) then
                    local cm = CleanUuid(m)
                    local repeatPenalty = (cm == LastActionVoiceSpeaker) and 15 or 0
                    local effHp = hpPct + repeatPenalty
                    if cm and ORIGIN_COMPANION_SET[cm] == true then
                        if effHp < bestOriginHp then
                            bestOriginHp = effHp
                            bestOrigin = m
                        end
                    elseif effHp < fallbackHp then
                        fallbackHp = effHp
                        fallbackSpeaker = m
                    end
                end
            end
        end)
    end

    if badlyWoundedCount < 1 and bruisedCount < 2 then
        return -- Minor skirmish; no heavy post-combat breather needed
    end

    local speaker = bestOrigin or fallbackSpeaker
    if not speaker then return end

    ScavengeStats.lastBreatherTime = now
    ActionVoiceStats.breathers = ActionVoiceStats.breathers + 1

    -- Coordinate smoothly with Auto-Wash so blood cleansing doesn't speak over the post-battle breather!
    ScavengeStats.quietNextWash = true
    if PendingAutoWashTime > 0 and PendingAutoWashTime < (now + 4600) then
        PendingAutoWashTime = now + 4600
    end

    local _, vMode = TryPlayCompanionActionVoice(speaker, "post_combat_tired")
    local shortRests = StateChecks.getAvailableShortRests(host)
    if shortRests >= 1 and (now - ScavengeStats.lastShortRestHintTime) >= 300000 then
        ScavengeStats.lastShortRestHintTime = now
        local hintText = GetLocalizedText(
            "h7d2e1b4ag0076g4a1dgb5e2g6f3a9c8b0076",
            "Could catch our breath... (Short Rest available)"
        )
        local delayMs = (vMode == "pad") and 3100 or 900
        if Ext and Ext.Timer and Ext.Timer.WaitFor then
            Ext.Timer.WaitFor(delayMs, function()
                if IsOsirisReady() and Osi.Exists(speaker) == 1 and Osi.IsInCombat(speaker) == 0 and not IsCharacterInDialog(speaker) then
                    SafeSay(speaker, hintText)
                end
            end)
        end
    end
end

local function WashPartyClean(host, now)
    if not Config.AutoWash or not host then return end
    if Osi.IsInCombat(host) == 1 or IsAnyDialogActive() or IsSneakingOrInvisible(host) or IsInTurnBased(host) then
        return
    end

    LastAutoWashTime = now
    PendingAutoWashTime = 0
    local quietWash = (ScavengeStats.quietNextWash == true)
    ScavengeStats.quietNextWash = false

    local members = GetPartyCompanions()
    local washed = 0
    local originWashed = {}
    local nonHostWashed = {}
    for _, m in ipairs(members) do
        pcall(function()
            if Osi.IsDead(m) == 0 and Osi.IsInCombat(m) == 0 and not IsCharacterInDialog(m) then
                if Osi.RemoveSplatters then
                    pcall(Osi.RemoveSplatters, m)
                end
                if Osi.ApplyStatus then
                    pcall(Osi.ApplyStatus, m, "SOAP_WASH", 1.0, 1, m)
                end
                washed = washed + 1
                if not SameEntity(m, host) then
                    nonHostWashed[#nonHostWashed + 1] = m
                    local cm = CleanUuid(m)
                    if cm and ORIGIN_COMPANION_SET[cm] == true then
                        originWashed[#originWashed + 1] = m
                    end
                end
            end
        end)
    end

    if washed > 0 then
        ScavengeStats.washes = ScavengeStats.washes + 1
        Log("AutoWash cleansed blood & grime on " .. tostring(washed) .. " party members.")
        if not quietWash then
            local pool = (#originWashed > 0) and originWashed or nonHostWashed
            if #pool > 0 then
                local speaker = pool[math.random(1, #pool)]
                TryPlayCompanionActionVoice(speaker, "wash_clean")
            end
        end
    end
end

local function CreateWarmingSequence(character, fireUuid)
    local queue = ActiveQueues[character]
    if not queue then return end
    queue.activityTag = "fire"

    queue:enqueue({
        name = "GoToFire",
        execute = function(char)
            local tx, ty, tz = GetSmartApproachPosition(char, fireUuid, 1.2)
            if tx then
                Osi.CharacterMoveToPosition(char, tx, ty, tz, "Walk", "")
            else
                queue.queue = {}
            end
        end,
        completion = function(char)
            if #queue.queue == 0 then return true end
            return StateChecks.isWithinReach(char, fireUuid, 2.4, 2.5) and Osi.IsMoving(char) == 0
        end,
    })

    AnimSystem.enqueueSmoothTurn(queue, "TurnToFire", fireUuid)

    local warmAnim = AnimSystem.WARM_FIRE

    queue:enqueue({
        name = "WarmHands",
        customAnim = true,
        execute = function(char)
            AnimSystem.lookAt(char, fireUuid, 5.0)
            local _, vMode = TryPlayCompanionActionVoice(char, "rest_fire", { resumeAnim = warmAnim })
            if vMode ~= "pad" then
                AnimSystem.play(char, warmAnim)
            end
        end,
        duration = math.random(8500, 14500),
    })

    AnimSystem.enqueueGracefulExit(queue, "FinishWarming", warmAnim)
end

local function CreateIdleAnimationSequence(character, zone)
    local queue = ActiveQueues[character]
    if not queue then return end
    local possibleAnims = GetContextIdleAnimations(character, zone)
    if not possibleAnims or #possibleAnims == 0 then return end
    local animName = possibleAnims[math.random(#possibleAnims)]
    local isTriplet = AnimSystem.isTriplet(animName)
    local animDuration = isTriplet and math.random(9500, 16500) or math.random(7500, 11500)
    queue.activityTag = "idle_anim"

    queue:enqueue({
        name = "PlayIdleAnim_" .. animName,
        customAnim = true,
        execute = function(char)
            local _, vMode = TryPlayCompanionActionVoice(char, "personal_idle", { resumeAnim = animName })
            if vMode ~= "pad" then
                AnimSystem.play(char, animName)
            end
        end,
        duration = animDuration,
    })

    AnimSystem.enqueueGracefulExit(queue, "FinishIdleAnim", animName)
end

local function CreateWanderSequence(character, propUuid)
    local queue = ActiveQueues[character]
    if not queue then return end
    queue.activityTag = "wander"

    queue:enqueue({
        name = "WanderToProp",
        execute = function(char)
            local tx, ty, tz = GetSmartApproachPosition(char, propUuid, 1.5)
            if tx then
                Osi.CharacterMoveToPosition(char, tx, ty, tz, "Walk", "")
            else
                queue.queue = {}
            end
        end,
        completion = function(char)
            if #queue.queue == 0 then return true end
            return StateChecks.isWithinReach(char, propUuid, 2.7, 2.8)
        end,
        onTimeout = function(char) StopInteraction(char) end,
    })
    queue:enqueue({ name = "LookAroundProp", duration = math.random(3600, 6800) })
end

local function CreateRandomWalkSequence(character, host)
    local queue = ActiveQueues[character]
    if not queue then return end
    local x, y, z = Osi.GetPosition(character)
    local hx, hy, hz = Osi.GetPosition(host)
    if not x or not hx then return end
    queue.activityTag = "walk"

    local angle = math.random() * 2 * math.pi
    local dist = 1.8 + math.random() * 1.5
    local tx = x + math.cos(angle) * dist
    local tz = z + math.sin(angle) * dist

    local maxLeash = Config.SearchRadius
    local dx = tx - hx
    local dz = tz - hz
    if (dx * dx + dz * dz) > (maxLeash * maxLeash) then
        local backAngle = math.random() * 2 * math.pi
        tx = hx + math.cos(backAngle) * math.min(3.5, maxLeash * 0.4)
        tz = hz + math.sin(backAngle) * math.min(3.5, maxLeash * 0.4)
        y = hy
    end

    if Osi.FindValidPosition then
        local okV, vx, vy, vz = pcall(Osi.FindValidPosition, tx, y, tz, 2.2, character, 0)
        if okV then
            if not vx then return end
            tx, y, tz = vx, vy, vz
        end
    end

    queue:enqueue({
        name = "RandomWander",
        execute = function(char)
            Osi.CharacterMoveToPosition(char, tx, y, tz, "Walk", "")
        end,
        completion = function(char)
            return Osi.IsMoving(char) == 0
        end,
        onComplete = function(char) PurgeCharacterOsiris(char) end,
        onTimeout = function(char) PurgeCharacterOsiris(char) end,
        duration = 5500,
    })
    queue:enqueue({ name = "PauseAfterWalk", duration = 3500 })
end

-- ============================================================================
-- 8. SUB-MILLISECOND CHUNKED ECS SPATIAL & CONTEXT SCANNER
-- ============================================================================

local SAFE_CURIOSITY_USE_PATTERNS = {
    "Harp", "Drum", "Lute", "bellows", "pump",
}

local function AllowsHarmlessUse(name, lowerName)
    for _, p in ipairs(SAFE_CURIOSITY_USE_PATTERNS) do
        if string.find(name, p, 1, true) or string.find(lowerName, p, 1, true) then
            return true
        end
    end
    return false
end

-- Amortized 2-phase background spatial sweep:
--   Phase "items": slices ServerItem @ 500 handles/tick (~0.2ms)
--   Phase "chars": slices ServerCharacter @ 250 handles/tick (~0.2ms)
-- Eliminates ALL unchunked GetAllEntitiesWithComponent loops in Tick so BG3SE never logs
-- "Dispatching event Tick took X ms" even on 20,000+ item / 2,000+ NPC Act 1 & Act 3 maps!
local function StepLocalSpatialIndex(host, now, budget)
    if not host then return end
    local hx, hy, hz = Osi.GetPosition(host)
    if not hx then return end

    if not LocalSpatialIndex.sweeping then
        local dx = hx - LocalSpatialIndex.hx
        local dz = hz - LocalSpatialIndex.hz
        local needsRefresh = (not LocalSpatialIndex.ready)
            or ((dx * dx + dz * dz) > 36.0)
            or ((now - LocalSpatialIndex.lastCompleted) >= 8000)

        if not needsRefresh then
            return
        end

        local okList, list = pcall(Ext.Entity.GetAllEntitiesWithComponent, "ServerItem")
        if not okList or not list then return end

        LocalSpatialIndex.phase = "items"
        LocalSpatialIndex.handles = list
        LocalSpatialIndex.total = #list
        LocalSpatialIndex.cursor = 1
        LocalSpatialIndex.hx = hx
        LocalSpatialIndex.hy = hy
        LocalSpatialIndex.hz = hz
        LocalSpatialIndex.sweepItems = {}
        LocalSpatialIndex.sweepTraps = {}
        LocalSpatialIndex.sweepChars = {}
        LocalSpatialIndex.sweeping = true
    end

    local shx = LocalSpatialIndex.hx
    local shy = LocalSpatialIndex.hy
    local shz = LocalSpatialIndex.hz

    if LocalSpatialIndex.phase == "items" then
        local handles = LocalSpatialIndex.handles
        local total = LocalSpatialIndex.total
        local startIdx = LocalSpatialIndex.cursor
        local slice = math.min(budget or 500, 500)
        local endIdx = math.min(total, startIdx + slice - 1)
        local winR = math.max(28.0, (Config.SearchRadius or 12) + 10.0)
        local winRSq = winR * winR
        local outItems = LocalSpatialIndex.sweepItems
        local outTraps = LocalSpatialIndex.sweepTraps

        pcall(function()
            for i = startIdx, endIdx do
                local h = handles[i]
                local e = (type(h) == "string") and Ext.Entity.Get(h) or h
                if e ~= nil then
                    local tr = e.Transform
                    if tr ~= nil then
                        local inner = tr.Transform
                        local pos = inner and inner.Translate or nil
                        if pos ~= nil then
                            local ix, iy, iz = pos[1], pos[2], pos[3]
                            if ix ~= nil then
                                local dx = ix - shx
                                local dz = iz - shz
                                local dy = iy - shy
                                if (dx * dx + dz * dz) <= winRSq and math.abs(dy) <= 4.5 then
                                    if e.InventoryMember == nil then
                                        local si = e.ServerItem
                                        local tpl = si and si.Template or nil
                                        local uc = e.Uuid
                                        if si ~= nil and tpl ~= nil and uc ~= nil and uc.EntityUuid ~= nil then
                                            local uuid = tostring(uc.EntityUuid)
                                            local name = tostring(tpl.Name or "")
                                            local lower = string.lower(name)
                                            local isTrap = (tpl.IsTrap == true)
                                                or string.find(lower, "trap", 1, true) ~= nil
                                                or string.find(lower, "mine", 1, true) ~= nil
                                                or string.find(lower, "vent", 1, true) ~= nil
                                            local entry = {
                                                u           = uuid,
                                                name        = name,
                                                lower       = lower,
                                                isContainer = (si.IsContainer == true),
                                                canPickUp   = (si.CanBePickedUp == true),
                                                canUse      = (si.CanUse == true),
                                                x           = ix,
                                                y           = iy,
                                                z           = iz,
                                            }
                                            outItems[#outItems + 1] = entry
                                            if isTrap then
                                                outTraps[#outTraps + 1] = entry
                                            end
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end)

        if endIdx >= total then
            LocalSpatialIndex.items = outItems
            LocalSpatialIndex.traps = outTraps
            -- Transition to Phase 2 ("chars") on the NEXT tick so we never allocate two lists in one tick!
            LocalSpatialIndex.phase = "chars_init"
            LocalSpatialIndex.handles = nil
            LocalSpatialIndex.cursor = 1
            LocalSpatialIndex.total = 0
        else
            LocalSpatialIndex.cursor = endIdx + 1
        end
        return
    end

    if LocalSpatialIndex.phase == "chars_init" then
        local okChars, charList = pcall(Ext.Entity.GetAllEntitiesWithComponent, "ServerCharacter")
        if not okChars or not charList or #charList == 0 then
            LocalSpatialIndex.chars = {}
            LocalSpatialIndex.corpses = {}
            LocalSpatialIndex.pets = {}
            LocalSpatialIndex.enemyNearby = false
            LocalSpatialIndex.enemyCoords = {}
            LocalSpatialIndex.handles = nil
            LocalSpatialIndex.sweeping = false
            LocalSpatialIndex.ready = true
            LocalSpatialIndex.lastCompleted = now
            WorldScanCache.timestamp = 0
            CampTriggerGuard.updatedAt = -999999
            return
        end
        LocalSpatialIndex.phase = "chars"
        LocalSpatialIndex.handles = charList
        LocalSpatialIndex.total = #charList
        LocalSpatialIndex.cursor = 1
        return
    end

    -- Phase "chars": slice 250 ServerCharacter handles per tick (~0.2ms)
    local cHandles = LocalSpatialIndex.handles
    local cTotal = LocalSpatialIndex.total
    local cStart = LocalSpatialIndex.cursor
    local cEnd = math.min(cTotal, cStart + 249)
    local charRangeSq = 26.0 * 26.0
    local outChars = LocalSpatialIndex.sweepChars

    pcall(function()
        for i = cStart, cEnd do
            local ch = cHandles[i]
            local ce = (type(ch) == "string") and Ext.Entity.Get(ch) or ch
            if ce ~= nil and ce.Transform ~= nil and ce.PartyMember == nil then
                local pos = ce.Transform.Transform and ce.Transform.Transform.Translate or nil
                if pos ~= nil and pos[1] ~= nil then
                    local dx = pos[1] - shx
                    local dy = pos[2] - shy
                    local dz = pos[3] - shz
                    local dSq = dx * dx + dz * dz
                    if dSq <= charRangeSq and math.abs(dy) <= 6.5 then
                        local uc = ce.Uuid
                        if uc ~= nil and uc.EntityUuid ~= nil then
                            local cuuid = tostring(uc.EntityUuid)
                            local tname = ""
                            if ce.ServerCharacter and ce.ServerCharacter.Template and ce.ServerCharacter.Template.Name then
                                tname = tostring(ce.ServerCharacter.Template.Name)
                            end
                            outChars[#outChars + 1] = {
                                u    = cuuid,
                                name = tname,
                                dead = (ce.Death ~= nil),
                                x    = pos[1],
                                y    = pos[2],
                                z    = pos[3],
                            }
                        end
                    end
                end
            end
        end
    end)

    if cEnd >= cTotal then
        local liveChars = {}
        local foundCorpses = {}
        local foundPets = {}
        local hasHostile = false
        local hostileCoords = {}
        local inCampNow = IsInCamp(host)
        local petR = (Config.SearchRadius or 12) + 3.0
        local petRangeSq = petR * petR
        pcall(function()
            for _, nc in ipairs(outChars) do
                local dx, dy, dz = nc.x - shx, math.abs(nc.y - shy), nc.z - shz
                local dSq = dx * dx + dz * dz
                if nc.dead then
                    if dSq <= petRangeSq and dy <= 3.5 then
                        foundCorpses[#foundCorpses + 1] = { u = nc.u, x = nc.x, y = nc.y, z = nc.z, isCorpse = true }
                    end
                else
                    liveChars[#liveChars + 1] = nc
                    local checkStr = (nc.name or "") .. "_" .. nc.u
                    if dSq <= petRangeSq and dy <= 3.5 and (
                        string.find(checkStr, "Scratch", 1, true)
                        or string.find(checkStr, "OwlbearCub", 1, true)
                        or string.find(checkStr, "Camp_Owlbear", 1, true)
                    ) then
                        foundPets[#foundPets + 1] = { u = nc.u, n = nc.name }
                    elseif not inCampNow and #hostileCoords < 12 and Osi.IsEnemy then
                        if Osi.Exists(nc.u) == 1 and Osi.IsDead(nc.u) == 0 and Osi.IsEnemy(host, nc.u) == 1 then
                            hasHostile = true
                            hostileCoords[#hostileCoords + 1] = nc
                        end
                    end
                end
            end
        end)
        LocalSpatialIndex.chars = liveChars
        LocalSpatialIndex.corpses = foundCorpses
        LocalSpatialIndex.pets = foundPets
        LocalSpatialIndex.enemyNearby = hasHostile
        LocalSpatialIndex.enemyCoords = hostileCoords
        LocalSpatialIndex.handles = nil
        LocalSpatialIndex.sweeping = false
        LocalSpatialIndex.ready = true
        LocalSpatialIndex.lastCompleted = now

        WorldScanCache.timestamp = 0
        CampTriggerGuard.updatedAt = -999999
    else
        LocalSpatialIndex.cursor = cEnd + 1
    end
end

local function ScanNearbyWorldTargets(host, now)
    local hx, hy, hz = Osi.GetPosition(host)
    if not hx then return nil, nil end

    if not LocalSpatialIndex.ready then
        StepLocalSpatialIndex(host, now, 900)
        if not LocalSpatialIndex.ready then
            return nil, nil
        end
    end

    local radius = Config.SearchRadius
    local inCampNow = IsInCamp(host)
    if WorldScanCache.targets
        and (now - WorldScanCache.timestamp) < 10000
        and WorldScanCache.radius == radius
        and WorldScanCache.zone
        and WorldScanCache.zone.inCamp == inCampNow
    then
        local mdx = hx - WorldScanCache.hx
        local mdz = hz - WorldScanCache.hz
        if (mdx * mdx + mdz * mdz) < 9.0 then
            return WorldScanCache.targets, WorldScanCache.zone
        end
    end

    local targets = {
        candles            = {},
        beds               = {},
        chairs             = {},
        books              = {},
        dummies            = {},
        art                = {},
        curiosity          = {},
        walls              = {},
        containers         = {},
        scavengeContainers = {},
        corpses            = {},
        pets               = {},
        loot               = {},
        wander             = {},
        hazards            = {},
    }

    local dungeonSignals = 0
    local cozySignals = 0
    local inCamp = IsInCamp(host)

    local maxR = radius + 3.0
    local maxRSq = maxR * maxR

    for _, item in ipairs(LocalSpatialIndex.items) do
        local ix, iy, iz = item.x, item.y, item.z
        local dx = ix - hx
        local dy = iy - hy
        local dz = iz - hz
        if (dx * dx + dz * dz) <= maxRSq and math.abs(dy) <= 4.5 then
            local uuid = item.u
            local name = item.name
            local lower = item.lower

            -- Environment heuristics (3-Tier Zone Context: Camp / Settlement / Dungeon)
            if string.find(name, "_DUN_", 1, true)
                or string.find(name, "CRYPT", 1, true)
                or string.find(name, "UND_", 1, true)
                or string.find(name, "SHA_", 1, true)
                or string.find(name, "SCL_", 1, true)
                or string.find(name, "HAG_", 1, true)
                or string.find(name, "MOO_Prison", 1, true)
                or string.find(lower, "stalagmite", 1, true)
                or string.find(lower, "sarcophagus", 1, true)
                or string.find(lower, "torture", 1, true)
                or string.find(lower, "spiderweb", 1, true)
                or string.find(lower, "cobweb", 1, true)
                or string.find(lower, "skeleton", 1, true)
                or string.find(lower, "gibbet", 1, true)
            then
                dungeonSignals = dungeonSignals + 1
            elseif string.find(lower, "tavern", 1, true)
                or string.find(lower, "bar_counter", 1, true)
                or string.find(lower, "fireplace", 1, true)
                or string.find(lower, "hearth", 1, true)
            then
                cozySignals = cozySignals + 1
            end

            if string.find(lower, "smokepowder", 1, true)
                or string.find(lower, "firewine", 1, true)
                or string.find(lower, "oil", 1, true)
                or string.find(lower, "grease", 1, true)
                or string.find(lower, "bibberbang", 1, true)
                or string.find(lower, "spiderweb", 1, true)
                or string.find(lower, "cobweb", 1, true)
                or string.find(lower, "web_", 1, true)
                or string.find(lower, "_web", 1, true)
                or string.find(lower, "alcohol", 1, true)
                or string.find(lower, "barrel_stalk", 1, true)
                or string.find(lower, "nautiloid_tank", 1, true)
                or string.find(lower, "caustic", 1, true)
            then
                table.insert(targets.hazards, { x = ix, y = iy, z = iz })
            elseif (string.find(name, "LTS_", 1, true)
                or string.find(name, "Brazier", 1, true)
                or string.find(lower, "candle", 1, true)
                or string.find(lower, "candelabr", 1, true)
                or string.find(lower, "candlestick", 1, true)
                or string.find(lower, "sconce", 1, true)
                or string.find(lower, "lantern", 1, true)
                or string.find(lower, "lamp", 1, true)
                or string.find(lower, "campfire", 1, true)
                or string.find(lower, "bonfire", 1, true)
                or string.find(lower, "firepit", 1, true)
                or string.find(lower, "fireplace", 1, true)
                or string.find(lower, "hearth", 1, true))
                and math.abs(dy) <= 2.35
                and not string.find(lower, "chandelier", 1, true)
                and not string.find(lower, "hanging_bowl", 1, true)
                and not string.find(name, "Vase", 1, true)
                and not string.find(name, "Crystal", 1, true)
                and not string.find(name, "Mushroom", 1, true)
                and not string.find(name, "Gem", 1, true)
                and not string.find(name, "Glowing", 1, true)
            then
                local isCampfire = string.find(lower, "campfire", 1, true) ~= nil
                    or string.find(lower, "bonfire", 1, true) ~= nil
                    or string.find(lower, "firepit", 1, true) ~= nil
                    or string.find(lower, "fireplace", 1, true) ~= nil
                    or string.find(lower, "hearth", 1, true) ~= nil
                    or CampTriggerGuard.isProtected(uuid)
                local isWaxCandle = string.find(lower, "candle", 1, true) ~= nil
                    and not string.find(lower, "torch", 1, true)
                    and not string.find(lower, "candelabr", 1, true)
                local isDedicatedFixture = string.find(name, "LTS_", 1, true) ~= nil
                    or string.find(lower, "candle", 1, true) ~= nil
                    or string.find(lower, "candelabr", 1, true) ~= nil
                    or string.find(lower, "candlestick", 1, true) ~= nil
                    or string.find(lower, "sconce", 1, true) ~= nil
                    or string.find(lower, "brazier", 1, true) ~= nil
                    or string.find(lower, "wall_bowl", 1, true) ~= nil
                    or string.find(lower, "standing_bowl", 1, true) ~= nil
                local isBrokenProp = string.find(lower, "broken", 1, true) ~= nil
                    or string.find(lower, "destruct", 1, true) ~= nil
                    or string.find(lower, "ruined", 1, true) ~= nil
                    or string.find(lower, "shattered", 1, true) ~= nil
                    or string.find(lower, "melted", 1, true) ~= nil
                    or string.find(lower, "snuffer", 1, true) ~= nil
                    or string.find(lower, "empty", 1, true) ~= nil
                    or string.find(lower, "moonlantern", 1, true) ~= nil
                    or string.find(lower, "pixie", 1, true) ~= nil
                local allowPickupCandle = (not item.canPickUp) or isWaxCandle
                local canIgnite = (not isCampfire)
                    and (not isBrokenProp)
                    and allowPickupCandle
                    and (isDedicatedFixture or item.canUse == true)
                local isWarmFire = isCampfire
                    or string.find(lower, "brazier", 1, true) ~= nil
                    or string.find(lower, "wall_bowl", 1, true) ~= nil
                    or string.find(lower, "standing_bowl", 1, true) ~= nil
                table.insert(targets.candles, {
                    u           = uuid,
                    n           = name,
                    lower       = lower,
                    x           = ix,
                    y           = iy,
                    z           = iz,
                    canUse      = item.canUse,
                    canPickUp   = item.canPickUp,
                    canIgnite   = canIgnite,
                    isWaxCandle = isWaxCandle,
                    isWarmFire  = isWarmFire,
                })
            elseif string.find(lower, "dummy", 1, true) and (string.find(lower, "practice", 1, true) or string.find(lower, "training", 1, true) or string.find(name, "Dummy", 1, true)) then
                table.insert(targets.dummies, { u = uuid, n = name })
            elseif string.find(name, "Bed", 1, true) or string.find(name, "Bunk", 1, true) then
                -- Never register Camp bedrolls/beds into targets.beds: in GLO_Camp, DB_CampBed
                -- beds/bedrolls act as End-the-Day / Long-Rest / Leave-Camp buttons!
                local isBedroll = string.find(name, "Bedroll", 1, true) ~= nil
                local isClosed = string.find(name, "Closed", 1, true) ~= nil or string.find(name, "Rolled", 1, true) ~= nil
                if (not inCamp)
                    and (not CampTriggerGuard.isProtected(uuid))
                    and (not isBedroll or string.find(name, "Open", 1, true))
                    and not isClosed
                then
                    table.insert(targets.beds, { u = uuid, n = name })
                    cozySignals = cozySignals + 1
                end
            elseif string.find(name, "Bookshelf", 1, true) or string.find(name, "Bookcase", 1, true) or string.find(name, "Lectern", 1, true) then
                table.insert(targets.books, { u = uuid, n = name })
                cozySignals = cozySignals + 1
            elseif (string.find(name, "Chair", 1, true)
                or string.find(name, "Bench", 1, true)
                or string.find(name, "Stool", 1, true)
                or string.find(name, "Pew", 1, true)
                or string.find(name, "Couch", 1, true)
                or string.find(name, "Sofa", 1, true)
                or string.find(name, "Armchair", 1, true)
                or string.find(name, "Loveseat", 1, true)
                or string.find(lower, "log_sit", 1, true)
                or string.find(lower, "sit_log", 1, true))
                and item.canUse == true
                and not item.isContainer
                and math.abs(dy) <= 1.85
                and not string.find(lower, "toadstool", 1, true)
                and not string.find(lower, "broken", 1, true)
                and not string.find(lower, "ruined", 1, true)
                and not string.find(lower, "destruct", 1, true)
                and not string.find(lower, "splinter", 1, true)
            then
                table.insert(targets.chairs, { u = uuid, n = name })
                cozySignals = cozySignals + 1
            elseif string.find(name, "Painting", 1, true) or string.find(name, "Statue", 1, true) or string.find(name, "Bust", 1, true) or string.find(name, "Sculpture", 1, true) or string.find(name, "Carving", 1, true) then
                table.insert(targets.art, { u = uuid, n = name })
            elseif string.find(name, "Telescope", 1, true)
                or string.find(name, "Globe", 1, true)
                or string.find(name, "Armillary", 1, true)
                or string.find(name, "Harp", 1, true)
                or string.find(name, "Drum", 1, true)
                or string.find(name, "Lute", 1, true)
                or string.find(name, "Vestige", 1, true)
                or string.find(lower, "bellows", 1, true)
                or string.find(lower, "pump", 1, true)
                or string.find(lower, "headstone", 1, true)
                or string.find(lower, "grave", 1, true)
                or string.find(lower, "tombstone", 1, true)
                or string.find(lower, "blackboard", 1, true)
                or string.find(lower, "mirror", 1, true)
            then
                table.insert(targets.curiosity, {
                    u = uuid,
                    n = name,
                    safeUse = AllowsHarmlessUse(name, lower),
                })
            elseif (string.find(lower, "cracked", 1, true) or string.find(lower, "destructible_wall", 1, true))
                and (string.find(lower, "wall", 1, true) or string.find(lower, "rock", 1, true) or string.find(lower, "masonry", 1, true))
            then
                table.insert(targets.walls, { u = uuid, n = name })
                dungeonSignals = dungeonSignals + 1
            elseif (item.isContainer or IsMinorScavengeContainerName(name, lower)
                or string.find(name, "Crate", 1, true) or string.find(name, "Chest", 1, true)
                or string.find(name, "Barrel", 1, true) or string.find(name, "Sack", 1, true)
                or string.find(name, "Rack", 1, true)
                or string.find(name, "Wardrobe", 1, true) or string.find(name, "Cupboard", 1, true)
                or string.find(name, "Cabinet", 1, true))
                and not string.find(lower, "cart", 1, true)
                and not string.find(lower, "wagon", 1, true)
            then
                -- Skip containers perched high on wagon beds (>1.45m vertical delta) so companions don't jam against carts!
                if IsMinorScavengeContainerName(name, lower) and math.abs(dy) <= 1.45 then
                    table.insert(targets.scavengeContainers, { u = uuid, n = name })
                end
                if math.abs(dy) <= 1.45
                    and not string.find(name, "Water", 1, true)
                    and not string.find(name, "Acid", 1, true)
                    and not string.find(name, "Brine", 1, true)
                then
                    table.insert(targets.containers, { u = uuid, n = name })
                end
            elseif (item.canPickUp
                or string.find(name, "WPN_", 1, true) or string.find(name, "ARM_", 1, true)
                or string.find(name, "MAG_", 1, true) or string.find(name, "SHIELD_", 1, true)
                or string.find(name, "RING_", 1, true) or string.find(name, "AMU_", 1, true)
                or string.find(name, "CONS_", 1, true) or string.find(name, "ALCH_", 1, true)
                or string.find(name, "POTION", 1, true) or string.find(name, "SCROLL", 1, true)
                or string.find(name, "BOOK_", 1, true) or string.find(name, "KEY_", 1, true)
                or string.find(name, "LOOT_", 1, true) or string.find(name, "Gold", 1, true)
                or string.find(name, "Supply", 1, true) or string.find(name, "TOOL_", 1, true)
                or string.find(name, "GEM_", 1, true) or string.find(name, "Map", 1, true))
                and math.abs(dy) <= 1.45
            then
                table.insert(targets.loot, { u = uuid, n = name })
            elseif string.find(name, "Table", 1, true) or string.find(name, "Pillar", 1, true) or string.find(name, "Rock", 1, true) or string.find(name, "Tree", 1, true) or string.find(name, "Bush", 1, true) then
                table.insert(targets.wander, { u = uuid, n = name })
            end
        end
    end

    -- Friendly pets & nearby hostiles are already maintained by chunked StepLocalSpatialIndex!
    if Config.SocialPets and LocalSpatialIndex.pets then
        for _, p in ipairs(LocalSpatialIndex.pets) do
            if Osi.Exists(p.u) == 1 and Osi.IsDead(p.u) == 0 and Osi.IsInCombat(p.u) == 0 and not IsCharacterInDialog(p.u) then
                table.insert(targets.pets, p)
            end
        end
    end

    -- Nearby dead NPC corpses are already indexed by chunked StepLocalSpatialIndex!
    if Config.LootMode == 0 and LocalSpatialIndex.corpses then
        for _, c in ipairs(LocalSpatialIndex.corpses) do
            local dx = c.x - hx
            local dy = c.y - hy
            local dz = c.z - hz
            if (dx * dx + dz * dz) <= maxRSq and math.abs(dy) <= 3.5 and Osi.Exists(c.u) == 1 then
                table.insert(targets.corpses, { u = c.u, isCorpse = true })
            end
        end
    end

    local inDanger = (not inCamp) and (StateChecks.isInDangerZone(host) or LocalSpatialIndex.enemyNearby == true)
    local isDungeon = (not inCamp) and (inDanger or dungeonSignals >= 2 or #targets.corpses >= 2)
    local isSettlement = (not inCamp) and (not isDungeon)
    local isRelaxed = inCamp or (isSettlement and (cozySignals >= 2 or #targets.chairs >= 2) and #targets.corpses == 0)
    local zoneMode = inCamp and "CAMP"
        or (inDanger and "DUNGEON_DANGER"
        or (isDungeon and "DUNGEON"
        or (isRelaxed and "TAVERN_TOWN" or "OUTDOOR_SAFE")))

    local zone = {
        inCamp       = inCamp,
        inDanger     = inDanger,
        isDungeon    = isDungeon,
        isSettlement = isSettlement,
        isRelaxed    = isRelaxed,
        mode         = zoneMode,
    }

    WorldScanCache.timestamp = now
    WorldScanCache.hx = hx
    WorldScanCache.hy = hy
    WorldScanCache.hz = hz
    WorldScanCache.radius = radius
    WorldScanCache.targets = targets
    WorldScanCache.zone = zone
    return targets, zone
end

local function IsNearFlammableHazard(item, hazards)
    if not item or not item.x then return false end
    if hazards then
        for _, hz in ipairs(hazards) do
            local dx = item.x - hz.x
            local dz = item.z - hz.z
            if (dx * dx + dz * dz) <= 22.0 then
                return true
            end
        end
    end
    -- Also skip lighting sconces/braziers right next to live hostile enemies (<= 16m sight-cone safety!)
    local enemies = LocalSpatialIndex and LocalSpatialIndex.enemyCoords or nil
    if enemies then
        for _, ec in ipairs(enemies) do
            local edx = item.x - ec.x
            local edz = item.z - ec.z
            if (edx * edx + edz * edz) <= 256.0 then
                return true
            end
        end
    end
    return false
end

local function ShuffleInPlace(arr)
    for i = #arr, 2, -1 do
        local j = math.random(i)
        arr[i], arr[j] = arr[j], arr[i]
    end
end

local function PickWeightedOption(options)
    local total = 0.0
    for _, opt in ipairs(options) do
        if opt.weight > 0 then
            total = total + opt.weight
        end
    end
    if total <= 0 then return nil end

    local roll = math.random() * total
    local acc = 0.0
    for _, opt in ipairs(options) do
        if opt.weight > 0 then
            acc = acc + opt.weight
            if roll <= acc then
                return opt
            end
        end
    end
    return options[#options]
end

-- ============================================================================
-- 8B. SMART FIELD TORCHBEARER (BUILD 04.3 — OPTIONAL HANDS-FREE DARKNESS LIGHT)
-- ============================================================================

do
    local PROTECTED_WEAPON_PATTERNS = {
        "DIPPED_", "COATED", "POISON", "TOXIN", "VENOM", "OIL_", "ALCH_",
        "MUCUS", "WYVERN", "MALICE", "ARSONIST", "WIZARDBANE", "DROW_POISON",
        "MAGIC_WEAPON", "ELEMENTAL_WEAPON", "SHILLELAGH", "SACRED_WEAPON",
        "LIGHT", "DAYLIGHT", "PACT_BLADE", "WEAPON_BOND", "FLAME_BLADE",
        "SHADOW_BLADE", "SEARING_SMITE", "BRANDING_SMITE", "DRK_",
    }

    local NO_DARKVISION_ORIGINS = {
        [COMP.Gale]   = 45, -- Human Wizard: no Darkvision, prime scholar torchbearer
        [COMP.Wyll]   = 40, -- Human Warlock: no Darkvision (unless Devil's Sight)
        [COMP.Laezel] = 35, -- Githyanki Fighter: no innate Darkvision in BG3!
        [COMP.Minsc]  = 35, -- Human Ranger: no Darkvision
    }

    function FieldTorchSystem.ensureStorage()
        PersistentVars = PersistentVars or {}
        if type(PersistentVars.FieldTorchState) ~= "table" then
            PersistentVars.FieldTorchState = {}
        end
        return PersistentVars.FieldTorchState
    end

    function FieldTorchSystem.isCarryingAutoTorch(char)
        if not char then return false end
        local key = CleanUuid(char)
        if not key then return false end
        local st = FieldTorchSystem.ensureStorage()[key]
        return st ~= nil and st.torchUuid ~= nil
    end

    function FieldTorchSystem.getActiveBearerKey()
        local map = FieldTorchSystem.ensureStorage()
        for k, st in pairs(map) do
            if type(st) == "table" and st.torchUuid then
                return k, st
            end
        end
        return nil, nil
    end

    function FieldTorchSystem.resolvePartyCharByKey(cleanKey, companions)
        if not cleanKey then return nil end
        local list = companions or GetPartyCompanions()
        for _, c in ipairs(list) do
            if CleanUuid(c) == cleanKey then
                return c
            end
        end
        if Osi.Exists and Osi.Exists(cleanKey) == 1 then
            return cleanKey
        end
        return nil
    end

    -- 04.3.10: which hand of THIS character holds the item? Osi.IsEquipped(item) only says that the
    -- item is worn by *somebody*, which made equipSilent report success for a torch that was never
    -- actually put into the companion's hand (the companion then just stood there unlit).
    function FieldTorchSystem.handOfItem(char, itemUuid)
        if not char or not itemUuid or not Osi.GetEquippedItem then return nil end
        local slots = { "Melee Main Weapon", "Melee Offhand Weapon" }
        for i = 1, #slots do
            local eq = Osi.GetEquippedItem(char, slots[i])
            if eq and eq ~= "" and SameEntity(eq, itemUuid) then return slots[i] end
        end
        return nil
    end

    function FieldTorchSystem.equipSilent(char, itemUuid)
        if not char or not itemUuid or not Osi.Equip then return false end
        if Osi.Exists and Osi.Exists(itemUuid) ~= 1 then return false end
        FieldTorchSystem.internalEquipGuard = true
        local hand = FieldTorchSystem.handOfItem(char, itemUuid)
        if not hand then
            -- main hand, then the plain engine form (which lets the engine pick a free hand)
            pcall(Osi.Equip, char, itemUuid, 1, 0, 0)
            hand = FieldTorchSystem.handOfItem(char, itemUuid)
            if not hand then
                pcall(Osi.Equip, char, itemUuid)
                hand = FieldTorchSystem.handOfItem(char, itemUuid)
            end
        end
        FieldTorchSystem.internalEquipGuard = false
        if hand then
            return true
        end
        -- Verification failed. Fall back to the legacy item-level answer (so this can never regress
        -- equipping on an engine quirk), but say so in the log - that is exactly the case where the
        -- torch ends up "equipped somewhere" while the companion stands in the dark.
        local legacy = (Osi.IsEquipped and Osi.IsEquipped(itemUuid) == 1)
        Log("FieldTorch: " .. tostring(itemUuid) .. " is not in a hand of " .. tostring(char)
            .. " after Equip (legacy IsEquipped=" .. tostring(legacy) .. ")")
        return legacy == true
    end

    function FieldTorchSystem.unequipSilent(char, itemUuid)
        if not char or not itemUuid or not Osi.Unequip then return end
        if Osi.Exists and Osi.Exists(itemUuid) ~= 1 then return end
        FieldTorchSystem.internalEquipGuard = true
        pcall(Osi.Unequip, char, itemUuid)
        FieldTorchSystem.internalEquipGuard = false
    end

    function FieldTorchSystem.isItemOwnedByChar(itemUuid, char)
        if not itemUuid or not char then return false end
        if Osi.Exists and Osi.Exists(itemUuid) ~= 1 then return false end
        if Osi.GetInventoryOwner then
            local okO, owner = pcall(Osi.GetInventoryOwner, itemUuid)
            if okO and owner and SameEntity(owner, char) then
                return true
            end
        end
        if Osi.IsInInventoryOf then
            local okIn, isIn = pcall(Osi.IsInInventoryOf, itemUuid, char)
            if okIn and isIn == 1 then
                return true
            end
        end
        local okE, found = pcall(function()
            local cEnt = Ext.Entity.Get(char)
            if not cEnt or not cEnt.InventoryOwner or not cEnt.InventoryOwner.Inventories then
                return false
            end
            for _, invH in pairs(cEnt.InventoryOwner.Inventories) do
                local invEnt = ResolveEntity(invH)
                if invEnt and invEnt.InventoryContainer and invEnt.InventoryContainer.Items then
                    for _, slotEntry in pairs(invEnt.InventoryContainer.Items) do
                        local iEnt = ResolveEntity(slotEntry and slotEntry.Item or slotEntry)
                        local iu = iEnt and iEnt.Uuid and iEnt.Uuid.EntityUuid or nil
                        if iu and SameEntity(iu, itemUuid) then
                            return true
                        end
                    end
                end
            end
            return false
        end)
        return okE and found == true
    end

    function FieldTorchSystem.isMundaneTorch(itemUuid)
        if not itemUuid then return false end
        if Osi.Exists and Osi.Exists(itemUuid) ~= 1 then return false end
        if Osi.IsStoryItem and Osi.IsStoryItem(itemUuid) == 1 then return false end

        local osiTorch = (Osi.IsTorch and Osi.IsTorch(itemUuid) == 1)
        local ok, valid = pcall(function()
            local e = Ext.Entity.Get(itemUuid)
            if e and e.ServerItem and e.ServerItem.StoryItem == true then
                return false
            end
            local tplName = tostring(e and e.ServerItem and e.ServerItem.Template and e.ServerItem.Template.Name or "")
            local statsId = tostring((e and e.Data and e.Data.StatsId) or (e and e.ServerItem and e.ServerItem.Stats) or "")
            local lower = string.lower(tplName .. " " .. statsId .. " " .. tostring(itemUuid))

            -- Never treat Moonlanterns, Torch of Revocation, lanterns, or candles as mundane torches!
            if string.find(lower, "moonlantern", 1, true)
                or string.find(lower, "revocation", 1, true)
                or string.find(lower, "pixie", 1, true)
                or string.find(lower, "lantern", 1, true)
                or string.find(lower, "candle", 1, true) then
                return false
            end

            if not osiTorch
                and not string.find(lower, "wpn_torch", 1, true)
                and not string.find(lower, "_torch", 1, true) then
                return false
            end

            -- Reject unique or magical (> Common) torches (NOTE: e.Value.Rarity in BG3SE v33 can be
            -- a Bitfield/Enum userdata for Common items, so NEVER reject unknown userdata strings!)
            if e and e.Value then
                if e.Value.Unique == true then return false end
                if type(e.Value.Rarity) == "number" and e.Value.Rarity >= 1 then
                    return false
                end
            end
            if statsId ~= "" and Ext.Stats and Ext.Stats.Get then
                local st = Ext.Stats.Get(statsId)
                if st then
                    if tonumber(st.Unique) == 1 then return false end
                    local sr = string.lower(tostring(st.Rarity or ""))
                    if sr == "uncommon" or sr == "rare" or sr == "veryrare" or sr == "legendary" or sr == "story" then
                        return false
                    end
                end
            end
            return true
        end)
        if not ok then return osiTorch end
        return valid == true
    end

    function FieldTorchSystem.findMundaneTorchOnChar(char, excludeMainOffHand, preferUnassignedOnly)
        if not char then return nil end
        local activeMain = Osi.GetEquippedItem and Osi.GetEquippedItem(char, "Melee Main Weapon") or nil
        local activeOff  = Osi.GetEquippedItem and Osi.GetEquippedItem(char, "Melee Offhand Weapon") or nil

        local bestBackpack = nil
        local bestLightSlot = nil

        local function inspectItemEnt(iEnt, fromNestedBag)
            if not iEnt then return end
            local iu = iEnt.Uuid and iEnt.Uuid.EntityUuid and tostring(iEnt.Uuid.EntityUuid) or nil
            if iu and FieldTorchSystem.isMundaneTorch(iu) then
                local inActiveHand = (activeMain and SameEntity(iu, activeMain))
                    or (activeOff and SameEntity(iu, activeOff))
                if not (excludeMainOffHand and inActiveHand) then
                    local eqSlot = (not fromNestedBag and iEnt.InventoryMember and tonumber(iEnt.InventoryMember.EquipmentSlot)) or -1
                    local isEq = (not fromNestedBag) and ((Osi.IsEquipped and Osi.IsEquipped(iu) == 1) or (eqSlot >= 0))
                    if not isEq then
                        if not bestBackpack then bestBackpack = iu end
                    elseif not preferUnassignedOnly and not inActiveHand then
                        if not bestLightSlot then bestLightSlot = iu end
                    end
                end
            end
        end

        pcall(function()
            local cEnt = Ext.Entity.Get(char)
            if not cEnt or not cEnt.InventoryOwner or not cEnt.InventoryOwner.Inventories then return end
            -- CRITICAL: Use pairs(), NOT ipairs(), on BG3SE C++ Array<EntityHandle> userdata!
            for _, invH in pairs(cEnt.InventoryOwner.Inventories) do
                local invEnt = ResolveEntity(invH)
                if invEnt and invEnt.InventoryContainer and invEnt.InventoryContainer.Items then
                    for _, slotEntry in pairs(invEnt.InventoryContainer.Items) do
                        local iEnt = ResolveEntity(slotEntry and slotEntry.Item or slotEntry)
                        if iEnt then
                            inspectItemEnt(iEnt, false)
                            -- Also check 1 level inside pouches/backpacks carried by the character!
                            if not bestBackpack and iEnt.InventoryOwner and iEnt.InventoryOwner.Inventories then
                                for _, subInvH in pairs(iEnt.InventoryOwner.Inventories) do
                                    local subInv = ResolveEntity(subInvH)
                                    if subInv and subInv.InventoryContainer and subInv.InventoryContainer.Items then
                                        for _, subSlot in pairs(subInv.InventoryContainer.Items) do
                                            local subItem = ResolveEntity(subSlot and subSlot.Item or subSlot)
                                            inspectItemEnt(subItem, true)
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end)

        return bestBackpack or bestLightSlot
    end

    function FieldTorchSystem.countPartyTorches(host, companions)
        local count = 0
        local seenChars = {}
        local function checkMember(m)
            if not m then return end
            local k = CleanUuid(m) or tostring(m)
            if seenChars[k] then return end
            seenChars[k] = true
            local t = FieldTorchSystem.findMundaneTorchOnChar(m, false, false)
            if t then
                local st = (Osi.GetStackAmount and Osi.GetStackAmount(t)) or 1
                count = count + (tonumber(st) or 1)
            end
        end
        checkMember(host)
        for _, c in ipairs(companions or {}) do
            checkMember(c)
        end
        return count
    end

    function FieldTorchSystem.hasProtectedStatusOnEntity(uuidOrEnt)
        if not uuidOrEnt then return false end
        local e = type(uuidOrEnt) == "string" and (Ext.Entity and Ext.Entity.Get(uuidOrEnt)) or uuidOrEnt
        if e and e.StatusContainer and e.StatusContainer.Statuses then
            for k, v in pairs(e.StatusContainer.Statuses) do
                local sName = string.upper(type(k) == "string" and k or tostring(v))
                for _, pat in ipairs(PROTECTED_WEAPON_PATTERNS) do
                    if string.find(sName, pat, 1, true) then
                        return true
                    end
                end
            end
        end
        if type(uuidOrEnt) == "string" and Osi.HasActiveStatus then
            for _, pat in ipairs({
                "DIPPED_FIRE", "DIPPED_POISON", "MAGIC_WEAPON", "ELEMENTAL_WEAPON",
                "SHILLELAGH", "SACRED_WEAPON", "LIGHT", "DAYLIGHT",
                "PACT_BLADE", "WEAPON_BOND", "FLAME_BLADE", "SHADOW_BLADE",
            }) do
                local okS, res = pcall(Osi.HasActiveStatus, uuidOrEnt, pat)
                if okS and res == 1 then
                    return true
                end
            end
        end
        return false
    end

    function FieldTorchSystem.isWeaponProtected(wpnUuid)
        if not wpnUuid or wpnUuid == "" then return false end
        if Osi.Exists and Osi.Exists(wpnUuid) ~= 1 then return false end
        if FieldTorchSystem.hasProtectedStatusOnEntity(wpnUuid) then
            return true
        end
        local ok, prot = pcall(function()
            local e = Ext.Entity.Get(wpnUuid)
            if not e then return false end
            if e.CannotBeTakenOut ~= nil then return true end
            local tplName = tostring(e.ServerItem and e.ServerItem.Template and e.ServerItem.Template.Name or "")
            local statsId = tostring((e.Data and e.Data.StatsId) or (e.ServerItem and e.ServerItem.Stats) or "")
            local lower = string.lower(tplName .. " " .. statsId)
            if string.find(lower, "pact", 1, true)
                or string.find(lower, "bound", 1, true)
                or string.find(lower, "summon", 1, true)
                or string.find(lower, "flame_blade", 1, true)
                or string.find(lower, "shadow_blade", 1, true)
                or string.find(lower, "moonlantern", 1, true)
                or string.find(lower, "lathander", 1, true) then
                return true
            end
            return false
        end)
        return ok and prot == true
    end

    function FieldTorchSystem.isShadowCurseActive(host, companions)
        local checkList = {}
        if host then checkList[#checkList + 1] = host end
        if companions then
            for _, c in ipairs(companions) do
                if not host or not SameEntity(c, host) then
                    checkList[#checkList + 1] = c
                end
            end
        end
        for _, m in ipairs(checkList) do
            if Osi.HasActiveStatus then
                local ok1, r1 = pcall(Osi.HasActiveStatus, m, "SCL_TRACKLIGHT")
                if ok1 and r1 == 1 then return true end
                local ok2, r2 = pcall(Osi.HasActiveStatus, m, "SCL_SHADOW_CURSE")
                if ok2 and r2 == 1 then return true end
            end
        end
        if Osi.DB_SCL_ShadowCurse_TrackLight and Osi.DB_SCL_ShadowCurse_TrackLight.Get then
            local okDb, rows = pcall(function() return Osi.DB_SCL_ShadowCurse_TrackLight:Get(nil) end)
            if okDb and rows then
                for _, row in ipairs(rows) do
                    local who = row and row[1]
                    if who then
                        for _, m in ipairs(checkList) do
                            if SameEntity(who, m) then return true end
                        end
                    end
                end
            end
        end
        return false
    end

    function FieldTorchSystem.isNearLightDetectorPuzzle(host)
        if not host then return false end
        if Osi.DB_SHA_EntrancePuzzle_LightDetectors and Osi.DB_SHA_EntrancePuzzle_LightDetectors.Get then
            -- DB_SHA_EntrancePuzzle_LightDetectors(_Ring, _Detector) has arity 2!
            local okDb, rows = pcall(function() return Osi.DB_SHA_EntrancePuzzle_LightDetectors:Get(nil, nil) end)
            if okDb and rows then
                for _, row in ipairs(rows) do
                    local det = row and (row[2] or row[1])
                    if det and Osi.Exists and Osi.Exists(det) == 1 and Osi.GetDistanceTo then
                        local d = Osi.GetDistanceTo(host, det)
                        if d and d <= 22.0 then
                            return true
                        end
                    end
                end
            end
        end
        return false
    end

    function FieldTorchSystem.partyAlreadyHasActiveLight(host, companions)
        local members = {}
        if host then members[#members + 1] = host end
        for _, c in ipairs(companions or {}) do
            if not host or not SameEntity(c, host) then
                local d = (host and Osi.GetDistanceTo and Osi.GetDistanceTo(host, c)) or 0
                if d and d <= 12.0 then
                    members[#members + 1] = c
                end
            end
        end

        for _, m in ipairs(members) do
            if Osi.HasActiveStatus then
                for _, st in ipairs({
                    "LIGHT", "DAYLIGHT", "PRODUCE_FLAME", "PRODUCE_FLAME_HURL",
                    "MAG_LIGHT", "MAG_THETHORNS_LIGHT", "LATHANDER_LIGHT",
                    "SCL_MOONLANTERN_LIGHT", "PIXIE_BLESSING",
                }) do
                    local okS, r = pcall(Osi.HasActiveStatus, m, st)
                    if okS and r == 1 then return true end
                end
            end
            for _, slotName in ipairs({ "Melee Main Weapon", "Melee Offhand Weapon" }) do
                local w = Osi.GetEquippedItem and Osi.GetEquippedItem(m, slotName) or nil
                if w and w ~= "" and Osi.Exists and Osi.Exists(w) == 1 then
                    if Osi.IsTorch and Osi.IsTorch(w) == 1 then
                        return true
                    end
                    if Osi.HasActiveStatus then
                        for _, wst in ipairs({ "LIGHT", "DAYLIGHT", "BURNING", "LATHANDER_LIGHT", "MAG_LIGHT" }) do
                            local okW, rw = pcall(Osi.HasActiveStatus, w, wst)
                            if okW and rw == 1 then return true end
                        end
                    end
                    local okM, isLantern = pcall(function()
                        local e = Ext.Entity.Get(w)
                        local tn = string.lower(tostring(e and e.ServerItem and e.ServerItem.Template and e.ServerItem.Template.Name or ""))
                        return string.find(tn, "moonlantern", 1, true) ~= nil
                            or string.find(tn, "lathander", 1, true) ~= nil
                    end)
                    if okM and isLantern then return true end
                end
            end
        end
        return false
    end

    function FieldTorchSystem.hasInnateDarkvision(char)
        local clean = CleanUuid(char)
        if clean and NO_DARKVISION_ORIGINS[clean] then
            -- Wyll may take Devil's Sight Eldritch Invocation; check passive!
            if Osi.HasPassive then
                local okD, d = pcall(Osi.HasPassive, char, "DevilsSight")
                if okD and d == 1 then return true end
                local okS, s = pcall(Osi.HasPassive, char, "SuperiorDarkvision")
                if okS and s == 1 then return true end
                local okN, n = pcall(Osi.HasPassive, char, "Darkvision")
                if okN and n == 1 then return true end
            end
            if Osi.HasActiveStatus then
                local okSt, st = pcall(Osi.HasActiveStatus, char, "DARKVISION")
                if okSt and st == 1 then return true end
            end
            return false
        end
        if Osi.HasPassive then
            for _, pas in ipairs({ "Darkvision", "SuperiorDarkvision", "DevilsSight" }) do
                local okP, rp = pcall(Osi.HasPassive, char, pas)
                if okP and rp == 1 then return true end
            end
        end
        if Osi.HasActiveStatus then
            local okSt, st = pcall(Osi.HasActiveStatus, char, "DARKVISION")
            if okSt and st == 1 then return true end
        end
        return false
    end

    function FieldTorchSystem.isCompanionEligible(comp, host)
        if not comp or not host or SameEntity(comp, host) then return false end
        if not IsRealPartyCompanion(comp) then return false end
        if Osi.IsDead and Osi.IsDead(comp) == 1 then return false end
        if Osi.IsControlled and Osi.IsControlled(comp) == 1 then return false end
        if Osi.IsInCombat and Osi.IsInCombat(comp) == 1 then return false end
        if IsSneakingOrInvisible(comp) or IsInTurnBased(comp) then return false end
        if ActivePerformers[comp] then return false end

        local dist = Osi.GetDistanceTo and Osi.GetDistanceTo(host, comp) or 999
        if not dist or dist > 12.5 then return false end

        -- Skip Wild Shaped / Polymorphed / Concentrating companions
        local okState, blocked = pcall(function()
            local e = Ext.Entity.Get(comp)
            if e and e.Concentration and (e.Concentration.SpellId ~= nil or e.Concentration.Target ~= nil) then
                return true
            end
            if e and e.ShapeshiftStates and e.ShapeshiftStates.States and #e.ShapeshiftStates.States > 0 then
                return true
            end
            if Osi.DB_Is_WildShaped and Osi.DB_Is_WildShaped.Get then
                local rows = Osi.DB_Is_WildShaped:Get(nil)
                for _, r in ipairs(rows or {}) do
                    if r and r[1] and SameEntity(r[1], comp) then return true end
                end
            end
            return false
        end)
        if okState and blocked then return false end

        if Osi.HasPassive then
            for _, bp in ipairs({ "WeaponBond", "PactOfTheBlade" }) do
                local okP, rp = pcall(Osi.HasPassive, comp, bp)
                if okP and rp == 1 then return false end
            end
        end
        if FieldTorchSystem.hasProtectedStatusOnEntity(comp) then
            return false
        end

        local mainWpn = Osi.GetEquippedItem and Osi.GetEquippedItem(comp, "Melee Main Weapon") or nil
        local offWpn  = Osi.GetEquippedItem and Osi.GetEquippedItem(comp, "Melee Offhand Weapon") or nil
        if FieldTorchSystem.isWeaponProtected(mainWpn) or FieldTorchSystem.isWeaponProtected(offWpn) then
            return false
        end
        return true
    end

    function FieldTorchSystem.scanEnvironment(host, bearer, now)
        local hx, hy, hz = Osi.GetPosition(host)
        local bx, by, bz = hx, hy, hz
        if bearer and Osi.Exists and Osi.Exists(bearer) == 1 then
            local tx, ty, tz = Osi.GetPosition(bearer)
            if tx and ty and tz then bx, by, bz = tx, ty, tz end
        end

        local hazardNear = false
        local litWorldLights = 0
        local litBigFire = 0
        local dungeonSignals = 0

        if hx and hy and hz then
            local items = LocalSpatialIndex.items
            for idx = 1, #items do
                local item = items[idx]
                local u = item.u
                local ix, iy, iz = item.x, item.y, item.z
                local dxH, dyH, dzH = ix - hx, math.abs(iy - hy), iz - hz
                local dSqH = dxH * dxH + dzH * dzH
                local dxB, dyB, dzB = ix - bx, math.abs(iy - by), iz - bz
                local dSqB = dxB * dxB + dzB * dzB
                -- 04.3.10: plain arithmetic first (this loop runs every 650 ms over the whole spatial
                -- index); Osi.Exists() is only worth calling for items within 15 m.
                if u and (dSqH <= 225.0 or dSqB <= 225.0) and Osi.Exists(u) == 1 then
                    local nl = item.lower or string.lower(item.name or item.n or "")

                    if (dSqH <= 225.0 and dyH <= 5.0) then
                        if string.find(nl, "_dun_", 1, true)
                            or string.find(nl, "crypt", 1, true)
                            or string.find(nl, "und_", 1, true)
                            or string.find(nl, "sha_", 1, true)
                            or string.find(nl, "scl_", 1, true)
                            or string.find(nl, "gob_", 1, true)
                            or string.find(nl, "temple", 1, true)
                            or string.find(nl, "sel_", 1, true)
                            or string.find(nl, "puz_", 1, true)
                            or string.find(nl, "cave", 1, true)
                            or string.find(nl, "cellar", 1, true)
                            or string.find(nl, "sewer", 1, true)
                            or string.find(nl, "ruin", 1, true)
                            or string.find(nl, "cracked", 1, true)
                            or string.find(nl, "stalagmite", 1, true)
                            or string.find(nl, "sarcophagus", 1, true)
                            or string.find(nl, "cobweb", 1, true) then
                            dungeonSignals = dungeonSignals + 1
                        end
                    end

                    -- 8.0m hazard buffer around BOTH Host and Torchbearer!
                    if (dSqH <= 64.0 and dyH <= 2.8) or (dSqB <= 64.0 and dyB <= 2.8) then
                        if string.find(nl, "smokepowder", 1, true)
                            or string.find(nl, "firewine", 1, true)
                            or string.find(nl, "oil", 1, true)
                            or string.find(nl, "grease", 1, true)
                            or string.find(nl, "bibberbang", 1, true)
                            or string.find(nl, "barrel_stalk", 1, true)
                            or string.find(nl, "nautiloid_tank", 1, true)
                            or string.find(nl, "spiderweb", 1, true)
                            or string.find(nl, "cobweb", 1, true)
                            or string.find(nl, "web_", 1, true)
                            or string.find(nl, "_web", 1, true)
                            or string.find(nl, "caustic", 1, true) then
                            hazardNear = true
                        end
                    end

                    -- Stationary world light sources within 8.5m of Host (excludes handheld torches!)
                    if dSqH <= 72.25 and dyH <= 3.0 and not string.find(nl, "wpn_torch", 1, true) then
                        local isBig = string.find(nl, "brazier", 1, true)
                            or string.find(nl, "campfire", 1, true)
                            or string.find(nl, "bonfire", 1, true)
                            or string.find(nl, "firepit", 1, true)
                            or string.find(nl, "fireplace", 1, true)
                            or string.find(nl, "hearth", 1, true)
                        local isFixture = isBig
                            or string.find(nl, "lts_", 1, true)
                            or string.find(nl, "candle", 1, true)
                            or string.find(nl, "candelabr", 1, true)
                            or string.find(nl, "candlestick", 1, true)
                            or string.find(nl, "sconce", 1, true)
                            or string.find(nl, "lamp", 1, true)
                            or string.find(nl, "lantern", 1, true)
                            or string.find(nl, "chandelier", 1, true)
                        if isFixture and IsLightSourceAlreadyLit(u) then
                            litWorldLights = litWorldLights + 1
                            if isBig and dSqH <= 46.24 then
                                litBigFire = litBigFire + 1
                            end
                        end
                    end
                end
            end

            for _, tr in ipairs(LocalSpatialIndex.traps) do
                local u = tr.u
                if u and Osi.Exists(u) == 1 then
                    local dxH, dyH, dzH = tr.x - hx, math.abs(tr.y - hy), tr.z - hz
                    local dxB, dyB, dzB = tr.x - bx, math.abs(tr.y - by), tr.z - bz
                    if (dxH * dxH + dzH * dzH <= 64.0 and dyH <= 2.8)
                        or (dxB * dxB + dzB * dzB <= 64.0 and dyB <= 2.8) then
                        local nl = tr.lower or string.lower(tr.name or tr.n or "")
                        if string.find(nl, "gas", 1, true)
                            or string.find(nl, "vent", 1, true)
                            or string.find(nl, "grease", 1, true)
                            or string.find(nl, "oil", 1, true)
                            or string.find(nl, "fire", 1, true) then
                            hazardNear = true
                        end
                    end
                end
            end
        end

        -- Sub-0.02ms 18.5m live enemy proximity check using chunked LocalSpatialIndex.chars
        -- (ZERO GetAllEntitiesWithComponent calls in scanEnvironment -> eliminates 13-16ms Tick spikes!)
        if (now - FieldTorchSystem.lastEnemyCheckAt) >= 1000 then
            FieldTorchSystem.lastEnemyCheckAt = now
            local foundEnemy = false
            if hx and hy and hz and LocalSpatialIndex.chars and Osi.IsEnemy then
                pcall(function()
                    for _, nc in ipairs(LocalSpatialIndex.chars) do
                        local dx = nc.x - hx
                        local dy = math.abs(nc.y - hy)
                        local dz = nc.z - hz
                        if (dx * dx + dz * dz) <= 342.25 and dy <= 5.5 then
                            local cu = nc.u
                            if cu and not SameEntity(cu, host)
                                and Osi.Exists(cu) == 1
                                and Osi.IsDead(cu) == 0
                                and Osi.IsEnemy(host, cu) == 1 then
                                foundEnemy = true
                                break
                            end
                        end
                    end
                end)
            end
            FieldTorchSystem.cachedEnemyNear = foundEnemy
        end

        FieldTorchSystem.lastLitLights = litWorldLights
        return {
            hazardNear     = hazardNear,
            litWorldLights = litWorldLights,
            litBigFire     = litBigFire,
            dungeonSignals = dungeonSignals,
            enemyNear      = FieldTorchSystem.cachedEnemyNear,
        }
    end

    function FieldTorchSystem.isAmbientBrightAroundBearer(host, bearer, env)
        -- 1. Room candles/sconces/braziers lit around Host -> safe to put away the handheld torch!
        if env and (env.litWorldLights >= 2 or env.litBigFire >= 1) then
            return true
        end
        -- 2. Sample 4 floor points 16.5m away from the torchbearer (strictly outside the 7.5m
        --    WPN_Torch light halo!) so the torch's own glow NEVER triggers a stow/draw strobe loop!
        if not Osi.GetObscuredStateAtPosition or not bearer then return false end
        local bx, by, bz = Osi.GetPosition(bearer)
        local hx, hy, hz = Osi.GetPosition(host)
        if not bx or not hy then return false end

        local offsets = {
            { 16.5, 0.0 },
            { -16.5, 0.0 },
            { 0.0, 16.5 },
            { 0.0, -16.5 },
        }
        local validProbes = 0
        local clearProbes = 0
        for _, off in ipairs(offsets) do
            local px, py, pz = bx + off[1], hy, bz + off[2]
            if Osi.FindValidPosition then
                local okF, fx, fy, fz = pcall(Osi.FindValidPosition, px, py, pz, 4.5, host, 0)
                if okF and fx and fy and fz then
                    px, py, pz = fx, fy, fz
                else
                    px = nil
                end
            end
            if px then
                local dx, dz = px - bx, pz - bz
                -- Must sit >= 11.5m outside bearer's 7.5m torch halo!
                if (dx * dx + dz * dz) >= 132.25 then
                    local okO, obs = pcall(Osi.GetObscuredStateAtPosition, px, py, pz)
                    if okO and type(obs) == "string" then
                        validProbes = validProbes + 1
                        if obs == "Clear" then
                            clearProbes = clearProbes + 1
                        end
                    end
                end
            end
        end
        return validProbes >= 3 and clearProbes >= 3
    end

    function FieldTorchSystem.restoreCompanion(cleanKey, reason, forceUnsheath)
        local map = FieldTorchSystem.ensureStorage()
        local st = cleanKey and map[cleanKey] or nil
        if not st then return false end

        -- 04.3.10: resolve FIRST. The old order wiped the saved state and only then discovered that
        -- the character was not resolvable (level transition, temporary unload): the companion kept
        -- our burning torch in hand with the original weapon stowed, and nothing could restore it.
        local comp = FieldTorchSystem.resolvePartyCharByKey(cleanKey)
        if not comp or (Osi.Exists and Osi.Exists(comp) ~= 1) then
            local nowTs = Ext.Utils.MonotonicTime()
            st.unresolvedSince = st.unresolvedSince or nowTs
            if (nowTs - st.unresolvedSince) > 120000 then
                Log("FieldTorch: dropping stale state for unresolvable " .. tostring(cleanKey))
                map[cleanKey] = nil
            end
            return false
        end
        st.unresolvedSince = nil

        map[cleanKey] = nil
        FieldTorchSystem.brightSince = 0
        FieldTorchSystem.darkSince = 0

        local mainRestored = false
        if st.mainHand and st.mainHand ~= "" and FieldTorchSystem.isItemOwnedByChar(st.mainHand, comp) then
            mainRestored = FieldTorchSystem.equipSilent(comp, st.mainHand)
        end

        -- If companion was unarmed (Monk) or mainHand weapon was moved out of their bag, unequip the torch!
        if not mainRestored and st.torchUuid and Osi.IsEquipped and Osi.IsEquipped(st.torchUuid) == 1 then
            FieldTorchSystem.unequipSilent(comp, st.torchUuid)
        end

        if st.offHand and st.offHand ~= "" and FieldTorchSystem.isItemOwnedByChar(st.offHand, comp) then
            FieldTorchSystem.equipSilent(comp, st.offHand)
        end

        if st.torchUuid and Osi.Exists and Osi.Exists(st.torchUuid) == 1 then
            if not (Osi.IsEquipped and Osi.IsEquipped(st.torchUuid) == 1) and Osi.RemoveStatus then
                pcall(Osi.RemoveStatus, st.torchUuid, "BURNING", comp)
            end
        end

        if Osi.SetWeaponUnsheathed then
            if forceUnsheath then
                pcall(Osi.SetWeaponUnsheathed, comp, 1, 1)
            else
                local wantUnsheathed = (tonumber(st.wasUnsheathed) == 1) and 1 or 0
                pcall(Osi.SetWeaponUnsheathed, comp, wantUnsheathed, 0)
            end
        end

        FieldTorchSystem.swaps = (FieldTorchSystem.swaps or 0) + 1
        Log(string.format(
            "FieldTorch stowed on %s (reason=%s, main=%s, off=%s, combatReady=%s)",
            tostring(comp), tostring(reason), tostring(st.mainHand), tostring(st.offHand), tostring(forceUnsheath == true)
        ))
        return true
    end

    function FieldTorchSystem.restoreAll(reason, forceUnsheath)
        local map = FieldTorchSystem.ensureStorage()
        local keys = {}
        for k, _ in pairs(map) do
            keys[#keys + 1] = k
        end
        for _, k in ipairs(keys) do
            FieldTorchSystem.restoreCompanion(k, reason, forceUnsheath)
        end
    end

    function FieldTorchSystem.onItemEquipped(itemUuid, character)
        if FieldTorchSystem.internalEquipGuard then return end
        if not itemUuid or not character then return end
        local key = CleanUuid(character)
        if not key then return end
        local map = FieldTorchSystem.ensureStorage()
        local st = map[key]
        if not st then return end
        if st.torchUuid and SameEntity(itemUuid, st.torchUuid) then
            return
        end
        -- 04.3.10: the engine may report OUR OWN equip asynchronously, i.e. after internalEquipGuard
        -- has already been reset. Such an event used to wipe the saved weapon state, and the
        -- companion then kept our burning torch in hand forever (nothing left to restore).
        local nowTs = Ext.Utils.MonotonicTime()
        if st.equippedAt and (nowTs - st.equippedAt) < 2500 then
            Log("FieldTorch: ignoring an early equip event on " .. tostring(character)
                .. " (" .. tostring(itemUuid) .. ") - our own torch swap is still settling")
            return
        end
        -- Player manually equipped a weapon/shield on the torchbearer -> respect their choice and clear saved state!
        map[key] = nil
        FieldTorchSystem.brightSince = 0
        Log("FieldTorch cleared saved state on " .. tostring(character) .. " (manual player equip: " .. tostring(itemUuid) .. ")")
    end

    function FieldTorchSystem.scoreCandidate(comp)
        local clean = CleanUuid(comp)
        local score = 50
        if not FieldTorchSystem.hasInnateDarkvision(comp) then
            score = score + 45
        end
        if clean and NO_DARKVISION_ORIGINS[clean] then
            score = score + 10
        end
        if AnimSystem and AnimSystem.isOriginCompanion and AnimSystem.isOriginCompanion(comp) then
            score = score + 12
        end
        -- Slight preference for companions holding a 1H weapon or free offhand over 2H/dual-wielders
        local offWpn = Osi.GetEquippedItem and Osi.GetEquippedItem(comp, "Melee Offhand Weapon") or nil
        if not offWpn or offWpn == "" then
            score = score + 6
        end
        -- Prefer companions who already carry a torch in their own backpack/slot
        if FieldTorchSystem.findMundaneTorchOnChar(comp, true, false) then
            score = score + 15
        end
        -- Prefer non-sneaky archetypes over Astarion (who prefers shadows)
        if clean == COMP.Astarion then
            score = score - 20
        end
        return score
    end

    function FieldTorchSystem.findAndAcquirePartyTorch(targetComp, host, companions)
        -- 1. Companion already carries a mundane torch in their own backpack or Light Source slot
        local ownTorch = FieldTorchSystem.findMundaneTorchOnChar(targetComp, true, false)
        if ownTorch then
            return ownTorch
        end
        -- 2. Another companion has an unequipped spare mundane torch in backpack
        for _, other in ipairs(companions or {}) do
            if not SameEntity(other, targetComp) and not SameEntity(other, host) then
                local spare = FieldTorchSystem.findMundaneTorchOnChar(other, true, true)
                if spare and Osi.ToInventory then
                    pcall(Osi.ToInventory, spare, targetComp, 1, 0, 0)
                    local landed = FieldTorchSystem.findMundaneTorchOnChar(targetComp, true, false)
                    if landed then return landed end
                end
            end
        end
        -- 3. Host has an unequipped mundane torch in backpack (or inactive Light Source slot if not in Host's hands)
        if host then
            local hostTorch = FieldTorchSystem.findMundaneTorchOnChar(host, true, false)
            if hostTorch and Osi.ToInventory then
                pcall(Osi.ToInventory, hostTorch, targetComp, 1, 0, 0)
                local landed = FieldTorchSystem.findMundaneTorchOnChar(targetComp, true, false)
                if landed then return landed end
            end
        end
        return nil
    end

    function FieldTorchSystem.tryEquipBestTorchbearer(host, companions, now)
        local candidates = {}
        for _, c in ipairs(companions or {}) do
            if FieldTorchSystem.isCompanionEligible(c, host) then
                local q = ActiveQueues[c]
                local busyIncompatible = q and q.isProcessing
                    and q.activityTag ~= "light"
                    and q.activityTag ~= "idle_anim"
                    and q.activityTag ~= "wander"
                if not busyIncompatible then
                    candidates[#candidates + 1] = {
                        comp = c,
                        score = FieldTorchSystem.scoreCandidate(c),
                    }
                end
            end
        end
        if #candidates == 0 then return false end

        table.sort(candidates, function(a, b) return a.score > b.score end)

        for _, entry in ipairs(candidates) do
            local comp = entry.comp
            local clean = CleanUuid(comp)
            local torchUuid = FieldTorchSystem.findAndAcquirePartyTorch(comp, host, companions)
            if clean and torchUuid then
                local prevMain = Osi.GetEquippedItem and Osi.GetEquippedItem(comp, "Melee Main Weapon") or nil
                local prevOff  = Osi.GetEquippedItem and Osi.GetEquippedItem(comp, "Melee Offhand Weapon") or nil
                local prevUnsheathed = (Osi.IsWeaponUnsheathed and Osi.IsWeaponUnsheathed(comp) == 1) and 1 or 0

                -- Abort any active custom pose cleanly before drawing torch
                local q = ActiveQueues[comp]
                if q and q.isProcessing and q.activityTag ~= "light" then
                    q:abort("draw_field_torch")
                end

                local equipped = FieldTorchSystem.equipSilent(comp, torchUuid)
                if equipped then
                    if Osi.ApplyStatus and (not Osi.HasActiveStatus or Osi.HasActiveStatus(torchUuid, "BURNING") ~= 1) then
                        pcall(Osi.ApplyStatus, torchUuid, "BURNING", -1.0, 1, comp)
                    end
                    if Osi.SetWeaponUnsheathed then
                        pcall(Osi.SetWeaponUnsheathed, comp, 1, 0)
                    end

                    local map = FieldTorchSystem.ensureStorage()
                    map[clean] = {
                        torchUuid     = torchUuid,
                        mainHand      = prevMain,
                        offHand       = prevOff,
                        wasUnsheathed = prevUnsheathed,
                        equippedAt    = now,
                    }
                    FieldTorchSystem.brightSince = 0
                    FieldTorchSystem.swaps = (FieldTorchSystem.swaps or 0) + 1

                    if Config.ActionVoices and math.random(1, 100) <= 55 then
                        TryPlayCompanionActionVoice(comp, "light", false)
                    end

                    Log(string.format(
                        "FieldTorch equipped on %s (score=%d, torch=%s, savedMain=%s, savedOff=%s)",
                        tostring(comp), entry.score, tostring(torchUuid), tostring(prevMain), tostring(prevOff)
                    ))
                    return true
                end
            end
        end
        return false
    end

    function FieldTorchSystem.tickWatchdog(host, now)
        if not host then return end
        local activeKey, activeState = FieldTorchSystem.getActiveBearerKey()
        local companions = nil

        -- Fast 150ms emergency safety checks whenever a companion is holding an auto-torch!
        if activeKey and activeState then
            if not Config.FieldTorch then
                FieldTorchSystem.restoreAll("mcm_disabled", false)
                return
            end
            companions = GetPartyCompanions()
            if not IsAmbientEnabled(host, companions) then
                FieldTorchSystem.restoreAll("passive_disabled", false)
                return
            end
            if (Osi.IsInCombat and Osi.IsInCombat(host) == 1) or IsInTurnBased(host) then
                FieldTorchSystem.restoreAll("combat_or_tb", true)
                return
            end
            for _, c in ipairs(companions) do
                if (Osi.IsInCombat and Osi.IsInCombat(c) == 1) or IsInTurnBased(c) then
                    FieldTorchSystem.restoreAll("party_combat_or_tb", true)
                    return
                end
            end

            local shadowCurseNow = FieldTorchSystem.isShadowCurseActive(host, companions)
            if not shadowCurseNow then
                if IsInCamp(host) then
                    FieldTorchSystem.restoreAll("entered_camp", false)
                    return
                end
                if IsAnyDialogActive() then
                    FieldTorchSystem.restoreAll("dialog_started", false)
                    return
                end
                if IsSneakingOrInvisible(host) then
                    FieldTorchSystem.cooldownUntil = now + 4000
                    FieldTorchSystem.restoreAll("host_stealth", false)
                    return
                end
                for _, c in ipairs(companions) do
                    if IsSneakingOrInvisible(c) then
                        FieldTorchSystem.cooldownUntil = now + 4000
                        FieldTorchSystem.restoreAll("party_stealth", false)
                        return
                    end
                end
            end

            local bearer = FieldTorchSystem.resolvePartyCharByKey(activeKey, companions)
            if not bearer
                or (Osi.IsDead and Osi.IsDead(bearer) == 1)
                or (Osi.IsControlled and Osi.IsControlled(bearer) == 1) then
                FieldTorchSystem.restoreCompanion(activeKey, "bearer_controlled_or_dead", false)
                return
            end
        end

        -- Throttled 650ms environmental light / darkness / hazard evaluation
        if (now - FieldTorchSystem.lastEnvCheckAt) < 650 then
            return
        end
        FieldTorchSystem.lastEnvCheckAt = now

        if not Config.FieldTorch then return end
        companions = companions or GetPartyCompanions()
        if not IsAmbientEnabled(host, companions) then return end

        local bearer = activeKey and FieldTorchSystem.resolvePartyCharByKey(activeKey, companions) or nil
        local shadowCurse = FieldTorchSystem.isShadowCurseActive(host, companions)
        local nearLightPuzzle = FieldTorchSystem.isNearLightDetectorPuzzle(host)
        local env = FieldTorchSystem.scanEnvironment(host, bearer, now)

        if activeKey and activeState and bearer then
            -- Verify our torch is still actually equipped in hand (handles save/load or story unequip)
            local curMain = Osi.GetEquippedItem and Osi.GetEquippedItem(bearer, "Melee Main Weapon") or nil
            local curOff  = Osi.GetEquippedItem and Osi.GetEquippedItem(bearer, "Melee Offhand Weapon") or nil
            local stillHoldingTorch = (curMain and SameEntity(curMain, activeState.torchUuid))
                or (curOff and SameEntity(curOff, activeState.torchUuid))
            if not stillHoldingTorch then
                FieldTorchSystem.ensureStorage()[activeKey] = nil
                FieldTorchSystem.brightSince = 0
                return
            end

            -- Keep torch unsheathed & lit while walking if an engine transition sheathed it
            if Osi.IsWeaponUnsheathed and Osi.IsWeaponUnsheathed(bearer) == 0 and Osi.SetWeaponUnsheathed then
                pcall(Osi.SetWeaponUnsheathed, bearer, 1, 0)
            end

            if nearLightPuzzle then
                FieldTorchSystem.cooldownUntil = now + 15000
                FieldTorchSystem.restoreCompanion(activeKey, "shar_light_puzzle", false)
                return
            end

            if not shadowCurse then
                if env.enemyNear then
                    FieldTorchSystem.cooldownUntil = now + 12000
                    FieldTorchSystem.restoreCompanion(activeKey, "enemy_nearby", true)
                    return
                end
                if env.hazardNear then
                    FieldTorchSystem.cooldownUntil = now + 10000
                    FieldTorchSystem.restoreCompanion(activeKey, "flammable_hazard", false)
                    return
                end
                if FieldTorchSystem.isAmbientBrightAroundBearer(host, bearer, env) then
                    if FieldTorchSystem.brightSince <= 0 then
                        FieldTorchSystem.brightSince = now
                    elseif (now - FieldTorchSystem.brightSince) >= 3000 then
                        FieldTorchSystem.cooldownUntil = now + 6000
                        FieldTorchSystem.restoreCompanion(activeKey, "area_illuminated", false)
                    end
                else
                    FieldTorchSystem.brightSince = 0
                end
            else
                FieldTorchSystem.brightSince = 0
            end
            return
        end

        -- No active auto-torchbearer: evaluate whether party needs a torch drawn!
        if now < FieldTorchSystem.cooldownUntil then
            FieldTorchSystem.lastStatusReason = "cooldown"
            return
        end
        if IsInCamp(host) or IsAnyDialogActive() or nearLightPuzzle then
            FieldTorchSystem.darkSince = 0
            FieldTorchSystem.lastStatusReason = IsInCamp(host) and "in_camp" or (nearLightPuzzle and "shar_puzzle" or "dialog")
            return
        end
        if (Osi.IsInCombat and Osi.IsInCombat(host) == 1) or IsSneakingOrInvisible(host) or IsInTurnBased(host) then
            FieldTorchSystem.darkSince = 0
            FieldTorchSystem.lastStatusReason = "combat_stealth_tb"
            return
        end
        for _, c in ipairs(companions) do
            if (Osi.IsInCombat and Osi.IsInCombat(c) == 1) or IsSneakingOrInvisible(c) or IsInTurnBased(c) then
                FieldTorchSystem.darkSince = 0
                FieldTorchSystem.lastStatusReason = "party_combat_stealth_tb"
                return
            end
        end
        if not shadowCurse then
            if env.enemyNear or env.hazardNear or env.litWorldLights >= 2 or env.litBigFire >= 1 then
                FieldTorchSystem.darkSince = 0
                FieldTorchSystem.lastStatusReason = env.enemyNear and "enemy_near"
                    or (env.hazardNear and "hazard_near" or "room_lit")
                return
            end
        end
        if FieldTorchSystem.partyAlreadyHasActiveLight(host, companions) then
            FieldTorchSystem.darkSince = 0
            FieldTorchSystem.lastStatusReason = "party_already_lit"
            return
        end

        local hostObs = Osi.GetObscuredState and Osi.GetObscuredState(host) or nil
        FieldTorchSystem.lastHostObs = tostring(hostObs or "nil")
        local anyHeavy = (hostObs == "HeavilyObscured")
        local anyLight = (hostObs == "LightlyObscured")
        for _, c in ipairs(companions) do
            if not SameEntity(c, host) and Osi.IsDead and Osi.IsDead(c) == 0 then
                local d = Osi.GetDistanceTo and Osi.GetDistanceTo(host, c) or 999
                if d and d <= 10.0 and Osi.GetObscuredState then
                    local co = Osi.GetObscuredState(c)
                    if co == "HeavilyObscured" then anyHeavy = true end
                    if co == "LightlyObscured" then anyLight = true end
                end
            end
        end

        local inDungeonZone = (WorldScanCache.zone and WorldScanCache.zone.mode == "DUNGEON")
            or (env.dungeonSignals >= 1)

        local isDark = shadowCurse
            or anyHeavy
            or (inDungeonZone and anyLight and env.litWorldLights < 2 and env.litBigFire == 0)

        if isDark then
            FieldTorchSystem.lastStatusReason = "dark_waiting"
            if FieldTorchSystem.darkSince <= 0 then
                FieldTorchSystem.darkSince = now
            else
                local reqDebounce = shadowCurse and 1200 or 2600
                if (now - FieldTorchSystem.darkSince) >= reqDebounce then
                    FieldTorchSystem.darkSince = 0
                    if FieldTorchSystem.tryEquipBestTorchbearer(host, companions, now) then
                        FieldTorchSystem.lastStatusReason = "equipped"
                    else
                        FieldTorchSystem.lastStatusReason = "no_torch_or_eligible_comp"
                        -- Avoid spamming inventory scans every 650ms if party owns 0 torches
                        FieldTorchSystem.cooldownUntil = now + 6000
                    end
                end
            end
        else
            FieldTorchSystem.darkSince = 0
            FieldTorchSystem.lastStatusReason = "area_bright"
        end
    end
end

-- ============================================================================
-- 9. MAIN SCHEDULER, BARD REACTION & WEIGHTED PERSONALITY AI
-- ============================================================================

local LastWatchdog = 0
local LastDecisionCheck = 0
local NextFlavorTime = 0
local NextLightTime = 0

local function ShouldCompanionScavengeNow(char)
    local key = CleanUuid(char) or char
    local streak = ScavengeStreak[key] or 0
    if streak >= 3 then
        -- After 3 scavenges in a row, take a guaranteed roleplay breather!
        return false
    end
    local trait = GetTraitWeight(char, "scavenge")
    if streak == 0 then
        -- Let eager scavengers (Astarion/Karlach) check barrels ~85% first, while Gale/Shadowheart
        -- naturally mix bench-sitting, reading, and social chats (~35-45% roleplay on stop 1)!
        local firstChance = math.min(88, math.max(52, math.floor(68 * trait + 0.5)))
        return math.random(1, 100) <= firstChance
    end
    if streak == 1 then
        local chance = math.min(85, math.max(25, math.floor(50 * trait + 0.5)))
        return math.random(1, 100) <= chance
    end
    local chance = math.min(60, math.max(15, math.floor(25 * trait + 0.5)))
    return math.random(1, 100) <= chance
end

local function RecoverPartyFromStuckOsiris(host, now)
    if not host then return end
    if Osi.IsInCombat(host) == 1 or IsInTurnBased(host) or IsAnyDialogActive() then
        return
    end

    -- 1. One-time cleanup on session/save load: immediately unstick any companion (and clear any persisted seat lock!)
    if NeedsInitialPartyUnstick then
        NeedsInitialPartyUnstick = false
        for _, comp in ipairs(GetPartyCompanions()) do
            if not SameEntity(comp, host)
                and Osi.IsDead(comp) == 0
                and Osi.IsInCombat(comp) == 0
                and not IsCharacterInDialog(comp)
            then
                if AmbientSeat.isSeated(comp) then
                    AmbientSeat.standUp(comp, "session_unstick")
                else
                    SetAmbientSeatFollowLock(comp, false)
                end
                StopCustomAnimation(comp, true)
                PurgeCharacterOsiris(comp)
            end
        end
        return
    end

    -- 2. Transition cleanup: the exact moment the player starts moving after an idle window, purge grouped companions
    local idleAllowed = StateChecks.isGroupedAllowedNow(now)
    if HostWasIdleAllowed and not idleAllowed then
        for _, comp in ipairs(GetPartyCompanions()) do
            if not SameEntity(comp, host)
                and StateChecks.isGrouped(comp, host)
                and Osi.IsDead(comp) == 0
                and Osi.IsInCombat(comp) == 0
                and not IsCharacterInDialog(comp)
                and not IsCharacterSpeakingBark(comp)
            then
                local q = ActiveQueues[comp]
                if not q or not q.isProcessing then
                    SetAmbientSeatFollowLock(comp, false)
                    if Osi.IsReposed and Osi.IsReposed(comp) == 1 and Osi.EndRepose then
                        pcall(Osi.EndRepose, comp)
                    end
                    PurgeCharacterOsiris(comp)
                end
            end
        end
    end
    HostWasIdleAllowed = idleAllowed

    -- 3. Continuous Tether Watchdog: if player is walking and a chained companion stands frozen >6.5m behind for >2.5s
    if not idleAllowed and Osi.IsMoving(host) == 1 then
        for _, comp in ipairs(GetPartyCompanions()) do
            if not SameEntity(comp, host) and StateChecks.isGrouped(comp, host) then
                local q = ActiveQueues[comp]
                local key = CleanUuid(comp) or comp
                if (not q or not q.isProcessing)
                    and Osi.IsDead(comp) == 0
                    and Osi.IsInCombat(comp) == 0
                    and not IsCharacterInDialog(comp)
                    and not IsCharacterSpeakingBark(comp)
                    and not IsSneakingOrInvisible(comp)
                then
                    local dist = Osi.GetDistanceTo(comp, host)
                    if dist and dist > 6.5 and Osi.IsMoving(comp) == 0 then
                        if not CompanionLagSince[key] then
                            CompanionLagSince[key] = now
                        elseif (now - CompanionLagSince[key]) >= 2500
                            and now >= (CompanionUnstickCooldown[key] or 0)
                        then
                            CompanionLagSince[key] = nil
                            CompanionUnstickCooldown[key] = now + 8000
                            if AmbientSeat.isSeated(comp) then
                                -- Seated & left behind: stand up (block held), follow resumes after
                                AmbientSeat.standUp(comp, "lag_watchdog")
                            else
                                SetAmbientSeatFollowLock(comp, false)
                                StopCustomAnimation(comp, true)
                                PurgeCharacterOsiris(comp)
                            end
                            Log("Auto-unstuck lagging grouped companion: " .. tostring(comp))
                        end
                    else
                        CompanionLagSince[key] = nil
                    end
                else
                    CompanionLagSince[key] = nil
                end
            end
        end
    end
end

-- ============================================================================
-- 04.3.23: familiar/summon idles (EXPERIMENTAL, off by default)
-- The idle system drops summons on purpose (IsRealPartyCompanion), so a familiar never
-- does anything of its own. Re-use the existing spatial index: now and then it drifts
-- 1.8-4 m to another spot around the host. No teleports, no forced animations.
-- ============================================================================
FamiliarIdle = {
    enabled    = false,
    inited     = false,
    nextScanAt = 0,
    scanMs     = 1000,     -- cheap: look around at most once a second
    hopMinMs   = 45000,    -- a familiar fidgets every 45-120 s, not constantly
    hopMaxMs   = 120000,
    nextHopAt  = {},
    found      = {},
    orbit      = {},   -- 04.3.25: map[cleanUuid] = { ang = radians, dir = 1 | -1 }
    hops       = 0,
    skipped    = 0,
    lastReason = "-",
}

local function FamiliarIdleSummonFlag(u)
    if not (u and Osi and Osi.IsSummon) then return false end
    local ok, v = pcall(Osi.IsSummon, u)
    return ok and v == 1
end

local function FamiliarIdleFollowerFlag(u)
    if not (u and Osi and Osi.IsPartyFollower) then return false end
    local ok, v = pcall(Osi.IsPartyFollower, u)
    return ok and v == 1
end

function FamiliarIdle.syncFromSave()
    if FamiliarIdle.inited then return end
    FamiliarIdle.inited = true
    PersistentVars = PersistentVars or {}
    FamiliarIdle.enabled = (PersistentVars.FamiliarIdle == true)
end

function FamiliarIdle.setEnabled(on)
    FamiliarIdle.syncFromSave()
    FamiliarIdle.enabled = on and true or false
    PersistentVars = PersistentVars or {}
    PersistentVars.FamiliarIdle = FamiliarIdle.enabled
    Ext.Utils.Print(string.format(
        "[AmbientAI] familiar idles %s (experimental) - a familiar now drifts to a new spot "
        .. "near the host every %d-%d s, never in combat or near hostiles",
        FamiliarIdle.enabled and "ON" or "OFF",
        math.floor(FamiliarIdle.hopMinMs / 1000), math.floor(FamiliarIdle.hopMaxMs / 1000)))
end

-- 04.3.24: the spatial index skips every entity with a PartyMember component, and a linked
-- summon (Pact of the Chain familiar) has one - so the index can never see the imp.
-- DB_PlayerSummons is the Osiris database made for exactly this question.
function FamiliarIdleSummons()
    local out, seen = {}, {}
    if not (Osi and Osi.DB_PlayerSummons) then return out end
    local ok, rows = pcall(function() return Osi.DB_PlayerSummons:Get(nil) end)
    if not ok or not rows then return out end
    for _, row in pairs(rows) do
        for _, cell in ipairs(row) do
            if type(cell) == "string" and Osi.Exists and Osi.Exists(cell) == 1 then
                local okS, isSummon = pcall(Osi.IsSummon, cell)
                if okS and isSummon == 1 then
                    local key = CleanUuid(cell) or cell
                    if not seen[key] then
                        seen[key] = true
                        out[#out + 1] = cell
                    end
                end
            end
        end
    end
    return out
end

-- Template name if the entity is resolvable, otherwise the raw GUID string (in the game it
-- already carries the template name, e.g. S_Player_ShadowHeart_3ed74f06-...).
function FamiliarIdleName(u)
    if Ext.Entity and Ext.Entity.Get then
        local ok, e = pcall(Ext.Entity.Get, u)
        if ok and e ~= nil and e.ServerCharacter ~= nil
            and e.ServerCharacter.Template ~= nil
            and e.ServerCharacter.Template.Name ~= nil then
            return tostring(e.ServerCharacter.Template.Name)
        end
    end
    return tostring(u)
end

function FamiliarIdleHasPartyComponent(u)
    if not (Ext.Entity and Ext.Entity.Get) then return false end
    local ok, e = pcall(Ext.Entity.Get, u)
    return ok and e ~= nil and e.PartyMember ~= nil
end

local function FamiliarIdleNote(why)
    FamiliarIdle.skipped = FamiliarIdle.skipped + 1
    FamiliarIdle.lastReason = why
end

-- 04.3.25: instead of a random spot, walk the familiar along an orbit around the host:
-- it circles, sometimes reverses, sometimes swings in close. Same rules, more character.
function FamiliarIdle.hop(u, key, now, hx, hy, hz)
    local TWO_PI = 6.28318530718
    local orbit = FamiliarIdle.orbit[key]
    if not orbit then
        -- start from wherever the familiar actually is, so the first hop is not a jump
        local ang = math.random() * TWO_PI
        if Osi.GetPosition then
            local ok, px, py, pz = pcall(Osi.GetPosition, u)
            if ok and px and (math.abs(px - hx) > 0.01 or math.abs(pz - hz) > 0.01) then
                local atan2 = math.atan2 or math.atan
                ang = atan2(px - hx, pz - hz)
            end
        end
        orbit = { ang = ang, dir = (math.random() < 0.5) and 1 or -1 }
        FamiliarIdle.orbit[key] = orbit
    end
    if math.random() < 0.20 then orbit.dir = -orbit.dir end
    local function FamiliarIdleCrowded(uuid, tx, tz)
        if not (uuid and Osi.GetPosition) then return false end
        local ok, px, py, pz = pcall(Osi.GetPosition, uuid)
        if not ok or not px then return false end
        local dx, dz = tx - px, tz - pz
        return (dx * dx + dz * dz) < 2.25
    end
    local function FamiliarIdleSpotFree(tx, tz)
        for _, nc in ipairs(LocalSpatialIndex.chars or {}) do
            local dx, dz = tx - nc.x, tz - nc.z
            if (dx * dx + dz * dz) < 2.25 then return false end
        end
        if GetPartyCompanions then
            for _, pc in ipairs(GetPartyCompanions()) do
                if FamiliarIdleCrowded(pc, tx, tz) then return false end
            end
        end
        return true
    end
    if not Osi.CharacterMoveToPosition then
        FamiliarIdleNote("no move api")
        return false
    end
    -- up to 4 candidates along the orbit, so a crowded spot does not eat the window.
    -- The orbit angle only advances on a SUCCESSFUL hop: rejected candidates must not
    -- silently spin the orbit (that made the drift look erratic after a crowded series).
    local ang = orbit.ang
    for attempt = 1, 4 do
        ang = (ang + orbit.dir * (0.61 + math.random() * 0.70)) % TWO_PI
        local r = 2.2 + math.random() * 1.4
        if math.random() < 0.15 then r = 1.8 + math.random() * 0.3 end   -- close pass
        local tx = hx + math.sin(ang) * r
        local tz = hz + math.cos(ang) * r
        if FamiliarIdleSpotFree(tx, tz) then
            if Osi.FindValidPosition then
                local okPos, px, py, pz = pcall(Osi.FindValidPosition, tx, hy, tz, 0.6, u, u)
                if okPos and px then tx, tz = px, pz or tz end
            end
            local okMove = pcall(Osi.CharacterMoveToPosition, u, tx, hy, tz, "Walk", "")
            if okMove then
                orbit.ang = ang
                FamiliarIdle.hops = FamiliarIdle.hops + 1
                FamiliarIdle.nextHopAt[key] = now + FamiliarIdle.hopMinMs
                    + math.random() * (FamiliarIdle.hopMaxMs - FamiliarIdle.hopMinMs)
                -- turn to the party once it arrives: cheap, no animation asset involved
                if Osi.LookAtEntity and Osi.GetHostCharacter then
                    local host = Osi.GetHostCharacter()
                    if host then pcall(Osi.LookAtEntity, u, host) end
                end
                Log(string.format(
                    "Familiar fidget: %s circles to %.2f,%.2f (%.1f m from the host, %+d deg)",
                    tostring(FamiliarIdle.found[key] or key), tx, tz, r,
                    math.floor(orbit.dir * 35)))
                return true
            end
        end
    end
    FamiliarIdleNote("crowded")
    return false
end

function FamiliarIdle.tick(now)
    FamiliarIdle.syncFromSave()
    if not FamiliarIdle.enabled then return end
    if now < FamiliarIdle.nextScanAt then return end
    FamiliarIdle.nextScanAt = now + FamiliarIdle.scanMs
    if not (Osi and Osi.GetHostCharacter) then return end
    local host = Osi.GetHostCharacter()
    if not host then return end
    if IsAnyDialogActive() then FamiliarIdleNote("dialog") return end
    if Osi.IsInCombat and Osi.IsInCombat(host) == 1 then FamiliarIdleNote("combat") return end
    if LocalSpatialIndex.enemyNearby then FamiliarIdleNote("hostiles nearby") return end
    if Osi.IsMoving and Osi.IsMoving(host) == 1 then FamiliarIdleNote("host is walking") return end
    if not LocalSpatialIndex.ready then FamiliarIdleNote("index warming up") return end
    local hx, hy, hz = LocalSpatialIndex.hx, LocalSpatialIndex.hy, LocalSpatialIndex.hz
    if not hx or not hz then FamiliarIdleNote("no host position") return end
    local seen = {}
    -- 04.3.24: ask the game who the summons are (the spatial index cannot see them)
    for _, u in ipairs(FamiliarIdleSummons()) do
        local key = CleanUuid(u) or u
        seen[key] = true
        FamiliarIdle.found[key] = FamiliarIdleName(u)
        local dead = Osi.IsDead and Osi.IsDead(u) == 1
        local d = Osi.GetDistanceTo and Osi.GetDistanceTo(host, u) or nil
        local okEnemy, isEnemy = pcall(Osi.IsEnemy, host, u)
        if dead then
            FamiliarIdleNote("summon is dead")
        elseif not d then
            FamiliarIdleNote("no distance")
        elseif d > 12.0 then
            FamiliarIdleNote("familiar too far")
        elseif d < 1.2 then
            FamiliarIdleNote("familiar is on the host")
        elseif okEnemy and isEnemy == 1 then
            FamiliarIdleNote("summon is hostile")
        elseif now >= (FamiliarIdle.nextHopAt[key] or 0) then
            FamiliarIdle.hop(u, key, now, hx, hy, hz)
        end
    end
    for key in pairs(FamiliarIdle.found) do
        if not seen[key] then FamiliarIdle.found[key] = nil end
    end
end

Ext.Events.Tick:Subscribe(function()
    -- Strict lifecycle gate: never touch Osi.* during LoadModule / LoadSession / LoadLevel / Sync / Paused
    if not IsOsirisReady() then return end

    local now = Ext.Utils.MonotonicTime()
    local steppedSpatialThisTick = false

    -- Advance chunked spatial index by a tiny 500-item / 250-char slice (~0.2ms) when refreshing
    if LocalSpatialIndex.sweeping and Osi and Osi.GetHostCharacter then
        local sweepHost = Osi.GetHostCharacter()
        if sweepHost then
            StepLocalSpatialIndex(sweepHost, now, 500)
            steppedSpatialThisTick = true
        end
    end

    if (now - LastWatchdog) >= ConfigValues.WatchdogInterval then
        LastWatchdog = now
        local wHost = StateChecks.updateHostActivity(now)
        if wHost then
            local didInitialUnstick = NeedsInitialPartyUnstick
            RecoverPartyFromStuckOsiris(wHost, now)
            if IsAmbientEnabled(wHost) then
                -- Defer heavy 20k-entity array allocation by 1 watchdog interval (200ms) on the
                -- single startup-unstick tick so even Frame 1 stays well under BG3SE's 10ms mark!
                if not didInitialUnstick then
                    if not steppedSpatialThisTick then
                        StepLocalSpatialIndex(wHost, now, 500)
                    end
                    if Config.ActionVoices and not VocalResourceCache.complete then
                        StepVocalResourceCache(450)
                    end
                end
                CheckNearbyTrapsWatchdog(wHost, now)
            end
            FieldTorchSystem.tickWatchdog(wHost, now)
        end

        for _, queue in pairs(ActiveQueues) do
            if queue.isProcessing then
                local abortNow, reason = queue:shouldAbort(now)
                if abortNow then
                    queue:abort(reason)
                end
            end
        end

        if CurrentReader ~= nil then
            local rq = ActiveQueues[CurrentReader]
            if not rq or not rq.isProcessing then
                CurrentReader = nil
            end
        end
    end

    -- 04.3.23: familiars get a little character in idles (self-throttled, off by default)
    FamiliarIdle.tick(now)

    if IsAnyDialogActive() then
        if ConfigValues.Debug and (now - LastDiagLogTime) >= 15000 then
            LastDiagLogTime = now
            Log("Paused: Dialog is active.")
        end
        return
    end
    if (now - LastDecisionCheck) < Config.CheckInterval then return end
    LastDecisionCheck = now

    if not Osi or not Osi.GetHostCharacter then return end
    local host = Osi.GetHostCharacter()
    if not host then return end

    local companions = GetPartyCompanions()

    if InitializedForHost ~= host then
        PersistentVars = PersistentVars or {}
        pcall(function()
            if Osi.HasPassive(host, "AmbientAI_Passive") == 0 then
                Osi.AddPassive(host, "AmbientAI_Passive")
            end
            -- One-time migration for saves that received AmbientAI_Passive when ToggledDefaultOff was set
            if not PersistentVars.DefaultOnMigrated_v122 and not UserExplicitlyToggledOff then
                PersistentVars.DefaultOnMigrated_v122 = true
                if Osi.HasActiveStatus(host, "AMBIENT_AI_STATUS") ~= 1 then
                    if Osi.TogglePassive then
                        pcall(Osi.TogglePassive, host, "AmbientAI_Passive")
                    end
                    if Osi.HasActiveStatus(host, "AMBIENT_AI_STATUS") ~= 1 and Osi.ApplyStatus then
                        pcall(Osi.ApplyStatus, host, "AMBIENT_AI_STATUS", -1.0, 1, host)
                    end
                end
            end
        end)
        InitializedForHost = host
        EnsureAutoSellStorage()
        local isOn = IsAmbientEnabled(host, companions)
        Log(string.format(
            "Initialized Build 04.3.2 (v1.4.3.2) for host %s | Toggle=%s | Party=%d | AllowGrouped=%s (%ds, Anchor=%.1fm) | FieldTorch=%s | Voices=%s (%d%%) | SmartScavenger=%s | AutoSell=%s | TrapReflex=%s | AutoWash=%s",
            tostring(host),
            isOn and "ON" or "OFF",
            #companions,
            tostring(Config.AllowGrouped),
            tonumber(Config.GroupedIdleDelay) or 6,
            tonumber(Config.IdleAnchorRadius) or 3.5,
            tostring(Config.FieldTorch),
            tostring(Config.ReactiveVoices),
            tonumber(Config.VoiceShare) or 80,
            tostring(Config.SmartScavenger),
            tostring(Config.AutoSellTrader),
            tostring(Config.TrapReflex),
            tostring(Config.AutoWash)
        ))
    end

    if not IsAmbientEnabled(host, companions) then
        if ConfigValues.Debug and (now - LastDiagLogTime) >= 15000 then
            LastDiagLogTime = now
            Log("Paused: 'Ambient AI' passive toggle on hotbar (Passives tab) is OFF.")
        end
        return
    end

    local inCombat = (Osi.IsInCombat(host) == 1)
    local sneaking = IsSneakingOrInvisible(host)
    local turnBased = IsInTurnBased(host)
    if inCombat or sneaking or turnBased then
        if ConfigValues.Debug and (now - LastDiagLogTime) >= 10000 then
            LastDiagLogTime = now
            Log(string.format(
                "Paused: Combat=%s | Sneak/Invis=%s | TurnBased=%s",
                tostring(inCombat),
                tostring(sneaking),
                tostring(turnBased)
            ))
        end
        return
    end

    -- Post-Combat Heavy Battle Breather & Gentle Short Rest Hint (fires ~4.8s after tough fights!)
    if ScavengeStats.pendingBreatherTime > 0 and now >= ScavengeStats.pendingBreatherTime then
        StateChecks.processPostCombatBreather(host, now)
    end

    -- Out-of-combat Auto-Wash (post-combat scheduled wash + peaceful camp/exploration refresh)
    if Config.AutoWash then
        if PendingAutoWashTime > 0 and now >= PendingAutoWashTime then
            WashPartyClean(host, now)
        elseif IsInCamp(host) and (now - LastAutoWashTime) >= 45000 then
            WashPartyClean(host, now)
        elseif (now - LastAutoWashTime) >= 90000 and Osi.IsMoving(host) == 0 then
            WashPartyClean(host, now)
        end
    end

    if #companions <= 1 then
        if ConfigValues.Debug and (now - LastDiagLogTime) >= 15000 then
            LastDiagLogTime = now
            Log("No active party companions detected alongside host (PartyMembers=" .. tostring(#companions) .. ").")
        end
        return
    end

    local activePartySet = {}
    local freeChars = {}
    local busyCount = 0
    for _, char in ipairs(companions) do
        activePartySet[char] = true
        if not ActiveQueues[char] then
            ActiveQueues[char] = ActionQueue:new(char)
        end
        local queue = ActiveQueues[char]
        if queue.isProcessing then
            busyCount = busyCount + 1
        elseif StateChecks.isReadyForNewTask(char, host, now) then
            table.insert(freeChars, char)
        end
    end

    for uuid, q in pairs(ActiveQueues) do
        if not activePartySet[uuid] then
            if q.isProcessing then q:abort("left_party") end
            ActiveQueues[uuid] = nil
        end
    end

    if #freeChars == 0 then
        if ConfigValues.Debug and busyCount == 0 and (now - LastDiagLogTime) >= 10000 then
            LastDiagLogTime = now
            local idleSec = (now - HostLastActiveTime) / 1000.0
            Log(string.format(
                "Waiting: Party=%d | HostIdle=%.1fs/%ds | AllowGrouped=%s",
                #companions,
                idleSec,
                tonumber(Config.GroupedIdleDelay) or 6,
                tostring(Config.AllowGrouped)
            ))
        end
        return
    end
    ShuffleInPlace(freeChars)

    -- Check for active Bard / Musician performance first!
    local activePerformer = FindNearbyBardPerformer(host, companions)

    ReservedTargets = {}
    for _, q in pairs(ActiveQueues) do
        if q.isProcessing then
            if q.currentTarget then
                ReservedTargets[q.currentTarget] = q.character
            end
            if q.clusterTargets then
                for _, cu in ipairs(q.clusterTargets) do
                    ReservedTargets[cu] = q.character
                end
            end
        end
    end

    -- 04.3.7: give the party its own voice slot (see AmbientVoice.chatterTick)
    if AmbientVoice.chatterTick then
        pcall(AmbientVoice.chatterTick, now)
    end

    local targets, zone = ScanNearbyWorldTargets(host, now)
    if not targets then return end

    local searchRadius = Config.SearchRadius
    local inCamp = zone.inCamp
    local useContext = Config.ContextAware
    local isDungeon = useContext and zone.isDungeon
    local inDanger = useContext and zone.inDanger
    local isSettlement = useContext and zone.isSettlement
    local nonBardDispatched = 0

    -- Build 04.2 Dark-Room Torchbearer Awareness: count currently burning vs safe unlit light fixtures
    -- (including simple wax candles & candle clusters «Свечи») so companions illuminate dark rooms first!
    local litLightsCount = 0
    local unlitSafeCount = 0
    -- 04.3.10: how many fixtures were refused because a live hostile (or a flammable hazard) sits
    -- within 16 m. Purely for the log: previously this silently produced "unlitSafeCount=0".
    local enemyBlockedFixtures = 0
    if targets.candles then
        for _, cItem in ipairs(targets.candles) do
            if IsLightSourceAlreadyLit(cItem.u) then
                litLightsCount = litLightsCount + 1
            elseif cItem.canIgnite == true
                and not ReservedTargets[cItem.u]
                and (not Blacklist[cItem.u] or now >= Blacklist[cItem.u])
                and not IsNearFlammableHazard(cItem, targets.hazards)
            then
                unlitSafeCount = unlitSafeCount + 1
            elseif cItem.canIgnite == true
                and (not Blacklist[cItem.u] or now >= Blacklist[cItem.u])
                and IsNearFlammableHazard(cItem, targets.hazards)
            then
                enemyBlockedFixtures = enemyBlockedFixtures + 1
            end
        end
    end
    local roomNeedsLight = Config.LightSources and (unlitSafeCount > 0)
    local roomIsDark = roomNeedsLight and (litLightsCount == 0 or (isDungeon and litLightsCount < 2 and unlitSafeCount >= 2))

    -- Best-Claimant Hero Habit Check: if only 1 scarce signature prop is free right now and another
    -- currently-free companion has a dominant lore affinity for it (score >= 2.4 & >= 1.55x ours),
    -- yield that scarce prop so Gale gets bookshelves/telescopes, Shadowheart gets pets/candles,
    -- Astarion gets mirrors/paintings, and Lae'zel/Karlach get training dummies!
    local function ShouldYieldScarceProp(char, category, propName, availableCount)
        if not Config.Personalities or #freeChars < 2 or (availableCount or 1) > 1 then
            return false
        end
        local propLower = string.lower(tostring(propName or ""))
        local myScore = AnimSystem.getSignatureScore(char, category, propLower)
        for _, other in ipairs(freeChars) do
            if not SameEntity(other, char) then
                local theirScore = AnimSystem.getSignatureScore(other, category, propLower)
                if theirScore >= 2.4 and theirScore >= (myScore * 1.55) then
                    return true
                end
            end
        end
        return false
    end

    for _, char in ipairs(freeChars) do
        local charKey = CleanUuid(char) or char
        -- 04.3.13: never launch several companions on the exact same tick, but keep it to
        -- roughly one decision tick (600 ms) apart instead of 1.3-2.9 s * position.
        if nonBardDispatched >= 1 and not activePerformer then
            CompanionRestUntil[charKey] = now + math.random(600, 1200)
        else
        local queue = ActiveQueues[char]
        local charAssigned = false

        local function ReserveForChar(targetUuid, cooldownMs)
            if targetUuid then
                ReservedTargets[targetUuid] = char
                queue.currentTarget = targetUuid
                if cooldownMs then
                    Blacklist[targetUuid] = now + cooldownMs
                end
            end
            charAssigned = true
            nonBardDispatched = nonBardDispatched + 1
        end

        local function FindFirstValid(list, verticalTol, mode, extraFilter)
            for _, item in ipairs(list) do
                local u = item.u
                if u and not ReservedTargets[u] and (not Blacklist[u] or now >= Blacklist[u]) then
                    if not extraFilter or extraFilter(item) then
                        local dChar = Osi.GetDistanceTo(char, u)
                        local dHost = Osi.GetDistanceTo(host, u)
                        if dChar and dChar <= searchRadius and dHost and dHost <= searchRadius then
                            local tol = verticalTol or 2.5
                            local _, y1, _ = Osi.GetPosition(char)
                            local _, y2, _ = Osi.GetPosition(u)
                            if (not y1 or not y2 or math.abs(y1 - y2) <= tol) then
                                if (not mode or IsSafeWorldObject(u, mode)) and Osi.HasLineOfSight(char, u) == 1 then
                                    return item
                                end
                            end
                        end
                    end
                end
            end
            return nil
        end

        local function FindClosestValid(list, verticalTol, mode, extraFilter)
            local bestItem = nil
            local bestDist = 999999.0
            for _, item in ipairs(list) do
                local u = item.u
                if u and not ReservedTargets[u] and (not Blacklist[u] or now >= Blacklist[u]) then
                    if not extraFilter or extraFilter(item) then
                        local dChar = Osi.GetDistanceTo(char, u)
                        local dHost = Osi.GetDistanceTo(host, u)
                        if dChar and dChar <= searchRadius and dHost and dHost <= searchRadius and dChar < bestDist then
                            local tol = verticalTol or 2.5
                            local _, y1, _ = Osi.GetPosition(char)
                            local _, y2, _ = Osi.GetPosition(u)
                            if (not y1 or not y2 or math.abs(y1 - y2) <= tol) then
                                if not mode or IsSafeWorldObject(u, mode) then
                                    local hasLoS = (Osi.HasLineOfSight(char, u) == 1)
                                    -- Tiny 5-8cm wax candles (LTS_DUN_Candles_* / Cluster_*) sitting flush on
                                    -- stone stair steps often have Dummy_Root (y=0.0m) clipped by stair-lip raycasts;
                                    -- accept them if GetSmartApproachPosition confirms a valid walkable spot nearby!
                                    if not hasLoS and mode == "light" and item.isWaxCandle and dChar <= 9.5 then
                                        local ax = GetSmartApproachPosition(char, u, 1.0)
                                        hasLoS = (ax ~= nil)
                                    end
                                    if hasLoS then
                                        bestItem = item
                                        bestDist = dChar
                                    end
                                end
                            end
                        end
                    end
                end
            end
            return bestItem
        end

        -- ====================================================================
        -- PRIORITY LAYER A: LIVE BARD PERFORMANCE REACTION
        -- ====================================================================
        if not charAssigned and activePerformer and not SameEntity(activePerformer, char) then
            local dPerf = Osi.GetDistanceTo(char, activePerformer)
            if dPerf and dPerf <= math.max(14.0, searchRadius) then
                charAssigned = true
                CreateBardAudienceSequence(char, activePerformer)
            end
        end

        -- ====================================================================
        -- PRIORITY LAYER B: DARK-ROOM TORCHBEARERS, SMART SCAVENGER & WALLS
        -- ====================================================================
        if Config.LightSources and unlitSafeCount == 0 and enemyBlockedFixtures > 0
            and (now - (LightTrace.lastGateLog or 0)) >= 15000 then
            LightTrace.lastGateLog = now
            Log(string.format(
                "Light layer idle: %d fixture(s) refused - live hostile or flammable hazard within 16m (dark-room duty on hold)",
                enemyBlockedFixtures))
        end
        if not charAssigned and Config.LightSources and now < NextLightTime
            and (now - (LightTrace.lastGateLog or 0)) >= 15000 then
            LightTrace.lastGateLog = now
            LightTrace.line("gate", "light layer cooling down: %.1fs left (unlit=%s lit=%s roomDark=%s)",
                (NextLightTime - now) / 1000.0, tostring(unlitSafeCount), tostring(litLightsCount), tostring(roomIsDark))
        end
        -- 04.3.10: the light-bearer already carries a burning light - no need to walk him to candles
        -- as well (every other roleplay layer is gated on carryingFieldTorch too).
        local lightLayerAllowed = not FieldTorchSystem.isCarryingAutoTorch(char)
        if not charAssigned and lightLayerAllowed and Config.LightSources and now >= NextLightTime then
            local activeLighters = 0
            for _, qOther in pairs(ActiveQueues) do
                if qOther.isProcessing and qOther.activityTag == "light" then
                    activeLighters = activeLighters + 1
                end
            end
            local maxLighters = ((unlitSafeCount + activeLighters) >= 2) and 2 or 1
            if activeLighters < maxLighters then
                -- 04.3.10: "the room is already lit" rule. Lighting exists to make a dark place
                -- explorable and to help hunt for secrets - not to switch on every candle in a room
                -- that is already bright. With >= 2 burning fixtures that outnumber the unlit ones,
                -- only a fixture within arm's reach of the companion is worth finishing.
                local roomWellLit = (litLightsCount >= 3) and (litLightsCount >= 2 * unlitSafeCount)
                local unlit = FindClosestValid(targets.candles, 2.35, "light", function(item)
                    return item.canIgnite == true
                        and not IsNearFlammableHazard(item, targets.hazards)
                        and not IsLightSourceAlreadyLit(item.u)
                end)
                local finishNearby = true
                if roomWellLit and unlit then
                    local dUnlit = Osi.GetDistanceTo(char, unlit.u)
                    finishNearby = (dUnlit ~= nil and dUnlit <= 6.0)
                    if not finishNearby then
                        -- stay quiet for a while instead of re-evaluating this room every tick
                        NextLightTime = now + 15000
                        if (now - (LightTrace.lastGateLog or 0)) >= 15000 then
                            LightTrace.lastGateLog = now
                            Log(string.format(
                                "Light layer idle: room already lit (%d burning / %d unlit) and the nearest unlit fixture is %.1fm away",
                                litLightsCount, unlitSafeCount, dUnlit or -1))
                        end
                    end
                end
                if unlit and finishNearby and not ShouldYieldScarceProp(char, "light", unlit.n, unlitSafeCount) then
                    -- Collect up to 2 adjacent unlit safe candles/sconces on/above the same table/altar/stairs (<= 2.3m)
                    local clusterExtras = nil
                    if unlit.x and targets.candles then
                        for _, adj in ipairs(targets.candles) do
                            if adj.u ~= unlit.u
                                and adj.x
                                and adj.canIgnite == true
                                and not ReservedTargets[adj.u]
                                and (not Blacklist[adj.u] or now >= Blacklist[adj.u])
                                and not IsNearFlammableHazard(adj, targets.hazards)
                                and not IsLightSourceAlreadyLit(adj.u)
                            then
                                local cdx = adj.x - unlit.x
                                local cdz = adj.z - unlit.z
                                local cdy = math.abs((adj.y or 0) - (unlit.y or 0))
                                if (cdx * cdx + cdz * cdz) <= 5.29 and cdy <= 1.5
                                    and IsSafeWorldObject(adj.u, "light")
                                then
                                    clusterExtras = clusterExtras or {}
                                    clusterExtras[#clusterExtras + 1] = adj.u
                                    ReservedTargets[adj.u] = char
                                    Blacklist[adj.u] = now + 10000
                                    if #clusterExtras >= 2 then break end
                                end
                            end
                        end
                    end
                    local consumed = 1 + (clusterExtras and #clusterExtras or 0)
                    unlitSafeCount = math.max(0, unlitSafeCount - consumed)
                    -- Allow a 2nd companion to immediately help light remaining dark-room fixtures
                    -- on their natural staggered wake-up; apply cooldown once all room lights are claimed!
                    NextLightTime = (unlitSafeCount >= 1) and (now + 900) or (now + (isDungeon and 7500 or 10500))
                    AmbientLightState = {
                        now = now, nextLightTime = NextLightTime,
                        unlitSafe = unlitSafeCount, lit = litLightsCount,
                        roomDark = roomIsDark, zone = zone and zone.mode or "?",
                        maxLighters = maxLighters, activeLighters = activeLighters,
                    }
                    ReserveForChar(unlit.u, 8000)
                    queue.clusterTargets = clusterExtras
                    CreateTorchbearerSequence(char, unlit.u, clusterExtras)
                end
            end
        end

        if not charAssigned and Config.SmartScavenger and not inCamp and ShouldCompanionScavengeNow(char) then
            -- 1. Smart loose world items (never 1-gold clutter; calls out gear/potions/books/keys!)
            local smartLoose = FindFirstValid(targets.loot, 2.5, nil, function(item)
                local clean = CleanUuid(item.u) or item.u
                if AlertedObjects[clean] then return false end
                if Osi.IsInInventory and Osi.IsInInventory(item.u) == 1 then return false end
                if Osi.IsTrapArmed and Osi.IsTrapArmed(item.u) == 1 then return false end
                if not IsPartyOwnedOrUnowned(item.u) then return false end
                local act = ClassifyScavengeItem(item.u, true)
                if act == "SKIP_JUNK" then
                    Blacklist[item.u] = now + 3600000
                    return false
                end
                if act == "CAMP_AUTOSELL" and not Config.AutoSellTrader then
                    return false
                end
                return true
            end)

            if smartLoose then
                ScavengeStreak[charKey] = (ScavengeStreak[charKey] or 0) + 1
                ReserveForChar(smartLoose.u, 1800000)
                CreateSmartLooseItemSequence(char, host, smartLoose.u)
            else
                -- 2. Safe unlocked minor containers (vases, urns, crates, sacks, safe barrels — NEVER chests!)
                local minorCont = FindFirstValid(targets.scavengeContainers, 2.5, nil, function(item)
                    return IsSafeScavengeContainer(item.u)
                end)
                if minorCont then
                    ScavengeStreak[charKey] = (ScavengeStreak[charKey] or 0) + 1
                    ReserveForChar(minorCont.u, 1800000)
                    CreateSmartScavengeContainerSequence(char, host, minorCont.u)
                end
            end
        elseif not charAssigned and Config.LootMode ~= 2 and not inCamp then
            -- Legacy LootMode fallback (still protected against 1-gold junk clutter!)
            local lootMode = Config.LootMode
            local loose = FindFirstValid(targets.loot, 2.5, "pickup", function(item)
                local act = ClassifyScavengeItem(item.u, true)
                if act == "SKIP_JUNK" or act == "ALERT_PLAYER" then return false end
                return (lootMode == 0)
                    or (lootMode == 1 and (string.find(item.n, "Gold", 1, true) ~= nil or string.find(item.n, "Map", 1, true) ~= nil))
            end)
            if loose then
                ReserveForChar(loose.u, 3600000)
                CreateSmartLooseItemSequence(char, host, loose.u)
            elseif lootMode == 0 then
                local cont = FindFirstValid(targets.containers, 2.5, "container")
                if cont then
                    ReserveForChar(cont.u, 300000)
                    CreateRummageSequence(char, cont.u, false)
                else
                    local corpse = FindFirstValid(targets.corpses, 2.5, nil)
                    if corpse then
                        ReserveForChar(corpse.u, 300000)
                        CreateRummageSequence(char, corpse.u, true)
                    end
                end
            end
        end

        if not charAssigned and Config.AttackWalls and not inCamp then
            local wall = FindFirstValid(targets.walls, 2.5, "wall")
            if wall then
                ReserveForChar(wall.u, 15000)
                CreateAttackWallSequence(char, wall.u)
            end
        end

        -- ====================================================================
        -- PRIORITY LAYER C: 3-TIER ZONE CONTEXT & HERO SIGNATURE HABITS
        -- ====================================================================
        if not charAssigned then
            local candidates = {}
            local carryingFieldTorch = FieldTorchSystem.isCarryingAutoTorch(char)

            -- 1. Greet Scratch / Owlbear Cub (Signature: Shadowheart, Halsin, Minsc, Karlach; Boosted in Camp!)
            if Config.SocialPets and #targets.pets > 0 and not inDanger and not carryingFieldTorch then
                local pet = FindFirstValid(targets.pets, 2.5, nil)
                if pet and not ShouldYieldScarceProp(char, "pet", pet.n, #targets.pets) then
                    local petZoneMult = inCamp and 1.85 or 1.15
                    table.insert(candidates, {
                        weight = 22.0 * AnimSystem.getSignatureScore(char, "pet", pet.n) * petZoneMult,
                        run = function()
                            ReserveForChar(pet.u, 120000)
                            CreatePetGreetSequence(char, pet.u)
                        end
                    })
                end
            end

            -- 2. Training Dummy Practice (Signature: Lae'zel, Karlach, Minsc, Wyll)
            if #targets.dummies > 0 and not inDanger and not carryingFieldTorch then
                local dummy = FindFirstValid(targets.dummies, 2.5, "use")
                if dummy and not ShouldYieldScarceProp(char, "dummy", dummy.n, #targets.dummies) then
                    local dummyZoneMult = inCamp and 1.35 or (isDungeon and 0.75 or 1.10)
                    table.insert(candidates, {
                        weight = 18.0 * AnimSystem.getSignatureScore(char, "dummy", dummy.n) * dummyZoneMult,
                        run = function()
                            ReserveForChar(dummy.u, 180000)
                            CreateDummyPracticeSequence(char, dummy.u)
                        end
                    })
                end
            end

            -- 3. Bookshelf & Pocket Tome Reading (Signature: Gale, Minthara, Jaheira, Shadowheart)
            -- Build 04.1: Never pull out a book or squint at bookshelves in a dark unlit room — light candles first!
            local darkReadMult = roomIsDark and 0.08 or 1.0
            local darkInspectMult = roomIsDark and 0.20 or 1.0
            if CurrentReader == nil and not inDanger and not carryingFieldTorch then
                local shelf = FindFirstValid(targets.books, 2.5, "use")
                if shelf then
                    if not ShouldYieldScarceProp(char, "books", shelf.n, 1) then
                        local bookZoneMult = inCamp and 1.45 or (isSettlement and 1.35 or (isDungeon and 0.95 or 1.0))
                        table.insert(candidates, {
                            weight = 18.0 * AnimSystem.getSignatureScore(char, "books", shelf.n) * bookZoneMult * darkReadMult,
                            run = function()
                                ReserveForChar(shelf.u, 120000)
                                CreateReadSequence(char, shelf.u)
                            end
                        })
                    end
                elseif not isDungeon then
                    -- Pocket book/tome reading in Camp & peaceful Settlements (especially Gale!)
                    local pocketMult = inCamp and 1.55 or 1.0
                    table.insert(candidates, {
                        weight = 3.8 * GetTraitWeight(char, "books") * pocketMult * darkReadMult,
                        run = function()
                            ReserveForChar(nil, nil)
                            CreateReadSequence(char, nil)
                        end
                    })
                end
            end

            -- 4. Curiosity Objects: Globes, Telescopes (Gale), Mirrors (Astarion), Stuffed Bears/Shrines (Shadowheart)
            if now > NextFlavorTime and #targets.curiosity > 0 then
                local cur = FindFirstValid(targets.curiosity, 2.8, "use")
                if cur and not ShouldYieldScarceProp(char, "curiosity", cur.n, #targets.curiosity) then
                    local curZoneMult = isSettlement and 1.45 or (inDanger and 0.70 or 1.10)
                    table.insert(candidates, {
                        weight = 16.0 * AnimSystem.getSignatureScore(char, "curiosity", string.lower(cur.n)) * curZoneMult * darkInspectMult,
                        run = function()
                            ReserveForChar(cur.u, 90000)
                            NextFlavorTime = now + Config.FlavorCooldown
                            CreateCuriositySequence(char, cur.u, cur.safeUse)
                        end
                    })
                end
            end

            -- 5. Paintings & Statues (Signature: Astarion, Shadowheart, Gale; Boosted in Towns/Taverns!)
            if #targets.art > 0 then
                local art = FindFirstValid(targets.art, 3.2, "use")
                if art and not ShouldYieldScarceProp(char, "art", art.n, #targets.art) then
                    local artZoneMult = isSettlement and 1.45 or (inDanger and 0.65 or 1.05)
                    table.insert(candidates, {
                        weight = 14.5 * AnimSystem.getSignatureScore(char, "art", string.lower(art.n)) * artZoneMult * darkInspectMult,
                        run = function()
                            ReserveForChar(art.u, 120000)
                            CreateArtSequence(char, art.u)
                        end
                    })
                end
            end

            -- 6. Chairs, Benches & Stools (Cozy in Camp & Taverns/Towns; strictly off in Red Danger Zones!)
            local foundSeat = false
            if #targets.chairs > 0 and not inDanger and not carryingFieldTorch then
                -- Build 04.3.6: closest seat wins (was: whichever the scan saw first, up to
                -- 12 m away - companions "vanished" to benches the player could not see) and
                -- the seat has to be near the player's own anchor, so it stays on screen.
                local chair = FindClosestValid(targets.chairs, 2.2, "seat", function(item)
                    local tx = GetSmartApproachPosition(char, item.u, 1.0)
                    if not tx then return false end
                    local dHost = Osi.GetDistanceTo(host, item.u)
                    if not dHost or dHost > AmbientSeat.SEAT_HOST_RADIUS then return false end
                    return AmbientSeat.canSitOn(item.u) ~= false
                end)
                if chair then
                    foundSeat = true
                    local relaxMult = 1.0
                    if useContext then
                        if inCamp or zone.isRelaxed then
                            relaxMult = 1.45
                        elseif isDungeon then
                            relaxMult = 0.25 -- Brief rare perch only in cleared, non-danger ruins
                        else
                            relaxMult = 1.20 -- Peaceful villages & roads
                        end
                    end
                    table.insert(candidates, {
                        weight = 16.5 * GetTraitWeight(char, "chair") * relaxMult,
                        run = function()
                            ReserveForChar(chair.u, 90000)
                            CreateSitSequence(char, chair.u)
                        end
                    })
                end
            end

            -- 6b. Camp & Peaceful Outdoor Ground-Sitting (NEVER in Dungeons or Danger Zones!)
            if (not foundSeat) and (not isDungeon) and (not inDanger) and (not carryingFieldTorch) then
                local activeGroundRests = 0
                for _, qOther in pairs(ActiveQueues) do
                    if qOther.isProcessing and qOther.activityTag == "ground_rest" then
                        activeGroundRests = activeGroundRests + 1
                    end
                end
                if activeGroundRests < 2 then
                    local groundZoneMult = inCamp and 1.35 or 1.00
                    table.insert(candidates, {
                        weight = 11.0 * GetTraitWeight(char, "chair") * groundZoneMult,
                        run = function()
                            ReserveForChar(nil, nil)
                            CreateGroundRestSequence(char, host)
                        end
                    })
                end
            end

            -- 7. Beds (Strictly restricted to cozy Taverns/Inns outside Camp — NEVER in Camp or Dungeons!
            --    In Camp, DB_CampBed beds/bedrolls trigger End Day / Long Rest / Leave Camp!)
            if (not inCamp) and (not carryingFieldTorch) and (not useContext or (zone.isRelaxed and not isDungeon and not inDanger)) and #targets.beds > 0 then
                local bed = FindFirstValid(targets.beds, 2.5, "bed")
                if bed then
                    table.insert(candidates, {
                        weight = 9.5 * GetTraitWeight(char, "bed"),
                        run = function()
                            ReserveForChar(bed.u, 180000)
                            CreateBedNapSequence(char, bed.u)
                        end
                    })
                end
            end

            -- 8. Warm Hands at Lit Fire / Brazier / Campfire (Major evening Camp centerpiece — zero Osi.Use!)
            if #targets.candles > 0 and not inDanger then
                local litFire = FindFirstValid(targets.candles, 2.5, nil, function(item)
                    return item.isWarmFire == true and IsLightSourceAlreadyLit(item.u)
                end)
                if litFire then
                    local fireZoneMult = inCamp and 2.05 or (isDungeon and 0.65 or 1.15)
                    table.insert(candidates, {
                        weight = 12.5 * GetTraitWeight(char, "fire") * fireZoneMult,
                        run = function()
                            ReserveForChar(litFire.u, 60000)
                            CreateWarmingSequence(char, litFire.u)
                        end
                    })
                end
            end

            -- 9. Social Chat & World Party Banter (Lively in Camp & Towns, hushed in quiet ruins, off in Red Danger!)
            if Config.SocialPets and now > NextSocialTime and not inDanger then
                for _, other in ipairs(companions) do
                    if not SameEntity(other, char) and not SameEntity(other, host) and not ReservedTargets[other] then
                        local oq = ActiveQueues[other]
                        local otherCalm = (not oq or not oq.isProcessing
                            or oq.activityTag == "fire"
                            or oq.activityTag == "idle_anim"
                            or oq.activityTag == "chair"
                            or oq.activityTag == "ground_rest")
                        local dOther = Osi.GetDistanceTo(char, other)
                        local dOtherHost = Osi.GetDistanceTo(host, other)
                        if otherCalm and Osi.IsMoving(other) == 0 and dOther and dOther <= 11.5 and dOther >= 1.2 and dOtherHost and dOtherHost <= searchRadius then
                            -- Prefer pairing Origin companions for authentic acted banter!
                            local originPairBoost = (AnimSystem.isOriginCompanion(char) and AnimSystem.isOriginCompanion(other)) and 1.35 or 0.70
                            local socialZoneMult = inCamp and 1.85 or (zone.isRelaxed and 1.35 or (isDungeon and 0.60 or 1.10))
                            local nextSocialCd = inCamp and 22000 or 30000
                            table.insert(candidates, {
                                weight = 14.5 * GetTraitWeight(char, "social") * socialZoneMult * originPairBoost,
                                run = function()
                                    ReserveForChar(other, 60000)
                                    NextSocialTime = now + nextSocialCd
                                    CreateSocialChatSequence(char, other)
                                end
                            })
                            break
                        end
                    end
                end
            end

            -- 10. Context-Aware Personal Idle Animation (Alert stances in Dungeons, relaxed in Camp/Towns)
            if Config.AnimFrequency > 0 and not carryingFieldTorch then
                table.insert(candidates, {
                    weight = 24.0 * Config.AnimFrequency,
                    run = function()
                        ReserveForChar(nil, nil)
                        CreateIdleAnimationSequence(char, zone)
                    end
                })
            end

            -- 11. Perimeter Watch / Landmark Patrol (Signature in Dungeons for Lae'zel, Karlach, Minthara, Jaheira, Minsc!)
            local perimBoost = isDungeon and (1.55 * GetTraitWeight(char, "perimeter")) or GetTraitWeight(char, "perimeter")
            if #targets.wander > 0 then
                local landmark = FindFirstValid(targets.wander, 2.5, nil)
                if landmark then
                    table.insert(candidates, {
                        weight = 7.0 * perimBoost,
                        run = function()
                            ReserveForChar(landmark.u, 45000)
                            CreateWanderSequence(char, landmark.u)
                        end
                    })
                end
            end

            table.insert(candidates, {
                weight = 3.5 * (isDungeon and math.max(1.0, GetTraitWeight(char, "perimeter") * 0.75) or 1.0),
                run = function()
                    ReserveForChar(nil, nil)
                    CreateRandomWalkSequence(char, host)
                end
            })

            local chosen = PickWeightedOption(candidates)
            if chosen then
                ScavengeStreak[charKey] = 0 -- Reset scavenge streak after any roleplay/ambient activity!
                chosen.run()
            end
        end
        end
    end
end)

-- ============================================================================
-- 9B. REACTIVE COMPANION VOICES (SAFE _PAD_ / _VB_ BARK REDIRECTION)
-- ============================================================================

local QUARANTINED_BARK_TOKENS = {
    "GLO_", "_GLO",
    "WRLD_", "_WRLD",
    "ORI_", "_ORI",
    "CAMP_", "_CAMP",
    "DARKURGE", "DARK_URGE", "DURGE", "_DU_",
    "TADPOLE", "ILLITHID", "DREAMVISITOR", "EMPEROR",
    "DIG_", "_DIG", "DIGGING", "SHOVEL", "BURIED",
    "LOWHP", "LOW_HP", "LOWHEALTH", "ENCUMBER", "INVENTORYFULL",
    "LOCKPICK", "TRAPDISARM", "NO_SPACE", "CINE_", "_CINE", "COMBAT",
}

local function IsSafeExplorationBarkResource(resource)
    if type(resource) ~= "string" or resource == "" then return false end
    local u = string.upper(resource)

    -- Must be an exploration Point-And-Discover (_PAD_) or Voice Bark (_VB_) resource
    local isPadOrVb = string.find(u, "_PAD_", 1, true) ~= nil
        or string.sub(u, 1, 4) == "PAD_"
        or string.sub(u, -4) == "_PAD"
        or string.find(u, "_VB_", 1, true) ~= nil
        or string.sub(u, 1, 3) == "VB_"
        or string.sub(u, -3) == "_VB"
    if not isPadOrVb then return false end

    -- Quarantine global story, Origin-personal, Dark Urge, Guardian, digging, and status barks
    for i = 1, #QUARANTINED_BARK_TOKENS do
        if string.find(u, QUARANTINED_BARK_TOKENS[i], 1, true) ~= nil then
            return false
        end
    end
    return true
end

local function GetAvatarBarkSpeaker(resource, instanceId, host)
    if not host or not instanceId then return nil end

    -- Must be a strictly 1-player monologue bark (never touch 2+ speaker banters!)
    local okP, numPlayers = pcall(Osi.DialogGetNumberOfInvolvedPlayers, instanceId)
    if not okP or numPlayers ~= 1 then return nil end

    -- Must involve 0 NPCs/statues/corpses/narrators
    if Osi.DialogGetNumberOfInvolvedNPCs then
        local okN, numNpcs = pcall(Osi.DialogGetNumberOfInvolvedNPCs, instanceId)
        if okN and type(numNpcs) == "number" and numNpcs > 0 then
            return nil
        end
    end

    local speaker = nil
    if Osi.DialogGetInvolvedPlayer then
        local okS, sp = pcall(Osi.DialogGetInvolvedPlayer, instanceId, 1)
        if okS and type(sp) == "string" and sp ~= "" and not string.find(sp, "00000000-0000-0000-0000-000000000000", 1, true) then
            speaker = sp
        end
    end
    if not speaker and Osi.SpeakerGetDialog then
        local okD, dlg = pcall(Osi.SpeakerGetDialog, host, 1)
        if okD and dlg == resource then
            speaker = host
        end
    end
    if not speaker then return nil end

    -- Only redirect when the controlled Avatar triggered the bark (never steal a companion's own bark!)
    if not SameEntity(speaker, host) then return nil end
    local okTag, isAvatar = pcall(Osi.IsTagged, speaker, AVATAR_TAG)
    if not okTag or isAvatar ~= 1 then return nil end

    return speaker
end

local function BuildWeightedVoiceCandidates(speaker, companions)
    local speakerInCamp = IsInCamp(speaker)
    local maxVoiceDist = math.max(14.0, tonumber(Config.SearchRadius) or 12.0)
    local weighted = {}

    for _, comp in ipairs(companions) do
        local clean = CleanUuid(comp)
        if clean
            and not SameEntity(comp, speaker)
            and ORIGIN_COMPANION_SET[clean] == true
            and not string.find(tostring(comp), "Hireling", 1, true)
        then
            local ok, eligibleWeight = pcall(function()
                if Osi.IsControlled(comp) == 1 then return nil end
                if Osi.IsInCombat(comp) == 1 then return nil end
                if IsPolymorphedOrIncapacitated(comp) then return nil end
                if IsSneakingOrInvisible(comp) then return nil end
                if Osi.HasActiveStatus(comp, "SILENCED") == 1 then return nil end
                if IsCharacterInDialog(comp) or IsCharacterSpeakingBark(comp) then return nil end
                if IsInCamp(comp) ~= speakerInCamp then return nil end

                local dist = Osi.GetDistanceTo(speaker, comp)
                if not dist or dist > maxVoiceDist then return nil end

                local baseW = 0.5 * GetTraitWeight(comp, "curiosity") + 0.5 * GetTraitWeight(comp, "social")
                local proxW = 1.0 + math.max(0.0, (maxVoiceDist - dist) / 40.0)
                local w = math.max(0.15, baseW * proxW)
                if clean == LastVoiceSpeaker then
                    w = w * 0.35 -- rotate voices naturally across the party
                end
                return w
            end)

            if ok and eligibleWeight and eligibleWeight > 0 then
                table.insert(weighted, { char = comp, weight = eligibleWeight })
            end
        end
    end

    -- Weighted permutation without replacement so fallback tries #1 -> #2 -> #3
    local ordered = {}
    while #weighted > 0 do
        local picked = PickWeightedOption(weighted)
        if not picked then break end
        table.insert(ordered, picked.char)
        for i = #weighted, 1, -1 do
            if weighted[i] == picked then
                table.remove(weighted, i)
                break
            end
        end
    end
    return ordered
end

local function TryRedirectExplorationBark(resource, instanceId)
    if not IsOsirisReady() then return end
    if not Config.ReactiveVoices then return end

    local share = tonumber(Config.VoiceShare) or 80
    if share <= 0 then return end

    local now = Ext.Utils.MonotonicTime()
    local cleanRes = CleanUuid(resource)
    if now < ActionVoiceStats.ownDialogWindowUntil
        or (RedirectGuard[resource] or 0) > now
        or (cleanRes and (RedirectGuard[cleanRes] or 0) > now)
    then
        return
    end

    if not IsSafeExplorationBarkResource(resource) then
        return
    end

    if IsAnyDialogActive() then
        return
    end

    local host = Osi.GetHostCharacter and Osi.GetHostCharacter() or nil
    if not host then return end

    local companions = GetPartyCompanions()
    if #companions <= 1 then return end
    if not IsAmbientEnabled(host, companions) then return end

    if Osi.IsInCombat(host) == 1 or IsSneakingOrInvisible(host) or IsInTurnBased(host) then
        return
    end

    local speaker = GetAvatarBarkSpeaker(resource, instanceId, host)
    if not speaker then return end

    -- Respect configured Companion Voice Share (%) before interrupting Avatar
    if share < 100 and math.random(1, 100) > share then
        Log("ReactiveVoice kept on Avatar by share roll (" .. tostring(resource) .. ")")
        return
    end

    local candidates = BuildWeightedVoiceCandidates(speaker, companions)
    if #candidates == 0 then
        return
    end

    -- Set timestamped re-entrancy guard BEFORE stopping/starting dialog
    RedirectGuard[resource] = now + 3000

    local stopped = false
    if Osi.DialogRequestStopForDialog then
        local okStop = pcall(Osi.DialogRequestStopForDialog, resource, speaker)
        stopped = okStop
    end
    if not stopped and Osi.DialogRequestStop then
        pcall(Osi.DialogRequestStop, speaker)
    end

    for _, cand in ipairs(candidates) do
        local q = ActiveQueues[cand]
        if q and q.isProcessing then
            q:abort("voice_bark")
        end

        local okStart, started = pcall(Osi.QRY_StartDialog_Fixed, resource, cand)
        if okStart and (started == true or started == 1) then
            local cleanCand = CleanUuid(cand)
            LastVoiceSpeaker = cleanCand
            GlobalReactiveBarkUntil = now + 5800
            if cleanCand then
                VoiceBusyUntil[cleanCand] = now + 5500
            end
            VoiceRedirectCount = VoiceRedirectCount + 1
            if Osi.IsMoving(cand) == 0 then
                FaceTarget(cand, speaker)
            end
            Log(string.format(
                "ReactiveVoice redirected [%s] -> %s (session total=%d)",
                tostring(resource),
                tostring(cand),
                VoiceRedirectCount
            ))
            return
        end
    end

    -- Zero-silence safety net: no companion had a voiced branch for this trigger; restore on Avatar!
    pcall(Osi.QRY_StartDialog_Fixed, resource, speaker)
    VoiceFallbackCount = VoiceFallbackCount + 1
    Log(string.format(
        "ReactiveVoice: no companion branch for [%s]; restored on Avatar (fallbacks=%d)",
        tostring(resource),
        VoiceFallbackCount
    ))
end

-- ============================================================================
-- 10. EVENT LISTENERS (GAME STATE LIFECYCLE & OSIRIS EVENTS)
-- ============================================================================

local function ResetSessionTransientState()
    AbortAllQueues("level_reset")
    ActiveDialogs = {}
    ForceTurnBasedObjects = {}
    ActivePerformers = {}
    ReservedTargets = {}
    Blacklist = {}
    RedirectGuard = {}
    VoiceBusyUntil = {}
    GlobalReactiveBarkUntil = 0
    NextGlobalActionVoiceTime = 0
    GlobalActionVoiceBusyUntil = 0
    ActionVoiceStats.ownDialogWindowUntil = 0
    ActionVoiceStats.nextWorldGossipTime = 0
    ActionVoiceStats.nextImportantTime = 0
    ActionVoiceStats.lastVoiceAt = 0
    ActionVoiceStats.spokenPadCooldown = {}
    CompanionActionVoiceCooldown = {}
    LastActionVoiceSpeaker = nil
    KnownDiscoveredTraps = {}
    AlertedObjects = {}
    CompanionWakeOffsets = {}
    WakeOffsetsStopStamp = -1
    CompanionRestUntil = {}
    ScavengeStreak = {}
    NeedsInitialPartyUnstick = true
    HostWasIdleAllowed = false
    CompanionLagSince = {}
    CompanionUnstickCooldown = {}
    LocalSpatialIndex = {
        ready         = false,
        sweeping      = false,
        phase         = "items",
        handles       = nil,
        cursor        = 1,
        total         = 0,
        hx            = 0,
        hy            = 0,
        hz            = 0,
        sweepItems    = {},
        sweepTraps    = {},
        sweepChars    = {},
        items         = {},
        traps         = {},
        chars         = {},
        corpses       = {},
        pets          = {},
        enemyNearby   = false,
        enemyCoords   = {},
        lastCompleted = -999999,
        lastPetScan   = -999999,
    }
    PendingAutoWashTime = 0
    ScavengeStats.pendingBreatherTime = 0
    ScavengeStats.litSet = {}
    ScavengeStats.quietNextWash = false
    FieldTorchSystem.internalEquipGuard = false
    FieldTorchSystem.lastEnvCheckAt = -999999
    FieldTorchSystem.lastEnemyCheckAt = -999999
    FieldTorchSystem.cachedEnemyNear = false
    FieldTorchSystem.darkSince = 0
    FieldTorchSystem.brightSince = 0
    FieldTorchSystem.cooldownUntil = 0
    FieldTorchSystem.lastStatusReason = "idle"
    FieldTorchSystem.lastHostObs = "unknown"
    FieldTorchSystem.lastLitLights = 0
    CurrentReader = nil
    InitializedForHost = nil
    WorldScanCache.targets = nil
    WorldScanCache.timestamp = 0
    StateChecks.resetIdleAnchor()
    HostLastPos = { x = nil, y = nil, z = nil }
    HostLastActiveTime = Ext.Utils.MonotonicTime()
    SuppressPopupUntil = HostLastActiveTime + 5000
    -- Build 04.3.3: fixtures lit by us in a previous session are re-armed a few seconds
    -- after the level/save finished loading (fixes "old saves stay dark").
    AmbientLightRepair.scheduleRearm(6000)
end

local OsirisListenersRegistered = false

local function RegisterOsirisListeners()
    if OsirisListenersRegistered then return end
    OsirisListenersRegistered = true

    Ext.Osiris.RegisterListener("LevelGameplayStarted", 2, "after", function(_levelName, _isEditorMode)
        IsServerRunning = true
        ResetSessionTransientState()
        SyncAllMCMSettings(true)
    end)

    Ext.Osiris.RegisterListener("SavegameLoaded", 0, "after", function()
        ResetSessionTransientState()
        SyncAllMCMSettings(true)
    end)

    Ext.Osiris.RegisterListener("StatusApplied", 4, "after", function(objectUuid, status, _causee, _storyActionID)
        if status == "AMBIENT_AI_STATUS" then
            UserExplicitlyToggledOff = false
            StateChecks.resetIdleAnchor()
            HostLastActiveTime = Ext.Utils.MonotonicTime()
            if IsOsirisReady() and Ext.Utils.MonotonicTime() > SuppressPopupUntil then
                Log("Hotbar toggle switched ON on " .. tostring(objectUuid))
                SafeSay(objectUuid, GetLocalizedText(LOCA_HANDLES.StatusOn, "Ambient AI: ON"))
            end
        elseif status == "SNEAKING" or status == "INVISIBILITY" or status == "DOWNED" then
            StateChecks.resetIdleAnchor()
            if IsOsirisReady() then
                AbortAllQueues("stealth_or_downed")
                local host = Osi.GetHostCharacter and Osi.GetHostCharacter() or nil
                if (host and SameEntity(objectUuid, host)) or IsRealPartyCompanion(objectUuid) then
                    if not FieldTorchSystem.isShadowCurseActive(host, GetPartyCompanions()) then
                        FieldTorchSystem.cooldownUntil = Ext.Utils.MonotonicTime() + 4000
                        FieldTorchSystem.restoreAll("stealth_or_downed", false)
                    end
                end
            end
        elseif IsMusicStatus(status) and objectUuid then
            ActivePerformers[objectUuid] = (ActivePerformers[objectUuid] or 0) + 1
            if IsOsirisReady() then
                Log("Bard performance detected on " .. tostring(objectUuid) .. " (" .. tostring(status) .. ")")
            end
        end
    end)

    Ext.Osiris.RegisterListener("StatusRemoved", 4, "after", function(objectUuid, status, _causee, _storyActionID)
        if status == "AMBIENT_AI_STATUS" then
            if IsOsirisReady() then
                UserExplicitlyToggledOff = true
                StateChecks.resetIdleAnchor()
                AbortAllQueues("toggled_off")
                FieldTorchSystem.restoreAll("toggled_off", false)
                Log("Hotbar toggle switched OFF on " .. tostring(objectUuid))
                if Ext.Utils.MonotonicTime() > SuppressPopupUntil then
                    SafeSay(objectUuid, GetLocalizedText(LOCA_HANDLES.StatusOff, "Ambient AI: OFF"))
                end
            end
        elseif IsMusicStatus(status) and objectUuid and ActivePerformers[objectUuid] then
            ActivePerformers[objectUuid] = ActivePerformers[objectUuid] - 1
            if ActivePerformers[objectUuid] <= 0 then
                ActivePerformers[objectUuid] = nil
            end
        end
    end)

    -- Build 04.3.5: authoritative dismount confirmation. Until this fires the companion
    -- keeps the follow block, so BG3 never catch-up-teleports them off a chair/bed.
    Ext.Osiris.RegisterListener("ReposeRemoved", 2, "after", function(character, _onEntity)
        if not IsOsirisReady() then return end
        if character then AmbientSeat.onReposeRemoved(character) end
    end)

    Ext.Osiris.RegisterListener("DialogStarted", 2, "after", function(_dialog, instance)
        if not IsOsirisReady() then return end
        local involvesParty = true
        if Osi.DialogGetNumberOfInvolvedPlayers then
            local okP, nPlayers = pcall(Osi.DialogGetNumberOfInvolvedPlayers, instance)
            if okP and type(nPlayers) == "number" then
                involvesParty = (nPlayers >= 1)
            end
        end
        if involvesParty then
            ActiveDialogs[instance] = Ext.Utils.MonotonicTime()
            AbortAllQueues("dialog")
            local host = Osi.GetHostCharacter and Osi.GetHostCharacter() or nil
            if not FieldTorchSystem.isShadowCurseActive(host, GetPartyCompanions()) then
                FieldTorchSystem.restoreAll("dialog", false)
            end
        end
    end)

    Ext.Osiris.RegisterListener("DialogEnded", 2, "after", function(_dialog, instance)
        ActiveDialogs[instance] = nil
        StateChecks.resetIdleAnchor()
        HostLastActiveTime = Ext.Utils.MonotonicTime()
    end)

    Ext.Osiris.RegisterListener("AutomatedDialogStarted", 2, "before", function(resource, instanceId)
        if not IsOsirisReady() then return end
        local now = Ext.Utils.MonotonicTime()
        -- CRITICAL: AutomatedDialogStarted fires for EVERY background NPC / creature / BHVR_WRLD
        -- dialog across the loaded region! Only set GlobalReactiveBarkUntil when a party member
        -- is actually participating AND outside AmbientAI's own PAD/banter launch window!
        local involvesParty = false
        if Osi.DialogGetNumberOfInvolvedPlayers then
            local okP, nPlayers = pcall(Osi.DialogGetNumberOfInvolvedPlayers, instanceId)
            if okP and type(nPlayers) == "number" and nPlayers >= 1 then
                involvesParty = true
            end
        end
        if involvesParty and now >= ActionVoiceStats.ownDialogWindowUntil then
            GlobalReactiveBarkUntil = math.max(GlobalReactiveBarkUntil, now + 5200)
        end
        TryRedirectExplorationBark(resource, instanceId)
    end)

    Ext.Osiris.RegisterListener("CombatStarted", 1, "after", function(_combatGuid)
        PendingAutoWashTime = 0
        ScavengeStats.pendingBreatherTime = 0
        ScavengeStats.quietNextWash = false
        if IsOsirisReady() then
            FieldTorchSystem.restoreAll("combat_started", true)
            AbortAllQueues("combat")
        end
    end)

    Ext.Osiris.RegisterListener("EnteredCombat", 2, "after", function(_object, _combatGuid)
        PendingAutoWashTime = 0
        ScavengeStats.pendingBreatherTime = 0
        ScavengeStats.quietNextWash = false
        if IsOsirisReady() then
            FieldTorchSystem.restoreAll("entered_combat", true)
            AbortAllQueues("combat")
        end
    end)

    Ext.Osiris.RegisterListener("CombatEnded", 1, "after", function(_combatGuid)
        if IsOsirisReady() then
            local now = Ext.Utils.MonotonicTime()
            if Config.PostCombatBreather then
                ScavengeStats.pendingBreatherTime = now + 4800
            end
            if Config.AutoWash then
                PendingAutoWashTime = now + 8800
            end
        end
    end)

    Ext.Osiris.RegisterListener("RollResult", 6, "after", function(_eventName, roller, rollSubject, resultType, _isActiveRoll, _criticality)
        if not IsOsirisReady() or not Config.TrapReflex then return end
        if resultType ~= 1 or not rollSubject or not roller then return end
        local okTrap, isArmed = pcall(function()
            if Osi.IsTrapArmed and Osi.IsTrapArmed(rollSubject) == 1 then return true end
            if Osi.IsTrap and Osi.IsTrap(rollSubject) == 1 then return true end
            return false
        end)
        if not okTrap or not isArmed then return end

        local host = Osi.GetHostCharacter and Osi.GetHostCharacter() or nil
        if (host and SameEntity(roller, host)) or IsRealPartyCompanion(roller) then
            if not host or IsAmbientEnabled(host) then
                EmergencyBrakeParty(roller, rollSubject)
            end
        end
    end)

    Ext.Osiris.RegisterListener("RequestTrade", 4, "after", function(character, trader, _tradeMode, _itemsTagFilter)
        if not IsOsirisReady() or not Config.AutoSellTrader then return end
        if not character or not trader then return end
        Ext.Timer.WaitFor(350, function()
            if IsOsirisReady() then
                ExecuteAutoSellAtTrader(character, trader)
            end
        end)
    end)

    Ext.Osiris.RegisterListener("EnteredForceTurnBased", 1, "after", function(objectUuid)
        if objectUuid then
            ForceTurnBasedObjects[objectUuid] = true
            ForceTurnBasedObjects[CleanUuid(objectUuid)] = true
        end
        if IsOsirisReady() then
            FieldTorchSystem.restoreAll("turn_based", true)
            AbortAllQueues("turn_based")
        end
    end)

    Ext.Osiris.RegisterListener("LeftForceTurnBased", 1, "after", function(objectUuid)
        if objectUuid then
            ForceTurnBasedObjects[objectUuid] = nil
            ForceTurnBasedObjects[CleanUuid(objectUuid)] = nil
        end
        StateChecks.resetIdleAnchor()
        HostLastActiveTime = Ext.Utils.MonotonicTime()
    end)

    Ext.Osiris.RegisterListener("Equipped", 2, "after", function(item, character)
        if not IsOsirisReady() then return end
        FieldTorchSystem.onItemEquipped(item, character)
    end)
end

if Ext and Ext.Events then
    if Ext.Events.GameStateChanged then
        Ext.Events.GameStateChanged:Subscribe(function(e)
            local toState = e and e.ToState ~= nil and tostring(e.ToState) or nil
            local fromState = e and e.FromState ~= nil and tostring(e.FromState) or nil

            if toState ~= nil then
                IsServerRunning = (toState == "Running")
            else
                RefreshRunningState()
            end

            if IsServerRunning then
                -- Fresh transition into live gameplay (e.g. Sync -> Running or Paused -> Running)
                StateChecks.resetIdleAnchor()
                HostLastActiveTime = Ext.Utils.MonotonicTime()
                if fromState == "Sync" or fromState == "LoadLevel" then
                    SuppressPopupUntil = HostLastActiveTime + 5000
                end
            elseif toState == "UnloadLevel" or toState == "UnloadSession" or toState == "LoadSession" or toState == "LoadLevel" then
                ResetSessionTransientState()
            end
        end)
    end

    if Ext.Events.ResetCompleted then
        Ext.Events.ResetCompleted:Subscribe(function()
            NeedsInitialPartyUnstick = true
            RefreshRunningState()
            SyncAllMCMSettings(true)
        end)
    end
end

-- Register Osiris event descriptors at bootstrap load (does NOT index Osi.*);
-- BG3SE binds them when StoryLoaded() runs, and callbacks themselves check IsOsirisReady().
RegisterOsirisListeners()

if Ext and Ext.RegisterConsoleCommand then
    Ext.RegisterConsoleCommand("ambient_status", function()
        if not IsOsirisReady() then
            Ext.Utils.Print("[AmbientAI] Server not in Running state yet.")
            return
        end
        local now = Ext.Utils.MonotonicTime()
        local host = Osi.GetHostCharacter and Osi.GetHostCharacter() or nil
        local comps = GetPartyCompanions()
        EnsureAutoSellStorage()
        local queuedLedgerCount = 0
        for _, _ in pairs(PersistentVars.AutoSellLedger) do
            queuedLedgerCount = queuedLedgerCount + 1
        end
        local groundAnims = GetGroundRestAnimations()
        local nearbySeats = (WorldScanCache.targets and WorldScanCache.targets.chairs and #WorldScanCache.targets.chairs) or 0
        local curZoneMode = (WorldScanCache.zone and WorldScanCache.zone.mode) or "SCANNING"
        local activeTorchBearer = FieldTorchSystem.getActiveBearerKey() or "none"
        local partyTorchCount = FieldTorchSystem.countPartyTorches(host, comps)
        Ext.Utils.Print(string.format(
            "[AmbientAI] === STATUS (v1.4.3.2) === Host=%s | Toggle=%s | Zone=%s | Party=%d | Idle=%.1fs/%ds | Anchor=%s (%.1fm) | FieldTorch=%s (bearer=%s, swaps=%d, why=%s, obs=%s, torches=%d, lit=%d) | LocalIdx=%d/%d/%d (seats=%d, groundAnims=%d) | LightsLit=%d | ReactiveVoices=%s (%d%%, %d) | ActionVoices=%s (cd=%ds, played=%d, gossips=%d, pads=%d, voc3d=%d, imp=%d, rep=%d, deleg=%d, breathers=%d) | Scavenger=%s (ess=%d, sup=%d, campSellQ=%d, sold=%d/%dg, alerts=%d) | TrapStops=%d | Washes=%d",
            tostring(host),
            tostring(IsAmbientEnabled(host, comps)),
            tostring(curZoneMode),
            #comps,
            (now - HostLastActiveTime) / 1000.0,
            tonumber(Config.GroupedIdleDelay) or 6,
            tostring(StateChecks.anchorActive),
            tonumber(Config.IdleAnchorRadius) or 3.5,
            tostring(Config.FieldTorch),
            tostring(activeTorchBearer),
            tonumber(FieldTorchSystem.swaps) or 0,
            tostring(FieldTorchSystem.lastStatusReason or "idle"),
            tostring(FieldTorchSystem.lastHostObs or "unknown"),
            partyTorchCount,
            tonumber(FieldTorchSystem.lastLitLights) or 0,
            #LocalSpatialIndex.items,
            #LocalSpatialIndex.traps,
            #(LocalSpatialIndex.chars or {}),
            nearbySeats,
            #groundAnims,
            ScavengeStats.lightsLit or 0,
            tostring(Config.ReactiveVoices),
            tonumber(Config.VoiceShare) or 80,
            VoiceRedirectCount,
            tostring(Config.ActionVoices),
            tonumber(Config.ActionVoiceCooldown) or 24,
            ActionVoiceStats.played,
            ActionVoiceStats.gossips,
            ActionVoiceStats.spokenPads,
            ActionVoiceStats.vocals3d,
            ActionVoiceStats.important,
            ActionVoiceStats.replies,
            ActionVoiceStats.originDelegations,
            ActionVoiceStats.breathers,
            tostring(Config.SmartScavenger),
            ScavengeStats.essentials,
            ScavengeStats.supplies,
            queuedLedgerCount,
            ScavengeStats.soldItems,
            ScavengeStats.soldGold,
            ScavengeStats.alerts,
            ScavengeStats.trapStops,
            ScavengeStats.washes
        ))
        for _, c in ipairs(comps) do
            local q = ActiveQueues[c]
            local cKey = CleanUuid(c)
            local seatLocked = (cKey and PersistentVars and PersistentVars.SeatFollowLocked and PersistentVars.SeatFollowLocked[cKey] == true) or false
            Ext.Utils.Print(string.format(
                "  -> %s | Grouped=%s | CanAct=%s | AutoTorch=%s | SeatLock=%s | Busy=%s (%s)",
                tostring(c),
                tostring(StateChecks.isGrouped(c, host)),
                tostring(StateChecks.canCompanionAct(c, host, now)),
                tostring(FieldTorchSystem.isCarryingAutoTorch(c)),
                tostring(seatLocked),
                tostring(q and q.isProcessing or false),
                tostring(q and q.currentAction and q.currentAction.name or "idle")
            ))
        end
    end)

    Ext.RegisterConsoleCommand("ambient_unstick", function()
        if not IsOsirisReady() then
            Ext.Utils.Print("[AmbientAI] Server not in Running state yet.")
            return
        end
        FieldTorchSystem.restoreAll("manual_unstick", false)
        AbortAllQueues("manual_unstick")
        local host = Osi.GetHostCharacter and Osi.GetHostCharacter() or nil
        local comps = GetPartyCompanions()
        local count = 0
        for _, c in ipairs(comps) do
            if not SameEntity(c, host) then
                if AmbientSeat.isSeated(c) then
                    AmbientSeat.standUp(c, "manual_unstick")
                else
                    SetAmbientSeatFollowLock(c, false)
                end
                StopCustomAnimation(c)
                PurgeCharacterOsiris(c)
                count = count + 1
            end
        end
        Ext.Utils.Print("[AmbientAI] Purged Osiris queues & custom animations on " .. tostring(count) .. " party companions.")
    end)

    Ext.RegisterConsoleCommand("ambient_testvoice", function(_cmd, categoryArg, targetArg)
        if not IsOsirisReady() then
            Ext.Utils.Print("[AmbientAI] Server not in Running state yet.")
            return
        end
        local host = Osi.GetHostCharacter and Osi.GetHostCharacter() or nil
        local comps = GetPartyCompanions()
        local nonHost = {}
        for _, c in ipairs(comps) do
            if not SameEntity(c, host) and Osi.IsDead(c) == 0 then
                nonHost[#nonHost + 1] = c
            end
        end
        local targetComp = nonHost[1] or host
        local secondComp = nonHost[2]
        if not targetComp then
            Ext.Utils.Print("[AmbientAI] No active companion found for voice test.")
            return
        end

        if categoryArg == "gossip" then
            local okGossip, dlgId = TryTriggerWorldPartyBanter(targetComp, secondComp, true)
            Ext.Utils.Print(string.format(
                "[AmbientAI] TestVoice WorldGossip on %s (%s) -> %s",
                tostring(targetComp),
                tostring(secondComp or "solo"),
                okGossip and ("STARTED: " .. tostring(dlgId)) or "NO_ELIGIBLE_BANTER_UNLOCKED_NOW"
            ))
            return
        end

        local cat = (type(categoryArg) == "string" and ACTION_VOICE_PROFILES[categoryArg]) and categoryArg or "social_init"
        local forcedTgt = (type(targetArg) == "string" and targetArg ~= "") and targetArg or nil
        local okVoice = TryPlayCompanionActionVoice(targetComp, cat, { force = true, debug = true, target = forcedTgt })
        Ext.Utils.Print(string.format(
            "[AmbientAI] TestVoice category='%s' target='%s' on %s -> %s",
            tostring(cat),
            tostring(forcedTgt or "auto"),
            tostring(targetComp),
            okVoice and "PLAYED" or "SUPPRESSED (check combat/stealth/dialog/ActionVoices)"
        ))
    end)

    Ext.RegisterConsoleCommand("ambient_voice", function()
        if not IsOsirisReady() then
            Ext.Utils.Print("[AmbientAI] Server not in Running state yet.")
            return
        end
        local now = Ext.Utils.MonotonicTime()
        local vc = AmbientVoice.context
        if not (vc and vc.Refresh) then
            Ext.Utils.Print("[AmbientAI] Voice context not initialised yet.")
            return
        end
        vc = vc.Refresh(now, true)
        Ext.Utils.Print(string.format(
            "[AmbientAI] === VOICE HEALTH === needsRest=%s (%s) | HP min=%d%% avg=%d%% low<=75:%d crit<=45:%d | slots=%s (%d/%d used, src=%s) | shortRests=%d",
            tostring(vc.needsRest),
            tostring(vc.reason),
            vc.minHp, vc.avgHp, vc.lowHp, vc.criticalHp,
            vc.slotsKnown and "known" or "unknown",
            vc.slotsUsed, vc.slotsMax, tostring(vc.slotsSrc),
            vc.restsLeft
        ))
        Ext.Utils.Print(string.format(
            "  -> pads: played=%d failed=%d | grunt-only lines=%d (a grunt is not speech - high numbers here mean the party is quieter than it looks)",
            ActionVoiceStats.spokenPads, ActionVoiceStats.padFail or 0, ActionVoiceStats.vocalOnly or 0))
        Ext.Utils.Print(string.format(
            "  -> action voices=%s | played=%d pads=%d voc3d=%d gossips=%d breathers=%d | silent for %.1fs | next line in %.1fs",
            tostring(Config.ActionVoices),
            ActionVoiceStats.played, ActionVoiceStats.spokenPads, ActionVoiceStats.vocals3d,
            ActionVoiceStats.gossips, ActionVoiceStats.breathers,
            (now - (ActionVoiceStats.lastVoiceAt or 0)) / 1000.0,
            math.max(0, (NextGlobalActionVoiceTime - now) / 1000.0)
        ))
        Ext.Utils.Print(string.format(
            "  -> queue ticks: slow(>120ms)=%d worst=%dms in %s",
            (ActionQueue.stats and ActionQueue.stats.slow) or 0,
            (ActionQueue.stats and ActionQueue.stats.worst) or 0,
            tostring(ActionQueue.stats and ActionQueue.stats.worstPhase or "-")))
    Ext.Utils.Print(string.format(
            "  -> rest-reminder lines: %s | last speaker=%s",
            vc.needsRest and "ALLOWED (party looks tired - soft reminder)"
                or "SUPPRESSED (party at full health and full spell slots)",
            tostring(LastActionVoiceSpeaker or "none")
        ))
        Ext.Utils.Print("  -> if slots say 'unknown', the tired-line gate falls back to HP only.")
    end)

    Ext.RegisterConsoleCommand("ambient_anims", function()
        local pool = GetGroundRestAnimations()
        Ext.Utils.Print("[AmbientAI] Ground-Rest Animation Pool (" .. tostring(#pool) .. " entries):")
        for idx, anim in ipairs(pool) do
            Ext.Utils.Print(string.format("  [%d] %s", idx, tostring(anim)))
        end
    end)
end

-- ============================================================================
-- 10B. ANIMATION RESOURCE DIAGNOSTICS (Build 04.3.16)
--   Why: the writing idle brings its props (book, quill) only when played as a full
--   Start / Loop / End triplet, and those resource names live in the game data.
--   The 04.3.15 sweep of the 101k-entry Animation bank matched nothing, so this build
--   first reports the *shape* of the bank (field names, nil rate) before scanning again.
-- ============================================================================
AnimProbe = AnimProbe or {
    types = { "Animation", "AnimationSet", "AnimationSetOverride", "VirtualAnimation", "BlendSpace" },
    running = false,
}

local ANIM_DEFAULT_LOOP_UUID = "896b83fb-27c3-41e0-924c-7ebf8473154b"

local function ProbePrint(fmt, ...)
    if not (Ext and Ext.Utils and Ext.Utils.Print) then return end
    if select("#", ...) > 0 then
        Ext.Utils.Print(string.format(fmt, ...))
    else
        Ext.Utils.Print(tostring(fmt))
    end
end

local function ResourceFields(res, limit)
    local parts = {}
    if type(res) ~= "table" then return nil end
    for k, v in pairs(res) do
        local tv = type(v)
        local shown
        if tv == "string" then
            shown = v
        elseif tv == "number" or tv == "boolean" then
            shown = tostring(v)
        else
            shown = "<" .. tv .. ">"
        end
        if #shown > 96 then shown = shown:sub(1, 96) .. "..." end
        parts[#parts + 1] = tostring(k) .. "=" .. shown
        if #parts >= (limit or 16) then break end
    end
    return table.concat(parts, " | ")
end

-- Collect every string value of a resource (names may hide in any field)
local function ResourceStrings(res, into)
    if type(res) ~= "table" then return into end
    for k, v in pairs(res) do
        if type(v) == "string" then
            into[#into + 1] = tostring(k) .. "=" .. v
        end
    end
    return into
end

local function TryGet(guid, bankType)
    if not (Ext and Ext.Resource and Ext.Resource.Get) then return nil end
    local ok, res = pcall(Ext.Resource.Get, guid, bankType)
    if ok and type(res) == "table" then return res end
    return nil
end

function AnimProbe.fields(typeArg)
    local bankType = typeArg or "Animation"
    local ok, list = pcall(Ext.Resource.GetAll, bankType)
    if not ok or type(list) ~= "table" or #list == 0 then
        ProbePrint("[AmbientAI] getAll(%s) returned nothing - try another type (AnimationSet, Visual ...)", bankType)
        return
    end
    ProbePrint("[AmbientAI] %s bank: %d entries. Shape of the first 5:", bankType, #list)
    for idx = 1, math.min(5, #list) do
        local res = TryGet(list[idx], bankType)
        ProbePrint("  [%d] guid=%s -> %s", idx, tostring(list[idx]),
            ResourceFields(res, 18) or "Ext.Resource.Get returned nil")
    end
    ProbePrint("  (counters below come from !ambient_anim_find)")
end

function AnimProbe.probe(guidArg)
    local guid = guidArg
    if not guid or guid == "" then guid = ANIM_DEFAULT_LOOP_UUID end
    ProbePrint("[AmbientAI] probing resource %s", tostring(guid))
    local foundAny = false
    for _, bankType in ipairs(AnimProbe.types) do
        local res = TryGet(guid, bankType)
        if res then
            foundAny = true
            ProbePrint("  [%s] %s", bankType, ResourceFields(res, 24) or "<empty>")
        end
    end
    if not foundAny then
        ProbePrint("  no type returned a resource for this GUID.")
        ProbePrint("  (a bare GUID may need the full resource name 'Name_guid'; try !ambient_anim_fields)")
    end
end

function AnimProbe.sets(needleArg)
    local needle = string.lower(needleArg or "writing")
    local ok, list = pcall(Ext.Resource.GetAll, "AnimationSet")
    if not ok or type(list) ~= "table" or #list == 0 then
        ProbePrint("[AmbientAI] AnimationSet bank is empty in this SE build.")
        return
    end
    ProbePrint("[AmbientAI] scanning %d AnimationSet resource(s) for '%s' ...", #list, needle)
    local hits, nilCount, namedCount = 0, 0, 0
    for idx = 1, #list do
        local guid = list[idx]
        local res = TryGet(guid, "AnimationSet")
        if not res then
            nilCount = nilCount + 1
        else
            local strings = ResourceStrings(res, {})
            if #strings > 0 then namedCount = namedCount + 1 end
            local joined = string.lower(table.concat(strings, "|"))
            if string.find(joined, needle, 1, true) then
                hits = hits + 1
                if hits <= 40 then
                    ProbePrint("  [set %d] %s :: %s", hits, tostring(guid), table.concat(strings, " | "))
                end
            end
        end
    end
    ProbePrint("[AmbientAI] AnimationSet scan done: hits=%d, readable=%d, nil=%d of %d",
        hits, namedCount, nilCount, #list)
end

function AnimProbe.guess(baseArg)
    local host = Osi.GetHostCharacter and Osi.GetHostCharacter() or nil
    if not host then
        ProbePrint("[AmbientAI] no host character.")
        return
    end
    local base = baseArg or "CUST_Writing_02"
    local uuid = ANIM_DEFAULT_LOOP_UUID
    local startName = base .. "_Start_" .. uuid
    local loopName = base .. "_Loop_" .. uuid
    local endName = base .. "_End_" .. uuid
    if loopName ~= (base .. "_Loop_" .. uuid) then return end
    ProbePrint("[AmbientAI] trying the naming convention on the host:")
    ProbePrint("  start=%s", startName)
    ProbePrint("  loop =%s", loopName)
    ProbePrint("  end  =%s", endName)
    if Osi.PlayLoopingAnimation then
        pcall(Osi.PlayLoopingAnimation, host, startName, loopName, endName, "", "", "", "")
    end
    ProbePrint("  look at the host: do the book and quill appear in his hands? (~9 s)")
    if Ext.Timer and Ext.Timer.WaitFor then
        Ext.Timer.WaitFor(9000, function()
            pcall(function() Osi.StopAnimation(host, 0) end)
            ProbePrint("[AmbientAI] animation guess finished.")
        end)
    end
end

-- ---------------------------------------------------------------- time-budgeted scan
AnimProbe.scan = AnimProbe.scan or {
    cursor = 1, handles = nil, bankType = nil, needle = "", matches = {},
    nilCount = 0, namedCount = 0, sample = nil, startedAt = 0, lastReport = 0,
}

function AnimProbe.stop(quiet)
    AnimProbe.running = false
    if not quiet then ProbePrint("[AmbientAI] animation scan stopped.") end
end

local function ScanSlice()
    if not AnimProbe.running then return end
    local scan = AnimProbe.scan
    local now = Ext.Utils.MonotonicTime()
    local sliceStart = now

    local processed = 0
    while scan.cursor <= #scan.handles do
        local guid = scan.handles[scan.cursor]
        scan.cursor = scan.cursor + 1
        processed = processed + 1
        local res = TryGet(guid, scan.bankType)
        if not res then
            scan.nilCount = scan.nilCount + 1
        else
            local strings = ResourceStrings(res, {})
            if #strings > 0 then
                scan.namedCount = scan.namedCount + 1
                if not scan.sample then scan.sample = strings end
                local joined = string.lower(table.concat(strings, "|"))
                if string.find(joined, scan.needle, 1, true) then
                    scan.matches[#scan.matches + 1] = {
                        guid = tostring(guid),
                        fields = table.concat(strings, " | "),
                    }
                end
            end
        end
        -- 6 ms of work per slice keeps a single callback well under the SE warn threshold
        if processed % 50 == 0 and (Ext.Utils.MonotonicTime() - sliceStart) > 6 then break end
    end

    local elapsed = now - scan.startedAt
    if now - scan.lastReport > 10000 then
        scan.lastReport = now
        ProbePrint("[AmbientAI] scan progress: %d/%d | readable=%d nil=%d matches=%d | %.0fs",
            scan.cursor - 1, #scan.handles, scan.namedCount, scan.nilCount, #scan.matches, elapsed / 1000)
    end

    if scan.cursor > #scan.handles then
        AnimProbe.running = false
        ProbePrint("[AmbientAI] scan complete: %d entries, readable=%d nil=%d matches=%d (%.1fs)",
            #scan.handles, scan.namedCount, scan.nilCount, #scan.matches, elapsed / 1000)
        if scan.sample then
            ProbePrint("  first readable resource: %s", table.concat(scan.sample, " | "))
        else
            ProbePrint("  NOTHING in this bank has a readable string field - names are not")
            ProbePrint("  exposed for %s resources; use !ambient_anim_sets instead.", tostring(scan.bankType))
        end
        for idx = 1, math.min(#scan.matches, 40) do
            local m = scan.matches[idx]
            ProbePrint("  [match %d] %s :: %s", idx, m.guid, m.fields)
        end
        return
    end

    if elapsed > 240000 then
        AnimProbe.running = false
        ProbePrint("[AmbientAI] scan stopped after 240 s (partial). Raise the needle or use AnimationSet.")
        return
    end

    if Ext.Timer and Ext.Timer.WaitFor then
        Ext.Timer.WaitFor(30, ScanSlice)
    else
        AnimProbe.running = false
    end
end

function AnimProbe.find(needleArg, typeArg)
    if AnimProbe.running then
        ProbePrint("[AmbientAI] a scan is already running - !ambient_anim_stop first.")
        return
    end
    local bankType = typeArg or "Animation"
    local ok, list = pcall(Ext.Resource.GetAll, bankType)
    if not ok or type(list) ~= "table" or #list == 0 then
        ProbePrint("[AmbientAI] getAll(%s) returned nothing.", bankType)
        return
    end
    local scan = AnimProbe.scan
    scan.cursor, scan.handles, scan.bankType = 1, list, bankType
    scan.needle = string.lower(needleArg or "writing")
    scan.matches, scan.nilCount, scan.namedCount, scan.sample = {}, 0, 0, nil
    scan.startedAt = Ext.Utils.MonotonicTime()
    scan.lastReport = scan.startedAt
    AnimProbe.running = true
    ProbePrint("[AmbientAI] scanning %d %s resource(s) for '%s' (6 ms slices, !ambient_anim_stop to cancel)",
        #list, bankType, scan.needle)
    ScanSlice()
end

if Ext and Ext.RegisterConsoleCommand then
    Ext.RegisterConsoleCommand("ambient_anim_fields", function(_cmd, typeArg)
        AnimProbe.fields(typeArg)
    end)
    Ext.RegisterConsoleCommand("ambient_anim_probe", function(_cmd, guidArg)
        AnimProbe.probe(guidArg)
    end)
    Ext.RegisterConsoleCommand("ambient_anim_sets", function(_cmd, needleArg)
        AnimProbe.sets(needleArg)
    end)
    Ext.RegisterConsoleCommand("ambient_anim_find", function(_cmd, needleArg, typeArg)
        AnimProbe.find(needleArg, typeArg)
    end)
    Ext.RegisterConsoleCommand("ambient_anim_stop", function()
        AnimProbe.stop(false)
    end)
    Ext.RegisterConsoleCommand("ambient_anim_guess", function(_cmd, baseArg)
        AnimProbe.guess(baseArg)
    end)
    -- 04.3.15 names kept as aliases so older notes keep working
    Ext.RegisterConsoleCommand("ambient_anim_test", function(_cmd, baseArg)
        AnimProbe.guess(baseArg)
    end)
end

-- ============================================================================
-- 10C. ANIMATION A/B TEST (Build 04.3.17)
--   Field report: CUST_Writing_02_Loop (played bare) shows quill + book, while
--   CUST_Reading_Old_Tome_01 (played as a Start/Loop/End triplet) shows nothing.
--   So let the host play the same clip both ways and look at his hands.
-- ============================================================================
AnimPlayTest = AnimPlayTest or {}

local ANIM_PLAY_KEYS = {
    write   = "CUST_Writing_02_Loop_896b83fb-27c3-41e0-924c-7ebf8473154b",
    tome    = "CUST_Reading_Old_Tome_01_7ce9c8f5-a969-4e66-a5c5-9a8c0d51d937",
    book    = "CUST_Reading_Book_01_Loop_d8db9dc7-c6dd-4b6f-8af0-620c7473d8f8",
    dukeread = "CUST_EPI_DukeWyll_Reading_01_Loop_e7047375-2edf-4c19-a408-e1f507020e78",
    ponder  = "CUST_Pondering_01_Loop_a47454a1-05a2-4153-bdfe-7a0500fa62d0",
    bored   = "CUST_Bored_01_Loop_23588ba8-fafb-438c-9bc5-660ff6650aef",
    meditate = "CUST_Meditating_01_45b1a54b-b127-46d2-bfe6-daa8963398ea",
    warm    = "CUST_WarmingByFire_01_Loop_e2d0b8f4-00ae-49a4-a878-a9841fd78a96",
}

local function AnimPlayHelp()
    Ext.Utils.Print("[AmbientAI] usage: !ambient_anim_play <key> [auto|triplet|bare]")
    local keys = {}
    for k in pairs(ANIM_PLAY_KEYS) do keys[#keys + 1] = k end
    table.sort(keys)
    Ext.Utils.Print("  keys: " .. table.concat(keys, ", "))
    Ext.Utils.Print("  auto    = exactly how the mod plays it right now")
    Ext.Utils.Print("  triplet = Start + Loop + End from the mod's table (if mapped)")
    Ext.Utils.Print("  bare    = the loop alone, no start/end pose")
end

function AnimPlayTest.run(keyArg, modeArg)
    if not (Ext and Ext.Utils and Ext.Utils.Print) then return end
    if not keyArg or keyArg == "list" then
        AnimPlayHelp()
        return
    end
    local anim = ANIM_PLAY_KEYS[string.lower(tostring(keyArg))]
    if not anim then
        Ext.Utils.Print("[AmbientAI] unknown key '" .. tostring(keyArg) .. "'")
        AnimPlayHelp()
        return
    end
    local host = Osi.GetHostCharacter and Osi.GetHostCharacter() or nil
    if not host then
        Ext.Utils.Print("[AmbientAI] no host character.")
        return
    end

    local mode = string.lower(tostring(modeArg or "auto"))
    if mode ~= "auto" and mode ~= "triplet" and mode ~= "bare" then
        Ext.Utils.Print("[AmbientAI] unknown mode '" .. mode .. "'")
        AnimPlayHelp()
        return
    end

    local triplet = AnimSystem.getTriplet and AnimSystem.getTriplet(anim) or nil
    local used
    if mode == "auto" then
        AnimSystem.play(host, anim)
        used = triplet and "triplet (via AnimSystem.play)" or "bare loop (via AnimSystem.play)"
    elseif mode == "triplet" then
        if not triplet then
            Ext.Utils.Print("[AmbientAI] this clip has no Start/End mapping in the mod's table -")
            Ext.Utils.Print("  playing it as a triplet is impossible without the real GUIDs.")
            return
        end
        pcall(Osi.PlayLoopingAnimation, host, triplet.start or "", triplet.loop or anim,
            triplet.stop or "", "", "", "", "")
        used = string.format("triplet start=%s | end=%s", tostring(triplet.start), tostring(triplet.stop))
    else
        pcall(Osi.PlayAnimation, host, anim, "")
        used = "bare loop"
    end

    Ext.Utils.Print(string.format("[AmbientAI] playing '%s' as %s", tostring(keyArg), used))
    Ext.Utils.Print("  look at the host's hands for ~9 s: props or empty hands?")
    if Ext.Timer and Ext.Timer.WaitFor then
        Ext.Timer.WaitFor(9000, function()
            pcall(function() Osi.StopAnimation(host, 0) end)
            Ext.Utils.Print("[AmbientAI] test finished - try the other mode and compare.")
        end)
    end
end

if Ext and Ext.RegisterConsoleCommand then
    Ext.RegisterConsoleCommand("ambient_anim_play", function(_cmd, keyArg, modeArg)
        AnimPlayTest.run(keyArg, modeArg)
    end)
end

-- ============================================================================
-- 11. LIGHT INVESTIGATION CONSOLE COMMANDS (Build 04.3.3)
--   !ambient_lights [radius]   - dump every indexed fixture + why it is skipped
--   !ambient_light_fix [radius]- force-ignite every dark fixture around the host
--   !ambient_light_reset       - clear blacklists + session/persistent light memory
-- ============================================================================
-- Build 04.3.4: every "give up" on a light fixture goes through here, so the console
-- always has an explanation (the 04.3.2/04.3.3 code path could drop a fixture silently).
BinLight = {
    unsafe = function(uuid, tpl)
        Blacklist[uuid] = Ext.Utils.MonotonicTime() + LIGHT_TARGET_COOLDOWN
        LightTrace.line("skip", "%s (%s) failed IsSafeWorldObject('light') at walk time -> %ds",
            tostring(tpl), tostring(uuid), math.floor(LIGHT_TARGET_COOLDOWN / 1000))
    end,
}

Ext.RegisterConsoleCommand("ambient_lights", function(_cmd, radiusArg)
    if not IsOsirisReady() then
        Ext.Utils.Print("[AmbientAI] Server not in Running state yet.")
        return
    end
    AmbientLightRepair.diagnose(tonumber(radiusArg) or 20.0)
end)

Ext.RegisterConsoleCommand("ambient_light_fix", function(_cmd, radiusArg)
    if not IsOsirisReady() then
        Ext.Utils.Print("[AmbientAI] Server not in Running state yet.")
        return
    end
    local host = Osi.GetHostCharacter and Osi.GetHostCharacter() or nil
    if not host then return end
    local r = tonumber(radiusArg) or 20.0
    local hx, hy, hz = Osi.GetPosition(host)
    if not hx then return end
    local rSq = r * r
    local touched = 0
    for _, item in ipairs((LocalSpatialIndex and LocalSpatialIndex.items) or {}) do
        local nm = tostring(item.name or "")
        local low = string.lower(nm)
        local isLightish = string.find(nm, "LTS_", 1, true) ~= nil
            or string.find(low, "candle", 1, true) ~= nil
            or string.find(low, "sconce", 1, true) ~= nil
            or string.find(low, "lamp", 1, true) ~= nil
            or string.find(low, "lantern", 1, true) ~= nil
            or string.find(low, "brazier", 1, true) ~= nil
        if isLightish and item.x and item.u then
            local dx, dz = item.x - hx, item.z - hz
            if (dx * dx + dz * dz) <= rSq and not AmbientLightRepair.isLit(item.u) then
                local info = { tplLabel = nm, canPickUp = item.canPickUp, canUse = item.canUse }
                pcall(function()
                    local e = Ext.Entity.Get(item.u)
                    if e and e.Constellation ~= nil then info.hasConstellation = true end
                end)
                local tl = string.lower(nm)
                info.isLampOnly = (string.find(tl, "lamp", 1, true) ~= nil or string.find(tl, "lantern", 1, true) ~= nil)
                    and not string.find(tl, "candle", 1, true)
                AmbientLightRepair.strike(host, item.u, info)
                touched = touched + 1
                Ext.Utils.Print("[AmbientAI] ignition attempt -> " .. nm .. " (" .. tostring(item.u) .. ")")
            end
        end
    end
    Ext.Utils.Print("[AmbientAI] fired the ignition cascade on " .. tostring(touched) ..
        " dark fixture(s); run !ambient_lights again in ~2s to see the verified state.")
end)

Ext.RegisterConsoleCommand("ambient_light_reset", function()
    Blacklist = {}
    ScavengeStats.litSet = {}
    AmbientLightRepair.fails = {}
    if PersistentVars then PersistentVars.LitByAmbientAI = {} end
    Ext.Utils.Print("[AmbientAI] light blacklists, session litSet and save re-arm memory cleared.")
end)

-- ============================================================================
-- 12. LIGHT PROBE / TRACE (Build 04.3.4)
--   !ambient_light_probe [radius]  - everything about the nearest fixtures + why each is skipped
--   !ambient_light_trace on|off    - verbose light tracing without turning on the whole MCM debug log
-- ============================================================================
Ext.RegisterConsoleCommand("ambient_light_trace", function(_cmd, arg)
    LightTrace.force = (tostring(arg) == "on" or tostring(arg) == "1")
    Ext.Utils.Print("[AmbientAI] light trace = " .. tostring(LightTrace.force) ..
        " (also enabled by MCM Debug Logging)")
end)

Ext.RegisterConsoleCommand("ambient_light_probe", function(_cmd, radiusArg)
    if not IsOsirisReady() then
        Ext.Utils.Print("[AmbientAI] Server not in Running state yet.")
        return
    end
    local host = Osi.GetHostCharacter and Osi.GetHostCharacter() or nil
    if not host then return end
    local r = tonumber(radiusArg) or 25.0
    local hx, hy, hz = Osi.GetPosition(host)
    if not hx then return end
    local now = Ext.Utils.MonotonicTime()

    Ext.Utils.Print("=== [AmbientAI] LIGHT PROBE (r=" .. tostring(r) .. "m) ===")
    local st = AmbientLightState
    if st then
        Ext.Utils.Print(string.format(" scheduler: mode=%s unlit=%s lit=%s roomDark=%s nextLightIn=%.1fs lighters=%s/%s",
            tostring(st.zone), tostring(st.unlitSafe), tostring(st.lit), tostring(st.roomDark),
            math.max(0, (st.nextLightTime - now) / 1000.0), tostring(st.activeLighters), tostring(st.maxLighters)))
    else
        Ext.Utils.Print(" scheduler: the light layer has not been reached yet")
    end
    Ext.Utils.Print(" config: LightSources=" .. tostring(Config.LightSources) ..
        " | Debug=" .. tostring(ConfigValues.Debug) ..
        " | trace=" .. tostring(LightTrace.enabled()))

    local comps = GetPartyCompanions()
    Ext.Utils.Print(" party: " .. tostring(#comps) .. " member(s)")
    for _, c in ipairs(comps) do
        local cx, cy, cz = Osi.GetPosition(c)
        Ext.Utils.Print(string.format("   %s | distHost=%.2f moving=%s grouped=%s canAct=%s",
            tostring(c),
            Osi.GetDistanceTo(c, host) or -1,
            tostring(Osi.IsMoving(c)),
            tostring(StateChecks.isGrouped(c, host)),
            tostring(StateChecks.canCompanionAct(c, host, now))))
    end

    local rSq = r * r
    local shown = 0
    for _, item in ipairs((LocalSpatialIndex and LocalSpatialIndex.items) or {}) do
        local nm = tostring(item.name or "")
        local low = string.lower(nm)
        local isLightish = string.find(nm, "LTS_", 1, true) ~= nil
            or string.find(low, "candle", 1, true) ~= nil
            or string.find(low, "candelabr", 1, true) ~= nil
            or string.find(low, "sconce", 1, true) ~= nil
            or string.find(low, "lamp", 1, true) ~= nil
            or string.find(low, "lantern", 1, true) ~= nil
            or string.find(low, "brazier", 1, true) ~= nil
            or string.find(low, "bowl", 1, true) ~= nil
        if isLightish and item.x and item.u then
            local dx, dz = item.x - hx, item.z - hz
            if (dx * dx + dz * dz) <= rSq then
                shown = shown + 1
                local lit, reason = AmbientLightRepair.state(item.u)
                local gpl = AmbientLightRepair.gameplayLightActive(item.u)
                local bl = (Blacklist[item.u] or 0) - now
                local los = "?"
                pcall(function() los = tostring(Osi.HasLineOfSight(host, item.u)) end)
                local safe = IsSafeWorldObject(item.u, "light")
                local pts = GetLightApproachPoints(host, item.u)
                local bestPt, charDist = nil, nil
                if #pts > 0 then
                    local bd = nil
                    for _, p in ipairs(pts) do
                        local d = LightTrace.dist3(host, p.x, p.y, p.z)
                        if d and (not bd or d < bd) then bestPt, bd = p, d end
                    end
                    charDist = bd
                end
                Ext.Utils.Print(string.format(
                    " [%d] %s\n     lit=%s (%s) GPL=%s BURNING=%s safe=%s LoS=%s canUse=%s canPickUp=%s\n     distHost=%.2f dy=%.2f blacklist=%s | approachPoints=%d nearest=(%.2f,%.2f,%.2f) hostWalk=%.2fm",
                    shown, nm, tostring(lit), tostring(reason), tostring(gpl),
                    tostring(AmbientLightRepair.hasLitStatus(item.u)), tostring(safe), los,
                    tostring(item.canUse), tostring(item.canPickUp),
                    math.sqrt(dx * dx + dz * dz + ((item.y or 0) - hy) * ((item.y or 0) - hy)),
                    (item.y or 0) - hy,
                    bl > 0 and string.format("%.0fs", bl / 1000) or "-",
                    #pts,
                    bestPt and bestPt.x or -1, bestPt and bestPt.y or -1, bestPt and bestPt.z or -1,
                    charDist or -1))
            end
        end
    end
    if shown == 0 then
        Ext.Utils.Print("  no light fixtures found in the spatial index around the host.")
        Ext.Utils.Print("  (index size = " .. tostring(#((LocalSpatialIndex or {}).items or {})) .. " items)")
    end
    Ext.Utils.Print("=== end probe ===")
end)

-- ============================================================================
-- 13. SEAT / DISMOUNT DIAGNOSTIC (Build 04.3.5)
--   !ambient_seats  - who is reposed right now, who holds the follow block, pending releases
-- ============================================================================
Ext.RegisterConsoleCommand("ambient_perf", function()
    local s = ActionQueue.stats or {}
    Ext.Utils.Print(string.format(
        "[AmbientAI] === QUEUE PERF === slowTicks(>120ms)=%d | worst=%dms in '%s' | luaMem=%.0fKB | quietSteps=%s | pendingSteps=%d logCost=%.0fms | stepsSuppressed=%d | stepFilter='%s' enqueued=%d filtered=%d",
        s.slow or 0, math.floor(s.worst or 0), tostring(s.worstPhase or "-"),
        collectgarbage("count"), tostring(ActionQueue.quietSteps == true),
        (ActionQueue.stepLog and ActionQueue.stepLog.size) or 0,
        (ActionQueue.stepLog and ActionQueue.stepLog.lastCostMs) or 0,
        ActionQueue.stepSuppressed or 0,
        tostring(ActionQueue.stepFilter or "-"),
        ActionQueue.stepsEnqueued or 0, ActionQueue.stepsFilteredOut or 0))

    -- aggregated per kind: ~10 rows, always complete
    local kinds = {}
    for kind, v in pairs(s.byKind or {}) do
        kinds[#kinds + 1] = { kind = kind, worst = v.worst, n = v.n, sum = v.sum, count = v.count }
    end
    table.sort(kinds, function(a, b) return a.worst > b.worst end)
    if #kinds > 0 then
        Ext.Utils.Print("  -- by kind (worst / avg / slowCount) --")
        for _, r in ipairs(kinds) do
            local avg = (r.count and r.count > 0) and (r.sum / r.count) or 0
            Ext.Utils.Print(string.format("  %-24s worst=%5dms  avg=%5.1fms  n=%d  calls=%d",
                r.kind, math.floor(r.worst), avg, r.n, r.count))
        end
    end

    -- detailed per-action rows, slowest first
    local rows = {}
    for phase, v in pairs(s.byPhase or {}) do
        rows[#rows + 1] = { phase = phase, worst = v.worst, n = v.n }
    end
    table.sort(rows, function(a, b) return a.worst > b.worst end)
    if #rows > 0 then
        Ext.Utils.Print("  -- slowest individual phases --")
    end
    for i = 1, math.min(20, #rows) do
        Ext.Utils.Print(string.format("  %-52s worst=%5dms  n=%d", rows[i].phase,
            math.floor(rows[i].worst), rows[i].n))
    end
    if #rows > 20 then
        Ext.Utils.Print(string.format("  ... %d more phases (all under %dms)", #rows - 20,
            math.floor(rows[21].worst or 0)))
    end
    Ext.Utils.Print("  (reset the counters with !ambient_perf_reset)")
end)

Ext.RegisterConsoleCommand("ambient_perf_reset", function()
    ActionQueue.stats = { slow = 0, worst = 0, worstPhase = "-", byPhase = {}, byKind = {} }
    Ext.Utils.Print("[AmbientAI] queue perf counters reset.")
end)

-- 04.3.19: mute/unmute the per-step "started: <action>" console lines.
-- Errors, voices and diagnostics are NOT affected.
Ext.RegisterConsoleCommand("ambient_quiet", function()
    ActionQueue.quietSteps = not ActionQueue.quietSteps
    Ext.Utils.Print(string.format("[AmbientAI] per-step logging is now %s",
        ActionQueue.quietSteps and "OFF (errors, voices and diagnostics stay on)" or "ON"))
end)

-- 04.3.20: flush deferred step lines right now (useful before copying the log).
-- 04.3.22: step-log filter -------------------------------------------------
Ext.RegisterConsoleCommand("ambient_focus", function(_cmd, pattern)
    if not pattern or pattern == "" then
        Ext.Utils.Print(string.format(
            "[AmbientAI] step filter: '%s' | enqueued=%d filteredOut=%d suppressed=%d | ring=%d",
            tostring(ActionQueue.stepFilter or "-"), ActionQueue.stepsEnqueued or 0,
            ActionQueue.stepsFilteredOut or 0, ActionQueue.stepSuppressed or 0,
            (ActionQueue.stepRing and ActionQueue.stepRing.size) or 0))
        Ext.Utils.Print("  usage: !ambient_focus Seat | !ambient_focus off")
        return
    end
    if string.lower(tostring(pattern)) == "off" then
        ActionQueue.stepFilter = nil
        Ext.Utils.Print("[AmbientAI] step filter cleared - every step line will be printed again")
        return
    end
    ActionQueue.stepFilter = string.lower(tostring(pattern))
    ActionQueue.stepsEnqueued, ActionQueue.stepsFilteredOut = 0, 0
    Ext.Utils.Print(string.format(
        "[AmbientAI] step filter set to '%s' - only matching step lines reach the console "
        .. "(the rest are counted and still kept in !ambient_steps)", ActionQueue.stepFilter))
end)

-- 04.3.21: print the buffered step lines on demand (they are kept even when muted).
Ext.RegisterConsoleCommand("ambient_steps", function(_cmd, countArg)
    local ring = ActionQueue.stepRing
    local want = math.max(1, math.min(ring.max, tonumber(countArg) or 20))
    local lines = ring.lines
    local from = math.max(1, #lines - want + 1)
    Ext.Utils.Print(string.format("[AmbientAI] last %d step line(s) of %d buffered:",
        math.max(0, #lines - from + 1), #lines))
    for i = from, #lines do
        Ext.Utils.Print("  " .. tostring(lines[i]))
    end
end)

-- 04.3.23: familiar idles ------------------------------------------------
Ext.RegisterConsoleCommand("ambient_familiars", function(_cmd, arg)
    FamiliarIdle.syncFromSave()
    local a = string.lower(tostring(arg or ""))
    if a == "on" then FamiliarIdle.setEnabled(true) return end
    if a == "off" then FamiliarIdle.setEnabled(false) return end
    -- 04.3.25: try a real animation resource on the familiars without a new build
    --   !ambient_familiars anim <resource-name>   |   !ambient_familiars anim off
    local animArg = string.match(tostring(arg or ""), "^[Aa][Nn][Ii][Mm]%s+(.+)$")
    if animArg then
        local list = FamiliarIdleSummons()
        if #list == 0 then
            Ext.Utils.Print("[AmbientAI] no summons right now - run the command with no argument")
            return
        end
        if string.lower(animArg) == "off" then
            for _, u in ipairs(list) do
                pcall(function() Osi.StopAnimation(u, 0) end)
            end
            Ext.Utils.Print("[AmbientAI] familiar animation stopped on " .. #list .. " summon(s)")
            return
        end
        for _, u in ipairs(list) do
            pcall(function() Osi.PlayAnimation(u, animArg, "") end)
        end
        Ext.Utils.Print(string.format("[AmbientAI] playing '%s' on %d familiar(s) for 9 s",
            animArg, #list))
        if Ext.Timer and Ext.Timer.WaitFor then
            local stop = list
            Ext.Timer.WaitFor(9000, function()
                for _, u in ipairs(stop) do
                    pcall(function() Osi.StopAnimation(u, 0) end)
                end
                Ext.Utils.Print("[AmbientAI] animation test finished")
            end)
        end
        return
    end
    Ext.Utils.Print(string.format(
        "[AmbientAI] familiar idles: %s | hops=%d skipped=%d last='%s'",
        FamiliarIdle.enabled and "ON" or "OFF", FamiliarIdle.hops or 0,
        FamiliarIdle.skipped or 0, tostring(FamiliarIdle.lastReason or "-")))
    local host = Osi.GetHostCharacter and Osi.GetHostCharacter() or nil
    -- 04.3.24: report from DB_PlayerSummons (works even when the spatial index skips the
    -- summon). Console lines cost seconds in some setups, so the output stays short.
    local rows = 0
    if Osi.DB_PlayerSummons then
        local ok, r = pcall(function() return Osi.DB_PlayerSummons:Get(nil) end)
        if ok and r then rows = #r end
    end
    local summons = FamiliarIdleSummons()
    local indexed = 0
    for _, u in ipairs(summons) do
        for _, nc in ipairs(LocalSpatialIndex.chars or {}) do
            if nc.u == u then indexed = indexed + 1 end
        end
    end
    Ext.Utils.Print(string.format(
        "[AmbientAI] familiar idles: %s | hops=%d skipped=%d last='%s'",
        FamiliarIdle.enabled and "ON" or "OFF", FamiliarIdle.hops or 0,
        FamiliarIdle.skipped or 0, tostring(FamiliarIdle.lastReason or "-")))
    Ext.Utils.Print(string.format(
        "  DB_PlayerSummons: %s | rows=%d summons=%d inSpatialIndex=%d",
        Osi.DB_PlayerSummons and "ok" or "MISSING", rows, #summons, indexed))
    local shown = 0
    for _, u in ipairs(summons) do
        if shown < 4 then
            shown = shown + 1
            local d = host and Osi.GetDistanceTo and Osi.GetDistanceTo(host, u) or nil
            local nm = FamiliarIdleName(u)
            if #nm > 40 then nm = string.sub(nm, 1, 40) end
            Ext.Utils.Print(string.format(
                "  %-40s %5.1f m  summon=%s partyComp=%s",
                nm, d or -1, tostring(FamiliarIdleSummonFlag(u)),
                tostring(FamiliarIdleHasPartyComponent(u))))
        end
    end
    if #summons == 0 then
        Ext.Utils.Print("  no summons reported by the game - summon the familiar and run this again")
    end
    Ext.Utils.Print("  usage: !ambient_familiars on | off")
end)

Ext.RegisterConsoleCommand("ambient_log_now", function()
    local n = ActionQueue.flushStepLog(400)
    Ext.Utils.Print(string.format("[AmbientAI] flushed %d deferred step line(s), %d still queued",
        n, (ActionQueue.stepLog and ActionQueue.stepLog.size) or 0))
end)

Ext.RegisterConsoleCommand("ambient_torch", function()
    if not IsOsirisReady() then
        Ext.Utils.Print("[AmbientAI] Server not in Running state yet.")
        return
    end
    local now = Ext.Utils.MonotonicTime()
    local host = Osi.GetHostCharacter and Osi.GetHostCharacter() or nil
    local comps = GetPartyCompanions()
    local key, st = FieldTorchSystem.getActiveBearerKey()
    local bearer = key and FieldTorchSystem.resolvePartyCharByKey(key) or nil
    local env = FieldTorchSystem.scanEnvironment(host, bearer, now)

    Ext.Utils.Print(string.format(
        "=== [AmbientAI] FIELD TORCH === enabled=%s | bearer=%s | reason=%s | cooldownLeft=%.1fs",
        tostring(Config.FieldTorch), tostring(key or "none"),
        tostring(FieldTorchSystem.lastStatusReason or "idle"),
        math.max(0, ((FieldTorchSystem.cooldownUntil or 0) - now) / 1000.0)))
    Ext.Utils.Print(string.format(
        "  env: litWorldLights=%d litBigFire=%d hazardNear=%s enemyNear=%s dungeonSignals=%d | hostObscured=%s | partyAlreadyLit=%s | darkFor=%.1fs",
        env.litWorldLights, env.litBigFire, tostring(env.hazardNear), tostring(env.enemyNear),
        env.dungeonSignals, tostring(FieldTorchSystem.lastHostObs or "?"),
        tostring(FieldTorchSystem.partyAlreadyHasActiveLight(host, comps)),
        (FieldTorchSystem.darkSince > 0) and ((now - FieldTorchSystem.darkSince) / 1000.0) or 0))
    for _, c in ipairs(comps) do
        local ck = CleanUuid(c) or c
        local state = FieldTorchSystem.ensureStorage()[ck]
        local ownTorch = FieldTorchSystem.findMundaneTorchOnChar(c, true, false)
        local main = Osi.GetEquippedItem and Osi.GetEquippedItem(c, "Melee Main Weapon") or nil
        local off = Osi.GetEquippedItem and Osi.GetEquippedItem(c, "Melee Offhand Weapon") or nil
        Ext.Utils.Print(string.format(
            "  -> %-46s eligible=%-5s score=%-4s torch=%s | main=%s off=%s | state=%s | darkvis=%s | dist=%.1f",
            tostring(c),
            tostring(FieldTorchSystem.isCompanionEligible(c, host)),
            tostring(FieldTorchSystem.scoreCandidate(c)),
            tostring(ownTorch or "-"),
            tostring(main or "-"), tostring(off or "-"),
            state and string.format("torch=%s savedMain=%s unresolved=%s",
                tostring(state.torchUuid), tostring(state.mainHand), tostring(state.unresolvedSince)) or "none",
            tostring(FieldTorchSystem.hasInnateDarkvision(c)),
            (host and Osi.GetDistanceTo and Osi.GetDistanceTo(host, c)) or -1))
    end
    Ext.Utils.Print("  torches in party: " .. tostring(FieldTorchSystem.countPartyTorches(host, comps))
        .. " | swaps this session: " .. tostring(FieldTorchSystem.swaps or 0))
    Ext.Utils.Print("=== end ===")
end)

Ext.RegisterConsoleCommand("ambient_seats", function()
    if not IsOsirisReady() then
        Ext.Utils.Print("[AmbientAI] Server not in Running state yet.")
        return
    end
    local now = Ext.Utils.MonotonicTime()
    Ext.Utils.Print("=== [AmbientAI] SEAT STATE ===")
    for _, c in ipairs(GetPartyCompanions()) do
        local key = CleanUuid(c) or c
        local lock = (PersistentVars and PersistentVars.SeatFollowLocked and PersistentVars.SeatFollowLocked[key] == true)
        local pending = AmbientSeat.pendingRelease[key]
        local seated = AmbientSeat.isSeated(c)
        local q = ActiveQueues[c]
        local last = AmbientSeat.lastSit[key]
        local lastTxt = "-"
        if last then
            lastTxt = string.format("%s on %s (%s)", tostring(last.result), tostring(last.tpl),
                last.dist and string.format("%.2fm", last.dist) or "?")
            if last.why then lastTxt = lastTxt .. " [" .. tostring(last.why) .. "]" end
        end
        Ext.Utils.Print(string.format(" %-46s seated=%-5s followBlock=%-5s pendingRelease=%-13s queue=%-10s lastSit=%s",
            tostring(c), tostring(seated), tostring(lock), tostring(pending or "-"),
            tostring(q and q.isProcessing and (q.activityTag or "?") or "idle"),
            lastTxt))
    end
    Ext.Utils.Print("=== end ===")
end)
