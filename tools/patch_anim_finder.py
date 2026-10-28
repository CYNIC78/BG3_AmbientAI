#!/usr/bin/env python3
"""04.3.15: in-game animation resource finder (diagnostics, not behaviour).

Why: the "writing" idle is played as a bare loop (no Start/End pose), so the book and
quill that BG3 only spawns from the animation's Start pose never appear. To play the
real triplet we need the Start/End animation resource names - and those live in the
game's own data, they are not documented anywhere on the web.

So this build adds two console commands that enumerate the game's animation resources
at runtime:

    !ambient_anim_find [substr]   - list animation resources whose name contains substr
                                    (default "Writing"), printed as Name_Guid, max 40 lines
    !ambient_anim_find            - no argument: dump the fields of a sample resource
                                    plus the first few raw guids (shape discovery)
    !ambient_anim_test [substr]   - play the best matching Start/Loop/End triplet on the
                                    host for ~9 s, so you can see in game whether the
                                    animation brings its props (book, quill, tome)

The scan is budgeted (40 resources per tick, self-driven timer chain) so it never
stalls the game, and it hard-stops after 60 s with a clear message.

    python3 tools/patch_anim_finder.py <in.lua> <out.lua>
"""
import sys

ANCHOR = """-- ============================================================================
-- 11. LIGHT INVESTIGATION CONSOLE COMMANDS (Build 04.3.3)"""

