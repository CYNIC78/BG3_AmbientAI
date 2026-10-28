#!/usr/bin/env python3
"""AmbientAI 04.3.5 "stand up before you follow" patch.

Applies on top of the 04.3.4 output (patch_light_repair.py -> patch_light_walk.py).

Problem (from the user's log):
    S_Player_ShadowHeart started: SitOnSeat
    S_Player_ShadowHeart started: RelaxingOnSeat
    ... aborting sequence (grouped_active)
  -> the companion does not stand up and run after the player, she TELEPORTS
     behind the player.

Cause: the seat sequences use the native repose (`Osi.SitOnEntity`), which binds the
character to the furniture socket, plus `Osi.SetNoFollowFlag(char, 1)` to stop BG3's
FollowOwnerOrLeader() from yanking them off the bench. On abort the code did:

    SetAmbientSeatFollowLock(char, false)   -- releases SetNoFollowFlag
    Osi.EndRepose(char)                     -- ...and only THEN ends the repose

So for at least one engine frame the companion is a *following* party member that is
still welded to a chair socket. BG3 resolves that with its catch-up teleport - the
character is snapped to the leader. Everything downstream (EndRepose, stand-up clip)
happens after the teleport, so the player only sees the pop.

Fix: never release the follow block while the character is still reposed.
`AmbientSeat.standUp()` keeps the block, asks the engine to end the repose and releases
the block only when the engine confirms it (`ReposeRemoved` Osiris event), with a
polling fallback if the event does not arrive.

Run:  python3 tools/patch_sit_standup.py [in.lua] [out.lua]
"""
import sys

SRC = sys.argv[1] if len(sys.argv) > 1 else "unpacked_fixed/Mods/AmbientAI/ScriptExtender/Lua/BootstrapServer.lua"
DST = sys.argv[2] if len(sys.argv) > 2 else "unpacked_fixed/Mods/AmbientAI/ScriptExtender/Lua/BootstrapServer.lua"
s = open(SRC, encoding="utf-8").read()
n0 = len(s)

# ---------------------------------------------------------------------------
# 1. Split the raw flag setter from the seat-aware release gate
# ---------------------------------------------------------------------------
OLD_LOCK = '''local function SetAmbientSeatFollowLock(char, locked)
    if not char then return end
    PersistentVars = PersistentVars or {}
    if type(PersistentVars.SeatFollowLocked) ~= "table" then
        PersistentVars.SeatFollowLocked = {}
    end
    local key = CleanUuid(char) or char
    if locked then
        if PersistentVars.SeatFollowLocked[key] ~= true then
            PersistentVars.SeatFollowLocked[key] = true
            if Osi.SetNoFollowFlag then
                pcall(Osi.SetNoFollowFlag, char, 1)
            end
        end
    else
        local hadLock = (PersistentVars.SeatFollowLocked[key] == true)
        PersistentVars.SeatFollowLocked[key] = nil
        if hadLock and Osi.SetNoFollowFlag then
            pcall(Osi.SetNoFollowFlag, char, 0)
        end
    end
end
'''

