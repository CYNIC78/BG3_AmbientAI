#!/usr/bin/env python3
"""04.3.19: find where the multi-second queue tick actually goes.

Field data (build 04.3.18):
    [PERF] slow queue tick: next-after(RandomWander) took 2763ms (action=RandomWander, slowTicks=1)
    Dispatching user function call (AmbientAI/BootstrapServer.lua:2512) took 2763.43 ms

`next-after(X)` wraps `self:processNext()` - i.e. the *start of the following action*, and the
only sub-phases inside it that we used to measure were start-prep/body. Both stayed silent, so
the time went into one of the unmeasured statements between them:
  * `SetAmbientSeatFollowLock` -> Osi.SetNoFollowFlag   (engine call)
  * `Log("... started: <action>")`                     (console / log-file I/O)
  * the second `shouldAbort()` inside executeWithGuard (≈15 engine queries per poll tick)
  * `action.execute`                                    (engine calls of the new action)

Also: `!ambient_perf` printed only 15 rows, so a quiet phase could fall off the table entirely.

This build adds:
  * phases: follow-lock(X), log-step(X), shouldAbort-next, execute(X);
  * `tick-total`: wraps the whole processNext call, so "everything not accounted for"
    (GC, engine stalls, timer scheduling) becomes a number;
  * per-cycle aggregation by kind (`tick-total`, `body`, `completion`, ... are 10 rows total
    instead of one row per action name), plus the detailed per-action table under it;
  * `!ambient_quiet` - mute/unmute the per-step "started:" lines at runtime, so the console-I/O
    hypothesis can be tested in-game in ten seconds;
  * `!ambient_perf` also reports Lua memory (`collectgarbage("count")`).

    python3 tools/patch_tick_whole.py <in.lua> <out.lua>
"""
import sys

PATCH_QUIET_DECL = (
    "ActionQueue.stats = ActionQueue.stats or { slow = 0, worst = 0, worstPhase = \"-\" }\n",
    "ActionQueue.stats = ActionQueue.stats or { slow = 0, worst = 0, worstPhase = \"-\" }\n"
    "-- 04.3.19: per-step console logging can be muted at runtime (!ambient_quiet).\n"
    "ActionQueue.quietSteps = ActionQueue.quietSteps or false\n",
)

PATCH_TICKPHASE_KIND = (
    "    if dt > row.worst then row.worst = dt end\n"
    "    if dt >= 40 then row.n = row.n + 1 end\n",

    "    if dt > row.worst then row.worst = dt end\n"
    "    if dt >= 40 then row.n = row.n + 1 end\n"
    "    -- 04.3.19: aggregate per kind as well, so a 30+ row per-action table collapses into\n"
    "    -- ~10 rows and a quiet phase can no longer fall off the printed list.\n"
    "    local kind = string.match(key, \"^[^%(]+\") or key\n"
    "    ActionQueue.stats.byKind = ActionQueue.stats.byKind or {}\n"
    "    local krow = ActionQueue.stats.byKind[kind]\n"
    "    if not krow then\n"
    "        krow = { worst = 0, n = 0, sum = 0, count = 0 }\n"
    "        ActionQueue.stats.byKind[kind] = krow\n"
    "    end\n"
    "    if dt > krow.worst then krow.worst = dt end\n"
    "    if dt >= 40 then krow.n = krow.n + 1 end\n"
    "    krow.sum = krow.sum + dt\n"
    "    krow.count = krow.count + 1\n",
)

PATCH_SHOULDABORT_NEXT = (
    "function ActionQueue:executeWithGuard()\n"
    "    self.timerId = nil\n"
    "    local tStart = Ext.Utils.MonotonicTime()\n"
    "    local abortNow, reason = self:shouldAbort()\n",

    "function ActionQueue:executeWithGuard()\n"
    "    self.timerId = nil\n"
    "    local tStart = Ext.Utils.MonotonicTime()\n"
    "    local abortNow, reason = self:shouldAbort()\n"
    "    -- 04.3.19: the abort gate runs ~15 engine queries on every poll tick and used to be\n"
    "    -- invisible in the profile.\n"
    "    TickPhase(tStart, \"shouldAbort-next\", self.currentAction and self.currentAction.name)\n",
)

PATCH_EXECUTE_PHASE = (
    "    if action.execute then\n"
    "        local ok, err = pcall(action.execute, self.character)\n"
    "        if not ok then\n",

    "    if action.execute then\n"
    "        local tExec = Ext.Utils.MonotonicTime()\n"
    "        local ok, err = pcall(action.execute, self.character)\n"
    "        TickPhase(tExec, \"execute(\" .. tostring(action.name) .. \")\", action.name)\n"
    "        if not ok then\n",
)

PATCH_FOLLOW_LOCK = (
    "    local stepName = self.currentAction and self.currentAction.name or \"\"\n"
    "    if self.activityTag ~= nil and stepName ~= \"StandUp\" and stepName ~= \"WakeUp\" then\n"
    "        SetAmbientSeatFollowLock(self.character, true)\n"
    "    end\n"
    "    local stepNameForPerf = self.currentAction.name\n"
    "    if stepNameForPerf and ConfigValues.Debug then\n"
    "        Log(tostring(self.character) .. \" started: \" .. tostring(stepNameForPerf))\n"
    "    end\n",

    "    local stepName = self.currentAction and self.currentAction.name or \"\"\n"
    "    local stepNameForPerf = self.currentAction.name\n"
    "    -- 04.3.19: engine call, previously unprofiled\n"
    "    local tLock = Ext.Utils.MonotonicTime()\n"
    "    if self.activityTag ~= nil and stepName ~= \"StandUp\" and stepName ~= \"WakeUp\" then\n"
    "        SetAmbientSeatFollowLock(self.character, true)\n"
    "    end\n"
    "    TickPhase(tLock, \"follow-lock(\" .. tostring(stepNameForPerf) .. \")\", stepNameForPerf)\n"
    "    -- 04.3.19: console write, previously unprofiled (prime suspect for the 2.7s hitch)\n"
    "    if stepNameForPerf and ConfigValues.Debug and not ActionQueue.quietSteps then\n"
    "        local tLog = Ext.Utils.MonotonicTime()\n"
    "        Log(tostring(self.character) .. \" started: \" .. tostring(stepNameForPerf))\n"
    "        TickPhase(tLog, \"log-step(\" .. tostring(stepNameForPerf) .. \")\", stepNameForPerf)\n"
    "    end\n",
)

