dofile("/home/user/sim/mock.lua")

-- ---------------------------------------------------------------------------
-- Scene: small dark room, host standing still, 2 companions, 5 unlit fixtures
-- ---------------------------------------------------------------------------
SIM.host = "aaaaaaaa-0000-0000-0000-000000000001"
local C1  = "aaaaaaaa-0000-0000-0000-000000000002"
local C2  = "aaaaaaaa-0000-0000-0000-000000000003"

SIM.addChar(SIM.host, "PLA_Avatar", 0.0, 0.0, 0.0)
SIM.addChar(C1, "S_Player_ShadowHeart", 1.2, 0.0, 1.6)
SIM.addChar(C2, "S_Player_Gale", -1.0, 0.0, 1.9)

SIM.addItem("bbbbbbbb-0000-0000-0000-000000000001", "LTS_DUN_Candles_Cluster_A",  2.0, 0.0,  1.2)
SIM.addItem("bbbbbbbb-0000-0000-0000-000000000002", "LTS_DUN_Candles_Cluster_B", -2.6, 0.0,  1.4)
SIM.addItem("bbbbbbbb-0000-0000-0000-000000000003", "LTS_DUN_Wall_Sconce_A",      3.4, 1.8, -0.6, { canPickUp = false })
SIM.addItem("bbbbbbbb-0000-0000-0000-000000000004", "Brazier_Standing_A",        -3.8, 0.0, -1.6, { canPickUp = false, canUse = true })
SIM.addItem("bbbbbbbb-0000-0000-0000-000000000005", "LTS_TWN_Candle_Table_A",     2.8, 0.0,  2.4)

-- host has the Ambient AI toggle status applied
STA[SIM.host] = { AMBIENT_AI_STATUS = true, ["PASSIVE:AmbientAI_Passive"] = true }

dofile(MODFILE or "/home/user/unpacked_original/Mods/AmbientAI/ScriptExtender/Lua/BootstrapServer.lua")

SIM.log("---- world loaded ----")
SIM.fire("LevelGameplayStarted", "GLO_Main", 0)

if SIM.debugMCM then SIM.log("debug on") end

SIM.run(150000)

for id, info in pairs(ITEMINFO) do end
local litCount, total = 0, 0
local lines = {}
for id, info in pairs(ITEMINFO) do
    if info.kind == "light" then
        total = total + 1
        if info.lit then litCount = litCount + 1 end
        lines[#lines + 1] = string.format("%-30s %s", info.tpl, info.lit and "LIT" or "unlit")
    end
end
table.sort(lines)
for _, l in ipairs(lines) do SIM.log("RESULT %s", l) end
SIM.log("RESULT total lit: %d / %d", litCount, total)

local unm = {}
for k, v in pairs(SIM.unmocked or {}) do unm[#unm + 1] = k .. "(" .. v .. ")" end
table.sort(unm)
SIM.log("UNMOCKED Osi calls: %s", table.concat(unm, " "))

SIM.report("SCENARIO 1: fresh session, dark room")
