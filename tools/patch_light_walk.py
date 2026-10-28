#!/usr/bin/env python3
"""AmbientAI 04.3.4 "light walk / arrival" patch.

Applies on top of the 04.3.3 output (run patch_light_repair.py first).

Fixes the failure visible in the user's log: the queue logs `started: GoToSconce`
and then dies silently - never reaching `TurnToSconce` / `LightIt`, and never
writing an `aborting sequence` line. That leaves exactly three silent exits in
the code: (1) no valid approach point, (2) the movement stall watchdog clearing
the queue, (3) an arrival radius (2.85 / 2.9 m) that is TIGHTER than the radius
the ignition itself allows (4.2 / 3.2 m) - so a companion that stops 3.5 m away
next to a table never "arrives", stops making progress, and gets blacklisted for
30 minutes.

This patch:
  * traces every stage of the light sequence (LightTrace),
  * builds up to 9 approach points (3 distances x 3 directions) and validates
    each one on the AI grid instead of a single hard-coded 1.0 m point,
  * lets a stalled-but-close companion light the fixture from where it stands,
  * caps light-related blacklists to 90 s (was 30 min in the shared watchdog),
  * adds `!ambient_light_probe` and `!ambient_light_trace` console commands.

Run:  python3 tools/patch_light_walk.py [in.lua] [out.lua]
"""
import sys, os, re

SRC = sys.argv[1] if len(sys.argv) > 1 else "unpacked_fixed/Mods/AmbientAI/ScriptExtender/Lua/BootstrapServer.lua"
DST = sys.argv[2] if len(sys.argv) > 2 else "unpacked_fixed/Mods/AmbientAI/ScriptExtender/Lua/BootstrapServer.lua"
s = open(SRC, encoding="utf-8").read()
n0 = len(s)

# ---------------------------------------------------------------------------
# 1. LightTrace module + approach point builder + arrival constants.
#    Inserted right before CreateTorchbearerSequence.
# ---------------------------------------------------------------------------
ANCHOR = "local function CreateTorchbearerSequence(character, sconceUuid, extraClusterUuids)"
assert ANCHOR in s

MODULE = r'''-- ============================================================================
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

'''

s = s.replace(ANCHOR, MODULE + ANCHOR, 1)

# ---------------------------------------------------------------------------
# 2. Replace GoToSconce execute/completion with the traced, tolerant version
# ---------------------------------------------------------------------------
OLD_GO = '''    queue:enqueue({
        name = "GoToSconce",
        precondition = function(char) return StateChecks.isIdle(char) end,
        execute = function(char)
            local tx, ty, tz = GetSmartApproachPosition(char, sconceUuid, 1.0)
            if tx and IsSafeWorldObject(sconceUuid, "light") then
                Osi.CharacterMoveToPosition(char, tx, ty, tz, "Walk", "")
            else
                -- Was a hard 30-minute blacklist: one bad navmesh snap kept the room dark.
                Blacklist[sconceUuid] = Ext.Utils.MonotonicTime() + 180000
                queue.queue = {}
            end
        end,
        completion = function(char)
            if #queue.queue == 0 then return true end
            return StateChecks.isWithinReach(char, sconceUuid, 2.85, 2.9) and Osi.IsMoving(char) == 0
        end,
    })
'''

NEW_GO = '''    queue:enqueue({
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
'''

assert OLD_GO in s, "GoToSconce block not found"
s = s.replace(OLD_GO, NEW_GO, 1)

# ---------------------------------------------------------------------------
# 3. BinLight helper: single place that records why a fixture was dropped
# ---------------------------------------------------------------------------
BIN_ANCHOR = "Ext.RegisterConsoleCommand(\"ambient_lights\""
BIN = '''-- Build 04.3.4: every "give up" on a light fixture goes through here, so the console
-- always has an explanation (the 04.3.2/04.3.3 code path could drop a fixture silently).
BinLight = {
    unsafe = function(uuid, tpl)
        Blacklist[uuid] = Ext.Utils.MonotonicTime() + LIGHT_TARGET_COOLDOWN
        LightTrace.line("skip", "%s (%s) failed IsSafeWorldObject('light') at walk time -> %ds",
            tostring(tpl), tostring(uuid), math.floor(LIGHT_TARGET_COOLDOWN / 1000))
    end,
}

'''
assert BIN_ANCHOR in s
s = s.replace(BIN_ANCHOR, BIN + BIN_ANCHOR, 1)

