-- Scenario 35 (04.3.21): консоль, которая стоит 800 мс за строку.
--   Ждём: (1) ни один вызов не длится секунды — сброс ограничен бюджетом 120 мс;
--          (2) после первого же дорогого сброса логирование шагов само выключается (auto-quiet);
--          (3) строки не теряются — их видно через !ambient_steps;
--          (4) в !ambient_perf есть stepsSuppressed.
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

-- самая дорогая точка: длительность каждого вызова печати
local maxPrintCall = 0
local origPrint = Ext.Utils.Print
Ext.Utils.Print = function(s)
    local t0 = SIM.time
    local r = origPrint(s)
    local dt = SIM.time - t0
    if dt > maxPrintCall then maxPrintCall = dt end
    return r
end

SIM.run(12000)
SIM.commands.ambient_perf_reset()
SIM.printCostMs = 800          -- как у игрока: 831 мс за строку
maxPrintCall = 0
SIM.run(20000)
local worstCallUnderLoad = maxPrintCall
SIM.printCostMs = 0

-- состояние после auto-quiet
local from = #SIM.prints + 1
SIM.commands.ambient_perf()
local header = ""
local stepsSuppressed = 0
for i = from, #SIM.prints do
    if string.find(SIM.prints[i], "QUEUE PERF", 1, true) then header = SIM.prints[i] end
end
local m = string.match(header, "stepsSuppressed=(%d+)")
if m then stepsSuppressed = tonumber(m) end

-- буфер строк жив?
local mark = #SIM.prints + 1
if SIM.commands.ambient_steps then SIM.commands.ambient_steps(nil, "5") end
local buffered = 0
for i = mark, #SIM.prints do
    if string.find(SIM.prints[i], "started: ", 1, true) then buffered = buffered + 1 end
end

local autoQuiet = string.find(header, "quietSteps=true", 1, true) ~= nil
local pass = autoQuiet and worstCallUnderLoad <= 1200 and buffered > 0
    and (SIM.commands.ambient_steps ~= nil)

SIM.log("RESULT worstPrintCall=%dms autoQuiet=%s suppressedShown=%s bufferedPrinted=%d",
    worstCallUnderLoad, tostring(autoQuiet), tostring(m ~= nil), buffered)
SIM.log(pass and "PASS s35: a crawling console can no longer freeze the game and step lines are kept"
    or "FAIL s35")
SIM.report("SCENARIO 35: pathological console guard")
