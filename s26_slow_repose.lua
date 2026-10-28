-- Scenario 26 (04.3.11): медленный blend позы (3.5 с) не должен «палить» скамью
--   SitOnSeat — единственное СТАЦИОНАРНОЕ действие без duration, поэтому на него срабатывал
--   stall-watchdog «нет движения 2.8 с»: скамья уходила в бан на 30 минут, персонажа
--   выдёргивало из позы, очередь чистилась -> "не сел".
--   Ожидание 04.3.11: сопартиец садится, скамья не банится.
dofile("/home/user/sim/mock.lua")
dofile("/home/user/sim/scene.lua")

SIM.reposeDelay = 3500          -- поза «доезжает» 3.5 с (медленный blend / тяжёлый кадр)
SIM.debugMCM = true

SCENE_SETUP({
    { "CHA_TWN_Chair_Wood_A", 2.2, 0.0, 1.4, { kind = "prop", canUse = true, canPickUp = false } },
})

SCENE_LOAD_MOD()

local guard = 0
local seated = nil
while guard < 300 and not seated do
    SIM.run(1000)
    guard = guard + 1
    for _, c in ipairs(CHARS) do
        if SIM.seated[c] then seated = c break end
    end
end

SIM.run(20000)

local stallLine = false
for _, line in ipairs(SIM.prints) do
    if string.find(line, "made no progress for 2.8s", 1, true) then stallLine = true end
end

SIM.log("RESULT seated=%s (after %ss) | stallWatchdogFired=%s", tostring(seated), tostring(guard), tostring(stallLine))
SIM.log(seated ~= nil and "PASS s26: a slow repose blend no longer kills the seat" or "FAIL s26")
SIM.report("SCENARIO 26: slow repose blend vs stall watchdog")
