-- Scenario 20: the companion is still finishing a spoken line when the sit starts.
-- BG3 silently refuses to repose a talking character. 04.3.7 called SitOnEntity anyway
-- ("did NOT enter repose" + a good bench banned), 04.3.8 waits for the line to end.
dofile("/home/user/sim/mock.lua")
dofile("/home/user/sim/scene.lua")
SIM.padsWork = true
SIM.debugMCM = true
SIM.reposeDelay = 600
SCENE_SETUP({
    { "FUR_Dungeon_Bench_Stone_C_029", 1.7, 0.0, 1.5, { kind = "prop", canUse = true, canPickUp = false } },
}, { party = { hp = 55, slotLevel = 3, slotsMax = 4, slotsUsed = 2 } })
SCENE_LOAD_MOD()

-- As soon as a companion starts walking to the bench, pretend he is still voicing a line
-- for 4 seconds (the overhead PAD from SeatTiredRemark / a banter that is still playing).
local marked, seen = {}, 0
local seatedAt, deadline = nil, SIM.time + 240000
while SIM.time < deadline and not seatedAt do
    SIM.run(100)
    for i = seen + 1, #SIM.prints do
        local l = SIM.prints[i]
        local char = l:match("(%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x) started: WalkNearSeat")
        if char and not marked[char] then
            marked[char] = true
            SIM.speaking[SIM.clean(char)] = SIM.time + 4000
            SIM.log("TEST: %s is still finishing a spoken line for 4s", SIM.clean(char))
        end
    end
    seen = #SIM.prints
    for _, c in ipairs(CHARS) do
        if SIM.seated[c] and not seatedAt then seatedAt = SIM.time end
    end
end
SIM.run(6000)

local refused, noRepose, sits = 0, 0, 0
for _, l in ipairs(SIM.prints) do
    if l:find("REFUSED (character is in a dialog)", 1, true) then refused = refused + 1 end
    if l:find("did NOT enter repose", 1, true) then noRepose = noRepose + 1 end
    if l:find("sits on", 1, true) and l:find("[SEAT]", 1, true) then sits = sits + 1 end
end
SIM.log("RESULT engineRefusedWhileTalking=%d | noReposeFailures=%d | sitAttempts=%d | seatedAt=%s",
    refused, noRepose, sits, seatedAt and string.format("%.1fs", seatedAt / 1000) or "never")
SIM.log("RESULT VERDICT %s", (refused == 0 and seatedAt ~= nil) and "PASS (waited for the line, then sat)"
    or "FAIL (spoke and sat collide)")
SIM.report("SCENARIO 20: sit while the companion is still talking")
