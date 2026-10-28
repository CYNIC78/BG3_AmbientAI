#!/usr/bin/env python3
"""Build 04.3.11 - SEAT WALK ARRIVAL + SLOW-POSE SAFETY + FULL QUEUE PROFILER

1. WalkNearSeat: arrival no longer depends on `Osi.IsMoving` alone. If the companion is already in
   reach but still flagged as moving, the walk counts as finished once the position has not changed
   for ~700 ms (the playtest log shows a companion standing 1.10 m from the bench for the whole 25 s
   timeout, then the 04.3.9 "late arrival" rescue sitting him down). The move order is re-issued
   (max 2 times) when the companion is still far away after 8 s - a party pull cancels AI moves.

2. SitOnSeat is the only STATIONARY action without a `duration`, so the movement stall watchdog
   applied to it: sit down, stand still for 2.8 s (that is the normal state!) -> the bench was
   blacklisted for 30 minutes, the character was purged and the queue emptied. It is now exempt.

3. Osi.FindValidPosition (approach-point navmesh query, up to 3 snap attempts per call, hundreds of
   ms in fragmented stone geometry) is cached for 2 s per (character, target, distance) and the
   cache is invalidated as soon as the character really moves.

4. The 04.3.9 profiler only covered the "action is still running" branch, so the BG3SE warnings
   ("Dispatching user function call ... took 2932 ms") were never attributed. Now every phase is
   measured - shouldAbort, completion, onTimeout/onComplete, next action, action body - and
   `!ambient_perf` prints the worst offender per phase. TickPhase is also moved above its users
   (it was declared after processNext/executeWithGuard, where a call would hit a nil global).

Usage: python3 tools/patch_sit_walk_perf.py <in.lua> <out.lua>
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
# 1. TickPhase: move the profiler above its call sites + per-phase stats
# ---------------------------------------------------------------------------
OLD_TICKPHASE = '''-- 04.3.9: BG3SE warns about a single timer callback taking hundreds of ms
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

'''

NEW_TICKPHASE = '''-- 04.3.9: BG3SE warns about a single timer callback taking hundreds of ms
-- ("Dispatching user function call ... took 846.76 ms"). Measure the poll phases so the
-- next log says exactly which part is slow instead of guessing.
-- 04.3.11: declared BEFORE processNext/executeWithGuard, which now call it as well (a local
-- declared further down would silently resolve to a nil global inside timer callbacks).
ActionQueue.stats = ActionQueue.stats or { slow = 0, worst = 0, worstPhase = "-" }

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

'''

# take the block out of its old position ...
sub(OLD_TICKPHASE, "", "tickphase-remove-old")
# ... and put the extended version in front of processNext
sub('''function ActionQueue:processNext()''', NEW_TICKPHASE + '''function ActionQueue:processNext()''',
    "tickphase-move-top")


# ---------------------------------------------------------------------------
# 2. profiler: cover every phase of the queue, not only "still running"
# ---------------------------------------------------------------------------
sub('''        local earlyDone = false
        if action.completion then
            local cOk, cRes = pcall(action.completion, self.character)
            if cOk and cRes then earlyDone = true end
        end
        if not earlyDone and (now - action.startTime < action.duration) then
            TickPhase(tPhase, "completion(" .. tostring(action.name) .. ")", action.name)
            self.timerId = Ext.Timer.WaitFor(200, function()
                self:waitForCompletion()
            end)
            return
        else
            if action.customAnim then
                self.playingCustomAnim = false
            end
            if not earlyDone and action.completion and action.onTimeout then
                pcall(action.onTimeout, self.character)
            elseif action.onComplete then
                pcall(action.onComplete, self.character)
            end
            self:processNext()
            return
        end''',
'''        local earlyDone = false
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
        end''',
    "profiler-completion-timeout-next")

sub('''    if not action.completion then
        if action.onComplete then pcall(action.onComplete, self.character) end
        self:processNext()
        return
    end''',
'''    if not action.completion then
        local tNoComp = Ext.Utils.MonotonicTime()
        if action.onComplete then pcall(action.onComplete, self.character) end
        self:processNext()
        TickPhase(tNoComp, "no-completion(" .. tostring(action.name) .. ") next", action.name)
        return
    end''',
    "profiler-no-completion-path")

sub('''function ActionQueue:executeWithGuard()
    self.timerId = nil
    local abortNow, reason = self:shouldAbort()''',
'''function ActionQueue:executeWithGuard()
    self.timerId = nil
    local tStart = Ext.Utils.MonotonicTime()
    local abortNow, reason = self:shouldAbort()''',
    "profiler-execute-start")

sub('''    local action = self.currentAction
    if not action then
        self:processNext()
        return
    end

    if action.precondition then''',
'''    local action = self.currentAction
    if not action then
        self:processNext()
        return
    end
    TickPhase(tStart, "start-prep(" .. tostring(action.name) .. ")", action.name)

    if action.precondition then''',
    "profiler-execute-prep")

sub('''    if self.currentAction.name and ConfigValues.Debug then
        Log(tostring(self.character) .. " started: " .. tostring(self.currentAction.name))
    end
    self:executeWithGuard()
end''',
'''    local stepNameForPerf = self.currentAction.name
    if stepNameForPerf and ConfigValues.Debug then
        Log(tostring(self.character) .. " started: " .. tostring(stepNameForPerf))
    end
    -- 04.3.11: the body of an action is where the engine calls live (CharacterMoveToPosition,
    -- SitOnEntity, Use, ToInventory, FindValidPosition...). Measure it too.
    local tBody = Ext.Utils.MonotonicTime()
    self:executeWithGuard()
    TickPhase(tBody, "body(" .. tostring(stepNameForPerf) .. ")", stepNameForPerf)
end''',
    "profiler-action-body")


# ---------------------------------------------------------------------------
# 3. WalkNearSeat: arrival without a hard dependency on Osi.IsMoving
# ---------------------------------------------------------------------------
sub('''    queue:enqueue({
        name = "WalkNearSeat",
        execute = function(char)
            local tx, ty, tz = GetSmartApproachPosition(char, chairUuid, 1.1)
            if tx and IsSafeWorldObject(chairUuid, "seat") then
                Osi.CharacterMoveToPosition(char, tx, ty, tz, "Walk", "")
            else
                Log("[SEAT] no approach point for " .. AmbientSeat.tplName(chairUuid) .. " -> seat dropped for now")
                Blacklist[chairUuid] = Ext.Utils.MonotonicTime() + 300000
                AmbientSeat.hardBlacklist[chairUuid] = true
                queue.queue = {}
            end
        end,
        completion = function(char)
            if #queue.queue == 0 then return true end
            return StateChecks.isWithinReach(char, chairUuid, 2.2, 1.6) and Osi.IsMoving(char) == 0
        end,''',
'''    -- 04.3.11: arrival bookkeeping for the walk below
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
        end,''',
    "walk-arrival-without-ismoving")


# ---------------------------------------------------------------------------
# 4. SitOnSeat is a STATIONARY action - the movement stall watchdog must not ban the chair
# ---------------------------------------------------------------------------
sub('''                elseif (now - action._lastMoveMs) >= 2800 then''',
'''                elseif (now - action._lastMoveMs) >= 2800
                    and not STALL_WATCHDOG_EXEMPT[action.name] then''',
    "stall-watchdog-exempt-guard")

sub('''function ActionQueue:waitForCompletion()
    self.timerId = nil''',
'''-- 04.3.11: actions that are SUPPOSED to stand still. Sitting is one of them: the companion stops at
-- the approach point and the repose blends, so "no movement for 2.8s" is the normal state, not a
-- stuck path. The watchdog used to treat it as a stall - the bench was blacklisted for 30 MINUTES,
-- the character was purged and the queue emptied (i.e. exactly "не сел, и скамья теперь плохая").
local STALL_WATCHDOG_EXEMPT = {
    SitOnSeat = true,
}

function ActionQueue:waitForCompletion()
    self.timerId = nil''',
    "stall-watchdog-exempt-table")


# ---------------------------------------------------------------------------
# 5. navmesh approach queries: cache instead of hammering Osi.FindValidPosition
# ---------------------------------------------------------------------------
sub('''local function GetSmartApproachPosition(sourceUuid, targetUuid, distance)''',
    '''local function GetSmartApproachPositionUncached(sourceUuid, targetUuid, distance)''',
    "approach-uncached")

sub('''-- ============================================================================
-- 4. PERSONALITY MATRIX & CONTEXT-SEPARATED ANIMATION POOLS''',
'''-- 04.3.11: Osi.FindValidPosition is a navmesh query - up to three snap attempts per call, and in
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
-- 4. PERSONALITY MATRIX & CONTEXT-SEPARATED ANIMATION POOLS''',
    "approach-cache")


# ---------------------------------------------------------------------------
# 6. !ambient_perf
# ---------------------------------------------------------------------------
sub('''Ext.RegisterConsoleCommand("ambient_torch", function()''',
'''Ext.RegisterConsoleCommand("ambient_perf", function()
    local s = ActionQueue.stats or {}
    Ext.Utils.Print(string.format(
        "[AmbientAI] === QUEUE PERF === slowTicks(>120ms)=%d | worst=%dms in '%s'",
        s.slow or 0, math.floor(s.worst or 0), tostring(s.worstPhase or "-")))
    local rows = {}
    for phase, v in pairs(s.byPhase or {}) do
        rows[#rows + 1] = { phase = phase, worst = v.worst, n = v.n }
    end
    table.sort(rows, function(a, b) return a.worst > b.worst end)
    for i = 1, math.min(15, #rows) do
        Ext.Utils.Print(string.format("  %-52s worst=%5dms  n=%d", rows[i].phase,
            math.floor(rows[i].worst), rows[i].n))
    end
    Ext.Utils.Print("  (reset the counters with !ambient_perf_reset)")
end)

Ext.RegisterConsoleCommand("ambient_perf_reset", function()
    ActionQueue.stats = { slow = 0, worst = 0, worstPhase = "-", byPhase = {} }
    Ext.Utils.Print("[AmbientAI] queue perf counters reset.")
end)

Ext.RegisterConsoleCommand("ambient_torch", function()''',
    "console-ambient_perf")

open(sys.argv[2], "w", encoding="utf-8").write(src)
print("applied %d patches: %s" % (len(applied), ", ".join(applied)))
