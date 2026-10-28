#!/usr/bin/env python3
"""AmbientAI 04.3.6 "sittable seats only" patch.

Applies on top of the 04.3.5 output (patch_light_repair -> patch_light_walk -> patch_sit_standup).

Reported symptom: "Gale sat on a bench several metres away - he just vanished, and
reappeared when I moved."

Why it can happen (all silent in 04.3.5):
  1. The seat target is picked with FindFirstValid() over the whole scan radius (12 m).
     The winner is whatever the spatial sweep saw first, so a companion can walk - and
     sit - on a bench on the other side of the room, out of the player's view.
  2. Osi.SitOnEntity is a native Repose: it *aligns the character to the socket of the
     furniture*. Calling it when the companion is not actually next to the seat snaps
     him onto it (looks like a vanish / teleport).
  3. Nothing verified that the repose really happened, and the SitOnSeat completion
     accepted "close enough + not moving" as success - so a failed sit left the companion
     in limbo: follow block ON, no repose, no blacklist.

Fix: pick the CLOSEST valid seat, cap it to the host's vicinity, gate the sit on real
proximity, require an engine-confirmed repose, and back out + blacklist if the pose
never started.

Run:  python3 tools/patch_seat_pick.py [in.lua] [out.lua]
"""
import sys

SRC = sys.argv[1] if len(sys.argv) > 1 else "unpacked_fixed/Mods/AmbientAI/ScriptExtender/Lua/BootstrapServer.lua"
DST = sys.argv[2] if len(sys.argv) > 2 else "unpacked_fixed/Mods/AmbientAI/ScriptExtender/Lua/BootstrapServer.lua"
s = open(SRC, encoding="utf-8").read()
n0 = len(s)

# ---------------------------------------------------------------------------
# 1. Seating helpers on AmbientSeat
# ---------------------------------------------------------------------------
OLD_SEAT_END = '''-- Public gate: every "unlock" request in the mod goes through here
function SetAmbientSeatFollowLock(char, locked)'''

NEW_SEAT_HELPERS = r'''-- ---------------------------------------------------------------------------
-- Build 04.3.6: seat picking / sitting with verification
-- ---------------------------------------------------------------------------
AmbientSeat.SIT_MAX_H = 2.2      -- m: never call SitOnEntity from further away (it snaps!)
AmbientSeat.SIT_MAX_V = 1.4
AmbientSeat.SEAT_HOST_RADIUS = 6.0  -- m: only sit on seats near the player's anchor
AmbientSeat.lastSit = {}         -- cleanUuid -> { result, tpl, dist, at }

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

    SetSeatFollowFlagRaw(char, true)
    if Osi.SitOnEntity then
        pcall(Osi.SitOnEntity, char, chairUuid)
    elseif Osi.Use then
        pcall(Osi.Use, char, chairUuid, "")
    end
    AmbientSeat.lastSit[key] = { result = "started", tpl = tpl, dist = h, at = now }
    Log(string.format("[SEAT] %s sits on %s (dist=%.2f)", tostring(char), tpl, h))

    -- Verify: the engine has to report an actual repose, otherwise the pose never took
    Ext.Timer.WaitFor(1200, function()
        if not IsOsirisReady() then return end
        if Osi.Exists(char) ~= 1 then return end
        if AmbientSeat.isSeated(char) then
            AmbientSeat.lastSit[key] = { result = "seated", tpl = tpl, dist = h, at = Ext.Utils.MonotonicTime() }
            return
        end
        local last = AmbientSeat.lastSit[key]
        if last and last.result == "seated" then return end
        AmbientSeat.lastSit[key] = { result = "no_repose", tpl = tpl, dist = h, at = Ext.Utils.MonotonicTime() }
        Blacklist[chairUuid] = Ext.Utils.MonotonicTime() + 300000
        Log(string.format("[SEAT] %s did NOT enter repose on %s -> standing back up and avoiding that seat",
            tostring(char), tpl))
        -- Never leave a companion half-sat with the follow block on (invisible / unresponsive).
        -- NOTE: StandUpFromFurniture() is a `local` declared further down the file, so it is not
        -- in scope here - do the dismount inline instead (EndRepose is harmless if no pose exists).
        pcall(function() if Osi.EndRepose then Osi.EndRepose(char) end end)
        SetSeatFollowFlagRaw(char, false)
        AmbientSeat.pendingRelease[CleanUuid(char) or char] = nil
        AmbientSeat.inFlight[CleanUuid(char) or char] = nil
        local q = ActiveQueues[char]
        if q then q.queue = {} end
    end)
    return true
end

-- Public gate: every "unlock" request in the mod goes through here
function SetAmbientSeatFollowLock(char, locked)'''

assert OLD_SEAT_END in s, "SetAmbientSeatFollowLock anchor not found"
s = s.replace(OLD_SEAT_END, NEW_SEAT_HELPERS, 1)

# ---------------------------------------------------------------------------
# 2. CreateSitSequence: log the pick, tighten the walk, verified sit
# ---------------------------------------------------------------------------
OLD_HEAD = '''local function CreateSitSequence(character, chairUuid)
    local queue = ActiveQueues[character]
    if not queue then return end
    queue.activityTag = "chair"

    queue:enqueue({
        name = "WalkNearSeat",
        execute = function(char)
            local tx, ty, tz = GetSmartApproachPosition(char, chairUuid, 1.2)
            if tx and IsSafeWorldObject(chairUuid, "seat") then
                Osi.CharacterMoveToPosition(char, tx, ty, tz, "Walk", "")
            else
                queue.queue = {}
            end
        end,
        completion = function(char)
            if #queue.queue == 0 then return true end
            return StateChecks.isWithinReach(char, chairUuid, 2.55, 2.2) and Osi.IsMoving(char) == 0
        end,
    })'''

