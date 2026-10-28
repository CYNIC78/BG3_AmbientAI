#!/usr/bin/env python3
"""04.3.13: tighter companion wake stagger.

Before: wake offsets 0.2-1.2 / 2.2-4.3 / 4.6-7.4 s (rolled every time the party stops),
        plus a second in-tick stagger CompanionRestUntil = now + nonBardDispatched * 1.3-2.9 s.
        With the 5 s idle gate the 3rd companion could start 16-18 s after the player stopped.

After:  offsets 0-0.3 / 0.4-0.8 / 0.8-1.3 s and a flat 0.6-1.2 s in-tick stagger.
        The decision tick is 600 ms, so anything below that is quantised to one tick anyway:
        0.6-1.2 s keeps "not all at once" while the last companion starts ~2-3 s after the first.

    python3 tools/patch_stagger.py <in.lua> <out.lua>
"""
import sys

PATCHES = [
    ("wake offset 1st",
     "            CompanionWakeOffsets[key] = math.random(200, 1200)",
     "            CompanionWakeOffsets[key] = math.random(0, 300)     -- 04.3.13: was 200..1200"),
    ("wake offset 2nd",
     "            CompanionWakeOffsets[key] = math.random(2200, 4300)",
     "            CompanionWakeOffsets[key] = math.random(400, 800)   -- 04.3.13: was 2200..4300"),
    ("wake offset 3rd",
     "            CompanionWakeOffsets[key] = math.random(4600, 7400)",
     "            CompanionWakeOffsets[key] = math.random(800, 1300)  -- 04.3.13: was 4600..7400"),
    ("wake offset 4th+",
     "            CompanionWakeOffsets[key] = (idx - 1) * 2300 + math.random(300, 1700)",
     "            CompanionWakeOffsets[key] = (idx - 1) * 500 + math.random(0, 300)  -- 04.3.13"),
    ("in-tick dispatch stagger",
     "        -- Never launch multiple companions on the exact same tick (stagger 2nd/3rd by 1.3s - 2.9s!)\n"
     "        if nonBardDispatched >= 1 and not activePerformer then\n"
     "            CompanionRestUntil[charKey] = now + (nonBardDispatched * math.random(1300, 2900))",
     "        -- 04.3.13: never launch several companions on the exact same tick, but keep it to\n"
     "        -- roughly one decision tick (600 ms) apart instead of 1.3-2.9 s * position.\n"
     "        if nonBardDispatched >= 1 and not activePerformer then\n"
     "            CompanionRestUntil[charKey] = now + math.random(600, 1200)"),
]


def main(src_path, out_path):
    src = open(src_path, encoding="utf-8").read()
    applied = []
    for name, old, new in PATCHES:
        if src.count(old) != 1:
            raise SystemExit("PATCH MISSING (%s): found %d" % (name, src.count(old)))
        src = src.replace(old, new)
        applied.append(name)
    import lupa
    lua = lupa.LuaRuntime()
    try:
        lua.execute("local f, err = load(%r); if not f then error(err) end" % src)
    except Exception as exc:  # noqa: BLE001
        raise SystemExit("SYNTAX ERROR: %s" % exc)
    open(out_path, "w", encoding="utf-8").write(src)
    print("applied %d patches: %s" % (len(applied), ", ".join(applied)))
    print("04.3.13 SYNTAX OK")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
