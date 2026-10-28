-- ============================================================================
-- BG3 Script Extender / Osiris mock harness for AmbientAI offline simulation
-- ============================================================================

SIM = {
    time = 0,
    moves = {},          -- cleanUuid -> { tx, ty, tz, speed }
    obstacles = {},      -- { x, z, r } - AI grid rejects points inside, walking is clamped outside
    walkSpeed = 3.0,
    seated = {},        -- cleanUuid -> chair uuid (native Repose)
    reposedAt = {},
    nofollow = {},      -- cleanUuid -> true while the mod blocks party follow
    teleports = {},     -- list of { char, at } - engine catch-up teleports
    followModel = false,
    prints = {},
    timers = {},
    nextTimerId = 1,
    stats = { applyStatus = {}, socket = 0, use = 0, errors = {} },
}

function SIM.log(fmt, ...)
    local s = select('#', ...) > 0 and string.format(fmt, ...) or fmt
    table.insert(SIM.prints, string.format("%8d  %s", SIM.time, s))
end

local function cleanguid(g)
    if type(g) ~= "string" then return g end
    return g:match("(%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x)$") or g
end
SIM.clean = cleanguid

function SIM.addTimer(ms, fn)
    local id = SIM.nextTimerId
    SIM.nextTimerId = id + 1
    table.insert(SIM.timers, { id = id, at = SIM.time + ms, fn = fn })
    return id
end

local function newEvent(name)
    local ev = { name = name, subs = {} }
    function ev:Subscribe(fn) table.insert(self.subs, fn) return fn end
    function ev:Fire(...)
        for _, fn in ipairs(self.subs) do
            local ok, err = pcall(fn, ...)
            if not ok then SIM.log("%s HANDLER-ERROR: %s", self.name, tostring(err)) end
        end
    end
    return ev
end
SIM.newEvent = newEvent

-- ---------------------------------------------------------------------------
-- World model
-- ---------------------------------------------------------------------------
ENT = {}   -- uuid -> entity
POS = {}   -- uuid -> {x,y,z}
STA = {}   -- uuid -> { [status] = true }
ITEMINFO = {} -- uuid -> { kind = "light"|"other", lit = false }
CHARS = {}

function SIM.addItem(uuid, tplName, x, y, z, opts)
    opts = opts or {}
    -- opts.engine: which mechanism actually switches the visible light on in this world
    --   "status" (ApplyStatus BURNING), "socket" (ConstellationTriggerInputSocket TurnOn),
    --   "use" (Osi.Use), "none" (nothing works)
    ENT[uuid] = {
        Uuid = { EntityUuid = uuid },
        Transform = { Transform = { Translate = { x, y, z } } },
        ServerItem = {
            CanBePickedUp = opts.canPickUp ~= false,
            CanUse = opts.canUse == true,
            IsContainer = opts.isContainer == true,
            CanOnlyBeUsedByOwner = false,
            Template = { Name = tplName },
            IsTrap = false,
        },
        GameplayLight = { Active = opts.gameplayLightActive == true },
        Constellation = opts.constellation and {} or nil,
    }
    POS[uuid] = { x, y, z }
    ITEMINFO[uuid] = {
        kind = opts.kind or "light",
        lit = false,
        tpl = tplName,
        engine = opts.engine or "status",
        ignoresBurningForLight = opts.ignoresBurningForLight == true,
        goodSocket = opts.goodSocket or "TurnOn",
        sittable = opts.sittable,          -- nil = ask engine default (true), false = no sit socket
    }
    if opts.preStatuses then
        STA[uuid] = STA[uuid] or {}
        for _, st in ipairs(opts.preStatuses) do STA[uuid][st] = true end
    end
end

