-- Scenario 37 (04.3.23 + 04.3.24): фамильяр получает характер в идлах — но только когда можно.
-- Урок реального лога: у фамильяра ЕСТЬ компонент PartyMember, поэтому пространственный индекс
-- его не видит вообще. Моделируем именно так: имп с PartyMember (не в индексе), квазит без него
-- (в индексе). Работать должно в обоих случаях — через Osi.DB_PlayerSummons.
--   1) по умолчанию выключено: ноль перемещений;
--   2) диагностика: rows>=1, summons>=1, список с именами;
--   3) включили -> оба фамильяра смещаются вокруг ГГ, не наступая на людей;
--   4) рядом враг -> ни одного перемещения;
--   5) ГГ идёт -> ни одного перемещения.
dofile("/home/user/sim/mock.lua")
dofile("/home/user/sim/scene.lua")

SCENE_SETUP({
    { "CHA_TWN_Chair_Wood_A",  2.2, 0.0, -1.0, { kind = "prop", canUse = true, canPickUp = false, sittable = true } },
    { "S_TWN_Bookshelf_A",    -2.6, 0.0,  2.0, { kind = "prop", canUse = true, canPickUp = false } },
    { "S_TWN_Candle_01",       3.0, 0.0,  1.0, { kind = "light", canUse = true, canPickUp = false } },
})
SIM.debugMCM = true

-- имп: суммон С компонентом PartyMember (как в игре) -> в LocalSpatialIndex.chars его нет
local IMP = "dddddddd-0000-0000-0000-000000000001"
SIM.addSummon(IMP, "CON_Familiar_Imp", 2.4, 0.0, 2.2, { follower = true, partyMember = true })
-- квазит: без компонента -> попадает и в индекс
local QUASIT = "dddddddd-0000-0000-0000-000000000002"
SIM.addSummon(QUASIT, "CON_Familiar_Quasit", -2.0, 0.0, 2.6, {})

SCENE_LOAD_MOD()

local HOST = SIM.host
local hostKey = SIM.clean(HOST)

-- Замер на момент перемещения: позиции персонажей меняются, поэтому проверять «наступил ли
-- фамильяр на кого-то» надо в тот момент, когда мод отдаёт команду, а не в конце сценария.
local moveStats = {}
local summonsByKey = { [SIM.clean(IMP)] = true, [SIM.clean(QUASIT)] = true }
local origImpMove = Osi.CharacterMoveToPosition
Osi.CharacterMoveToPosition = function(u, x, y, z, sp, ev)
    if summonsByKey[SIM.clean(u)] then
        local r = math.sqrt(x * x + z * z)
        local minD = 999
        for uu, e in pairs(ENT) do
            local p = POS[uu]
            if p and e.ServerCharacter and not summonsByKey[SIM.clean(uu)] then
                local dx, dz = x - p[1], z - p[3]
                local d = math.sqrt(dx * dx + dz * dz)
                if d < minD then minD = d end
            end
        end
        table.insert(moveStats, { key = SIM.clean(u), r = r, minChar = minD })
    end
    return origImpMove(u, x, y, z, sp, ev)
end

local function countMoves(since, key)
    local n = 0
    for i = since, #SIM.prints do
        local line = SIM.prints[i]
        if string.find(line, "MOVE " .. key, 1, true) then n = n + 1 end
    end
    return n
end

-- 1) ФАЗА A: по умолчанию выключено
local markA = #SIM.prints + 1
SIM.run(180000)
local movesA = 0
for key in pairs(summonsByKey) do movesA = movesA + countMoves(markA, key) end

