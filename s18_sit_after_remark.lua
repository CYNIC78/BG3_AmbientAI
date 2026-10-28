-- Scenario 18: "Gale did not sit down any more" (log from 04.3.7)
-- The tired remark played an overhead PAD *before* the sit. A talking character cannot enter
-- Repose, so the pose never took, the 1.2 s check declared failure and a good bench was banned.
dofile("/home/user/sim/mock.lua")
dofile("/home/user/sim/scene.lua")
SIM.padsWork = true
SIM.debugMCM = true
SIM.reposeDelay = 600
-- tired party, so the rest-reminder pad in SeatTiredRemark is allowed
SCENE_SETUP({
    { "FUR_Dungeon_Bench_Stone_C_029", 1.7, 0.0, 1.5, { kind = "prop", canUse = true, canPickUp = false } },
}, { party = { hp = 55, slotLevel = 3, slotsMax = 4, slotsUsed = 2 } })
SCENE_LOAD_MOD()

local seatedAt = nil
local waited = 0
while waited < 240000 and not seatedAt do
    SIM.run(250); waited = waited + 250
    for _, c in ipairs(CHARS) do
        if SIM.seated[c] and not seatedAt then seatedAt = SIM.time end
    end
end

local refused, sat, noRepose = 0, 0, 0
for _, l in ipairs(SIM.prints) do
    if l:find("REFUSED (character is in a dialog)", 1, true) then refused = refused + 1 end
    if l:find("started: SitOnSeat", 1, true) then sat = sat + 1 end
    if l:find("did NOT enter repose", 1, true) then noRepose = noRepose + 1 end
end
-- let the seated companion finish the remark + relax, then stand up cleanly
SIM.run(8000)
local stillSeated = 0
for _, c in ipairs(CHARS) do if SIM.seated[c] then stillSeated = stillSeated + 1 end end

SIM.log("RESULT sitAttempts=%d sitOnEntityRefused=%d noReposeFailures=%d seatedAt=%s",
    sat, refused, noRepose, seatedAt and string.format("%.1fs", seatedAt / 1000) or "never")
SIM.log("RESULT VERDICT %s", (sat > 0 and noRepose == 0) and "PASS (companion actually sits)" or "FAIL")
SIM.report("SCENARIO 18: sit after the tired remark (dialog overlap)")
