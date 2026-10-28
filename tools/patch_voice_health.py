#!/usr/bin/env python3
"""Build 04.3.7 - VOICE HEALTH

Fixes found by the bark/voice audit:
  1. "tired / we should rest" overhead lines (CAMP_RestReminder_PAD, *AfterShortRest* PAD)
     now only play when the party actually looks tired: HP threshold or spent spell slots.
     When HP is full and every slot is full they are silently dropped from the pad pool.
  2. Companions talk too rarely: a "chatter" tick speaks on its own after long silence
     and ambient cooldowns scale with the current quiet streak.
  3. Barks no longer start overhead PAD dialogs while a companion is reposed on furniture
     (a dialog cancels repose -> the 04.3.5 seat fix would be fought by the voice system).
  4. Diagnostics: !ambient_voice dumps the oracle (HP / slots / source / needsRest).

Usage: python3 tools/patch_voice_health.py <in.lua> <out.lua>
"""
import sys

src = open(sys.argv[1], encoding="utf-8").read()
applied = []


def sub(old, new, name, count=1):
    global src
    assert src.count(old) >= 1, "ANCHOR NOT FOUND: " + name
    src = src.replace(old, new, count)
    applied.append(name)


# ---------------------------------------------------------------------------
# 1. mark the rest-reminder pads so they can be state-gated
# ---------------------------------------------------------------------------
sub('''    local PAD_REST_TIRED    = { id = "CAMP_RestReminder_PAD_c08e3366-ac86-586a-2065-59317be3e012",               timeline = true  }
    local PAD_REST_RESPITE  = { id = "GLO_PAD_PartyCommentsAfterShortRest_d08505e7-9c2d-7fc4-95ab-1a340692ac84", timeline = true  }''',
'''    -- 04.3.7: restHint pads talk about being tired / resting. They are dropped from the
    -- candidate list unless the party oracle says there is a reason (HP or spell slots).
    local PAD_REST_TIRED    = { id = "CAMP_RestReminder_PAD_c08e3366-ac86-586a-2065-59317be3e012",               timeline = true, restHint = true }
    local PAD_REST_RESPITE  = { id = "GLO_PAD_PartyCommentsAfterShortRest_d08505e7-9c2d-7fc4-95ab-1a340692ac84", timeline = true, restHint = true }''',
    "pad-restHint")


# ---------------------------------------------------------------------------
# 2. party rest-state oracle
# ---------------------------------------------------------------------------
ORACLE = '''
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
'''

sub('''    local SND_VOCAL_EFFORTS  = "14319f88-14a1-844d-a200-a90cd778262c" -- Player_Races_Voice_Gen_ClosedMouthEfforts
''',
'''    local SND_VOCAL_EFFORTS  = "14319f88-14a1-844d-a200-a90cd778262c" -- Player_Races_Voice_Gen_ClosedMouthEfforts
''' + ORACLE,
    "oracle-block")


# ---------------------------------------------------------------------------
# 3. file-scope handle (single extra register, the file is close to the 200-locals cap)
# ---------------------------------------------------------------------------
sub('''local ACTION_VOICE_PROFILES
local TryTriggerWorldPartyBanter
local TryPlayCompanionActionVoice''',
'''local AmbientVoice = {}   -- Build 04.3.7: voice health context + self-driven chatter tick
local ACTION_VOICE_PROFILES
local TryTriggerWorldPartyBanter
local TryPlayCompanionActionVoice''',
    "ambientvoice-handle")


# ---------------------------------------------------------------------------
# 4. gate the rest-hint pads inside the pad launcher
# ---------------------------------------------------------------------------
sub('''    local function TryStartSpokenOverheadPad(char, padList, now, forceTest, noTimelinePad)''',
'''    local function TryStartSpokenOverheadPad(char, padList, now, forceTest, noTimelinePad, allowRestTalk)''',
    "pad-signature")

sub('''                local compOk = (not entry.onlyComp) or (cleanChar == entry.onlyComp)
                local tlOk   = (not noTimelinePad) or (entry.timeline == false)
                local cdOk   = forceTest or ((ActionVoiceStats.spokenPadCooldown[entry.id] or 0) <= now)
                if compOk and tlOk and cdOk then''',
'''                local compOk = (not entry.onlyComp) or (cleanChar == entry.onlyComp)
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
                if compOk and tlOk and cdOk and stateOk then''',
    "pad-state-filter")


