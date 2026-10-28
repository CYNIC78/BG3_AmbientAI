#!/usr/bin/env python3
"""04.3.23: give familiars/summons a little character in idles (EXPERIMENTAL, off by default).

Why this is cheap: the mod already indexes every non-party character within 26 m of the host
(`LocalSpatialIndex.chars` - uuid + template name + position) on a chunked, ~0.2 ms/tick budget,
and the idle system *deliberately* drops summons:

    IsRealPartyCompanion():  if Osi.IsSummon and Osi.IsSummon(char) == 1 then return false end

So an imp that follows you around never does anything on its own - it just hovers where the engine
parked it. This patch adds one small module that re-uses the existing index:

    * every 45-120 s a familiar near the host moves 1.8-4 m to another spot around it
      (engine move call, no teleports, no forced animations, no seat/pose touching);
    * never during combat, never while a hostile is nearby (same rule as the candles),
      never during dialog, never while the host is walking;
    * personal space respected: no spot closer than 1.2 m to any other character;
    * all of it is gated by one toggle, default OFF, persisted in the save (not in MCM, so no
      saved MCM value of the user is ever overwritten).

Console command:

    !ambient_familiars on | off
    !ambient_familiars            -> state, counters, and the diagnostic list of every
                                     non-party character within 12 m with its template name
                                     and whether BG3SE reports it as a summon / follower

That list is the point: it tells us what the game actually calls the familiar, so v2 can key on
template names even if IsSummon does not flag them.

    python3 tools/patch_familiar_idle.py <in.lua> <out.lua>
"""
import sys

