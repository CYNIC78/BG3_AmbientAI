-- Scenario 5: loading a save where fixtures were lit by AmbientAI last session but load dark.
-- The mod must re-arm them from PersistentVars.LitByAmbientAI without any walking.
dofile("/home/user/sim/mock.lua")
dofile("/home/user/sim/scene.lua")
SCENE_SETUP({
    { "LTS_DUN_Candles_Cluster_A",  2.0, 0.0,  1.2, { engine = "status" } },
    { "LTS_DUN_Candles_Cluster_B", -2.6, 0.0,  1.4, { engine = "status" } },
    { "LTS_TWN_Candle_Table_A",     2.8, 0.0,  2.4, { engine = "status" } },
})
-- pretend a previous session lit them
PersistentVars.LitByAmbientAI = {}
for _, d in ipairs({ "bbbbbbbb-0000-0000-0000-000000000001",
                     "bbbbbbbb-0000-0000-0000-000000000002",
                     "bbbbbbbb-0000-0000-0000-000000000003" }) do
    PersistentVars.LitByAmbientAI[d] = true
end
SCENE_LOAD_MOD()
SIM.run(10000)   -- only 10s: no companion has even woken up yet
SCENE_RESULT("SCENARIO 5: save re-arm after load")
