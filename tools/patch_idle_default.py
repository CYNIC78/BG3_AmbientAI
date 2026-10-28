#!/usr/bin/env python3
"""04.3.12: Grouped Idle Delay default 12 s -> 6 s (MCM floor stays 5 s).

The floor of 5 s is justified: decision tick is 600 ms, the idle anchor locks a 3.5 m
radius on expiry, and a 1-2 s base makes the whole party twitch on short loot stops
(measured on the stand: 5 action steps started / 2 aborted at 2 s stops vs 0 at 5 s).
The default of 12 s however stacked on top of the per-companion wake offsets
(0.2-1.2 / 2.2-4.3 / 4.6-7.4 s) meant the third companion only woke up at 16.6-19.4 s
and nothing at all happened on 6 s stops.

    python3 tools/patch_idle_default.py <in.lua> <out.lua>
"""
import sys, json

PATCHES_LUA = [
    ("ConfigValues default",
     "    GroupedIdleDelay    = 12,",
     "    GroupedIdleDelay    = 6,   -- 04.3.12: was 12 (wake offsets stack on top of this)"),
    ("clamp fallback on MCM read",
     "ConfigValues.GroupedIdleDelay = math.max(3, tonumber(value) or 12)",
     "ConfigValues.GroupedIdleDelay = math.max(3, tonumber(value) or 6)"),
    ("anchor gate fallback",
     "        local requiredMs = (Config.GroupedIdleDelay or 12) * 1000\n        if (now - HostLastActiveTime) >= requiredMs then",
     "        local requiredMs = (Config.GroupedIdleDelay or 6) * 1000\n        if (now - HostLastActiveTime) >= requiredMs then"),
    ("isGroupedAllowedNow fallback",
     "    local requiredMs = (Config.GroupedIdleDelay or 12) * 1000\n    return (now - HostLastActiveTime) >= requiredMs",
     "    local requiredMs = (Config.GroupedIdleDelay or 6) * 1000\n    return (now - HostLastActiveTime) >= requiredMs"),
    ("wake offset fallback",
     "        local requiredMs = (Config.GroupedIdleDelay or 12) * 1000 + (CompanionWakeOffsets[key] or 0)",
     "        local requiredMs = (Config.GroupedIdleDelay or 6) * 1000 + (CompanionWakeOffsets[key] or 0)"),
    ("debug log default",
     "            tonumber(Config.GroupedIdleDelay) or 12,",
     "            tonumber(Config.GroupedIdleDelay) or 6,"),
]


def patch_lua(src):
    applied = []
    for name, old, new in PATCHES_LUA:
        n = src.count(old)
        if n == 0:
            raise SystemExit("PATCH MISSING: %s" % name)
        src = src.replace(old, new)
        applied.append("%s x%d" % (name, n))
    return src, applied


def patch_blueprint(path):
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
    hits = []

    def walk(node):
        if isinstance(node, dict):
            if node.get("Id") == "AmbientAI_GroupedIdleDelay":
                assert node["Default"] == 12, node["Default"]
                node["Default"] = 6
                hits.append(node.get("Options"))
            for v in node.values():
                walk(v)
        elif isinstance(node, list):
            for v in node:
                walk(v)

    walk(data)
    assert len(hits) == 1, hits
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
        f.write("\n")
    return hits[0]


if __name__ == "__main__":
    src_path, out_path = sys.argv[1], sys.argv[2]
    with open(src_path, encoding="utf-8") as f:
        src = f.read()
    out, applied = patch_lua(src)
    import lupa
    lua = lupa.LuaRuntime()
    try:
        lua.execute("local f, err = load(%r); if not f then error(err) end" % out)
    except Exception as exc:  # noqa: BLE001
        raise SystemExit("SYNTAX ERROR: %s" % exc)
    with open(out_path, "w", encoding="utf-8") as f:
        f.write(out)
    print("applied %d patches: %s" % (len(applied), ", ".join(applied)))
    print("04.3.12 SYNTAX OK")
