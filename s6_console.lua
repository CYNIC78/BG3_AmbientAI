-- Scenario 6: exercise the new console commands (regression test for Lua runtime errors)
dofile("/home/user/sim/mock.lua")
dofile("/home/user/sim/scene.lua")
SCENE_SETUP({
    { "LTS_DUN_Candles_Cluster_A",  2.0, 0.0,  1.2, { engine = "none" } },
    { "LTS_TWN_Lamp_Standing_A",  -2.6, 0.0,  1.4, { engine = "status", constellation = true, canPickUp = false } },
})
SCENE_LOAD_MOD()
SIM.run(40000)
local lights = SIM.commands and SIM.commands["ambient_lights"]
local fix = SIM.commands and SIM.commands["ambient_light_fix"]
local reset = SIM.commands and SIM.commands["ambient_light_reset"]
print("commands registered:", tostring(lights ~= nil), tostring(fix ~= nil), tostring(reset ~= nil))
if lights then lights("ambient_lights", "25") end
if fix then fix("ambient_light_fix", "25") end
SIM.run(6000)
if lights then lights("ambient_lights", "25") end
if reset then reset() end
SCENE_RESULT("SCENARIO 6: console commands")
