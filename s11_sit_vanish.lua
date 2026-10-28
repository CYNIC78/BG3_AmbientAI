-- Scenario 11 (the user's report): several seats in the room; the scan order hands the
-- mod a bench on the far side. Old code walked/sat there (or snapped) and the companion
-- "vanished" from the player's view. New code must pick the CLOSEST seat and never sit
-- from a distance.
dofile("/home/user/sim/mock.lua")
dofile("/home/user/sim/scene.lua")
SIM.debugMCM = true
SIM.followModel = true

SCENE_SETUP({
    -- uuid order matters: the spatial sweep returns sorted handles, so the far bench comes first
    { "CHA_TWN_Bench_Far_A",   0.5, 0.0, 9.5, { kind = "prop", canUse = true, canPickUp = false } },
    { "CHA_TWN_Bench_Near_A",  1.6, 0.0, 1.6, { kind = "prop", canUse = true, canPickUp = false } },
})
SCENE_LOAD_MOD()

local satTpl = nil
local waited = 0
while waited < 200000 and not satTpl do
    SIM.run(1000); waited = waited + 1000
    for _, c in ipairs(CHARS) do
        local chair = SIM.seated[c]
        if chair then satTpl = ITEMINFO[chair] and ITEMINFO[chair].tpl break end
        if POS[c] and POS[c][2] < -1.0 then satTpl = "VOID" break end
    end
end
local hostX, hostZ = 0, 0
local distToHost = -1
for _, c in ipairs(CHARS) do
    if c ~= SIM.host and SIM.seated[c] then
        local p = POS[c]
        distToHost = math.sqrt((p[1]-hostX)^2 + (p[3]-hostZ)^2)
    end
end
SIM.log("RESULT seatedOn=%s | distToHostOfSeat=%.2fm", tostring(satTpl), distToHost)
SIM.report("SCENARIO 11: far bench vs near bench")
