-- Scenario 19: many sit cycles with overhead PADs enabled, tired party.
-- Counts how often the sit is started while the companion is still talking (dialog overlap),
-- how many of those end in "did NOT enter repose", and how many seats really happen.
dofile("/home/user/sim/mock.lua")
dofile("/home/user/sim/scene.lua")
SIM.padsWork = true
SIM.debugMCM = true
SIM.reposeDelay = 600
SIM.padDuration = 4000     -- a spoken line lasts a few seconds; SeatTiredRemark waits max 2.6 s
SCENE_SETUP({
    { "FUR_Dungeon_Bench_Stone_A", 1.7, 0.0, 1.5, { kind = "prop", canUse = true, canPickUp = false } },
    { "FUR_Dungeon_Bench_Stone_B", -1.9, 0.0, 2.4, { kind = "prop", canUse = true, canPickUp = false } },
    { "CHA_TWN_Bench_C", 2.4, 0.0, -1.7, { kind = "prop", canUse = true, canPickUp = false } },
}, { party = { hp = 55, slotLevel = 3, slotsMax = 4, slotsUsed = 2 } })
SCENE_LOAD_MOD()
SIM.run(600000)

local sits, refused, noRepose, seatedOK = 0, 0, 0, 0
for _, l in ipairs(SIM.prints) do
    if l:find("[SEAT]", 1, true) then
        if l:find("sits on", 1, true) then sits = sits + 1 end
        if l:find("did NOT enter repose", 1, true) then noRepose = noRepose + 1 end
    end
    if l:find("REFUSED (character is in a dialog)", 1, true) then refused = refused + 1 end
    if l:find("WORLD:", 1, true) and l:find("SNAPPED to socket", 1, true) then seatedOK = seatedOK + 1 end
end
SIM.log("RESULT sitStarts=%d | engineRefusedWhileTalking=%d | seatPoses=%d | noReposeFailures=%d",
    sits, refused, seatedOK, noRepose)
SIM.log("RESULT VERDICT %s", (refused == 0 and noRepose == 0 and seatedOK > 0) and "PASS" or "FAIL")
SIM.report("SCENARIO 19: sits vs overhead lines (10 min, tired party)")