# ---------------------------------------------------------------------------
# 4. Movement stall watchdog: light-aware cooldown + trace line
# ---------------------------------------------------------------------------
OLD_STALL = '''                elseif (now - action._lastMoveMs) >= 2800 then
                    if self.currentTarget then
                        Blacklist[self.currentTarget] = now + 1800000
                    end
                    PurgeCharacterOsiris(self.character)
                    self.queue = {}
                    self:processNext()
                    return
                end'''
NEW_STALL = '''                elseif (now - action._lastMoveMs) >= 2800 then
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
                end'''
assert OLD_STALL in s, "stall watchdog block not found"
s = s.replace(OLD_STALL, NEW_STALL, 1)

# ---------------------------------------------------------------------------
# 5. Ignition radius aligned with the arrival radius + entry trace
# ---------------------------------------------------------------------------
OLD_IGNITE_GUARD = '''        if not StateChecks.isWithinReach(char, targetUuid, 4.2, 3.2) then
            Blacklist[targetUuid] = nowTs + math.random(6000, 12000)
            Log("LightIt skipped: out of reach " .. tostring(targetUuid))
            return false
        end'''
NEW_IGNITE_GUARD = '''        local okReach, hDist, vDelta = LightTrace.metrics(char, targetUuid)
        if not (okReach and hDist <= LIGHT_IGNITE_H and vDelta <= LIGHT_IGNITE_V) then
            Blacklist[targetUuid] = nowTs + math.random(8000, 15000)
            LightTrace.line("LightIt", "skipped %s: out of reach (dist=%.2f dy=%.2f, limit %.1f/%.1f)",
                LightTrace.tpl(targetUuid), hDist, vDelta, LIGHT_IGNITE_H, LIGHT_IGNITE_V)
            return false
        end
        LightTrace.line("LightIt", "igniting %s (%s) from dist=%.2f dy=%.2f",
            LightTrace.tpl(targetUuid), tostring(targetUuid), hDist, vDelta)'''
assert OLD_IGNITE_GUARD in s
s = s.replace(OLD_IGNITE_GUARD, NEW_IGNITE_GUARD, 1)

# ---------------------------------------------------------------------------
# 6. Expose scheduler light state for the probe command
# ---------------------------------------------------------------------------
OLD_NLT = "                    NextLightTime = (unlitSafeCount >= 1) and (now + 900) or (now + (isDungeon and 7500 or 10500))"
NEW_NLT = """                    NextLightTime = (unlitSafeCount >= 1) and (now + 900) or (now + (isDungeon and 7500 or 10500))
                    AmbientLightState = {
                        now = now, nextLightTime = NextLightTime,
                        unlitSafe = unlitSafeCount, lit = litLightsCount,
                        roomDark = roomIsDark, zone = zone and zone.mode or "?",
                        maxLighters = maxLighters, activeLighters = activeLighters,
                    }"""
assert OLD_NLT in s
s = s.replace(OLD_NLT, NEW_NLT, 1)

# Also record the state when the light layer is skipped entirely (gate closed)
OLD_GATE = "        if not charAssigned and Config.LightSources and now >= NextLightTime then"
NEW_GATE = """        if not charAssigned and Config.LightSources and now < NextLightTime
            and (now - (LightTrace.lastGateLog or 0)) >= 15000 then
            LightTrace.lastGateLog = now
            LightTrace.line("gate", "light layer cooling down: %.1fs left (unlit=%s lit=%s roomDark=%s)",
                (NextLightTime - now) / 1000.0, tostring(unlitSafeCount), tostring(litLightsCount), tostring(roomIsDark))
        end
        if not charAssigned and Config.LightSources and now >= NextLightTime then"""
assert OLD_GATE in s
s = s.replace(OLD_GATE, NEW_GATE, 1)

# ---------------------------------------------------------------------------
# 7. Console commands: probe + trace
# ---------------------------------------------------------------------------
APPEND = r'''

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
'''

s = s.rstrip("\n") + APPEND
open(DST, "w", encoding="utf-8").write(s)
print(f"04.3.4 walk/arrival patch: {SRC} ({n0}) -> {DST} ({len(s)})")
