-- Scenario 2: save made AFTER the mod lit the candles (BURNING status stored in the save),
-- but on load the fixtures are visually dark again (light VFX/GameplayLight not restored).
dofile("/home/user/sim/mock.lua")
dofile("/home/user/sim/scene.lua")

local STALE = { preStatuses = { "BURNING" }, gameplayLightActive = false, engine = "status" }
SCENE_SETUP({
    { "LTS_DUN_Candles_Cluster_A",  2.0, 0.0,  1.2, STALE },
    { "LTS_DUN_Candles_Cluster_B", -2.6, 0.0,  1.4, STALE },
    { "LTS_DUN_Wall_Sconce_A",      3.4, 1.8, -0.6, { preStatuses={"BURNING"}, canPickUp=false, engine="status" } },
    { "LTS_TWN_Candle_Table_A",     2.8, 0.0,  2.4, STALE },
})
SCENE_LOAD_MOD()
SIM.run(120000)
SCENE_RESULT("SCENARIO 2: old save, fixtures still carry BURNING but are dark")