# ---------------------------------------------------------------------------
# 5. rest-context categories may always talk about resting (they ARE the rest)
# ---------------------------------------------------------------------------
sub('''        wash_clean       = { chance = 0.90, pads = { PAD_MIRROR_CLEAN, PAD_REST_RESPITE },''',
    '''        wash_clean       = { chance = 0.90, restContext = true, pads = { PAD_MIRROR_CLEAN, PAD_REST_RESPITE },''',
    "restcontext-wash")
sub('''        rest_sit_done    = { chance = 0.85, pads = { PAD_REST_RESPITE },''',
    '''        rest_sit_done    = { chance = 0.85, restContext = true, pads = { PAD_REST_RESPITE },''',
    "restcontext-sitdone")
sub('''        wake_bed         = { chance = 0.85, pads = { PAD_REST_RESPITE },''',
    '''        wake_bed         = { chance = 0.85, restContext = true, pads = { PAD_REST_RESPITE },''',
    "restcontext-wake")
sub('''        post_combat_tired = { chance = 1.00, pads = { PAD_REST_TIRED, PAD_REST_RESPITE },''',
    '''        post_combat_tired = { chance = 1.00, restContext = true, pads = { PAD_REST_TIRED, PAD_REST_RESPITE },''',
    "restcontext-postcombat")

# a cheap ambient line for the chatter tick
sub('''        post_combat_tired = { chance = 1.00, restContext = true, pads = { PAD_REST_TIRED, PAD_REST_RESPITE },''',
    '''        idle_chatter      = { chance = 0.90, pads = { PAD_PERCEPTION, PAD_INVESTIGATION, PAD_MIRROR_CLEAN, PAD_REST_TIRED }, vocalGuid = SND_VOCAL_RECOVER, event = "BGClickReaction_ReptAction_PortraitClick", alt3d = "Player_Races_Voice_Gen_Recover" },
        post_combat_tired = { chance = 1.00, restContext = true, pads = { PAD_REST_TIRED, PAD_REST_RESPITE },''',
    "idle-chatter-profile")


# ---------------------------------------------------------------------------
# 5b. audit finding: the "after a short rest" PAD was also used by chatter
#     categories, so a rested party still heard resting talk. Rest pads now
#     only appear in real rest moments.
# ---------------------------------------------------------------------------
sub("        wash_clean       = { chance = 0.90, restContext = true, pads = { PAD_MIRROR_CLEAN, PAD_REST_RESPITE },",
    "        wash_clean       = { chance = 0.90, pads = { PAD_MIRROR_CLEAN },",
    "pad-tidy-wash")
sub("        social_init      = { chance = 0.95, pads = { PAD_INVESTIGATION, PAD_PERCEPTION, PAD_REST_RESPITE },",
    "        social_init      = { chance = 0.95, pads = { PAD_INVESTIGATION, PAD_PERCEPTION },",
    "pad-tidy-socialinit")
sub("        social_reply     = { chance = 0.92, pads = { PAD_REST_RESPITE, PAD_MIRROR_CLEAN },",
    "        social_reply     = { chance = 0.92, pads = { PAD_MIRROR_CLEAN },",
    "pad-tidy-socialreply")
sub("        pet_greet        = { chance = 0.92, pads = { PAD_SH_CALL_PET, PAD_REST_RESPITE },",
    "        pet_greet        = { chance = 0.92, pads = { PAD_SH_CALL_PET },",
    "pad-tidy-pet")
sub("        bard_cheer       = { chance = 0.82, pads = { PAD_REST_RESPITE },  vocalGuid",
    "        bard_cheer       = { chance = 0.82, vocalGuid",
    "pad-tidy-bard")


# ---------------------------------------------------------------------------
# 6. hand the flag to the pad launcher + never open a PAD dialog while reposed
# ---------------------------------------------------------------------------
sub('''        -- Reserve overhead PAD dialogs for Origin companions whenever Origin companions are in the party!
        local allowSpokenPad = (padCandidates ~= nil)
            and (isOrigin or otherOrigins == 0 or forceTest)
            and (not forceTarget or forceTarget == "" or forceTarget == "pad")
        if allowSpokenPad then
            local startedPad, usedPadId = TryStartSpokenOverheadPad(char, padCandidates, now, forceTest, noTimelinePad)''',
'''        -- 04.3.7: a PAD is a real dialog - it cancels a Repose pose. A companion who is
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
            local startedPad, usedPadId = TryStartSpokenOverheadPad(char, padCandidates, now, forceTest, noTimelinePad, allowRestTalk)''',
    "pad-allow-resttalk")


