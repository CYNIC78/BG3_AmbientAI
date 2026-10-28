#!/usr/bin/env python3
"""Applies the AmbientAI Build 04.3.3 "light ignition repair" patch to BootstrapServer.lua.

Run:  python3 tools/patch_light_repair.py <input.lua> <output.lua>
"""
import sys, os

SRC = sys.argv[1] if len(sys.argv) > 1 else "unpacked_original/Mods/AmbientAI/ScriptExtender/Lua/BootstrapServer.lua"
DST = sys.argv[2] if len(sys.argv) > 2 else "unpacked_fixed/Mods/AmbientAI/ScriptExtender/Lua/BootstrapServer.lua"

s = open(SRC, encoding="utf-8").read()
orig_len = len(s)

# ---------------------------------------------------------------------------
# 1. Replace IsLightSourceAlreadyLit with the verified state machine + module
# ---------------------------------------------------------------------------
OLD_ISLIT = '''local function IsLightSourceAlreadyLit(uuid)
    if not uuid then return false end
    local clean = CleanUuid(uuid) or uuid
    if ScavengeStats.litSet and ScavengeStats.litSet[clean] == true then
        return true
    end
    local ok, lit = pcall(function()
        if Osi.HasActiveStatus(uuid, "BURNING") == 1
            or Osi.HasActiveStatus(uuid, "MAG_LIGHT") == 1
            or Osi.HasActiveStatus(uuid, "LAMP") == 1
            or Osi.HasActiveStatus(uuid, "TORCH") == 1
        then
            return true
        end
        local e = Ext.Entity.Get(uuid)
        if e and e.GameplayLight ~= nil and e.GameplayLight.Active == true then
            return true
        end
        return false
    end)
    return ok and lit == true
end
'''

NEW_ISLIT = r'''-- ============================================================================
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
'''

assert OLD_ISLIT in s, "IsLightSourceAlreadyLit block not found"
s = s.replace(OLD_ISLIT, NEW_ISLIT, 1)

# ---------------------------------------------------------------------------
# 2. Replace the whole IgniteSingleFixture nested function
# ---------------------------------------------------------------------------
start_marker = "    local function IgniteSingleFixture(char, targetUuid, playVoice)"
end_marker = '\n    queue:enqueue({\n        name = "GoToSconce",'
i = s.index(start_marker)
j = s.index(end_marker, i)

NEW_IGNITE = r'''    local function IgniteSingleFixture(char, targetUuid, playVoice)
        if not targetUuid then return false end
        local nowTs = Ext.Utils.MonotonicTime()

        -- Never blacklist before the attempt (old bug: one bad frame hid a fixture for 30 minutes)
        if not StateChecks.isWithinReach(char, targetUuid, 4.2, 3.2) then
            Blacklist[targetUuid] = nowTs + math.random(6000, 12000)
            Log("LightIt skipped: out of reach " .. tostring(targetUuid))
            return false
        end
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
'''

s = s[:i] + NEW_IGNITE + s[j:]

# ---------------------------------------------------------------------------
# 3. Shorter cooldown when the approach point cannot be found (was 30 min)
# ---------------------------------------------------------------------------
OLD_APPROACH_FAIL = '''            else
                Blacklist[sconceUuid] = Ext.Utils.MonotonicTime() + 1800000
                queue.queue = {}
            end'''
NEW_APPROACH_FAIL = '''            else
                -- Was a hard 30-minute blacklist: one bad navmesh snap kept the room dark.
                Blacklist[sconceUuid] = Ext.Utils.MonotonicTime() + 180000
                queue.queue = {}
            end'''
assert OLD_APPROACH_FAIL in s
s = s.replace(OLD_APPROACH_FAIL, NEW_APPROACH_FAIL, 1)

# ---------------------------------------------------------------------------
# 4. Schedule a save re-arm on every session/level reset
# ---------------------------------------------------------------------------
OLD_RESET_TAIL = '''    HostLastActiveTime = Ext.Utils.MonotonicTime()
    SuppressPopupUntil = HostLastActiveTime + 5000
end'''
NEW_RESET_TAIL = '''    HostLastActiveTime = Ext.Utils.MonotonicTime()
    SuppressPopupUntil = HostLastActiveTime + 5000
    -- Build 04.3.3: fixtures lit by us in a previous session are re-armed a few seconds
    -- after the level/save finished loading (fixes "old saves stay dark").
    AmbientLightRepair.scheduleRearm(6000)
end'''
assert OLD_RESET_TAIL in s
s = s.replace(OLD_RESET_TAIL, NEW_RESET_TAIL, 1)

# ---------------------------------------------------------------------------
# 5. Console commands for in-game investigation
# ---------------------------------------------------------------------------
APPEND = r'''

-- ============================================================================
-- 11. LIGHT INVESTIGATION CONSOLE COMMANDS (Build 04.3.3)
--   !ambient_lights [radius]   - dump every indexed fixture + why it is skipped
--   !ambient_light_fix [radius]- force-ignite every dark fixture around the host
--   !ambient_light_reset       - clear blacklists + session/persistent light memory
-- ============================================================================
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
'''

s = s.rstrip("\n") + APPEND

os.makedirs(os.path.dirname(DST), exist_ok=True)
open(DST, "w", encoding="utf-8").write(s)
print(f"patched {SRC} ({orig_len} bytes) -> {DST} ({len(s)} bytes)")
