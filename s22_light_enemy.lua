-- Scenario 22 (04.3.10): "не зажигать свет при врагах поблизости"
--   0-45s  : один живой враг в ~5 м от группы, тёмная комната, 4 незажжённые свечи
--            ожидание: НИ одной свечи не зажжено
--   45s    : враг уходит на 60 м
--   до 160s: ожидание: свечи начинают зажигаться => гейт не выключил механику навсегда
dofile("/home/user/sim/mock.lua")
dofile("/home/user/sim/scene.lua")

local ENEMY = "dddddddd-0000-0000-0000-000000000001"
local ENEMY_LEAVES_AT = 90000

SCENE_SETUP({
    { "LTS_DUN_Candles_Cluster_A",  2.0, 0.0,  1.2 },
    { "LTS_DUN_Candles_Cluster_B", -2.6, 0.0,  1.4 },
    { "LTS_DUN_Wall_Sconce_A",      3.4, 1.8, -0.6, { canPickUp = false } },
    { "LTS_TWN_Candle_Table_A",     2.8, 0.0,  2.4 },
}, {
    preSession = function()
        SIM.addChar(ENEMY, "S_Goblin_Archer", 5.5, 0.0, 5.0)
        SIM.setEnemy(ENEMY, true)
    end,
})

SIM.debugMCM = true
SCENE_LOAD_MOD()

SIM.addTimer(ENEMY_LEAVES_AT, function()
    SIM.log("### enemy leaves the room (moves 60m away)")
    SIM.moveChar(ENEMY, 60.0, 0.0, 60.0)
end)

SIM.run(200000)

-- ---- проверки -------------------------------------------------------------
local litDuring, litAfter = 0, 0
for _, line in ipairs(SIM.prints) do
    local ts = tonumber(string.match(line, "^(%d+)"))
    if string.find(line, "lit via", 1, true) then
        if ts and ts < ENEMY_LEAVES_AT then
            litDuring = litDuring + 1
        else
            litAfter = litAfter + 1
        end
    end
end

local skipLogged = 0
for _, line in ipairs(SIM.prints) do
    if string.find(line, "Light layer skipped: enemy_nearby", 1, true) then
        skipLogged = skipLogged + 1
    end
end

local litCount, total = 0, 0
for _, info in pairs(ITEMINFO) do
    if info.kind == "light" then
        total = total + 1
        if info.lit then litCount = litCount + 1 end
    end
end

SIM.log("RESULT fixtures lit BEFORE the enemy left = %d (want 0) | after = %d (want > 0)", litDuring, litAfter)
SIM.log("RESULT skip messages in log = %d | world lit %d/%d", skipLogged, litCount, total)

local pass = (litDuring == 0) and (litAfter > 0)
SIM.log(pass and "PASS s22: no fixture was lit while a hostile stood next to the party, lighting resumed after it left"
    or "FAIL s22")
SIM.report("SCENARIO 22: light discipline around enemies")
