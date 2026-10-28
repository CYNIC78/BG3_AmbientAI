#!/usr/bin/env python3
"""04.3.24: find familiars through DB_PlayerSummons, not through the spatial index.

The first in-game test of 04.3.23 printed

    no non-party character within 12 m

while the imp was standing in the same pile of characters as the party. Root cause is in the
mod's own chunked sweep:

    -- LocalSpatialIndex "chars" phase
    if ce ~= nil and ce.Transform ~= nil and ce.PartyMember == nil then

The sweep deliberately skips every entity that carries the `PartyMember` ECS component, and a
LINKED SUMMON (Pact of the Chain familiar) carries it - that is exactly why the idle system needs
`Osi.IsSummon` in `IsRealPartyCompanion` in the first place. So `LocalSpatialIndex.chars` never
contains the imp, and a list built from it can only ever say "nothing here".

Fix: read the summons from the Osiris database that exists for this purpose:

    Osi.DB_PlayerSummons:Get(nil)   -> rows of active player summons

That is independent of the ECS component layout and of the sweep's filters. The spatial index is
still used for the "don't stand on people" check, plus `Osi.GetPosition` for party members.

The diagnostics command now prints a compact report (the user's console costs seconds per line, so
the output is capped at a few lines) and states plainly whether the DB exists, how many rows it
has, and whether each summon is visible in the spatial index - so if the DB is empty while the
familiar is out, we learn that at once instead of guessing.

    python3 tools/patch_familiar_db.py <in.lua> <out.lua>
"""
import sys

PATCH_HELPERS = (
    "local function FamiliarIdleNote(why)\n",

    "-- 04.3.24: the spatial index skips every entity with a PartyMember component, and a linked\n"
    "-- summon (Pact of the Chain familiar) has one - so the index can never see the imp.\n"
    "-- DB_PlayerSummons is the Osiris database made for exactly this question.\n"
    "function FamiliarIdleSummons()\n"
    "    local out, seen = {}, {}\n"
    "    if not (Osi and Osi.DB_PlayerSummons) then return out end\n"
    "    local ok, rows = pcall(function() return Osi.DB_PlayerSummons:Get(nil) end)\n"
    "    if not ok or not rows then return out end\n"
    "    for _, row in pairs(rows) do\n"
    "        for _, cell in ipairs(row) do\n"
    "            if type(cell) == \"string\" and Osi.Exists and Osi.Exists(cell) == 1 then\n"
    "                local okS, isSummon = pcall(Osi.IsSummon, cell)\n"
    "                if okS and isSummon == 1 then\n"
    "                    local key = CleanUuid(cell) or cell\n"
    "                    if not seen[key] then\n"
    "                        seen[key] = true\n"
    "                        out[#out + 1] = cell\n"
    "                    end\n"
    "                end\n"
    "            end\n"
    "        end\n"
    "    end\n"
    "    return out\n"
    "end\n"
    "\n"
    "-- Template name if the entity is resolvable, otherwise the raw GUID string (in the game it\n"
    "-- already carries the template name, e.g. S_Player_ShadowHeart_3ed74f06-...).\n"
    "function FamiliarIdleName(u)\n"
    "    if Ext.Entity and Ext.Entity.Get then\n"
    "        local ok, e = pcall(Ext.Entity.Get, u)\n"
    "        if ok and e ~= nil and e.ServerCharacter ~= nil\n"
    "            and e.ServerCharacter.Template ~= nil\n"
    "            and e.ServerCharacter.Template.Name ~= nil then\n"
    "            return tostring(e.ServerCharacter.Template.Name)\n"
    "        end\n"
    "    end\n"
    "    return tostring(u)\n"
    "end\n"
    "\n"
    "function FamiliarIdleHasPartyComponent(u)\n"
    "    if not (Ext.Entity and Ext.Entity.Get) then return false end\n"
    "    local ok, e = pcall(Ext.Entity.Get, u)\n"
    "    return ok and e ~= nil and e.PartyMember ~= nil\n"
    "end\n"
    "\n"
    "local function FamiliarIdleNote(why)\n",
)

