-- Scenario 25 (04.3.11): подход к мебели, когда движок отменяет AI-движение
--   Реальный случай из лога: WalkNearSeat идёт все 25 с, сопартиец «топчется», а потом
--   срабатывает "late arrival" (или, если он не успел подойти, скамья уходит в бан на 300 с).
--   Здесь движение отменяется сразу после старта: партийный pull / follow-block делают это молча.
--   Ожидание 04.3.11: мод замечает «далеко и стою» через 8 с, повторяет приказ идти -> садится.
dofile("/home/user/sim/mock.lua")
dofile("/home/user/sim/scene.lua")

local SITTER = "aaaaaaaa-0000-0000-0000-000000000002"

SCENE_SETUP({
    { "CHA_TWN_Chair_Wood_A", 4.2, 0.0, 4.2, { kind = "prop", canUse = true, canPickUp = false } },
})

SIM.walkSpeed = 0.8   -- медленная ходьба: отмена движения должна прийтись на сам путь, а не после него
SIM.debugMCM = true
SCENE_LOAD_MOD()

local function findAt(token)
    for i = 1, #SIM.prints do
        if string.find(SIM.prints[i], token, 1, true) then
            return tonumber(string.match(SIM.prints[i], "^%s*(%d+)"))
        end
    end
    return nil
end

-- ждём старт подхода (до 4 минут игрового времени)
local guard = 0
while not findAt("started: WalkNearSeat") and guard < 240 do
    SIM.run(1000)
    guard = guard + 1
end
local walkAt = findAt("started: WalkNearSeat")

-- движок молча отменяет AI-движение первые 6 секунд (как партийный pull посреди подхода)
for _ = 1, 12 do
    SIM.run(500)
    SIM.moves[SIM.clean(SITTER)] = nil
end
SIM.log("### AI move of the sitter was cancelled right after the walk started")

SIM.run(60000)

local sitAt = findAt("started: SitOnSeat")
local lateArrival = findAt("late arrival")
local couldNotReach = findAt("could not reach")
local reissue = findAt("restarted")
local satLog = findAt("sits on")
local delta = (walkAt and sitAt) and (sitAt - walkAt) or nil

SIM.log("RESULT walkAt=%s sitAt=%s delta=%sms reissued=%s couldNotReach=%s lateArrival=%s seated=%s",
    tostring(walkAt), tostring(sitAt), tostring(delta), tostring(reissue ~= nil),
    tostring(couldNotReach ~= nil), tostring(lateArrival ~= nil), tostring(satLog ~= nil))

local pass = satLog ~= nil and couldNotReach == nil
SIM.log(pass and "PASS s25: the cancelled approach was re-issued and the companion sat down"
    or "FAIL s25")
SIM.report("SCENARIO 25: seat walk with a silently cancelled AI move")
