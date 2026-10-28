-- Scenario 34 (04.3.20): консольная строка не должна тормозить тик.
--   Фаза 1: норма (печать быстрая) -> строки "started:" всё равно появляются (отложенно).
--   Фаза 2: мок «печатает по 400 мс» -> тик обязан остаться быстрым (log-enqueue ~0),
--           а стоимость уйти в отдельную фазу log-flush, т.е. партия больше не замирает.
--   Сравнение с 04.3.19: там ровно эта же печать была ВНУТРИ тика (log-step = 400 мс).
dofile("/home/user/sim/mock.lua")
dofile("/home/user/sim/scene.lua")

SCENE_SETUP({
    { "S_TWN_Candle_01",       3.0, 0.0, 2.0, { kind = "light", canUse = true, canPickUp = false } },
    { "S_TWN_Bookshelf_A",     2.6, 0.0, 3.0, { kind = "prop", canUse = true, canPickUp = false } },
    { "OBJ_TWN_Crate_A",       1.4, 0.0, 3.4, { kind = "container", canUse = true, canPickUp = false, isContainer = true } },
    { "S_TWN_Candle_02",       4.2, 0.0, 0.4, { kind = "light", canUse = true, canPickUp = false } },
})
SIM.debugMCM = true
SCENE_LOAD_MOD()

local function perfReport()
    local from = #SIM.prints + 1
    SIM.commands.ambient_perf()
    local text, rows = {}, {}
    for i = from, #SIM.prints do
        local line = SIM.prints[i]
        text[#text + 1] = line
        local slow = string.match(line, "slowTicks%(%>120ms%)=(%d+)")
        if slow then rows.slow = tonumber(slow) end
        local pending = string.match(line, "pendingSteps=(%d+)")
        if pending then rows.pending = tonumber(pending) end
        local kind, worst = string.match(line, "([%w%-_]+)%s+worst=%s*(%d+)ms")
        if kind then rows[kind] = math.max(rows[kind] or 0, tonumber(worst)) end
    end
    rows.text = table.concat(text, "\n")
    return rows
end

local function countSteps(since)
    local n = 0
    for i = since, #SIM.prints do
        if string.find(SIM.prints[i], " started: ", 1, true) then n = n + 1 end
    end
    return n
end

-- Фаза 1: обычная печать. Строки должны появиться, хоть и отложенно.
local mark1 = #SIM.prints + 1
SIM.run(25000)
local stepsSeen = countSteps(mark1)
local normal = perfReport()
SIM.log("PHASE1 deferredStepLines=%d logEnqueueWorst=%s logFlushWorst=%s pending=%s",
    stepsSeen, tostring(normal["log-enqueue"]), tostring(normal["log-flush"]), tostring(normal.pending))

-- Фаза 2: консоль «тормозит» — 400 мс на строку
SIM.commands.ambient_perf_reset()
SIM.printCostMs = 400
SIM.run(30000)
local slow = perfReport()
SIM.printCostMs = 0

local enq = slow["log-enqueue"] or 0
local flush = slow["log-flush"] or 0
local tickTotal = slow["tick-total"] or 0
SIM.log("PHASE2 slowConsole enqueueWorst=%dms flushWorst=%dms tickTotalWorst=%dms slowTicks=%s throttled=%s",
    enq, flush, tickTotal, tostring(slow.slow),
    tostring(string.find(slow.text, "throttled to 1 line", 1, true) ~= nil))

-- ключевая проверка: стоимость печати НЕ в тике
local pass = stepsSeen > 0 and enq < 50 and flush >= 300
SIM.log(pass and "PASS s34: console cost lives in the drainer, the action queue tick stays clean"
    or "FAIL s34")
SIM.report("SCENARIO 34: deferred step logging")