# ---------------------------------------------------------------------------
# 7. density: the longer the silence, the sooner the next line
# ---------------------------------------------------------------------------
sub('''        local baseCdMs = math.max(5000, (tonumber(Config.ActionVoiceCooldown) or 24) * 1000)
        local jitterFactor = 0.85 + (math.random() * 0.30)
        local partyWaitMs = math.floor(baseCdMs * jitterFactor)
        local hirelingMult = isOrigin and 1.0 or 2.2''',
'''        local baseCdMs = math.max(5000, (tonumber(Config.ActionVoiceCooldown) or 24) * 1000)
        local jitterFactor = 0.85 + (math.random() * 0.30)
        local hirelingMult = isOrigin and 1.0 or 2.2
        -- 04.3.7 Voice density: a party that has been silent for a while earns a shorter
        -- pause. Long silence used to snowball (each quiet minute made the next line rarer).
        local quietFor = now - (ActionVoiceStats.lastVoiceAt or 0)
        local density = 1.0
        if quietFor > 45000 then density = 1.35 end
        if quietFor > 90000 then density = 1.75 end
        if isImportant then density = 1.0 end
        local partyWaitMs = math.floor((baseCdMs / density) * jitterFactor)''',
    "density-wait")

sub('''            NextGlobalActionVoiceTime = math.max(NextGlobalActionVoiceTime, now + math.floor(baseCdMs * 0.85))
            CompanionActionVoiceCooldown[clean] = now + math.floor(math.max(22000, math.floor(baseCdMs * 1.15)) * hirelingMult)''',
'''            NextGlobalActionVoiceTime = math.max(NextGlobalActionVoiceTime, now + math.floor((baseCdMs * 0.85) / density))
            CompanionActionVoiceCooldown[clean] = now + math.floor(math.max(16000, math.floor(baseCdMs * 0.90 / density)) * hirelingMult)''',
    "density-reply")

sub('''            NextGlobalActionVoiceTime = now + partyWaitMs
            CompanionActionVoiceCooldown[clean] = now + math.floor(math.max(24000, math.floor(baseCdMs * 1.20)) * hirelingMult)''',
'''            NextGlobalActionVoiceTime = now + partyWaitMs
            CompanionActionVoiceCooldown[clean] = now + math.floor(math.max(15000, math.floor(baseCdMs * 0.70 / density)) * hirelingMult)''',
    "density-ambient")


# ---------------------------------------------------------------------------
# 8. self-driven chatter tick
# ---------------------------------------------------------------------------
sub('''        return true, playedMode
    end
end''',
'''        return true, playedMode
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
        if quietFor < 55000 then return end
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
end''',
    "chatter-tick")


# ---------------------------------------------------------------------------
# 9. call it from the main tick
# ---------------------------------------------------------------------------
sub('''    local targets, zone = ScanNearbyWorldTargets(host, now)
    if not targets then return end''',
'''    -- 04.3.7: give the party its own voice slot (see AmbientVoice.chatterTick)
    if AmbientVoice.chatterTick then
        pcall(AmbientVoice.chatterTick, now)
    end

    local targets, zone = ScanNearbyWorldTargets(host, now)
    if not targets then return end''',
    "main-tick-call")


# ---------------------------------------------------------------------------
# 10. diagnostics
# ---------------------------------------------------------------------------
sub('''    Ext.RegisterConsoleCommand("ambient_anims", function()''',
'''    Ext.RegisterConsoleCommand("ambient_voice", function()
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
            "  -> action voices=%s | played=%d pads=%d voc3d=%d gossips=%d breathers=%d | silent for %.1fs | next line in %.1fs",
            tostring(Config.ActionVoices),
            ActionVoiceStats.played, ActionVoiceStats.spokenPads, ActionVoiceStats.vocals3d,
            ActionVoiceStats.gossips, ActionVoiceStats.breathers,
            (now - (ActionVoiceStats.lastVoiceAt or 0)) / 1000.0,
            math.max(0, (NextGlobalActionVoiceTime - now) / 1000.0)
        ))
        Ext.Utils.Print(string.format(
            "  -> rest-reminder lines: %s | last speaker=%s",
            vc.needsRest and "ALLOWED (party looks tired - soft reminder)"
                or "SUPPRESSED (party at full health and full spell slots)",
            tostring(LastActionVoiceSpeaker or "none")
        ))
        Ext.Utils.Print("  -> if slots say 'unknown', the tired-line gate falls back to HP only.")
    end)

    Ext.RegisterConsoleCommand("ambient_anims", function()''',
    "console-ambient_voice")


