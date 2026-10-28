#!/usr/bin/env python3
"""04.3.25: give the familiar a bit of *character* in the drift, and a way to test real animations.

The random drift works (user confirmed: "Imp_Summon drifts to 432.93,78.79"), but random teleport-
points read as noise. A familiar that always moves along a circle around the party reads as
purposeful: it circles, sometimes turns around, sometimes swings close.

So:
  * each familiar keeps its own orbit angle + direction; every hop advances it by 35-75 degrees
    (direction flips ~20% of the time), radius 2.2-3.6 m, with a close pass (1.8-2.1 m) now and
    then - that is the "крутанулся вокруг" look without any animation asset;
  * after the move it turns to face the host (`Osi.LookAtEntity`) - cheap, one-shot, no asset;
  * up to 4 candidate points are tried per hop, so a crowded spot no longer eats the whole window.

Animations are a separate question: familiar clips live in the game's animation bank and are not
discoverable offline (the web has no names, and a 101k-entry sweep is what `!ambient_anim_find`
is for). To close that loop without another build:

    !ambient_anim_find imp        -> scans the Animation bank for names containing "imp"
    !ambient_familiars anim <name> -> plays that resource on every familiar for 9 s
    !ambient_familiars anim off    -> stops it

    python3 tools/patch_familiar_charm.py <in.lua> <out.lua>
"""
import sys

PATCH_STATE = (
    "    nextHopAt  = {},\n"
    "    found      = {},\n",

    "    nextHopAt  = {},\n"
    "    found      = {},\n"
    "    orbit      = {},   -- 04.3.25: map[cleanUuid] = { ang = radians, dir = 1 | -1 }\n",
)

