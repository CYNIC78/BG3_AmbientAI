#!/usr/bin/env python3
"""Build 04.3.9 - SEAT TIMEOUT POLISH + SLOW-TICK PROFILER

Everything here comes from the 04.3.8 playtest log:

  1. "[SEAT] could not reach FUR_Dungeon_Bench_Stone_C_029 -> cooldown 300s (kept)"
     followed one line later by "sits on <the same bench> (dist=1.10)".
     The walk action hit its 25 s limit while the companion was already standing next to
     the bench, and the timeout banned a perfectly good seat for 5 minutes. Now the timeout
     checks the real distance first: if the companion is in reach we simply proceed to the
     sit (the repose verification decides the rest) and nothing is blacklisted.

  2. The light trace shows "moving=false" while the distance is clearly going down:
     Osi.IsMoving does not see AI-driven CharacterMoveToPosition movement on this engine.
     The sit preparation used to wait for "not moving" - now it only waits briefly and then
     goes ahead, so an IsMoving that is stuck on can not delay a sit either.

  3. "Dispatching user function call (BootstrapServer.lua:2489) took 846.76 ms":
     a queue poll blocked for almost a second. We cannot profile that from here, so the poll
     now measures its own phases (abort check / action completion / next action) and logs a
     line whenever one of them takes longer than 120 ms. That turns the next playtest log
     into a pinpoint answer.

Usage: python3 tools/patch_slowtick.py <in.lua> <out.lua>
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
# 1. a walk timeout while already standing next to the seat is not a failure
# ---------------------------------------------------------------------------
sub('''        onTimeout = function(char)
            Blacklist[chairUuid] = Ext.Utils.MonotonicTime() + 300000
            AmbientSeat.hardBlacklist[chairUuid] = true
            Log("[SEAT] could not reach " .. AmbientSeat.tplName(chairUuid) .. " -> cooldown 300s (kept)")''',
'''        onTimeout = function(char)
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
            Log("[SEAT] could not reach " .. AmbientSeat.tplName(chairUuid) .. " -> cooldown 300s (kept)")''',
    "timeout-reach-check")


# ---------------------------------------------------------------------------
# 2. do not wait long for Osi.IsMoving - it does not report AI walks
# ---------------------------------------------------------------------------
sub('''    if Osi.IsMoving and Osi.IsMoving(char) == 1 then
        Ext.Timer.WaitFor(250, function()
            if not IsOsirisReady() then return end
            AmbientSeat.beginSit(char, chairUuid, tpl, h, attempt + 1)
        end)
        return
    end''',
'''    -- 04.3.9: Osi.IsMoving does not see AI-driven CharacterMoveToPosition walks on every
    -- engine build (the playtest log shows moving=false while the companion is walking).
    -- Give it a short, bounded benefit of the doubt instead of a hard gate.
    if attempt < 4 and Osi.IsMoving and Osi.IsMoving(char) == 1 then
        Ext.Timer.WaitFor(250, function()
            if not IsOsirisReady() then return end
            AmbientSeat.beginSit(char, chairUuid, tpl, h, attempt + 1)
        end)
        return
    end''',
    "ismoving-bounded")


# ---------------------------------------------------------------------------
# 3. slow-tick profiler around the queue poll
# ---------------------------------------------------------------------------
sub('''function ActionQueue:waitForCompletion()
    self.timerId = nil
    local abortNow, reason = self:shouldAbort()
    if abortNow then
        self:abort(reason)
        return
    end''',
'''-- 04.3.9: BG3SE warns about a single timer callback taking hundreds of ms
-- ("Dispatching user function call ... took 846.76 ms"). Measure the poll phases so the
-- next log says exactly which part is slow instead of guessing.
ActionQueue.stats = ActionQueue.stats or { slow = 0, worst = 0, worstPhase = "-" }

local function TickPhase(t0, phase, actionName)
    local dt = Ext.Utils.MonotonicTime() - t0
    if dt >= 120 then
        ActionQueue.stats.slow = ActionQueue.stats.slow + 1
        if dt > (ActionQueue.stats.worst or 0) then
            ActionQueue.stats.worst = dt
            ActionQueue.stats.worstPhase = phase
        end
        Log(string.format("[PERF] slow queue tick: %s took %dms (action=%s, slowTicks=%d)",
            tostring(phase), math.floor(dt), tostring(actionName or "-"), ActionQueue.stats.slow))
    end
    return dt
end

function ActionQueue:waitForCompletion()
    self.timerId = nil
    local tPhase = Ext.Utils.MonotonicTime()
    local abortNow, reason = self:shouldAbort()
    TickPhase(tPhase, "shouldAbort", self.currentAction and self.currentAction.name)
    if abortNow then
        self:abort(reason)
        return
    end''',
    "tick-profiler-head")

sub('''        if not earlyDone and (now - action.startTime < action.duration) then
            self.timerId = Ext.Timer.WaitFor(200, function()
                self:waitForCompletion()
            end)
            return''',
'''        if not earlyDone and (now - action.startTime < action.duration) then
            TickPhase(tPhase, "completion(" .. tostring(action.name) .. ")", action.name)
            self.timerId = Ext.Timer.WaitFor(200, function()
                self:waitForCompletion()
            end)
            return''',
    "tick-profiler-completion")

sub('''                    local isLightSeq = (self.activityTag == "light")''',
'''                    TickPhase(tPhase, "stall-watchdog(" .. tostring(action.name) .. ")", action.name)
                    local isLightSeq = (self.activityTag == "light")''',
    "tick-profiler-timeout")

sub('''    local compOk, compRes = pcall(action.completion, self.character)''',
'''    local compOk, compRes = pcall(action.completion, self.character)
    TickPhase(tPhase, "completion(" .. tostring(action.name) .. ")", action.name)''',
    "tick-profiler-completion2")


# ---------------------------------------------------------------------------
# 4. successful repose clears the hard ban on that seat (it obviously works)
# ---------------------------------------------------------------------------
sub('''            if AmbientSeat.isSeated(char) then
                finished = true
                AmbientSeat.lastSit[key] = { result = "seated", tpl = tpl, dist = h, at = Ext.Utils.MonotonicTime() }
                return
            end''',
'''            if AmbientSeat.isSeated(char) then
                finished = true
                AmbientSeat.lastSit[key] = { result = "seated", tpl = tpl, dist = h, at = Ext.Utils.MonotonicTime() }
                if AmbientSeat.hardBlacklist then AmbientSeat.hardBlacklist[chairUuid] = nil end
                return
            end''',
    "clear-hardban-on-success")


# ---------------------------------------------------------------------------
# 5. expose the profiler in the console
# ---------------------------------------------------------------------------
sub('''    Ext.Utils.Print(string.format(
            "  -> rest-reminder lines: %s | last speaker=%s",''',
'''    Ext.Utils.Print(string.format(
            "  -> queue ticks: slow(>120ms)=%d worst=%dms in %s",
            (ActionQueue.stats and ActionQueue.stats.slow) or 0,
            (ActionQueue.stats and ActionQueue.stats.worst) or 0,
            tostring(ActionQueue.stats and ActionQueue.stats.worstPhase or "-")))
    Ext.Utils.Print(string.format(
            "  -> rest-reminder lines: %s | last speaker=%s",''',
    "diag-perf-line")

open(sys.argv[2], "w", encoding="utf-8").write(src)
print("applied %d patches: %s" % (len(applied), ", ".join(applied)))