PATCH_MODULE = (
    "Ext.Events.Tick:Subscribe(function()\n"
    "    -- Strict lifecycle gate: never touch Osi.* during LoadModule / LoadSession / LoadLevel / Sync / Paused\n",

    "-- ============================================================================\n"
    "-- 04.3.23: familiar/summon idles (EXPERIMENTAL, off by default)\n"
    "-- The idle system drops summons on purpose (IsRealPartyCompanion), so a familiar never\n"
    "-- does anything of its own. Re-use the existing spatial index: now and then it drifts\n"
    "-- 1.8-4 m to another spot around the host. No teleports, no forced animations.\n"
    "-- ============================================================================\n"
    "FamiliarIdle = {\n"
    "    enabled    = false,\n"
    "    inited     = false,\n"
    "    nextScanAt = 0,\n"
    "    scanMs     = 1000,     -- cheap: look around at most once a second\n"
    "    hopMinMs   = 45000,    -- a familiar fidgets every 45-120 s, not constantly\n"
    "    hopMaxMs   = 120000,\n"
    "    nextHopAt  = {},\n"
    "    found      = {},\n"
    "    hops       = 0,\n"
    "    skipped    = 0,\n"
    "    lastReason = \"-\",\n"
    "}\n"
    "\n"
    "local function FamiliarIdleSummonFlag(u)\n"
    "    if not (u and Osi and Osi.IsSummon) then return false end\n"
    "    local ok, v = pcall(Osi.IsSummon, u)\n"
    "    return ok and v == 1\n"
    "end\n"
    "\n"
    "local function FamiliarIdleFollowerFlag(u)\n"
    "    if not (u and Osi and Osi.IsPartyFollower) then return false end\n"
    "    local ok, v = pcall(Osi.IsPartyFollower, u)\n"
    "    return ok and v == 1\n"
    "end\n"
    "\n"
    "function FamiliarIdle.syncFromSave()\n"
    "    if FamiliarIdle.inited then return end\n"
    "    FamiliarIdle.inited = true\n"
    "    PersistentVars = PersistentVars or {}\n"
    "    FamiliarIdle.enabled = (PersistentVars.FamiliarIdle == true)\n"
    "end\n"
    "\n"
    "function FamiliarIdle.setEnabled(on)\n"
    "    FamiliarIdle.syncFromSave()\n"
    "    FamiliarIdle.enabled = on and true or false\n"
    "    PersistentVars = PersistentVars or {}\n"
    "    PersistentVars.FamiliarIdle = FamiliarIdle.enabled\n"
    "    Ext.Utils.Print(string.format(\n"
    "        \"[AmbientAI] familiar idles %s (experimental) - a familiar now drifts to a new spot \"\n"
    "        .. \"near the host every %d-%d s, never in combat or near hostiles\",\n"
    "        FamiliarIdle.enabled and \"ON\" or \"OFF\",\n"
    "        math.floor(FamiliarIdle.hopMinMs / 1000), math.floor(FamiliarIdle.hopMaxMs / 1000)))\n"
    "end\n"
    "\n"
    "local function FamiliarIdleNote(why)\n"
    "    FamiliarIdle.skipped = FamiliarIdle.skipped + 1\n"
    "    FamiliarIdle.lastReason = why\n"
    "end\n"
    "\n"
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
    "end\n"
    "\n"
    "function FamiliarIdle.tick(now)\n"
    "    FamiliarIdle.syncFromSave()\n"
    "    if not FamiliarIdle.enabled then return end\n"
    "    if now < FamiliarIdle.nextScanAt then return end\n"
    "    FamiliarIdle.nextScanAt = now + FamiliarIdle.scanMs\n"
    "    if not (Osi and Osi.GetHostCharacter) then return end\n"
    "    local host = Osi.GetHostCharacter()\n"
    "    if not host then return end\n"
    "    if IsAnyDialogActive() then FamiliarIdleNote(\"dialog\") return end\n"
    "    if Osi.IsInCombat and Osi.IsInCombat(host) == 1 then FamiliarIdleNote(\"combat\") return end\n"
    "    if LocalSpatialIndex.enemyNearby then FamiliarIdleNote(\"hostiles nearby\") return end\n"
    "    if Osi.IsMoving and Osi.IsMoving(host) == 1 then FamiliarIdleNote(\"host is walking\") return end\n"
    "    if not LocalSpatialIndex.ready then FamiliarIdleNote(\"index warming up\") return end\n"
    "    local hx, hy, hz = LocalSpatialIndex.hx, LocalSpatialIndex.hy, LocalSpatialIndex.hz\n"
    "    if not hx or not hz then FamiliarIdleNote(\"no host position\") return end\n"
    "    local seen = {}\n"
    "    for _, nc in ipairs(LocalSpatialIndex.chars or {}) do\n"
    "        local u = nc.u\n"
    "        if u and not nc.dead then\n"
    "            local okS, isSummon = pcall(Osi.IsSummon, u)\n"
    "            if okS and isSummon == 1 then\n"
    "                local key = CleanUuid(u) or u\n"
    "                seen[key] = true\n"
    "                FamiliarIdle.found[key] = nc.name\n"
    "                local d = Osi.GetDistanceTo and Osi.GetDistanceTo(host, u) or nil\n"
    "                local okEnemy, isEnemy = pcall(Osi.IsEnemy, host, u)\n"
    "                if d and d > 12.0 then\n"
    "                    FamiliarIdleNote(\"familiar too far\")\n"
    "                elseif d and d < 1.2 then\n"
    "                    FamiliarIdleNote(\"familiar is on the host\")\n"
    "                elseif okEnemy and isEnemy == 1 then\n"
    "                    FamiliarIdleNote(\"summon is hostile\")\n"
    "                elseif now >= (FamiliarIdle.nextHopAt[key] or 0) then\n"
    "                    FamiliarIdle.hop(u, key, now, hx, hy, hz)\n"
    "                end\n"
    "            end\n"
    "        end\n"
    "    end\n"
    "    for key in pairs(FamiliarIdle.found) do\n"
    "        if not seen[key] then FamiliarIdle.found[key] = nil end\n"
    "    end\n"
    "end\n"
    "\n"
    "Ext.Events.Tick:Subscribe(function()\n"
    "    -- Strict lifecycle gate: never touch Osi.* during LoadModule / LoadSession / LoadLevel / Sync / Paused\n",
)

PATCH_TICK_CALL = (
    "        if CurrentReader ~= nil then\n"
    "            local rq = ActiveQueues[CurrentReader]\n"
    "            if not rq or not rq.isProcessing then\n"
    "                CurrentReader = nil\n"
    "            end\n"
    "        end\n"
    "    end\n"
    "\n"
    "    if IsAnyDialogActive() then\n",

    "        if CurrentReader ~= nil then\n"
    "            local rq = ActiveQueues[CurrentReader]\n"
    "            if not rq or not rq.isProcessing then\n"
    "                CurrentReader = nil\n"
    "            end\n"
    "        end\n"
    "    end\n"
    "\n"
    "    -- 04.3.23: familiars get a little character in idles (self-throttled, off by default)\n"
    "    FamiliarIdle.tick(now)\n"
    "\n"
    "    if IsAnyDialogActive() then\n",
)

