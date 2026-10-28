-- Shared scene builder for all simulations
-- Usage: SCENE(title, { itemdefs... }) ; then SCENE_RUN(ms)

function SCENE_SETUP(defs, opts)
    opts = opts or {}
    SIM.host = "aaaaaaaa-0000-0000-0000-000000000001"
    -- 04.3.18: personality branches in the mod are keyed on the REAL origin GUIDs (COMP.*).
    -- Set SIM.realGuids = true before SCENE_SETUP to get Shadowheart + Gale instead of
    -- placeholders, otherwise those branches never fire in the simulator.
    local C1 = "aaaaaaaa-0000-0000-0000-000000000002"
    local C2 = "aaaaaaaa-0000-0000-0000-000000000003"
    if SIM.realGuids then
        C1 = "3ed74f06-3c60-42dc-83f6-f034cb47c679"   -- Shadowheart
        C2 = "ad9af97d-75da-406a-ae13-7071c563f604"   -- Gale
    end
    local partyOpts = opts.party or {}
    SIM.addChar(SIM.host, "PLA_Avatar", 0.0, 0.0, 0.0, partyOpts)
    SIM.addChar(C1, "S_Player_ShadowHeart", 1.2, 0.0, 1.6, partyOpts)
    SIM.addChar(C2, "S_Player_Gale", -1.0, 0.0, 1.9, partyOpts)
    SIM.hostKey = SIM.host
    local i = 0
    for _, d in ipairs(defs) do
        i = i + 1
        local uuid = string.format("bbbbbbbb-0000-0000-0000-%012d", i)
        SIM.addItem(uuid, d[1], d[2], d[3], d[4], d[5])
    end
    STA[SIM.host] = { AMBIENT_AI_STATUS = true, ["PASSIVE:AmbientAI_Passive"] = true }
    if opts.preSession then opts.preSession() end
end

function SCENE_LOAD_MOD()
    dofile(MODFILE or "/home/user/mod_src/Mods/AmbientAI/ScriptExtender/Lua/BootstrapServer.lua")
    SIM.fire("LevelGameplayStarted", "GLO_Main", 0)
    if SIM.loadSaveToo then SIM.fire("SavegameLoaded") end
end

function SCENE_RESULT(title)
    local litCount, total = 0, 0
    local lines = {}
    for _, info in pairs(ITEMINFO) do
        if info.kind == "light" then
            total = total + 1
            if info.lit then litCount = litCount + 1 end
            lines[#lines + 1] = string.format("%-32s engine=%-7s %s", info.tpl, info.engine, info.lit and "LIT" or "dark")
        end
    end
    table.sort(lines)
    for _, l in ipairs(lines) do SIM.log("RESULT %s", l) end
    SIM.log("RESULT lit %d / %d fixtures", litCount, total)
    SIM.report(title)
end
