#!/usr/bin/env python3
"""04.3.22: keep Debug usable with a slow console - filter the step log, don't drown in it.

The user keeps AmbientAI_Debug ON on purpose (that is how we hunt bugs), but a console that
costs hundreds of ms per line turns "log every step of every companion" into freezes. 04.3.21
already protects the frame budget (queue + bounded flush + auto-quiet + ring buffer). This build
makes debugging *cheaper and sharper*:

    !ambient_focus Seat          - only step lines whose action name contains "Seat"
                                   (case-insensitive); everything else is counted, not printed
    !ambient_focus off           - clear the filter (back to everything)
    !ambient_focus               - show the current filter + counters

Counters (enqueued / filtered / suppressed) are shown in the !ambient_perf header, so it is
visible how much noise a filter removes.

    python3 tools/patch_steps_filter.py <in.lua> <out.lua>
"""
import sys

PATCH_FILTER_STATE = (
    "ActionQueue.stepSuppressed = ActionQueue.stepSuppressed or 0\n",

    "ActionQueue.stepSuppressed = ActionQueue.stepSuppressed or 0\n"
    "-- 04.3.22: Debug stays usable on a slow console - filter step lines by action-name substring.\n"
    "ActionQueue.stepFilter = ActionQueue.stepFilter or nil\n"
    "ActionQueue.stepsEnqueued = ActionQueue.stepsEnqueued or 0\n"
    "ActionQueue.stepsFilteredOut = ActionQueue.stepsFilteredOut or 0\n",
)

PATCH_QUEUE = (
    "function ActionQueue.queueStepLog(line)\n"
    "    local log = ActionQueue.stepLog\n"
    "    log.size = log.size + 1\n",

    "function ActionQueue.queueStepLog(line)\n"
    "    local log = ActionQueue.stepLog\n"
    "    -- 04.3.22: a filter makes Debug affordable (and the log readable): count, don't print.\n"
    "    local filter = ActionQueue.stepFilter\n"
    "    if filter and not string.find(string.lower(tostring(line)), filter, 1, true) then\n"
    "        ActionQueue.stepsFilteredOut = ActionQueue.stepsFilteredOut + 1\n"
    "        ActionQueue.rememberStep(line)\n"
    "        return\n"
    "    end\n"
    "    ActionQueue.stepsEnqueued = ActionQueue.stepsEnqueued + 1\n"
    "    log.size = log.size + 1\n",
)

PATCH_HEADER = (
    "        \"[AmbientAI] === QUEUE PERF === slowTicks(>120ms)=%d | worst=%dms in '%s' | luaMem=%.0fKB | quietSteps=%s | pendingSteps=%d logCost=%.0fms | stepsSuppressed=%d\",\n"
    "        s.slow or 0, math.floor(s.worst or 0), tostring(s.worstPhase or \"-\"),\n"
    "        collectgarbage(\"count\"), tostring(ActionQueue.quietSteps == true),\n"
    "        (ActionQueue.stepLog and ActionQueue.stepLog.size) or 0,\n"
    "        (ActionQueue.stepLog and ActionQueue.stepLog.lastCostMs) or 0,\n"
    "        ActionQueue.stepSuppressed or 0))\n",

    "        \"[AmbientAI] === QUEUE PERF === slowTicks(>120ms)=%d | worst=%dms in '%s' | luaMem=%.0fKB | quietSteps=%s | pendingSteps=%d logCost=%.0fms | stepsSuppressed=%d | stepFilter='%s' enqueued=%d filtered=%d\",\n"
    "        s.slow or 0, math.floor(s.worst or 0), tostring(s.worstPhase or \"-\"),\n"
    "        collectgarbage(\"count\"), tostring(ActionQueue.quietSteps == true),\n"
    "        (ActionQueue.stepLog and ActionQueue.stepLog.size) or 0,\n"
    "        (ActionQueue.stepLog and ActionQueue.stepLog.lastCostMs) or 0,\n"
    "        ActionQueue.stepSuppressed or 0,\n"
    "        tostring(ActionQueue.stepFilter or \"-\"),\n"
    "        ActionQueue.stepsEnqueued or 0, ActionQueue.stepsFilteredOut or 0))\n",
)

PATCH_CMD = (
    "-- 04.3.21: print the buffered step lines on demand (they are kept even when muted).\n",

    "-- 04.3.22: step-log filter -------------------------------------------------\n"
    "Ext.RegisterConsoleCommand(\"ambient_focus\", function(_cmd, pattern)\n"
    "    if not pattern or pattern == \"\" then\n"
    "        Ext.Utils.Print(string.format(\n"
    "            \"[AmbientAI] step filter: '%s' | enqueued=%d filteredOut=%d suppressed=%d | ring=%d\",\n"
    "            tostring(ActionQueue.stepFilter or \"-\"), ActionQueue.stepsEnqueued or 0,\n"
    "            ActionQueue.stepsFilteredOut or 0, ActionQueue.stepSuppressed or 0,\n"
    "            (ActionQueue.stepRing and ActionQueue.stepRing.size) or 0))\n"
    "        Ext.Utils.Print(\"  usage: !ambient_focus Seat | !ambient_focus off\")\n"
    "        return\n"
    "    end\n"
    "    if string.lower(tostring(pattern)) == \"off\" then\n"
    "        ActionQueue.stepFilter = nil\n"
    "        Ext.Utils.Print(\"[AmbientAI] step filter cleared - every step line will be printed again\")\n"
    "        return\n"
    "    end\n"
    "    ActionQueue.stepFilter = string.lower(tostring(pattern))\n"
    "    ActionQueue.stepsEnqueued, ActionQueue.stepsFilteredOut = 0, 0\n"
    "    Ext.Utils.Print(string.format(\n"
    "        \"[AmbientAI] step filter set to '%s' - only matching step lines reach the console \"\n"
    "        .. \"(the rest are counted and still kept in !ambient_steps)\", ActionQueue.stepFilter))\n"
    "end)\n"
    "\n"
    "-- 04.3.21: print the buffered step lines on demand (they are kept even when muted).\n",
)


def main(src_path, out_path):
    src = open(src_path, encoding="utf-8").read()
    applied = []
    for name, (old, new) in [
        ("filter state", PATCH_FILTER_STATE),
        ("queue honours the filter", PATCH_QUEUE),
        ("perf header: filter counters", PATCH_HEADER),
        ("ambient_focus command", PATCH_CMD),
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
    print("04.3.22 SYNTAX OK")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
