#!/usr/bin/env python3
"""Build 04.3.10 - LIGHT DISCIPLINE + FIELD TORCH AUDIT

Light layer
  * "The room is already lit": lighting fired whenever ANY unlit fixture existed, even in a room
    with ten burning candles. Now, when at least three fixtures are already burning and they
    outnumber the unlit ones 2:1, only a fixture within 6 m of the companion is still finished off
    (the rest of the room is left alone; retry in 15 s, i.e. it re-evaluates if the party moves).
  * Visibility of the existing enemy check: fixtures skipped because a hostile (or a flammable
    hazard) is within 16 m are now counted and logged, instead of silently producing
    "unlitSafeCount=0" and an idle companion.
  * The layer no longer sends a companion who already carries a burning field torch off to light
    more candles (consistent with every other roleplay layer, which is gated on carryingFieldTorch).

Field torch (FieldTorchSystem)
  * equipSilent() trusted Osi.IsEquipped(item) - an item-level flag that is true even when somebody
    ELSE holds the torch or it landed in a non-hand slot. It now verifies that this companion really
    holds the torch in a hand (main hand, then the plain engine form) instead of trusting the
    item-level Osi.IsEquipped flag.
  * restoreCompanion() deleted the saved state BEFORE resolving the character. During a level
    transition (or any moment the entity is not resolvable) the state was lost forever and the
    companion kept our burning torch with the original weapon stowed. The state is now kept and
    retried (dropped after 2 minutes of being unresolvable).
  * scanEnvironment() called Osi.Exists() for every indexed world item every 650 ms. The plain
    distance math now runs first and the engine call only for items within 15 m.
  * onItemEquipped() wiped the saved weapon state when the engine reported our OWN torch equip
    asynchronously (the guard was already released by then): the companion then kept the burning
    torch in hand forever. An equip event within 2.5 s of our own swap is now ignored.
  * New console command !ambient_torch dumps the whole torch decision for every party member.

Usage: python3 tools/patch_light_torch.py <in.lua> <out.lua>
"""
import sys

src = open(sys.argv[1], encoding="utf-8").read()
applied = []


def sub(old, new, name, count=1):
    global src
    assert old in src, "ANCHOR NOT FOUND: " + name
    src = src.replace(old, new, count)
    applied.append(name)


# ---------------------------------------------------------------------------
# 1. light layer: count fixtures skipped by the (already existing) 16 m enemy check
# ---------------------------------------------------------------------------
sub('''    local litLightsCount = 0
    local unlitSafeCount = 0''',
'''    local litLightsCount = 0
    local unlitSafeCount = 0
    -- 04.3.10: how many fixtures were refused because a live hostile (or a flammable hazard) sits
    -- within 16 m. Purely for the log: previously this silently produced "unlitSafeCount=0".
    local enemyBlockedFixtures = 0''',
    "light-count-enemy-blocked")

sub('''            elseif cItem.canIgnite == true
                and not ReservedTargets[cItem.u]
                and (not Blacklist[cItem.u] or now >= Blacklist[cItem.u])
                and not IsNearFlammableHazard(cItem, targets.hazards)
            then
                unlitSafeCount = unlitSafeCount + 1''',
'''            elseif cItem.canIgnite == true
                and not ReservedTargets[cItem.u]
                and (not Blacklist[cItem.u] or now >= Blacklist[cItem.u])
                and not IsNearFlammableHazard(cItem, targets.hazards)
            then
                unlitSafeCount = unlitSafeCount + 1
            elseif cItem.canIgnite == true
                and (not Blacklist[cItem.u] or now >= Blacklist[cItem.u])
                and IsNearFlammableHazard(cItem, targets.hazards)
            then
                enemyBlockedFixtures = enemyBlockedFixtures + 1''',
    "light-enemy-blocked-count")

sub('''        if not charAssigned and Config.LightSources and now < NextLightTime''',
'''        if Config.LightSources and unlitSafeCount == 0 and enemyBlockedFixtures > 0
            and (now - (LightTrace.lastGateLog or 0)) >= 15000 then
            LightTrace.lastGateLog = now
            Log(string.format(
                "Light layer idle: %d fixture(s) refused - live hostile or flammable hazard within 16m (dark-room duty on hold)",
                enemyBlockedFixtures))
        end
        if not charAssigned and Config.LightSources and now < NextLightTime''',
    "light-enemy-blocked-log")


# ---------------------------------------------------------------------------
# 2. light layer: a companion carrying a field torch does not go lighting candles
# ---------------------------------------------------------------------------
sub('''        if not charAssigned and Config.LightSources and now >= NextLightTime then
            local activeLighters = 0''',
'''        -- 04.3.10: the light-bearer already carries a burning light - no need to walk him to candles
        -- as well (every other roleplay layer is gated on carryingFieldTorch too).
        local lightLayerAllowed = not FieldTorchSystem.isCarryingAutoTorch(char)
        if not charAssigned and lightLayerAllowed and Config.LightSources and now >= NextLightTime then
            local activeLighters = 0''',
    "light-carrying-torch-gate")


