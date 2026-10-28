-- Scenario 27: сколько работы реально начинается/срывается при разной паузе
-- "Grouped Idle Delay". Игрок «лутается»: 1 с ходьбы, 2.5 с стоит, и так 12 раз.
-- Меряем: сколько действий боты начали и сколько из них было прервано (grouped_active).
-- Запуск:  python3 sim/run_scenario.py sim/s27_idle_delay.lua <mod> <delaySec>
dofile("/home/user/sim/mock.lua")
dofile("/home/user/sim/scene.lua")

SIM.debugMCM = true
SIM.walkSpeed = 3.0

-- подменяем значение слайдера MCM до загрузки мода
local SIMX = SIM
local origGet = MCM.Get
MCM.Get = function(id)
    if id == "AmbientAI_GroupedIdleDelay" then return tonumber(_G.DELAY_OVERRIDE) or 5 end
    return origGet(id)
end

SCENE_SETUP({
    { "CHA_TWN_Chair_Wood_A",   2.2, 0.0, 1.0, { kind = "prop", canUse = true, canPickUp = false, sittable = true } },
    { "S_TWN_Candle_01",        3.0, 0.0, 2.0, { kind = "light", canUse = true, canPickUp = false } },
    { "S_TWN_Bookshelf_A",      2.6, 0.0, 3.0, { kind = "prop", canUse = true, canPickUp = false } },
    { "OBJ_TWN_Crate_A",        1.4, 0.0, 3.4, { kind = "container", canUse = true, canPickUp = false, isContainer = true } },
    { "S_TWN_Candle_02",        4.2, 0.0, 0.4, { kind = "light", canUse = true, canPickUp = false } },
    { "S_TWN_Candle_03",        5.0, 0.0, 2.6, { kind = "light", canUse = true, canPickUp = false } },
})
SCENE_LOAD_MOD()

local function countMatches(token)
    local n = 0
    for i = 1, #SIM.prints do
        if string.find(SIM.prints[i], token, 1, true) then n = n + 1 end
    end
    return n
end

local PATH = { { 0, 0, 0 }, { 0.6, 0, 3.6 }, { -0.6, 0, 0.2 } }
local stops = tonumber(_G.STOPS) or 12
local STOP_MS = tonumber(_G.STOP_MS) or 2500
for k = 1, stops do
    local tgt = PATH[(k % #PATH) + 1]
    SIM.moves[SIM.host] = { tx = tgt[1], ty = tgt[2], tz = tgt[3] }
    SIM.run(1400)                       -- идём ~1.2 м
    SIM.moves[SIM.host] = nil
    SIM.run(STOP_MS)                    -- остановка «залутать»
end

local started = countMatches(" started: ")
local aborted = countMatches("grouped_active")
local tried = countMatches("[ACT]")
SIM.log("DELAY=%s stops=%d started=%d aborted_on_move=%d",
    tostring(tonumber(_G.DELAY_OVERRIDE) or 5), stops, started, aborted)
SIM.log("RESULT delay=%ss stopMs=%d started=%d aborted=%d",
    tostring(tonumber(_G.DELAY_OVERRIDE) or 5), STOP_MS, started, aborted)
local errs = 0
for i = 1, #SIM.prints do
    if string.find(SIM.prints[i], "TIMER-ERROR", 1, true) or string.find(SIM.prints[i], "LuaError", 1, true) then
        errs = errs + 1
    end
end
SIM.log("ERRSTAT errors=%d", errs)
SIM.report("SCENARIO 27: idle delay vs started/aborted actions")
