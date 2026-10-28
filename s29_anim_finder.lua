-- Scenario 29 (04.3.15): проверка команд поиска анимационных ресурсов.
-- Мок отдаёт фейковый список Animation-ресурсов; смотрим, что finder находит триплет
-- Writing (Start/Loop/End) и что test проигрывает именно триплет, а не голый луп.
dofile("/home/user/sim/mock.lua")
dofile("/home/user/sim/scene.lua")

SIM.animBanks = { Animation = {
    "11111111-0000-0000-0000-000000000001",
    "22222222-0000-0000-0000-000000000002",
    "33333333-0000-0000-0000-000000000003",
    "44444444-0000-0000-0000-000000000004",
} }
SIM.animResourceData = {
    ["11111111-0000-0000-0000-000000000001"] = { Name = "CUST_Writing_02_Start", SourceFile = "CUST_Writing_02_Start.gr2" },
    ["22222222-0000-0000-0000-000000000002"] = { Name = "CUST_Writing_02_Loop",  SourceFile = "CUST_Writing_02_Loop.gr2" },
    ["33333333-0000-0000-0000-000000000003"] = { Name = "CUST_Writing_02_End",   SourceFile = "CUST_Writing_02_End.gr2" },
    ["44444444-0000-0000-0000-000000000004"] = { Name = "CUST_Pondering_01_Loop" },
}

SCENE_SETUP({})
SIM.debugMCM = true
SCENE_LOAD_MOD()
SIM.run(2000)

-- команда должна быть зарегистрирована
SIM.log("PROBE has_find=%s has_test=%s",
    tostring(SIM.commands.ambient_anim_find ~= nil),
    tostring(SIM.commands.ambient_anim_test ~= nil))

SIM.commands.ambient_anim_find(nil, nil)     -- без аргумента: дамп полей структуры ресурса
SIM.run(1000)
SIM.commands.ambient_anim_find(nil, "Writing")
SIM.run(3000)

local found = {}
for i = 1, #SIM.prints do
    local line = SIM.prints[i]
    if string.find(line, "CUST_Writing_02", 1, true) then found[#found + 1] = line end
end
local count = #found

SIM.loopingAnim = nil
SIM.loopingAnims = nil
SIM.commands.ambient_anim_test(nil, "CUST_Writing_02")
local triple = SIM.loopingAnim or {}
local okTriplet = tostring(triple.start or ""):find("Writing_02_Start", 1, true) ~= nil
    and tostring(triple.stop or ""):find("Writing_02_End", 1, true) ~= nil

SIM.log("RESULT listed=%d tripletPlayed=%s start=%s loop=%s stop=%s",
    count, tostring(okTriplet), tostring(triple.start), tostring(triple.loop), tostring(triple.stop))

local pass = count >= 3 and okTriplet
SIM.log(pass and "PASS s29: finder lists the triplet and test plays start+loop+end"
    or "FAIL s29")
SIM.report("SCENARIO 29: animation resource finder")