# ---------------------------------------------------------------------------
# 3. light layer: "the room is already lit" rule
# ---------------------------------------------------------------------------
sub('''                local unlit = FindClosestValid(targets.candles, 2.35, "light", function(item)''',
'''                -- 04.3.10: "the room is already lit" rule. Lighting exists to make a dark place
                -- explorable and to help hunt for secrets - not to switch on every candle in a room
                -- that is already bright. With >= 2 burning fixtures that outnumber the unlit ones,
                -- only a fixture within arm's reach of the companion is worth finishing.
                local roomWellLit = (litLightsCount >= 3) and (litLightsCount >= 2 * unlitSafeCount)
                local unlit = FindClosestValid(targets.candles, 2.35, "light", function(item)''',
    "light-welllit-flag")

sub('''                if unlit and not ShouldYieldScarceProp(char, "light", unlit.n, unlitSafeCount) then''',
'''                local finishNearby = true
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
                if unlit and finishNearby and not ShouldYieldScarceProp(char, "light", unlit.n, unlitSafeCount) then''',
    "light-welllit-rule")


# ---------------------------------------------------------------------------
# 4. torch: equip must be verified in a hand of THIS character
# ---------------------------------------------------------------------------
sub('''    function FieldTorchSystem.equipSilent(char, itemUuid)
        if not char or not itemUuid or not Osi.Equip then return false end
        if Osi.Exists and Osi.Exists(itemUuid) ~= 1 then return false end
        FieldTorchSystem.internalEquipGuard = true
        local ok5 = pcall(Osi.Equip, char, itemUuid, 1, 0, 0)
        local equipped = (Osi.IsEquipped and Osi.IsEquipped(itemUuid) == 1)
        if (not ok5 or not equipped) then
            pcall(Osi.Equip, char, itemUuid)
            equipped = (Osi.IsEquipped and Osi.IsEquipped(itemUuid) == 1)
        end
        FieldTorchSystem.internalEquipGuard = false
        return equipped
    end''',
'''    -- 04.3.10: which hand of THIS character holds the item? Osi.IsEquipped(item) only says that the
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
    end''',
    "equip-verified-in-hand")


# ---------------------------------------------------------------------------
# 5. torch: never forget a companion who is still holding our torch
# ---------------------------------------------------------------------------
sub('''        local map = FieldTorchSystem.ensureStorage()
        local st = cleanKey and map[cleanKey] or nil
        if not st then return false end

        map[cleanKey] = nil
        FieldTorchSystem.brightSince = 0
        FieldTorchSystem.darkSince = 0

        local comp = FieldTorchSystem.resolvePartyCharByKey(cleanKey)
        if not comp or (Osi.Exists and Osi.Exists(comp) ~= 1) then
            return false
        end''',
'''        local map = FieldTorchSystem.ensureStorage()
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
        FieldTorchSystem.darkSince = 0''',
    "restore-resolve-first")


# ---------------------------------------------------------------------------
# 6. torch: cheap distance filter before the engine call
# ---------------------------------------------------------------------------
sub('''            for _, item in ipairs(LocalSpatialIndex.items) do
                local u = item.u
                if u and Osi.Exists(u) == 1 then
                    local dxH, dyH, dzH = item.x - hx, math.abs(item.y - hy), item.z - hz
                    local dSqH = dxH * dxH + dzH * dzH
                    local dxB, dyB, dzB = item.x - bx, math.abs(item.y - by), item.z - bz
                    local dSqB = dxB * dxB + dzB * dzB
                    local nl = item.lower or string.lower(item.name or item.n or "")''',
'''            local items = LocalSpatialIndex.items
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
                    local nl = item.lower or string.lower(item.name or item.n or "")''',
    "scan-distance-first")


# ---------------------------------------------------------------------------
# 7. torch: do not throw away the saved state on our own (asynchronous) equip event
# ---------------------------------------------------------------------------
sub('''        if st.torchUuid and SameEntity(itemUuid, st.torchUuid) then
            return
        end
        -- Player manually equipped a weapon/shield on the torchbearer -> respect their choice and clear saved state!
        map[key] = nil''',
'''        if st.torchUuid and SameEntity(itemUuid, st.torchUuid) then
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
        map[key] = nil''',
    "torch-equip-event-grace")


# ---------------------------------------------------------------------------
# 8. diagnostics: !ambient_torch
# ---------------------------------------------------------------------------
sub('''Ext.RegisterConsoleCommand("ambient_seats", function()''',
'''Ext.RegisterConsoleCommand("ambient_torch", function()
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

Ext.RegisterConsoleCommand("ambient_seats", function()''',
    "console-ambient_torch")

open(sys.argv[2], "w", encoding="utf-8").write(src)
print("applied %d patches: %s" % (len(applied), ", ".join(applied)))
