#!/usr/bin/env python3
"""04.3.18: drop the propless "old tome" animation, verified in game.

Field test on the host (build 04.3.17, !ambient_anim_play):
    tome bare     -> no tome in his hands
    tome triplet  -> no tome in his hands
    book auto     -> the book IS in his hands

So CUST_Reading_Old_Tome_01 simply has no prop, no matter how it is played; while
CUST_Reading_Book_01 does bring its book. Consequences:
  1. remove the tome from Gale's calm-idle pool (it looked like reading thin air);
  2. `pickReadAnim` no longer picks the tome at a bookshelf (used READ_TOME ~55% of the
     time for Gale / Minthara / Jaheira);
  3. keep the LOOP_TO_TRIPLET mapping and the READ_TOME constant (documented as unused)
     so a corrected Start GUID can be dropped in if one is ever found;
  4. add a `dukeread` key to !ambient_anim_play so the "thicker book" alternative
     (CUST_EPI_DukeWyll_Reading_01) can be checked visually before it is used anywhere.

    python3 tools/patch_no_tome.py <in.lua> <out.lua>
"""
import sys

PATCHES = [
    ("gale pool: drop old tome",
     '        [COMP.Gale] = {\n'
     '            "CUST_Thinking_01_97588786-d9bf-4d18-879b-1bd3dcaa62ba",\n'
     '            "CUST_Reading_Old_Tome_01_7ce9c8f5-a969-4e66-a5c5-9a8c0d51d937",\n'
     '            "CUST_Writing_02_Loop_896b83fb-27c3-41e0-924c-7ebf8473154b",\n'
     '        },',
     '        [COMP.Gale] = {\n'
     '            "CUST_Thinking_01_97588786-d9bf-4d18-879b-1bd3dcaa62ba",\n'
     '            -- 04.3.18: CUST_Reading_Old_Tome_01 removed - played with empty hands in\n'
     '            -- every mode (verified on the host), so it read as "reading thin air".\n'
     '            "CUST_Writing_02_Loop_896b83fb-27c3-41e0-924c-7ebf8473154b",\n'
     '        },'),
    ("pickReadAnim: always the book",
     '    function AnimSystem.pickReadAnim(char)\n'
     '        local c = CleanUuid(char)\n'
     '        if Config.Personalities and (c == COMP.Gale or c == COMP.Minthara or c == COMP.Jaheira) and math.random() < 0.55 then\n'
     '            return AnimSystem.READ_TOME\n'
     '        end\n'
     '        return AnimSystem.READ_BOOK\n'
     '    end',
     '    function AnimSystem.pickReadAnim(char)\n'
     '        -- 04.3.18: the old tome clip never spawns its prop (bare and triplet both verified\n'
     '        -- empty-handed in game), while the plain book clip does. So everybody reads a book.\n'
     '        -- READ_TOME stays below for the day a working Start GUID turns up.\n'
     '        return AnimSystem.READ_BOOK\n'
     '    end'),
    ("play-test: add the thicker reading variant",
     '    book    = "CUST_Reading_Book_01_Loop_d8db9dc7-c6dd-4b6f-8af0-620c7473d8f8",',
     '    book    = "CUST_Reading_Book_01_Loop_d8db9dc7-c6dd-4b6f-8af0-620c7473d8f8",\n'
     '    dukeread = "CUST_EPI_DukeWyll_Reading_01_Loop_e7047375-2edf-4c19-a408-e1f507020e78",'),
]


def main(src_path, out_path):
    src = open(src_path, encoding="utf-8").read()
    applied = []
    for name, old, new in PATCHES:
        if src.count(old) != 1:
            raise SystemExit("PATCH MISSING (%s): count=%d" % (name, src.count(old)))
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
    print("04.3.18 SYNTAX OK")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
