#!/usr/bin/env python3
"""Build 04.3.8 - SIT ORDER FIX

Root cause of "Gale did not sit down any more" (log from 04.3.7):
    SeatTiredRemark  ->  SitOnSeat  ->  "sits on X (dist=1.10)"  ->  "did NOT enter repose"

CreateSitSequence played the tired REMARK *before* the sit. When that remark turns into an
overhead PAD (a real dialog), the character is still "in dialog" when AmbientSeat.sit calls
Osi.SitOnEntity - the engine does not repose a talking character, so the pose never takes,
the 1.2 s check declares failure, the companion stands up and blacklists a perfectly good bench.

Fixes:
  1. Order: walk -> SIT -> (only if the repose really took) remark -> relax -> stand up.
  2. AmbientSeat.sit waits for "not talking / not moving" (bounded) before calling SitOnEntity.
  3. Verification is staggered (0.5 / 1.2 / 2.2 / 3.2 s) instead of a single 1.2 s look, so a
     slow repose transition is no longer punished, and a real failure now logs WHY
     (distance, moving, talking, engine CanSitOn, line of sight).
  4. A bench the companion could not reach is blacklisted for 300 s and that mark is no longer
     wiped by an unrelated queue abort (that is how Gale ended up walking to the very bench the
     previous companion had just failed to reach).

Usage: python3 tools/patch_seat_verify.py <in.lua> <out.lua>
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
# 1. state table for hard (reach-timeout) blacklists
# ---------------------------------------------------------------------------
sub('''AmbientSeat = {
    pendingRelease = {},   -- cleanUuid -> reason
    inFlight = {},         -- cleanUuid -> true while a stand-up cascade is running
    releaseLog = {},''',
'''AmbientSeat = {
    pendingRelease = {},   -- cleanUuid -> reason
    inFlight = {},         -- cleanUuid -> true while a stand-up cascade is running
    hardBlacklist = {},    -- map[targetUuid] = true: NOT cleared by an unrelated queue abort
    releaseLog = {},''',
    "hard-blacklist-table")


# ---------------------------------------------------------------------------
# 2. "is this character busy talking right now?"
# ---------------------------------------------------------------------------
sub('''function AmbientSeat.tplName(uuid)''',
'''-- A character that is in a dialog / overhead PAD can NOT enter Repose. The engine does not
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

function AmbientSeat.tplName(uuid)''',
    "is-talking")


# ---------------------------------------------------------------------------
# 3. sit() = validation only, then a deferred, dialog-aware start + staggered verify
# ---------------------------------------------------------------------------
OLD_SIT = '''    SetSeatFollowFlagRaw(char, true)
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
end'''

NEW_SIT = '''    -- 04.3.8: do not ask for a pose while the character is still finishing a bark/PAD or a step
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

    if Osi.IsMoving and Osi.IsMoving(char) == 1 then
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
end'''

sub(OLD_SIT, NEW_SIT, "sit-workflow")


# ---------------------------------------------------------------------------
# 4. sequence order: sit first, remark only after a real repose
# ---------------------------------------------------------------------------
OLD_REMARK = '''    queue:enqueue({
        name = "SeatTiredRemark",
        execute = function(char)
            FaceTarget(char, chairUuid)
            TryPlayCompanionActionVoice(char, "rest_sit")
        end,
        completion = function(char)
            return not IsCharacterSpeakingBark(char, true)
        end,
        duration = 2600,
    })

    local startedAt = 0'''
NEW_REMARK = '''    local startedAt = 0'''
sub(OLD_REMARK, NEW_REMARK, "remark-moved-out")

sub('''    queue:enqueue({
        name = "RelaxingOnSeat",
        execute = function()
            relaxStartedAt = Ext.Utils.MonotonicTime()
        end,''',
'''    -- 04.3.8: the tired remark now comes AFTER the pose is confirmed. Before, the remark could
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
        end,''',
    "remark-after-sit")


# ---------------------------------------------------------------------------
# 5. an unreachable bench stays blacklisted
# ---------------------------------------------------------------------------
sub('''        onTimeout = function(char)
            Blacklist[chairUuid] = Ext.Utils.MonotonicTime() + 120000
            Log("[SEAT] could not reach " .. AmbientSeat.tplName(chairUuid) .. " -> cooldown 120s")''',
'''        onTimeout = function(char)
            Blacklist[chairUuid] = Ext.Utils.MonotonicTime() + 300000
            AmbientSeat.hardBlacklist[chairUuid] = true
            Log("[SEAT] could not reach " .. AmbientSeat.tplName(chairUuid) .. " -> cooldown 300s (kept)")''',
    "timeout-blacklist")

sub('''                Log("[SEAT] no approach point for " .. AmbientSeat.tplName(chairUuid) .. " -> seat dropped for now")
                Blacklist[chairUuid] = Ext.Utils.MonotonicTime() + 120000''',
'''                Log("[SEAT] no approach point for " .. AmbientSeat.tplName(chairUuid) .. " -> seat dropped for now")
                Blacklist[chairUuid] = Ext.Utils.MonotonicTime() + 300000
                AmbientSeat.hardBlacklist[chairUuid] = true''',
    "no-approach-blacklist")

sub('''        if abortedTarget and Blacklist[abortedTarget] and (Blacklist[abortedTarget] - tNow) < 900000 then
            Blacklist[abortedTarget] = nil
        end
        if abortedClusters then
            for _, cu in ipairs(abortedClusters) do
                if Blacklist[cu] and (Blacklist[cu] - tNow) < 900000 then
                    Blacklist[cu] = nil
                end
            end
        end''',
'''        -- 04.3.8: do not wipe a "could not reach this seat" mark when the walk was aborted for an
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
        end''',
    "abort-keep-blacklist")


# ---------------------------------------------------------------------------
# 6. diagnostics
# ---------------------------------------------------------------------------
sub("        local last = AmbientSeat.lastSit[key]\n        Ext.Utils.Print(string.format(\" %-46s",
"""        local last = AmbientSeat.lastSit[key]
        local lastTxt = "-"
        if last then
            lastTxt = string.format("%s on %s (%s)", tostring(last.result), tostring(last.tpl),
                last.dist and string.format("%.2fm", last.dist) or "?")
            if last.why then lastTxt = lastTxt .. " [" .. tostring(last.why) .. "]" end
        end
        Ext.Utils.Print(string.format(" %-46s""",
    "diag-seats-why-prep")

sub('''                last.dist and string.format("%.2fm", last.dist) or "?") or "-"))''',
    '''                lastTxt))''',
    "diag-seats-why")

sub('''            last and string.format("%s on %s (%s)", tostring(last.result), tostring(last.tpl),
                lastTxt))''',
    '''            lastTxt))''',
    "diag-seats-why-arg")


open(sys.argv[2], "w", encoding="utf-8").write(src)
print("applied %d patches: %s" % (len(applied), ", ".join(applied)))
