#!/usr/bin/env python3
"""04.3.16: animation resource diagnostics, round 2.

Field report from 04.3.15: `!ambient_anim_find Writing` scanned the whole Animation bank
(101286 resources) in 60 s and matched nothing. Two possible reasons:
  a) Ext.Resource.Get(guid, "Animation") returns nil / has no name field at all, or
  b) names live in a different resource type (AnimationSet / AnimationSetOverride).

Also the previous scan was too greedy: 40 resources per timer tick starved the game
(the same window shows "Dispatching user function call (BootstrapServer.lua:2338)
took 1633.34 ms" - that line is the action-queue tick).

This build replaces the finder block with a diagnostic suite:

    !ambient_anim_fields  [type]      - shape of the first 5 resources of a type (default Animation)
    !ambient_anim_probe   [guid]      - dump one resource across every animation-ish type
                                        (default = the known CUST_Writing_02 loop UUID)
    !ambient_anim_sets    [needle]    - scan AnimationSet resources (~2-3k, cheap) for a name
    !ambient_anim_find    [needle]    - full Animation bank scan, now time-budgeted (6 ms per
                                        tick), with progress lines, counters and a hard stop
    !ambient_anim_stop                - abort a running scan
    !ambient_anim_guess   [loopUuid]  - play CUST_Writing_02 as a triplet built from the loop's
                                        own UUID (the naming convention Larian uses), 9 s, so you
                                        can see whether the book and quill appear

    python3 tools/patch_anim_probe.py <in.lua> <out.lua>
"""
import sys

START_MARK = "-- ============================================================================\n-- 10B. ANIMATION RESOURCE FINDER"
END_MARK = "-- ============================================================================\n-- 11. LIGHT INVESTIGATION CONSOLE COMMANDS"

