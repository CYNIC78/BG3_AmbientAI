-- Scenario 10 (the user's report): a companion sits on a chair, the player walks away.
-- Old builds released the party-follow block while she was still reposed -> the engine
-- snapped her behind the player instead of letting her stand up and run.
dofile("/home/user/sim/mock.lua")
dofile("/home/user/sim/scene.lua")
SIM.debugMCM = true
SIM.followModel = true

SCENE_SETUP({
    { "CHA_TWN_Chair_Wood_A", 1.9, 0.0, 1.9, { kind = "prop", canUse = true, canPickUp = false } },
})
SCENE_LOAD_MOD()

-- Phase 1: wait (max 200s) until somebody is actually sitting, then act immediately
local seatWho, waited = nil, 0
while waited < 200000 and not seatWho do
    SIM.run(1000)
    waited = waited + 1000
    for _, c in ipairs(CHARS) do
        if SIM.seated[c] then seatWho = c break end
    end
end
SIM.log("PHASE1 (t=%.1fs): seated=%s", SIM.time / 1000, tostring(seatWho))

-- Phase 2: the player walks away, well past the idle anchor
Osi.CharacterMoveToPosition(SIM.host, 16.0, 0.0, 16.0, "Run", "")
SIM.run(16000)

-- Phase 3: verdict
for _, t in ipairs(SIM.teleports) do
    SIM.log("RESULT engine teleported %s at t=%.1fs", tostring(t.char), t.at / 1000)
end
if seatWho then
    local p, hp = POS[seatWho], POS[SIM.host]
    local d = math.sqrt((p[1] - hp[1]) ^ 2 + (p[3] - hp[3]) ^ 2)
    SIM.log("RESULT sitter=%s stillReposed=%s distToHost=%.1fm", tostring(seatWho),
        tostring(SIM.seated[seatWho] ~= nil), d)
end
SIM.log("RESULT engine catch-up teleports: %d", #SIM.teleports)
SIM.report("SCENARIO 10: seated companion vs player walking away")
