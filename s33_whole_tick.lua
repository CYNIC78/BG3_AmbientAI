-- Scenario 33 (04.3.19): виден ли «неучтённый» простой тика.
--   Фаза 1: всё быстро -> tick-total есть, slowTicks=0.
--   Фаза 2: консольная запись тормозит (SIM.printCostMs = 350) -> профайлер ОБЯЗАН показать
--           это как log-step(...) и slowTicks>0. Именно так выглядел хитч 2763 мс:
--           известные фазы молчали, а время уходило в неохваченный участок тика.
--   Фаза 3: !ambient_quiet -> строки "started:" исчезают, флаг виден в !ambient_perf.
dofile("/home/user/sim/mock.lua")
dofile("/home/user/sim/scene.lua")

SCENE_SETUP({
    { "CHA_TWN_Chair_Wood_A",  2.2, 0.0, 1.0, { kind = "prop", canUse = true, canPickUp = false, sittable = true } },
    { "S_TWN_Candle_01",       3.0, 0.0, 2.0, { kind = "light", canUse = true, canPickUp = false } },
    { "S_TWN_Bookshelf_A",     2.6, 0.0, 3.0, { kind = "prop", canUse = true, canPickUp = false } },
    { "OBJ_TWN_Crate_A",       1.4, 0.0, 3.4, { kind = "container", canUse = true, canPickUp = false, isContainer = true } },
    { "S_TWN_Candle_02",       4.2, 0.0, 0.4, { kind = "light", canUse = true, canPickUp = false } },
})
SIM.debugMCM = true
SCENE_LOAD_MOD()

-- !ambient_perf пишет в лог; держим и текст (для подстрок), и разбор worst для slowTicks
local function perfReport()
    local from = #SIM.prints + 1
    SIM.commands.ambient_perf()
    local text, rows = {}, {}
    for i = from, #SIM.prints do
        local line = SIM.prints[i]
        text[#text + 1] = line
        local slow = string.match(line, "slowTicks%(%>120ms%)=(%d+)")
        if slow then rows.slow = tonumber(slow) end
        local quiet = string.match(line, "quietSteps=(%a+)")
        if quiet then rows.quiet = quiet end
        local phase, worst = string.match(line, ":?%s*(%a[%w%-_%(%)]*)%s+worst=%s*(%d+)ms")
        if phase then rows[phase] = math.max(rows[phase] or 0, tonumber(worst)) end
    end
    rows.text = table.concat(text, "\n")
    return rows
end

local function startedSince(from)
    local n = 0
    for i = from, #SIM.prints do
        if string.find(SIM.prints[i], " started: ", 1, true) then n = n + 1 end
    end
    return n
end

-- Фаза 1: норма
SIM.run(20000)
local normal = perfReport()
local function has(word) return string.find(normal.text, word, 1, true) ~= nil end
local hasTickTotal = has("tick-total")
local hasLogStep = has("log-step") or has("log-enqueue")
local hasLock, hasAbortNext, hasKinds = has("follow-lock"), has("shouldAbort-next"), has("by kind")
SIM.log("PHASE1 tick-total=%s logStep=%s followLock=%s shouldAbortNext=%s kinds=%s slow=%s quiet=%s",
    tostring(hasTickTotal), tostring(hasLogStep), tostring(hasLock), tostring(hasAbortNext),
    tostring(hasKinds), tostring(normal.slow), tostring(normal.quiet))

-- Фаза 2: !ambient_quiet глушит только пошаговые строки
SIM.commands.ambient_quiet()
local markQuiet = #SIM.prints + 1
SIM.run(25000)
local quietLines = startedSince(markQuiet)
local quietPerf = perfReport()
SIM.commands.ambient_quiet()   -- обратно

-- Фаза 3: консоль тормозит (мок «уводит время» вперёд на каждой печати)
SIM.commands.ambient_perf_reset()
SIM.printCostMs = 350
local mark = #SIM.prints + 1
SIM.run(25000)
local stepLines = startedSince(mark)
local slow = perfReport()
SIM.printCostMs = 0
local logWorst = 0
for phase, worst in pairs(slow) do
    if string.find(phase, "log%-step", 1, true) then logWorst = math.max(logWorst, worst) end
end
SIM.log("PHASE2 quiet: startedLines=%d quietFlag=%s", quietLines, tostring(quietPerf.quiet))
SIM.log("PHASE3 slowConsole startedLines=%d slowTicks=%s logStepWorst=%dms",
    stepLines, tostring(slow.slow), logWorst)

-- 04.3.20: пошаговый лог больше не печатается внутри тика, поэтому стоимость ловится
-- в фазе log-flush (дренажер), а не в log-step. Годится любой из двух вариантов.
local seesLogCost = string.find(slow.text, "350ms", 1, true) ~= nil
    and (string.find(slow.text, "log-flush", 1, true) ~= nil
         or string.find(slow.text, "log-step", 1, true) ~= nil)
local caught = (slow.slow or 0) > 0 and seesLogCost
SIM.log("DEBUG caught=%s slowTicks=%s", tostring(caught), tostring(slow.slow))

local pass = hasTickTotal and hasLogStep and hasLock and hasAbortNext and hasKinds
    and caught and quietLines == 0 and quietPerf.quiet == "true"
SIM.log(pass and "PASS s33: the unaccounted stretch of the tick is visible and step logging can be muted"
    or "FAIL s33")
SIM.report("SCENARIO 33: whole-tick profiling")
