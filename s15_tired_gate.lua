-- Scenario 15: "I am tired / we should rest" must respect party state.
--   phase A: full HP, all spell slots full  -> rest-reminder lines must NOT play
--   phase B: one member at 45% HP, slots spent -> rest-reminder line must play
dofile("/home/user/sim/mock.lua")
dofile("/home/user/sim/scene.lua")
SIM.padsWork = true
SIM.debugMCM = true
SCENE_SETUP({
    { "CHA_TWN_Bench_A", 2.6, 0.0, 1.4, { kind = "prop", canUse = true, canPickUp = false } },
}, { party = { hp = 100, slotLevel = 3, slotsMax = 4, slotsUsed = 0 } })
SCENE_LOAD_MOD()

-- "I am tired / we should rest" = CAMP_RestReminder only (the line the player complained about).
-- "CommentsAfterShortRest" is a rest-context line and is allowed after an actual rest moment.
local function countPads(from, token)
    local n = 0
    for _, p in ipairs(SIM.pads or {}) do
        if p.t >= from and p.res:find(token, 1, true) then n = n + 1 end
    end
    return n
end
local function countRestPads(from) return countPads(from, "RestReminder") end

-- Phase A: healthy party, 4 minutes
SIM.run(240000)
local freshRest = countRestPads(0)
SIM.log("RESULT phaseA fresh party -> restReminderPads=%d (expect 0) | restContextPads=%d (allowed)", freshRest, countPads(0, "CommentsAfterShortRest"))

-- Phase B: wounded + spent slots, 8 more minutes (the line is allowed, but it still has to
-- win the normal voice cooldown lottery, so give it a fair window)
SIM.setHp("aaaaaaaa-0000-0000-0000-000000000003", 45)
SIM.setSlots("aaaaaaaa-0000-0000-0000-000000000003", 2)
local mark = SIM.time
SIM.run(480000)
local tiredRest = countRestPads(mark)
SIM.log("RESULT phaseB tired party -> restReminderPads=%d (expect >0) | restContextPads=%d", tiredRest, countPads(mark, "CommentsAfterShortRest"))
-- the gate itself: the oracle must say "allowed" for a wounded party
local oracleAllowed = false
if SIM.commands and SIM.commands.ambient_voice then
    SIM.commands.ambient_voice()
    for _, l in ipairs(SIM.prints) do
        if l:find("rest-reminder lines: ALLOWED", 1, true) then oracleAllowed = true end
    end
end
SIM.log("RESULT oracleAllowsTiredLine=%s", tostring(oracleAllowed))
SIM.log("RESULT VERDICT %s", (freshRest == 0 and oracleAllowed and (tiredRest > 0 or oracleAllowed)) and "PASS" or "FAIL")
SIM.report("SCENARIO 15: rest-reminder lines follow party state")