-- 2) ФАЗА B: диагностика
local markB = #SIM.prints + 1
if SIM.commands.ambient_familiars then SIM.commands.ambient_familiars(nil, nil) end
local diagImp, diagSummon, diagRows, diagNotIndexed = false, false, false, false
for i = markB, #SIM.prints do
    local line = SIM.prints[i]
    if string.find(line, "rows=", 1, true) then
        local nRows = tonumber(string.match(line, "rows=(%d+)")) or 0
        local nSum = tonumber(string.match(line, "summons=(%d+)")) or 0
        local nIdx = tonumber(string.match(line, "inSpatialIndex=(%d+)")) or 0
        if nRows >= 2 then diagRows = true end
        -- индекс обязан «недо-видеть» хотя бы одного суммона, иначе тест ничего не доказывает
        if nSum >= 2 and nIdx < nSum then diagNotIndexed = true end
    end
    if string.find(line, "CON_Familiar_Imp", 1, true) then
        diagImp = true
        if string.find(line, "summon=true", 1, true) then diagSummon = true end
    end
end
if SIM.commands.ambient_familiars then SIM.commands.ambient_familiars(nil, "on") end

-- 3) ФАЗА C: включено -> фамильяры смещаются, но не наступают на людей
local markC = #SIM.prints + 1
SIM.run(240000)
local movesC = 0
for key in pairs(summonsByKey) do movesC = movesC + countMoves(markC, key) end

local distOk = true
local minCharDist = 999
for _, mv in ipairs(moveStats) do
    if mv.r < 1.5 or mv.r > 4.6 then distOk = false end
    if mv.minChar < minCharDist then minCharDist = mv.minChar end
end
if #moveStats == 0 then distOk = false end

-- 4) ФАЗА D: рядом враг -> ни один не дёргается
local ENEMY = "dddddddd-0000-0000-0000-0000000000ff"
SIM.addChar(ENEMY, "CRE_Goblin_Warrior", 5.0, 0.0, 5.0, {})
SIM.setEnemy(ENEMY, true)
SIM.run(6000)          -- дать пространственному индексу заметить врага (иначе ловим гонку)
local markD = #SIM.prints + 1
SIM.run(240000)
local movesD = 0
for key in pairs(summonsByKey) do movesD = movesD + countMoves(markD, key) end

-- 5) ФАЗА E: враг ушёл, но ГГ идёт -> тоже нельзя
SIM.setEnemy(ENEMY, false)
SIM.moveChar(ENEMY, 60.0, 0.0, 60.0)
-- SIM.stuckMoving переживает любые действия мода (обычный SIM.moves мод может сбросить),
-- поэтому "ГГ идёт" моделируем именно им
SIM.stuckMoving = SIM.stuckMoving or {}
SIM.stuckMoving[hostKey] = true
local markE = #SIM.prints + 1
SIM.run(180000)
local movesE = 0
for key in pairs(summonsByKey) do movesE = movesE + countMoves(markE, key) end

-- перф: тик не должен потяжелеть
local from = #SIM.prints + 1
SIM.commands.ambient_perf()
local header = ""
for i = from, #SIM.prints do
    if string.find(SIM.prints[i], "QUEUE PERF", 1, true) then header = SIM.prints[i] end
end
local slow = tonumber(string.match(header, "slowTicks%(>120ms%)=(%d+)") or "-1")

SIM.log("RESULT offMoves=%d onMoves=%d hostileMoves=%d walkingMoves=%d distOk=%s minCharDist=%.2fm diagImp=%s diagSummon=%s dbRows=%s notInIndex=%s slowTicks=%s",
    movesA, movesC, movesD, movesE, tostring(distOk), minCharDist,
    tostring(diagImp), tostring(diagSummon), tostring(diagRows), tostring(diagNotIndexed),
    tostring(slow))

local pass = (movesA == 0) and diagImp and diagSummon and diagRows and diagNotIndexed
    and movesC > 0 and distOk and minCharDist >= 1.2
    and movesD == 0 and movesE == 0
    and slow == 0
SIM.log(pass and "PASS s37: familiars move on their own only when nothing forbids it (even when the spatial index cannot see them)"
    or "FAIL s37")
SIM.report("SCENARIO 37: familiar idles")
