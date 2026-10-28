-- Scenario 21: the walk action runs out of its 25 s while the companion is standing next to
-- the bench (04.3.8 playtest: "could not reach ... -> cooldown 300s (kept)" right before
-- "sits on <the same bench>"). The seat must not be banned in that case.
dofile("/home/user/sim/mock.lua")
dofile("/home/user/sim/scene.lua")
SIM.padsWork = true
SIM.debugMCM = true
SCENE_SETUP({
    { "FUR_Dungeon_Bench_Stone_C_029", 1.7, 0.0, 1.5, { kind = "prop", canUse = true, canPickUp = false } },
}, { party = { hp = 55, slotLevel = 3, slotsMax = 4, slotsUsed = 2 } })
-- make IsMoving report "still walking" forever for one companion: the walk action can never
-- complete, but the companion is physically right next to the bench
SIM.stuckMoving = {}
SCENE_LOAD_MOD()

-- Only pretend "still walking" *after* the walk action has started: this reproduces an engine
-- where arrival can never be confirmed, while the companion physically reaches the bench.
local marked, seen, clearAt = {}, 0, nil
local seatedAt, deadline = nil, SIM.time + 200000
while SIM.time < deadline and not seatedAt do
    SIM.run(250)
    for i = seen + 1, #SIM.prints do
        local l = SIM.prints[i]
        local char = l:match("(%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x) started: WalkNearSeat")
        if char and not marked[char] then
            marked[char] = true
            SIM.stuckMoving[SIM.clean(char)] = true
            clearAt = SIM.time + 26000
            SIM.log("TEST: %s WalkNearSeat started, IsMoving stuck ON for 26s", SIM.clean(char))
        end
    end
    seen = #SIM.prints
    if clearAt and SIM.time > clearAt then
        SIM.stuckMoving = {}
        clearAt = nil
    end
    for _, c in ipairs(CHARS) do if SIM.seated[c] and not seatedAt then seatedAt = SIM.time end end
end
SIM.run(4000)

local banned, lateArrival, noRepose = 0, 0, 0
for _, l in ipairs(SIM.prints) do
    if l:find("could not reach", 1, true) then banned = banned + 1 end
    if l:find("late arrival at", 1, true) then lateArrival = lateArrival + 1 end
    if l:find("did NOT enter repose", 1, true) then noRepose = noRepose + 1 end
end
SIM.log("RESULT bannedAsUnreachable=%d | lateArrivalAccepted=%d | noReposeFailures=%d | seatedAt=%s",
    banned, lateArrival, noRepose, seatedAt and string.format("%.1fs", seatedAt / 1000) or "never")
SIM.log("RESULT VERDICT %s", (banned == 0 and seatedAt ~= nil) and "PASS" or "FAIL")
SIM.report("SCENARIO 21: walk timeout while already in reach")