function SIM.addObstacle(x, z, r, pad)
    SIM.obstacles[#SIM.obstacles + 1] = { x = x, z = z, r = r, pad = pad or 0.55 }
end

SIM.enemies = {}   -- cleanUuid -> true  (Osi.IsEnemy answers 1 for these)
SIM.speaking = {}  -- cleanUuid -> timestamp until which the character is in an overhead PAD dialog
SIM.padDuration = 2600
SIM.reposeDelay = 600   -- repose transition blend (char is not "seated" during it)
SIM.hp = {}        -- cleanUuid -> hit points percent
SIM.slots = {}     -- cleanUuid -> { level = n, max = m, used = u }

-- opts: { hp = 100, slotLevel = 3, slotsMax = 4, slotsUsed = 0, namedResources = bool }
function SIM.addChar(uuid, tplName, x, y, z, opts)
    opts = opts or {}
    local key = cleanguid(uuid)
    local hp = opts.hp or 100
    SIM.hp[key] = hp
    local level = opts.slotLevel or 3
    local maxSlots = opts.slotsMax or 4
    local used = opts.slotsUsed or 0
    SIM.slots[key] = { level = level, max = maxSlots, used = used }

    local resources = nil
    if maxSlots > 0 then
        -- Unnamed leveled entries (like the real BG3SE component): the mod has to pair
        -- them with the Osiris value by level + amount. namedResources=true exercises
        -- the name-based layer instead.
        local entry = { Amount = maxSlots - used, MaxAmount = maxSlots, Level = level }
        if opts.namedResources then entry.Name = "SpellSlot" end
        resources = {
            Resources = {
                ["cccccccc-0000-0000-0000-000000000001"] = entry,
                ["cccccccc-0000-0000-0000-000000000002"] = { Amount = 2, MaxAmount = 2, Level = 0 },
            },
        }
    end

    ENT[uuid] = {
        Uuid = { EntityUuid = uuid },
        Transform = { Transform = { Translate = { x, y, z } } },
        ServerCharacter = { Template = { Name = tplName } },
        PartyMember = (not SIM.enemies[key]) and { ViewUuid = "11111111-1111-1111-1111-111111111111" } or nil,
        BodyType = { BodyType = 0 },
        Health = { Hp = hp, MaxHp = 100 },
        ActionResources = resources,
    }
    POS[uuid] = { x, y, z }
    CHARS[#CHARS + 1] = uuid
end

function SIM.moveChar(uuid, x, y, z)
    local p = POS[uuid]
    if not p then return end
    p[1], p[2], p[3] = x, y, z
    local e = ENT[uuid]
    if e and e.Transform then
        e.Transform.Transform.Translate = { x, y, z }
    end
end

function SIM.setEnemy(uuid, flag)
    local k = cleanguid(uuid)
    SIM.enemies[k] = flag and true or nil
    -- a hostile is NOT a party member: the spatial index only indexes characters
    -- without a PartyMember component
    local e = ENT[k]
    if e then
        if flag then
            e.PartyMember = nil
        elseif e.PartyMember == nil then
            e.PartyMember = { ViewUuid = "11111111-1111-1111-1111-111111111111" }
        end
    end
end

function SIM.setHp(uuid, pct)
    local key = cleanguid(uuid)
    SIM.hp[key] = pct
    local e = ENT[key]
    if e and e.Health then e.Health.Hp = pct end
end

function SIM.setSlots(uuid, used)
    local key = cleanguid(uuid)
    local s = SIM.slots[key]
    if not s then return end
    s.used = used
    local e = ENT[key]
    local res = e and e.ActionResources and e.ActionResources.Resources
    if res then
        for _, entry in pairs(res) do
            if entry.Level and entry.Level > 0 then entry.Amount = entry.MaxAmount - used end
        end
    end
end

function SIM.hpOf(uuid)
    local key = cleanguid(uuid)
    return SIM.hp[key] or 100
end

local function markLit(uuid, how)
    uuid = cleanguid(uuid)
    local info = ITEMINFO[uuid]
    if info then info.lit = true end
    -- (visual state does not survive a save/load for fixtures that are not persistent)
    local e = ENT[uuid]
    if e and e.GameplayLight then e.GameplayLight.Active = true end
    STA[uuid] = STA[uuid] or {}
    STA[uuid]["BURNING"] = true
    SIM.log("WORLD: %s lit via %s", tostring(info and info.tpl or uuid), how)
end
SIM.markLit = markLit

-- ---------------------------------------------------------------------------
-- Ext
-- ---------------------------------------------------------------------------
local TickEvent = newEvent("Tick")
local GameStateChanged = newEvent("GameStateChanged")
local SessionLoaded = newEvent("SessionLoaded")
local ResetCompleted = newEvent("ResetCompleted")
SIM.TickEvent = TickEvent

Ext = {
    Utils = {
        Print = function(s)
            SIM.log("PRINT %s", tostring(s))
            -- SIM.printCostMs simulates a slow console/log write (a real BG3SE hazard):
            -- advancing SIM.time makes it show up as elapsed time inside the caller.
            if (SIM.printCostMs or 0) > 0 then
                SIM.time = SIM.time + SIM.printCostMs
            end
        end,
        MonotonicTime = function() return SIM.time end,
        GetGameState = function() return "Running" end,
    },
    Timer = {
        WaitFor = function(ms, fn) return SIM.addTimer(ms, fn) end,
        Cancel = function(id)
            for _, t in ipairs(SIM.timers) do if t.id == id then t.cancelled = true end end
        end,
    },
    Events = {
        Tick = TickEvent,
        GameStateChanged = GameStateChanged,
        SessionLoaded = SessionLoaded,
        ResetCompleted = ResetCompleted,
    },
    Entity = {
        Get = function(uuid)
            if type(uuid) ~= "string" then return uuid end
            return ENT[cleanguid(uuid)]
        end,
        GetAllEntitiesWithComponent = function(comp)
            local out = {}
            for u, e in pairs(ENT) do
                if e[comp] ~= nil then out[#out + 1] = u end
            end
            table.sort(out)
            return out
        end,
    },
    Osiris = {
        IsCallable = function() return true end,
        RegisterListener = function(name, argc, phase, fn)
            SIM.listeners = SIM.listeners or {}
            SIM.listeners[name] = SIM.listeners[name] or {}
            table.insert(SIM.listeners[name], fn)
        end,
    },
    Loca = { GetTranslatedString = function(h, f) return f end },
    Net = {
        CreateChannel = function()
            return { Post = function() end, Subscribe = function() end, Name = "chan" }
        end,
    },
    Resource = {
        GetAll = function(t)
            return (SIM.animBanks or {})[t] or {}
        end,
        Get = function(guid, t)
            local bank = (SIM.animBanks or {})[t]
            if not bank then return nil end
            for _, g in ipairs(bank) do
                if g == guid then return (SIM.animResourceData or {})[guid] end
            end
            return nil
        end,
    },
    Stats = { Get = function() return nil end },
    Template = { GetRootTemplate = function() return nil end },
    ModEvents = { BG3MCM = {} },
    RegisterConsoleCommand = function(name, fn)
        SIM.commands = SIM.commands or {}
        SIM.commands[name] = fn
    end,
}

function SIM.fire(name, ...)
    local l = SIM.listeners and SIM.listeners[name]
    if not l then return end
    for _, fn in ipairs(l) do
        local ok, err = pcall(fn, ...)
        if not ok then SIM.log("OSIRIS %s ERROR: %s", name, tostring(err)) end
    end
end

-- MCM mock (only used for Debug flag; everything else stays at code defaults)
MCM = {
    Get = function(id)
        if id == "AmbientAI_Debug" then return SIM.debugMCM == true end
        -- allow scenarios to override the idle tempo: pass "_G.SIM_IDLE_DELAY = 3" in the prelude
        if id == "AmbientAI_GroupedIdleDelay" and _G.SIM_IDLE_DELAY then
            return tonumber(_G.SIM_IDLE_DELAY)
        end
        return nil
    end,
}

ModuleUUID = "7d2e1b4a-9c8f-4a1d-b5e2-6f3a9c8b1d4e"
PersistentVars = {}

-- ---------------------------------------------------------------------------
-- Osi
-- ---------------------------------------------------------------------------
local function db()
    return { Get = function() return {} end }
end

Osi = setmetatable({
    GetHostCharacter = function() return SIM.host end,
    GetPosition = function(u)
        local p = POS[cleanguid(u)]
        if not p then return nil end
        return p[1], p[2], p[3]
    end,
    GetDistanceTo = function(a, b)
        local p, q = POS[cleanguid(a)], POS[cleanguid(b)]
        if not p or not q then return nil end
        local dx, dy, dz = p[1] - q[1], p[2] - q[2], p[3] - q[3]
        return math.sqrt(dx * dx + dy * dy + dz * dz)
    end,
    Exists = function(u) return ENT[cleanguid(u)] and 1 or 0 end,
    IsDead = function() return 0 end,
    IsInCombat = function() return 0 end,
    IsControlled = function() return 0 end,
    IsMoving = function(u)
        -- SIM.stuckMoving[key] = true models engines where IsMoving never reports 0
        -- (the 04.3.8 playtest log showed moving=false for AI walks; this is the mirror case)
        if SIM.stuckMoving and SIM.stuckMoving[cleanguid(u)] then return 1 end
        return SIM.moves[cleanguid(u)] and 1 or 0
    end,
    IsReposed = function(u) return SIM.seated[cleanguid(u)] and 1 or 0 end,
    IsReposedSitting = function(u) return SIM.seated[cleanguid(u)] and 1 or 0 end,
    IsReposedLying = function(u) return 0 end,
    IsReposedStanding = function(u) return (not SIM.seated[cleanguid(u)]) and 1 or 0 end,
    SitOnEntity = function(u, chair)
        local key = cleanguid(u)
        local ckey = cleanguid(chair)
        local info = ITEMINFO[ckey]
        local cp = POS[ckey]
        local cur = POS[key]
        local d = 0
        if cur and cp then
            d = math.sqrt((cur[1]-cp[1])^2 + (cur[2]-cp[2])^2 + (cur[3]-cp[3])^2)
        end
        SIM.lastStand = SIM.lastStand or {}
        SIM.lastStand[key] = cur and { cur[1], cur[2], cur[3] } or nil
        -- BG3 does not repose a character that is in a dialog / overhead PAD: silent refusal
        local talkUntil = SIM.speaking[key]
        if talkUntil and SIM.time < talkUntil then
            SIM.log("WORLD: %s SitOnEntity on %s REFUSED (character is in a dialog)", tostring(key),
                info and info.tpl or tostring(chair))
            return 0
        end
        if info and (info.sittable == false or info.sittable == "silent") then
            -- prop advertises CanUse but has no sit socket: Repose puts the character nowhere
            SIM.seated[key] = nil
            if cur then POS[key] = { cur[1], cur[2] - 3.0, cur[3] } end
            SIM.log("WORLD: %s SitOnEntity on %s FAILED -> character nowhere (void pose, still not reposed)",
                tostring(key), info.tpl)
            return 1
        end
        -- native Repose aligns the character to the furniture socket, whatever the distance.
        -- The pose is only reported as "seated" after the blend delay.
        SIM.moves[key] = nil
        SIM.log("WORLD: %s SNAPPED to socket of %s from %.2fm (pose blends over %dms)",
            tostring(key), info and info.tpl or chair, d, SIM.reposeDelay)
        SIM.addTimer(SIM.reposeDelay, function()
            SIM.seated[key] = ckey
            SIM.reposedAt[key] = SIM.time
            if cp then POS[key] = { cp[1], cp[2], cp[3] } end
        end)
        return 1
    end,
    EndRepose = function(u)
        local key = cleanguid(u)
        if not SIM.seated[key] then
            local back = SIM.lastStand and SIM.lastStand[key]
            if back and POS[key] and POS[key][2] < -1.0 then
                POS[key] = { back[1], back[2], back[3] }
                SIM.log("WORLD: %s pulled back onto the navmesh after the failed pose", tostring(key))
            end
            return 1
        end
        local chair = SIM.seated[key]
        SIM.log("WORLD: %s EndRepose -> stand-up clip starts (420ms)", tostring(key))
        SIM.addTimer(420, function()
            SIM.seated[key] = nil
            SIM.log("WORLD: %s is standing now", tostring(key))
            if SIM.fire then SIM.fire("ReposeRemoved", key, chair) end
        end)
        return 1
    end,
    TemplateCanSitOn = function(u)
        local info = ITEMINFO[cleanguid(u)]
        if info and info.sittable == false then return 0 end
        return 1
    end,
    IsTrapArmed = function() return 0 end,
    IsTrap = function() return 0 end,
    IsTrapDiscovered = function() return 0 end,
    IsStoryItem = function() return 0 end,
    IsDestroyed = function() return 0 end,
    IsLocked = function() return 0 end,
    IsMovable = function() return 1 end,
    CanPickUp = function() return 1 end,
    IsInInventory = function() return 0 end,
    IsInInventoryOf = function() return 0 end,
    IsEquipped = function() return 0 end,
    IsEquipable = function() return 0 end,
    IsConsumable = function() return 0 end,
    IsTorch = function() return 0 end,
    IsSummon = function() return 0 end,
    IsPartyFollower = function() return 0 end,
    IsPartyMember = function() return 1 end,
    IsEnemy = function(a, b)
        SIM.isEnemyCalls = (SIM.isEnemyCalls or 0) + 1
        local k = b and cleanguid(b) or nil
        if k and SIM.enemies[k] then
            SIM.isEnemyHits = (SIM.isEnemyHits or 0) + 1
            return 1
        end
        return 0
    end,
    IsTagged = function() return 0 end,
    IsInDialog = function() return 0 end,
    IsSpeakerReserved = function() return 0 end,
    IsInForceTurnBasedMode = function() return 0 end,
    IsWeaponUnsheathed = function() return 0 end,
    GetHitpoints = function() return 100 end,
    GetHitpointsPercentage = function(u) return SIM.hpOf(u) end,
    GetOwner = function() return "" end,
    GetInventoryOwner = function() return "" end,
    GetTemplate = function() return "" end,
    GetEquippedItem = function() return "" end,
    GetStackAmount = function() return 1 end,
    GetGold = function() return 0 end,
    ItemGetGoldValue = function() return 1 end,
    GetActionResourceValuePersonal = function(u, resource, level)
        local key = cleanguid(u)
        local s = SIM.slots[key]
        if not s then return 0 end
        local low = string.lower(tostring(resource or ""))
        if string.find(low, "spellslot", 1, true) and (tonumber(level) or -1) == s.level then
            return math.max(0, s.max - s.used)
        end
        return 1
    end,
    PartyGetActionResourceValue = function() return 1 end,
    GetObscuredState = function() return 0 end,
    GetObscuredStateAtPosition = function() return 0 end,
    HasLineOfSight = function() return 1 end,
    HasPassive = function(u, p) return (STA[cleanguid(u)] and STA[cleanguid(u)]["PASSIVE:" .. p]) and 1 or 1 end,
    HasActiveStatus = function(u, s)
        local st = STA[cleanguid(u)]
        return (st and st[s]) and 1 or 0
    end,
    HasAppliedStatusOfType = function() return 0 end,
    ApplyStatus = function(u, s, dur, amount, cause)
        local key = cleanguid(u)
        SIM.stats.applyStatus[s] = (SIM.stats.applyStatus[s] or 0) + 1
        SIM.log("OSI ApplyStatus(%s, %s)", tostring(ITEMINFO[key] and ITEMINFO[key].tpl or key), tostring(s))
        STA[key] = STA[key] or {}
        STA[key][s] = true
        if s == "BURNING" then
            local info = ITEMINFO[key]
            if info and info.kind == "light" and info.engine == "status" then
                markLit(key, "ApplyStatus BURNING")
            elseif info and info.kind == "light" then
                SIM.log("WORLD: %s got BURNING but stays dark (engine=%s)", info.tpl, info.engine)
            end
        end
        return 1
    end,
    RemoveStatus = function(u, s)
        local key = cleanguid(u)
        if STA[key] then STA[key][s] = nil end
        return 1
    end,
    ConstellationTriggerInputSocket = function(u, socket, src, guid)
        SIM.stats.socket = SIM.stats.socket + 1
        local key = cleanguid(u)
        SIM.log("OSI ConstellationTriggerInputSocket(%s, %s, %s)", tostring(ITEMINFO[key] and ITEMINFO[key].tpl or key), tostring(socket), tostring(src))
        local info = ITEMINFO[key]
        if info and info.kind == "light" and info.engine == "socket" and socket == info.goodSocket then
            markLit(key, "Constellation socket " .. tostring(socket))
        end
        return 1
    end,
    Use = function(ch, u, s)
        SIM.stats.use = SIM.stats.use + 1
        local key = cleanguid(u)
        SIM.log("OSI Use(%s, %s)", tostring(ch), tostring(ITEMINFO[key] and ITEMINFO[key].tpl or key))
        local info = ITEMINFO[key]
        if info and info.kind == "light" and info.engine == "use" then markLit(key, "Osi.Use") end
        return 1
    end,
    UseSpell = function() return 1 end,
    CharacterMoveToPosition = function(u, x, y, z, speed, event)
        local key = cleanguid(u)
        -- engine-side fallback: a blocked destination is clamped to the nearest free spot
        for _, o in ipairs(SIM.obstacles) do
            local dx, dz = x - o.x, z - o.z
            local d = math.sqrt(dx * dx + dz * dz)
            local minD = o.r + o.pad
            if d > 0.001 and d < minD then
                x = o.x + (dx / d) * minD
                z = o.z + (dz / d) * minD
                SIM.log("ENGINE: destination clamped to %.2f,%.2f (obstacle %.1fm)", x, z, minD)
            end
        end
        SIM.moves[key] = { tx = x, ty = y, tz = z }
        SIM.log("MOVE %s -> %.2f,%.2f,%.2f", tostring(key), x, y, z)
        return 1
    end,
    CharacterMoveTo = function() return 1 end,
    FindValidPosition = function(x, y, z, radius, obj, avoid)
        for _, o in ipairs(SIM.obstacles) do
            local dx, dz = x - o.x, z - o.z
            if (dx * dx + dz * dz) < (o.r * o.r) then
                return nil   -- AI grid rejects the point (props / unwalkable surface)
            end
        end
        return x, y, z
    end,
    SteerTo = function() return 1 end,
    LookAtEntity = function() return 1 end,
    PlayAnimation = function(c, anim)
        SIM.playedAnims = SIM.playedAnims or {}
        table.insert(SIM.playedAnims, { char = c, anim = anim })
        return 1
    end,
    PlayLoopingAnimation = function(c, start, loop, stop)
        SIM.loopingAnim = { char = c, start = start, loop = loop, stop = stop }
        SIM.loopingAnims = SIM.loopingAnims or {}
        table.insert(SIM.loopingAnims, { char = c, start = start, loop = loop, stop = stop })
        return 1
    end,
    StopAnimation = function() return 1 end,
    PlaySound = function() return 1 end,
    PlaySoundResource = function() return 1 end,
    PlayEffect = function() return 1 end,
    SetNoFollowFlag = function(u, flag)
        local key = cleanguid(u)
        local want = (flag == 1) or (flag == true)
        if SIM.nofollow[key] ~= want then
            SIM.nofollow[key] = want
            SIM.log("WORLD: %s follow block = %s", tostring(key), tostring(want))
        end
        return 1
    end,
    SetCanGossip = function() return 1 end,
    SetWeaponUnsheathed = function() return 1 end,
    Equip = function() return 1 end,
    Unequip = function() return 1 end,
    ToInventory = function() return 1 end,
    SendToCampChest = function() return 1 end,
    AddGold = function() return 1 end,
    AddExperience = function() return 1 end,
    AddExplorationExperience = function() return 1 end,
    AddPassive = function(u, p)
        STA[cleanguid(u)] = STA[cleanguid(u)] or {}
        STA[cleanguid(u)]["PASSIVE:" .. p] = true
        return 1
    end,
    TogglePassive = function(u, p)
        STA[cleanguid(u)] = STA[cleanguid(u)] or {}
        STA[cleanguid(u)]["PASSIVE:" .. p] = true
        return 1
    end,
    ShowOverheadText = function() return 1 end,
    CharacterStatusText = function() return 1 end,
    PurgeOsirisQueue = function() return 1 end,
    FlushOsirisQueue = function() return 1 end,
    CanSitOn = function(u)
        local info = ITEMINFO[cleanguid(u)]
        if info and info.sittable == false then return 0 end
        return 1
    end,
    RemoveSplatters = function() return 1 end,
    SetHitpointsPercentage = function() return 1 end,
    GenerateTreasure = function() return 1 end,
    GenerateItems = function() return 1 end,
    -- SIM.padsWork = true makes overhead PAD dialogs actually start (they are otherwise
    -- invisible to the harness), so the rest-reminder gating can be measured.
    QRY_StartDialog_Fixed = function(resource, char)
        if not SIM.padsWork then return 0 end
        SIM.pads = SIM.pads or {}
        table.insert(SIM.pads, { t = SIM.time, res = tostring(resource), char = cleanguid(char) })
        SIM.speaking[cleanguid(char)] = SIM.time + SIM.padDuration
        SIM.log("PAD %s on %s", tostring(resource), tostring(cleanguid(char)))
        return 1
    end,
    QRY_StartDialogCustom_Fixed = function(resource, char)
        if not SIM.padsWork then return 0 end
        SIM.pads = SIM.pads or {}
        table.insert(SIM.pads, { t = SIM.time, res = tostring(resource), char = cleanguid(char) })
        SIM.log("PAD %s on %s", tostring(resource), tostring(cleanguid(char)))
        return 1
    end,
    StartDialog_Internal = function() return 0 end,
    SpeakerGetDialog = function(u)
        local key = cleanguid(u)
        local untilT = SIM.speaking[key]
        if untilT and SIM.time < untilT then return "PAD_Active" end
        if untilT then SIM.speaking[key] = nil end
        return ""
    end,
    -- SIM.dialog = { instance = "...", players = 1, broken = false }
    --   broken = true models an instance the engine can no longer resolve (pcall fails)
    DialogGetNumberOfInvolvedPlayers = function(inst)
        if SIM.dialog and inst == SIM.dialog.instance then
            if SIM.dialog.broken then error("dialog instance not resolvable") end
            return SIM.dialog.players
        end
        return 0
    end,
    DialogGetNumberOfInvolvedNPCs = function() return 0 end,
    DialogGetInvolvedPlayer = function() return "" end,
    DialogRequestStop = function() return 1 end,
    DialogRequestStopForDialog = function() return 1 end,
    PROC_StartWorldGossip = function() return 0 end,
    DB_Camp = db(), DB_CampBed = db(), DB_InCamp = db(), DB_PartyMembers = db(),
    DB_Players = db(), DB_DialogPlayers = db(), DB_AutomatedDialog = db(),
    DB_BlockWorldGossip = db(), DB_Camp_UserCampChest = db(), DB_Is_WildShaped = db(),
    DB_InDangerZone = db(), DB_SHA_EntrancePuzzle_LightDetectors = db(),
    DB_SCL_ShadowCurse_TrackLight = db(),
}, {
    __index = function(_, k)
        -- Any Osi call we did not model: log once and behave like a no-op that returns nil
        SIM.unmocked = SIM.unmocked or {}
        if not SIM.unmocked[k] then
            SIM.unmocked[k] = 0
        end
        SIM.unmocked[k] = SIM.unmocked[k] + 1
        return function() return nil end
    end
})

-- DB_PartyMembers / DB_InCamp real implementations
Osi.DB_PartyMembers = { Get = function(_, a)
    local rows = {}
    for _, c in ipairs(CHARS) do
        if not SIM.enemies[cleanguid(c)] then rows[#rows + 1] = { c } end
    end
    return rows
end }
Osi.DB_Players = { Get = function(_, a)
    if SIM.host then return { { SIM.host } } end
    return {}
end }
Osi.DB_InCamp = { Get = function() return {} end }

-- ---------------------------------------------------------------------------
-- Driver
-- ---------------------------------------------------------------------------
function SIM.run(durationMs, stepMs)
    stepMs = stepMs or 16
    local target = SIM.time + durationMs
    while SIM.time < target do
        SIM.time = SIM.time + stepMs

        local processed = 0
        while processed < 2000 do
            local best, bi = nil, nil
            for i, t in ipairs(SIM.timers) do
                if not t.cancelled and t.at <= SIM.time then
                    if not best or t.at < best.at then best, bi = t, i end
                end
            end
            if not best then break end
            table.remove(SIM.timers, bi)
            local ok, err = pcall(best.fn)
            if not ok then SIM.log("TIMER-ERROR: %s", tostring(err)) end
            processed = processed + 1
        end

        -- BG3 party-follow model: a following party member that is still welded to a
        -- chair/bed socket is resolved with a catch-up teleport to the leader.
        if SIM.followModel and SIM.host then
            local hp = POS[SIM.host]
            local hostMoving = SIM.moves[SIM.host] ~= nil
            for _, c in ipairs(CHARS) do
                if c ~= SIM.host and not SIM.nofollow[c] and not SIM.enemies[cleanguid(c)] then
                    local cp = POS[c]
                    if hp and cp then
                        local dx, dz = cp[1] - hp[1], cp[3] - hp[3]
                        local d = math.sqrt(dx * dx + dz * dz)
                        if SIM.seated[c] and (hostMoving or d > 4.0) then
                            local bx, bz = hp[1] - 1.1, hp[3] - 1.1
                            POS[c] = { bx, hp[2], bz }
                            SIM.moves[c] = nil
                            SIM.teleports[#SIM.teleports + 1] = { char = c, at = SIM.time }
                            SIM.log("ENGINE: TELEPORT %s behind the player (still reposed on furniture!)", tostring(c))
                        elseif (not SIM.seated[c]) and d > 3.2 and (hostMoving or d > 6.0) then
                            local nx, nz = dx / d, dz / d
                            SIM.moves[c] = { tx = hp[1] + nx * 2.0, ty = hp[2], tz = hp[3] + nz * 2.0 }
                        end
                    end
                end
            end
        end

        -- advance interpolated movement
        local dt = stepMs / 1000.0
        for key, mv in pairs(SIM.moves) do
            local p = POS[key]
            if p then
                local dx, dy, dz = mv.tx - p[1], mv.ty - p[2], mv.tz - p[3]
                local d = math.sqrt(dx * dx + dy * dy + dz * dz)
                local step = SIM.walkSpeed * dt
                if d <= step then
                    POS[key] = { mv.tx, mv.ty, mv.tz }
                    SIM.moves[key] = nil
                else
                    POS[key] = { p[1] + dx / d * step, p[2] + dy / d * step, p[3] + dz / d * step }
                end
            else
                SIM.moves[key] = nil
            end
        end

        TickEvent:Fire({})
    end
end

function SIM.report(title)
    print(("=== %s (t=%.1fs) ==="):format(title, SIM.time / 1000))
    for _, l in ipairs(SIM.prints) do print(l) end
    SIM.prints = {}
    local ap = {}
    for k, v in pairs(SIM.stats.applyStatus) do ap[#ap + 1] = k .. "=" .. v end
    print("ApplyStatus: " .. table.concat(ap, ", ") ..
        " | sockets=" .. SIM.stats.socket .. " | Osi.Use=" .. SIM.stats.use)
    print("=== end ===")
end
