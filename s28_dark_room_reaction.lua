-- Scenario 28: время реакции на тёмную комнату.
-- Игрок входит в тёмную комнату, останавливается -> измеряем, через сколько КАЖДЫЙ
-- сопартиец начинает первое действие (started: X) после остановки.
-- Запуск:  python3 sim/run_scenario.py sim/s28_dark_room_reaction.lua <mod> "DELAY_OVERRIDE=5"
dofile("/home/user/sim/mock.lua")
dofile("/home/user/sim/scene.lua")

SIM.debugMCM = true
SIM.walkSpeed = 3.0

local SIMX = SIM
local origGet = MCM.Get
MCM.Get = function(id)
    if id == "AmbientAI_GroupedIdleDelay" then return tonumber(_G.DELAY_OVERRIDE) or 5 end
    return origGet(id)
end

SCENE_SETUP({
    { "LTS_TWN_Candle_Shelf_A", 3.2, 0.0, 4.2, { engine = "status" } },
    { "LTS_TWN_Candle_Shelf_B", 0.4, 0.0, 5.0, { engine = "status" } },
    { "LTS_TWN_Candle_Shelf_C", -3.0, 0.0, 4.4, { engine = "status" } },
    { "LTS_TWN_Candle_Table_A", 5.4, 0.0, 5.6, { engine = "status" } },
})
-- третий сопартиец, чтобы был виден "последний в очереди"
SIM.addChar("aaaaaaaa-0000-0000-0000-000000000004", "S_Player_Astarion", -2.1, 0.0, 2.3, {})
SIM.markLitDummy = nil
SCENE_LOAD_MOD()

-- входим в комнату
SIM.moves[SIM.host] = { tx = 0.0, ty = 0.0, tz = 4.0 }
SIM.run(1400)
SIM.moves[SIM.host] = nil
local stopAt = SIM.time
SIM.log("### host stopped at t=%.1fs in a dark room", stopAt / 1000)

SIM.run(26000)

local function firstActionAfter(key, since)
    local pat = key .. " started: "
    for i = 1, #SIM.prints do
        if string.find(SIM.prints[i], pat, 1, true) then
            local t = tonumber(string.match(SIM.prints[i], "^%s*(%d+)"))
            if t and t >= since then return t end
        end
    end
    return nil
end

local c2 = firstActionAfter("aaaaaaaa-0000-0000-0000-000000000002", stopAt)
local c3 = firstActionAfter("aaaaaaaa-0000-0000-0000-000000000003", stopAt)
local c4 = firstActionAfter("aaaaaaaa-0000-0000-0000-000000000004", stopAt)
local function ms(v) return v and (v - stopAt) or -1 end

SIM.log("RESULT delay=%ss c2=%dms c3=%dms c4=%dms",
    tostring(tonumber(_G.DELAY_OVERRIDE) or 5), ms(c2), ms(c3), ms(c4))
SIM.report("SCENARIO 28: dark room reaction time")
