-- Scenario 31 (04.3.17): A/B-тест анимаций на ГГ.
--   !ambient_anim_play write auto    -> как играет мод (для write это голый луп)
--   !ambient_anim_play tome triplet  -> Start+Loop+End из таблицы мода
--   !ambient_anim_play tome bare     -> только луп
dofile("/home/user/sim/mock.lua")
dofile("/home/user/sim/scene.lua")

SCENE_SETUP({})
SIM.debugMCM = true
SCENE_LOAD_MOD()
SIM.run(2000)

SIM.log("PROBE has_play=%s has_anim_stop=%s",
    tostring(SIM.commands.ambient_anim_play ~= nil),
    tostring(SIM.commands.ambient_anim_stop ~= nil))

-- 1. список ключей
SIM.commands.ambient_anim_play(nil, "list")
SIM.run(100)

-- 2. write, auto: в таблице мода письмо ЕСТЬ триплетом -> должен уйти PlayLoopingAnimation
SIM.playedAnims, SIM.loopingAnim = nil, nil
SIM.commands.ambient_anim_play(nil, "write", "auto")
SIM.run(100)
local writeTriplet = SIM.loopingAnim
local writeBareCall = SIM.playedAnims and SIM.playedAnims[1] and SIM.playedAnims[1].anim or nil
SIM.log("PROBE write_auto triplet=%s bareCall=%s",
    tostring(writeTriplet and writeTriplet.start), tostring(writeBareCall))

-- 3. tome, triplet: должен уйти PlayLoopingAnimation со start/loop/stop из таблицы
SIM.playedAnims, SIM.loopingAnim = nil, nil
SIM.commands.ambient_anim_play(nil, "tome", "triplet")
SIM.run(100)
local tomeTriplet = SIM.loopingAnim

-- 4. tome, bare: должен уйти PlayAnimation
SIM.playedAnims, SIM.loopingAnim = nil, nil
SIM.commands.ambient_anim_play(nil, "tome", "bare")
SIM.run(100)
local tomeBare = SIM.playedAnims and SIM.playedAnims[1] and SIM.playedAnims[1].anim or nil

-- 5. неизвестный ключ и неизвестный режим не должны ломать ничего
SIM.commands.ambient_anim_play(nil, "nope", "auto")
SIM.commands.ambient_anim_play(nil, "write", "sideways")
SIM.run(100)

local pass = writeTriplet ~= nil and tostring(writeTriplet.start or ""):find("Writing_02_Start", 1, true) ~= nil
    and writeBareCall == nil
    and tomeTriplet ~= nil and tostring(tomeTriplet.start or ""):find("Tome_01_Start", 1, true) ~= nil
    and tomeBare ~= nil and tostring(tomeBare):find("Tome_01", 1, true) ~= nil

SIM.log("RESULT writeTriplet=%s tomeTriplet=%s tomeBare=%s",
    tostring(writeTriplet and writeTriplet.start), tostring(tomeTriplet and tomeTriplet.start), tostring(tomeBare))
SIM.log(pass and "PASS s31: play-test can force bare vs triplet for the same clip" or "FAIL s31")
SIM.report("SCENARIO 31: animation play A/B test")
