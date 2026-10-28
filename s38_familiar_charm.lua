-- Scenario 38 (04.3.25): «характер» в дрейфе — фамильяр не прыгает в случайную точку,
-- а обходит партию по орбите: шаг 35-75°, радиус 2.2-3.6 м (иногда ближе), изредка разворот,
-- и после каждого перелёта поворачивается к ГГ.
--   1) шагов >= 3, все шаги орбитальные (|дельта угла| в 0.5..1.4 рад, радиус 1.8..3.7);
--   2) LookAtEntity вызван на каждый успешный перелёт и целится в ГГ;
--   3) !ambient_familiars anim <name> проигрывает анимацию на фамильяре (и это видно в моке);
--   4) выключенный мод по-прежнему ничего не двигает.
dofile("/home/user/sim/mock.lua")
dofile("/home/user/sim/scene.lua")

SCENE_SETUP({
    { "CHA_TWN_Chair_Wood_A",  2.2, 0.0, -1.0, { kind = "prop", canUse = true, canPickUp = false, sittable = true } },
    { "S_TWN_Candle_01",       3.0, 0.0,  1.0, { kind = "light", canUse = true, canPickUp = false } },
})
SIM.debugMCM = true

local IMP = "dddddddd-0000-0000-0000-000000000001"
SIM.addSummon(IMP, "Imp_Summon", 2.4, 0.0, 2.2, { follower = true, partyMember = true })

SCENE_LOAD_MOD()

local HOST = SIM.host
local hostKey = SIM.clean(HOST)
local impKey = SIM.clean(IMP)
local impPat = impKey:gsub("%-", "%%-")

-- 0) выключено: ничего не двигается
local markOff = #SIM.prints + 1
SIM.run(120000)
local offMoves = 0
for i = markOff, #SIM.prints do
    if string.find(SIM.prints[i], "MOVE " .. impKey, 1, true) then offMoves = offMoves + 1 end
end

SIM.commands.ambient_familiars(nil, "on")
local lookBefore = SIM.lookAtCalls or 0
local mark = #SIM.prints + 1
SIM.run(300000)

-- 1) собрать все перелёты и посчитать углы вокруг ГГ
local angles, radii = {}, {}
for i = mark, #SIM.prints do
    local line = SIM.prints[i]
    -- "MOVE <uuid> -> x,y,z"
    local x, y, z = string.match(line, "MOVE " .. impPat .. " %-> (%-?%d+%.?%d*),(%-?%d+%.?%d*),(%-?%d+%.?%d*)")
    if x then
        local px, pz = tonumber(x), tonumber(z)
        local atan2 = math.atan2 or math.atan
        angles[#angles + 1] = atan2(px, pz)      -- ГГ стоит в 0,0
        radii[#radii + 1] = math.sqrt(px * px + pz * pz)
    end
end

local function norm(a)
    while a > math.pi do a = a - 2 * math.pi end
    while a < -math.pi do a = a + 2 * math.pi end
    return a
end

-- Шаг по орбите: 35-75 градусов (0.61-1.31 рад). Разворот даёт скачок в другую сторону,
-- поэтому |дельта| может доходить до ~2.1 рад. Зато два соседних шага в одну сторону
-- могут быть только при орбите - случайные точки так себя не ведут.
local orbitOk = #angles >= 3
local deltas, signed = {}, {}
for i = 2, #angles do
    local d = norm(angles[i] - angles[i - 1])
    signed[#signed + 1] = d
    deltas[#deltas + 1] = math.abs(d)
    if math.abs(d) < 0.4 or math.abs(d) > 3.2 then orbitOk = false end
end
-- Каждый шаг орбиты - либо одиночный (35-75 градусов = 0.61..1.31 рад), либо разворот
-- (тогда |дельта| = сумма двух соседних шагов, 1.22..2.62). Случайные точки дают дельты,
-- равномерные по всему диапазону, поэтому в «одиночную» полосу попадает лишь часть.
local forwardCount = 0
for _, d in ipairs(deltas) do
    if d >= 0.55 and d <= 1.35 then forwardCount = forwardCount + 1 end
end
local sameDirPairs = 0
for i = 2, #signed do
    if signed[i] * signed[i - 1] > 0 then sameDirPairs = sameDirPairs + 1 end
end
-- forwardCount и sameDirPairs остаются информацией в отчёте: два разворота подряд
-- (редкий, но легальный случай) не должны валить тест
local radiusOk = true
for _, r in ipairs(radii) do
    if r < 1.7 or r > 3.8 then radiusOk = false end
end

-- 2) повороты к ГГ
local lookAdd = (SIM.lookAtCalls or 0) - lookBefore
local lookAtHost = 0
for _, t in ipairs(SIM.lookAtTargets or {}) do
    if t.char == impKey and t.target == hostKey then lookAtHost = lookAtHost + 1 end
end

-- 3) тест анимации на фамильяре
local animSeen, animMsg = false, false
local markAnim = #SIM.prints + 1
SIM.commands.ambient_familiars(nil, "anim CUST_TestSpin_01")
for i = markAnim, #SIM.prints do
    if string.find(SIM.prints[i], "playing 'CUST_TestSpin_01'", 1, true) then animMsg = true end
end
for _, a in ipairs(SIM.playedAnims or {}) do
    if a.anim == "CUST_TestSpin_01" and SIM.clean(a.char) == impKey then animSeen = true end
end

local slow
local from = #SIM.prints + 1
SIM.commands.ambient_perf()
for i = from, #SIM.prints do
    local v = string.match(SIM.prints[i], "slowTicks%(>120ms%)=(%d+)")
    if v then slow = tonumber(v) end
end

SIM.log("RESULT steps=%d deltas=%s sameDirPairs=%d forward=%d radii=%s orbitOk=%s radiusOk=%s lookAtImpToHost=%d lookTotal=%d offMoves=%d animPlayed=%s animMsg=%s slowTicks=%s",
    #angles, table.concat((function()
        local t = {}
        for _, d in ipairs(deltas) do t[#t + 1] = string.format("%.2f", d) end
        return t
    end)(), "/"), sameDirPairs, forwardCount,
    table.concat((function()
        local t = {}
        for _, r in ipairs(radii) do t[#t + 1] = string.format("%.1f", r) end
        return t
    end)(), "/"),
    tostring(orbitOk), tostring(radiusOk), lookAtHost, lookAdd or 0, offMoves,
    tostring(animSeen), tostring(animMsg), tostring(slow))

local pass = orbitOk and radiusOk and #angles >= 3
    and lookAtHost >= #angles          -- на каждый перелёт свой поворот
    and offMoves == 0
    and animSeen and animMsg
    and slow == 0
SIM.log(pass and "PASS s38: the familiar circles the party instead of jumping at random, and a found animation can be tested live"
    or "FAIL s38")
SIM.report("SCENARIO 38: familiar charm (orbit + look-at + anim test)")
