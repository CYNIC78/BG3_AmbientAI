#!/usr/bin/env python3
"""04.3.14: lower the "Grouped Idle Delay" MCM floor from 5 s to 3 s.

The code clamp was already math.max(3, ...) - only the blueprint slider blocked 3-4 s.
Measured on the stand (sim/s27_idle_delay.lua, 8 stops per run, 3 companions):

    delay | 2.5 s stop      | 3.5 s stop     | 6 s stop       | 15 s stop
    3 s   | 9 started / 4 cut| 27 / 10        | 30 / 10        | 58 / 10
    5 s   | 0 / 0            | 0 / 0          | 33 / 11        | 43 / 8
    6 s   | 0 / 0            | 0 / 0          | 26 / 9         | 43 / 8

So 3 s buys noticeably faster reaction on medium stops, and the price is that very short
stops (looting a crate, reading a tooltip) start producing action steps that get cut
when the player walks on. 4 s sits in between; the default stays at 6 s.

    python3 tools/patch_idle_floor.py <MCM_blueprint.json>
"""
import json
import sys

NEW_DESCRIPTION = (
    "Seconds the player character must stand still before grouped companions start acting "
    "on their own. Lower = snappier reactions (3-4 s), higher = calmer party that ignores very "
    "short stops (8-12 s)."
)


def main(path):
    with open(path, encoding="utf-8") as f:
        data = json.load(f)

    hits = []

    def walk(node):
        if isinstance(node, dict):
            if node.get("Id") == "AmbientAI_GroupedIdleDelay":
                assert node["Options"]["Min"] == 5, node["Options"]
                node["Options"]["Min"] = 3
                node["Description"] = NEW_DESCRIPTION
                hits.append(node)
            for v in node.values():
                walk(v)
        elif isinstance(node, list):
            for v in node:
                walk(v)

    walk(data)
    assert len(hits) == 1, len(hits)

    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
        f.write("\n")
    print("MCM floor: 5 -> 3 | default %s | step %s | max %s"
          % (hits[0]["Default"], hits[0]["Options"]["Step"], hits[0]["Options"]["Max"]))
    print("04.3.14 blueprint OK")


if __name__ == "__main__":
    main(sys.argv[1])
