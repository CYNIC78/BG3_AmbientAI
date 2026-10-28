-- Scenario 16 (voice health audit): a dialog instance the engine can no longer resolve
-- used to make IsAnyDialogActive() answer "busy" forever -> the party went mute for the
-- rest of the session. 04.3.7 prunes those rows after a 20 s grace window.
dofile("/home/user/sim/mock.lua")
dofile("/home/user/sim/scene.lua")
SIM.padsWork = true
SIM.debugMCM = true
SCENE_SETUP({
    { "CHA_TWN_Bench_A", 2.6, 0.0, 1.4, { kind = "prop", canUse = true, canPickUp = false } },
}, { party = { hp = 100, slotLevel = 3, slotsMax = 4, slotsUsed = 0 } })
SCENE_LOAD_MOD()

-- a party dialog starts, then the engine forgets how to resolve that instance
SIM.dialog = { instance = "DLG-STALE-1", players = 1, broken = false }
SIM.fire("DialogStarted", "GLO_SomePartyDialog", "DLG-STALE-1")
SIM.dialog.broken = true

local mark = SIM.time
SIM.run(240000)
local function voicesSince(from)
    local n = 0
    for _, l in ipairs(SIM.prints) do
        local t = tonumber(l:match("^%s*(%d+)"))
        if t and t >= from and l:find("ActionVoice %[", 1, false) then n = n + 1 end
    end
    return n
end
local afterStale = voicesSince(mark + 25000)
SIM.log("RESULT staleDialog voices after the 20s grace window = %d (expect >0)", afterStale)

-- now a genuinely live dialog: the party must stay quiet
SIM.dialog = { instance = "DLG-LIVE-1", players = 1, broken = false }
SIM.fire("DialogStarted", "GLO_LivePartyDialog", "DLG-LIVE-1")
local liveMark = SIM.time
SIM.run(120000)
local duringLive = voicesSince(liveMark)
SIM.log("RESULT liveDialog voices while a real dialog runs = %d (expect 0)", duringLive)
SIM.log("RESULT VERDICT %s", (afterStale > 0 and duringLive == 0) and "PASS" or "FAIL")
SIM.report("SCENARIO 16: stale dialog instance must not mute the party")
