-- Scenario 36 (04.3.22): Debug с фильтром — меньше шума, тот же отладочный смысл.
--   1) без фильтра: в консоль идут все пошаговые строки;
--   2) !ambient_focus Seat -> печатаются только шаги со "seat" в имени, остальные считаются;
--   3) !ambient_steps показывает и отфильтрованные (они не теряются);
--   4) !ambient_perf показывает фильтр и счётчики.
dofile("/home/user/sim/mock.lua")
dofile("/home/user/sim/scene.lua")

SCENE_SETUP({
    { "CHA_TWN_Chair_Wood_A",  2.2, 0.0, 1.0, { kind = "prop", canUse = true, canPickUp = false, sittable = true } },
    { "S_TWN_Bookshelf_A",     2.6, 0.0, 3.0, { kind = "prop", canUse = true, canPickUp = false } },
    { "OBJ_TWN_Crate_A",       1.4, 0.0, 3.4, { kind = "container", canUse = true, canPickUp = false, isContainer = true } },
    { "S_TWN_Candle_01",       3.0, 0.0, 2.0, { kind = "light", canUse = true, canPickUp = false } },
})
SIM.debugMCM = true
SCENE_LOAD_MOD()

local function stepLines(since)
    local all, seat = 0, 0
    for i = since, #SIM.prints do
        local line = SIM.prints[i]
        if string.find(line, " started: ", 1, true) then
            all = all + 1
            if string.find(string.lower(line), "seat", 1, true) then seat = seat + 1 end
        end
    end
    return all, seat
end

local function perfHeader()
    local from = #SIM.prints + 1
    SIM.commands.ambient_perf()
    for i = from, #SIM.prints do
        if string.find(SIM.prints[i], "QUEUE PERF", 1, true) then return SIM.prints[i] end
    end
    return ""
end

-- 1) без фильтра
local mark1 = #SIM.prints + 1
SIM.run(40000)
local all1, seat1 = stepLines(mark1)
local header1 = perfHeader()

-- 2) фильтр по Seat
SIM.commands.ambient_focus(nil, "Seat")
SIM.run(2000)                     -- дать очереди дренаж
local mark2 = #SIM.prints + 1
SIM.run(60000)
local all2, seat2 = stepLines(mark2)
local header2 = perfHeader()

-- 3) буфер: отфильтрованные строки не потеряны
local mark3 = #SIM.prints + 1
SIM.commands.ambient_steps(nil, "10")
local buffered = 0
for i = mark3, #SIM.prints do
    if string.find(SIM.prints[i], "started: ", 1, true) then buffered = buffered + 1 end
end

-- 4) снятие фильтра
SIM.commands.ambient_focus(nil, "off")
local cleared = string.find(SIM.prints[#SIM.prints] or "", "cleared", 1, true) ~= nil

local filterShown = string.find(header2, "stepFilter='seat'", 1, true) ~= nil
local filteredCount = tonumber(string.match(header2, "filtered=(%d+)") or "0")

SIM.log("RESULT unfiltered=%d(filtered_run) seatOnly=%d buffered=%d filterShown=%s filteredCount=%d cleared=%s",
    all1, seat2, buffered, tostring(filterShown), filteredCount, tostring(cleared))

-- с фильтром в консоль должны идти только Seat-строки (или ничего, если их не было),
-- и счётчик отфильтрованных должен быть больше нуля
local pass = filterShown and filteredCount > 0 and buffered > 0 and cleared
    and (all2 == seat2)
SIM.log(pass and "PASS s36: the step filter cuts console noise without losing debug info"
    or "FAIL s36")
SIM.report("SCENARIO 36: step-log filter")
