#!/usr/bin/env python3
"""04.3.21: make step logging survive a pathologically slow console.

Field data (build 04.3.20, in game):
    [AmbientAI] console I/O is slow (831 ms per line) - step logging throttled to 1 line/slice
    Dispatching user function call (BootstrapServer.lua:2431) took 831.46 ms
    Dispatching user function call (BootstrapServer.lua:2431) took 10954.40 ms
    !ambient_perf: log-flush worst=10955ms | every game phase <= 3ms

So the queue is now clean (all engine work <= 3 ms) but `Ext.Utils.Print` itself costs ~0.8 s per
line in this setup and a single flush could reach 11 s. Throttling to "1 line per slice" is not
enough - a single line is already a second-long freeze.

This build:
  1. hard wall-clock budget per flush (120 ms, at least one line attempted) - a callback can
     never take seconds again;
  2. auto-quiet: if a measured line costs > 200 ms, step logging switches itself off, says so
     once, and stops the drainer entirely;
  3. keeps the last 60 step lines in a ring buffer, so they are not lost - `!ambient_steps [n]`
     prints them on demand (one user-initiated command, cost is acceptable);
  4. `!ambient_perf` shows `stepsSuppressed` (how many step lines were produced while muted);
  5. when slow, the drainer backs off to one slice every 500 ms instead of 80 ms.

    python3 tools/patch_log_guard.py <in.lua> <out.lua>
"""
import sys

PATCH_STATE = (
    "ActionQueue.stepLog = ActionQueue.stepLog or { queue = {}, size = 0, timerId = nil, perSlice = 4,\n"
    "                                               lastCostMs = 0, warned = false, dropped = 0 }\n",

    "ActionQueue.stepLog = ActionQueue.stepLog or { queue = {}, size = 0, timerId = nil, perSlice = 4,\n"
    "                                               lastCostMs = 0, warned = false, dropped = 0 }\n"
    "-- 04.3.21: a console can be catastrophically slow (831 ms per line, 11 s per flush in the\n"
    "-- field). Keep a ring buffer of the lines, bound every flush in wall-clock time, and mute\n"
    "-- ourselves automatically instead of freezing the game.\n"
    "ActionQueue.stepBudgetMs = ActionQueue.stepBudgetMs or 120\n"
    "ActionQueue.stepAutoQuietMs = ActionQueue.stepAutoQuietMs or 200\n"
    "ActionQueue.stepRing = ActionQueue.stepRing or { lines = {}, size = 0, max = 60 }\n"
    "ActionQueue.stepSuppressed = ActionQueue.stepSuppressed or 0\n"
    "\n"
    "function ActionQueue.rememberStep(line)\n"
    "    local ring = ActionQueue.stepRing\n"
    "    ring.lines[#ring.lines + 1] = tostring(line)\n"
    "    while #ring.lines > ring.max do table.remove(ring.lines, 1) end\n"
    "    ring.size = #ring.lines\n"
    "end\n",
)

PATCH_ENQUEUE = (
    "    log.queue[#log.queue + 1] = line\n",

    "    log.queue[#log.queue + 1] = line\n"
    "    ActionQueue.rememberStep(line)\n"
    "    if ActionQueue.quietSteps then ActionQueue.stepSuppressed = ActionQueue.stepSuppressed + 1 end\n",
)

PATCH_DRAIN = (
    "    local t0 = Ext.Utils.MonotonicTime()\n"
    "    local n = 0\n"
    "    while #log.queue > 0 and n < (log.perSlice or 4) do\n"
    "        local line = table.remove(log.queue, 1)\n"
    "        log.size = log.size - 1\n"
    "        if ConfigValues.Debug then\n"
    "            Ext.Utils.Print(\"[AmbientAI] \" .. tostring(line))\n"
    "        end\n"
    "        n = n + 1\n"
    "    end\n"
    "    local dt = TickPhase(t0, \"log-flush\", \"step-log\")\n",

    "    local t0 = Ext.Utils.MonotonicTime()\n"
    "    local n = 0\n"
    "    while #log.queue > 0 and n < (log.perSlice or 4) do\n"
    "        local line = table.remove(log.queue, 1)\n"
    "        log.size = log.size - 1\n"
    "        if ConfigValues.Debug then\n"
    "            Ext.Utils.Print(\"[AmbientAI] \" .. tostring(line))\n"
    "        end\n"
    "        n = n + 1\n"
    "        -- 04.3.21: never spend more than the budget in one callback, even if the console\n"
    "        -- crawls; the rest of the queue waits for the next slice.\n"
    "        if (Ext.Utils.MonotonicTime() - t0) > (ActionQueue.stepBudgetMs or 120) then\n"
    "            break\n"
    "        end\n"
    "    end\n"
    "    local dt = TickPhase(t0, \"log-flush\", \"step-log\")\n"
    "    -- a single line slower than 200 ms makes every future flush a freeze -> mute ourselves\n"
    "    if n > 0 and (dt / n) > (ActionQueue.stepAutoQuietMs or 200) and not ActionQueue.quietSteps then\n"
    "        ActionQueue.quietSteps = true\n"
    "        ActionQueue.stepLog.warned = true\n"
    "        log.queue = {}\n"
    "        log.size = 0\n"
    "        if log.timerId then\n"
    "            local tid = log.timerId\n"
    "            log.timerId = nil\n"
    "            pcall(Ext.Timer.Cancel, tid)\n"
    "        end\n"
    "        Ext.Utils.Print(string.format(\n"
    "            \"[AmbientAI] console write costs %.0f ms per line - per-step logging switched OFF automatically \"\n"
    "            .. \"(the last %d lines are kept in memory: !ambient_steps). Gameplay is unaffected.\",\n"
    "            dt / n, ActionQueue.stepRing.size))\n"
    "        return\n"
    "    end\n",
)

