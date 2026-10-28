-- Scenario 8 (reproduces the user's log): the candle stands on a table / altar and the
-- AI grid does not let a companion closer than ~3.2 m. Old code required 2.85 m to count
-- as "arrived", so the queue went silent and the fixture got a 30-minute blacklist.
dofile("/home/user/sim/mock.lua")
dofile("/home/user/sim/scene.lua")
SIM.debugMCM = true                     -- MCM "Debug Logging" ON, like in the user's log
SCENE_SETUP({
    { "LTS_TWN_Candle_Table_A", 0.0, 0.0, 4.0, { engine = "status" } },
})
SIM.addObstacle(0.0, 4.0, 2.65, 0.55)   -- table around the candle: closest stand ~3.2 m
SCENE_LOAD_MOD()
SIM.run(120000)
SCENE_RESULT("SCENARIO 8: table blocks the approach (arrival 2.85m unreachable)")
