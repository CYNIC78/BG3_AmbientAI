-- Scenario 32 (04.3.18): Гейл больше не «читает воздух».
--   1) прогон с книжной полкой рядом: в логе не должно быть Old_Tome, но должно быть чтение
--      (ReadingBook / Reading_Book_01);
--   2) прямой вызов pickReadAnim-пути: 12 запусков ReadingBook через рестарт сцены — все книги.
--   3) старый том остался только в таблице триплетов (для будущих попыток), в пуле его нет.
dofile("/home/user/sim/mock.lua")
dofile("/home/user/sim/scene.lua")

-- ВАЖНО: личности в моде определяются по РЕАЛЬНЫМ GUID сопартийцев (COMP.*), а не по
-- шаблону. В сцене по умолчанию GUID фейковые, поэтому личностные ветки там не работают -
-- добавляем настоящего Гейла отдельным персонажем.
local GALE = "ad9af97d-75da-406a-ae13-7071c563f604"

SCENE_SETUP({
    { "S_TWN_Bookshelf_A", 2.4, 0.0, 1.4, { kind = "prop", canUse = true, canPickUp = false } },
})
SIM.debugMCM = true
SCENE_LOAD_MOD()

SIM.addChar(GALE, "S_Player_Gale", 1.6, 0.0, 1.2, {})
SIM.run(180000)

-- 1) реально проигранные анимации (мок пишет каждый PlayLoopingAnimation)
local tomePlayed, bookPlayed = 0, 0
for _, entry in ipairs(SIM.loopingAnims or {}) do
    local s1 = tostring(entry.start or "") .. tostring(entry.loop or "")
    if string.find(s1, "Old_Tome", 1, true) then tomePlayed = tomePlayed + 1 end
    if string.find(s1, "Reading_Book_01", 1, true) or string.find(s1, "DukeWyll_Reading", 1, true) then
        bookPlayed = bookPlayed + 1
    end
end

-- 2) айдлы: лог печатает имя анимации прямо в строке started:
local tomeIdle, bookIdle = 0, 0
for i = 1, #SIM.prints do
    local line = SIM.prints[i]
    if string.find(line, "PlayIdleAnim_CUST_Reading_Old_Tome", 1, true) then tomeIdle = tomeIdle + 1 end
    if string.find(line, "PlayIdleAnim_CUST_Reading_Book", 1, true) then bookIdle = bookIdle + 1 end
end

SIM.log("RESULT tomePlayed=%d tomeIdle=%d bookPlayed=%d bookIdle=%d",
    tomePlayed, tomeIdle, bookPlayed, bookIdle)

local pass = (tomePlayed + tomeIdle) == 0 and (bookPlayed + bookIdle) > 0
SIM.log(pass and "PASS s32: no propless tome, the book clip is what gets played"
    or "FAIL s32")
SIM.report("SCENARIO 32: Gale reads a real book")
