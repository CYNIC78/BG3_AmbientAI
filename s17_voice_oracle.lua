-- Scenario 17: the voice oracle itself - is it reading HP / spell slots correctly?
dofile("/home/user/sim/mock.lua")
dofile("/home/user/sim/scene.lua")
SIM.debugMCM = true
SCENE_SETUP({}, { party = { hp = 100, slotLevel = 3, slotsMax = 4, slotsUsed = 0 } })
SCENE_LOAD_MOD()
SIM.run(3000)
local function dump(tag)
    local out = {}
    for _, l in ipairs(SIM.prints) do
        if l:find("VOICE HEALTH", 1, true) or l:find("rest-reminder lines", 1, true) then out[#out + 1] = l end
    end
    SIM.prints = {}
    SIM.log("--- %s ---", tag)
    for _, l in ipairs(out) do SIM.log("%s", l:gsub("^%s*%d+%s+", "")) end
end
SIM.commands.ambient_voice()
dump("fresh party: 100% hp, 0/4 slots used")
SIM.setHp("aaaaaaaa-0000-0000-0000-000000000003", 40)
SIM.commands.ambient_voice()
dump("one companion at 40% hp")
SIM.setHp("aaaaaaaa-0000-0000-0000-000000000003", 100)
SIM.setSlots("aaaaaaaa-0000-0000-0000-000000000003", 3)
SIM.commands.ambient_voice()
dump("full hp, 3 of 4 slots spent")
SIM.report("SCENARIO 17: !ambient_voice oracle")
