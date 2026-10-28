-- Scenario 12: the only seat advertises CanUse but has no sit socket (decor bench).
-- Old code: character "vanishes" into a void pose, follow block stays ON, no blacklist.
-- New code: no repose -> stand back up, release follow, avoid that seat.
dofile("/home/user/sim/mock.lua")
dofile("/home/user/sim/scene.lua")
SIM.debugMCM = true
SIM.followModel = true
SCENE_SETUP({
    { "CHA_TWN_Bench_Decor_A", 1.7, 0.0, 1.7, { kind = "prop", canUse = true, canPickUp = false, sittable = false } },
})
SCENE_LOAD_MOD()
local void, waited = false, 0
while waited < 200000 and not void do
    SIM.run(500); waited = waited + 500
    for _, c in ipairs(CHARS) do
        if POS[c] and POS[c][2] < -1.0 then void = true end
    end
end
SIM.log("RESULT voidPose=%s at t=%.1fs", tostring(void), SIM.time/1000)
-- let the verification timer fire
SIM.run(4000)
local stuck = 0
for _, c in ipairs(CHARS) do
    if POS[c] and POS[c][2] < -1.0 then stuck = stuck + 1 end
end
SIM.log("RESULT stillInVoid=%d | blacklisted=%s",
    stuck, tostring((function()
        local n = 0
        for _, i in pairs(ITEMINFO) do n = n + 1 end
        return n
    end)()))
SIM.report("SCENARIO 12: seat without a sit socket")
