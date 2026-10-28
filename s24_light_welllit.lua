-- Scenario 24 (04.3.10): "комната уже освещена" - не бегать зажигать остатки
--   SIM.litCount = сколько светильников уже горит при старте (3 = комната светлая, 1 = тёмная)
--   Один незажжённый светильник в ~8 м.
--   litCount=3 -> НЕ должен зажигаться (лог "room already lit"); litCount=1 -> должен зажигаться.
if not SIM then dofile("/home/user/sim/mock.lua") end
dofile("/home/user/sim/scene.lua")

local LIT = { preStatuses = { "BURNING" }, gameplayLightActive = true, engine = "status" }
local DARK = { engine = "status" }
local want = SIM.litCount
SIM.litCount = want

SCENE_SETUP({
    { "LTS_TWN_Candle_Shelf_A", 2.2, 0.0, 1.3, (want >= 1) and LIT or DARK },
    { "LTS_TWN_Candle_Shelf_B", -2.4, 0.0, 1.5, (want >= 2) and LIT or DARK },
    { "LTS_TWN_Candle_Shelf_C", 1.4, 0.0, -2.2, (want >= 3) and LIT or DARK },
    -- единственный незажжённый, далеко (~8 м)
    { "LTS_TWN_Candle_Table_A", 6.6, 0.0, 6.6, DARK },
})

SIM.debugMCM = true
SCENE_LOAD_MOD()
SIM.run(180000)

local farLit = false
for _, pr in pairs(SIM.prints) do end
for _, info in pairs(ITEMINFO) do
    if info.tpl == "LTS_TWN_Candle_Table_A" and info.lit then farLit = true end
end

local wellLitLog = 0
for _, line in ipairs(SIM.prints) do
    if string.find(line, "room already lit", 1, true) then wellLitLog = wellLitLog + 1 end
end

local litAtStart = want
SIM.log("RESULT alreadyLitAtStart=%d | farFixtureIgnd=%s | roomAlreadyLitLogs=%d",
    litAtStart, tostring(farLit), wellLitLog)

local litEnded = 0
for _, info in pairs(ITEMINFO) do
    if info.kind == "light" and info.lit then litEnded = litEnded + 1 end
end
SIM.log("RESULT fixtures lit at the end = %d (started %d)", litEnded, litAtStart)

local pass
if litAtStart >= 3 then
    -- комната уже светлая: дальний не трогаем
    pass = (not farLit) and wellLitLog > 0
else
    -- комната тёмная: боты должны хотя бы начать освещать
    pass = litEnded > litAtStart
end
SIM.log(pass and "PASS s24" or "FAIL s24")
SIM.report("SCENARIO 24: room already lit -> no candle marathon")