PATCH_CMD = (
    "Ext.RegisterConsoleCommand(\"ambient_steps\", function(_cmd, countArg)\n"
    "    local ring = ActionQueue.stepRing\n"
    "    local want = math.max(1, math.min(ring.max, tonumber(countArg) or 20))\n"
    "    local lines = ring.lines\n"
    "    local from = math.max(1, #lines - want + 1)\n"
    "    Ext.Utils.Print(string.format(\"[AmbientAI] last %d step line(s) of %d buffered:\",\n"
    "        math.max(0, #lines - from + 1), #lines))\n"
    "    for i = from, #lines do\n"
    "        Ext.Utils.Print(\"  \" .. tostring(lines[i]))\n"
    "    end\n"
    "end)\n",

    "Ext.RegisterConsoleCommand(\"ambient_steps\", function(_cmd, countArg)\n"
    "    local ring = ActionQueue.stepRing\n"
    "    local want = math.max(1, math.min(ring.max, tonumber(countArg) or 20))\n"
    "    local lines = ring.lines\n"
    "    local from = math.max(1, #lines - want + 1)\n"
    "    Ext.Utils.Print(string.format(\"[AmbientAI] last %d step line(s) of %d buffered:\",\n"
    "        math.max(0, #lines - from + 1), #lines))\n"
    "    for i = from, #lines do\n"
    "        Ext.Utils.Print(\"  \" .. tostring(lines[i]))\n"
    "    end\n"
    "end)\n"
    "\n"
    "-- 04.3.23: familiar idles ------------------------------------------------\n"
    "Ext.RegisterConsoleCommand(\"ambient_familiars\", function(_cmd, arg)\n"
    "    FamiliarIdle.syncFromSave()\n"
    "    local a = string.lower(tostring(arg or \"\"))\n"
    "    if a == \"on\" then FamiliarIdle.setEnabled(true) return end\n"
    "    if a == \"off\" then FamiliarIdle.setEnabled(false) return end\n"
    "    Ext.Utils.Print(string.format(\n"
    "        \"[AmbientAI] familiar idles: %s | hops=%d skipped=%d last='%s'\",\n"
    "        FamiliarIdle.enabled and \"ON\" or \"OFF\", FamiliarIdle.hops or 0,\n"
    "        FamiliarIdle.skipped or 0, tostring(FamiliarIdle.lastReason or \"-\")))\n"
    "    local host = Osi.GetHostCharacter and Osi.GetHostCharacter() or nil\n"
    "    local shown = 0\n"
    "    if host and LocalSpatialIndex.chars then\n"
    "        for _, nc in ipairs(LocalSpatialIndex.chars) do\n"
    "            local u = nc.u\n"
    "            local d = u and Osi.GetDistanceTo and Osi.GetDistanceTo(host, u) or nil\n"
    "            if u and d and d <= 12.0 and shown < 12 then\n"
    "                shown = shown + 1\n"
    "                local hostile = false\n"
    "                if Osi.IsEnemy then\n"
    "                    local okE, r = pcall(Osi.IsEnemy, host, u)\n"
    "                    hostile = okE and r == 1\n"
    "                end\n"
    "                Ext.Utils.Print(string.format(\n"
    "                    \"  %-34s %5.1f m  summon=%s follower=%s%s\",\n"
    "                    tostring(nc.name ~= \"\" and nc.name or u), d,\n"
    "                    tostring(FamiliarIdleSummonFlag(u)),\n"
    "                    tostring(FamiliarIdleFollowerFlag(u)),\n"
    "                    hostile and \"  HOSTILE\" or \"\"))\n"
    "            end\n"
    "        end\n"
    "    end\n"
    "    if shown == 0 then\n"
    "        Ext.Utils.Print(\"  no non-party character within 12 m - summon the familiar next to you \"\n"
    "            .. \"and run the command again\")\n"
    "    end\n"
    "    Ext.Utils.Print(\"  usage: !ambient_familiars on | off   (this list is what we key on)\")\n"
    "end)\n",
)


def main(src_path, out_path):
    src = open(src_path, encoding="utf-8").read()
    applied = []
    for name, (old, new) in [
        ("familiar idle module", PATCH_MODULE),
        ("tick hook", PATCH_TICK_CALL),
        ("ambient_familiars command", PATCH_CMD),
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
    print("04.3.23 SYNTAX OK")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