PATCH_HOP = (
    "function FamiliarIdle.hop(u, key, now, hx, hy, hz)\n"
    "    local ang = math.random() * 6.28318530718\n"
    "    local r = 1.8 + math.random() * 2.2\n"
    "    local tx, tz = hx + math.cos(ang) * r, hz + math.sin(ang) * r\n"
    "    -- personal space (1.5 m): never park the familiar on top of somebody.\n"
    "    -- NOTE: LocalSpatialIndex.chars only holds NON-party entities (the sweep skips\n"
    "    -- PartyMember on purpose), so the party itself has to be asked directly.\n"
    "    local function FamiliarIdleCrowded(uuid)\n"
    "        if not (uuid and Osi.GetPosition) then return false end\n"
    "        local ok, px, py, pz = pcall(Osi.GetPosition, uuid)\n"
    "        if not ok or not px then return false end\n"
    "        local dx, dz = tx - px, tz - pz\n"
    "        return (dx * dx + dz * dz) < 2.25\n"
    "    end\n"
    "    for _, nc in ipairs(LocalSpatialIndex.chars or {}) do\n"
    "        local dx, dz = tx - nc.x, tz - nc.z\n"
    "        if (dx * dx + dz * dz) < 2.25 then\n"
    "            FamiliarIdleNote(\"crowded\")\n"
    "            return false\n"
    "        end\n"
    "    end\n"
    "    if GetPartyCompanions then\n"
    "        for _, pc in ipairs(GetPartyCompanions()) do\n"
    "            if FamiliarIdleCrowded(pc) then\n"
    "                FamiliarIdleNote(\"crowded (party)\")\n"
    "                return false\n"
    "            end\n"
    "        end\n"
    "    end\n"
    "    if not Osi.CharacterMoveToPosition then\n"
    "        FamiliarIdleNote(\"no move api\")\n"
    "        return false\n"
    "    end\n"
    "    if Osi.FindValidPosition then\n"
    "        local okPos, px, py, pz = pcall(Osi.FindValidPosition, tx, hy, tz, 0.6, u, u)\n"
    "        if okPos and px then tx, tz = px, pz or tz end\n"
    "    end\n"
    "    local okMove = pcall(Osi.CharacterMoveToPosition, u, tx, hy, tz, \"Walk\", \"\")\n"
    "    if not okMove then\n"
    "        FamiliarIdleNote(\"move call failed\")\n"
    "        return false\n"
    "    end\n"
    "    FamiliarIdle.hops = FamiliarIdle.hops + 1\n"
    "    FamiliarIdle.nextHopAt[key] = now + FamiliarIdle.hopMinMs\n"
    "        + math.random() * (FamiliarIdle.hopMaxMs - FamiliarIdle.hopMinMs)\n"
    "    Log(string.format(\"Familiar fidget: %s drifts to %.2f,%.2f (%.1f m from the host)\",\n"
    "        tostring(FamiliarIdle.found[key] or key), tx, tz, r))\n"
    "    return true\n"
    "end\n",

    "-- 04.3.25: instead of a random spot, walk the familiar along an orbit around the host:\n"
    "-- it circles, sometimes reverses, sometimes swings in close. Same rules, more character.\n"
    "function FamiliarIdle.hop(u, key, now, hx, hy, hz)\n"
    "    local TWO_PI = 6.28318530718\n"
    "    local orbit = FamiliarIdle.orbit[key]\n"
    "    if not orbit then\n"
    "        -- start from wherever the familiar actually is, so the first hop is not a jump\n"
    "        local ang = math.random() * TWO_PI\n"
    "        if Osi.GetPosition then\n"
    "            local ok, px, py, pz = pcall(Osi.GetPosition, u)\n"
    "            if ok and px and (math.abs(px - hx) > 0.01 or math.abs(pz - hz) > 0.01) then\n"
    "                local atan2 = math.atan2 or math.atan\n"
    "                ang = atan2(px - hx, pz - hz)\n"
    "            end\n"
    "        end\n"
    "        orbit = { ang = ang, dir = (math.random() < 0.5) and 1 or -1 }\n"
    "        FamiliarIdle.orbit[key] = orbit\n"
    "    end\n"
    "    if math.random() < 0.20 then orbit.dir = -orbit.dir end\n"
    "    local function FamiliarIdleCrowded(uuid, tx, tz)\n"
    "        if not (uuid and Osi.GetPosition) then return false end\n"
    "        local ok, px, py, pz = pcall(Osi.GetPosition, uuid)\n"
    "        if not ok or not px then return false end\n"
    "        local dx, dz = tx - px, tz - pz\n"
    "        return (dx * dx + dz * dz) < 2.25\n"
    "    end\n"
    "    local function FamiliarIdleSpotFree(tx, tz)\n"
    "        for _, nc in ipairs(LocalSpatialIndex.chars or {}) do\n"
    "            local dx, dz = tx - nc.x, tz - nc.z\n"
    "            if (dx * dx + dz * dz) < 2.25 then return false end\n"
    "        end\n"
    "        if GetPartyCompanions then\n"
    "            for _, pc in ipairs(GetPartyCompanions()) do\n"
    "                if FamiliarIdleCrowded(pc, tx, tz) then return false end\n"
    "            end\n"
    "        end\n"
    "        return true\n"
    "    end\n"
    "    if not Osi.CharacterMoveToPosition then\n"
    "        FamiliarIdleNote(\"no move api\")\n"
    "        return false\n"
    "    end\n"
    "    -- up to 4 candidates along the orbit, so a crowded spot does not eat the window.\n"
    "    -- The orbit angle only advances on a SUCCESSFUL hop: rejected candidates must not\n"
    "    -- silently spin the orbit (that made the drift look erratic after a crowded series).\n"
    "    local ang = orbit.ang\n"
    "    for attempt = 1, 4 do\n"
    "        ang = (ang + orbit.dir * (0.61 + math.random() * 0.70)) % TWO_PI\n"
    "        local r = 2.2 + math.random() * 1.4\n"
    "        if math.random() < 0.15 then r = 1.8 + math.random() * 0.3 end   -- close pass\n"
    "        local tx = hx + math.sin(ang) * r\n"
    "        local tz = hz + math.cos(ang) * r\n"
    "        if FamiliarIdleSpotFree(tx, tz) then\n"
    "            if Osi.FindValidPosition then\n"
    "                local okPos, px, py, pz = pcall(Osi.FindValidPosition, tx, hy, tz, 0.6, u, u)\n"
    "                if okPos and px then tx, tz = px, pz or tz end\n"
    "            end\n"
    "            local okMove = pcall(Osi.CharacterMoveToPosition, u, tx, hy, tz, \"Walk\", \"\")\n"
    "            if okMove then\n"
    "                orbit.ang = ang\n"
    "                FamiliarIdle.hops = FamiliarIdle.hops + 1\n"
    "                FamiliarIdle.nextHopAt[key] = now + FamiliarIdle.hopMinMs\n"
    "                    + math.random() * (FamiliarIdle.hopMaxMs - FamiliarIdle.hopMinMs)\n"
    "                -- turn to the party once it arrives: cheap, no animation asset involved\n"
    "                if Osi.LookAtEntity and Osi.GetHostCharacter then\n"
    "                    local host = Osi.GetHostCharacter()\n"
    "                    if host then pcall(Osi.LookAtEntity, u, host) end\n"
    "                end\n"
    "                Log(string.format(\n"
    "                    \"Familiar fidget: %s circles to %.2f,%.2f (%.1f m from the host, %+d deg)\",\n"
    "                    tostring(FamiliarIdle.found[key] or key), tx, tz, r,\n"
    "                    math.floor(orbit.dir * 35)))\n"
    "                return true\n"
    "            end\n"
    "        end\n"
    "    end\n"
    "    FamiliarIdleNote(\"crowded\")\n"
    "    return false\n"
    "end\n",
)