NEW_LOCK = r'''local function SetSeatFollowFlagRaw(char, locked)
    if not char then return end
    PersistentVars = PersistentVars or {}
    if type(PersistentVars.SeatFollowLocked) ~= "table" then
        PersistentVars.SeatFollowLocked = {}
    end
    local key = CleanUuid(char) or char
    if locked then
        if PersistentVars.SeatFollowLocked[key] ~= true then
            PersistentVars.SeatFollowLocked[key] = true
            if Osi.SetNoFollowFlag then
                pcall(Osi.SetNoFollowFlag, char, 1)
            end
        end
    else
        local hadLock = (PersistentVars.SeatFollowLocked[key] == true)
        PersistentVars.SeatFollowLocked[key] = nil
        if hadLock and Osi.SetNoFollowFlag then
            pcall(Osi.SetNoFollowFlag, char, 0)
        end
    end
end

-- ============================================================================
-- 3B. SEAT DISMOUNT GATE (Build 04.3.5)
--
-- BG3's repose (Osi.SitOnEntity / Osi.LieOnEntity) welds the character to a socket of
-- the furniture. A party member that is *following* while still welded gets resolved by
-- the engine with a catch-up teleport to the leader - exactly the "companions teleport
-- instead of standing up" bug. Therefore the follow block must stay ON until the engine
-- confirms the repose ended (ReposeRemoved event, with a polling fallback).
-- ============================================================================
AmbientSeat = {
    pendingRelease = {},   -- cleanUuid -> reason
    inFlight = {},         -- cleanUuid -> true while a stand-up cascade is running
    releaseLog = {},
    pollMs = 150,
    maxPolls = 24,
}

function AmbientSeat.isSeated(char)
    if not char then return false end
    local ok, seated = pcall(function()
        if Osi.IsReposed and Osi.IsReposed(char) == 1 then return true end
        if Osi.IsReposedSitting and Osi.IsReposedSitting(char) == 1 then return true end
        if Osi.IsReposedLying and Osi.IsReposedLying(char) == 1 then return true end
        return false
    end)
    return ok and seated == true
end

function AmbientSeat.seatName(char)
    local ok, name = pcall(function()
        local e = Ext.Entity.Get(char)
        local sc = e and e.ServerCharacter or nil
        return tostring(sc and sc.Template and sc.Template.Name or char)
    end)
    return ok and name or tostring(char)
end

-- Final, unconditional release (engine already confirmed the character is standing)
function AmbientSeat.releaseNow(char, reason)
    SetSeatFollowFlagRaw(char, false)
    local key = CleanUuid(char) or char
    AmbientSeat.pendingRelease[key] = nil
    AmbientSeat.inFlight[key] = nil
    Log(string.format("[SEAT] %s follow released (%s)", AmbientSeat.seatName(char), tostring(reason or "standing")))
end

-- Called by the ReposeRemoved Osiris event: this is the authoritative "character stood up"
function AmbientSeat.onReposeRemoved(char)
    if not char then return end
    local key = CleanUuid(char) or char
    if AmbientSeat.pendingRelease[key] then
        AmbientSeat.releaseNow(char, "repose_removed")
    end
end

-- Keep the follow block, end the repose, release only when the character is out of the pose
function AmbientSeat.standUp(char, reason, attempt)
    if not char then return end
    attempt = attempt or 0
    local key = CleanUuid(char) or char

    -- abort() calls the action's onAbort AND the seat branch; only run the cascade once
    if attempt == 0 and AmbientSeat.inFlight[key] then return end
    if attempt == 0 then AmbientSeat.inFlight[key] = true end

    if not AmbientSeat.isSeated(char) then
        if attempt == 0 then
            AmbientSeat.releaseNow(char, reason or "not_seated")
        else
            AmbientSeat.releaseNow(char, "stood_up")
        end
        return
    end

    -- Still seated: make sure the follow block is ON so the engine cannot teleport them
    SetSeatFollowFlagRaw(char, true)
    AmbientSeat.pendingRelease[key] = reason or "stand_up"

    local shouldAsk = (attempt == 0) or (attempt % 6 == 0)
    if shouldAsk then
        if attempt == 0 then
            Log(string.format("[SEAT] %s is reposed -> EndRepose, holding follow block until it stands",
                AmbientSeat.seatName(char)))
        end
        if Osi.EndRepose then pcall(Osi.EndRepose, char) end
    end

    -- Fallback: if a pending sit task keeps re-seating the character, drop it once
    if attempt == 8 and PurgeCharacterOsiris then
        pcall(PurgeCharacterOsiris, char)
    end

    if attempt >= AmbientSeat.maxPolls then
        Log(string.format("[SEAT] %s never reported ReposeRemoved - releasing follow anyway", AmbientSeat.seatName(char)))
        AmbientSeat.releaseNow(char, "timeout")
        return
    end

    Ext.Timer.WaitFor(AmbientSeat.pollMs, function()
        if not IsOsirisReady() then return end
        if AmbientSeat.pendingRelease[key] == nil then return end   -- already released by the event
        AmbientSeat.standUp(char, reason, attempt + 1)
    end)
end

-- Public gate: every "unlock" request in the mod goes through here
function SetAmbientSeatFollowLock(char, locked)
    if not char then return end
    if locked then
        SetSeatFollowFlagRaw(char, true)
    else
        if AmbientSeat.isSeated(char) then
            AmbientSeat.standUp(char, "unlock_request")
        else
            SetSeatFollowFlagRaw(char, false)
        end
    end
end
'''

assert OLD_LOCK in s, "SetAmbientSeatFollowLock block not found"
s = s.replace(OLD_LOCK, NEW_LOCK, 1)

# ---------------------------------------------------------------------------
# 2. StandUpFromFurniture -> route through the gate
# ---------------------------------------------------------------------------
OLD_STANDUP = '''local function StandUpFromFurniture(char)
    if not char then return end
    -- Release PartyBlockFollowComponent FIRST so FollowOwnerOrLeader() resumes cleanly!
    SetAmbientSeatFollowLock(char, false)
    -- IMPORTANT (Build 04.3.1): Prefer native Osi.EndRepose(char) when reposed so benches,
    -- chairs, stools & tavern beds play the exact Sit_Chair_End / Lie_Bed_End dismount!
    pcall(function()
        if Osi.IsInCombat(char) == 0 then
            if Osi.EndRepose and ((not Osi.IsReposed) or Osi.IsReposed(char) == 1) then
                Osi.EndRepose(char)
                return
            end
            local x, y, z = Osi.GetPosition(char)
            if x then
                local vx, vy, vz = x + 0.45, y, z + 0.45
                if Osi.FindValidPosition then
                    local ok, fx, fy, fz = pcall(Osi.FindValidPosition, x + 0.50, y, z + 0.50, 2.0, char, 0)
                    if ok and fx then vx, vy, vz = fx, fy, fz end
                end
                Osi.CharacterMoveToPosition(char, vx, vy, vz, "Walk", "")
            end
        end
    end)
end
'''

