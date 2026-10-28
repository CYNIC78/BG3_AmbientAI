-- Scenario 30 (04.3.16): диагностический набор для анимационных банков.
-- Мок отдаёт три вида банков:
--   Animation      - 5 ресурсов, у которых ВООБЩЕ нет строковых полей (как в отчёте игрока:
--                    101286 записей и 0 совпадений);
--   AnimationSet   - 3 ресурса с именами CUST_* (там и должен найтись Writing);
--   Visual         - 1 ресурс, чтобы проверить !ambient_anim_fields;
-- Проверяем: fields печатает "Get returned nil"/поля, sets находит CUST_Writing_02,
-- find по Animation честно рапортует readable=0 (а не "0 совпадений" без объяснений),
-- stop останавливает скан, guess играет триплет из UUID лупа.
dofile("/home/user/sim/mock.lua")
dofile("/home/user/sim/scene.lua")

local NUM = 101
local animBank = {}
for i = 1, NUM do
    animBank[i] = string.format("aaaa0000-0000-0000-0000-%012d", i)
end

SIM.animBanks = {
    Animation = animBank,
    AnimationSet = {
        "bbbb0000-0000-0000-0000-000000000001",
        "bbbb0000-0000-0000-0000-000000000002",
        "bbbb0000-0000-0000-0000-000000000003",
    },
    Visual = { "cccc0000-0000-0000-0000-000000000001" },
}
SIM.animResourceData = {
    -- Animation: ни одного строкового поля
    ["aaaa0000-0000-0000-0000-000000000001"] = { Duration = 1.5 },
    ["aaaa0000-0000-0000-0000-000000000002"] = { Duration = 2.5 },
    -- AnimationSet: имена лежат здесь
    ["bbbb0000-0000-0000-0000-000000000001"] = {
        Name = "CUST_Writing_02_896b83fb-27c3-41e0-924c-7ebf8473154b",
        Poses = "start,loop,end",
    },
    ["bbbb0000-0000-0000-0000-000000000002"] = {
        Name = "CUST_Pondering_01_a47454a1-05a2-4153-bdfe-7a0500fa62d0",
    },
    ["bbbb0000-0000-0000-0000-000000000003"] = {
        SourceFile = "CUST_Bored_01_Loop_23588ba8-fafb-438c-9bc5-660ff6650aef.gr2",
    },
    ["cccc0000-0000-0000-0000-000000000001"] = { Name = "Some visual", Mesh = "x" },
}
for i = 3, NUM do
    SIM.animResourceData[string.format("aaaa0000-0000-0000-0000-%012d", i)] = { Duration = i / 10 }
end

SCENE_SETUP({})
SIM.debugMCM = true
SCENE_LOAD_MOD()
SIM.run(2000)

local function cmdsRegistered()
    local need = { "ambient_anim_fields", "ambient_anim_probe", "ambient_anim_sets",
                   "ambient_anim_find", "ambient_anim_stop", "ambient_anim_guess" }
    for _, name in ipairs(need) do
        if not (SIM.commands and SIM.commands[name]) then return name end
    end
    return nil
end

local missing = cmdsRegistered()
SIM.log("PROBE missing_command=%s", tostring(missing or "none"))

-- 1. shape of the Animation bank (все ресурсы без строк)
SIM.commands.ambient_anim_fields(nil, "Animation")
SIM.run(200)
-- 2. shape of a bank where names live
SIM.commands.ambient_anim_fields(nil, "AnimationSet")
SIM.run(200)
-- 3. probe одного GUID во всех типах
SIM.commands.ambient_anim_probe(nil, "bbbb0000-0000-0000-0000-000000000001")
SIM.run(200)
-- 4. поиск по AnimationSet
SIM.commands.ambient_anim_sets(nil, "Writing")
SIM.run(200)
-- 5. полный скан Animation: должен дойти до конца и сказать readable=0
SIM.commands.ambient_anim_find(nil, "Writing")
SIM.run(30000)
-- 6. stop: запускаем снова и сразу останавливаем
SIM.commands.ambient_anim_find(nil, "Writing")
SIM.run(100)
SIM.commands.ambient_anim_stop()
SIM.run(100)
-- 7. guess: триплет из UUID лупа
SIM.loopingAnims = nil
SIM.commands.ambient_anim_guess(nil, "CUST_Writing_02")
SIM.run(200)

local function countPrint(needle)
    local n = 0
    for i = 1, #SIM.prints do
        if string.find(SIM.prints[i], needle, 1, true) then n = n + 1 end
    end
    return n
end

local nilShape = countPrint("Duration=")          -- shape dump of the Animation bank works
local setShape = countPrint("Name=CUST_Writing")  -- names are reachable in AnimationSet
local setHits = 0
for i = 1, #SIM.prints do
    if string.find(SIM.prints[i], "[set 1]", 1, true) then setHits = setHits + 1 end
end
local readableZero = countPrint("NOTHING in this bank has a readable string field")
local complete = countPrint("scan complete")
local stopped = countPrint("animation scan stopped")
local g = SIM.loopingAnims and SIM.loopingAnims[1] or {}
local guessOk = tostring(g.start or ""):find("Writing_02_Start_896b83fb", 1, true) ~= nil
    and tostring(g.loop or ""):find("Writing_02_Loop_896b83fb", 1, true) ~= nil
    and tostring(g.stop or ""):find("Writing_02_End_896b83fb", 1, true) ~= nil

SIM.log("RESULT shape=%d setShape=%d setHits=%d readableZero=%d complete=%d stopped=%d guessOk=%s",
    nilShape, setShape, setHits, readableZero, complete, stopped, tostring(guessOk))

local pass = missing == nil and nilShape > 0 and setShape > 0 and setHits > 0
    and readableZero > 0 and complete > 0 and stopped > 0 and guessOk
SIM.log(pass and "PASS s30: probes explain the empty scan and AnimationSet exposes names"
    or "FAIL s30")
SIM.report("SCENARIO 30: animation bank diagnostics")
