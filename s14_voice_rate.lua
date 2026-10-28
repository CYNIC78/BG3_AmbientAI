-- Scenario 14: how often does the party actually talk while exploring a quiet room?
-- Peaceful inn room, no lights to fix, host idle. 10 minutes of game time.
dofile("/home/user/sim/mock.lua")
dofile("/home/user/sim/scene.lua")
SIM.padsWork = true
SIM.debugMCM = true
SCENE_SETUP({
    { "CHA_TWN_Bench_A",   2.6, 0.0,  1.4, { kind = "prop", canUse = true, canPickUp = false } },
    { "S_TWN_Bookshelf_A", -2.4, 0.0, -1.2, { kind = "prop", canUse = true, canPickUp = false } },
}, { party = { hp = 100, slotLevel = 3, slotsMax = 4, slotsUsed = 0 } })
SCENE_LOAD_MOD()
SIM.run(600000)

local voices, pads, gaps, last = {}, {}, {}, nil
for _, l in ipairs(SIM.prints) do
    local t = tonumber(l:match("^%s*(%d+)"))
    local cat = l:match("ActionVoice %[([%w_]+)%]")
    if cat and t then
        voices[cat] = (voices[cat] or 0) + 1
        if last then gaps[#gaps + 1] = (t - last) / 1000.0 end
        last = t
    end
    local res = l:match("PAD (%S+) on")
    if res then pads[res] = (pads[res] or 0) + 1 end
end
local total = 0
for k, v in pairs(voices) do total = total + v; SIM.log("COUNT voice %-18s %d", k, v) end
for k, v in pairs(pads) do SIM.log("COUNT pad   %-42s %d", k, v) end
table.sort(gaps)
local mean = 0.0
for _, g in ipairs(gaps) do mean = mean + g end
if #gaps > 0 then mean = mean / #gaps end
SIM.log("RESULT voices=%d pads=%d over %.1fs | meanGap=%.1fs | gaps=%s",
    total, (function() local n = 0 for _, v in pairs(pads) do n = n + v end return n end)(),
    SIM.time / 1000.0, mean,
    (function()
        local parts = {}
        for i = 1, math.min(#gaps, 8) do parts[#parts + 1] = string.format("%.0f", gaps[i]) end
        return table.concat(parts, ",")
    end)())
SIM.report("SCENARIO 14: voice rate in a peaceful room (10 min)")