PATCH_TICK_TOTAL = (
    "    self:executeWithGuard()\n"
    "    TickPhase(tBody, \"body(\" .. tostring(stepNameForPerf) .. \")\", stepNameForPerf)\n"
    "end\n",

    "    self:executeWithGuard()\n"
    "    TickPhase(tBody, \"body(\" .. tostring(stepNameForPerf) .. \")\", stepNameForPerf)\n"
    "end\n"
    "\n"
    "-- 04.3.19: wrap the whole tick. BG3SE reports \"Dispatching user function call\n"
    "-- (BootstrapServer.lua:<line>) took N ms\" for this callback; whatever is NOT inside one\n"
    "-- of the profiled phases (GC, engine stalls, console I/O, timer scheduling) shows up here.\n"
    "local _processNextInner = ActionQueue.processNext\n"
    "function ActionQueue:processNext()\n"
    "    local tWhole = Ext.Utils.MonotonicTime()\n"
    "    local ok, err = pcall(_processNextInner, self)\n"
    "    TickPhase(tWhole, \"tick-total\", self.currentAction and self.currentAction.name)\n"
    "    if not ok then error(err) end\n"
    "end\n",
)

PATCH_QUIET_CMD = (
    "Ext.RegisterConsoleCommand(\"ambient_perf_reset\", function()\n"
    "    ActionQueue.stats = { slow = 0, worst = 0, worstPhase = \"-\", byPhase = {} }\n"
    "    Ext.Utils.Print(\"[AmbientAI] queue perf counters reset.\")\n"
    "end)\n",

    "Ext.RegisterConsoleCommand(\"ambient_perf_reset\", function()\n"
    "    ActionQueue.stats = { slow = 0, worst = 0, worstPhase = \"-\", byPhase = {}, byKind = {} }\n"
    "    Ext.Utils.Print(\"[AmbientAI] queue perf counters reset.\")\n"
    "end)\n"
    "\n"
    "-- 04.3.19: mute/unmute the per-step \"started: <action>\" console lines.\n"
    "-- Errors, voices and diagnostics are NOT affected.\n"
    "Ext.RegisterConsoleCommand(\"ambient_quiet\", function()\n"
    "    ActionQueue.quietSteps = not ActionQueue.quietSteps\n"
    "    Ext.Utils.Print(string.format(\"[AmbientAI] per-step logging is now %s\",\n"
    "        ActionQueue.quietSteps and \"OFF (errors, voices and diagnostics stay on)\" or \"ON\"))\n"
    "end)\n",
)

NEW_PERF_COMMAND = r'''Ext.RegisterConsoleCommand("ambient_perf", function()
    local s = ActionQueue.stats or {}
    Ext.Utils.Print(string.format(
        "[AmbientAI] === QUEUE PERF === slowTicks(>120ms)=%d | worst=%dms in '%s' | luaMem=%.0fKB | quietSteps=%s",
        s.slow or 0, math.floor(s.worst or 0), tostring(s.worstPhase or "-"),
        collectgarbage("count"), tostring(ActionQueue.quietSteps == true)))

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

'''


def main(src_path, out_path):
    src = open(src_path, encoding="utf-8").read()
    applied = []
    for name, (old, new) in [
        ("quiet-flag decl", PATCH_QUIET_DECL),
        ("byKind aggregation", PATCH_TICKPHASE_KIND),
        ("shouldAbort inside executeWithGuard", PATCH_SHOULDABORT_NEXT),
        ("execute(...) phase", PATCH_EXECUTE_PHASE),
        ("follow-lock + log-step phases", PATCH_FOLLOW_LOCK),
        ("tick-total wrapper", PATCH_TICK_TOTAL),
        ("ambient_quiet command + reset byKind", PATCH_QUIET_CMD),
    ]:
        if src.count(old) != 1:
            raise SystemExit("PATCH MISSING (%s): count=%d" % (name, src.count(old)))
        src = src.replace(old, new)
        applied.append(name)

    # replace the whole !ambient_perf body (it used to print at most 15 rows)
    start = src.index('Ext.RegisterConsoleCommand("ambient_perf", function()')
    end = src.index('Ext.RegisterConsoleCommand("ambient_perf_reset"')
    src = src[:start] + NEW_PERF_COMMAND + src[end:]
    applied.append("rewritten !ambient_perf")

    import lupa
    lua = lupa.LuaRuntime()
    try:
        lua.execute("local f, err = load(%r); if not f then error(err) end" % src)
    except Exception as exc:  # noqa: BLE001
        raise SystemExit("SYNTAX ERROR: %s" % exc)
    open(out_path, "w", encoding="utf-8").write(src)
    print("applied %d patches: %s" % (len(applied), ", ".join(applied)))
    print("04.3.19 SYNTAX OK")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