BLOCK = """-- ============================================================================
-- 10B. ANIMATION RESOURCE FINDER (Build 04.3.15, diagnostics)
--   The writing/reading idle poses only bring their props (book, quill, tome) when the
--   animation is played as a full Start / Loop / End triplet. Some vanity loops are only
--   documented as loops, so this scans the game's animation resources at runtime and can
--   test a triplet straight on the host.
-- ============================================================================
AnimFinder = AnimFinder or {
    type        = nil,
    handles     = nil,
    cursor      = 1,
    startedAt   = 0,
    steps       = 0,
    mode        = nil,
    needle      = nil,
    matches     = nil,
    sample      = nil,
    finished    = false,
}

function AnimFinder.describe(res, guid)
    local name = nil
    if type(res) == "table" then
        name = res.Name or res.ShortName or res.AnimationName or res.ID or res.DisplayName
        if not name and res.SourceFile then
            local src = tostring(res.SourceFile)
            name = string.match(src, "([%w_%-]+)%.gr2$") or nil
        end
    end
    if not name then return nil end
    return tostring(name)
end

function AnimFinder.finish(now)
    AnimFinder.finished = true
    local mode = AnimFinder.mode
    local needle = AnimFinder.needle or ""
    local matches = AnimFinder.matches or {}
    if mode == "sample" then
        Ext.Utils.Print("[AmbientAI] animation resource scan: " .. tostring(AnimFinder.cachedCount or 0) ..
            " entries of type " .. tostring(AnimFinder.type or "?") .. " (took " ..
            string.format("%.1fs", (now - (AnimFinder.startedAt or now)) / 1000.0) .. ")")
        if AnimFinder.sample then
            Ext.Utils.Print("  sample fields: " .. tostring(AnimFinder.sample))
        else
            Ext.Utils.Print("  sample fields: <could not read a resource struct>")
        end
        for idx = 1, math.min(8, AnimFinder.cachedCount or 0) do
            local raw = AnimFinder.firstGuids and AnimFinder.firstGuids[idx]
            if raw then Ext.Utils.Print(string.format("  raw guid [%d] %s", idx, tostring(raw))) end
        end
        Ext.Utils.Print("  now try: !ambient_anim_find Writing")
        return
    end
    if mode == "test" then
        local host = Osi.GetHostCharacter and Osi.GetHostCharacter() or nil
        if not host then
            Ext.Utils.Print("[AmbientAI] no host character.")
            return
        end
        local bySub = {}
        for _, entry in ipairs(matches) do
            bySub[entry.sub] = entry
        end
        local loop = bySub["Loop"] or bySub["loop"] or bySub["Start"] or bySub["start"]
        local startRes = bySub["Start"] or bySub["start"]
        local endRes = bySub["End"] or bySub["end"]
        if not loop then
            Ext.Utils.Print("[AmbientAI] nothing matched '" .. needle .. "'. Run !ambient_anim_find to list names.")
            return
        end
        if startRes and Osi.PlayLoopingAnimation then
            pcall(Osi.PlayLoopingAnimation, host, startRes.id, loop.id, endRes and endRes.id or "", "", "", "", "")
            Ext.Utils.Print(string.format(
                "[AmbientAI] playing triplet on host: start=%s | loop=%s | end=%s",
                tostring(startRes.id), tostring(loop.id), tostring(endRes and endRes.id or "<none>")))
        else
            pcall(Osi.PlayAnimation, host, loop.id, "")
            Ext.Utils.Print("[AmbientAI] no Start pose found - playing the bare loop " .. tostring(loop.id))
        end
        Ext.Utils.Print("  look at the host now: are the props (book, quill, tome) in his hands?")
        if Ext.Timer and Ext.Timer.WaitFor then
            Ext.Timer.WaitFor(9000, function()
                pcall(function() Osi.StopAnimation(host, 0) end)
                Ext.Utils.Print("[AmbientAI] animation test finished.")
            end)
        end
        return
    end
    Ext.Utils.Print(string.format(
        "[AmbientAI] %d animation resource(s) match '%s' (scanned %d entries, %.1fs):",
        #matches, needle, AnimFinder.cachedCount or 0,
        (now - (AnimFinder.startedAt or now)) / 1000.0))
    local printed = 0
    for _, entry in ipairs(matches) do
        if printed >= 40 then
            Ext.Utils.Print("  ... (truncated)")
            break
        end
        printed = printed + 1
        Ext.Utils.Print(string.format("  [%s] %s", tostring(entry.sub), tostring(entry.id)))
    end
    if #matches >= 3 then
        Ext.Utils.Print("  tip: !ambient_anim_test " .. needle .. "  - plays the triplet on the host")
    end
end

function AnimFinder.step(now)
    if AnimFinder.finished then return end
    if not (Ext and Ext.Resource and Ext.Resource.GetAll and Ext.Resource.Get) then
        Ext.Utils.Print("[AmbientAI] Ext.Resource is not available in this SE build - cannot scan.")
        AnimFinder.finished = true
        return
    end
    if not AnimFinder.handles then
        local types = { "Animation", "AnimationBlueprint", "AnimationSet" }
        for _, t in ipairs(types) do
            local ok, list = pcall(Ext.Resource.GetAll, t)
            if ok and type(list) == "table" and #list > 0 then
                AnimFinder.type = t
                AnimFinder.handles = list
                AnimFinder.cachedCount = #list
                AnimFinder.firstGuids = { list[1], list[2], list[3] }
                Ext.Utils.Print("[AmbientAI] scanning " .. tostring(#list) .. " resource(s) of type " .. t .. " ...")
                break
            end
        end
        if not AnimFinder.handles then
            Ext.Utils.Print("[AmbientAI] no animation resources came back from Ext.Resource.GetAll.")
            AnimFinder.finished = true
            return
        end
        AnimFinder.startedAt = now
    end

    local needle = string.lower(AnimFinder.needle or "")
    local stopAt = math.min(#AnimFinder.handles, AnimFinder.cursor + 39)
    pcall(function()
        for idx = AnimFinder.cursor, stopAt do
            local guid = AnimFinder.handles[idx]
            if guid then
                local res = Ext.Resource.Get(guid, AnimFinder.type)
                if not AnimFinder.sample and type(res) == "table" then
                    local parts = {}
                    for k in pairs(res) do
                        parts[#parts + 1] = tostring(k)
                        if #parts >= 12 then break end
                    end
                    AnimFinder.sample = table.concat(parts, ", ")
                end
                local name = AnimFinder.describe(res, guid)
                if name then
                    local lower = string.lower(name)
                    if string.find(lower, needle, 1, true) then
                        -- Lua patterns have no alternation: check each pose explicitly
                        local sub = string.match(lower, "_start") and "start"
                            or string.match(lower, "_loop") and "loop"
                            or string.match(lower, "_end") and "end"
                            or nil
                        AnimFinder.matches[#AnimFinder.matches + 1] = {
                            id = name .. "_" .. tostring(guid),
                            sub = sub or "single",
                        }
                    end
                end
            end
        end
    end)
    AnimFinder.cursor = stopAt + 1
    AnimFinder.steps = (AnimFinder.steps or 0) + 1

    if AnimFinder.cursor > #AnimFinder.handles then
        AnimFinder.finish(now)
        return
    end
    if (now - (AnimFinder.startedAt or now)) > 60000 then
        Ext.Utils.Print("[AmbientAI] animation scan timed out after 60s - partial result below.")
        AnimFinder.finish(now)
        return
    end
    if Ext.Timer and Ext.Timer.WaitFor then
        Ext.Timer.WaitFor(16, function()
            AnimFinder.step(Ext.Utils.MonotonicTime())
        end)
    else
        AnimFinder.finished = true
    end
end

function AnimFinder.start(mode, needle)
    if not (Ext and Ext.Utils and Ext.Utils.Print) then return end
    AnimFinder.handles = nil
    AnimFinder.cursor = 1
    AnimFinder.steps = 0
    AnimFinder.matches = {}
    AnimFinder.sample = nil
    AnimFinder.finished = false
    AnimFinder.mode = mode
    AnimFinder.needle = needle or "Writing"
    AnimFinder.startedAt = Ext.Utils.MonotonicTime()
    AnimFinder.step(AnimFinder.startedAt)
end

if Ext and Ext.RegisterConsoleCommand then
    Ext.RegisterConsoleCommand("ambient_anim_find", function(_cmd, needleArg)
        AnimFinder.start(needleArg and "find" or "sample", needleArg)
    end)
    Ext.RegisterConsoleCommand("ambient_anim_test", function(_cmd, needleArg)
        AnimFinder.start("test", needleArg)
    end)
end

""" + ANCHOR


def main(src_path, out_path):
    src = open(src_path, encoding="utf-8").read()
    if src.count(ANCHOR) != 1:
        raise SystemExit("ANCHOR not found exactly once (%d)" % src.count(ANCHOR))
    out = src.replace(ANCHOR, BLOCK)
    import lupa
    lua = lupa.LuaRuntime()
    try:
        lua.execute("local f, err = load(%r); if not f then error(err) end" % out)
    except Exception as exc:  # noqa: BLE001
        raise SystemExit("SYNTAX ERROR: %s" % exc)
    open(out_path, "w", encoding="utf-8").write(out)
    print("applied anim finder (%d bytes of new code)" % (len(BLOCK) - len(ANCHOR)))
    print("04.3.15 SYNTAX OK")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
