-- ============================================================================
-- Script: Ambient AI - Build 04.3.2 Client Wwise Audio Bridge (v1.4.3.2)
-- Purpose:
--   Uses BG3SE v29+ Ext.Net.CreateChannel(ModuleUUID, "ActionVoice") to receive
--   companion vocal events from BootstrapServer.lua, preload Wwise VOCALS &
--   PLAYER_RACES soundbanks/events, extract the speaking companion's exact
--   ls::SoundComponent ActiveData.SoundSwitches + TagSoundState switches, and:
--     * Route 2D VOCALS.bnk BGClickReaction_* onto BG3's dedicated point-and-click
--       "PlayerEmitter" first (with "HUD" fallback) using the speaking companion's
--       SoundSwitches, restoring the controlled Host's switches afterwards.
--     * Route 3D PLAYER_RACES.bnk character vocals (MaxDistance = 40) directly
--       onto the companion's 3D client entity (compEnt).
-- ============================================================================

local MyModUUID = ModuleUUID or "7d2e1b4a-9c8f-4a1d-b5e2-6f3a9c8b1d4e"
local ActionVoiceChannel = (Ext and Ext.Net and Ext.Net.CreateChannel)
    and Ext.Net.CreateChannel(MyModUUID, "ActionVoice")
    or nil

local PRELOAD_BANKS = {
    "VOCALS",
    "PLAYER_RACES",
}

local PRELOAD_EVENTS = {
    "BGClickReaction_Action_InteractWith",
    "BGClickReaction_Action_OpenContainer",
    "BGClickReaction_Action_ItemPickup",
    "BGClickReaction_RelationPrototype_Rest",
    "BGClickReaction_Action_SpeakTo",
    "BGClickReaction_RelationPrototype_SetPositive",
    "BGClickReaction_ReptAction_PortraitClick",
    "BGClickReaction_Action_Attack",
    "BGClickReaction_Action_Utility",
    "BGClickReaction_Action_OpenLock",
    "Player_Races_Voice_Gen_Laughter",
    "Player_Races_Voice_Gen_Recover",
    "Player_Races_Voice_Gen_ClosedMouthEfforts",
    "Player_Races_Voice_Gen_Victory",
}

local VocalsPreloaded = false
local TagSwitchCache = nil
local RestoreToken = 0

local function CleanUuidClient(str)
    if type(str) ~= "string" then return nil end
    return string.match(str, "%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$")
end

local function BuildTagSwitchCache()
    if TagSwitchCache ~= nil then return TagSwitchCache end
    TagSwitchCache = {}
    if not Ext or not Ext.StaticData or not Ext.StaticData.GetAll then
        return TagSwitchCache
    end

    pcall(function()
        local ids = Ext.StaticData.GetAll("TagSoundState")
        if not ids then return end
        for _, id in ipairs(ids) do
            local res = Ext.StaticData.Get(id, "TagSoundState")
            if res and res.TagUuid and res.OverrideSwitchGroup and res.OverrideSwitch then
                local tagStr = tostring(res.TagUuid)
                local grpStr = tostring(res.OverrideSwitchGroup)
                local swStr  = tostring(res.OverrideSwitch)
                if tagStr ~= "" and grpStr ~= "" and swStr ~= "" then
                    TagSwitchCache[tagStr] = {
                        group = grpStr,
                        switch = swStr,
                        default = res.DefaultSwitch and tostring(res.DefaultSwitch) or nil,
                    }
                end
            end
        end
    end)
    return TagSwitchCache
end

local function EnsureVocalsPreloaded()
    if VocalsPreloaded then return end
    if not Ext or not Ext.Audio then return end
    VocalsPreloaded = true

    BuildTagSwitchCache()
    for _, bank in ipairs(PRELOAD_BANKS) do
        pcall(Ext.Audio.LoadBank, bank)
    end
    for _, ev in ipairs(PRELOAD_EVENTS) do
        pcall(Ext.Audio.LoadEvent, ev)
    end
end

