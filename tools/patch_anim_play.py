#!/usr/bin/env python3
"""04.3.17: compare how each vanity idle is played (triplet vs bare loop) on the host.

Field data (build 04.3.14, same session):
  CUST_Writing_02_Loop_896b83fb-...  -> quill + book ARE in his hands  (played BARE today)
  CUST_Reading_Old_Tome_01_7ce9c8f5-... -> nothing in his hands        (played as TRIPLET today)

So the props are not tied to "triplet vs bare" the way I assumed. Either the Start GUID we
use for the tome is wrong (then PlayLoopingAnimation silently falls back to the loop),
or that animation simply has no prop spawn. This build adds an on-host A/B test so the
answer comes from the game in ~30 seconds:

    !ambient_anim_play list              - available keys
    !ambient_anim_play write auto        - exactly how the mod plays it now
    !ambient_anim_play tome bare         - the loop alone, no Start/End pose
    !ambient_anim_play tome triplet      - Start + Loop + End from our table (if mapped)
    !ambient_anim_stop                   - stop the test animation immediately

    python3 tools/patch_anim_play.py <in.lua> <out.lua>
"""
import sys

ANCHOR_ISTRIPLET = """    function AnimSystem.isTriplet(animKey)
        return (animKey and LOOP_TO_TRIPLET[animKey] ~= nil) or false
    end
"""

REPLACEMENT_ISTRIPLET = ANCHOR_ISTRIPLET + """
    -- 04.3.17: console A/B test needs read access to the triplet table
    function AnimSystem.getTriplet(animKey)
        if not animKey then return nil end
        return LOOP_TO_TRIPLET[animKey]
    end
"""

ANCHOR_LIGHT = """-- ============================================================================
-- 11. LIGHT INVESTIGATION CONSOLE COMMANDS (Build 04.3.3)"""

PLAY_BLOCK = r'''-- ============================================================================
-- 10C. ANIMATION A/B TEST (Build 04.3.17)
--   Field report: CUST_Writing_02_Loop (played bare) shows quill + book, while
--   CUST_Reading_Old_Tome_01 (played as a Start/Loop/End triplet) shows nothing.
--   So let the host play the same clip both ways and look at his hands.
-- ============================================================================
AnimPlayTest = AnimPlayTest or {}

local ANIM_PLAY_KEYS = {
    write   = "CUST_Writing_02_Loop_896b83fb-27c3-41e0-924c-7ebf8473154b",
    tome    = "CUST_Reading_Old_Tome_01_7ce9c8f5-a969-4e66-a5c5-9a8c0d51d937",
    book    = "CUST_Reading_Book_01_Loop_d8db9dc7-c6dd-4b6f-8af0-620c7473d8f8",
    ponder  = "CUST_Pondering_01_Loop_a47454a1-05a2-4153-bdfe-7a0500fa62d0",
    bored   = "CUST_Bored_01_Loop_23588ba8-fafb-438c-9bc5-660ff6650aef",
    meditate = "CUST_Meditating_01_45b1a54b-b127-46d2-bfe6-daa8963398ea",
    warm    = "CUST_WarmingByFire_01_Loop_e2d0b8f4-00ae-49a4-a878-a9841fd78a96",
}

local function AnimPlayHelp()
    Ext.Utils.Print("[AmbientAI] usage: !ambient_anim_play <key> [auto|triplet|bare]")
    local keys = {}
    for k in pairs(ANIM_PLAY_KEYS) do keys[#keys + 1] = k end
    table.sort(keys)
    Ext.Utils.Print("  keys: " .. table.concat(keys, ", "))
    Ext.Utils.Print("  auto    = exactly how the mod plays it right now")
    Ext.Utils.Print("  triplet = Start + Loop + End from the mod's table (if mapped)")
    Ext.Utils.Print("  bare    = the loop alone, no start/end pose")
end

function AnimPlayTest.run(keyArg, modeArg)
    if not (Ext and Ext.Utils and Ext.Utils.Print) then return end
    if not keyArg or keyArg == "list" then
        AnimPlayHelp()
        return
    end
    local anim = ANIM_PLAY_KEYS[string.lower(tostring(keyArg))]
    if not anim then
        Ext.Utils.Print("[AmbientAI] unknown key '" .. tostring(keyArg) .. "'")
        AnimPlayHelp()
        return
    end
    local host = Osi.GetHostCharacter and Osi.GetHostCharacter() or nil
    if not host then
        Ext.Utils.Print("[AmbientAI] no host character.")
        return
    end

    local mode = string.lower(tostring(modeArg or "auto"))
    if mode ~= "auto" and mode ~= "triplet" and mode ~= "bare" then
        Ext.Utils.Print("[AmbientAI] unknown mode '" .. mode .. "'")
        AnimPlayHelp()
        return
    end

    local triplet = AnimSystem.getTriplet and AnimSystem.getTriplet(anim) or nil
    local used
    if mode == "auto" then
        AnimSystem.play(host, anim)
        used = triplet and "triplet (via AnimSystem.play)" or "bare loop (via AnimSystem.play)"
    elseif mode == "triplet" then
        if not triplet then
            Ext.Utils.Print("[AmbientAI] this clip has no Start/End mapping in the mod's table -")
            Ext.Utils.Print("  playing it as a triplet is impossible without the real GUIDs.")
            return
        end
        pcall(Osi.PlayLoopingAnimation, host, triplet.start or "", triplet.loop or anim,
            triplet.stop or "", "", "", "", "")
        used = string.format("triplet start=%s | end=%s", tostring(triplet.start), tostring(triplet.stop))
    else
        pcall(Osi.PlayAnimation, host, anim, "")
        used = "bare loop"
    end

    Ext.Utils.Print(string.format("[AmbientAI] playing '%s' as %s", tostring(keyArg), used))
    Ext.Utils.Print("  look at the host's hands for ~9 s: props or empty hands?")
    if Ext.Timer and Ext.Timer.WaitFor then
        Ext.Timer.WaitFor(9000, function()
            pcall(function() Osi.StopAnimation(host, 0) end)
            Ext.Utils.Print("[AmbientAI] test finished - try the other mode and compare.")
        end)
    end
end

if Ext and Ext.RegisterConsoleCommand then
    Ext.RegisterConsoleCommand("ambient_anim_play", function(_cmd, keyArg, modeArg)
        AnimPlayTest.run(keyArg, modeArg)
    end)
end

''' + ANCHOR_LIGHT


def main(src_path, out_path):
    src = open(src_path, encoding="utf-8").read()
    # 1) expose the triplet table
    if src.count(ANCHOR_ISTRIPLET) != 1:
        raise SystemExit("isTriplet anchor not unique (%d)" % src.count(ANCHOR_ISTRIPLET))
    out = src.replace(ANCHOR_ISTRIPLET, REPLACEMENT_ISTRIPLET)
    # 2) console command block
    if out.count(ANCHOR_LIGHT) != 1:
        raise SystemExit("light anchor not unique (%d)" % out.count(ANCHOR_LIGHT))
    out = out.replace(ANCHOR_LIGHT, PLAY_BLOCK)

    import lupa
    lua = lupa.LuaRuntime()
    try:
        lua.execute("local f, err = load(%r); if not f then error(err) end" % out)
    except Exception as exc:  # noqa: BLE001
        raise SystemExit("SYNTAX ERROR: %s" % exc)
    open(out_path, "w", encoding="utf-8").write(out)
    print("added AnimSystem.getTriplet + !ambient_anim_play")
    print("04.3.17 SYNTAX OK")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