NEW_HEAD = '''local function CreateSitSequence(character, chairUuid)
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

    queue:enqueue({
        name = "WalkNearSeat",
        execute = function(char)
            local tx, ty, tz = GetSmartApproachPosition(char, chairUuid, 1.1)
            if tx and IsSafeWorldObject(chairUuid, "seat") then
                Osi.CharacterMoveToPosition(char, tx, ty, tz, "Walk", "")
            else
                Log("[SEAT] no approach point for " .. AmbientSeat.tplName(chairUuid) .. " -> seat dropped for now")
                Blacklist[chairUuid] = Ext.Utils.MonotonicTime() + 120000
                queue.queue = {}
            end
        end,
        completion = function(char)
            if #queue.queue == 0 then return true end
            return StateChecks.isWithinReach(char, chairUuid, 2.2, 1.6) and Osi.IsMoving(char) == 0
        end,
        onTimeout = function(char)
            Blacklist[chairUuid] = Ext.Utils.MonotonicTime() + 120000
            Log("[SEAT] could not reach " .. AmbientSeat.tplName(chairUuid) .. " -> cooldown 120s")
            StandUpFromFurniture(char)
        end,
        duration = 25000,
    })'''

assert OLD_HEAD in s, "CreateSitSequence head not found"
s = s.replace(OLD_HEAD, NEW_HEAD, 1)

OLD_SIT_EXEC = '''        name = "SitOnSeat",
        execute = function(char)
            startedAt = Ext.Utils.MonotonicTime()
            if IsSafeWorldObject(chairUuid, "seat") then
                -- Prevent DefaultPartyMember FollowOwnerOrLeader() from yanking grouped companions
                -- off the bench the millisecond SitOnEntity / Osi.Use completes!
                SetAmbientSeatFollowLock(char, true)
                if Osi.SitOnEntity and ((not Osi.CanSitOn) or Osi.CanSitOn(chairUuid) == 1) then
                    Osi.SitOnEntity(char, chairUuid)
                else
                    Osi.Use(char, chairUuid, "")
                end
            else
                queue.queue = {}
            end
        end,
        completion = function(char)
            if #queue.queue == 0 then return true end
            local elapsed = Ext.Utils.MonotonicTime() - startedAt
            if elapsed < 900 then return false end
            if (Osi.IsReposedSitting and Osi.IsReposedSitting(char) == 1)
                or (Osi.IsReposed and Osi.IsReposed(char) == 1) then
                return true
            end
            local d = Osi.GetDistanceTo(char, chairUuid)
            return elapsed >= 1800 and d and d < 2.3 and Osi.IsMoving(char) == 0
        end,'''

NEW_SIT_EXEC = '''        name = "SitOnSeat",
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
        end,''' 

assert OLD_SIT_EXEC in s, "SitOnSeat execute/completion not found"
s = s.replace(OLD_SIT_EXEC, NEW_SIT_EXEC, 1)

# ---------------------------------------------------------------------------
# 3. Scheduler: closest seat + host-vicinity cap
# ---------------------------------------------------------------------------
OLD_PICK = '''            local foundSeat = false
            if #targets.chairs > 0 and not inDanger and not carryingFieldTorch then
                local chair = FindFirstValid(targets.chairs, 2.2, "seat", function(item)
                    local tx = GetSmartApproachPosition(char, item.u, 1.0)
                    return tx ~= nil
                end)'''

NEW_PICK = '''            local foundSeat = false
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
                end)'''

assert OLD_PICK in s, "chair pick block not found"
s = s.replace(OLD_PICK, NEW_PICK, 1)

# ---------------------------------------------------------------------------
# 4. !ambient_seats: include the last sit result
# ---------------------------------------------------------------------------
OLD_DIAG = '''        Ext.Utils.Print(string.format(" %-46s seated=%-5s followBlock=%-5s pendingRelease=%-14s queue=%s",
            tostring(c), tostring(seated), tostring(lock), tostring(pending or "-"),
            tostring(q and q.isProcessing and (q.activityTag or "?") or "idle")))'''
NEW_DIAG = '''        local last = AmbientSeat.lastSit[key]
        Ext.Utils.Print(string.format(" %-46s seated=%-5s followBlock=%-5s pendingRelease=%-13s queue=%-10s lastSit=%s",
            tostring(c), tostring(seated), tostring(lock), tostring(pending or "-"),
            tostring(q and q.isProcessing and (q.activityTag or "?") or "idle"),
            last and string.format("%s on %s (%s)", tostring(last.result), tostring(last.tpl),
                last.dist and string.format("%.2fm", last.dist) or "?") or "-"))'''
assert OLD_DIAG in s
s = s.replace(OLD_DIAG, NEW_DIAG, 1)

open(DST, "w", encoding="utf-8").write(s)
print(f"04.3.6 seat pick/sit patch: {SRC} ({n0}) -> {DST} ({len(s)})")
