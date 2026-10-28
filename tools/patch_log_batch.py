#!/usr/bin/env python3
"""04.3.20: take the per-step console write out of the action-queue tick.

Field data (build 04.3.19, in game):
    tick-total   worst= 672ms  avg= 26.6ms  n=1  calls=26
    log-step     worst= 668ms  avg= 34.2ms  n=1  calls=20      <- 34 ms PER LOG LINE
    log-step(StandUpFromGround) worst= 3914ms
    everything else (body/execute/completion/follow-lock/shouldAbort) <= 3 ms

So `Ext.Utils.Print` (BG3SE console + log file) costs tens of milliseconds per call, sometimes
seconds, and it sat inline in the middle of the queue tick - i.e. the companion froze mid-action.

Fix: the tick only pushes a string into a queue (microseconds). A dedicated, self-throttling
drainer prints those lines from its own timer, 4 lines per 80 ms slice, so a slow console can
never block an action. It also measures itself as phase `log-flush` and, if the console turns
out to be slower than 100 ms per line, drops to 1 line per slice and says so once.

    python3 tools/patch_log_batch.py <in.lua> <out.lua>
"""
import sys

ANCHOR = '''    return dt
end

function ActionQueue:processNext()'''

NEW_LOGGER = '''    return dt
end

-- 04.3.20: the per-step "started: <action>" line used to be printed INLINE in the queue tick.
-- In game that single Ext.Utils.Print costs 34 ms on average and up to 3.9 s, freezing the
-- companion mid-action. Now the tick only enqueues the string; a separate timer drains it.
ActionQueue.stepLog = ActionQueue.stepLog or { queue = {}, size = 0, timerId = nil, perSlice = 4,
                                               lastCostMs = 0, warned = false, dropped = 0 }

function ActionQueue.queueStepLog(line)
    local log = ActionQueue.stepLog
    log.size = log.size + 1
    if log.size > 400 then           -- hard cap: never let the queue grow unbounded
        log.dropped = log.dropped + 1
        return
    end
    log.queue[#log.queue + 1] = line
    if log.timerId == nil and Ext and Ext.Timer and Ext.Timer.WaitFor then
        log.timerId = Ext.Timer.WaitFor(80, ActionQueue.drainStepLog)
    end
end

function ActionQueue.drainStepLog()
    local log = ActionQueue.stepLog
    log.timerId = nil
    local t0 = Ext.Utils.MonotonicTime()
    local n = 0
    while #log.queue > 0 and n < (log.perSlice or 4) do
        local line = table.remove(log.queue, 1)
        log.size = log.size - 1
        if ConfigValues.Debug then
            Ext.Utils.Print("[AmbientAI] " .. tostring(line))
        end
        n = n + 1
    end
    local dt = TickPhase(t0, "log-flush", "step-log")
    if n > 0 then
        log.lastCostMs = dt / n
        -- a console that slow must not eat the frame budget: one line per slice, warn once
        if dt > 100 and (log.perSlice or 4) > 1 then
            log.perSlice = 1
            if not log.warned then
                log.warned = true
                Ext.Utils.Print(string.format(
                    "[AmbientAI] console I/O is slow (%.0f ms per line) - step logging throttled to 1 line/slice. Use !ambient_quiet to mute it entirely.",
                    dt / n))
            end
        elseif dt < 8 and (log.perSlice or 1) < 4 then
            log.perSlice = math.min(4, (log.perSlice or 1) + 1)
        end
    end
    if log.dropped > 0 then
        Ext.Utils.Print(string.format("[AmbientAI] step log: %d line(s) dropped (queue cap)", log.dropped))
        log.dropped = 0
    end
    if #log.queue > 0 and Ext and Ext.Timer and Ext.Timer.WaitFor then
        log.timerId = Ext.Timer.WaitFor(80, ActionQueue.drainStepLog)
    end
end

function ActionQueue.flushStepLog(count)
    local log = ActionQueue.stepLog
    local n = 0
    while #log.queue > 0 and n < (count or 200) do
        local line = table.remove(log.queue, 1)
        log.size = log.size - 1
        if ConfigValues.Debug then
            Ext.Utils.Print("[AmbientAI] " .. tostring(line))
        end
        n = n + 1
    end
    return n
end

function ActionQueue:processNext()'''

# A slow phase used to trigger a Log right there in the tick - with a slow console that is a
# self-amplifying loop (print costs 400 ms -> phase looks slower -> prints again).
PATCH_PERF_LOG_RATELIMIT = (
    "    if dt >= 120 then\n"
    "        ActionQueue.stats.slow = ActionQueue.stats.slow + 1\n"
    "        if dt > (ActionQueue.stats.worst or 0) then\n"
    "            ActionQueue.stats.worst = dt\n"
    "            ActionQueue.stats.worstPhase = phase\n"
    "        end\n"
    "        Log(string.format(\"[PERF] slow queue tick: %s took %dms (action=%s, slowTicks=%d)\",\n"
    "            tostring(phase), math.floor(dt), tostring(actionName or \"-\"), ActionQueue.stats.slow))\n"
    "    end\n",

    "    if dt >= 120 then\n"
    "        ActionQueue.stats.slow = ActionQueue.stats.slow + 1\n"
    "        if dt > (ActionQueue.stats.worst or 0) then\n"
    "            ActionQueue.stats.worst = dt\n"
    "            ActionQueue.stats.worstPhase = phase\n"
    "        end\n"
    "        -- 04.3.20: rate-limit this line. Printing it inline on every slow phase turns a slow\n"
    "        -- console into a feedback loop (the print itself makes the next phase slower).\n"
    "        local nowMs = Ext.Utils.MonotonicTime()\n"
    "        ActionQueue.perfLog = ActionQueue.perfLog or { last = 0, skipped = 0 }\n"
    "        if (nowMs - ActionQueue.perfLog.last) >= 3000 then\n"
    "            ActionQueue.perfLog.last = nowMs\n"
    "            local full = string.format(\"[PERF] slow queue tick: %s took %dms (action=%s, slowTicks=%d, %d more suppressed)\",\n"
    "                tostring(phase), math.floor(dt), tostring(actionName or \"-\"), ActionQueue.stats.slow,\n"
    "                ActionQueue.perfLog.skipped)\n"
    "            -- also deferred: printing this inline made a slow console inflate the very tick it reports\n"
    "            if ActionQueue.queueStepLog then\n"
    "                ActionQueue.queueStepLog(full)\n"
    "            else\n"
    "                Log(full)\n"
    "            end\n"
    "            ActionQueue.perfLog.skipped = 0\n"
    "        else\n"
    "            ActionQueue.perfLog.skipped = ActionQueue.perfLog.skipped + 1\n"
    "        end\n"
    "    end\n",
)

