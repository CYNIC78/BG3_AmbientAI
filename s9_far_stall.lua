-- Scenario 9: the fixture is effectively unreachable (huge obstacle) - we only check that
-- the mod now says WHY, retries in 90s instead of blacklisting for 30 minutes, and keeps
-- serving the rest of the room.
dofile("/home/user/sim/mock.lua")
dofile("/home/user/sim/scene.lua")
SIM.debugMCM = true
SCENE_SETUP({
    { "LTS_DUN_Wall_Sconce_A", 0.0, 0.0, 5.0, { engine = "status", canPickUp = false } },
    { "LTS_DUN_Candles_Cluster_B", -3.0, 0.0, 1.0, { engine = "status" } },
})
SIM.addObstacle(0.0, 5.0, 6.0, 0.7)
SCENE_LOAD_MOD()
SIM.run(180000)
SCENE_RESULT("SCENARIO 9: unreachable fixture - diagnosis + short cooldown")