local function FindClientEntity(uuidStr)
    local clean = CleanUuidClient(uuidStr) or uuidStr
    if not clean or not Ext or not Ext.Entity or not Ext.Entity.Get then return nil end

    local okDirect, ent = pcall(Ext.Entity.Get, clean)
    if okDirect and ent ~= nil then
        return ent
    end

    if uuidStr ~= clean then
        local okRaw, entRaw = pcall(Ext.Entity.Get, uuidStr)
        if okRaw and entRaw ~= nil then
            return entRaw
        end
    end

    local found = nil
    pcall(function()
        local party = Ext.Entity.GetAllEntitiesWithComponent("PartyMember")
        if party then
            for _, h in pairs(party) do
                local e = (type(h) == "string") and Ext.Entity.Get(h) or h
                if e and e.Uuid and tostring(e.Uuid.EntityUuid) == clean then
                    found = e
                    return
                end
            end
        end
    end)
    return found
end

local function CollectEntityTags(ent)
    local tags = {}
    if not ent then return tags end
    local function addList(list)
        if not list then return end
        for _, t in pairs(list) do
            tags[tostring(t)] = true
        end
    end
    pcall(function() if ent.Tag and ent.Tag.Tags then addList(ent.Tag.Tags) end end)
    pcall(function() if ent.OsirisTag and ent.OsirisTag.Tags then addList(ent.OsirisTag.Tags) end end)
    pcall(function() if ent.OriginTag and ent.OriginTag.Tags then addList(ent.OriginTag.Tags) end end)
    pcall(function() if ent.VoiceTag and ent.VoiceTag.Tags then addList(ent.VoiceTag.Tags) end end)
    pcall(function()
        if ent.Voice and ent.Voice.Voice and Ext.StaticData and Ext.StaticData.Get then
            local vRes = Ext.StaticData.Get(ent.Voice.Voice, "Voice")
            if vRes and vRes.Tags then addList(vRes.Tags) end
        end
    end)
    return tags
end

local function ExtractEntitySwitches(ent)
    local map = {}
    if not ent then return map, 0 end

    -- 1. StaticData TagSoundState mapping (Origin / Voice / Character tags -> Wwise Switch)
    local tagCache = BuildTagSwitchCache()
    local entTags = CollectEntityTags(ent)
    for tagUuid, _ in pairs(entTags) do
        local entry = tagCache[tagUuid]
        if entry then
            map[entry.group] = entry.switch
        end
    end

    -- 2. Live ls::SoundComponent ActiveData.SoundSwitches (verified in BG3Extender/GameDefinitions/Components/Sound.h)
    pcall(function()
        local active = ent.Sound and ent.Sound.ActiveData or nil
        local switches = active and active.SoundSwitches or nil
        if switches then
            for k, v in pairs(switches) do
                local ks = tostring(k)
                local vs = tostring(v)
                if ks ~= "" and vs ~= "" then
                    map[ks] = vs
                end
            end
        end
    end)

    local count = 0
    for _ in pairs(map) do count = count + 1 end
    return map, count
end

local function ApplySwitchesToTarget(targetObj, baseSwitches, overrideSwitches)
    if not Ext or not Ext.Audio or not Ext.Audio.SetSwitch then return end
    if baseSwitches then
        for k, v in pairs(baseSwitches) do
            if not overrideSwitches or overrideSwitches[k] == nil then
                pcall(Ext.Audio.SetSwitch, targetObj, k, v)
            end
        end
    end
    if overrideSwitches then
        for k, v in pairs(overrideSwitches) do
            pcall(Ext.Audio.SetSwitch, targetObj, k, v)
        end
    end
end

local function TryPostOnTarget(targetObj, eventName)
    if not targetObj or not eventName or eventName == "" then return false end
    pcall(Ext.Audio.LoadEvent, eventName)
    local ok, played = pcall(Ext.Audio.PostEvent, targetObj, eventName)
    return ok and played == true
end

local function ScheduleEmitterRestore(hostSwitches)
    if not hostSwitches or next(hostSwitches) == nil then return end
    if not Ext or not Ext.Timer or not Ext.Timer.WaitForRealtime then return end

    RestoreToken = RestoreToken + 1
    local myToken = RestoreToken
    Ext.Timer.WaitForRealtime(3400, function()
        if myToken ~= RestoreToken then return end
        ApplySwitchesToTarget("HUD", nil, hostSwitches)
        ApplySwitchesToTarget("PlayerEmitter", nil, hostSwitches)
    end)
end

