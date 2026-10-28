-- Scenario 13: the seat claims to be sittable (CanSitOn = 1) but the repose silently fails
-- (some decor benches / modded props behave like this). The companion must not be left in
-- the broken pose with the follow block on.
dofile("/home/user/sim/mock.lua")
dofile("/home/user/sim/scene.lua")
SIM.debugMCM = true
SIM.followModel = true
SCENE_SETUP({
    { "CHA_TWN_Bench_Silent_A", 1.7, 0.0, 1.7, { kind = "prop", canUse = true, canPickUp = false, sittable = "silent" } },
})
SCENE_LOAD_MOD()
local void, waited = false, 0
while waited < 120000 and not void do
    SIM.run(500); waited = waited + 500
    for _, c in ipairs(CHARS) do
        if POS[c] and POS[c][2] < -1.0 then void = true end
    end
end
SIM.log("RESULT brokenPose=%s at t=%.1fs", tostring(void), SIM.time/1000)
SIM.run(5000)
local stuck = 0
for _, c in ipairs(CHARS) do
    if POS[c] and POS[c][2] < -1.0 then stuck = stuck + 1 end
end
SIM.log("RESULT stillBroken=%d", stuck)
SIM.report("SCENARIO 13: seat that silently fails")