NEW_STANDUP = '''local function StandUpFromFurniture(char)
    if not char then return end
    -- Build 04.3.5: the follow block is released by AmbientSeat ONLY after ReposeRemoved,
    -- otherwise BG3 snap-teleports a still-seated follower to the party leader.
    pcall(function()
        if Osi.IsInCombat and Osi.IsInCombat(char) == 1 then
            -- In combat we cannot wait: hard release, the engine needs them mobile now
            SetSeatFollowFlagRaw(char, false)
            return
        end
        if AmbientSeat.isSeated(char) then
            AmbientSeat.standUp(char, "sequence")
        else
            AmbientSeat.releaseNow(char, "already_standing")
        end
    end)
end
'''

assert OLD_STANDUP in s, "StandUpFromFurniture block not found"
s = s.replace(OLD_STANDUP, NEW_STANDUP, 1)

# ---------------------------------------------------------------------------
# 3. abort(): do not unlock before the dismount
# ---------------------------------------------------------------------------
OLD_ABORT = '''    SetAmbientSeatFollowLock(self.character, false)
    if abortedTag == "chair" or abortedTag == "bed" then
        StandUpFromFurniture(self.character)
    else
        if isUrgentCut or (wasCustomAnim and not IsCharacterSpeakingBark(self.character)) then
            StopCustomAnimation(self.character, not isUrgentCut)
        end
        PurgeCharacterOsiris(self.character)
    end'''
NEW_ABORT = '''    if abortedTag == "chair" or abortedTag == "bed" then
        -- Build 04.3.5: stand up FIRST (follow block held), release it afterwards.
        -- Releasing first is what made seated companions teleport to the player.
        Log(string.format("[SEAT] %s abort (%s) -> standing up before following",
            AmbientSeat.seatName(self.character), tostring(reason or "abort")))
        StandUpFromFurniture(self.character)
        if isUrgentCut then
            SetSeatFollowFlagRaw(self.character, false)
        end
    else
        SetAmbientSeatFollowLock(self.character, false)
        if isUrgentCut or (wasCustomAnim and not IsCharacterSpeakingBark(self.character)) then
            StopCustomAnimation(self.character, not isUrgentCut)
        end
        PurgeCharacterOsiris(self.character)
    end'''
assert OLD_ABORT in s, "abort() seat branch not found"
s = s.replace(OLD_ABORT, NEW_ABORT, 1)

# ---------------------------------------------------------------------------
# 4. Step-level onAbort handlers must not unlock either
# ---------------------------------------------------------------------------
OLD_ONABORT = '''        onAbort = function(char)
            SetAmbientSeatFollowLock(char, false)
        end,
    })
    queue:enqueue({
        name = "RelaxingOnSeat",'''
NEW_ONABORT = '''        onAbort = function(char)
            -- Build 04.3.5: stand up first; the follow block is released on ReposeRemoved
            StandUpFromFurniture(char)
        end,
    })
    queue:enqueue({
        name = "RelaxingOnSeat",'''
assert OLD_ONABORT in s, "SitOnSeat onAbort not found"
s = s.replace(OLD_ONABORT, NEW_ONABORT, 1)

OLD_ONABORT2 = '''        onAbort = function(char)
            SetAmbientSeatFollowLock(char, false)
        end,
        duration = math.random(18000, 32000),'''
NEW_ONABORT2 = '''        onAbort = function(char)
            StandUpFromFurniture(char)
        end,
        duration = math.random(18000, 32000),'''
assert OLD_ONABORT2 in s, "RelaxingOnSeat onAbort not found"
s = s.replace(OLD_ONABORT2, NEW_ONABORT2, 1)

# ---------------------------------------------------------------------------
# 5. Lag watchdog & session unstick: same ordering
# ---------------------------------------------------------------------------
OLD_LAG = '''                            CompanionLagSince[key] = nil
                            CompanionUnstickCooldown[key] = now + 8000
                            SetAmbientSeatFollowLock(comp, false)
                            if Osi.IsReposed and Osi.IsReposed(comp) == 1 and Osi.EndRepose then
                                pcall(Osi.EndRepose, comp)
                            end
                            StopCustomAnimation(comp, true)
                            PurgeCharacterOsiris(comp)'''