# ---------------------------------------------------------------------------
# 11. AUDIT FIX: a single unresolvable dialog instance could silence the whole
#     voice system for the rest of the session (IsAnyDialogActive never returned
#     false again). Entries now carry a timestamp and stale rows are pruned.
# ---------------------------------------------------------------------------
sub('''local function IsAnyDialogActive()
    for inst, _ in pairs(ActiveDialogs) do
        if Osi.DialogGetNumberOfInvolvedPlayers then
            local ok, count = pcall(Osi.DialogGetNumberOfInvolvedPlayers, inst)
            if ok and type(count) == "number" and count <= 0 then
                ActiveDialogs[inst] = nil
            else
                return true
            end
        else
            return true
        end
    end''',
'''local function IsAnyDialogActive()
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
    end''',
    "dialog-stale-guard")

sub('''        if involvesParty then
            ActiveDialogs[instance] = true
            AbortAllQueues("dialog")''',
'''        if involvesParty then
            ActiveDialogs[instance] = Ext.Utils.MonotonicTime()
            AbortAllQueues("dialog")''',
    "dialog-stamp")

# ---------------------------------------------------------------------------
# 12. AUDIT FIX: VoiceBusyUntil/lastVoiceAt was read (with a nil guard) but never
#     initialised, which made the very first rotation decision behave differently.
# ---------------------------------------------------------------------------
sub('''    ownDialogWindowUntil = 0,
    nextWorldGossipTime  = 0,''',
'''    ownDialogWindowUntil = 0,
    lastVoiceAt          = 0,
    nextWorldGossipTime  = 0,''',
    "stats-lastvoiceat")

# ---------------------------------------------------------------------------
# 13. chatter threshold: 55 s of total silence is a long time to wait
# ---------------------------------------------------------------------------
sub('''        local quietFor = now - (ActionVoiceStats.lastVoiceAt or 0)
        if quietFor < 55000 then return end''',
'''        local quietFor = now - (ActionVoiceStats.lastVoiceAt or 0)
        if quietFor < 40000 then return end''',
    "chatter-threshold")



# ---------------------------------------------------------------------------
# 14. AUDIT FIX: a failed PAD launch left RedirectGuard armed for 4.5 s, so a
#     genuinely reactive companion bark in that window was silently dropped.
# ---------------------------------------------------------------------------
sub('''            if LaunchSingleOverheadPad(char, padId) then
                ActionVoiceStats.spokenPadCooldown[padId] = now + 36000
                ActionVoiceStats.spokenPads = ActionVoiceStats.spokenPads + 1
                return true, padId
            end''',
'''            if LaunchSingleOverheadPad(char, padId) then
                ActionVoiceStats.spokenPadCooldown[padId] = now + 36000
                ActionVoiceStats.spokenPads = ActionVoiceStats.spokenPads + 1
                return true, padId
            end
            -- launch failed: do not keep the re-entrancy guard armed, it would mute
            -- reactive barks for the next 4.5 s for nothing
            ActionVoiceStats.padFail = (ActionVoiceStats.padFail or 0) + 1
            RedirectGuard[padId] = nil
            if cleanPad then RedirectGuard[cleanPad] = nil end''',
    "pad-fail-guard")

# ---------------------------------------------------------------------------
# 15. diagnostics counters for the pad / vocal split (is the party really talking?)
# ---------------------------------------------------------------------------
sub('''    lastVoiceAt          = 0,''',
'''    lastVoiceAt          = 0,
    padFail              = 0,
    vocalOnly            = 0,''',
    "stats-counters")

sub('''            playedMode = vocRoute
            playedDetail = chosenTplField or profile.vocalGuid or chosenEvent''',
'''            playedMode = vocRoute
            playedDetail = chosenTplField or profile.vocalGuid or chosenEvent
            ActionVoiceStats.vocalOnly = ActionVoiceStats.vocalOnly + 1   -- no PAD: grunt/sigh only''',
    "count-vocalonly")

sub('''        Ext.Utils.Print(string.format(
            "  -> action voices=%s | played=%d pads=%d voc3d=%d gossips=%d breathers=%d | silent for %.1fs | next line in %.1fs",''',
'''        Ext.Utils.Print(string.format(
            "  -> pads: played=%d failed=%d | grunt-only lines=%d (a grunt is not speech - high numbers here mean the party is quieter than it looks)",
            ActionVoiceStats.spokenPads, ActionVoiceStats.padFail or 0, ActionVoiceStats.vocalOnly or 0))
        Ext.Utils.Print(string.format(
            "  -> action voices=%s | played=%d pads=%d voc3d=%d gossips=%d breathers=%d | silent for %.1fs | next line in %.1fs",''',
    "diag-pad-split")



open(sys.argv[2], "w", encoding="utf-8").write(src)
print("applied %d patches: %s" % (len(applied), ", ".join(applied)))