PATCH_BACKOFF = (
    "    if #log.queue > 0 and Ext and Ext.Timer and Ext.Timer.WaitFor then\n"
    "        log.timerId = Ext.Timer.WaitFor(80, ActionQueue.drainStepLog)\n"
    "    end\n",

    "    if #log.queue > 0 and Ext and Ext.Timer and Ext.Timer.WaitFor then\n"
    "        -- 04.3.21: on a slow console give the engine room between slices\n"
    "        local delay = ((log.lastCostMs or 0) > 50) and 500 or 80\n"
    "        log.timerId = Ext.Timer.WaitFor(delay, ActionQueue.drainStepLog)\n"
    "    end\n",
)

PATCH_HEADER = (
    "        \"[AmbientAI] === QUEUE PERF === slowTicks(>120ms)=%d | worst=%dms in '%s' | luaMem=%.0fKB | quietSteps=%s | pendingSteps=%d logCost=%.0fms\",\n"
    "        s.slow or 0, math.floor(s.worst or 0), tostring(s.worstPhase or \"-\"),\n"
    "        collectgarbage(\"count\"), tostring(ActionQueue.quietSteps == true),\n"
    "        (ActionQueue.stepLog and ActionQueue.stepLog.size) or 0,\n"
    "        (ActionQueue.stepLog and ActionQueue.stepLog.lastCostMs) or 0))\n",

    "        \"[AmbientAI] === QUEUE PERF === slowTicks(>120ms)=%d | worst=%dms in '%s' | luaMem=%.0fKB | quietSteps=%s | pendingSteps=%d logCost=%.0fms | stepsSuppressed=%d\",\n"
    "        s.slow or 0, math.floor(s.worst or 0), tostring(s.worstPhase or \"-\"),\n"
    "        collectgarbage(\"count\"), tostring(ActionQueue.quietSteps == true),\n"
    "        (ActionQueue.stepLog and ActionQueue.stepLog.size) or 0,\n"
    "        (ActionQueue.stepLog and ActionQueue.stepLog.lastCostMs) or 0,\n"
    "        ActionQueue.stepSuppressed or 0))\n",
)

PATCH_STEPS_CMD = (
    "Ext.RegisterConsoleCommand(\"ambient_log_now\", function()\n",

    "-- 04.3.21: print the buffered step lines on demand (they are kept even when muted).\n"
    "Ext.RegisterConsoleCommand(\"ambient_steps\", function(_cmd, countArg)\n"
    "    local ring = ActionQueue.stepRing\n"
    "    local want = math.max(1, math.min(ring.max, tonumber(countArg) or 20))\n"
    "    local lines = ring.lines\n"
    "    local from = math.max(1, #lines - want + 1)\n"
    "    Ext.Utils.Print(string.format(\"[AmbientAI] last %d step line(s) of %d buffered:\",\n"
    "        math.max(0, #lines - from + 1), #lines))\n"
    "    for i = from, #lines do\n"
    "        Ext.Utils.Print(\"  \" .. tostring(lines[i]))\n"
    "    end\n"
    "end)\n"
    "\n"
    "Ext.RegisterConsoleCommand(\"ambient_log_now\", function()\n",
)


def main(src_path, out_path):
    src = open(src_path, encoding="utf-8").read()
    applied = []
    for name, (old, new) in [
        ("ring buffer + budgets", PATCH_STATE),
        ("remember+count on enqueue", PATCH_ENQUEUE),
        ("bounded flush + auto-quiet", PATCH_DRAIN),
        ("slow-console backoff", PATCH_BACKOFF),
        ("perf header stepsSuppressed", PATCH_HEADER),
        ("ambient_steps command", PATCH_STEPS_CMD),
    ]:
        if src.count(old) != 1:
            raise SystemExit("PATCH MISSING (%s): count=%d" % (name, src.count(old)))
        src = src.replace(old, new)
        applied.append(name)
    import lupa
    lua = lupa.LuaRuntime()
    try:
        lua.execute("local f, err = load(%r); if not f then error(err) end" % src)
    except Exception as exc:  # noqa: BLE001
        raise SystemExit("SYNTAX ERROR: %s" % exc)
    open(out_path, "w", encoding="utf-8").write(src)
    print("applied %d patches: %s" % (len(applied), ", ".join(applied)))
    print("04.3.21 SYNTAX OK")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
