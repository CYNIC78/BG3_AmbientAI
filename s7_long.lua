-- Scenario 7: 5-minute stability run, mixed engine classes incl. one fixture that refuses to light
dofile("/home/user/sim/mock.lua")
dofile("/home/user/sim/scene.lua")
SCENE_SETUP({
    { "LTS_DUN_Candles_Cluster_A",  2.0, 0.0,  1.2, { engine = "status" } },
    { "LTS_DUN_Candles_Cluster_B", -2.6, 0.0,  1.4, { engine = "status" } },
    { "LTS_TWN_Lamp_Standing_A",    3.4, 0.0, -0.6, { engine = "status", constellation = true, canPickUp = false } },
    { "LTS_DUN_Wall_Sconce_A",     -3.6, 1.6, -1.4, { engine = "use", canPickUp = false } },
    { "LTS_DUN_Candles_Broken_A",   1.4, 0.0,  3.4, { engine = "none" } },  -- never works
})
SCENE_LOAD_MOD()
SIM.run(300000)
-- count how many times each fixture was touched
local counts = {}
for _, l in ipairs(SIM.prints) do
    local tpl = l:match("ConstellationTriggerInputSocket%(([%w_]+)")
    if tpl then counts[tpl] = (counts[tpl] or 0) + 1 end
end
for k, v in pairs(counts) do SIM.log("TOUCHES %-30s %d", k, v) end
SCENE_RESULT("SCENARIO 7: 5 min stability / anti-spam")