NEW_LAG = '''                            CompanionLagSince[key] = nil
                            CompanionUnstickCooldown[key] = now + 8000
                            if AmbientSeat.isSeated(comp) then
                                -- Seated & left behind: stand up (block held), follow resumes after
                                AmbientSeat.standUp(comp, "lag_watchdog")
                            else
                                SetAmbientSeatFollowLock(comp, false)
                                StopCustomAnimation(comp, true)
                                PurgeCharacterOsiris(comp)
                            end'''
assert OLD_LAG in s, "lag watchdog block not found"
s = s.replace(OLD_LAG, NEW_LAG, 1)

OLD_UNSTICK = '''                SetAmbientSeatFollowLock(comp, false)
                if Osi.IsReposed and Osi.IsReposed(comp) == 1 and Osi.EndRepose then
                    pcall(Osi.EndRepose, comp)
                end
                StopCustomAnimation(comp, true)
                PurgeCharacterOsiris(comp)
            end
        end
        return
    end'''
NEW_UNSTICK = '''                if AmbientSeat.isSeated(comp) then
                    AmbientSeat.standUp(comp, "session_unstick")
                else
                    SetAmbientSeatFollowLock(comp, false)
                end
                StopCustomAnimation(comp, true)
                PurgeCharacterOsiris(comp)
            end
        end
        return
    end'''
assert OLD_UNSTICK in s, "session unstick block not found"
s = s.replace(OLD_UNSTICK, NEW_UNSTICK, 1)

OLD_CMD_UNSTICK = '''                SetAmbientSeatFollowLock(c, false)
                if Osi.IsReposed and Osi.IsReposed(c) == 1 and Osi.EndRepose then
                    pcall(Osi.EndRepose, c)
                end
                StopCustomAnimation(c)
                PurgeCharacterOsiris(c)'''
NEW_CMD_UNSTICK = '''                if AmbientSeat.isSeated(c) then
                    AmbientSeat.standUp(c, "manual_unstick")
                else
                    SetAmbientSeatFollowLock(c, false)
                end
                StopCustomAnimation(c)
                PurgeCharacterOsiris(c)'''
assert OLD_CMD_UNSTICK in s, "!ambient_unstick body not found"
s = s.replace(OLD_CMD_UNSTICK, NEW_CMD_UNSTICK, 1)

# ---------------------------------------------------------------------------
# 6. ReposeRemoved listener (authoritative "stood up" signal)
# ---------------------------------------------------------------------------
OLD_LISTENER_ANCHOR = '''    Ext.Osiris.RegisterListener("DialogStarted", 2, "after", function(_dialog, instance)'''
NEW_LISTENER = '''    -- Build 04.3.5: authoritative dismount confirmation. Until this fires the companion
    -- keeps the follow block, so BG3 never catch-up-teleports them off a chair/bed.
    Ext.Osiris.RegisterListener("ReposeRemoved", 2, "after", function(character, _onEntity)
        if not IsOsirisReady() then return end
        if character then AmbientSeat.onReposeRemoved(character) end
    end)

    Ext.Osiris.RegisterListener("DialogStarted", 2, "after", function(_dialog, instance)'''
assert OLD_LISTENER_ANCHOR in s
s = s.replace(OLD_LISTENER_ANCHOR, NEW_LISTENER, 1)

# ---------------------------------------------------------------------------
# 7. `!ambient_seats` diagnostic
# ---------------------------------------------------------------------------
APPEND = r'''

-- ============================================================================
-- 13. SEAT / DISMOUNT DIAGNOSTIC (Build 04.3.5)
--   !ambient_seats  - who is reposed right now, who holds the follow block, pending releases
-- ============================================================================
Ext.RegisterConsoleCommand("ambient_seats", function()
    if not IsOsirisReady() then
        Ext.Utils.Print("[AmbientAI] Server not in Running state yet.")
        return
    end
    local now = Ext.Utils.MonotonicTime()
    Ext.Utils.Print("=== [AmbientAI] SEAT STATE ===")
    for _, c in ipairs(GetPartyCompanions()) do
        local key = CleanUuid(c) or c
        local lock = (PersistentVars and PersistentVars.SeatFollowLocked and PersistentVars.SeatFollowLocked[key] == true)
        local pending = AmbientSeat.pendingRelease[key]
        local seated = AmbientSeat.isSeated(c)
        local q = ActiveQueues[c]
        Ext.Utils.Print(string.format(" %-46s seated=%-5s followBlock=%-5s pendingRelease=%-14s queue=%s",
            tostring(c), tostring(seated), tostring(lock), tostring(pending or "-"),
            tostring(q and q.isProcessing and (q.activityTag or "?") or "idle")))
    end
    Ext.Utils.Print("=== end ===")
end)
'''

s = s.rstrip("\n") + APPEND
open(DST, "w", encoding="utf-8").write(s)
print(f"04.3.5 seat/stand-up patch: {SRC} ({n0}) -> {DST} ({len(s)})")