PATCH_CMD = (
    "    local a = string.lower(tostring(arg or \"\"))\n"
    "    if a == \"on\" then FamiliarIdle.setEnabled(true) return end\n"
    "    if a == \"off\" then FamiliarIdle.setEnabled(false) return end\n",

    "    local a = string.lower(tostring(arg or \"\"))\n"
    "    if a == \"on\" then FamiliarIdle.setEnabled(true) return end\n"
    "    if a == \"off\" then FamiliarIdle.setEnabled(false) return end\n"
    "    -- 04.3.25: try a real animation resource on the familiars without a new build\n"
    "    --   !ambient_familiars anim <resource-name>   |   !ambient_familiars anim off\n"
    "    local animArg = string.match(tostring(arg or \"\"), \"^[Aa][Nn][Ii][Mm]%s+(.+)$\")\n"
    "    if animArg then\n"
    "        local list = FamiliarIdleSummons()\n"
    "        if #list == 0 then\n"
    "            Ext.Utils.Print(\"[AmbientAI] no summons right now - run the command with no argument\")\n"
    "            return\n"
    "        end\n"
    "        if string.lower(animArg) == \"off\" then\n"
    "            for _, u in ipairs(list) do\n"
    "                pcall(function() Osi.StopAnimation(u, 0) end)\n"
    "            end\n"
    "            Ext.Utils.Print(\"[AmbientAI] familiar animation stopped on \" .. #list .. \" summon(s)\")\n"
    "            return\n"
    "        end\n"
    "        for _, u in ipairs(list) do\n"
    "            pcall(function() Osi.PlayAnimation(u, animArg, \"\") end)\n"
    "        end\n"
    "        Ext.Utils.Print(string.format(\"[AmbientAI] playing '%s' on %d familiar(s) for 9 s\",\n"
    "            animArg, #list))\n"
    "        if Ext.Timer and Ext.Timer.WaitFor then\n"
    "            local stop = list\n"
    "            Ext.Timer.WaitFor(9000, function()\n"
    "                for _, u in ipairs(stop) do\n"
    "                    pcall(function() Osi.StopAnimation(u, 0) end)\n"
    "                end\n"
    "                Ext.Utils.Print(\"[AmbientAI] animation test finished\")\n"
    "            end)\n"
    "        end\n"
    "        return\n"
    "    end\n",
)


def main(src_path, out_path):
    src = open(src_path, encoding="utf-8").read()
    applied = []
    for name, (old, new) in [
        ("orbit state", PATCH_STATE),
        ("orbiting hop + look-at", PATCH_HOP),
        ("anim test command", PATCH_CMD),
    ]:
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
    print("04.3.25 SYNTAX OK")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
