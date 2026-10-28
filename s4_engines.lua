-- Scenario 4 (realistic engine classes):
--   * LTS_TWN_Lamp_Standing_A : Constellation lamp. The mod SKIPS BURNING for this class,
--     and its "TurnOn" socket does nothing -> original build can never light it.
--   * LTS_DUN_Wall_Sconce_A   : only the game's own "Use" interaction works (CanUse = false,
--     so the original "fill in" fallback never runs).
--   * LTS_DUN_Candles_Cluster_A : classic BURNING candle.
dofile("/home/user/sim/mock.lua")
dofile("/home/user/sim/scene.lua")
SCENE_SETUP({
    { "LTS_TWN_Lamp_Standing_A",   2.0, 0.0,  1.2, { engine = "status", constellation = true, canPickUp = false } },
    { "LTS_DUN_Wall_Sconce_A",    -2.6, 0.0,  1.4, { engine = "use",    canPickUp = false, canUse = false } },
    { "LTS_DUN_Candles_Cluster_A", 3.4, 0.0, -0.6, { engine = "status" } },
})
SCENE_LOAD_MOD()
SIM.run(120000)
SCENE_RESULT("SCENARIO 4: per-class ignition engines")