PATCH_CALLSITE = (
    "    -- 04.3.19: console write, previously unprofiled (prime suspect for the 2.7s hitch)\n"
    "    if stepNameForPerf and ConfigValues.Debug and not ActionQueue.quietSteps then\n"
    "        local tLog = Ext.Utils.MonotonicTime()\n"
    "        Log(tostring(self.character) .. \" started: \" .. tostring(stepNameForPerf))\n"
    "        TickPhase(tLog, \"log-step(\" .. tostring(stepNameForPerf) .. \")\", stepNameForPerf)\n"
    "    end\n",

    "    -- 04.3.20: enqueue only - the actual console write happens in ActionQueue.drainStepLog\n"
    "    -- (34 ms per line inline was freezing companions mid-action).\n"
    "    if stepNameForPerf and ConfigValues.Debug and not ActionQueue.quietSteps then\n"
    "        local tLog = Ext.Utils.MonotonicTime()\n"
    "        ActionQueue.queueStepLog(tostring(self.character) .. \" started: \" .. tostring(stepNameForPerf))\n"
    "        TickPhase(tLog, \"log-enqueue(\" .. tostring(stepNameForPerf) .. \")\", stepNameForPerf)\n"
    "    end\n",
)

PATCH_HEADER = (
    "        \"[AmbientAI] === QUEUE PERF === slowTicks(>120ms)=%d | worst=%dms in '%s' | luaMem=%.0fKB | quietSteps=%s\",\n"
    "        s.slow or 0, math.floor(s.worst or 0), tostring(s.worstPhase or \"-\"),\n"
    "        collectgarbage(\"count\"), tostring(ActionQueue.quietSteps == true)))\n",

    "        \"[AmbientAI] === QUEUE PERF === slowTicks(>120ms)=%d | worst=%dms in '%s' | luaMem=%.0fKB | quietSteps=%s | pendingSteps=%d logCost=%.0fms\",\n"
    "        s.slow or 0, math.floor(s.worst or 0), tostring(s.worstPhase or \"-\"),\n"
    "        collectgarbage(\"count\"), tostring(ActionQueue.quietSteps == true),\n"
    "        (ActionQueue.stepLog and ActionQueue.stepLog.size) or 0,\n"
    "        (ActionQueue.stepLog and ActionQueue.stepLog.lastCostMs) or 0))\n",
)

PATCH_FLUSH_CMD = (
    "Ext.RegisterConsoleCommand(\"ambient_quiet\", function()\n"
    "    ActionQueue.quietSteps = not ActionQueue.quietSteps\n"
    "    Ext.Utils.Print(string.format(\"[AmbientAI] per-step logging is now %s\",\n"
    "        ActionQueue.quietSteps and \"OFF (errors, voices and diagnostics stay on)\" or \"ON\"))\n"
    "end)\n",

    "Ext.RegisterConsoleCommand(\"ambient_quiet\", function()\n"
    "    ActionQueue.quietSteps = not ActionQueue.quietSteps\n"
    "    Ext.Utils.Print(string.format(\"[AmbientAI] per-step logging is now %s\",\n"
    "        ActionQueue.quietSteps and \"OFF (errors, voices and diagnostics stay on)\" or \"ON\"))\n"
    "end)\n"
    "\n"
    "-- 04.3.20: flush deferred step lines right now (useful before copying the log).\n"
    "Ext.RegisterConsoleCommand(\"ambient_log_now\", function()\n"
    "    local n = ActionQueue.flushStepLog(400)\n"
    "    Ext.Utils.Print(string.format(\"[AmbientAI] flushed %d deferred step line(s), %d still queued\",\n"
    "        n, (ActionQueue.stepLog and ActionQueue.stepLog.size) or 0))\n"
    "end)\n",
)


def main(src_path, out_path):
    src = open(src_path, encoding="utf-8").read()
    applied = []
    if src.count(ANCHOR) != 1:
        raise SystemExit("anchor not unique (%d)" % src.count(ANCHOR))
    src = src.replace(ANCHOR, NEW_LOGGER)
    applied.append("deferred step-log queue + drainer")
    for name, (old, new) in [
        ("tick enqueues instead of printing", PATCH_CALLSITE),
        ("rate-limit the [PERF] slow-tick log", PATCH_PERF_LOG_RATELIMIT),
        ("perf header: pending/log cost", PATCH_HEADER),
        ("ambient_log_now command", PATCH_FLUSH_CMD),
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
    print("04.3.20 SYNTAX OK")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