NEW_BLOCK = r'''-- ============================================================================
-- 10B. ANIMATION RESOURCE DIAGNOSTICS (Build 04.3.16)
--   Why: the writing idle brings its props (book, quill) only when played as a full
--   Start / Loop / End triplet, and those resource names live in the game data.
--   The 04.3.15 sweep of the 101k-entry Animation bank matched nothing, so this build
--   first reports the *shape* of the bank (field names, nil rate) before scanning again.
-- ============================================================================
AnimProbe = AnimProbe or {
    types = { "Animation", "AnimationSet", "AnimationSetOverride", "VirtualAnimation", "BlendSpace" },
    running = false,
}

local ANIM_DEFAULT_LOOP_UUID = "896b83fb-27c3-41e0-924c-7ebf8473154b"

local function ProbePrint(fmt, ...)
    if not (Ext and Ext.Utils and Ext.Utils.Print) then return end
    if select("#", ...) > 0 then
        Ext.Utils.Print(string.format(fmt, ...))
    else
        Ext.Utils.Print(tostring(fmt))
    end
end

local function ResourceFields(res, limit)
    local parts = {}
    if type(res) ~= "table" then return nil end
    for k, v in pairs(res) do
        local tv = type(v)
        local shown
        if tv == "string" then
            shown = v
        elseif tv == "number" or tv == "boolean" then
            shown = tostring(v)
        else
            shown = "<" .. tv .. ">"
        end
        if #shown > 96 then shown = shown:sub(1, 96) .. "..." end
        parts[#parts + 1] = tostring(k) .. "=" .. shown
        if #parts >= (limit or 16) then break end
    end
    return table.concat(parts, " | ")
end

-- Collect every string value of a resource (names may hide in any field)
local function ResourceStrings(res, into)
    if type(res) ~= "table" then return into end
    for k, v in pairs(res) do
        if type(v) == "string" then
            into[#into + 1] = tostring(k) .. "=" .. v
        end
    end
    return into
end

local function TryGet(guid, bankType)
    if not (Ext and Ext.Resource and Ext.Resource.Get) then return nil end
    local ok, res = pcall(Ext.Resource.Get, guid, bankType)
    if ok and type(res) == "table" then return res end
    return nil
end

function AnimProbe.fields(typeArg)
    local bankType = typeArg or "Animation"
    local ok, list = pcall(Ext.Resource.GetAll, bankType)
    if not ok or type(list) ~= "table" or #list == 0 then
        ProbePrint("[AmbientAI] getAll(%s) returned nothing - try another type (AnimationSet, Visual ...)", bankType)
        return
    end
    ProbePrint("[AmbientAI] %s bank: %d entries. Shape of the first 5:", bankType, #list)
    for idx = 1, math.min(5, #list) do
        local res = TryGet(list[idx], bankType)
        ProbePrint("  [%d] guid=%s -> %s", idx, tostring(list[idx]),
            ResourceFields(res, 18) or "Ext.Resource.Get returned nil")
    end
    ProbePrint("  (counters below come from !ambient_anim_find)")
end

function AnimProbe.probe(guidArg)
    local guid = guidArg
    if not guid or guid == "" then guid = ANIM_DEFAULT_LOOP_UUID end
    ProbePrint("[AmbientAI] probing resource %s", tostring(guid))
    local foundAny = false
    for _, bankType in ipairs(AnimProbe.types) do
        local res = TryGet(guid, bankType)
        if res then
            foundAny = true
            ProbePrint("  [%s] %s", bankType, ResourceFields(res, 24) or "<empty>")
        end
    end
    if not foundAny then
        ProbePrint("  no type returned a resource for this GUID.")
        ProbePrint("  (a bare GUID may need the full resource name 'Name_guid'; try !ambient_anim_fields)")
    end
end

function AnimProbe.sets(needleArg)
    local needle = string.lower(needleArg or "writing")
    local ok, list = pcall(Ext.Resource.GetAll, "AnimationSet")
    if not ok or type(list) ~= "table" or #list == 0 then
        ProbePrint("[AmbientAI] AnimationSet bank is empty in this SE build.")
        return
    end
    ProbePrint("[AmbientAI] scanning %d AnimationSet resource(s) for '%s' ...", #list, needle)
    local hits, nilCount, namedCount = 0, 0, 0
    for idx = 1, #list do
        local guid = list[idx]
        local res = TryGet(guid, "AnimationSet")
        if not res then
            nilCount = nilCount + 1
        else
            local strings = ResourceStrings(res, {})
            if #strings > 0 then namedCount = namedCount + 1 end
            local joined = string.lower(table.concat(strings, "|"))
            if string.find(joined, needle, 1, true) then
                hits = hits + 1
                if hits <= 40 then
                    ProbePrint("  [set %d] %s :: %s", hits, tostring(guid), table.concat(strings, " | "))
                end
            end
        end
    end
    ProbePrint("[AmbientAI] AnimationSet scan done: hits=%d, readable=%d, nil=%d of %d",
        hits, namedCount, nilCount, #list)
end

function AnimProbe.guess(baseArg)
    local host = Osi.GetHostCharacter and Osi.GetHostCharacter() or nil
    if not host then
        ProbePrint("[AmbientAI] no host character.")
        return
    end
    local base = baseArg or "CUST_Writing_02"
    local uuid = ANIM_DEFAULT_LOOP_UUID
    local startName = base .. "_Start_" .. uuid
    local loopName = base .. "_Loop_" .. uuid
    local endName = base .. "_End_" .. uuid
    if loopName ~= (base .. "_Loop_" .. uuid) then return end
    ProbePrint("[AmbientAI] trying the naming convention on the host:")
    ProbePrint("  start=%s", startName)
    ProbePrint("  loop =%s", loopName)
    ProbePrint("  end  =%s", endName)
    if Osi.PlayLoopingAnimation then
        pcall(Osi.PlayLoopingAnimation, host, startName, loopName, endName, "", "", "", "")
    end
    ProbePrint("  look at the host: do the book and quill appear in his hands? (~9 s)")
    if Ext.Timer and Ext.Timer.WaitFor then
        Ext.Timer.WaitFor(9000, function()
            pcall(function() Osi.StopAnimation(host, 0) end)
            ProbePrint("[AmbientAI] animation guess finished.")
        end)
    end
end

-- ---------------------------------------------------------------- time-budgeted scan
AnimProbe.scan = AnimProbe.scan or {
    cursor = 1, handles = nil, bankType = nil, needle = "", matches = {},
    nilCount = 0, namedCount = 0, sample = nil, startedAt = 0, lastReport = 0,
}

function AnimProbe.stop(quiet)
    AnimProbe.running = false
    if not quiet then ProbePrint("[AmbientAI] animation scan stopped.") end
end

local function ScanSlice()
    if not AnimProbe.running then return end
    local scan = AnimProbe.scan
    local now = Ext.Utils.MonotonicTime()
    local sliceStart = now

    local processed = 0
    while scan.cursor <= #scan.handles do
        local guid = scan.handles[scan.cursor]
        scan.cursor = scan.cursor + 1
        processed = processed + 1
        local res = TryGet(guid, scan.bankType)
        if not res then
            scan.nilCount = scan.nilCount + 1
        else
            local strings = ResourceStrings(res, {})
            if #strings > 0 then
                scan.namedCount = scan.namedCount + 1
                if not scan.sample then scan.sample = strings end
                local joined = string.lower(table.concat(strings, "|"))
                if string.find(joined, scan.needle, 1, true) then
                    scan.matches[#scan.matches + 1] = {
                        guid = tostring(guid),
                        fields = table.concat(strings, " | "),
                    }
                end
            end
        end
        -- 6 ms of work per slice keeps a single callback well under the SE warn threshold
        if processed % 50 == 0 and (Ext.Utils.MonotonicTime() - sliceStart) > 6 then break end
    end

    local elapsed = now - scan.startedAt
    if now - scan.lastReport > 10000 then
        scan.lastReport = now
        ProbePrint("[AmbientAI] scan progress: %d/%d | readable=%d nil=%d matches=%d | %.0fs",
            scan.cursor - 1, #scan.handles, scan.namedCount, scan.nilCount, #scan.matches, elapsed / 1000)
    end

    if scan.cursor > #scan.handles then
        AnimProbe.running = false
        ProbePrint("[AmbientAI] scan complete: %d entries, readable=%d nil=%d matches=%d (%.1fs)",
            #scan.handles, scan.namedCount, scan.nilCount, #scan.matches, elapsed / 1000)
        if scan.sample then
            ProbePrint("  first readable resource: %s", table.concat(scan.sample, " | "))
        else
            ProbePrint("  NOTHING in this bank has a readable string field - names are not")
            ProbePrint("  exposed for %s resources; use !ambient_anim_sets instead.", tostring(scan.bankType))
        end
        for idx = 1, math.min(#scan.matches, 40) do
            local m = scan.matches[idx]
            ProbePrint("  [match %d] %s :: %s", idx, m.guid, m.fields)
        end
        return
    end

    if elapsed > 240000 then
        AnimProbe.running = false
        ProbePrint("[AmbientAI] scan stopped after 240 s (partial). Raise the needle or use AnimationSet.")
        return
    end

    if Ext.Timer and Ext.Timer.WaitFor then
        Ext.Timer.WaitFor(30, ScanSlice)
    else
        AnimProbe.running = false
    end
end

function AnimProbe.find(needleArg, typeArg)
    if AnimProbe.running then
        ProbePrint("[AmbientAI] a scan is already running - !ambient_anim_stop first.")
        return
    end
    local bankType = typeArg or "Animation"
    local ok, list = pcall(Ext.Resource.GetAll, bankType)
    if not ok or type(list) ~= "table" or #list == 0 then
        ProbePrint("[AmbientAI] getAll(%s) returned nothing.", bankType)
        return
    end
    local scan = AnimProbe.scan
    scan.cursor, scan.handles, scan.bankType = 1, list, bankType
    scan.needle = string.lower(needleArg or "writing")
    scan.matches, scan.nilCount, scan.namedCount, scan.sample = {}, 0, 0, nil
    scan.startedAt = Ext.Utils.MonotonicTime()
    scan.lastReport = scan.startedAt
    AnimProbe.running = true
    ProbePrint("[AmbientAI] scanning %d %s resource(s) for '%s' (6 ms slices, !ambient_anim_stop to cancel)",
        #list, bankType, scan.needle)
    ScanSlice()
end

if Ext and Ext.RegisterConsoleCommand then
    Ext.RegisterConsoleCommand("ambient_anim_fields", function(_cmd, typeArg)
        AnimProbe.fields(typeArg)
    end)
    Ext.RegisterConsoleCommand("ambient_anim_probe", function(_cmd, guidArg)
        AnimProbe.probe(guidArg)
    end)
    Ext.RegisterConsoleCommand("ambient_anim_sets", function(_cmd, needleArg)
        AnimProbe.sets(needleArg)
    end)
    Ext.RegisterConsoleCommand("ambient_anim_find", function(_cmd, needleArg, typeArg)
        AnimProbe.find(needleArg, typeArg)
    end)
    Ext.RegisterConsoleCommand("ambient_anim_stop", function()
        AnimProbe.stop(false)
    end)
    Ext.RegisterConsoleCommand("ambient_anim_guess", function(_cmd, baseArg)
        AnimProbe.guess(baseArg)
    end)
    -- 04.3.15 names kept as aliases so older notes keep working
    Ext.RegisterConsoleCommand("ambient_anim_test", function(_cmd, baseArg)
        AnimProbe.guess(baseArg)
    end)
end

'''


def main(src_path, out_path):
    src = open(src_path, encoding="utf-8").read()
    start = src.find(START_MARK)
    end = src.find(END_MARK)
    if start < 0 or end < 0 or end <= start:
        raise SystemExit("markers not found (start=%d end=%d)" % (start, end))
    out = src[:start] + NEW_BLOCK + src[end:]
    import lupa
    lua = lupa.LuaRuntime()
    try:
        lua.execute("local f, err = load(%r); if not f then error(err) end" % out)
    except Exception as exc:  # noqa: BLE001
        raise SystemExit("SYNTAX ERROR: %s" % exc)
    open(out_path, "w", encoding="utf-8").write(out)
    print("replaced anim finder block: %d -> %d bytes" % (end - start, len(NEW_BLOCK)))
    print("04.3.16 SYNTAX OK")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