local function HandleActionVoiceData(data)
    if not Ext or not Ext.Audio or type(data) ~= "table" then return end
    EnsureVocalsPreloaded()

    local compEnt = FindClientEntity(data.char)
    local hostEnt = data.host and FindClientEntity(data.host) or nil
    local compSwitches, compSwitchCount = ExtractEntitySwitches(compEnt)
    local hostSwitches, _ = ExtractEntitySwitches(hostEnt)

    local primaryEvent = (type(data.event) == "string" and data.event ~= "") and data.event or nil
    local alt3dEvent   = (type(data.alt3d) == "string" and data.alt3d ~= "") and data.alt3d or nil
    local forceTarget  = (type(data.target) == "string" and data.target ~= "") and data.target or nil
    local onlyAlt3d    = (data.onlyAlt3d == true)
    local skipAlt3d    = (data.skipAlt3d == true)
    local playedVia    = nil

    if forceTarget then
        local tgt = (forceTarget == "entity") and compEnt or forceTarget
        local evToPlay = (forceTarget == "entity") and (alt3dEvent or primaryEvent) or (primaryEvent or alt3dEvent)
        if tgt and evToPlay then
            ApplySwitchesToTarget(tgt, hostSwitches, compSwitches)
            if TryPostOnTarget(tgt, evToPlay) then
                playedVia = tostring(forceTarget) .. "(" .. tostring(evToPlay) .. ")"
                if forceTarget ~= "entity" then
                    ScheduleEmitterRestore(hostSwitches)
                end
            end
        end
    else
        -- 1. If 3D racial/character vocal is explicitly requested (e.g. social reply laugh, pet greet, sigh)
        if (onlyAlt3d or data.preferAlt3d) and alt3dEvent and compEnt and not skipAlt3d then
            ApplySwitchesToTarget(compEnt, hostSwitches, compSwitches)
            if TryPostOnTarget(compEnt, alt3dEvent) then
                playedVia = "Entity3D(" .. alt3dEvent .. ")"
            end
        end

        -- 2. 2D VOCALS.bnk BGClickReaction_* routing (MaxDistance = -1):
        --    Post onto BG3's dedicated point-and-click "PlayerEmitter" first (snd->PlayerEmitter[0]),
        --    then fall back to "HUD", copying the speaking companion's SoundSwitches!
        if not playedVia and not onlyAlt3d and primaryEvent then
            ApplySwitchesToTarget("PlayerEmitter", hostSwitches, compSwitches)
            if TryPostOnTarget("PlayerEmitter", primaryEvent) then
                playedVia = "PlayerEmitter(" .. primaryEvent .. ")"
                ScheduleEmitterRestore(hostSwitches)
            else
                ApplySwitchesToTarget("HUD", hostSwitches, compSwitches)
                if TryPostOnTarget("HUD", primaryEvent) then
                    playedVia = "HUD(" .. primaryEvent .. ")"
                    ScheduleEmitterRestore(hostSwitches)
                end
            end
        end

        -- 3. 3D PLAYER_RACES.bnk fallback on companion entity if HUD had no switches or returned false
        if not playedVia and not skipAlt3d and alt3dEvent and compEnt then
            ApplySwitchesToTarget(compEnt, hostSwitches, compSwitches)
            if TryPostOnTarget(compEnt, alt3dEvent) then
                playedVia = "Entity3D_Fallback(" .. alt3dEvent .. ")"
            end
        end
    end

    if data.debug then
        local swList = {}
        for k, v in pairs(compSwitches) do
            swList[#swList + 1] = k .. "=" .. v
        end
        Ext.Utils.Print(string.format(
            "[AmbientAI-Client] Voice char=%s | compEnt=%s | switches=%d (%s) | result=%s",
            tostring(data.char),
            tostring(compEnt ~= nil),
            compSwitchCount,
            table.concat(swList, ", "),
            tostring(playedVia or "NONE")
        ))
    end
end

if ActionVoiceChannel then
    ActionVoiceChannel:SetHandler(function(data)
        HandleActionVoiceData(data)
    end)
end

if Ext and Ext.Events and Ext.Events.SessionLoaded then
    Ext.Events.SessionLoaded:Subscribe(function()
        EnsureVocalsPreloaded()
        Ext.Utils.Print("[AmbientAI-Client] Wwise audio bridge ready (v1.4.3.2).")
    end)
end