PATCH_TICK = (
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
    "    end\n",

    "    local seen = {}\n"
    "    -- 04.3.24: ask the game who the summons are (the spatial index cannot see them)\n"
    "    for _, u in ipairs(FamiliarIdleSummons()) do\n"
    "        local key = CleanUuid(u) or u\n"
    "        seen[key] = true\n"
    "        FamiliarIdle.found[key] = FamiliarIdleName(u)\n"
    "        local dead = Osi.IsDead and Osi.IsDead(u) == 1\n"
    "        local d = Osi.GetDistanceTo and Osi.GetDistanceTo(host, u) or nil\n"
    "        local okEnemy, isEnemy = pcall(Osi.IsEnemy, host, u)\n"
    "        if dead then\n"
    "            FamiliarIdleNote(\"summon is dead\")\n"
    "        elseif not d then\n"
    "            FamiliarIdleNote(\"no distance\")\n"
    "        elseif d > 12.0 then\n"
    "            FamiliarIdleNote(\"familiar too far\")\n"
    "        elseif d < 1.2 then\n"
    "            FamiliarIdleNote(\"familiar is on the host\")\n"
    "        elseif okEnemy and isEnemy == 1 then\n"
    "            FamiliarIdleNote(\"summon is hostile\")\n"
    "        elseif now >= (FamiliarIdle.nextHopAt[key] or 0) then\n"
    "            FamiliarIdle.hop(u, key, now, hx, hy, hz)\n"
    "        end\n"
    "    end\n",
)

PATCH_CMD = (
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
    "    Ext.Utils.Print(\"  usage: !ambient_familiars on | off   (this list is what we key on)\")\n",

    "    local host = Osi.GetHostCharacter and Osi.GetHostCharacter() or nil\n"
    "    -- 04.3.24: report from DB_PlayerSummons (works even when the spatial index skips the\n"
    "    -- summon). Console lines cost seconds in some setups, so the output stays short.\n"
    "    local rows = 0\n"
    "    if Osi.DB_PlayerSummons then\n"
    "        local ok, r = pcall(function() return Osi.DB_PlayerSummons:Get(nil) end)\n"
    "        if ok and r then rows = #r end\n"
    "    end\n"
    "    local summons = FamiliarIdleSummons()\n"
    "    local indexed = 0\n"
    "    for _, u in ipairs(summons) do\n"
    "        for _, nc in ipairs(LocalSpatialIndex.chars or {}) do\n"
    "            if nc.u == u then indexed = indexed + 1 end\n"
    "        end\n"
    "    end\n"
    "    Ext.Utils.Print(string.format(\n"
    "        \"[AmbientAI] familiar idles: %s | hops=%d skipped=%d last='%s'\",\n"
    "        FamiliarIdle.enabled and \"ON\" or \"OFF\", FamiliarIdle.hops or 0,\n"
    "        FamiliarIdle.skipped or 0, tostring(FamiliarIdle.lastReason or \"-\")))\n"
    "    Ext.Utils.Print(string.format(\n"
    "        \"  DB_PlayerSummons: %s | rows=%d summons=%d inSpatialIndex=%d\",\n"
    "        Osi.DB_PlayerSummons and \"ok\" or \"MISSING\", rows, #summons, indexed))\n"
    "    local shown = 0\n"
    "    for _, u in ipairs(summons) do\n"
    "        if shown < 4 then\n"
    "            shown = shown + 1\n"
    "            local d = host and Osi.GetDistanceTo and Osi.GetDistanceTo(host, u) or nil\n"
    "            local nm = FamiliarIdleName(u)\n"
    "            if #nm > 40 then nm = string.sub(nm, 1, 40) end\n"
    "            Ext.Utils.Print(string.format(\n"
    "                \"  %-40s %5.1f m  summon=%s partyComp=%s\",\n"
    "                nm, d or -1, tostring(FamiliarIdleSummonFlag(u)),\n"
    "                tostring(FamiliarIdleHasPartyComponent(u))))\n"
    "        end\n"
    "    end\n"
    "    if #summons == 0 then\n"
    "        Ext.Utils.Print(\"  no summons reported by the game - summon the familiar and run this again\")\n"
    "    end\n"
    "    Ext.Utils.Print(\"  usage: !ambient_familiars on | off\")\n",
)


def main(src_path, out_path):
    src = open(src_path, encoding="utf-8").read()
    applied = []
    for name, (old, new) in [
        ("summon discovery helpers", PATCH_HELPERS),
        ("tick reads DB_PlayerSummons", PATCH_TICK),
        ("compact diagnostic report", PATCH_CMD),
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
    print("04.3.24 SYNTAX OK")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
