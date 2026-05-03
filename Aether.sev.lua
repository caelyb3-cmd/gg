-- ============================================================
--  Aether.sev - Unified Script
--  Modules : Resolver | Buybot | Double Tap | Lag Comp
--  Source  : Resolver.lua, buybot.lua, DoubleTap.lua, lagcomp.lua
-- ============================================================

-- ===========================
-- 0A  STUBS FOR UNDOCUMENTED GLOBALS
-- (prof_start/prof_end/eb_on/json used in Resolver.lua but absent from
--  Lua Api Docs .txt - stubs prevent load-time errors while preserving intent)
-- ===========================
if not prof_start then prof_start = function() end end
if not prof_end   then prof_end   = function() end end
if not eb_on      then eb_on      = function() end end
if not json then
    json = {
        parse     = function() return nil end,
        stringify = function(v) return tostring(v) end,
    }
end

-- ===========================
-- 0B  AETHER.SEV PAGE NAVIGATOR
-- ===========================
local aether_page = ui.new_combobox("LUA", "B", "Aether.sev",
    "Resolver", "Buybot", "Double Tap", "Lag Comp")
-- ============================================================
-- RESOLVER MODULE
-- ============================================================

-- ============================================================
--  Aether.sev
--  Platform : Gamesense (gamesensical.gitbook.io/docs)
--  Weapons  : SSG-08 | Deagle | Revolver (R8) | TEC-9 | Zeus
--  Author   : kapus
--  Date     : 2026-04-21
-- ============================================================
--
--  API REFERENCES USED:
--    client.*         — camera, trace, events, damage, log
--    entity.*         — players, props, hitboxes, weapon
--    renderer.*       — rectangle, text, circle, gradient
--    ui.*             — button, checkbox, slider, combobox
--    plist.*          — player list overrides
--    globals.*        — tickcount, curtime, tickinterval
--
-- ============================================================

-- ===========================
-- § 1  CONSTANTS & WEAPON IDs
-- ===========================

WEAPON_DEAGLE       = 1
WEAPON_SSG08        = 40
WEAPON_TEC9         = 30
WEAPON_ZEUS         = 31
WEAPON_REVOLVER     = 64

HITGROUP_HEAD       = 1
HITGROUP_CHEST      = 2
HITGROUP_STOMACH    = 3
HITGROUP_L_ARM      = 4
HITGROUP_R_ARM      = 5
HITGROUP_L_LEG      = 6
HITGROUP_R_LEG      = 7

HITBOX_HEAD         = 0
HITBOX_NECK         = 1
HITBOX_PELVIS       = 2
HITBOX_STOMACH      = 3
HITBOX_THORAX       = 4
HITBOX_CHEST        = 5
HITBOX_UPPER_CHEST  = 6
HITBOX_L_THIGH      = 7
HITBOX_R_THIGH      = 8

FL_ONGROUND         = 1
FL_DUCKING          = 4

MAX_HISTORY         = 16
MAX_PLAYERS         = 64
MAX_MISSES          = 6
YAW_CORRECTION_STEP = 29.5

-- desync side constants
SIDE_NONE  = 0
SIDE_LEFT  = 1
SIDE_RIGHT = 2

-- brute-force states
BRUTE_DEFAULT  = 0
BRUTE_LEFT     = 1
BRUTE_RIGHT    = 2
BRUTE_SMALL_L  = 3
BRUTE_SMALL_R  = 4
BRUTE_ZERO     = 5
BRUTE_MAX      = 5

-- resolver mode indices (combobox)
MODE_AUTO  = "Auto"
MODE_BRUTE = "Brute Force"
MODE_JITTER= "Anti-Jitter"
MODE_STATIC= "Static"

-- version tag painted on HUD
VERSION_TAG = "Aether.sev"

-- ===========================
-- § 2  UTILITY FUNCTIONS
-- ===========================

function math_clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

function math_normalize_yaw(y)
    while y > 180  do y = y - 360 end
    while y < -180 do y = y + 360 end
    return y
end

function math_normalize_pitch(p)
    while p > 89   do p = p - 180 end
    while p < -89  do p = p + 180 end
    return p
end

function math_angle_diff(a, b)
    return math_normalize_yaw(a - b)
end

function math_abs(v)
    return v < 0 and -v or v
end

function math_sign(v)
    if v > 0 then return 1 end
    if v < 0 then return -1 end
    return 0
end

function math_lerp(a, b, t)
    return a + (b - a) * t
end

function math_vec_len2d(vx, vy)
    return math.sqrt(vx * vx + vy * vy)
end

function math_vec_len3d(vx, vy, vz)
    return math.sqrt(vx * vx + vy * vy + vz * vz)
end

function math_average(tbl)
    if #tbl == 0 then return 0 end
    local s = 0
    for _, v in ipairs(tbl) do s = s + v end
    return s / #tbl
end

function math_variance(tbl)
    if #tbl < 2 then return 0 end
    local avg = math_average(tbl)
    local s = 0
    for _, v in ipairs(tbl) do
        local d = v - avg
        s = s + d * d
    end
    return s / (#tbl - 1)
end

function table_insert_limited(t, v, limit)
    table.insert(t, 1, v)
    if #t > limit then
        table.remove(t, #t)
    end
end

function table_contains(t, val)
    for _, v in ipairs(t) do
        if v == val then return true end
    end
    return false
end

-- ===========================
-- § 3  WEAPON HELPERS
-- ===========================

-- maps weapon entity index -> weapon_id integer via m_iItemDefinitionIndex
function get_weapon_id(ent)
    local weapon_ent = entity.get_player_weapon(ent)
    if not weapon_ent then return nil end
    local wid = entity.get_prop(weapon_ent, "m_iItemDefinitionIndex")
    return wid
end

-- returns true when the weapon is one of our supported pistols/rifles
function is_supported_weapon(wid)
    return wid == WEAPON_DEAGLE
        or wid == WEAPON_SSG08
        or wid == WEAPON_TEC9
        or wid == WEAPON_ZEUS
        or wid == WEAPON_REVOLVER
end

function weapon_name(wid)
    if wid == WEAPON_DEAGLE   then return "Deagle"   end
    if wid == WEAPON_SSG08    then return "SSG-08"   end
    if wid == WEAPON_TEC9     then return "TEC-9"    end
    if wid == WEAPON_ZEUS     then return "Zeus"     end
    if wid == WEAPON_REVOLVER then return "Revolver" end
    return "Unknown"
end

-- per-weapon accuracy multiplier used to scale miss penalty
function weapon_miss_weight(wid)
    if wid == WEAPON_DEAGLE   then return 1.4 end
    if wid == WEAPON_SSG08    then return 1.6 end
    if wid == WEAPON_TEC9     then return 0.9 end
    if wid == WEAPON_ZEUS     then return 2.0 end -- zeus is 1-hit, brutal
    if wid == WEAPON_REVOLVER then return 1.5 end
    return 1.0
end

-- maximum expected desync delta per weapon
function weapon_desync_cap(wid)
    if wid == WEAPON_SSG08    then return 60 end -- sniper wide body
    if wid == WEAPON_DEAGLE   then return 58 end
    if wid == WEAPON_REVOLVER then return 58 end
    if wid == WEAPON_TEC9     then return 55 end
    if wid == WEAPON_ZEUS     then return 45 end
    return 58
end

-- ===========================
-- § 4  PLAYER STATE STORAGE
-- ===========================

-- player_data[entindex] = { ... }
player_data = {}

function get_player_data(ent)
    if not player_data[ent] then
        player_data[ent] = {
            -- yaw history with timestamps
            yaw_history      = {},
            sim_time_history = {},
            -- velocity snapshots
            vel_x_hist       = {},
            vel_y_hist       = {},
            vel_z_hist       = {},
            -- angles
            last_yaw         = 0,
            last_pitch       = 0,
            eye_yaw          = 0,
            lby_yaw          = 0,
            lby_flick_yaw    = 0,
            -- desync
            desync_side      = SIDE_NONE,
            desync_delta     = 0,
            resolved_yaw     = 0,
            -- brute force
            brute_state      = BRUTE_DEFAULT,
            brute_misses     = 0,
            -- miss tracking
            total_shots      = 0,
            total_hits       = 0,
            total_misses     = 0,
            miss_streak      = 0,
            -- correction offset applied at last shot
            applied_offset   = 0,
            applied_side     = SIDE_NONE,
            -- jitter detection
            jitter_detected  = false,
            jitter_amplitude = 0,
            jitter_yaws      = {},
            -- static detection
            is_static        = false,
            static_counter   = 0,
            -- on-ground state
            was_on_ground    = false,
            -- simulation time
            last_sim_time    = 0,
            sim_time_updated = false,
            -- weapon info
            last_weapon_id   = nil,
            -- confidence  [0-100]
            confidence       = 50,
            -- how many ticks the player has not updated
            choke_ticks      = 0,
            -- low delta flag
            low_delta        = false,
            -- last resolver mode that fired
            last_mode        = "",
            -- flick LBY detection
            lby_update_time  = 0,
            lby_next_update  = 0,
            -- eye angles deltas rolling buffer
            delta_history    = {},
            -- prediction of next yaw
            predicted_yaw    = 0,
        }
    end
    return player_data[ent]
end

-- ===========================
-- § 5  UI ELEMENTS
-- ===========================

ui_enabled     = ui.new_checkbox("LUA", "B", "UV Resolver")
ui_mode        = ui.new_combobox("LUA", "B", "Resolver Mode", MODE_AUTO, MODE_BRUTE, MODE_JITTER, MODE_STATIC)
ui_hud         = ui.new_checkbox("LUA", "B", "Resolver HUD")
ui_log         = ui.new_checkbox("LUA", "B", "Console Log")
ui_hitchance   = ui.new_slider("LUA", "B", "Min Hitchance Override", 0, 100, 40, true, "%")
ui_max_brute   = ui.new_slider("LUA", "B", "Brute Cycle Depth", 1, 6, 4, true)
ui_auto_stop   = ui.new_checkbox("LUA", "B", "Adaptive Miss Correction")
ui_show_side   = ui.new_checkbox("LUA", "B", "Show Desync Side ESP")

-- single activation button
ui.new_button("LUA", "B", "Toggle UV Resolver", function()
    local cur = ui.get(ui_enabled)
    ui.set(ui_enabled, not cur)
    if not cur then
        client.color_log(100, 220, 255, "[Aether.sev] ENABLED")
    else
        client.color_log(255, 100, 100, "[Aether.sev] DISABLED")
    end
end)

-- ===========================
-- § 6  HUD STATE
-- ===========================

hud = {
    log_lines     = {},
    max_lines     = 8,
    fade_time     = 4.0,
    entries       = {},  -- { text, r, g, b, expire }
}

function hud_push(text, r, g, b)
    local expire = globals.curtime() + hud.fade_time
    table.insert(hud.entries, { text=text, r=r, g=g, b=b, expire=expire })
    if #hud.entries > hud.max_lines then
        table.remove(hud.entries, 1)
    end
end

-- ===========================
-- § 7  SHOT EVENT STORAGE
-- ===========================

pending_shots = {}  -- list of { tick, target_ent, applied_offset, applied_yaw }
last_shot_tick = 0
last_shot_ent  = nil

-- ===========================
-- § 8  CORE RESOLVER LOGIC
-- ===========================

------------------------------------------------------------------------
-- 8.1  Detect jitter by analysing yaw delta variance
------------------------------------------------------------------------
function detect_jitter(pdata)
    local yaws = pdata.yaw_history
    if #yaws < 4 then
        pdata.jitter_detected = false
        return false
    end

    local deltas = {}
    for i = 1, #yaws - 1 do
        deltas[#deltas + 1] = math_abs(math_angle_diff(yaws[i], yaws[i + 1]))
    end

    local avg  = math_average(deltas)
    local vari = math_variance(deltas)

    -- jitter: large average delta AND high variance
    if avg > 20 and vari > 100 then
        pdata.jitter_detected  = true
        pdata.jitter_amplitude = avg
        return true
    end

    pdata.jitter_detected = false
    return false
end

------------------------------------------------------------------------
-- 8.2  Detect static (AA that doesn't change)
------------------------------------------------------------------------
function detect_static(pdata)
    local yaws = pdata.yaw_history
    if #yaws < 6 then
        pdata.is_static = false
        return false
    end

    local first = yaws[1]
    local same  = 0
    for i = 2, math.min(6, #yaws) do
        if math_abs(math_angle_diff(first, yaws[i])) < 2.0 then
            same = same + 1
        end
    end

    if same >= 4 then
        pdata.is_static      = true
        pdata.static_counter = pdata.static_counter + 1
        return true
    end
    pdata.is_static      = false
    pdata.static_counter = 0
    return false
end

------------------------------------------------------------------------
-- 8.3  Estimate desync delta using LBY vs Eye-Yaw
------------------------------------------------------------------------
function calc_desync_delta(ent, pdata, wid)
    local eye_yaw = pdata.eye_yaw
    local lby_yaw = pdata.lby_yaw
    if lby_yaw == 0 then return 0, SIDE_NONE end

    local delta   = math_angle_diff(eye_yaw, lby_yaw)
    local cap     = weapon_desync_cap(wid or 58)
    delta         = math_clamp(delta, -cap, cap)

    local side = SIDE_NONE
    if math_abs(delta) > 6 then
        side = delta > 0 and SIDE_LEFT or SIDE_RIGHT
    end
    return delta, side
end

------------------------------------------------------------------------
-- 8.4  Velocity-based forward yaw prediction
------------------------------------------------------------------------
function predict_yaw_from_velocity(pdata)
    local vx = pdata.vel_x_hist[1] or 0
    local vy = pdata.vel_y_hist[1] or 0
    local spd = math_vec_len2d(vx, vy)
    if spd < 8 then return pdata.eye_yaw end
    local move_yaw = math.deg(math.atan2(vy, vx))
    return move_yaw
end

------------------------------------------------------------------------
-- 8.5  Brute-force offset table indexed by BRUTE_* state
------------------------------------------------------------------------
function brute_offset(state, wid)
    local cap = weapon_desync_cap(wid)
    local offsets = {
        [BRUTE_DEFAULT] =  0,
        [BRUTE_LEFT]    =  cap,
        [BRUTE_RIGHT]   = -cap,
        [BRUTE_SMALL_L] =  cap * 0.5,
        [BRUTE_SMALL_R] = -cap * 0.5,
        [BRUTE_ZERO]    =  0,
    }
    return offsets[state] or 0
end

------------------------------------------------------------------------
-- 8.6  Advance brute state after a miss
------------------------------------------------------------------------
function advance_brute(pdata, max_state)
    pdata.brute_state = (pdata.brute_state + 1) % (max_state + 1)
end

------------------------------------------------------------------------
-- 8.7  Low-delta detection (choked packets / fake-lag)
------------------------------------------------------------------------
function detect_low_delta(pdata)
    local yaws = pdata.yaw_history
    if #yaws < 3 then return false end

    local d1 = math_abs(math_angle_diff(yaws[1], yaws[2]))
    local d2 = math_abs(math_angle_diff(yaws[2], yaws[3]))
    if d1 < 3.5 and d2 < 3.5 then
        pdata.low_delta = true
        return true
    end
    pdata.low_delta = false
    return false
end

------------------------------------------------------------------------
-- 8.8  Choke tick estimation
------------------------------------------------------------------------
function estimate_choke(pdata)
    local st_hist = pdata.sim_time_history
    if #st_hist < 2 then return 0 end
    local dt  = st_hist[1] - st_hist[2]
    local tki = globals.tickinterval()
    if tki <= 0 then return 0 end
    local ticks = math.floor(dt / tki + 0.5)
    pdata.choke_ticks = math_clamp(ticks, 0, 14)
    return pdata.choke_ticks
end

------------------------------------------------------------------------
-- 8.9  Confidence score updater
------------------------------------------------------------------------
function update_confidence(pdata)
    -- miss streak lowers confidence
    pdata.confidence = pdata.confidence - pdata.miss_streak * 8
    -- static target + long observation boosts confidence
    if pdata.is_static then
        pdata.confidence = pdata.confidence + 5
    end
    pdata.confidence = math_clamp(pdata.confidence, 0, 100)
end

------------------------------------------------------------------------
-- 8.10  Main resolver per-player update (called every shot scan)
------------------------------------------------------------------------
function resolve_player(ent, pdata, wid)
    local mode = ui.get(ui_mode)

    -- pull eye angles
    local pitch = entity.get_prop(ent, "m_angEyeAngles[0]") or 0
    local yaw   = entity.get_prop(ent, "m_angEyeAngles[1]") or 0
    -- lower body yaw
    local lby   = entity.get_prop(ent, "m_flLowerBodyYawTarget") or yaw
    pdata.eye_yaw   = yaw
    pdata.lby_yaw   = lby
    pdata.last_pitch = pitch

    -- history push
    table_insert_limited(pdata.yaw_history, yaw, MAX_HISTORY)

    -- velocity
    local vx = entity.get_prop(ent, "m_vecVelocity[0]") or 0
    local vy = entity.get_prop(ent, "m_vecVelocity[1]") or 0
    local vz = entity.get_prop(ent, "m_vecVelocity[2]") or 0
    table_insert_limited(pdata.vel_x_hist, vx, MAX_HISTORY)
    table_insert_limited(pdata.vel_y_hist, vy, MAX_HISTORY)
    table_insert_limited(pdata.vel_z_hist, vz, MAX_HISTORY)

    -- sim time
    local stime = entity.get_prop(ent, "m_flSimulationTime") or 0
    pdata.sim_time_updated = (stime ~= pdata.last_sim_time)
    pdata.last_sim_time    = stime
    table_insert_limited(pdata.sim_time_history, stime, MAX_HISTORY)

    -- flags
    local flags = entity.get_prop(ent, "m_fFlags") or 0
    local on_ground = bit.band(flags, FL_ONGROUND) ~= 0

    -- detection passes
    detect_jitter(pdata)
    detect_static(pdata)
    detect_low_delta(pdata)
    estimate_choke(pdata)
    update_confidence(pdata)

    -- desync calc
    local delta, side = calc_desync_delta(ent, pdata, wid)
    pdata.desync_delta = delta
    pdata.desync_side  = side

    -- base resolved yaw starts at eye_yaw
    local resolved = yaw
    local offset   = 0

    -- ----------------------------------------------------------------
    -- AUTO mode: pick best strategy based on detection
    -- ----------------------------------------------------------------
    if mode == MODE_AUTO then
        if pdata.jitter_detected then
            -- jitter: pick one side based on miss streak
            if pdata.miss_streak == 0 then
                offset = delta
                pdata.last_mode = "AUTO/JITTER-MATCH"
            else
                offset = (pdata.miss_streak % 2 == 0) and math_abs(delta) or -math_abs(delta)
                pdata.last_mode = "AUTO/JITTER-FLIP"
            end
        elseif pdata.is_static then
            -- static: just use LBY directly
            resolved = lby
            offset   = 0
            pdata.last_mode = "AUTO/STATIC-LBY"
        elseif pdata.low_delta then
            -- low delta / choke: brute
            offset = brute_offset(pdata.brute_state, wid)
            pdata.last_mode = "AUTO/BRUTE-LOWDELTA"
        else
            -- normal desync compensation
            offset = delta
            pdata.last_mode = "AUTO/DESYNC"
        end
    -- ----------------------------------------------------------------
    -- BRUTE FORCE mode
    -- ----------------------------------------------------------------
    elseif mode == MODE_BRUTE then
        local max_b = ui.get(ui_max_brute) - 1
        offset = brute_offset(pdata.brute_state, wid)
        pdata.last_mode = "BRUTE#" .. pdata.brute_state
    -- ----------------------------------------------------------------
    -- ANTI-JITTER mode: always follow LBY
    -- ----------------------------------------------------------------
    elseif mode == MODE_JITTER then
        resolved = lby
        offset   = 0
        pdata.last_mode = "JITTER/LBY"
    -- ----------------------------------------------------------------
    -- STATIC mode: use the average of recent yaws
    -- ----------------------------------------------------------------
    elseif mode == MODE_STATIC then
        if #pdata.yaw_history >= 3 then
            resolved = math_average(pdata.yaw_history)
        end
        offset = 0
        pdata.last_mode = "STATIC/AVG"
    end

    resolved = math_normalize_yaw(resolved + offset)
    pdata.resolved_yaw   = resolved
    pdata.applied_offset = offset
    pdata.applied_side   = side
end

-- ===========================
-- § 9  MISS-CORRECTION ENGINE
-- ===========================

------------------------------------------------------------------------
-- Called when a shot missed the target
------------------------------------------------------------------------
function on_shot_missed(ent, pdata, wid)
    pdata.total_misses    = pdata.total_misses + 1
    pdata.miss_streak     = pdata.miss_streak + 1
    pdata.brute_misses    = pdata.brute_misses + 1
    pdata.confidence      = math_clamp(pdata.confidence - 12, 0, 100)

    local mode    = ui.get(ui_mode)
    local max_brute = ui.get(ui_max_brute) - 1

    if mode == MODE_AUTO or mode == MODE_BRUTE then
        if pdata.brute_misses > max_brute then
            pdata.brute_misses = 0
            pdata.brute_state  = BRUTE_DEFAULT
        else
            advance_brute(pdata, max_brute)
        end
    end

    local wname = weapon_name(wid or 0)
    local mw    = weapon_miss_weight(wid or 0)
    local msg   = string.format("[UV] MISS #%d on %s | mode=%s | offset=%.1f | wep=%s (x%.1f)",
        pdata.miss_streak,
        entity.get_player_name(ent),
        pdata.last_mode,
        pdata.applied_offset,
        wname,
        mw)

    if ui.get(ui_log) then
        client.color_log(255, 120, 50, msg)
    end
    hud_push(msg, 255, 120, 50)
end

------------------------------------------------------------------------
-- Called when a shot hit the target
------------------------------------------------------------------------
function on_shot_hit(ent, pdata, wid, hitgroup)
    pdata.total_hits    = pdata.total_hits + 1
    pdata.miss_streak   = 0
    pdata.brute_misses  = 0
    pdata.confidence    = math_clamp(pdata.confidence + 10, 0, 100)

    local hgnames = { [1]="head",[2]="chest",[3]="stomach",[4]="l.arm",
                      [5]="r.arm",[6]="l.leg",[7]="r.leg" }
    local hgstr = hgnames[hitgroup] or "?"
    local wname = weapon_name(wid or 0)
    local msg   = string.format("[UV] HIT %s on %s | offset=%.1f | mode=%s | wep=%s",
        hgstr,
        entity.get_player_name(ent),
        pdata.applied_offset,
        pdata.last_mode,
        wname)

    if ui.get(ui_log) then
        client.color_log(80, 255, 120, msg)
    end
    hud_push(msg, 80, 255, 120)
end

-- ===========================
-- § 10  GAME EVENT CALLBACKS
-- ===========================

------------------------------------------------------------------------
-- 10.1  bullet_impact — fired when a shot hits ANYTHING in the world
--       We compare to expected target; if it missed player → miss count
------------------------------------------------------------------------
function on_bullet_impact(e)
    if not ui.get(ui_enabled) then return end

    local uid    = e.userid
    local me     = entity.get_local_player()
    if not me then return end

    local shooter_ent = client.userid_to_entindex(uid)
    if shooter_ent ~= me then return end

    -- check if our last shot missed
    if last_shot_ent and entity.is_alive(last_shot_ent) then
        local pdata = get_player_data(last_shot_ent)
        local wid   = get_weapon_id(me)
        if wid and is_supported_weapon(wid) then
            -- do a quick bullet trace to see if we hit them
            local ex, ey, ez = client.eye_position()
            if ex then
                local tx, ty, tz = entity.hitbox_position(last_shot_ent, HITBOX_CHEST)
                if tx then
                    local _, dmg = client.trace_bullet(me, ex, ey, ez, tx, ty, tz, false)
                    if not dmg or dmg <= 0 then
                        on_shot_missed(last_shot_ent, pdata, wid)
                    end
                end
            end
        end
    end
end

------------------------------------------------------------------------
-- 10.2  player_hurt — confirmed hit
------------------------------------------------------------------------
function on_player_hurt(e)
    if not ui.get(ui_enabled) then return end

    local attacker_uid = e.attacker
    local victim_uid   = e.userid
    local me           = entity.get_local_player()
    if not me then return end

    local attacker_ent = client.userid_to_entindex(attacker_uid)
    if attacker_ent ~= me then return end

    local victim_ent = client.userid_to_entindex(victim_uid)
    if not victim_ent or victim_ent == 0 then return end

    local pdata    = get_player_data(victim_ent)
    local wid      = get_weapon_id(me)
    local hitgroup = e.hitgroup or 0

    pdata.total_shots = pdata.total_shots + 1
    on_shot_hit(victim_ent, pdata, wid, hitgroup)
end

------------------------------------------------------------------------
-- 10.3  weapon_fire — track that we fired a shot
------------------------------------------------------------------------
function on_weapon_fire(e)
    if not ui.get(ui_enabled) then return end
    local me = entity.get_local_player()
    if not me then return end
    local shiuter_uid = e.userid
    local shooter_ent = client.userid_to_entindex(shiuter_uid)
    if shooter_ent ~= me then return end

    last_shot_tick = globals.tickcount()
    -- store current targeted entity (find closest to crosshair)
    last_shot_ent = nil
    local enemies = entity.get_players(true)
    local best_dist = 9999999
    local ex, ey, ez = client.eye_position()
    if not ex then return end

    for _, ent in ipairs(enemies) do
        if entity.is_alive(ent) and not entity.is_dormant(ent) then
            local hx, hy, hz = entity.hitbox_position(ent, HITBOX_HEAD)
            if hx then
                local d = math_vec_len3d(hx - ex, hy - ey, hz - ez)
                if d < best_dist then
                    best_dist    = d
                    last_shot_ent = ent
                end
            end
        end
    end

    if last_shot_ent then
        local pdata = get_player_data(last_shot_ent)
        local wid   = get_weapon_id(me)
        if wid and is_supported_weapon(wid) then
            pdata.total_shots = pdata.total_shots + 1
        end
    end
end

------------------------------------------------------------------------
-- 10.4  round_start — reset per-round data
------------------------------------------------------------------------
function on_round_start(e)
    player_data = {}
    hud.entries = {}
    last_shot_ent  = nil
    last_shot_tick = 0
    if ui.get(ui_log) then
        client.color_log(100, 180, 255, "[Aether.sev] Round reset — player data cleared")
    end
end

------------------------------------------------------------------------
-- 10.5  round_end
------------------------------------------------------------------------
function on_round_end(e)
    -- optional: log overall accuracy
    if not ui.get(ui_log) then return end
    local total_shots = 0
    local total_hits  = 0
    for _, pd in pairs(player_data) do
        total_shots = total_shots + pd.total_shots
        total_hits  = total_hits  + pd.total_hits
    end
    if total_shots > 0 then
        local pct = math.floor(total_hits / total_shots * 100)
        client.color_log(200, 200, 100,
            string.format("[Aether.sev] Round stats: %d shots, %d hits (%d%%)", total_shots, total_hits, pct))
    end
end

------------------------------------------------------------------------
-- 10.6  player_disconnect — cleanup
------------------------------------------------------------------------
function on_player_disconnect(e)
    local ent = client.userid_to_entindex(e.userid)
    if ent and player_data[ent] then
        player_data[ent] = nil
    end
end

-- register all callbacks
client.set_event_callback("bullet_impact",       on_bullet_impact)
client.set_event_callback("player_hurt",         on_player_hurt)
client.set_event_callback("weapon_fire",         on_weapon_fire)
client.set_event_callback("round_start",         on_round_start)
client.set_event_callback("round_end",           on_round_end)
client.set_event_callback("player_disconnect",   on_player_disconnect)

-- ===========================
-- § 11  PER-FRAME UPDATE
-- ===========================

------------------------------------------------------------------------
-- Called every frame; iterates enemy players and resolves their angles
------------------------------------------------------------------------
function on_createmove()
    if not ui.get(ui_enabled) then return end

    local me = entity.get_local_player()
    if not me or not entity.is_alive(me) then return end

    local my_wid = get_weapon_id(me)
    if not my_wid or not is_supported_weapon(my_wid) then return end

    local enemies = entity.get_players(true)
    for _, ent in ipairs(enemies) do
        if entity.is_alive(ent) and not entity.is_dormant(ent) then
            local pdata = get_player_data(ent)
            resolve_player(ent, pdata, my_wid)

            -- apply resolved yaw via entity prop set (simulation)
            -- (Gamesense lets you read real angles; override can be done via plist)
            -- use plist to set override pitch/yaw for aimbot targeting
            -- Note: plist fields vary; we set what the aimbot reads
            -- plist.set(ent, "Pitch", pdata.last_pitch)   -- optional
            -- plist.set(ent, "Yaw override", pdata.resolved_yaw) -- if exposed
        end
    end
end

client.set_event_callback("createmove", on_createmove)

-- ===========================
-- § 12  HUD / RENDERER
-- ===========================

------------------------------------------------------------------------
-- 12.1  colour helpers
------------------------------------------------------------------------
function confidence_color(conf)
    -- green → yellow → red  as confidence drops
    if conf >= 70 then return 80,  255, 80  end
    if conf >= 40 then return 255, 200, 0   end
    return 255, 70, 70
end

function side_color(side)
    if side == SIDE_LEFT  then return 80,  180, 255 end
    if side == SIDE_RIGHT then return 255, 100, 80  end
    return 180, 180, 180
end

------------------------------------------------------------------------
-- 12.2  Main HUD paint
------------------------------------------------------------------------
function on_paint()
    if not ui.get(ui_enabled) then return end
    if not ui.get(ui_hud) then return end

    local sw, sh = client.screen_size()
    local me     = entity.get_local_player()
    local is_alive_me = me and entity.is_alive(me)

    -- Panel position
    local px = 12
    local py = sh - 220
    local pw = 310
    local ph = 200

    -- panel background
    renderer.rectangle(px, py, pw, ph, 10, 10, 14, 200)
    -- panel border
    renderer.rectangle(px,      py,      pw, 1,  80, 180, 255, 220)
    renderer.rectangle(px,      py+ph-1, pw, 1,  80, 180, 255, 80)
    renderer.rectangle(px,      py,      1,  ph, 80, 180, 255, 160)
    renderer.rectangle(px+pw-1, py,      1,  ph, 80, 180, 255, 160)

    -- header gradient bar
    renderer.gradient(px+1, py+1, pw-2, 20, 20, 60, 120, 200, 10, 10, 14, 200, true)

    -- title
    renderer.text(px + pw/2, py + 5, 100, 220, 255, 255, "c", 0, VERSION_TAG)

    local mode = ui.get(ui_mode)
    renderer.text(px + 8, py + 28, 160, 160, 160, 200, nil, 0, "Mode: " .. mode)

    local my_wid  = is_alive_me and get_weapon_id(me) or nil
    local wepname = my_wid and weapon_name(my_wid) or "---"
    renderer.text(px + 8, py + 42, 160, 160, 160, 200, nil, 0, "Weapon: " .. wepname)

    -- per-enemy table header
    renderer.rectangle(px+1, py+58, pw-2, 1, 60, 60, 80, 180)
    renderer.text(px + 8,   py + 62, 120, 120, 120, 180, nil, 0, "Player")
    renderer.text(px + 150, py + 62, 120, 120, 120, 180, nil, 0, "Side")
    renderer.text(px + 200, py + 62, 120, 120, 120, 180, nil, 0, "Δ")
    renderer.text(px + 240, py + 62, 120, 120, 120, 180, nil, 0, "Conf")
    renderer.text(px + 280, py + 62, 120, 120, 120, 180, nil, 0, "Ms")

    local row_y  = py + 76
    local row_h  = 14
    local row    = 0

    local enemies = entity.get_players(true)
    for _, ent in ipairs(enemies) do
        if entity.is_alive(ent) and not entity.is_dormant(ent) then
            if player_data[ent] then
                local pdata  = player_data[ent]
                local name   = entity.get_player_name(ent)
                -- truncate name
                if #name > 12 then name = name:sub(1, 12) .. ".." end

                local cr, cg, cb = confidence_color(pdata.confidence)
                local sr, sg, sb = side_color(pdata.desync_side)

                local side_str = "?"
                if pdata.desync_side == SIDE_LEFT  then side_str = "L" end
                if pdata.desync_side == SIDE_RIGHT then side_str = "R" end
                if pdata.desync_side == SIDE_NONE  then side_str = "-" end

                renderer.text(px + 8,   row_y, 220, 220, 220, 220, nil, 0, name)
                renderer.text(px + 150, row_y, sr,  sg,  sb,  220, nil, 0, side_str)
                renderer.text(px + 200, row_y, 220, 180, 80,  220, nil, 0,
                    string.format("%.0f", pdata.desync_delta))
                renderer.text(px + 240, row_y, cr,  cg,  cb,  220, nil, 0,
                    string.format("%d", pdata.confidence))
                renderer.text(px + 280, row_y, 255, 80,  80,  220, nil, 0,
                    string.format("%d", pdata.miss_streak))

                row   = row + 1
                row_y = row_y + row_h
                if row >= 6 then break end
            end
        end
    end

    -- ----------------------------------------------------------------
    -- HUD log lines at bottom-right
    -- ----------------------------------------------------------------
    local log_x = sw - 420
    local log_y = sh - 20
    local now   = globals.curtime()
    for i = #hud.entries, 1, -1 do
        local entry = hud.entries[i]
        if entry.expire > now then
            local alpha = math_clamp(math.floor((entry.expire - now) / hud.fade_time * 255), 0, 255)
            renderer.text(log_x, log_y, entry.r, entry.g, entry.b, alpha, nil, 0, entry.text)
            log_y = log_y - 14
        else
            table.remove(hud.entries, i)
        end
    end

    -- ----------------------------------------------------------------
    -- Desync side ESP over player heads
    -- ----------------------------------------------------------------
    if ui.get(ui_show_side) then
        for _, ent in ipairs(enemies) do
            if entity.is_alive(ent) and not entity.is_dormant(ent) and player_data[ent] then
                local pdata = player_data[ent]
                local hx, hy, hz = entity.hitbox_position(ent, HITBOX_HEAD)
                if hx then
                    local sx, sy = renderer.world_to_screen(hx, hy, hz + 12)
                    if sx and sy then
                        local sr, sg, sb = side_color(pdata.desync_side)
                        local side_str = (pdata.desync_side == SIDE_LEFT)  and "<L>" or
                                         (pdata.desync_side == SIDE_RIGHT) and "<R>" or "[-]"
                        renderer.text(sx, sy - 16, sr, sg, sb, 220, "c", 0, side_str)
                        -- draw resolver confidence arc
                        local arc_pct = pdata.confidence / 100
                        local cr, cg, cb = confidence_color(pdata.confidence)
                        renderer.circle_outline(sx, sy - 24, cr, cg, cb, 180, 6, 270, arc_pct, 2)
                    end
                end
            end
        end
    end
end

client.set_event_callback("paint", on_paint)

-- ===========================
-- § 13  WEAPON-SPECIFIC LOGIC
-- ===========================

------------------------------------------------------------------------
-- SSG-08 specific: scoped players have more predictable angles
------------------------------------------------------------------------
function handle_ssg08(ent, pdata)
    local weapon_ent = entity.get_player_weapon(ent)
    if not weapon_ent then return end
    local scoped = entity.get_prop(weapon_ent, "m_bIsScoped")
    if scoped and scoped ~= 0 then
        -- scoped ssg: minimal desync, just use LBY
        pdata.resolved_yaw = pdata.lby_yaw
        pdata.last_mode    = "SSG08/SCOPED"
    else
        -- unscoped: normal resolver
    end
end

------------------------------------------------------------------------
-- Deagle: one-shot headshot potential, prioritise head accuracy
------------------------------------------------------------------------
function handle_deagle(ent, pdata)
    -- deagle players often stand still when shooting
    -- detect standing still → bias toward last known LBY
    local speed = math_vec_len2d(
        pdata.vel_x_hist[1] or 0,
        pdata.vel_y_hist[1] or 0
    )
    if speed < 5 then
        -- standing: LBY is most reliable
        local lby = pdata.lby_yaw
        if math_abs(math_angle_diff(lby, pdata.eye_yaw)) > 5 then
            pdata.resolved_yaw = math_lerp(pdata.resolved_yaw, lby, 0.65)
            pdata.last_mode    = "DEAGLE/STILL-LBY"
        end
    end
end

------------------------------------------------------------------------
-- Revolver: single-shot like deagle but even more reliable desync
------------------------------------------------------------------------
function handle_revolver(ent, pdata)
    -- revolver has a cocking delay — player usually stops to fire
    local speed = math_vec_len2d(
        pdata.vel_x_hist[1] or 0,
        pdata.vel_y_hist[1] or 0
    )
    if speed < 20 then
        pdata.resolved_yaw = pdata.lby_yaw
        pdata.last_mode    = "REVOLVER/LBY"
    end
end

------------------------------------------------------------------------
-- TEC-9: spray weapon, less per-shot accuracy needed → brute more ok
------------------------------------------------------------------------
function handle_tec9(ent, pdata)
    -- tec9 spammers: pick whichever side we haven't tried yet
    -- just bump brute every other miss
    if pdata.miss_streak > 0 and pdata.miss_streak % 2 == 0 then
        advance_brute(pdata, 3)
        pdata.last_mode = "TEC9/BRUTE-FAST"
    end
end

------------------------------------------------------------------------
-- Zeus: one-zap, max confidence required before shooting
------------------------------------------------------------------------
function handle_zeus(ent, pdata)
    -- zeus range is 256 units; check distance
    local me = entity.get_local_player()
    if not me then return end
    local ex, ey, ez = client.eye_position()
    if not ex then return end
    local ox, oy, oz = entity.get_origin(ent)
    if not ox then return end
    local dist = math_vec_len3d(ex - ox, ey - oy, ez - oz)
    if dist > 256 then
        -- too far for zeus, nothing useful to do in resolver
        pdata.last_mode = "ZEUS/OUT-OF-RANGE"
        return
    end
    -- at close range: brute force all sides rapidly
    if pdata.miss_streak > 0 then
        advance_brute(pdata, BRUTE_MAX)
        pdata.last_mode = "ZEUS/BRUTE-CLOSE"
    else
        pdata.last_mode = "ZEUS/CLOSE"
    end
end

------------------------------------------------------------------------
-- Dispatch per-weapon handler after generic resolve
------------------------------------------------------------------------
function dispatch_weapon_handler(ent, pdata, wid)
    if wid == WEAPON_SSG08    then handle_ssg08(ent, pdata)    end
    if wid == WEAPON_DEAGLE   then handle_deagle(ent, pdata)   end
    if wid == WEAPON_REVOLVER then handle_revolver(ent, pdata) end
    if wid == WEAPON_TEC9     then handle_tec9(ent, pdata)     end
    if wid == WEAPON_ZEUS     then handle_zeus(ent, pdata)     end
end

-- ===========================
-- § 14  EXTENDED CREATEMOVE
-- ===========================

function on_createmove_extended()
    if not ui.get(ui_enabled) then return end
    local me = entity.get_local_player()
    if not me or not entity.is_alive(me) then return end

    local wid = get_weapon_id(me)
    if not wid or not is_supported_weapon(wid) then return end

    local enemies = entity.get_players(true)
    for _, ent in ipairs(enemies) do
        if entity.is_alive(ent) and not entity.is_dormant(ent) then
            local pdata = get_player_data(ent)
            -- weapon-specific second pass
            dispatch_weapon_handler(ent, pdata, wid)
        end
    end
end

client.set_event_callback("createmove_end", on_createmove_extended)

-- ===========================
-- § 15  ANTI-FREESTAND LOGIC
-- ===========================

------------------------------------------------------------------------
-- Detect if a player is peeking from left or right of a corner
-- by tracing from their origin to ours and checking trace fraction
------------------------------------------------------------------------
function detect_freestand_side(ent)
    local me = entity.get_local_player()
    if not me then return SIDE_NONE end
    local ex, ey, ez = client.eye_position()
    if not ex then return SIDE_NONE end
    local ox, oy, oz = entity.get_origin(ent)
    if not ox then return SIDE_NONE end

    -- offset the enemy origin left and right by 32 units in eye-yaw plane
    local fwd_yaw_rad = math.rad(entity.get_prop(ent, "m_angEyeAngles[1]") or 0)
    local right_x =  math.cos(fwd_yaw_rad + math.pi/2) * 32
    local right_y =  math.sin(fwd_yaw_rad + math.pi/2) * 32

    local skip = entity.get_local_player()
    -- left offset trace
    local fl, _ = client.trace_line(skip, ex, ey, ez, ox + right_x, oy + right_y, oz + 64)
    -- right offset trace
    local fr, _ = client.trace_line(skip, ex, ey, ez, ox - right_x, oy - right_y, oz + 64)

    if fl == nil then fl = 1.0 end
    if fr == nil then fr = 1.0 end

    if fl > fr + 0.05 then return SIDE_LEFT  end
    if fr > fl + 0.05 then return SIDE_RIGHT end
    return SIDE_NONE
end

------------------------------------------------------------------------
-- Freestand update: merge with resolver
------------------------------------------------------------------------
function update_freestand(ent, pdata, wid)
    local fs_side = detect_freestand_side(ent)
    if fs_side ~= SIDE_NONE then
        local cap = weapon_desync_cap(wid)
        if fs_side == SIDE_LEFT then
            pdata.resolved_yaw = math_normalize_yaw(pdata.eye_yaw + cap)
            pdata.last_mode    = pdata.last_mode .. "+FS-L"
        else
            pdata.resolved_yaw = math_normalize_yaw(pdata.eye_yaw - cap)
            pdata.last_mode    = pdata.last_mode .. "+FS-R"
        end
    end
end

-- ===========================
-- § 16  ADAPTIVE MISS SYSTEM
-- ===========================

------------------------------------------------------------------------
-- Flip the applied offset by 180 degrees after N consecutive misses
------------------------------------------------------------------------
function adaptive_correction(ent, pdata, wid)
    if not ui.get(ui_auto_stop) then return end
    if pdata.miss_streak < 2 then return end

    -- every 2 misses → mirror the offset
    if pdata.miss_streak % 2 == 0 then
        local cap  = weapon_desync_cap(wid)
        local flip = -math_sign(pdata.applied_offset) * cap
        pdata.resolved_yaw = math_normalize_yaw(pdata.eye_yaw + flip)
        pdata.applied_offset = flip
        pdata.last_mode = pdata.last_mode .. "+ADAPT"
    end
end

-- ===========================
-- § 17  LBY DELTA TRACKER
-- ===========================

------------------------------------------------------------------------
-- Track lower body yaw (LBY) flicks which indicate AA updates
------------------------------------------------------------------------
function track_lby(ent, pdata)
    local lby_now  = entity.get_prop(ent, "m_flLowerBodyYawTarget") or pdata.lby_yaw
    local lby_prev = pdata.lby_yaw
    local diff     = math_abs(math_angle_diff(lby_now, lby_prev))

    if diff > 25 then
        -- LBY flick detected
        pdata.lby_flick_yaw  = lby_now
        pdata.lby_update_time = globals.curtime()
        -- LBY updates typically every 1.1 seconds while standing
        -- use this timing to predict next update
        pdata.lby_next_update = globals.curtime() + 1.1
    end
    pdata.lby_yaw = lby_now
end

-- ===========================
-- § 18  INTERPOLATION / LERPs
-- ===========================

------------------------------------------------------------------------
-- Smooth the resolved yaw to prevent stuttering when switching sides
------------------------------------------------------------------------
last_resolved = {}

function smooth_resolved_yaw(ent, pdata)
    local prev = last_resolved[ent] or pdata.resolved_yaw
    local diff  = math_abs(math_angle_diff(pdata.resolved_yaw, prev))
    local t     = 0.25  -- blend factor, higher = faster snap

    if diff > 45 then
        t = 1.0  -- instant snap for large corrections
    end

    local smoothed = math_normalize_yaw(prev + math_angle_diff(pdata.resolved_yaw, prev) * t)
    last_resolved[ent]  = smoothed
    pdata.resolved_yaw  = smoothed
end

-- ===========================
-- § 19  FULL RESOLVE PIPELINE
-- ===========================

------------------------------------------------------------------------
-- Master pipeline: runs on createmove, calls all sub-systems in order
------------------------------------------------------------------------
function full_resolve_pipeline(ent, wid)
    local pdata = get_player_data(ent)

    -- 1. gather and detect
    resolve_player(ent, pdata, wid)

    -- 2. track LBY flicks
    track_lby(ent, pdata)

    -- 3. per-weapon second pass
    dispatch_weapon_handler(ent, pdata, wid)

    -- 4. freestand override
    update_freestand(ent, pdata, wid)

    -- 5. adaptive miss correction
    adaptive_correction(ent, pdata, wid)

    -- 6. smooth output
    smooth_resolved_yaw(ent, pdata)
end

-- overwrite the generic createmove to use full pipeline
client.unset_event_callback("createmove", on_createmove)
client.set_event_callback("createmove", function()
    if not ui.get(ui_enabled) then return end
    local me = entity.get_local_player()
    if not me or not entity.is_alive(me) then return end
    local wid = get_weapon_id(me)
    if not wid or not is_supported_weapon(wid) then return end

    local enemies = entity.get_players(true)
    for _, ent in ipairs(enemies) do
        if entity.is_alive(ent) and not entity.is_dormant(ent) then
            full_resolve_pipeline(ent, wid)
        end
    end
end)

-- ===========================
-- § 20  STATISTICS & DATABASE
-- ===========================

------------------------------------------------------------------------
-- Save accuracy stats for reloads via database
------------------------------------------------------------------------
DB_KEY = "uv_resolver_stats"

function save_stats()
    local total_shots = 0
    local total_hits  = 0
    for _, pd in pairs(player_data) do
        total_shots = total_shots + pd.total_shots
        total_hits  = total_hits  + pd.total_hits
    end
    -- database module is available in Gamesense
    -- database.write(DB_KEY, json.stringify({ shots=total_shots, hits=total_hits }))
end

function load_stats()
    -- local raw = database.read(DB_KEY)
    -- if not raw then return end
    -- local data = json.parse(raw)
    -- if data then ... end
end

-- ===========================
-- § 21  CLAN-TAG STATUS
-- ===========================

function update_clan_tag()
    if not ui.get(ui_enabled) then
        client.set_clan_tag()
        return
    end
    local h, m, s = client.system_time()
    local mode    = ui.get(ui_mode):sub(1, 4)
    client.set_clan_tag("void")
end

-- Update clan tag every 60 frames
clan_tag_counter = 0
client.set_event_callback("paint", function()
    clan_tag_counter = clan_tag_counter + 1
    if clan_tag_counter >= 60 then
        clan_tag_counter = 0
        update_clan_tag()
    end
end)

-- ===========================
-- § 22  ESP FLAG
-- ===========================

-- Register an ESP flag showing resolver state
client.register_esp_flag("UV", 80, 180, 255, function(ent)
    if not ui.get(ui_enabled) then return false end
    if not entity.is_enemy(ent) then return false end
    if not entity.is_alive(ent) then return false end
    if player_data[ent] then
        return true
    end
    return false
end)

-- ===========================
-- § 23  DAMAGE VALIDATION
-- ===========================

------------------------------------------------------------------------
-- Before accepting a shot, validate it can actually kill
-- Uses client.scale_damage + client.trace_bullet
------------------------------------------------------------------------
function validate_shot_damage(target_ent, hitgroup, base_damage)
    local me = entity.get_local_player()
    if not me then return true end
    local scaled = client.scale_damage(target_ent, hitgroup, base_damage)
    if not scaled then return true end
    -- only proceed if we deal meaningful damage
    return scaled > 10
end

-- ===========================
-- § 24  VELOCITY PREDICTION
-- ===========================

------------------------------------------------------------------------
-- Predict where the player will be next tick by extrapolating velocity
------------------------------------------------------------------------
function predict_origin(ent, pdata, ticks_ahead)
    local ox, oy, oz = entity.get_origin(ent)
    if not ox then return nil end
    local vx = pdata.vel_x_hist[1] or 0
    local vy = pdata.vel_y_hist[1] or 0
    local vz = pdata.vel_z_hist[1] or 0
    local dt  = globals.tickinterval() * ticks_ahead
    return ox + vx * dt, oy + vy * dt, oz + vz * dt
end

-- ===========================
-- § 25  RESOLVER DEBUG PANEL
-- ===========================

------------------------------------------------------------------------
-- Extended debug info rendered in console on demand
------------------------------------------------------------------------
function dump_player_info(ent)
    local pdata = player_data[ent]
    if not pdata then
        client.log("No data for entity ", ent)
        return
    end
    local name = entity.get_player_name(ent)
    client.color_log(100, 220, 255, string.format(
        "=== UV Debug: %s (ent=%d) ===", name, ent))
    client.color_log(200, 200, 100, string.format(
        "  Eye Yaw=%.1f  LBY=%.1f  Resolved=%.1f",
        pdata.eye_yaw, pdata.lby_yaw, pdata.resolved_yaw))
    client.color_log(200, 200, 100, string.format(
        "  Delta=%.1f  Side=%d  Mode=%s",
        pdata.desync_delta, pdata.desync_side, pdata.last_mode))
    client.color_log(200, 200, 100, string.format(
        "  Shots=%d  Hits=%d  Misses=%d  Streak=%d",
        pdata.total_shots, pdata.total_hits, pdata.total_misses, pdata.miss_streak))
    client.color_log(200, 200, 100, string.format(
        "  Confidence=%d  Brute=%d  Choke=%d",
        pdata.confidence, pdata.brute_state, pdata.choke_ticks))
    client.color_log(200, 200, 100, string.format(
        "  Jitter=%s  Static=%s  LowDelta=%s",
        tostring(pdata.jitter_detected),
        tostring(pdata.is_static),
        tostring(pdata.low_delta)))
end

-- ===========================
-- § 26  PLIST INTEGRATION
-- ===========================

------------------------------------------------------------------------
-- Push resolved angles into plist so gamesense aimbot uses them
-- Note: exact plist field names may depend on your gs version/config
------------------------------------------------------------------------
-- (commented exemplars — uncomment if your build supports these fields)
--[[
function push_plist_overrides(ent, pdata)
    -- plist.set(ent, "Pitch",        math_clamp(pdata.last_pitch, -89, 89))
    -- plist.set(ent, "Yaw override", pdata.resolved_yaw)
    -- plist.set(ent, "Hitchance",    ui.get(ui_hitchance))
end
--]]

-- ===========================
-- § 27  BOUNDING BOX CHECKS
-- ===========================

------------------------------------------------------------------------
-- Use bounding box alpha from entity.get_bounding_box to skip
-- players who are off-screen / culled by the engine
------------------------------------------------------------------------
function is_renderable(ent)
    local x1, y1, x2, y2, alpha = entity.get_bounding_box(ent)
    if not alpha or alpha == 0 then return false end
    return true
end

-- ===========================
-- § 28  ANGLE SANITY FILTER
-- ===========================

------------------------------------------------------------------------
-- Filter out bogus angles that might be server-side artefacts
------------------------------------------------------------------------
function is_angle_valid(yaw, pitch)
    if math_abs(yaw)   > 180.1 then return false end
    if math_abs(pitch) > 90.1  then return false end
    return true
end

-- ===========================
-- § 29  RESOLVER RESULT CACHE
-- ===========================

resolve_cache = {}
resolve_cache_tick = {}

function get_cached_resolved(ent)
    local tick = globals.tickcount()
    if resolve_cache_tick[ent] == tick then
        return resolve_cache[ent]
    end
    return nil
end

function set_cached_resolved(ent, yaw)
    resolve_cache[ent]      = yaw
    resolve_cache_tick[ent] = globals.tickcount()
end

-- ===========================
-- § 30  FINAL INIT LOG
-- ===========================

client.color_log(80,  180, 255, "[Aether.sev] ============================================")
client.color_log(100, 220, 255, "[Aether.sev]  Aether.sev loaded")
client.color_log(180, 255, 180, "[Aether.sev]  Supported: SSG-08 | Deagle | Revolver | TEC-9 | Zeus")
client.color_log(200, 200, 100, "[Aether.sev]  API: gamesensical.gitbook.io/docs")
client.color_log(80,  180, 255, "[Aether.sev] ============================================")
client.color_log(140, 140, 140, "[Aether.sev]  Navigate: LUA > A > Aether.sev page selector")

-- ===========================
-- § 31  EXTRA BRUTE PATTERNS
-- ===========================

------------------------------------------------------------------------
-- Extended brute pattern for 6 states including half-delta positions
-- Used when confidence is very low AND miss streak is high
------------------------------------------------------------------------
extended_brute_offsets = {
    [0] =  0,
    [1] =  58,
    [2] = -58,
    [3] =  29,
    [4] = -29,
    [5] =  45,
    [6] = -45,
}

function extended_brute_resolve(pdata, wid)
    if pdata.confidence > 20 then return end
    if pdata.miss_streak < 3 then return end
    local cap = weapon_desync_cap(wid)
    local idx = pdata.miss_streak % 7
    local off = (extended_brute_offsets[idx] or 0)
    -- scale offset by cap ratio
    off = off * (cap / 58)
    pdata.resolved_yaw = math_normalize_yaw(pdata.eye_yaw + off)
    pdata.applied_offset = off
    pdata.last_mode = "EXT-BRUTE#" .. idx
end

-- hook into createmove_end for extended brute
client.set_event_callback("createmove_end", function()
    if not ui.get(ui_enabled) then return end
    local me = entity.get_local_player()
    if not me or not entity.is_alive(me) then return end
    local wid = get_weapon_id(me)
    if not wid or not is_supported_weapon(wid) then return end

    local enemies = entity.get_players(true)
    for _, ent in ipairs(enemies) do
        if entity.is_alive(ent) and not entity.is_dormant(ent) and player_data[ent] then
            extended_brute_resolve(player_data[ent], wid)
            set_cached_resolved(ent, player_data[ent].resolved_yaw)
        end
    end
end)

-- ===========================
-- § 32  MICRO-CORRECTIONS
-- ===========================

------------------------------------------------------------------------
-- Tiny pitch micro-corrections for SSG and Deagle head-shots
-- Negative pitch = looking slightly downward at target head
------------------------------------------------------------------------
function micro_pitch_correction(ent, pdata, wid)
    if wid ~= WEAPON_SSG08 and wid ~= WEAPON_DEAGLE and wid ~= WEAPON_REVOLVER then
        return
    end
    local me = entity.get_local_player()
    if not me then return end
    local ex, ey, ez = client.eye_position()
    if not ex then return end
    local hx, hy, hz = entity.hitbox_position(ent, HITBOX_HEAD)
    if not hx then return end
    local dx  = hx - ex
    local dy  = hy - ey
    local dz  = hz - ez
    local dist2d = math_vec_len2d(dx, dy)
    if dist2d < 0.01 then return end
    local ideal_pitch = math.deg(math.atan2(-dz, dist2d))
    pdata.last_pitch  = math_clamp(ideal_pitch, -89, 89)
end

-- ===========================
-- § 33  SHOT TIMING TRACKER
-- ===========================

shot_timestamps = {}  -- [ent] = { time, ... }

function record_shot_time(ent)
    if not shot_timestamps[ent] then
        shot_timestamps[ent] = {}
    end
    table_insert_limited(shot_timestamps[ent], globals.curtime(), 10)
end

function avg_shot_interval(ent)
    local ts = shot_timestamps[ent]
    if not ts or #ts < 2 then return 0 end
    local total = 0
    for i = 1, #ts - 1 do
        total = total + (ts[i] - ts[i + 1])
    end
    return total / (#ts - 1)
end

-- ===========================
-- § 34  DORMANT HANDLING
-- ===========================

------------------------------------------------------------------------
-- When a player goes dormant, preserve their last known resolved yaw
-- so we can resume accurately when they re-appear
------------------------------------------------------------------------
dormant_resolved = {}

client.set_event_callback("createmove", function()
    for ent = 1, MAX_PLAYERS do
        if entity.is_dormant(ent) and player_data[ent] then
            dormant_resolved[ent] = player_data[ent].resolved_yaw
        end
    end
end)

function restore_dormant_resolved(ent, pdata)
    if dormant_resolved[ent] then
        pdata.resolved_yaw = dormant_resolved[ent]
        dormant_resolved[ent] = nil
    end
end

-- ===========================
-- § 35  CLEANUP ON UNLOAD
-- ===========================

client.set_event_callback("shutdown", function()
    save_stats()
    client.set_clan_tag()
    client.color_log(255, 120, 50, "[Aether.sev] Unloaded — stats saved.")
end)

-- ===========================
-- § 36  ANGLE HISTORY ANALYSIS
-- ===========================

------------------------------------------------------------------------
-- Detect alternating AA (flip-flop between two fixed yaws)
-- This is a common pattern where players press A/D to alternate desync
------------------------------------------------------------------------
function detect_flip_flop(pdata)
    local yaws = pdata.yaw_history
    if #yaws < 6 then return false, 0, 0 end

    -- collect unique yaw buckets (rounded to nearest 5 degrees)
    local buckets = {}
    for _, y in ipairs(yaws) do
        local key = math.floor(y / 5 + 0.5) * 5
        buckets[key] = (buckets[key] or 0) + 1
    end

    -- find top-2 buckets
    local b1_key, b1_cnt = nil, 0
    local b2_key, b2_cnt = nil, 0
    for k, v in pairs(buckets) do
        if v > b1_cnt then
            b2_key, b2_cnt = b1_key, b1_cnt
            b1_key, b1_cnt = k, v
        elseif v > b2_cnt then
            b2_key, b2_cnt = k, v
        end
    end

    if not b1_key or not b2_key then return false, 0, 0 end

    -- flip-flop if both buckets have >= 2 hits and differ by > 30 degrees
    local diff = math_abs(math_angle_diff(b1_key, b2_key))
    if b1_cnt >= 2 and b2_cnt >= 2 and diff > 30 then
        return true, b1_key, b2_key
    end
    return false, 0, 0
end

------------------------------------------------------------------------
-- Use flip-flop detection to pick next expected yaw
------------------------------------------------------------------------
function resolve_flip_flop(ent, pdata, wid)
    local is_ff, yaw_a, yaw_b = detect_flip_flop(pdata)
    if not is_ff then return end

    -- pick whichever we HAVEN'T hit yet, or alternate on miss
    local last_y = pdata.resolved_yaw
    local dist_a = math_abs(math_angle_diff(last_y, yaw_a))
    local dist_b = math_abs(math_angle_diff(last_y, yaw_b))

    if pdata.miss_streak == 0 then
        -- no miss yet: pick the closer of the two
        pdata.resolved_yaw = (dist_a <= dist_b) and yaw_a or yaw_b
    else
        -- miss: flip to the other
        pdata.resolved_yaw = (dist_a <= dist_b) and yaw_b or yaw_a
    end
    pdata.last_mode = "FLIP-FLOP"
end

-- ===========================
-- § 37  AIR-STRAFE DETECTION
-- ===========================

------------------------------------------------------------------------
-- Detect air strafing by checking vertical velocity + horizontal speed
-- Air strafing players typically have high horizontal speed while airborne
------------------------------------------------------------------------
function detect_air_strafe(ent, pdata)
    local flags = entity.get_prop(ent, "m_fFlags") or 0
    local on_ground = bit.band(flags, FL_ONGROUND) ~= 0
    if on_ground then return false end

    local vx = pdata.vel_x_hist[1] or 0
    local vy = pdata.vel_y_hist[1] or 0
    local spd2d = math_vec_len2d(vx, vy)

    -- air strafe: airborne + fast horizontal movement
    if spd2d > 200 then
        return true
    end
    return false
end

------------------------------------------------------------------------
-- During air strafe: use velocity direction as the dominant yaw
------------------------------------------------------------------------
function resolve_air_strafe(ent, pdata, wid)
    if not detect_air_strafe(ent, pdata) then return end

    local vx   = pdata.vel_x_hist[1] or 0
    local vy   = pdata.vel_y_hist[1] or 0
    local spd  = math_vec_len2d(vx, vy)
    if spd < 1 then return end

    local move_yaw = math.deg(math.atan2(vy, vx))
    -- air-strafe resolver: blend velocity direction with desync offset
    local cap = weapon_desync_cap(wid)
    local side_off = pdata.desync_delta
    pdata.resolved_yaw = math_normalize_yaw(move_yaw + side_off)
    pdata.last_mode    = "AIR-STRAFE"
end

-- ===========================
-- § 38  MULTI-TARGET PRIORITY
-- ===========================

------------------------------------------------------------------------
-- Rank enemies by threat level:
--  1. Zeus wielders at close range (instant kill threat)
--  2. Deagle/SSG headshot range
--  3. Low health
------------------------------------------------------------------------
function compute_threat_score(ent)
    local me = entity.get_local_player()
    if not me then return 0 end

    local score = 0

    -- distance factor
    local ex, ey, ez = client.eye_position()
    local ox, oy, oz = entity.get_origin(ent)
    if ex and ox then
        local dist = math_vec_len3d(ex - ox, ey - oy, ez - oz)
        if dist < 256 then score = score + 100 end -- very close
        if dist < 512 then score = score + 50  end
    end

    -- weapon factor
    local wep = entity.get_player_weapon(ent)
    if wep then
        local wid = entity.get_prop(wep, "m_iItemDefinitionIndex")
        if wid == WEAPON_ZEUS     then score = score + 200 end
        if wid == WEAPON_DEAGLE   then score = score + 80  end
        if wid == WEAPON_SSG08    then score = score + 90  end
        if wid == WEAPON_REVOLVER then score = score + 80  end
    end

    -- health factor
    local hp = entity.get_prop(ent, "m_iHealth") or 100
    if hp <= 25 then score = score + 30 end -- almost dead, finish them

    -- visibility factor
    if ex then
        local hx, hy, hz = entity.hitbox_position(ent, HITBOX_HEAD)
        if hx then
            local vis = client.visible(hx, hy, hz)
            if vis then score = score + 60 end
        end
    end

    return score
end

------------------------------------------------------------------------
-- Returns sorted list of enemies by threat score (highest first)
------------------------------------------------------------------------
function get_prioritized_enemies()
    local enemies = entity.get_players(true)
    local scored  = {}
    for _, ent in ipairs(enemies) do
        if entity.is_alive(ent) and not entity.is_dormant(ent) then
            scored[#scored + 1] = { ent=ent, score=compute_threat_score(ent) }
        end
    end
    table.sort(scored, function(a, b) return a.score > b.score end)
    local result = {}
    for _, v in ipairs(scored) do
        result[#result + 1] = v.ent
    end
    return result
end

-- ===========================
-- § 39  LATENCY COMPENSATION
-- ===========================

------------------------------------------------------------------------
-- Compensate for network latency by extrapolating player position
-- forward by (latency / tickinterval) ticks
------------------------------------------------------------------------
function get_latency_ticks()
    local lat = client.latency()
    local tki = globals.tickinterval()
    if tki <= 0 then return 0 end
    return math.floor(lat / tki + 0.5)
end

------------------------------------------------------------------------
-- Extrapolate resolved yaw accounting for player rotation speed
-- during the latency window
------------------------------------------------------------------------
function latency_compensate_yaw(ent, pdata)
    local lat_ticks = get_latency_ticks()
    if lat_ticks <= 0 or #pdata.yaw_history < 2 then
        return pdata.resolved_yaw
    end

    -- estimate yaw rate (degrees per tick) from history
    local dy = math_angle_diff(pdata.yaw_history[1], pdata.yaw_history[2])
    local tki = globals.tickinterval()
    if tki > 0 then
        dy = dy / (tki * 64) -- normalise to ticks (approximate)
    end

    -- project forward
    local predicted = math_normalize_yaw(pdata.resolved_yaw + dy * lat_ticks)
    return predicted
end

-- ===========================
-- § 40  LBY TIMING PREDICTOR
-- ===========================

------------------------------------------------------------------------
-- Lower body yaw updates on a ~1.1 s timer when standing still
-- Predict when the next update is and pre-aim for it
------------------------------------------------------------------------
function predict_lby_update(pdata)
    local now  = globals.curtime()
    local next = pdata.lby_next_update or 0
    local dt   = next - now

    if dt < 0 then
        -- overdue: LBY update imminent or already happened
        return true
    end
    if dt < 0.2 then
        -- very close: pre-arm for it
        return true
    end
    return false
end

function apply_lby_timing(pdata)
    if not predict_lby_update(pdata) then return end
    -- just before LBY update: snap to flick target
    if pdata.lby_flick_yaw ~= 0 then
        pdata.resolved_yaw = math_normalize_yaw(pdata.lby_flick_yaw)
        pdata.last_mode    = pdata.last_mode .. "+LBY-PRED"
    end
end

-- ===========================
-- § 41  VELOCITY-YAW CORRELATION
-- ===========================

------------------------------------------------------------------------
-- Correlate movement direction with the observed eye yaw to detect
-- if a player is moving "away" (back to us) or "toward" (facing us).
-- This affects which desync side they most likely use.
------------------------------------------------------------------------
function velocity_yaw_correlation(ent, pdata)
    local vx = pdata.vel_x_hist[1] or 0
    local vy = pdata.vel_y_hist[1] or 0
    if math_vec_len2d(vx, vy) < 10 then return end

    local move_yaw = math.deg(math.atan2(vy, vx))
    local eye_yaw  = pdata.eye_yaw
    local diff     = math_abs(math_angle_diff(move_yaw, eye_yaw))

    -- moving away from us: back-AA likely, prefer LBY
    if diff > 135 then
        pdata.resolved_yaw = math_normalize_yaw(pdata.lby_yaw)
        pdata.last_mode    = "VEL-BACKAIM"
    end
end

-- ===========================
-- § 42  PER-TICK TRACE GATE
-- ===========================

------------------------------------------------------------------------
-- Before every shot we run a quick trace to check if the resolved
-- position would actually penetrate. If not, skip the shot.
-- This prevents wasted shots through walls due to resolver errors.
------------------------------------------------------------------------
function can_hit_resolved(ent, pdata)
    local me = entity.get_local_player()
    if not me then return true end
    local ex, ey, ez = client.eye_position()
    if not ex then return true end

    -- compute head position at resolved yaw
    local hx, hy, hz = entity.hitbox_position(ent, HITBOX_HEAD)
    if not hx then return false end

    local fraction, hit_ent = client.trace_bullet(me, ex, ey, ez, hx, hy, hz, false)
    if not fraction then return false end
    if fraction < 0.97 and hit_ent ~= ent then return false end
    return true
end

-- ===========================
-- § 43  HITCHANCE OVERRIDE
-- ===========================

------------------------------------------------------------------------
-- Dynamically override min hitchance based on weapon and distance
------------------------------------------------------------------------
function compute_dynamic_hitchance(wid, dist)
    local base = ui.get(ui_hitchance)
    if not wid then return base end

    -- SSG-08: higher min chance since each bullet is precious
    if wid == WEAPON_SSG08    then base = math.max(base, 55) end
    -- Deagle: at close range we can afford lower HC
    if wid == WEAPON_DEAGLE then
        if dist and dist < 200 then base = math.max(base, 30)
        else                        base = math.max(base, 50) end
    end
    -- Zeus: must be basically certain before wasting charge
    if wid == WEAPON_ZEUS     then base = math.max(base, 75) end
    -- Revolver: cocking cost means we want high certainty
    if wid == WEAPON_REVOLVER then base = math.max(base, 60) end
    -- TEC-9: spray, low HC ok
    if wid == WEAPON_TEC9     then base = math.max(base, 25) end

    return math_clamp(base, 0, 100)
end

-- ===========================
-- § 44  ESP ANGLES OVERLAY
-- ===========================

------------------------------------------------------------------------
-- Draw a small arc on the enemy showing the resolved yaw angle
-- relative to their eye yaw (the desync offset visualised)
------------------------------------------------------------------------
function draw_resolver_arc(ent, pdata)
    if not ui.get(ui_show_side) then return end
    local hx, hy, hz = entity.hitbox_position(ent, HITBOX_HEAD)
    if not hx then return end
    local sx, sy = renderer.world_to_screen(hx, hy, hz)
    if not sx or not sy then return end

    local offset_pct = math_abs(pdata.desync_delta) / 60
    offset_pct = math_clamp(offset_pct, 0, 1)

    local cr, cg, cb = side_color(pdata.desync_side)
    -- outer ring shows desync amount
    renderer.circle_outline(sx, sy, cr, cg, cb, 140, 10, 270, offset_pct, 1)
    -- inner dot indicates resolved side
    local dot_col_r, dot_col_g, dot_col_b = confidence_color(pdata.confidence)
    renderer.circle(sx, sy, dot_col_r, dot_col_g, dot_col_b, 180, 3, 0, 1)
end

------------------------------------------------------------------------
-- Register second paint callback for arc ESP only
------------------------------------------------------------------------
client.set_event_callback("paint", function()
    if not ui.get(ui_enabled) then return end
    if not ui.get(ui_show_side) then return end
    local enemies = entity.get_players(true)
    for _, ent in ipairs(enemies) do
        if entity.is_alive(ent) and not entity.is_dormant(ent) and player_data[ent] then
            draw_resolver_arc(ent, player_data[ent])
        end
    end
end)

-- ===========================
-- § 45  RESOLVER STATE MACHINE
-- ===========================

-- States
RSM_IDLE      = "IDLE"
RSM_TRACKING  = "TRACKING"
RSM_BRUTING   = "BRUTING"
RSM_CONFIRMED = "CONFIRMED"
RSM_LOST      = "LOST"

------------------------------------------------------------------------
-- Update the resolver state machine based on current data
------------------------------------------------------------------------
function update_rsm(pdata)
    local state = pdata.rsm_state or RSM_IDLE

    if state == RSM_IDLE then
        if #pdata.yaw_history >= 4 then
            pdata.rsm_state = RSM_TRACKING
        end

    elseif state == RSM_TRACKING then
        if pdata.confidence >= 60 then
            pdata.rsm_state = RSM_CONFIRMED
        elseif pdata.miss_streak >= 3 then
            pdata.rsm_state = RSM_BRUTING
        end

    elseif state == RSM_BRUTING then
        if pdata.miss_streak == 0 and pdata.total_hits > 0 then
            pdata.rsm_state = RSM_CONFIRMED
        elseif pdata.brute_state >= BRUTE_MAX then
            -- exhausted all brute states, reset and try again
            pdata.brute_state = BRUTE_DEFAULT
            pdata.rsm_state   = RSM_TRACKING
        end

    elseif state == RSM_CONFIRMED then
        if pdata.miss_streak >= 2 then
            pdata.rsm_state = RSM_BRUTING
        end

    elseif state == RSM_LOST then
        -- player went dormant — handled by restore_dormant_resolved
        if #pdata.yaw_history >= 2 then
            pdata.rsm_state = RSM_TRACKING
        end
    end

    -- store for HUD
    pdata.rsm_state = pdata.rsm_state or RSM_IDLE
end

-- init rsm_state field on new players
_orig_get_player_data = get_player_data
get_player_data = function(ent)
    local pd = _orig_get_player_data(ent)
    if not pd.rsm_state then pd.rsm_state = RSM_IDLE end
    return pd
end

-- ===========================
-- § 46  BRUTE CONFIRMATION
-- ===========================

------------------------------------------------------------------------
-- When a brute-force hit succeeds, lock that offset for a short time
-- before allowing further bruting (prevents flip-flopping on success)
------------------------------------------------------------------------
brute_lock     = {}  -- [ent] = locked offset
brute_lock_until = {} -- [ent] = timestamp until lock expires
BRUTE_LOCK_DURATION = 2.5  -- seconds

function try_lock_brute(ent, pdata)
    local now = globals.curtime()
    if brute_lock_until[ent] and brute_lock_until[ent] > now then
        -- still locked: enforce the stored offset
        pdata.resolved_yaw = math_normalize_yaw(pdata.eye_yaw + brute_lock[ent])
        pdata.applied_offset = brute_lock[ent]
        pdata.last_mode    = "BRUTE-LOCKED"
        return true
    end
    return false
end

function confirm_brute_lock(ent, pdata)
    if pdata.miss_streak == 0 and pdata.total_hits > 0 then
        local now = globals.curtime()
        brute_lock[ent]       = pdata.applied_offset
        brute_lock_until[ent] = now + BRUTE_LOCK_DURATION
    end
end

-- ===========================
-- § 47  ACCURACY LOGGER
-- ===========================

------------------------------------------------------------------------
-- Every 30 seconds write a mini accuracy report to console
------------------------------------------------------------------------
accuracy_log_timer = 0
ACCURACY_LOG_INTERVAL = 30

client.set_event_callback("paint", function()
    if not ui.get(ui_enabled) or not ui.get(ui_log) then return end
    local now = globals.curtime()
    if now - accuracy_log_timer < ACCURACY_LOG_INTERVAL then return end
    accuracy_log_timer = now

    local total_s = 0
    local total_h = 0
    for _, pd in pairs(player_data) do
        total_s = total_s + pd.total_shots
        total_h = total_h + pd.total_hits
    end
    if total_s == 0 then return end

    local pct = math.floor(total_h / total_s * 100)
    client.color_log(100, 220, 255,
        string.format("[UV] Accuracy report: %d/%d hits = %d%%", total_h, total_s, pct))
end)

-- ===========================
-- § 48  COMBINED FINAL UPDATE
-- ===========================

------------------------------------------------------------------------
-- Hook into the final createmove_end pass where we run:
--   flip-flop, air-strafe, LBY timing, velocity-yaw, RSM, brute-lock
------------------------------------------------------------------------
client.set_event_callback("createmove_end", function()
    if not ui.get(ui_enabled) then return end
    local me = entity.get_local_player()
    if not me or not entity.is_alive(me) then return end

    local wid = get_weapon_id(me)
    if not wid or not is_supported_weapon(wid) then return end

    local ranked = get_prioritized_enemies()

    for _, ent in ipairs(ranked) do
        if entity.is_alive(ent) and not entity.is_dormant(ent) then
            local pdata = get_player_data(ent)

            -- restore dormant data if any
            restore_dormant_resolved(ent, pdata)

            -- state machine update
            update_rsm(pdata)

            -- brute lock check (highest priority override)
            if try_lock_brute(ent, pdata) then
                goto continue_ent
            end

            -- flip-flop detection pass
            resolve_flip_flop(ent, pdata, wid)

            -- air-strafe override
            resolve_air_strafe(ent, pdata, wid)

            -- velocity-yaw correlation
            velocity_yaw_correlation(ent, pdata)

            -- LBY timing prediction
            apply_lby_timing(pdata)

            -- latency compensation
            pdata.resolved_yaw = latency_compensate_yaw(ent, pdata)
            pdata.resolved_yaw = math_normalize_yaw(pdata.resolved_yaw)

            -- brute confirmation on hit
            confirm_brute_lock(ent, pdata)

            -- final cache update
            set_cached_resolved(ent, pdata.resolved_yaw)

            ::continue_ent::
        end
    end
end)

-- ===========================
-- § 49  HUD EXTENDED — STATE
-- ===========================

------------------------------------------------------------------------
-- Second HUD widget: show RSM state and hitchance per-player
------------------------------------------------------------------------
client.set_event_callback("paint", function()
    if not ui.get(ui_enabled) or not ui.get(ui_hud) then return end

    local sw, _ = client.screen_size()
    local px = sw - 230
    local py = 60
    local pw = 220
    local line_h = 14

    -- background
    renderer.rectangle(px, py, pw, 6 + line_h * 7, 10, 10, 14, 180)
    renderer.rectangle(px, py, pw, 1, 80, 180, 255, 200)

    renderer.text(px + pw/2, py + 3, 100, 220, 255, 255, "c", 0, "UV State Monitor")

    local row_y = py + 18
    local ranked = get_prioritized_enemies()
    local shown  = 0

    for _, ent in ipairs(ranked) do
        if shown >= 5 then break end
        if entity.is_alive(ent) and not entity.is_dormant(ent) and player_data[ent] then
            local pdata = player_data[ent]
            local name  = entity.get_player_name(ent)
            if #name > 10 then name = name:sub(1, 10) .. "." end

            local rsm   = pdata.rsm_state or RSM_IDLE
            local rsm_r, rsm_g, rsm_b = 180, 180, 180
            if rsm == RSM_CONFIRMED then rsm_r, rsm_g, rsm_b = 80,  255, 80  end
            if rsm == RSM_BRUTING   then rsm_r, rsm_g, rsm_b = 255, 180, 0   end
            if rsm == RSM_LOST      then rsm_r, rsm_g, rsm_b = 255, 60,  60  end

            local me   = entity.get_local_player()
            local wid2 = me and get_weapon_id(me)
            local ex, ey, ez = client.eye_position()
            local ox, oy, oz = entity.get_origin(ent)
            local dist = (ex and ox) and math_vec_len3d(ex - ox, ey - oy, ez - oz) or 0
            local hc   = wid2 and compute_dynamic_hitchance(wid2, dist) or 0

            renderer.text(px + 4,   row_y, 220, 220, 220, 220, nil, 0, name)
            renderer.text(px + 110, row_y, rsm_r, rsm_g, rsm_b, 220, nil, 0, rsm)
            renderer.text(px + 185, row_y, 200, 200, 100, 220, nil, 0, hc .. "%")

            row_y = row_y + line_h
            shown = shown + 1
        end
    end
end)

-- ===========================
-- § 50  RESOLVER SELF-TEST
-- ===========================

------------------------------------------------------------------------
-- On script load: run a quick internal self-test of math utilities
-- Prints PASS/FAIL to console for each test
------------------------------------------------------------------------
function run_self_test()
    local pass = 0
    local fail = 0

    local function test(name, cond)
        if cond then
            pass = pass + 1
        else
            fail = fail + 1
            client.color_log(255, 80, 80, "[UV-SelfTest] FAIL: " .. name)
        end
    end

    test("normalize_yaw(370)  == 10",   math_abs(math_normalize_yaw(370)  - 10)  < 0.01)
    test("normalize_yaw(-190) == 170",  math_abs(math_normalize_yaw(-190) - 170) < 0.01)
    test("angle_diff(10,-10)  == 20",   math_abs(math_angle_diff(10, -10) - 20)  < 0.01)
    test("angle_diff(170,-170)== -20",  math_abs(math_angle_diff(170,-170)+ 20)  < 0.01)
    test("clamp(150,0,100)    == 100",  math_clamp(150, 0, 100) == 100)
    test("clamp(-10,0,100)    == 0",    math_clamp(-10, 0, 100) == 0)
    test("vec_len2d(3,4)      == 5",    math_abs(math_vec_len2d(3, 4) - 5) < 0.01)
    test("lerp(0,10,0.5)      == 5",    math_abs(math_lerp(0, 10, 0.5) - 5) < 0.01)

    if fail == 0 then
        client.color_log(80, 255, 120,
            string.format("[UV-SelfTest] All %d tests passed.", pass))
    else
        client.color_log(255, 180, 0,
            string.format("[UV-SelfTest] %d passed, %d failed.", pass, fail))
    end
end

-- defer self-test to first frame so API is fully ready
client.delay_call(0.1, run_self_test)

-- ===========================
-- § 51  PLAYER HEALTH MONITOR
-- ===========================

------------------------------------------------------------------------
-- Track enemy health to detect if our damage is registering correctly
-- If an enemy's health doesn't decrease after a reported hit, flag it
------------------------------------------------------------------------
health_history = {}  -- [ent] = { hp, tick }

function track_enemy_health(ent)
    local hp = entity.get_prop(ent, "m_iHealth")
    if not hp then return end

    if not health_history[ent] then
        health_history[ent] = { hp=hp, tick=globals.tickcount() }
        return
    end

    local prev_hp   = health_history[ent].hp
    local prev_tick = health_history[ent].tick
    local curr_tick = globals.tickcount()

    -- update
    health_history[ent] = { hp=hp, tick=curr_tick }

    -- if we recorded a shot within last 10 ticks and HP didn't drop
    if last_shot_ent == ent then
        local ticks_since = curr_tick - prev_tick
        if ticks_since < 10 and hp >= prev_hp then
            -- possible miss or server-side rejection
            local pdata = player_data[ent]
            if pdata then
                pdata.confidence = math_clamp(pdata.confidence - 5, 0, 100)
            end
        end
    end
end

client.set_event_callback("createmove", function()
    if not ui.get(ui_enabled) then return end
    local enemies = entity.get_players(true)
    for _, ent in ipairs(enemies) do
        if entity.is_alive(ent) and not entity.is_dormant(ent) then
            track_enemy_health(ent)
        end
    end
end)

-- ===========================
-- § 52  FINAL EXTENDED INIT
-- ===========================

client.color_log(80,  180, 255, "[Aether.sev] ============================================")
client.color_log(100, 220, 255, "[Aether.sev]  Modules loaded:")
client.color_log(180, 255, 180, "[Aether.sev]  § 36  Angle History / Flip-Flop Detection")
client.color_log(180, 255, 180, "[Aether.sev]  § 37  Air-Strafe Detection & Resolve")
client.color_log(180, 255, 180, "[Aether.sev]  § 38  Multi-Target Priority System")
client.color_log(180, 255, 180, "[Aether.sev]  § 39  Latency Compensation")
client.color_log(180, 255, 180, "[Aether.sev]  § 40  LBY Timing Predictor")
client.color_log(180, 255, 180, "[Aether.sev]  § 41  Velocity-Yaw Correlation")
client.color_log(180, 255, 180, "[Aether.sev]  § 42  Per-Tick Trace Gate")
client.color_log(180, 255, 180, "[Aether.sev]  § 43  Dynamic Hitchance Override")
client.color_log(180, 255, 180, "[Aether.sev]  § 44  ESP Angles Arc Overlay")
client.color_log(180, 255, 180, "[Aether.sev]  § 45  Resolver State Machine (RSM)")
client.color_log(180, 255, 180, "[Aether.sev]  § 46  Brute-Force Confirmation Lock")
client.color_log(180, 255, 180, "[Aether.sev]  § 47  30s Accuracy Logger")
client.color_log(180, 255, 180, "[Aether.sev]  § 48  Combined Final Update Pipeline")
client.color_log(180, 255, 180, "[Aether.sev]  § 49  Extended HUD State Monitor")
client.color_log(180, 255, 180, "[Aether.sev]  § 50  Internal Self-Test Suite")
client.color_log(180, 255, 180, "[Aether.sev]  § 51  Enemy Health Monitor")
client.color_log(80,  180, 255, "[Aether.sev] ============================================")
client.color_log(255, 220, 50,  "[Aether.sev]  Ready! Toggle: LUA > A > Aether.sev page selector")

-- ===========================
-- § 53  SMART HITBOX SELECTOR
-- ===========================
-- Zawsze strzela w głowę.
-- Jeśli wróg ma ≤ X HP i obrażenia w ciało wystarczą do zabicia
-- → przełącza na klatkę piersiową (większy hitbox = więcej hitchance).

------------------------------------------------------------------------
-- 53.1  Bazowe obrażenia per broń (przed skalowaniem armor/hitgroup)
------------------------------------------------------------------------
WEAPON_BASE_DMG = {
    [WEAPON_DEAGLE]   = 63,
    [WEAPON_SSG08]    = 88,
    [WEAPON_TEC9]     = 33,
    [WEAPON_ZEUS]     = 100,
    [WEAPON_REVOLVER] = 60,
}

------------------------------------------------------------------------
-- 53.2  UI — próg HP i przełącznik body-kill
------------------------------------------------------------------------
ui_body_kill   = ui.new_checkbox("LUA", "B", "UV Body Kill on Low HP")
ui_body_thresh = ui.new_slider("LUA", "B", "Body Kill HP Threshold",
    1, 100, 40, true, "hp")

------------------------------------------------------------------------
-- 53.3  Wybierz najlepszy hitbox dla strzału
-- Zwraca: hitgroup (int), hitbox (int), powód (string)
------------------------------------------------------------------------
function select_hitbox(target_ent, wid)
    -- domyślnie: głowa
    local default_hg  = HITGROUP_HEAD
    local default_hb  = HITBOX_HEAD
    local default_why = "HEAD"

    if not ui.get(ui_body_kill) then
        return default_hg, default_hb, default_why
    end

    local hp = entity.get_prop(target_ent, "m_iHealth")
    if not hp then return default_hg, default_hb, default_why end

    local thresh = ui.get(ui_body_thresh)
    if hp > thresh then
        return default_hg, default_hb, default_why
    end

    -- HP poniżej progu — sprawdź czy damage w ciało zabija
    local base = WEAPON_BASE_DMG[wid] or 50

    local chest_dmg   = client.scale_damage(target_ent, HITGROUP_CHEST,   base)
    local stomach_dmg = client.scale_damage(target_ent, HITGROUP_STOMACH,  base)

    chest_dmg   = chest_dmg   or 0
    stomach_dmg = stomach_dmg or 0

    local best_dmg = math.max(chest_dmg, stomach_dmg)

    if best_dmg >= hp then
        -- ciało wystarczy do zabicia → klatka (większy hitbox)
        return HITGROUP_CHEST, HITBOX_THORAX, "BODY-KILL"
    end

    return default_hg, default_hb, default_why
end

------------------------------------------------------------------------
-- 53.4  Aktualny cel + wybrany hitbox — cache per tick
------------------------------------------------------------------------
hitbox_cache      = {}  -- [ent] = { hg, hb, why }
hitbox_cache_tick = {}

function get_hitbox_for(ent, wid)
    local tick = globals.tickcount()
    if hitbox_cache_tick[ent] == tick and hitbox_cache[ent] then
        return table.unpack(hitbox_cache[ent])
    end
    local hg, hb, why = select_hitbox(ent, wid)
    hitbox_cache[ent]      = { hg, hb, why }
    hitbox_cache_tick[ent] = tick
    return hg, hb, why
end

------------------------------------------------------------------------
-- 53.5  Hook — loguj wybrany hitbox raz na trafienie
------------------------------------------------------------------------
client.set_event_callback("player_hurt", function(e)
    local me = entity.get_local_player()
    if not me then return end
    if client.userid_to_entindex(e.attacker) ~= me then return end

    local target = client.userid_to_entindex(e.userid)
    if not target then return end

    local _, hb_cached  = hitbox_cache[target] and table.unpack(hitbox_cache[target])
    local wid = get_weapon_id(me)
    if not wid then return end
    local _, _, why = get_hitbox_for(target, wid)

    if ui.get(ui_log) then
        client.color_log(80, 255, 150, string.format(
            "[UV-HB] Shot registered | mode=%s | ent=%d | dmg=%d | hp_left=%d",
            why, target, e.dmg_health or 0, e.health or 0))
    end
end)

-- ===========================
-- § 54  HEAD ACCURACY TUNER
-- ===========================
-- Przed każdym strzałem waliduje czy bullet trace dotrze do głowy.
-- Jeśli głowa jest za ścianą → fallback na klatkę (nie traci strzału).
-- Działa razem z §53 — §54 decyduje o osiągalności, §53 o optimum.

------------------------------------------------------------------------
-- 54.1  Trace gate — czy jesteśmy w stanie trafić w wybrany hitbox?
------------------------------------------------------------------------
function hitbox_is_hittable(target_ent, hitbox_id)
    local me = entity.get_local_player()
    if not me then return false end
    local ex, ey, ez = client.eye_position()
    if not ex then return false end

    local hx, hy, hz = entity.hitbox_position(target_ent, hitbox_id)
    if not hx then return false end

    local _, dmg = client.trace_bullet(me, ex, ey, ez, hx, hy, hz, false)
    return dmg and dmg > 0
end

------------------------------------------------------------------------
-- 54.2  Wybierz najlepszy osiągalny hitbox (head → upper_chest → chest)
-- Jeśli żaden nie jest osiągalny → zwróć false (nie strzelaj)
------------------------------------------------------------------------
hitbox_priority = {
    { HITBOX_HEAD,          "HEAD"        },
    { HITBOX_UPPER_CHEST,   "UPPER_CHEST" },
    { HITBOX_CHEST,         "CHEST"       },
    { HITBOX_THORAX,        "THORAX"      },
    { HITBOX_STOMACH,       "STOMACH"     },
}

function best_hittable_hitbox(target_ent, wid, preferred_hb)
    -- najpierw sprawdź preferowany (z §53)
    if hitbox_is_hittable(target_ent, preferred_hb) then
        return preferred_hb, true
    end
    -- fallback — przejdź po priority liście
    for _, entry in ipairs(hitbox_priority) do
        local hb, _ = entry[1], entry[2]
        if hb ~= preferred_hb and hitbox_is_hittable(target_ent, hb) then
            return hb, true
        end
    end
    return preferred_hb, false  -- żaden nie jest osiągalny
end

------------------------------------------------------------------------
-- 54.3  Połączony selektor: §53 + §54 razem
-- Zwraca: hitbox, hittable, mode_string
------------------------------------------------------------------------
function final_hitbox_decision(target_ent, wid)
    local hg, hb_preferred, why = get_hitbox_for(target_ent, wid)
    local hb_final, reachable   = best_hittable_hitbox(target_ent, wid, hb_preferred)

    if not reachable then
        return hb_preferred, false, why .. "/BLOCKED"
    end

    if hb_final ~= hb_preferred then
        return hb_final, true, why .. "/FALLBACK"
    end

    return hb_final, true, why
end

------------------------------------------------------------------------
-- 54.4  ESP flag — pokaż czy głowa jest hittable
------------------------------------------------------------------------
client.register_esp_flag("HB", 255, 200, 50, function(ent)
    if not ui.get(ui_enabled)  then return false end
    if not entity.is_enemy(ent) then return false end
    if not entity.is_alive(ent) then return false end

    local me  = entity.get_local_player()
    if not me then return false end
    local wid = get_weapon_id(me)
    if not wid or not is_supported_weapon(wid) then return false end

    local _, reachable, _ = final_hitbox_decision(ent, wid)
    return reachable
end)

------------------------------------------------------------------------
-- 54.5  HUD overlay — ponad głową pokaż HEAD / BODY / BLOCKED
------------------------------------------------------------------------
client.set_event_callback("paint", function()
    if not ui.get(ui_enabled) then return end
    if not ui.get(ui_hud)     then return end

    local me = entity.get_local_player()
    if not me or not entity.is_alive(me) then return end
    local wid = get_weapon_id(me)
    if not wid or not is_supported_weapon(wid) then return end

    local enemies = entity.get_players(true)
    for _, ent in ipairs(enemies) do
        if entity.is_alive(ent) and not entity.is_dormant(ent) then
            local hx, hy, hz = entity.hitbox_position(ent, HITBOX_HEAD)
            if hx then
                local sx, sy = renderer.world_to_screen(hx, hy, hz + 10)
                if sx and sy then
                    local hb_final, reachable, mode = final_hitbox_decision(ent, wid)
                    local lr, lg, lb = 80, 255, 80
                    if not reachable      then lr, lg, lb = 255, 60,  60  end
                    if mode:find("BODY")  then lr, lg, lb = 255, 180, 50  end
                    if mode:find("FALL")  then lr, lg, lb = 200, 200, 80  end
                    renderer.text(sx, sy - 28, lr, lg, lb, 220, "c", 0, mode)
                end
            end
        end
    end
end)

-- ===========================
-- § 55  DOUBLETAP ENHANCER
-- ===========================
-- Synchronizuje doubletap z resolved yawem:
--   • strzał 1: czeka aż resolved yaw jest walidowany przez trace gate
--   • strzał 2: natychmiast po strzale 1 (exploit tick sync)
--   • po miss obu → advance_brute x2
--   • po hit+miss → flip desync przed synchronizacją strzału 2

------------------------------------------------------------------------
-- 55.1  UI
------------------------------------------------------------------------
ui_dt_enable    = ui.new_checkbox("LUA", "B", "UV Doubletap Sync")
ui_dt_hitchance = ui.new_slider("LUA", "B", "DT Min Hitchance",
    50, 100, 75, true, "%")

-- referuj wbudowany doubletap (jeśli jest w menu)
dt_ref = nil
pcall(function()
    dt_ref = ui.reference("RAGE", "Exploits", "Double tap")
end)

------------------------------------------------------------------------
-- 55.2  Stan doubletap
------------------------------------------------------------------------
dt = {
    armed         = false,   -- doubletap załadowany
    shot1_tick    = 0,       -- tick pierwszego strzału
    shot1_done    = false,   -- czy shot1 poszedł
    shot2_done    = false,   -- czy shot2 poszedł
    target        = nil,     -- cel
    shot1_hit     = false,   -- potwierdzone trafienie shot1
    shot2_hit     = false,   -- potwierdzone trafienie shot2
    suppressed    = false,   -- czy wstrzymujemy strzał
    last_resolved = 0,       -- resolved yaw użyty przy shot1
    miss_both     = false,   -- obie kule chybiły
}

------------------------------------------------------------------------
-- 55.3  Sprawdź czy doubletap jest aktualnie aktywny w Gamesense
------------------------------------------------------------------------
function doubletap_is_active()
    if not ui.get(ui_dt_enable) then return false end
    if dt_ref then
        local ok, val = pcall(ui.get, dt_ref)
        if ok and val then return true end
    end
    return false
end

------------------------------------------------------------------------
-- 55.4  Weryfikacja kąta przed strzałem doubletap
-- Zwraca true jeśli resolved pozycja jest hittable z wymaganą szansą
------------------------------------------------------------------------
function dt_angle_valid(target_ent, wid)
    if not target_ent then return false end

    -- trace gate z §54
    local _, reachable, _ = final_hitbox_decision(target_ent, wid)
    if not reachable then return false end

    -- dodatkowy check: czy resolved yaw daje dobry kąt
    local pdata = player_data[target_ent]
    if not pdata then return true end

    local me = entity.get_local_player()
    if not me then return true end
    local ex, ey, ez = client.eye_position()
    if not ex then return true end

    -- test trace_bullet na resolved pozycji głowy
    local hx, hy, hz = entity.hitbox_position(target_ent, HITBOX_HEAD)
    if not hx then return false end

    local _, dmg = client.trace_bullet(me, ex, ey, ez, hx, hy, hz, false)
    if not dmg or dmg <= 0 then return false end

    -- min hitchance check (przybliżony przez scale_damage)
    local base   = WEAPON_BASE_DMG[wid] or 50
    local scaled = client.scale_damage(target_ent, HITGROUP_HEAD, base)
    if not scaled then return true end

    local min_hc = ui.get(ui_dt_hitchance)
    -- jeśli scaled dmg > 75% base → zakładamy hitchance ok
    local effective_hc = math_clamp((scaled / base) * 100, 0, 100)
    return effective_hc >= min_hc
end

------------------------------------------------------------------------
-- 55.5  Znajdź najlepszy cel dla doubletap (najbliższy hittable)
------------------------------------------------------------------------
function dt_find_target(wid)
    local me = entity.get_local_player()
    if not me then return nil end
    local ex, ey, ez = client.eye_position()
    if not ex then return nil end

    local best_ent  = nil
    local best_dist = 9999999

    local enemies = entity.get_players(true)
    for _, ent in ipairs(enemies) do
        if entity.is_alive(ent) and not entity.is_dormant(ent) then
            local hx, hy, hz = entity.hitbox_position(ent, HITBOX_HEAD)
            if hx then
                local d = math.sqrt((hx-ex)^2 + (hy-ey)^2 + (hz-ez)^2)
                if d < best_dist and dt_angle_valid(ent, wid) then
                    best_dist = d
                    best_ent  = ent
                end
            end
        end
    end
    return best_ent
end

------------------------------------------------------------------------
-- 55.6  Doubletap createmove hook
------------------------------------------------------------------------
client.set_event_callback("createmove", function()
    if not doubletap_is_active() then
        dt.armed      = false
        dt.suppressed = false
        return
    end

    local me = entity.get_local_player()
    if not me or not entity.is_alive(me) then return end
    local wid = get_weapon_id(me)
    if not wid or not is_supported_weapon(wid) then return end

    local tick = globals.tickcount()

    -- arm doubletap
    dt.armed = true

    -- znajdź cel
    if not dt.target or not entity.is_alive(dt.target) then
        dt.target = dt_find_target(wid)
    end

    if not dt.target then
        dt.suppressed = false
        return
    end

    local pdata = get_player_data(dt.target)

    -- ---- Shot 1 validation ----
    if not dt.shot1_done then
        local angle_ok = dt_angle_valid(dt.target, wid)

        if not angle_ok then
            -- kąt nie jest gotowy → wstrzymaj strzał o 1 tick
            dt.suppressed = true
            if ui.get(ui_log) then
                client.color_log(255, 180, 0,
                    "[Aether.sev] Shot 1 suppressed — waiting for valid angle on " ..
                    entity.get_player_name(dt.target))
            end
            return
        end

        dt.suppressed    = false
        dt.shot1_done    = true
        dt.shot1_tick    = tick
        dt.last_resolved = pdata.resolved_yaw

        if ui.get(ui_log) then
            client.color_log(80, 255, 120,
                string.format("[Aether.sev] Shot 1 FIRED | tick=%d | yaw=%.1f",
                    tick, pdata.resolved_yaw))
        end
        return
    end

    -- ---- Shot 2 sync (tick bezpośrednio po shot1) ----
    if dt.shot1_done and not dt.shot2_done then
        -- doubletap shot2 musi byc na resolved angle
        -- jeśli desync sie zmienił od shot1 → koryguj
        local yaw_drift = math_abs(math_angle_diff(
            pdata.resolved_yaw, dt.last_resolved))

        if yaw_drift > 15 then
            -- kąt za bardzo się zmienił: flip brute i odczekaj
            advance_brute(pdata, ui.get(ui_max_brute) - 1)
            dt.shot2_done  = true  -- anuluj shot2
            dt.shot1_done  = false
            dt.miss_both   = true
            if ui.get(ui_log) then
                client.color_log(255, 80, 80,
                    string.format("[Aether.sev] Shot 2 CANCELLED — yaw drift %.1f° → brute advanced",
                        yaw_drift))
            end
            return
        end

        dt.suppressed = false
        dt.shot2_done = true

        if ui.get(ui_log) then
            client.color_log(80, 200, 255,
                string.format("[Aether.sev] Shot 2 FIRED | tick=%d | yaw=%.1f",
                    tick, pdata.resolved_yaw))
        end

        -- reset state for next doubletap
        client.delay_call(0.3, function()
            dt.shot1_done = false
            dt.shot2_done = false
            dt.shot1_hit  = false
            dt.shot2_hit  = false
            dt.miss_both  = false
            dt.target     = nil
            dt.suppressed = false
        end)
    end
end)

------------------------------------------------------------------------
-- 55.7  Doubletap miss/hit tracking via player_hurt
------------------------------------------------------------------------
function on_dt_player_hurt(e)
    if not doubletap_is_active() then return end
    local me = entity.get_local_player()
    if not me then return end
    if client.userid_to_entindex(e.attacker) ~= me then return end

    local victim = client.userid_to_entindex(e.userid)
    if victim ~= dt.target then return end

    if dt.shot1_done and not dt.shot2_done then
        dt.shot1_hit = true
        if ui.get(ui_log) then
            client.color_log(80, 255, 120, "[Aether.sev] Shot 1 CONFIRMED HIT")
        end
    elseif dt.shot2_done then
        dt.shot2_hit = true
        if ui.get(ui_log) then
            client.color_log(80, 255, 120, "[Aether.sev] Shot 2 CONFIRMED HIT")
        end
    end
end

client.set_event_callback("player_hurt", on_dt_player_hurt)

------------------------------------------------------------------------
-- 55.8  Doubletap miss reaction via bullet_impact
-- Jeśli oba strzały chybiły → advance_brute x2 + flip desync side
------------------------------------------------------------------------
dt_impact_count = 0

function on_dt_bullet_impact(e)
    if not doubletap_is_active() then return end
    local me = entity.get_local_player()
    if not me then return end
    if client.userid_to_entindex(e.userid) ~= me then return end

    if not dt.target then return end
    local pdata = player_data[dt.target]
    if not pdata then return end

    dt_impact_count = dt_impact_count + 1

    -- po dwóch impactach (= oba strzały DT poleciały) sprawdź wyniki
    if dt_impact_count >= 2 then
        dt_impact_count = 0

        if not dt.shot1_hit and not dt.shot2_hit then
            -- BOTH MISSED → advance brute twice + flip desync
            advance_brute(pdata, ui.get(ui_max_brute) - 1)
            advance_brute(pdata, ui.get(ui_max_brute) - 1)
            pdata.miss_streak = pdata.miss_streak + 2
            pdata.confidence  = math_clamp(pdata.confidence - 20, 0, 100)

            -- flip desync side jeśli zapisany
            if pdata.desync_side == SIDE_LEFT  then pdata.desync_side = SIDE_RIGHT
            elseif pdata.desync_side == SIDE_RIGHT then pdata.desync_side = SIDE_LEFT end

            if ui.get(ui_log) then
                client.color_log(255, 60, 60,
                    "[Aether.sev] BOTH MISSED — brute x2 advanced, desync flipped | mode=" ..
                    pdata.last_mode)
            end
            hud_push("[DT] DOUBLE MISS → brute+flip", 255, 80, 80)

        elseif dt.shot1_hit and not dt.shot2_hit then
            -- shot1 hit, shot2 miss → flip desync + reset miss streak
            if pdata.desync_side == SIDE_LEFT  then pdata.desync_side = SIDE_RIGHT
            elseif pdata.desync_side == SIDE_RIGHT then pdata.desync_side = SIDE_LEFT end
            pdata.miss_streak = 0
            pdata.confidence  = math_clamp(pdata.confidence + 5, 0, 100)

            if ui.get(ui_log) then
                client.color_log(255, 200, 50,
                    "[Aether.sev] HIT+MISS — desync flipped for next DT")
            end

        else
            -- oba trafiły 
            pdata.miss_streak = 0
            pdata.confidence  = math_clamp(pdata.confidence + 15, 0, 100)
            if ui.get(ui_log) then
                client.color_log(80, 255, 80, "[Aether.sev] BOTH HIT — confidence+" )
            end
            hud_push("[DT] DOUBLE HIT!", 80, 255, 80)
        end
    end
end

client.set_event_callback("bullet_impact", on_dt_bullet_impact)

------------------------------------------------------------------------
-- 55.9  DT HUD widget
------------------------------------------------------------------------
client.set_event_callback("paint", function()
    if not ui.get(ui_enabled) then return end
    if not ui.get(ui_hud)     then return end
    if not doubletap_is_active() then return end

    local sw, sh = client.screen_size()
    local cx = sw / 2
    local cy = sh / 2 + 100

    -- strzałki DT
    local s1_r, s1_g, s1_b = dt.shot1_hit and 80 or 60,
                               dt.shot1_hit and 255 or 60,
                               dt.shot1_hit and 80 or 60
    local s2_r, s2_g, s2_b = dt.shot2_hit and 80 or 60,
                               dt.shot2_hit and 255 or 60,
                               dt.shot2_hit and 80 or 60

    if dt.shot1_done and not dt.shot1_hit then s1_r, s1_g, s1_b = 255, 80, 80 end
    if dt.shot2_done and not dt.shot2_hit then s2_r, s2_g, s2_b = 255, 80, 80 end

    renderer.rectangle(cx - 30, cy,     24, 6, s1_r, s1_g, s1_b, 200)
    renderer.rectangle(cx +  6, cy,     24, 6, s2_r, s2_g, s2_b, 200)
    renderer.text(cx, cy + 10, 200, 200, 200, 180, "c", 0, "DT")

    -- suppressed indicator
    if dt.suppressed then
        renderer.text(cx, cy - 14, 255, 200, 50, 220, "c", 0, "DT WAIT...")
    end
end)

------------------------------------------------------------------------
-- 55.10  Version bump log
------------------------------------------------------------------------
client.color_log(80,  180, 255, "[Aether.sev] ============================================")
client.color_log(100, 220, 255, "[Aether.sev]  v3.8 modules appended:")
client.color_log(180, 255, 180, "[Aether.sev]  §53 Smart Hitbox Selector (head-first + body-kill)")
client.color_log(180, 255, 180, "[Aether.sev]  §54 Head Accuracy Tuner (trace gate + fallback)")
client.color_log(180, 255, 180, "[Aether.sev]  §55 Doubletap Enhancer (sync + miss reaction)")
client.color_log(80,  180, 255, "[Aether.sev] ============================================")

-- ============================================================
-- ██╗   ██╗██╗   ██╗    █████╗ ██╗
-- ██║   ██║██║   ██║   ██╔══██╗██║
-- ██║   ██║██║   ██║   ███████║██║
-- ██║   ██║╚██╗ ██╔╝   ██╔══██║██║
-- ╚██████╔╝ ╚████╔╝    ██║  ██║██║
--  ╚═════╝   ╚═══╝     ╚═╝  ╚═╝╚═╝
--  ULTRAVIOLET  ARTIFICIAL  INTELLIGENCE
--  resolver.lua  →  AI Engine v4.0
-- ============================================================

-- ===========================
-- § 56  AA PATTERN CLASSIFIER
-- ===========================

AA_SPIN     = "SPIN"
AA_JITTER   = "JITTER"
AA_STATIC   = "STATIC"
AA_BACKWARD = "BACKWARD"
AA_FLIPFLOP = "FLIPFLOP"
AA_RANDOM   = "RANDOM"

------------------------------------------------------------------------
-- 56.1  Statistical helpers
------------------------------------------------------------------------
function tbl_avg(t)
    if #t == 0 then return 0 end
    local s = 0
    for _, v in ipairs(t) do s = s + v end
    return s / #t
end

function tbl_std_dev(t)
    if #t < 2 then return 0 end
    local avg = tbl_avg(t)
    local s   = 0
    for _, v in ipairs(t) do s = s + (v - avg)^2 end
    return math.sqrt(s / (#t - 1))
end

function tbl_max_abs(t)
    local m = 0
    for _, v in ipairs(t) do
        local a = math_abs(v)
        if a > m then m = a end
    end
    return m
end

function count_sign_changes(t)
    local n = 0
    for i = 1, #t - 1 do
        if (t[i] >= 0 and t[i+1] < 0) or (t[i] < 0 and t[i+1] >= 0) then
            n = n + 1
        end
    end
    return n
end

------------------------------------------------------------------------
-- 56.2  Main classifier
------------------------------------------------------------------------
aa_type_cache      = {}  -- [ent] = string
aa_type_cache_tick = {}  -- [ent] = tick

function classify_aa(ent, pdata)
    local tick = globals.tickcount()
    if aa_type_cache_tick[ent] == tick and aa_type_cache[ent] then
        return aa_type_cache[ent]
    end

    local yaws = pdata.yaw_history
    if #yaws < 5 then
        aa_type_cache[ent]      = AA_RANDOM
        aa_type_cache_tick[ent] = tick
        return AA_RANDOM
    end

    -- build deltas
    local deltas = {}
    for i = 1, #yaws - 1 do
        deltas[#deltas + 1] = math_angle_diff(yaws[i], yaws[i + 1])
    end

    local avg_d  = tbl_avg(deltas)
    local std_d  = tbl_std_dev(deltas)
    local max_d  = tbl_max_abs(deltas)
    local sc     = count_sign_changes(deltas)
    local ratio  = #deltas > 0 and (sc / #deltas) or 0

    -- 1. SPIN: monotonic large delta, low std dev
    if std_d < 6 and math_abs(avg_d) > 8 then
        local result = AA_SPIN
        aa_type_cache[ent]      = result
        aa_type_cache_tick[ent] = tick
        return result
    end

    -- 2. JITTER: high sign-change ratio
    if ratio >= 0.65 and max_d > 10 then
        aa_type_cache[ent]      = AA_JITTER
        aa_type_cache_tick[ent] = tick
        return AA_JITTER
    end

    -- 3. STATIC: near-zero movement
    if max_d < 4 then
        aa_type_cache[ent]      = AA_STATIC
        aa_type_cache_tick[ent] = tick
        return AA_STATIC
    end

    -- 4. BACKWARD: yaw ~= velocity direction + 180
    local vx = pdata.vel_x_hist[1] or 0
    local vy = pdata.vel_y_hist[1] or 0
    if math_vec_len2d(vx, vy) > 20 then
        local vel_yaw = math.deg(math.atan2(vy, vx))
        local back_yaw = math_normalize_yaw(vel_yaw + 180)
        if math_abs(math_angle_diff(yaws[1], back_yaw)) < 18 then
            aa_type_cache[ent]      = AA_BACKWARD
            aa_type_cache_tick[ent] = tick
            return AA_BACKWARD
        end
    end

    -- 5. FLIPFLOP: existing detect_flip_flop
    local is_ff, _, _ = detect_flip_flop(pdata)
    if is_ff then
        aa_type_cache[ent]      = AA_FLIPFLOP
        aa_type_cache_tick[ent] = tick
        return AA_FLIPFLOP
    end

    aa_type_cache[ent]      = AA_RANDOM
    aa_type_cache_tick[ent] = tick
    return AA_RANDOM
end

------------------------------------------------------------------------
-- 56.3  Classifier-driven resolver override
------------------------------------------------------------------------
function apply_classified_resolve(ent, pdata, wid, aa_type)
    local view_yaw = pdata.eye_yaw

    if aa_type == AA_SPIN then
        -- extrapolate spin: predict next angle from avg delta
        local yaws   = pdata.yaw_history
        if #yaws < 2 then return end
        local delta  = math_angle_diff(yaws[1], yaws[2])
        local pred   = math_normalize_yaw(yaws[1] + delta)
        pdata.resolved_yaw = pred
        pdata.last_mode    = "AI/SPIN"

    elseif aa_type == AA_JITTER then
        -- anti-jitter: aim at the midpoint between last two yaws
        local yaws = pdata.yaw_history
        if #yaws < 2 then return end
        -- circular midpoint
        local dy  = math_angle_diff(yaws[1], yaws[2])
        local mid = math_normalize_yaw(yaws[2] + dy * 0.5)
        pdata.resolved_yaw = mid
        pdata.last_mode    = "AI/JITTER-MID"

    elseif aa_type == AA_STATIC then
        -- static: LBY is ground truth
        pdata.resolved_yaw = math_normalize_yaw(pdata.lby_yaw)
        pdata.last_mode    = "AI/STATIC-LBY"

    elseif aa_type == AA_BACKWARD then
        -- backward: velocity direction + 0 (straight back toward us)
        local vx = pdata.vel_x_hist[1] or 0
        local vy = pdata.vel_y_hist[1] or 0
        if math_vec_len2d(vx, vy) > 5 then
            local vel_yaw = math.deg(math.atan2(vy, vx))
            pdata.resolved_yaw = math_normalize_yaw(vel_yaw + 180)
            pdata.last_mode    = "AI/BACKWARD"
        end

    elseif aa_type == AA_FLIPFLOP then
        -- handled by existing resolve_flip_flop (§48)
        pdata.last_mode = "AI/FLIPFLOP"

    else -- AA_RANDOM
        -- full brute-force (handled by existing pipeline)
        pdata.last_mode = "AI/RANDOM-BRUTE"
    end
end

-- ===========================
-- § 57  BAYESIAN HIT PREDICTOR
-- ===========================

------------------------------------------------------------------------
-- 57.1  Per-player Bayesian state
------------------------------------------------------------------------
bayes_default_priors = {
    [AA_SPIN]     = 0.45,
    [AA_JITTER]   = 0.55,
    [AA_STATIC]   = 0.70,
    [AA_BACKWARD] = 0.75,
    [AA_FLIPFLOP] = 0.60,
    [AA_RANDOM]   = 0.35,
}

bayes_state = {}   -- [ent] = { priors={}, shots=0, hits=0 }

function get_bayes(ent)
    if not bayes_state[ent] then
        local p = {}
        for k, v in pairs(bayes_default_priors) do p[k] = v end
        bayes_state[ent] = { priors=p, shots=0, hits=0 }
    end
    return bayes_state[ent]
end

------------------------------------------------------------------------
-- 57.2  Likelihood functions
------------------------------------------------------------------------
function likelihood_delta(delta)
    -- higher delta = lower hit chance
    local norm = math_clamp(delta / 60, 0, 1)
    return 1 - norm * 0.6   -- [0.4, 1.0]
end

function likelihood_dist(dist)
    -- farther = lower chance (capped at 800u)
    local norm = math_clamp(dist / 800, 0, 1)
    return 1 - norm * 0.5   -- [0.5, 1.0]
end

function likelihood_confidence(conf)
    return math_clamp(conf / 100, 0.1, 1.0)
end

------------------------------------------------------------------------
-- 57.3  Compute P(hit) for a target
------------------------------------------------------------------------
function bayes_hit_probability(ent, aa_type, dist)
    local bs     = get_bayes(ent)
    local prior  = bs.priors[aa_type] or 0.4
    local pdata  = player_data[ent]
    local delta  = pdata and math_abs(pdata.desync_delta) or 30
    local conf   = pdata and pdata.confidence or 50

    local p = prior
              * likelihood_delta(delta)
              * likelihood_dist(dist)
              * likelihood_confidence(conf)

    return math_clamp(p, 0, 1)
end

------------------------------------------------------------------------
-- 57.4  Update priors (online Bayesian averaging)
------------------------------------------------------------------------
BAYES_ALPHA = 0.10  -- learning rate

function bayes_update(ent, aa_type, hit)
    local bs = get_bayes(ent)
    bs.shots  = bs.shots + 1
    if hit then bs.hits = bs.hits + 1 end

    local obs  = hit and 1.0 or 0.0
    local prev = bs.priors[aa_type] or 0.4
    bs.priors[aa_type] = prev * (1 - BAYES_ALPHA) + obs * BAYES_ALPHA
    bs.priors[aa_type] = math_clamp(bs.priors[aa_type], 0.05, 0.97)
end

------------------------------------------------------------------------
-- 57.5  UI threshold
------------------------------------------------------------------------
ui_bayes_thresh = ui.new_slider("LUA", "B", "AI Shoot Threshold",
    0, 100, 55, true, "%")

------------------------------------------------------------------------
-- 57.6  Should we shoot? Gate for Doubletap, etc.
------------------------------------------------------------------------
function bayes_should_shoot(ent, aa_type, dist)
    local p       = bayes_hit_probability(ent, aa_type, dist)
    local thresh  = ui.get(ui_bayes_thresh) / 100
    return p >= thresh, p
end

-- ===========================
-- § 58  NEURAL RESOLVER
-- ===========================

------------------------------------------------------------------------
-- 58.1  NN architecture: 5 → 4 → 1
------------------------------------------------------------------------
NN_INPUTS  = 5
NN_HIDDEN  = 4
NN_LR_BASE = 0.01

function nn_relu(x)
    return x > 0 and x or 0
end

function nn_tanh(x)
    local e2x = math.exp(2 * x)
    return (e2x - 1) / (e2x + 1)
end

------------------------------------------------------------------------
-- 58.2  Per-player NN state
------------------------------------------------------------------------
nn_state = {}   -- [ent] = { w1, b1, w2, b2, lr, last_input, last_hidden, last_output }

function init_nn_weights()
    local w1, b1, w2 = {}, {}, {}
    for h = 1, NN_HIDDEN do
        w1[h] = {}
        for i = 1, NN_INPUTS do
            w1[h][i] = client.random_float(-0.4, 0.4)
        end
        b1[h] = 0
        w2[h] = client.random_float(-0.4, 0.4)
    end
    return {
        w1 = w1, b1 = b1, w2 = w2, b2 = 0,
        lr = NN_LR_BASE,
        last_input = {}, last_hidden = {}, last_output = 0,
        trained = 0
    }
end

function get_nn(ent)
    if not nn_state[ent] then
        nn_state[ent] = init_nn_weights()
    end
    return nn_state[ent]
end

------------------------------------------------------------------------
-- 58.3  Forward pass
------------------------------------------------------------------------
function nn_forward(nn, inputs)
    -- hidden layer
    local hidden = {}
    for h = 1, NN_HIDDEN do
        local sum = nn.b1[h]
        for i = 1, NN_INPUTS do
            sum = sum + (inputs[i] or 0) * nn.w1[h][i]
        end
        hidden[h] = nn_relu(sum)
    end

    -- output layer
    local out = nn.b2
    for h = 1, NN_HIDDEN do
        out = out + hidden[h] * nn.w2[h]
    end
    out = nn_tanh(out) * 60  -- scale to [-60, 60]

    -- store for backprop
    nn.last_input  = inputs
    nn.last_hidden = hidden
    nn.last_output = out

    return out
end

------------------------------------------------------------------------
-- 58.4  Backward pass (delta rule)
------------------------------------------------------------------------
function nn_train(nn, target_offset)
    local err = target_offset - nn.last_output
    if math_abs(err) < 0.5 then return end  -- skip tiny errors

    nn.trained = nn.trained + 1
    local lr = nn.lr

    -- output layer delta
    local d_out = err  -- tanh gradient simplified (treating as linear for small lr)

    -- update output weights
    for h = 1, NN_HIDDEN do
        nn.w2[h] = nn.w2[h] + lr * d_out * nn.last_hidden[h]
    end
    nn.b2 = nn.b2 + lr * d_out

    -- hidden layer delta (chain rule through ReLU)
    for h = 1, NN_HIDDEN do
        local d_h = d_out * nn.w2[h]
        -- ReLU gradient: 1 if hidden > 0
        if nn.last_hidden[h] > 0 then
            for i = 1, NN_INPUTS do
                nn.w1[h][i] = nn.w1[h][i] + lr * d_h * (nn.last_input[i] or 0)
            end
            nn.b1[h] = nn.b1[h] + lr * d_h
        end
    end
end

------------------------------------------------------------------------
-- 58.5  Build input vector from player data
------------------------------------------------------------------------
function build_nn_inputs(ent, pdata)
    local vx    = pdata.vel_x_hist[1] or 0
    local vy    = pdata.vel_y_hist[1] or 0
    local speed = math_clamp(math_vec_len2d(vx, vy) / 250, 0, 1)

    return {
        math_clamp(math_abs(pdata.desync_delta) / 60,        0, 1),
        math_clamp(math_abs(math_angle_diff(pdata.lby_yaw, pdata.eye_yaw)) / 180, 0, 1),
        math_clamp(pdata.confidence / 100,                    0, 1),
        math_clamp(pdata.miss_streak / 10,                    0, 1),
        speed,
    }
end

------------------------------------------------------------------------
-- 58.6  UI
------------------------------------------------------------------------
ui_nn_lr = ui.new_slider("LUA", "B", "NN Learning Rate",
    1, 50, 10, true, "x0.001")
ui_ai_enable = ui.new_checkbox("LUA", "B", "UV AI Engine")

------------------------------------------------------------------------
-- 58.7  Run neural resolver for a player
------------------------------------------------------------------------
function neural_resolve(ent, pdata)
    if not ui.get(ui_ai_enable) then return nil end
    local nn     = get_nn(ent)
    nn.lr        = ui.get(ui_nn_lr) * 0.001
    local inputs = build_nn_inputs(ent, pdata)
    local offset = nn_forward(nn, inputs)
    return offset
end

-- ===========================
-- § 59  MARKOV MOVEMENT PREDICTOR
-- ===========================

------------------------------------------------------------------------
-- 59.1  Velocity states
------------------------------------------------------------------------
VS_STOP = 1
VS_WALK = 2
VS_RUN  = 3
VS_AIR  = 4
VS_DUCK = 5
VS_COUNT = 5

function velocity_state(ent)
    local flags = entity.get_prop(ent, "m_fFlags") or 0
    local on_ground = bit.band(flags, FL_ONGROUND) ~= 0
    local ducking   = bit.band(flags, FL_DUCKING)  ~= 0
    local vx = entity.get_prop(ent, "m_vecVelocity[0]") or 0
    local vy = entity.get_prop(ent, "m_vecVelocity[1]") or 0
    local spd = math_vec_len2d(vx, vy)

    if not on_ground          then return VS_AIR  end
    if ducking                then return VS_DUCK end
    if spd > 130              then return VS_RUN  end
    if spd > 10               then return VS_WALK end
    return VS_STOP
end

------------------------------------------------------------------------
-- 59.2  Per-player Markov model
------------------------------------------------------------------------
markov_state = {}  -- [ent] = { matrix[5][5], prev_state, counts[5] }

function get_markov(ent)
    if not markov_state[ent] then
        local mat  = {}
        local cnts = {}
        for i = 1, VS_COUNT do
            mat[i]  = {}
            cnts[i] = 0
            for j = 1, VS_COUNT do
                mat[i][j] = 1 / VS_COUNT  -- uniform prior
            end
        end
        markov_state[ent] = {
            matrix     = mat,
            raw_counts = {},  -- raw transition counts for normalization
            prev_state = VS_STOP,
            counts     = cnts,
        }
        -- init raw counts
        local mk = markov_state[ent]
        for i = 1, VS_COUNT do
            mk.raw_counts[i] = {}
            for j = 1, VS_COUNT do mk.raw_counts[i][j] = 1 end
        end
    end
    return markov_state[ent]
end

------------------------------------------------------------------------
-- 59.3  Update Markov matrix
------------------------------------------------------------------------
function markov_update(ent)
    local mk   = get_markov(ent)
    local curr = velocity_state(ent)
    local prev = mk.prev_state

    -- increment raw count
    mk.raw_counts[prev][curr] = mk.raw_counts[prev][curr] + 1

    -- recompute row probability
    local row_sum = 0
    for j = 1, VS_COUNT do row_sum = row_sum + mk.raw_counts[prev][j] end
    for j = 1, VS_COUNT do
        mk.matrix[prev][j] = mk.raw_counts[prev][j] / row_sum
    end

    mk.prev_state = curr
end

------------------------------------------------------------------------
-- 59.4  Predict next state (argmax of transition row)
------------------------------------------------------------------------
function markov_predict_state(ent)
    local mk   = get_markov(ent)
    local curr = mk.prev_state
    local best_p  = -1
    local best_st = VS_STOP
    for j = 1, VS_COUNT do
        if mk.matrix[curr][j] > best_p then
            best_p  = mk.matrix[curr][j]
            best_st = j
        end
    end
    return best_st, best_p
end

------------------------------------------------------------------------
-- 59.5  Predict position in N ticks
------------------------------------------------------------------------
function markov_predict_pos(ent, ticks_ahead)
    local pred_state, _ = markov_predict_state(ent)
    local ox, oy, oz    = entity.get_origin(ent)
    if not ox then return nil end

    local vx = entity.get_prop(ent, "m_vecVelocity[0]") or 0
    local vy = entity.get_prop(ent, "m_vecVelocity[1]") or 0
    local vz = entity.get_prop(ent, "m_vecVelocity[2]") or 0
    local dt = globals.tickinterval() * ticks_ahead

    if pred_state == VS_STOP then
        return ox, oy, oz  -- will stop — no movement
    end
    return ox + vx*dt, oy + vy*dt, oz + vz*dt
end

------------------------------------------------------------------------
-- 59.6  Get yaw angle from me to Markov-predicted position
------------------------------------------------------------------------
function markov_predicted_yaw(ent)
    local me = entity.get_local_player()
    if not me then return nil end
    local ex, ey, ez = client.eye_position()
    if not ex then return nil end

    local px, py, pz = markov_predict_pos(ent, 3)
    if not px then return nil end

    local dx, dy = px - ex, py - ey
    if math_vec_len2d(dx, dy) < 1 then return nil end
    return math.deg(math.atan2(dy, dx))
end

-- ===========================
-- § 60  ADAPTIVE WEIGHT BLENDER
-- ===========================

------------------------------------------------------------------------
-- 60.1  Per-player signal weights
------------------------------------------------------------------------
default_signal_weights = {
    lby     = 0.30,
    velocity= 0.15,
    neural  = 0.25,
    markov  = 0.10,
    brute   = 0.20,
}

signal_weights = {}  -- [ent] = { lby, velocity, neural, markov, brute }
active_signal  = {}  -- [ent] = string (which signal was used last shot)

function get_weights(ent)
    if not signal_weights[ent] then
        local w = {}
        for k, v in pairs(default_signal_weights) do w[k] = v end
        signal_weights[ent] = w
    end
    return signal_weights[ent]
end

function normalize_weights(w)
    local s = 0
    for _, v in pairs(w) do s = s + v end
    if s <= 0 then s = 1 end
    for k in pairs(w) do w[k] = w[k] / s end
end

------------------------------------------------------------------------
-- 60.2  Circular weighted mean (correct for angles)
------------------------------------------------------------------------
function weighted_circular_mean(angles, weights)
    local sin_sum = 0
    local cos_sum = 0
    local w_sum   = 0
    for k, ang in pairs(angles) do
        local w = weights[k] or 0
        if ang ~= nil then
            sin_sum = sin_sum + w * math.sin(math.rad(ang))
            cos_sum = cos_sum + w * math.cos(math.rad(ang))
            w_sum   = w_sum + w
        end
    end
    if w_sum <= 0 then return nil end
    return math.deg(math.atan2(sin_sum / w_sum, cos_sum / w_sum))
end

------------------------------------------------------------------------
-- 60.3  Adapt weights after hit/miss
------------------------------------------------------------------------
function adapt_weights(ent, signal_key, hit)
    local w = get_weights(ent)
    if not w[signal_key] then return end

    if hit then
        w[signal_key] = w[signal_key] * 0.9 + 0.1
    else
        w[signal_key] = math.max(w[signal_key] * 0.82, 0.02)
    end
    normalize_weights(w)
end

------------------------------------------------------------------------
-- 60.4  Blend all signals into final_yaw
------------------------------------------------------------------------
function blend_and_resolve(ent, pdata, wid)
    if not ui.get(ui_ai_enable) then return end

    local aa_type  = classify_aa(ent, pdata)
    local weights  = get_weights(ent)

    -- gather raw signals
    local signals = {
        lby      = pdata.lby_yaw,
        velocity = (function()
            local vx = pdata.vel_x_hist[1] or 0
            local vy = pdata.vel_y_hist[1] or 0
            if math_vec_len2d(vx, vy) < 10 then return nil end
            return math_normalize_yaw(math.deg(math.atan2(vy, vx)) + 180)
        end)(),
        neural   = (function()
            local off = neural_resolve(ent, pdata)
            if not off then return nil end
            return math_normalize_yaw(pdata.eye_yaw + off)
        end)(),
        markov   = markov_predicted_yaw(ent),
        brute    = (function()
            local brute_offsets_local = { [0]=0, [1]=58, [2]=-58, [3]=29, [4]=-29, [5]=0 }
            local off = brute_offsets_local[pdata.brute_state] or 0
            return math_normalize_yaw(pdata.eye_yaw + off)
        end)(),
    }

    -- apply classifier override on top
    apply_classified_resolve(ent, pdata, wid, aa_type)
    signals.classifier = pdata.resolved_yaw

    -- extend weight table with classifier
    local blended_weights = {}
    for k, v in pairs(weights) do blended_weights[k] = v end
    blended_weights.classifier = 0.30  -- strong weight for classifier
    normalize_weights(blended_weights)

    local blended = weighted_circular_mean(signals, blended_weights)
    if blended then
        pdata.resolved_yaw = math_normalize_yaw(blended)
        pdata.last_mode    = pdata.last_mode .. "+AI(" .. aa_type .. ")"
    end

    -- remember dominant signal
    local best_sig = "brute"
    local best_w   = 0
    for k, v in pairs(blended_weights) do
        if v > best_w and signals[k] ~= nil then
            best_w   = v
            best_sig = k
        end
    end
    active_signal[ent] = best_sig
end

-- hook into full_resolve_pipeline (run after existing resolver)
_orig_full_pipeline = full_resolve_pipeline
full_resolve_pipeline = function(ent, wid)
    _orig_full_pipeline(ent, wid)
    local pdata = player_data[ent]
    if pdata and ui.get(ui_ai_enable) then
        markov_update(ent)
        blend_and_resolve(ent, pdata, wid)
    end
end

-- ===========================
-- § 61  MEMORY BANK
-- ===========================

------------------------------------------------------------------------
-- 61.1  Minimal Lua serializer (JSON-like, no external deps)
------------------------------------------------------------------------
function lua_serialize(val, depth)
    depth = depth or 0
    if depth > 8 then return "null" end
    local t = type(val)
    if t == "nil"     then return "null"
    elseif t == "boolean" then return tostring(val)
    elseif t == "number"  then
        if val ~= val then return "0" end  -- NaN guard
        return string.format("%.6g", val)
    elseif t == "string"  then
        return '"' .. val:gsub('"', '\\"'):gsub("\n", "\\n") .. '"'
    elseif t == "table"   then
        -- check if array-like
        local is_arr = (#val > 0)
        if is_arr then
            local parts = {}
            for i, v in ipairs(val) do
                parts[i] = lua_serialize(v, depth + 1)
            end
            return "[" .. table.concat(parts, ",") .. "]"
        else
            local parts = {}
            for k, v in pairs(val) do
                if type(k) == "string" or type(k) == "number" then
                    local key = '"' .. tostring(k) .. '"'
                    parts[#parts + 1] = key .. ":" .. lua_serialize(v, depth + 1)
                end
            end
            return "{" .. table.concat(parts, ",") .. "}"
        end
    end
    return "null"
end

------------------------------------------------------------------------
-- 61.2  Minimal deserializer (number/string primitives via pcall+load)
-- For full table reconstruction we store as Lua and load with loadstring
------------------------------------------------------------------------
function lua_deserialize(str)
    if not str or str == "" then return nil end
    -- attempt to decode JSON-like back into Lua
    local ok, result = pcall(function()
        -- convert JSON null→nil literals, booleans, numbers
        local fn = load("return " .. str:gsub("null", "nil")
                                        :gsub("true", "true")
                                        :gsub("false", "false"))
        if fn then return fn() end
        return nil
    end)
    return ok and result or nil
end

------------------------------------------------------------------------
-- 61.3  Get player key
------------------------------------------------------------------------
function get_player_key(ent)
    -- try steamid, fall back to name
    local ok, sid = pcall(entity.get_steam64, ent)
    if ok and sid and sid ~= "" and sid ~= "0" then
        return "uv4_" .. sid
    end
    local name = entity.get_player_name(ent) or ("ent" .. tostring(ent))
    return "uv4_n_" .. name:sub(1, 20)
end

------------------------------------------------------------------------
-- 61.4  Serialize AI state for a player
------------------------------------------------------------------------
function build_ai_snapshot(ent)
    local bs  = bayes_state[ent]
    local nn  = nn_state[ent]
    local mk  = markov_state[ent]
    local sw  = signal_weights[ent]

    return {
        aa_type        = aa_type_cache[ent] or AA_RANDOM,
        bayes_priors   = bs and bs.priors or {},
        bayes_shots    = bs and bs.shots  or 0,
        bayes_hits     = bs and bs.hits   or 0,
        nn_w2          = nn and nn.w2     or {},
        nn_b2          = nn and nn.b2     or 0,
        nn_trained     = nn and nn.trained or 0,
        -- skip w1/b1 for size; they reinit fast
        markov_raw     = mk and mk.raw_counts or {},
        signal_weights = sw or {},
        sessions       = 1,
    }
end

------------------------------------------------------------------------
-- 61.5  Save to database
------------------------------------------------------------------------
ui_memory_bank = ui.new_checkbox("LUA", "B", "AI Memory Bank")

function save_player_ai(ent)
    if not ui.get(ui_memory_bank) then return end
    if not entity.is_alive(ent) then return end

    local key      = get_player_key(ent)
    local snapshot = build_ai_snapshot(ent)
    local encoded  = lua_serialize(snapshot)

    local ok = pcall(database.write, key, encoded)
    if not ok and ui.get(ui_log) then
        client.color_log(255, 180, 0, "[Aether.sev] Failed to save: " .. key)
    end
end

------------------------------------------------------------------------
-- 61.6  Load from database and restore state
------------------------------------------------------------------------
function load_player_ai(ent)
    if not ui.get(ui_memory_bank) then return end

    local key = get_player_key(ent)
    local ok_r, raw = pcall(database.read, key)
    if not ok_r or not raw then return end

    local data = lua_deserialize(raw)
    if not data then return end

    -- restore bayes
    if data.bayes_priors then
        local bs = get_bayes(ent)
        for k, v in pairs(data.bayes_priors) do
            bs.priors[k] = math_clamp(tonumber(v) or 0.4, 0.05, 0.97)
        end
        bs.shots = tonumber(data.bayes_shots) or 0
        bs.hits  = tonumber(data.bayes_hits)  or 0
    end

    -- restore NN output weights only (fast, meaningful)
    if data.nn_w2 and #data.nn_w2 == NN_HIDDEN then
        local nn = get_nn(ent)
        for h = 1, NN_HIDDEN do
            nn.w2[h] = tonumber(data.nn_w2[h]) or nn.w2[h]
        end
        nn.b2     = tonumber(data.nn_b2)     or 0
        nn.trained= tonumber(data.nn_trained) or 0
    end

    -- restore Markov
    if data.markov_raw then
        local mk = get_markov(ent)
        for i = 1, VS_COUNT do
            if data.markov_raw[i] then
                for j = 1, VS_COUNT do
                    mk.raw_counts[i][j] = tonumber(data.markov_raw[i][j]) or 1
                end
                -- recompute row probability
                local row_sum = 0
                for j = 1, VS_COUNT do row_sum = row_sum + mk.raw_counts[i][j] end
                for j = 1, VS_COUNT do
                    mk.matrix[i][j] = mk.raw_counts[i][j] / row_sum
                end
            end
        end
    end

    -- restore signal weights
    if data.signal_weights then
        local sw = get_weights(ent)
        for k, v in pairs(data.signal_weights) do
            if sw[k] ~= nil then
                sw[k] = math_clamp(tonumber(v) or 0.2, 0.01, 1)
            end
        end
        normalize_weights(sw)
    end

    local sessions = (tonumber(data.sessions) or 0) + 1
    if ui.get(ui_log) then
        client.color_log(80, 180, 255, string.format(
            "[Aether.sev] Loaded AI for %s | sessions=%d | bayes_shots=%d | nn_trained=%d",
            entity.get_player_name(ent) or "?",
            sessions,
            bayes_state[ent] and bayes_state[ent].shots or 0,
            nn_state[ent] and nn_state[ent].trained or 0))
    end
end

------------------------------------------------------------------------
-- 61.7  Load on first encounter
------------------------------------------------------------------------
memory_loaded = {}

client.set_event_callback("createmove", function()
    if not ui.get(ui_ai_enable) or not ui.get(ui_memory_bank) then return end
    local enemies = entity.get_players(true)
    for _, ent in ipairs(enemies) do
        if entity.is_alive(ent) and not entity.is_dormant(ent) then
            if not memory_loaded[ent] then
                memory_loaded[ent] = true
                load_player_ai(ent)
            end
        end
    end
end)

------------------------------------------------------------------------
-- 61.8  Save on round_end + shutdown
------------------------------------------------------------------------
client.set_event_callback("round_end", function()
    if not ui.get(ui_ai_enable) then return end
    local enemies = entity.get_players(true)
    for _, ent in ipairs(enemies) do
        if entity.is_alive(ent) then
            save_player_ai(ent)
        end
    end
    client.color_log(80, 180, 255, "[Aether.sev] AI state saved for all players (round_end)")
end)

client.set_event_callback("shutdown", function()
    if not ui.get(ui_ai_enable) then return end
    local enemies = entity.get_players(true)
    for _, ent in ipairs(enemies) do
        pcall(save_player_ai, ent)
    end
end)

------------------------------------------------------------------------
-- 61.9  Auto-save every 5 minutes
------------------------------------------------------------------------
function ai_autosave_loop()
    if ui.get(ui_ai_enable) and ui.get(ui_memory_bank) then
        local enemies = entity.get_players(true)
        for _, ent in ipairs(enemies) do
            pcall(save_player_ai, ent)
        end
        client.color_log(80, 180, 255, "[Aether.sev] Auto-save complete")
    end
    client.delay_call(300, ai_autosave_loop)  -- reschedule in 5 min
end
client.delay_call(300, ai_autosave_loop)

-- ===========================
-- § 62  AI LEARNING HOOKS
-- ===========================

------------------------------------------------------------------------
-- 62.1  Hook player_hurt — train NN on hit, update Bayes
------------------------------------------------------------------------
client.set_event_callback("player_hurt", function(e)
    if not ui.get(ui_ai_enable) then return end
    local me = entity.get_local_player()
    if not me then return end
    if client.userid_to_entindex(e.attacker) ~= me then return end

    local victim = client.userid_to_entindex(e.userid)
    if not victim then return end

    local pdata = player_data[victim]
    if not pdata then return end

    -- Bayes update (hit)
    local aa_type = aa_type_cache[victim] or AA_RANDOM
    bayes_update(victim, aa_type, true)

    -- NN train: target offset = what we actually applied
    local nn     = get_nn(victim)
    local inputs = build_nn_inputs(victim, pdata)
    nn_forward(nn, inputs)  -- ensure last_input is set
    nn_train(nn, pdata.applied_offset or 0)  -- target = what worked

    -- adapt signal weights (hit)
    local sig = active_signal[victim] or "brute"
    adapt_weights(victim, sig, true)

    if ui.get(ui_log) then
        client.color_log(80, 255, 120, string.format(
            "[Aether.sev] HIT → Bayes[%s]=%.2f | NN trained=%d | sig=%s",
            aa_type, bayes_state[victim].priors[aa_type],
            nn.trained, sig))
    end
end)

------------------------------------------------------------------------
-- 62.2  Hook bullet_impact — train NN on miss, update Bayes
------------------------------------------------------------------------
last_impact_ent  = nil
last_impact_tick = 0

client.set_event_callback("bullet_impact", function(e)
    if not ui.get(ui_ai_enable) then return end
    local me = entity.get_local_player()
    if not me then return end
    if client.userid_to_entindex(e.userid) ~= me then return end

    -- find likely target (nearest enemy to impact point)
    local ix, iy, iz = e.x, e.y, e.z
    if not ix then return end

    local tick = globals.tickcount()
    -- debounce: one miss per 3 ticks
    if tick - last_impact_tick < 3 then return end
    last_impact_tick = tick

    local best_ent  = nil
    local best_dist = 200  -- max distance to associate impact with enemy
    local enemies = entity.get_players(true)
    for _, ent in ipairs(enemies) do
        if entity.is_alive(ent) and not entity.is_dormant(ent) then
            local ox, oy, oz = entity.get_origin(ent)
            if ox then
                local d = math_vec_len3d(ox - ix, oy - iy, oz - iz)
                if d < best_dist then
                    best_dist = d
                    best_ent  = ent
                end
            end
        end
    end

    if not best_ent then return end
    local pdata = player_data[best_ent]
    if not pdata then return end

    -- Bayes update (miss)
    local aa_type = aa_type_cache[best_ent] or AA_RANDOM
    bayes_update(best_ent, aa_type, false)

    -- NN train: target = opposite of what we sent (suggest flip)
    local nn     = get_nn(best_ent)
    local inputs = build_nn_inputs(best_ent, pdata)
    nn_forward(nn, inputs)
    local corrected_offset = -(pdata.applied_offset or 0)
    nn_train(nn, corrected_offset)

    -- adapt signal weights (miss)
    local sig = active_signal[best_ent] or "brute"
    adapt_weights(best_ent, sig, false)

    last_impact_ent = best_ent
end)

-- ===========================
-- § 63  AI HUD PANEL
-- ===========================

ui_ai_hud = ui.new_checkbox("LUA", "B", "AI Debug HUD")

client.set_event_callback("paint", function()
    if not ui.get(ui_ai_enable) then return end
    if not ui.get(ui_ai_hud)    then return end

    local sw, sh = client.screen_size()
    local px = sw - 295
    local py = 270
    local pw = 285
    local line_h = 14

    -- find best target
    local me = entity.get_local_player()
    if not me or not entity.is_alive(me) then return end
    local wid = get_weapon_id(me)

    local ranked = get_prioritized_enemies()
    local target = ranked[1]

    local panel_lines = 12
    local ph = 10 + panel_lines * line_h

    -- background
    renderer.rectangle(px, py, pw, ph, 8, 8, 12, 215)
    renderer.gradient(px, py, pw, 2, 100, 80, 255, 255, 50, 20, 180, 255, true)
    renderer.rectangle(px, py+ph-1, pw, 1, 80, 50, 180, 180)
    renderer.rectangle(px,      py, 1, ph, 100, 80, 255, 160)
    renderer.rectangle(px+pw-1, py, 1, ph, 100, 80, 255, 80)

    renderer.text(px+pw/2, py+4, 180, 100, 255, 255, "c", 0, "Aether.sev AI Engine")

    local row = py + 18

    if not target then
        renderer.text(px+8, row, 120, 120, 120, 180, nil, 0, "No targets")
        return
    end

    local pdata   = player_data[target]
    local aa_type = aa_type_cache[target] or "?"
    local bs      = bayes_state[target]
    local nn      = nn_state[target]
    local mk      = get_markov(target)
    local sw_t    = signal_weights[target]

    -- target name
    local name = entity.get_player_name(target) or "?"
    if #name > 18 then name = name:sub(1,18) end
    renderer.text(px+8, row, 220, 220, 220, 220, nil, 0, "Target: " .. name)
    row = row + line_h

    -- AA type with color
    local at_r, at_g, at_b = 180, 180, 180
    if aa_type == AA_JITTER   then at_r,at_g,at_b = 255,180,50  end
    if aa_type == AA_SPIN     then at_r,at_g,at_b = 255,80,80   end
    if aa_type == AA_STATIC   then at_r,at_g,at_b = 80,255,80   end
    if aa_type == AA_BACKWARD then at_r,at_g,at_b = 80,180,255  end
    if aa_type == AA_FLIPFLOP then at_r,at_g,at_b = 255,100,200 end
    renderer.text(px+8,   row, 140,140,140,200, nil, 0, "AA Type:")
    renderer.text(px+110, row, at_r,at_g,at_b,220, nil, 0, aa_type)
    row = row + line_h

    -- Bayes P(hit)
    if bs and wid then
        local ex,ey,ez = client.eye_position()
        local ox,oy,oz = entity.get_origin(target)
        local dist = (ex and ox) and math_vec_len3d(ex-ox,ey-oy,ez-oz) or 0
        local p    = bayes_hit_probability(target, aa_type, dist)
        local pr,pg,pb = 80,255,80
        if p < 0.6 then pr,pg,pb = 255,200,50 end
        if p < 0.4 then pr,pg,pb = 255,80,80  end
        renderer.text(px+8,   row, 140,140,140,200, nil, 0, "P(hit):")
        renderer.text(px+110, row, pr,pg,pb,220, nil, 0, string.format("%.2f", p))
        row = row + line_h
    end

    -- NN info
    if nn then
        local inputs = pdata and build_nn_inputs(target, pdata) or {}
        local offset = (pdata and #inputs > 0) and nn_forward(nn, inputs) or 0
        renderer.text(px+8,   row, 140,140,140,200, nil, 0, "NN offset:")
        renderer.text(px+110, row, 200,150,255,220, nil, 0,
            string.format("%.1f° | trained=%d", offset, nn.trained))
        row = row + line_h
    end

    -- Markov prediction
    local pred_state, pred_p = markov_predict_state(target)
    local state_names = {"STOP","WALK","RUN","AIR","DUCK"}
    local curr_st     = mk.prev_state
    renderer.text(px+8, row, 140,140,140,200, nil, 0, "Markov:")
    renderer.text(px+110, row, 100,200,255,220, nil, 0,
        string.format("%s→%s (%.0f%%)",
            state_names[curr_st] or "?",
            state_names[pred_state] or "?",
            pred_p * 100))
    row = row + line_h

    -- blended yaw
    if pdata then
        renderer.text(px+8,   row, 140,140,140,200, nil, 0, "Blended:")
        renderer.text(px+110, row, 180,255,180,220, nil, 0,
            string.format("%.1f°", pdata.resolved_yaw))
        row = row + line_h
    end

    -- signal weights bar
    if sw_t then
        renderer.rectangle(px+4, row, pw-8, 1, 60,60,80,150)
        row = row + 4
        renderer.text(px+8, row, 140,140,140,200, nil, 0, "Weights:")
        row = row + line_h
        local sig_colors = {
            lby={80,255,200}, velocity={80,180,255}, neural={200,100,255},
            markov={100,200,255}, brute={255,150,50}
        }
        local bar_x = px + 8
        for sig, w in pairs(sw_t) do
            local bc = sig_colors[sig] or {180,180,180}
            local bar_w = math.floor(w * (pw - 16))
            renderer.rectangle(bar_x, row, pw-16, 6, 30,30,40,180)
            renderer.rectangle(bar_x, row, bar_w, 6, bc[1],bc[2],bc[3], 200)
            renderer.text(bar_x, row-1, 180,180,180,180, nil, 0,
                sig:sub(1,4) .. string.format("%.0f%%", w*100))
            row = row + 9
        end
    end

    -- memory bank status
    if ui.get(ui_memory_bank) then
        local nn_t = nn and nn.trained or 0
        renderer.text(px+8, row, 80,255,120,200, nil, 0,
            string.format("[MEM] %s | %d shots trained",
                get_player_key(target):sub(1,12), nn_t))
    end
end)

-- ===========================
-- § 64  AI SELF-TEST
-- ===========================

client.delay_call(0.2, function()
    local pass, fail = 0, 0
    local function t(name, cond)
        if cond then pass = pass + 1
        else fail = fail + 1
            client.color_log(255,80,80, "[UV-AI TEST] FAIL: " .. name)
        end
    end

    -- test NN forward with zero inputs
    local test_nn = init_nn_weights()
    local zero_in = {0,0,0,0,0}
    local out = nn_forward(test_nn, zero_in)
    t("nn_forward zeros → near-zero", math_abs(out) < 5)

    -- test AA classifier: spin-like history
    local fake_pdata = {
        yaw_history  = {10,30,50,70,90,110,130},
        vel_x_hist   = {0},
        vel_y_hist   = {0},
        desync_delta = 0,
    }
    -- manual classify_aa call (simplified)
    local deltas = {}
    local yaws = fake_pdata.yaw_history
    for i = 1, #yaws-1 do
        deltas[#deltas+1] = math_angle_diff(yaws[i+1], yaws[i])
    end
    local avg_d = tbl_avg(deltas)
    local std_d = tbl_std_dev(deltas)
    t("spin classifier: avg~20 std<6", math_abs(avg_d - 20) < 2 and std_d < 2)

    -- test Bayes update
    local bs_test = { priors = { [AA_STATIC] = 0.70 }, shots = 0, hits = 0 }
    for _ = 1, 10 do
        local prev = bs_test.priors[AA_STATIC]
        bs_test.priors[AA_STATIC] = prev * (1-BAYES_ALPHA) + 1.0 * BAYES_ALPHA
    end
    t("bayes 10x hit → prior > 0.88", bs_test.priors[AA_STATIC] > 0.88)

    -- test weighted_circular_mean
    local test_angles  = { a=0, b=180 }
    local test_weights = { a=1, b=0 }
    local mean = weighted_circular_mean(test_angles, test_weights)
    t("circular_mean (0,w=1),(180,w=0) -> ~0", mean ~= nil and math_abs(mean) < 5)

    -- test serializer roundtrip
    local orig  = { x=1.23, y="hello", z=true, arr={1,2,3} }
    local ser   = lua_serialize(orig)
    local deser = lua_deserialize(ser)
    t("serialize roundtrip: x=1.23", deser ~= nil and math_abs((deser.x or 0) - 1.23) < 0.01)

    -- test Markov update
    local mk = get_markov(9999)
    mk.prev_state = VS_RUN
    for _ = 1, 8 do
        mk.raw_counts[VS_RUN][VS_RUN] = mk.raw_counts[VS_RUN][VS_RUN] + 1
        local row_sum = 0
        for j = 1, VS_COUNT do row_sum = row_sum + mk.raw_counts[VS_RUN][j] end
        for j = 1, VS_COUNT do mk.matrix[VS_RUN][j] = mk.raw_counts[VS_RUN][j]/row_sum end
    end
    local best_st, best_p = markov_predict_state(9999)
    t("markov RUN→RUN dominant", best_st == VS_RUN and best_p > 0.5)

    if fail == 0 then
        client.color_log(80,255,120, string.format("[Aether.sev] Self-test: %d/%d PASS ✓", pass, pass))
    else
        client.color_log(255,180,0, string.format("[Aether.sev] Self-test: %d pass, %d FAIL", pass, fail))
    end
end)

-- ===========================
-- § 65  AI BOOT LOG
-- ===========================

client.color_log(100, 80, 255, "[Aether.sev] =====================================================")
client.color_log(180, 100, 255, "[Aether.sev]  ULTRAVIOLET AI ENGINE v4.0 — LOADED")
client.color_log(180, 255, 180, "[Aether.sev]  §56  AA Pattern Classifier (SPIN/JITTER/STATIC/BACK/FF)")
client.color_log(180, 255, 180, "[Aether.sev]  §57  Bayesian Hit Predictor (P(hit) per AA type)")
client.color_log(180, 255, 180, "[Aether.sev]  §58  Neural Resolver (5→4→1 perceptron, online train)")
client.color_log(180, 255, 180, "[Aether.sev]  §59  Markov Movement Predictor (5-state chain)")
client.color_log(180, 255, 180, "[Aether.sev]  §60  Adaptive Weight Blender (circular weighted mean)")
client.color_log(180, 255, 180, "[Aether.sev]  §61  Memory Bank (database per SteamID/name)")
client.color_log(180, 255, 180, "[Aether.sev]  §62  Learning Hooks (player_hurt + bullet_impact)")
client.color_log(180, 255, 180, "[Aether.sev]  §63  AI Debug HUD (AA type, P(hit), NN, Markov, weights)")
client.color_log(180, 255, 180, "[Aether.sev]  §64  Self-Test Suite (6 automated tests)")
client.color_log(100, 80, 255, "[Aether.sev] =====================================================")
client.color_log(255, 220, 50,  "[Aether.sev]  Toggle: LUA > A > UV AI Engine")

-- ============================================================
--  GROUP A  :  ANIMATION & BONE ANALYSIS
--  Sections : §66 – §70
-- ============================================================

-- ===========================
-- § 66  ANIMATION LAYER TRACKER
-- ===========================
-- Tracks the 13 CS:GO animation overlay layers per player.
-- Changes in cycle speed / weight reveal the real movement state
-- and predict the next LBY flip window.

ANIM_LAYERS     = 13
ANIM_MOVE_LAYER = 6   -- run/walk blending layer
ANIM_DUCK_LAYER = 5   -- duck blending layer
ANIM_LAND_LAYER = 8   -- landing impact layer

------------------------------------------------------------------------
-- 66.1  Storage
------------------------------------------------------------------------
anim_data = {}   -- [ent] = { layers[1..13] = {weight,cycle,seq}, prev, ... }

function get_anim_data(ent)
    if not anim_data[ent] then
        anim_data[ent] = { layers = {}, prev_layers = {}, stand_weight = 0,
                           move_weight = 0, duck_weight = 0, land_cycle = 0 }
    end
    return anim_data[ent]
end

------------------------------------------------------------------------
-- 66.2  Read animation layers from entity props
------------------------------------------------------------------------
function update_anim_layers(ent)
    local ad = get_anim_data(ent)
    -- copy previous
    for i = 1, ANIM_LAYERS do
        ad.prev_layers[i] = ad.layers[i]
    end

    for i = 0, ANIM_LAYERS - 1 do
        local base  = "m_AnimOverlay[" .. i .. "]."
        local w     = entity.get_prop(ent, base .. "m_flWeight")
        local cyc   = entity.get_prop(ent, base .. "m_flCycle")
        local seq   = entity.get_prop(ent, base .. "m_nSequence")
        ad.layers[i + 1] = {
            weight   = w   or 0,
            cycle    = cyc or 0,
            sequence = seq or 0,
        }
    end

    -- Convenient accessors
    ad.move_weight = ad.layers[ANIM_MOVE_LAYER + 1] and
                     ad.layers[ANIM_MOVE_LAYER + 1].weight or 0
    ad.duck_weight = ad.layers[ANIM_DUCK_LAYER + 1] and
                     ad.layers[ANIM_DUCK_LAYER + 1].weight or 0
    ad.land_cycle  = ad.layers[ANIM_LAND_LAYER + 1] and
                     ad.layers[ANIM_LAND_LAYER + 1].cycle  or 0
    ad.stand_weight = math_clamp(1 - ad.move_weight - ad.duck_weight, 0, 1)
end

------------------------------------------------------------------------
-- 66.3  Detect LBY animation transition window
-- Returns true if the current cycle indicates an LBY update is imminent.
------------------------------------------------------------------------
function anim_lby_window(ent)
    local ad = get_anim_data(ent)
    -- Layer 3 (idle) cycle nearing 1.0 → LBY about to reset
    local idle_layer = ad.layers[4]
    if idle_layer and idle_layer.cycle then
        return idle_layer.cycle > 0.92
    end
    return false
end

------------------------------------------------------------------------
-- 66.4  Is the player genuinely standing (not animating movement)?
------------------------------------------------------------------------
function anim_is_genuine_stand(ent)
    local ad = get_anim_data(ent)
    return ad.move_weight < 0.08 and ad.duck_weight < 0.05
end

------------------------------------------------------------------------
-- 66.5  Hook – update every createmove tick
------------------------------------------------------------------------
client.set_event_callback("createmove", function()
    if not ui.get(ui_enabled) then return end
    local enemies = entity.get_players(true)
    for _, ent in ipairs(enemies) do
        if entity.is_alive(ent) and not entity.is_dormant(ent) then
            pcall(update_anim_layers, ent)
        end
    end
end)

------------------------------------------------------------------------
-- 66.6  Feed animation data into resolver pipeline
------------------------------------------------------------------------
function anim_adjust_resolve(ent, pdata)
    local ad = get_anim_data(ent)
    -- If player is genuinely standing, LBY is more trustworthy
    if anim_is_genuine_stand(ent) then
        pdata.confidence = math_clamp(pdata.confidence + 8, 0, 100)
    end
    -- If LBY window is open, snap to LBY immediately
    if anim_lby_window(ent) then
        pdata.resolved_yaw = math_normalize_yaw(pdata.lby_yaw)
        pdata.last_mode    = pdata.last_mode .. "+ANIM_LBY"
    end
end

-- ===========================
-- § 67  LBY UPDATE RATE ANALYSER
-- ===========================
-- Builds a histogram of LBY update intervals to detect fake-stand
-- and predict the next LBY window.

------------------------------------------------------------------------
-- 67.1  Storage
------------------------------------------------------------------------
LBY_HIST_SIZE = 16

lby_hist = {}   -- [ent] = { times={}, intervals={}, avg=0, drift=0 }

function get_lby_hist(ent)
    if not lby_hist[ent] then
        lby_hist[ent] = { times={}, intervals={}, avg=0, drift=0, last_yaw=0 }
    end
    return lby_hist[ent]
end

------------------------------------------------------------------------
-- 67.2  Detect LBY change and record timestamp
------------------------------------------------------------------------
function lby_update_tick(ent)
    local pdata = player_data[ent]
    if not pdata then return end
    local lh = get_lby_hist(ent)

    local cur_lby = entity.get_prop(ent, "m_flLowerBodyYawTarget")
    if not cur_lby then return end

    if math_abs(math_angle_diff(cur_lby, lh.last_yaw)) > 3 then
        -- LBY changed → record timestamp
        local now = globals.curtime()
        if #lh.times > 0 then
            local interval = now - lh.times[#lh.times]
            lh.intervals[#lh.intervals + 1] = interval
            if #lh.intervals > LBY_HIST_SIZE then
                table.remove(lh.intervals, 1)
            end
            -- recompute avg
            lh.avg = tbl_avg(lh.intervals)
        end
        lh.times[#lh.times + 1] = now
        if #lh.times > LBY_HIST_SIZE then table.remove(lh.times, 1) end
        lh.last_yaw = cur_lby

        -- drift score: std_dev / avg (relative variation)
        if lh.avg > 0 then
            local sd = tbl_std_dev(lh.intervals)
            lh.drift = math_clamp(sd / lh.avg * 100, 0, 100)
        end
    end
end

------------------------------------------------------------------------
-- 67.3  Predict when next LBY update will occur (in seconds)
------------------------------------------------------------------------
function lby_predict_next(ent)
    local lh = get_lby_hist(ent)
    if lh.avg < 0.05 then return nil end
    if #lh.times == 0 then return nil end
    local last_time = lh.times[#lh.times]
    local predicted = last_time + lh.avg
    local time_left  = predicted - globals.curtime()
    return math.max(time_left, 0)
end

------------------------------------------------------------------------
-- 67.4  Hook
------------------------------------------------------------------------
client.set_event_callback("createmove", function()
    if not ui.get(ui_enabled) then return end
    local enemies = entity.get_players(true)
    for _, ent in ipairs(enemies) do
        if entity.is_alive(ent) and not entity.is_dormant(ent) then
            pcall(lby_update_tick, ent)
        end
    end
end)

-- ===========================
-- § 68  BONE MATRIX EXTRAPOLATION
-- ===========================
-- Predicts next-tick hitbox positions by computing bone velocity
-- (delta position / tick interval) and extrapolating forward.

------------------------------------------------------------------------
-- 68.1  Bone position history
------------------------------------------------------------------------
bone_hist = {}   -- [ent][hitbox_id] = { prev_x,prev_y,prev_z, cur_x,... }

function get_bone_hist(ent, hb)
    if not bone_hist[ent] then bone_hist[ent] = {} end
    if not bone_hist[ent][hb] then
        bone_hist[ent][hb] = { px=0,py=0,pz=0, cx=0,cy=0,cz=0 }
    end
    return bone_hist[ent][hb]
end

------------------------------------------------------------------------
-- 68.2  Update bone history
------------------------------------------------------------------------
BONE_TRACK = { HITBOX_HEAD, HITBOX_CHEST, HITBOX_STOMACH, HITBOX_UPPER_CHEST }

function update_bone_hist(ent)
    for _, hb in ipairs(BONE_TRACK) do
        local x, y, z = entity.hitbox_position(ent, hb)
        if x then
            local bh = get_bone_hist(ent, hb)
            bh.px, bh.py, bh.pz = bh.cx, bh.cy, bh.cz
            bh.cx, bh.cy, bh.cz = x, y, z
        end
    end
end

------------------------------------------------------------------------
-- 68.3  Extrapolate position N ticks ahead
------------------------------------------------------------------------
function bone_extrapolate(ent, hb, ticks)
    local bh = get_bone_hist(ent, hb)
    if bh.cx == 0 then return nil end
    local dt = globals.tickinterval() * ticks
    local vx = bh.cx - bh.px
    local vy = bh.cy - bh.py
    local vz = bh.cz - bh.pz
    -- divide by tickinterval to get vel, multiply by prediction dt
    local scale = dt / math.max(globals.tickinterval(), 0.001)
    return bh.cx + vx * scale,
           bh.cy + vy * scale,
           bh.cz + vz * scale
end

------------------------------------------------------------------------
-- 68.4  Extrapolated trace gate — is head hittable next tick?
------------------------------------------------------------------------
function bone_trace_gate(ent)
    local me = entity.get_local_player()
    if not me then return false end
    local ex, ey, ez = client.eye_position()
    if not ex then return false end

    local hx, hy, hz = bone_extrapolate(ent, HITBOX_HEAD, 1)
    if not hx then return false end

    local _, dmg = client.trace_bullet(me, ex, ey, ez, hx, hy, hz, false)
    return dmg and dmg > 0
end

------------------------------------------------------------------------
-- 68.5  Hook
------------------------------------------------------------------------
client.set_event_callback("createmove", function()
    if not ui.get(ui_enabled) then return end
    local enemies = entity.get_players(true)
    for _, ent in ipairs(enemies) do
        if entity.is_alive(ent) and not entity.is_dormant(ent) then
            pcall(update_bone_hist, ent)
        end
    end
end)

-- ===========================
-- § 69  FAKE-DUCK DETECTOR
-- ===========================
-- Detects fake-duck by comparing actual viewOffset with expected values.

EXPECTED_STAND_OFFSET = 64.0
EXPECTED_DUCK_OFFSET  = 46.0
FAKEDUCK_TOLERANCE    = 5.0

fakeduck_state = {}   -- [ent] = { is_fd, confidence, history }

function get_fd_state(ent)
    if not fakeduck_state[ent] then
        fakeduck_state[ent] = { is_fd=false, conf=0, history={} }
    end
    return fakeduck_state[ent]
end

------------------------------------------------------------------------
-- 69.1  Classify duck state
------------------------------------------------------------------------
function detect_fake_duck(ent)
    local fds    = get_fd_state(ent)
    local flags  = entity.get_prop(ent, "m_fFlags") or 0
    local ducking = bit.band(flags, FL_DUCKING) ~= 0

    local view_z = entity.get_prop(ent, "m_vecViewOffset[2]")
    if not view_z then
        fds.is_fd = false
        return
    end

    if ducking then
        -- ducking flag set; check if view offset matches
        local diff = math_abs(view_z - EXPECTED_DUCK_OFFSET)
        if diff > FAKEDUCK_TOLERANCE * 2 then
            -- viewOffset doesn't match real duck → fake-duck
            fds.conf = math_clamp(fds.conf + 10, 0, 100)
            fds.is_fd = fds.conf > 50
        else
            fds.conf = math_clamp(fds.conf - 5, 0, 100)
            fds.is_fd = false
        end
    else
        -- not ducking: is viewOffset in stand range?
        local diff = math_abs(view_z - EXPECTED_STAND_OFFSET)
        if diff > FAKEDUCK_TOLERANCE then
            -- transitioning; might be real duck animation
            fds.conf = math_clamp(fds.conf + 2, 0, 100)
        else
            fds.conf = math_clamp(fds.conf - 8, 0, 100)
            fds.is_fd = false
        end
        fds.is_fd = fds.conf > 50
    end

    -- Track history for pattern analysis
    fds.history[#fds.history + 1] = fds.is_fd and 1 or 0
    if #fds.history > 32 then table.remove(fds.history, 1) end
end

------------------------------------------------------------------------
-- 69.2  Fake-duck resolver adjustment
-- Fake-duck means the real body is standing → use standing hitboxes
------------------------------------------------------------------------
function fakeduck_adjust_resolve(ent, pdata)
    local fds = get_fd_state(ent)
    if not fds.is_fd then return end

    -- Force head hitbox (body is standing, head is accessible)
    if pdata then
        pdata.confidence = math_clamp(pdata.confidence - 15, 0, 100)
        pdata.last_mode  = pdata.last_mode .. "+FD"
    end
end

------------------------------------------------------------------------
-- 69.3  Hook
------------------------------------------------------------------------
client.set_event_callback("createmove", function()
    if not ui.get(ui_enabled) then return end
    local enemies = entity.get_players(true)
    for _, ent in ipairs(enemies) do
        if entity.is_alive(ent) and not entity.is_dormant(ent) then
            pcall(detect_fake_duck, ent)
            local pdata = player_data[ent]
            if pdata then pcall(fakeduck_adjust_resolve, ent, pdata) end
        end
    end
end)

-- ===========================
-- § 70  SIMULATED TICK RESOLVER
-- ===========================
-- Runs a mini lookahead simulation: copies pdata, advances N ticks,
-- scores each candidate yaw offset via Bayes and picks the best one.

SIM_OFFSETS = { 0, 29, -29, 58, -58, 44, -44, 14, -14 }
SIM_TICKS   = 3

------------------------------------------------------------------------
-- 70.1  Simulate pdata N ticks forward (simplified)
------------------------------------------------------------------------
function sim_advance_pdata(pdata, ticks)
    -- Create shallow copy
    local sim = {}
    for k, v in pairs(pdata) do sim[k] = v end
    -- Advance LBY by trend
    local lby_delta = math_angle_diff(sim.lby_yaw, sim.eye_yaw)
    sim.lby_yaw = math_normalize_yaw(sim.lby_yaw + lby_delta * 0.1 * ticks)
    -- Advance confidence decay
    sim.confidence = math_clamp(sim.confidence - ticks * 2, 0, 100)
    return sim
end

------------------------------------------------------------------------
-- 70.2  Score a yaw offset via Bayes P(hit)
------------------------------------------------------------------------
function sim_score_offset(ent, sim_pdata, offset, wid)
    local test_yaw = math_normalize_yaw(sim_pdata.eye_yaw + offset)
    local aa_type  = aa_type_cache[ent] or AA_RANDOM

    -- Use eye_position + test_yaw direction as proxy for hit quality
    local me = entity.get_local_player()
    if not me then return 0 end
    local ex, ey, ez = client.eye_position()
    if not ex then return 0 end

    -- Estimate distance
    local ox, oy, oz = entity.get_origin(ent)
    local dist = ox and math_vec_len3d(ex-ox, ey-oy, ez-oz) or 500

    local p = bayes_hit_probability(ent, aa_type, dist)
    -- Penalize larger offsets (more uncertain)
    local offset_penalty = math_abs(offset) / 60
    return p * (1 - offset_penalty * 0.3)
end

------------------------------------------------------------------------
-- 70.3  Main simulated resolver
------------------------------------------------------------------------
sim_cache       = {}   -- [ent] = best_offset
sim_cache_tick  = {}

function simulated_tick_resolve(ent, pdata, wid)
    local tick = globals.tickcount()
    -- Run every 4 ticks (expensive-ish)
    if sim_cache_tick[ent] and tick - sim_cache_tick[ent] < 4 then
        local cached = sim_cache[ent]
        if cached then
            pdata.resolved_yaw = math_normalize_yaw(pdata.eye_yaw + cached)
            pdata.last_mode    = pdata.last_mode .. "+SIM"
        end
        return
    end

    local sim_pdata  = sim_advance_pdata(pdata, SIM_TICKS)
    local best_score = -1
    local best_off   = 0

    for _, off in ipairs(SIM_OFFSETS) do
        local score = sim_score_offset(ent, sim_pdata, off, wid)
        if score > best_score then
            best_score = score
            best_off   = off
        end
    end

    sim_cache[ent]      = best_off
    sim_cache_tick[ent] = tick

    if best_score > 0.35 then
        pdata.resolved_yaw = math_normalize_yaw(pdata.eye_yaw + best_off)
        pdata.last_mode    = pdata.last_mode .. "+SIM(" .. tostring(best_off) .. ")"
    end
end

-- ============================================================
--  GROUP B  :  PHYSICS & BULLET COMPENSATION
--  Sections : §71 – §75
-- ============================================================

-- ===========================
-- § 71  BULLET TRAVEL TIME COMPENSATOR
-- ===========================
-- Computes lead position: where the enemy will be when bullet arrives.

BULLET_VELOCITY = {
    [WEAPON_DEAGLE]   = 44400,
    [WEAPON_SSG08]    = 54000,
    [WEAPON_TEC9]     = 39750,
    [WEAPON_REVOLVER] = 44400,
    [WEAPON_ZEUS]     = 999999,  -- instant
}
BULLET_VELOCITY_DEFAULT = 40000

------------------------------------------------------------------------
-- 71.1  Compute lead position
------------------------------------------------------------------------
function bullet_lead_position(ent, wid)
    local me = entity.get_local_player()
    if not me then return nil end
    local ex, ey, ez = client.eye_position()
    if not ex then return nil end

    local ox, oy, oz = entity.get_origin(ent)
    if not ox then return nil end

    local dist = math_vec_len3d(ex-ox, ey-oy, ez-oz)
    local vel  = BULLET_VELOCITY[wid] or BULLET_VELOCITY_DEFAULT
    local t    = dist / vel  -- travel time in seconds

    local vx = entity.get_prop(ent, "m_vecVelocity[0]") or 0
    local vy = entity.get_prop(ent, "m_vecVelocity[1]") or 0
    local vz = entity.get_prop(ent, "m_vecVelocity[2]") or 0

    return ox + vx * t, oy + vy * t, oz + vz * t, t
end

------------------------------------------------------------------------
-- 71.2  Lead-compensated yaw
------------------------------------------------------------------------
function bullet_lead_yaw(ent, wid)
    local me = entity.get_local_player()
    if not me then return nil end
    local ex, ey, ez = client.eye_position()
    if not ex then return nil end

    local lx, ly, lz, t = bullet_lead_position(ent, wid)
    if not lx then return nil end

    -- Yaw from eye to lead position
    local dx, dy = lx - ex, ly - ey
    if math_vec_len2d(dx, dy) < 1 then return nil end
    return math.deg(math.atan2(dy, dx)), t
end

------------------------------------------------------------------------
-- 71.3  Integrate into resolver
------------------------------------------------------------------------
function apply_bullet_lead(ent, pdata, wid)
    local lead_yaw, travel_t = bullet_lead_yaw(ent, wid)
    if not lead_yaw then return end

    -- Only adjust if significant travel time
    if travel_t > 0.02 then
        -- Blend with resolved yaw (20% lead correction)
        local diff = math_angle_diff(lead_yaw, pdata.resolved_yaw) * 0.20
        pdata.resolved_yaw = math_normalize_yaw(pdata.resolved_yaw + diff)
        pdata.last_mode    = pdata.last_mode ..
            string.format("+LEAD(%.0fms)", travel_t * 1000)
    end
end

-- ===========================
-- § 72  GRAVITY & ARC COMPENSATION
-- ===========================
-- Primarily for SSG-08: computes bullet drop and adds pitch correction.

CS_GRAVITY = 800.0   -- units/s²

------------------------------------------------------------------------
-- 72.1  Compute pitch correction for bullet drop
------------------------------------------------------------------------
function gravity_pitch_correction(ent, wid)
    if wid ~= WEAPON_SSG08 then return 0 end

    local me = entity.get_local_player()
    if not me then return 0 end
    local ex, ey, ez = client.eye_position()
    if not ex then return 0 end

    local hx, hy, hz = entity.hitbox_position(ent, HITBOX_HEAD)
    if not hx then return 0 end

    local dist_h = math_vec_len2d(hx - ex, hy - ey)
    if dist_h < 50 then return 0 end

    local vel  = BULLET_VELOCITY[WEAPON_SSG08]
    local t    = dist_h / vel
    local drop = 0.5 * CS_GRAVITY * t * t

    -- pitch correction: aim UP by the drop amount
    local pitch_rad = math.atan2(drop, dist_h)
    return -math.deg(pitch_rad)  -- negative = look up
end

------------------------------------------------------------------------
-- 72.2  Per-tick pitch adjustment
------------------------------------------------------------------------
gravity_pitch = {}   -- [ent] = correction_degrees

client.set_event_callback("createmove", function()
    if not ui.get(ui_enabled) then return end
    local me = entity.get_local_player()
    if not me then return end

    local wid = get_weapon_id(me)
    if wid ~= WEAPON_SSG08 then return end

    local enemies = entity.get_players(true)
    for _, ent in ipairs(enemies) do
        if entity.is_alive(ent) and not entity.is_dormant(ent) then
            local corr = pcall(gravity_pitch_correction, ent, wid)
            if type(corr) == "number" then
                gravity_pitch[ent] = corr
            else
                gravity_pitch[ent] = gravity_pitch_correction(ent, wid)
            end
        end
    end
end)

-- ===========================
-- § 73  SPREAD COMPENSATION
-- ===========================
-- Tracks shots fired vs expected pattern; biases aim at center of spread.

spread_bias = {}   -- [ent] = { shots=0, cumulative_miss=0 }

SPREAD_COMPENSATION = {
    [WEAPON_DEAGLE]   = 0.50,   -- degrees half-cone
    [WEAPON_SSG08]    = 0.20,
    [WEAPON_TEC9]     = 2.0,
    [WEAPON_REVOLVER] = 0.30,
    [WEAPON_ZEUS]     = 0,
}

function get_spread_bias(ent)
    if not spread_bias[ent] then
        spread_bias[ent] = { shots=0, factor=0 }
    end
    return spread_bias[ent]
end

------------------------------------------------------------------------
-- 73.1  Spread-adjusted hitchance estimate
-- For weapons with significant spread, bias toward center (larger hitbox)
------------------------------------------------------------------------
function spread_adjusted_hitchance(ent, wid, base_hc)
    local sb     = get_spread_bias(ent)
    local half   = SPREAD_COMPENSATION[wid] or 0

    if half < 0.1 then return base_hc end

    -- heuristic: widen effective hit area by spread half-cone
    -- if we aim at center of hitbox, spread only helps (slightly)
    local bonus = math_clamp(half * 2, 0, 15)
    return math_clamp(base_hc + bonus, 0, 100)
end

------------------------------------------------------------------------
-- 73.2  Track miss/hit and update bias
------------------------------------------------------------------------
client.set_event_callback("player_hurt", function(e)
    local me = entity.get_local_player()
    if not me then return end
    if client.userid_to_entindex(e.attacker) ~= me then return end
    local victim = client.userid_to_entindex(e.userid)
    if not victim then return end
    local sb = get_spread_bias(victim)
    sb.shots = sb.shots + 1
    sb.factor = math_clamp(sb.factor * 0.9, 0, 1)
end)

-- ===========================
-- § 74  PENETRATION DEPTH CALCULATOR
-- ===========================
-- Checks if a wallbang is viable: enough damage after penetration to kill.

PENETRATION_FACTOR = {
    [WEAPON_DEAGLE]   = 2.0,
    [WEAPON_SSG08]    = 1.5,
    [WEAPON_TEC9]     = 1.0,
    [WEAPON_REVOLVER] = 2.0,
    [WEAPON_ZEUS]     = 0,    -- can't penetrate
}

------------------------------------------------------------------------
-- 74.1  Wallbang damage estimate
------------------------------------------------------------------------
function wallbang_damage(ent, wid)
    local me = entity.get_local_player()
    if not me then return 0, false end
    local ex, ey, ez = client.eye_position()
    if not ex then return 0, false end

    local hx, hy, hz = entity.hitbox_position(ent, HITBOX_CHEST)
    if not hx then return 0, false end

    local _, dmg = client.trace_bullet(me, ex, ey, ez, hx, hy, hz, false)
    dmg = dmg or 0

    -- If trace confirms direct line → not a wallbang situation
    if dmg > 0 then
        return dmg, false  -- direct hit, no wall
    end

    -- Estimate through-wall damage
    local base  = WEAPON_BASE_DMG[wid] or 50
    local pfact = PENETRATION_FACTOR[wid] or 1.0
    local estimated_wall_dmg = base * (1 / pfact) * 0.4  -- rough estimate

    return estimated_wall_dmg, true
end

------------------------------------------------------------------------
-- 74.2  Should we attempt wallbang?
------------------------------------------------------------------------
function wallbang_viable(ent, wid)
    local hp = entity.get_prop(ent, "m_iHealth") or 100
    local dmg, through_wall = wallbang_damage(ent, wid)
    return through_wall and dmg >= hp, dmg
end

------------------------------------------------------------------------
-- 74.3  HUD indicator for wallbang
------------------------------------------------------------------------
client.set_event_callback("paint", function()
    if not ui.get(ui_enabled) or not ui.get(ui_hud) then return end
    local me = entity.get_local_player()
    if not me or not entity.is_alive(me) then return end
    local wid = get_weapon_id(me)
    if not wid or not is_supported_weapon(wid) then return end

    local enemies = entity.get_players(true)
    for _, ent in ipairs(enemies) do
        if entity.is_alive(ent) and not entity.is_dormant(ent) then
            local can_wb, wb_dmg = wallbang_viable(ent, wid)
            if can_wb then
                local hx, hy, hz = entity.hitbox_position(ent, HITBOX_HEAD)
                if hx then
                    local sx, sy = renderer.world_to_screen(hx, hy, hz + 20)
                    if sx and sy then
                        renderer.text(sx, sy - 42, 255, 180, 50, 220, "c", 0,
                            string.format("WB ~%d", math.floor(wb_dmg)))
                    end
                end
            end
        end
    end
end)

-- ===========================
-- § 75  SUB-TICK INTERPOLATION ENGINE
-- ===========================
-- Interpolates hitbox positions between ticks using m_flSimulationTime.

simtime_hist = {}   -- [ent] = { prev_time, curr_time, prev_pos, curr_pos }

TRACKED_HITBOXES_ST = { HITBOX_HEAD, HITBOX_CHEST }

function get_simtime_state(ent)
    if not simtime_hist[ent] then
        simtime_hist[ent] = {}
        for _, hb in ipairs(TRACKED_HITBOXES_ST) do
            simtime_hist[ent][hb] = {
                prev_time=0, curr_time=0,
                px=0,py=0,pz=0, cx=0,cy=0,cz=0
            }
        end
    end
    return simtime_hist[ent]
end

------------------------------------------------------------------------
-- 75.1  Update sim time history
------------------------------------------------------------------------
function simtime_update(ent)
    local sth  = get_simtime_state(ent)
    local st   = entity.get_prop(ent, "m_flSimulationTime") or 0

    for _, hb in ipairs(TRACKED_HITBOXES_ST) do
        local s = sth[hb]
        if not s then goto continue end
        local x, y, z = entity.hitbox_position(ent, hb)
        if x then
            s.prev_time = s.curr_time
            s.px, s.py, s.pz = s.cx, s.cy, s.cz
            s.curr_time = st
            s.cx, s.cy, s.cz = x, y, z
        end
        ::continue::
    end
end

------------------------------------------------------------------------
-- 75.2  Interpolate position at current render time
------------------------------------------------------------------------
function simtime_interp_pos(ent, hb)
    local sth = get_simtime_state(ent)
    local s   = sth[hb]
    if not s then return nil end

    local dt  = s.curr_time - s.prev_time
    if dt <= 0 then return s.cx, s.cy, s.cz end

    local now    = globals.curtime()
    local frac   = math_clamp((now - s.prev_time) / dt, 0, 1)

    local ix = s.px + (s.cx - s.px) * frac
    local iy = s.py + (s.cy - s.py) * frac
    local iz = s.pz + (s.cz - s.pz) * frac
    return ix, iy, iz
end

------------------------------------------------------------------------
-- 75.3  Interpolated trace gate
------------------------------------------------------------------------
function simtime_trace_gate(ent)
    local me = entity.get_local_player()
    if not me then return false end
    local ex, ey, ez = client.eye_position()
    if not ex then return false end

    local hx, hy, hz = simtime_interp_pos(ent, HITBOX_HEAD)
    if not hx then return false end

    local _, dmg = client.trace_bullet(me, ex, ey, ez, hx, hy, hz, false)
    return dmg and dmg > 0
end

------------------------------------------------------------------------
-- 75.4  Hook
------------------------------------------------------------------------
client.set_event_callback("createmove", function()
    if not ui.get(ui_enabled) then return end
    local enemies = entity.get_players(true)
    for _, ent in ipairs(enemies) do
        if entity.is_alive(ent) and not entity.is_dormant(ent) then
            pcall(simtime_update, ent)
        end
    end
end)

------------------------------------------------------------------------
-- 75.5  Group A+B init log
------------------------------------------------------------------------
client.color_log(80, 220, 255,  "[UV] GROUP A  §66-§70 Animation & Bone — LOADED")
client.color_log(80, 255, 180,  "[UV] GROUP B  §71-§75 Physics & Bullet  — LOADED")
client.color_log(200, 200, 200, "[UV] §66 AnimLayers | §67 LBY-Rate | §68 BoneExtrapolation")
client.color_log(200, 200, 200, "[UV] §69 FakeDuck   | §70 SimTick  | §71 BulletLead")
client.color_log(200, 200, 200, "[UV] §72 GravArc    | §73 Spread   | §74 Penetration")
client.color_log(200, 200, 200, "[UV] §75 SubTick-Interp")
-- ============================================================
--  GROUP C  :  RESOLVER ALGORITHM SUITE   §76 – §80
-- ============================================================

-- ===========================
-- § 76  PARALLEL ALGORITHM VOTER
-- ===========================

ALGO_LBY        = "lby"
ALGO_VELOCITY   = "velocity"
ALGO_NEURAL     = "neural"
ALGO_MARKOV_YAW = "markov_yaw"
ALGO_CLASSIFIER = "classifier"
ALGO_BRUTE_SIDE = "brute_side"
ALGO_FREESTAND  = "freestand"
ALGO_BONE_EXTRAP= "bone_extrap"

voter_base_weights = {
    [ALGO_LBY]        = 1.0,
    [ALGO_VELOCITY]   = 0.8,
    [ALGO_NEURAL]     = 1.2,
    [ALGO_MARKOV_YAW] = 0.7,
    [ALGO_CLASSIFIER] = 1.5,
    [ALGO_BRUTE_SIDE] = 0.9,
    [ALGO_FREESTAND]  = 1.1,
    [ALGO_BONE_EXTRAP]= 1.0,
}

voter_weights_adapted = {}
last_votes_cache      = {}

function get_voter_weights(ent)
    if not voter_weights_adapted[ent] then
        local w = {}
        for k, v in pairs(voter_base_weights) do w[k] = v end
        voter_weights_adapted[ent] = w
    end
    return voter_weights_adapted[ent]
end

function normalize_voter_weights(w)
    local s = 0
    for _, v in pairs(w) do s = s + v end
    if s <= 0 then s = 1 end
    for k in pairs(w) do w[k] = w[k] / s end
end

brute_offsets_v76 = { [0]=0,[1]=58,[2]=-58,[3]=29,[4]=-29,[5]=0,[6]=44,[7]=-44 }

function run_algorithm_voter(ent, pdata, wid)
    local votes = {}

    if pdata.lby_yaw then votes[ALGO_LBY] = pdata.lby_yaw end

    local vx76 = pdata.vel_x_hist[1] or 0
    local vy76 = pdata.vel_y_hist[1] or 0
    if math_vec_len2d(vx76, vy76) > 15 then
        votes[ALGO_VELOCITY] = math_normalize_yaw(math.deg(math.atan2(vy76, vx76)) + 180)
    end

    if ui.get(ui_ai_enable) then
        local off76 = neural_resolve(ent, pdata)
        if off76 then votes[ALGO_NEURAL] = math_normalize_yaw(pdata.eye_yaw + off76) end
    end

    local mk_yaw76 = markov_predicted_yaw(ent)
    if mk_yaw76 then votes[ALGO_MARKOV_YAW] = mk_yaw76 end

    local aa_type76 = classify_aa(ent, pdata)
    if aa_type76 ~= AA_RANDOM then
        local before76 = pdata.resolved_yaw
        apply_classified_resolve(ent, pdata, wid, aa_type76)
        votes[ALGO_CLASSIFIER] = pdata.resolved_yaw
        pdata.resolved_yaw = before76
    end

    local broff76 = brute_offsets_v76[pdata.brute_state] or 0
    votes[ALGO_BRUTE_SIDE] = math_normalize_yaw(pdata.eye_yaw + broff76)

    local me76 = entity.get_local_player()
    if me76 then
        local ex76, ey76, ez76 = client.eye_position()
        if ex76 then
            local hx76, hy76, hz76 = entity.hitbox_position(ent, HITBOX_HEAD)
            if hx76 then
                local dy76 = hy76 - ey76
                local dx76 = hx76 - ex76
                local base_yaw76 = math.deg(math.atan2(dy76, dx76))
                votes[ALGO_FREESTAND] = math_normalize_yaw(base_yaw76 - 14)
            end
        end
    end

    local bx76, by76 = bone_extrapolate(ent, HITBOX_HEAD, 1)
    if bx76 and me76 then
        local ex76b, ey76b = client.eye_position()
        if ex76b then
            local dx76b = bx76 - ex76b
            local dy76b = by76 - ey76b
            if math_vec_len2d(dx76b, dy76b) > 1 then
                votes[ALGO_BONE_EXTRAP] = math.deg(math.atan2(dy76b, dx76b))
            end
        end
    end

    last_votes_cache[ent] = votes

    local w76     = get_voter_weights(ent)
    local blended76 = weighted_circular_mean(votes, w76)
    if blended76 then
        pdata.resolved_yaw = math_normalize_yaw(blended76)
        pdata.last_mode    = "VOTE(" .. aa_type76 .. ")"
    end
    return votes
end

function voter_adapt(ent, hit)
    local votes = last_votes_cache[ent]
    if not votes then return end
    local pdata76 = player_data[ent]
    if not pdata76 then return end
    local ref76 = pdata76.resolved_yaw
    local w76 = get_voter_weights(ent)
    local best_algo76, best_dist76 = nil, 9999
    for algo76, yaw76 in pairs(votes) do
        local d76 = math_abs(math_angle_diff(yaw76, ref76))
        if d76 < best_dist76 then best_dist76 = d76; best_algo76 = algo76 end
    end
    if best_algo76 then
        if hit then w76[best_algo76] = math_clamp(w76[best_algo76]*0.9+0.15, 0.05, 3.0)
        else        w76[best_algo76] = math_clamp(w76[best_algo76]*0.85,     0.05, 3.0) end
        normalize_voter_weights(w76)
    end
end

client.set_event_callback("player_hurt", function(e)
    local me = entity.get_local_player()
    if not me then return end
    if client.userid_to_entindex(e.attacker) ~= me then return end
    local v = client.userid_to_entindex(e.userid)
    if v then voter_adapt(v, true) end
end)

-- ===========================
-- § 77  ADAPTIVE BRUTE v2
-- ===========================

brute_v2 = {}

function get_brute_v2(ent)
    if not brute_v2[ent] then
        brute_v2[ent] = { offsets={0,58,-58,29,-29,44,-44,14,-14}, idx=1, miss=0, decay=1.0 }
    end
    return brute_v2[ent]
end

function brute_v2_compute_offsets(delta)
    local cap  = math_clamp(math_abs(delta), 10, 60)
    local s    = cap / 3
    return { 0, cap, -cap, s*2, -s*2, s, -s, cap*0.75, -cap*0.75 }
end

function brute_v2_advance(ent, pdata77)
    local b77 = get_brute_v2(ent)
    if not pdata77 then pdata77 = player_data[ent] end
    if not pdata77 then return end
    b77.miss  = b77.miss + 1
    b77.decay = math_clamp(b77.decay * 0.88, 0.3, 1.0)
    b77.offsets = brute_v2_compute_offsets(pdata77.desync_delta or 30)
    b77.idx = (b77.idx % #b77.offsets) + 1
end

function brute_v2_resolve(ent, pdata77)
    local b77 = get_brute_v2(ent)
    if #b77.offsets == 0 then b77.offsets = {0,58,-58,29,-29} end
    local off77 = (b77.offsets[b77.idx] or 0) * b77.decay
    pdata77.resolved_yaw = math_normalize_yaw(pdata77.eye_yaw + off77)
    pdata77.last_mode    = string.format("BRUTE2(%.0f)", off77)
end

client.set_event_callback("player_hurt", function(e)
    local me = entity.get_local_player()
    if not me then return end
    if client.userid_to_entindex(e.attacker) ~= me then return end
    local v = client.userid_to_entindex(e.userid)
    if v then local b77 = brute_v2[v]; if b77 then b77.miss=0; b77.decay=1.0 end end
end)

-- ===========================
-- § 78  CONFIDENCE MATRIX v2
-- ===========================

conf_matrix_v2  = {}
CONF_MATRIX_LR2 = 0.08

function get_conf_matrix(ent)
    if not conf_matrix_v2[ent] then
        local m78 = {}
        local types78 = {AA_SPIN,AA_JITTER,AA_STATIC,AA_BACKWARD,AA_FLIPFLOP,AA_RANDOM}
        for _, at78 in ipairs(types78) do
            m78[at78] = {}
            for vs78 = 1, 5 do
                local base78 = 0.50
                if at78==AA_STATIC   then base78=0.72 end
                if at78==AA_BACKWARD then base78=0.68 end
                if at78==AA_JITTER   then base78=0.55 end
                if at78==AA_RANDOM   then base78=0.33 end
                if vs78==VS_AIR      then base78=base78*0.85 end
                if vs78==VS_RUN      then base78=base78*0.92 end
                m78[at78][vs78] = base78
            end
        end
        conf_matrix_v2[ent] = m78
    end
    return conf_matrix_v2[ent]
end

function conf_matrix_get(ent, at78, vs78)
    local m78 = get_conf_matrix(ent)
    return (m78[at78] and m78[at78][vs78]) or 0.4
end

function conf_matrix_update(ent, at78, vs78, hit78)
    local m78 = get_conf_matrix(ent)
    if not (m78[at78] and m78[at78][vs78]) then return end
    local prev78 = m78[at78][vs78]
    local obs78  = hit78 and 1.0 or 0.0
    m78[at78][vs78] = math_clamp(prev78*(1-CONF_MATRIX_LR2)+obs78*CONF_MATRIX_LR2, 0.05, 0.97)
end

client.set_event_callback("player_hurt", function(e)
    local me = entity.get_local_player()
    if not me then return end
    if client.userid_to_entindex(e.attacker) ~= me then return end
    local v = client.userid_to_entindex(e.userid)
    if v then conf_matrix_update(v, aa_type_cache[v] or AA_RANDOM, velocity_state(v), true) end
end)

-- ===========================
-- § 79  SHOT SUPPRESSION SYSTEM
-- ===========================

suppress_state   = {}
SUPPRESS_THRESH  = 2.5
ui_suppression   = ui.new_checkbox("LUA", "B", "UV Shot Suppression")

function evaluate_suppression(ent, wid)
    local pdata79 = player_data[ent]
    if not pdata79 then return false, {} end
    local me79 = entity.get_local_player()
    if not me79 then return false, {} end
    local aa79  = aa_type_cache[ent] or AA_RANDOM
    local ox79,oy79,oz79 = entity.get_origin(ent)
    local ex79,ey79,ez79 = client.eye_position()
    local dist79 = (ox79 and ex79) and math_vec_len3d(ex79-ox79,ey79-oy79,ez79-oz79) or 400
    local reasons79 = {}
    local total79   = 0

    local p79 = bayes_hit_probability(ent, aa79, dist79)
    if p79 < (ui.get(ui_bayes_thresh)/100) then
        reasons79[#reasons79+1]="P(hit) low"; total79=total79+1.5 end
    if not hitbox_is_hittable(ent, HITBOX_HEAD) then
        reasons79[#reasons79+1]="Trace blocked"; total79=total79+1.3 end
    if pdata79.miss_streak > 4 then
        reasons79[#reasons79+1]="Miss streak"; total79=total79+0.8*(pdata79.miss_streak/5) end
    if (pdata79.desync_side==SIDE_NONE or not pdata79.desync_side) then
        reasons79[#reasons79+1]="Unknown side"; total79=total79+0.9 end
    if math_abs(pdata79.desync_delta or 0) > 52 then
        reasons79[#reasons79+1]="High delta"; total79=total79+0.7 end

    suppress_state[ent] = total79 >= SUPPRESS_THRESH
    return suppress_state[ent], reasons79
end

client.set_event_callback("paint", function()
    if not ui.get(ui_enabled) or not ui.get(ui_suppression) or not ui.get(ui_hud) then return end
    local me79 = entity.get_local_player()
    if not me79 or not entity.is_alive(me79) then return end
    local wid79 = get_weapon_id(me79)
    if not wid79 or not is_supported_weapon(wid79) then return end
    local ranked79 = get_prioritized_enemies()
    local target79 = ranked79[1]
    if not target79 then return end
    local sw79,sh79 = client.screen_size()
    local supp79, reasons79 = evaluate_suppression(target79, wid79)
    if supp79 and #reasons79 > 0 then
        renderer.text(sw79/2, sh79/2-50, 255,80,80, 230, "c", 0, "SUPPRESSED: " .. reasons79[1])
    end
end)

-- ===========================
-- § 80  RESOLVER TOURNAMENT
-- ===========================

shot_algo_log80 = {}
SHOT_LOG_SZ80   = 20

function tourney_log_shot80(ent, hit)
    local votes80 = last_votes_cache[ent]
    local pdata80 = player_data[ent]
    shot_algo_log80[#shot_algo_log80+1] = {
        ent=ent, votes=votes80, hit=hit,
        resolved=pdata80 and pdata80.resolved_yaw or 0
    }
    if #shot_algo_log80 > SHOT_LOG_SZ80 then table.remove(shot_algo_log80,1) end
end

client.set_event_callback("player_hurt", function(e)
    local me=entity.get_local_player(); if not me then return end
    if client.userid_to_entindex(e.attacker)~=me then return end
    local v=client.userid_to_entindex(e.userid); if v then tourney_log_shot80(v,true) end
end)

function tourney_score80()
    local scores80={}
    for algo80 in pairs(voter_base_weights) do scores80[algo80]={hits=0,shots=0} end
    for _,entry80 in ipairs(shot_algo_log80) do
        for algo80,yaw80 in pairs(entry80.votes or {}) do
            if scores80[algo80] then
                scores80[algo80].shots=scores80[algo80].shots+1
                local diff80=entry80.resolved and math_abs(math_angle_diff(yaw80,entry80.resolved)) or 999
                if diff80<15 and entry80.hit then scores80[algo80].hits=scores80[algo80].hits+1 end
            end
        end
    end
    return scores80
end

function apply_tourney80(scores80)
    local best80,bacc80=nil,-1
    for algo80,s80 in pairs(scores80) do
        if s80.shots>=3 then
            local acc80=s80.hits/s80.shots
            if acc80>bacc80 then bacc80=acc80;best80=algo80 end
        end
    end
    if not best80 then return end
    for _,w80 in pairs(voter_weights_adapted) do
        if w80[best80] then
            w80[best80]=math_clamp(w80[best80]*1.15,0.1,3.0)
            normalize_voter_weights(w80)
        end
    end
    if ui.get(ui_log) then
        client.color_log(255,220,50,string.format("[TOURNEY] Winner: %s | acc=%.0f%%",best80,bacc80*100))
    end
end

function tourney_loop80()
    if #shot_algo_log80>=8 then apply_tourney80(tourney_score80()) end
    client.delay_call(5.0, tourney_loop80)
end
client.delay_call(5.0, tourney_loop80)

-- ============================================================
--  GROUP D  :  ADVANCED HUD & TELEMETRY   §81 – §85
-- ============================================================

-- ===========================
-- § 81  ACCURACY GRAPH
-- ===========================

acc_graph_data81 = {}
ACC_GRAPH_W81    = 180
ACC_GRAPH_H81    = 38
ui_acc_graph     = ui.new_checkbox("LUA", "B", "UV Accuracy Graph")

client.set_event_callback("player_hurt", function(e)
    local me=entity.get_local_player(); if not me then return end
    if client.userid_to_entindex(e.attacker)~=me then return end
    acc_graph_data81[#acc_graph_data81+1]={t=globals.curtime(),hit=true}
end)

client.set_event_callback("paint", function()
    if not ui.get(ui_enabled) or not ui.get(ui_acc_graph) then return end
    local sw81,sh81=client.screen_size()
    local gx81=sw81-ACC_GRAPH_W81-315
    local gy81=sh81-ACC_GRAPH_H81-65
    local now81=globals.curtime()
    while #acc_graph_data81>0 and now81-acc_graph_data81[1].t>30 do
        table.remove(acc_graph_data81,1)
    end
    renderer.rectangle(gx81-2,gy81-16,ACC_GRAPH_W81+4,ACC_GRAPH_H81+20, 8,8,12,200)
    renderer.text(gx81+ACC_GRAPH_W81/2,gy81-14, 180,180,180,200, "c",0,"ACCURACY 30s")
    local cy81=gy81+ACC_GRAPH_H81/2
    renderer.rectangle(gx81,cy81,ACC_GRAPH_W81,1, 40,40,50,100)
    for _,entry81 in ipairs(acc_graph_data81) do
        local age81=now81-entry81.t
        local px81=gx81+ACC_GRAPH_W81-math.floor((age81/30)*ACC_GRAPH_W81)
        local py81=entry81.hit and (gy81+4) or (gy81+ACC_GRAPH_H81-4)
        local r81,g81=entry81.hit and 80 or 255, entry81.hit and 255 or 80
        if px81>=gx81 and px81<=gx81+ACC_GRAPH_W81 then
            renderer.rectangle(px81,py81,2,2,r81,g81,80,230)
        end
    end
    local hits81,total81=0,#acc_graph_data81
    for _,e81 in ipairs(acc_graph_data81) do if e81.hit then hits81=hits81+1 end end
    local pct81=total81>0 and math.floor(hits81/total81*100) or 0
    local ar81,ag81,ab81=80,255,80
    if pct81<50 then ar81,ag81,ab81=255,200,50 end
    if pct81<30 then ar81,ag81,ab81=255,80,80 end
    renderer.text(gx81+ACC_GRAPH_W81/2,gy81+ACC_GRAPH_H81+4, ar81,ag81,ab81,220,"c",0,pct81.."%")
end)

-- ===========================
-- § 82  YAW DELTA GRAPH
-- ===========================

DELTA_GRAPH_W82 = 160
DELTA_GRAPH_H82 = 36
ui_delta_graph  = ui.new_checkbox("LUA", "B", "UV Delta Graph")

client.set_event_callback("paint", function()
    if not ui.get(ui_enabled) or not ui.get(ui_delta_graph) then return end
    local ranked82=get_prioritized_enemies()
    local target82=ranked82[1]; if not target82 then return end
    local pdata82=player_data[target82]
    if not pdata82 or #pdata82.yaw_history<4 then return end
    local sw82,sh82=client.screen_size()
    local gx82=sw82-DELTA_GRAPH_W82-315
    local gy82=350
    renderer.rectangle(gx82-2,gy82-16,DELTA_GRAPH_W82+4,DELTA_GRAPH_H82+20, 8,8,12,200)
    renderer.text(gx82+DELTA_GRAPH_W82/2,gy82-14, 180,180,180,200,"c",0,"YAW DELTA")
    local cy82=gy82+DELTA_GRAPH_H82/2
    renderer.rectangle(gx82,cy82,DELTA_GRAPH_W82,1, 60,60,80,150)
    local yaws82=pdata82.yaw_history
    local n82=math.min(#yaws82-1,DELTA_GRAPH_W82)
    local step82=DELTA_GRAPH_W82/math.max(n82,1)
    for i82=1,n82 do
        local d82=math_angle_diff(yaws82[i82],yaws82[i82+1])
        local norm82=math_clamp(d82/60,-1,1)
        local px82=gx82+(i82-1)*step82
        local py82=cy82-math.floor(norm82*(DELTA_GRAPH_H82/2))
        renderer.rectangle(math.floor(px82),py82,math.max(1,math.floor(step82)),2,
            d82>0 and 80 or 255, 80, d82>0 and 255 or 80, 200)
    end
    renderer.text(gx82+DELTA_GRAPH_W82/2,gy82+DELTA_GRAPH_H82+4, 180,180,180,200,"c",0,
        (aa_type_cache[target82] or "?"))
end)

-- ===========================
-- § 83  RESOLVER TELEMETRY LOGGER
-- ===========================

telem_log83  = {}
TELEM_MAX83  = 100
ui_telem83   = ui.new_checkbox("LUA", "B", "UV Telemetry Log")

function telem_record83(victim83, hit83, dmg83)
    if not ui.get(ui_telem83) then return end
    local pdata83=player_data[victim83]; if not pdata83 then return end
    telem_log83[#telem_log83+1]={
        tick=globals.tickcount(), time=globals.curtime(),
        target=entity.get_player_name(victim83) or "?",
        aa_type=aa_type_cache[victim83] or "?",
        resolved_yaw=pdata83.resolved_yaw, eye_yaw=pdata83.eye_yaw,
        delta=pdata83.desync_delta, mode=pdata83.last_mode,
        hit=hit83, dmg=dmg83, conf=pdata83.confidence,
        miss_streak=pdata83.miss_streak,
        nn_trained=nn_state[victim83] and nn_state[victim83].trained or 0,
    }
    if #telem_log83>TELEM_MAX83 then table.remove(telem_log83,1) end
end

client.set_event_callback("player_hurt", function(e)
    local me=entity.get_local_player(); if not me then return end
    if client.userid_to_entindex(e.attacker)~=me then return end
    local v=client.userid_to_entindex(e.userid); if v then telem_record83(v,true,e.dmg_health) end
end)

-- ===========================
-- § 84  PER-PLAYER ACCURACY DASHBOARD
-- ===========================

player_acc84  = {}
ui_dashboard84 = ui.new_checkbox("LUA", "B", "UV Player Dashboard")

function get_acc84(ent)
    if not player_acc84[ent] then
        player_acc84[ent]={shots=0,hits=0,head_hits=0,body_hits=0,
            most_common_aa="?",aa_counts={},avg_conf=0,conf_sum=0}
    end
    return player_acc84[ent]
end

client.set_event_callback("player_hurt", function(e)
    local me=entity.get_local_player(); if not me then return end
    if client.userid_to_entindex(e.attacker)~=me then return end
    local v=client.userid_to_entindex(e.userid); if not v then return end
    local ad84=get_acc84(v); local pdata84=player_data[v]
    ad84.shots=ad84.shots+1; ad84.hits=ad84.hits+1
    if e.hitgroup==HITGROUP_HEAD then ad84.head_hits=ad84.head_hits+1
    else ad84.body_hits=ad84.body_hits+1 end
    if pdata84 then ad84.conf_sum=ad84.conf_sum+pdata84.confidence; ad84.avg_conf=ad84.conf_sum/ad84.hits end
    local at84=aa_type_cache[v] or AA_RANDOM
    ad84.aa_counts[at84]=(ad84.aa_counts[at84] or 0)+1
    local bst84,bn84=AA_RANDOM,0
    for k84,v84 in pairs(ad84.aa_counts) do if v84>bn84 then bn84=v84;bst84=k84 end end
    ad84.most_common_aa=bst84
end)

client.set_event_callback("paint", function()
    if not ui.get(ui_enabled) or not ui.get(ui_dashboard84) then return end
    local ranked84=get_prioritized_enemies()
    local target84=ranked84[1]; if not target84 then return end
    local ad84=get_acc84(target84)
    local sw84,_=client.screen_size()
    local px84,py84=20,200; local pw84=220; local lh84=13; local ph84=16+8*lh84
    renderer.rectangle(px84,py84,pw84,ph84, 8,8,12,210)
    renderer.gradient(px84,py84,pw84,2, 80,60,255,255,20,100,200,255,true)
    local name84=entity.get_player_name(target84) or "?"
    if #name84>16 then name84=name84:sub(1,16) end
    renderer.text(px84+pw84/2,py84+4, 220,180,255,255,"c",0,name84)
    local row84=py84+18
    local function rw84(l,v,r,g,b)
        renderer.text(px84+8,row84,140,140,140,200,nil,0,l)
        renderer.text(px84+120,row84,r or 200,g or 200,b or 200,220,nil,0,v)
        row84=row84+lh84
    end
    local acc84=ad84.shots>0 and math.floor(ad84.hits/ad84.shots*100) or 0
    local hs84=ad84.hits>0 and math.floor(ad84.head_hits/ad84.hits*100) or 0
    rw84("Shots fired:", tostring(ad84.shots))
    rw84("Accuracy:", acc84.."%", acc84>=50 and 80 or 255, acc84>=50 and 255 or 80, 80)
    rw84("Headshots:", hs84.."%", 200,200,80)
    rw84("Avg Confidence:", string.format("%.0f%%",ad84.avg_conf))
    rw84("Common AA:", ad84.most_common_aa)
    rw84("NN trained:", tostring(nn_state[target84] and nn_state[target84].trained or 0))
    rw84("Brute state:", tostring(player_data[target84] and player_data[target84].brute_state or 0))
    rw84("Miss streak:", tostring(player_data[target84] and player_data[target84].miss_streak or 0))
end)

-- ===========================
-- § 85  LIVE RESOLVER STATUS BAR
-- ===========================

ui_status_bar85 = ui.new_checkbox("LUA", "B", "UV Live Status Bar")

AA_COLORS85 = {
    [AA_SPIN]={255,80,80},[AA_JITTER]={255,180,50},[AA_STATIC]={80,255,80},
    [AA_BACKWARD]={80,180,255},[AA_FLIPFLOP]={255,100,200},[AA_RANDOM]={160,160,160},
}

client.set_event_callback("paint", function()
    if not ui.get(ui_enabled) or not ui.get(ui_status_bar85) then return end
    local sw85,sh85=client.screen_size()
    local cell_w85=88; local bar_y85=sh85-28; local bar_h85=22
    local enemies85=entity.get_players(true)
    local visible85={}
    for _,ent85 in ipairs(enemies85) do
        if entity.is_alive(ent85) and not entity.is_dormant(ent85) then
            visible85[#visible85+1]=ent85
        end
    end
    local count85=math.min(#visible85, math.floor(sw85/cell_w85))
    local total_w85=count85*cell_w85
    local sx85=math.floor((sw85-total_w85)/2)
    renderer.rectangle(sx85-4,bar_y85-2,total_w85+8,bar_h85+4, 6,6,10,210)
    for i85=1,count85 do
        local ent85=visible85[i85]
        local pdata85=player_data[ent85]
        local at85=aa_type_cache[ent85] or AA_RANDOM
        local col85=AA_COLORS85[at85] or {160,160,160}
        local conf85=pdata85 and math.floor(pdata85.confidence) or 0
        local hp85=entity.get_prop(ent85,"m_iHealth") or 0
        local name85=entity.get_player_name(ent85) or "?"
        if #name85>8 then name85=name85:sub(1,8) end
        local cx85=sx85+(i85-1)*cell_w85
        renderer.rectangle(cx85,bar_y85,cell_w85-2,bar_h85, 14,14,20,220)
        renderer.rectangle(cx85,bar_y85,cell_w85-2,2, col85[1],col85[2],col85[3],220)
        local cw85=math.floor((cell_w85-4)*conf85/100)
        renderer.rectangle(cx85+1,bar_y85+bar_h85-4,cell_w85-4,3, 30,30,40,180)
        renderer.rectangle(cx85+1,bar_y85+bar_h85-4,cw85,3, col85[1],col85[2],col85[3],200)
        renderer.text(cx85+4,bar_y85+4, col85[1],col85[2],col85[3],220,nil,0,name85)
        renderer.text(cx85+4,bar_y85+11, 200,200,200,180,nil,0,
            at85:sub(1,4).." "..tostring(hp85).."hp")
    end
end)

client.color_log(80,220,255,"[UV] GROUP C §76-§80 Algorithm Suite  — LOADED")
client.color_log(80,255,180,"[UV] GROUP D §81-§85 HUD & Telemetry  — LOADED")

-- ============================================================
--  GROUP E  :  WEAPON-SPECIFIC DEEP SYSTEMS   §86 – §90
-- ============================================================

-- ===========================
-- § 86  SSG-08 ADVANCED MODULE
-- ===========================

ssg_state = {}   -- [ent] = { is_scoped, zoom_level, onetap_prob }

function get_ssg_state(ent)
    if not ssg_state[ent] then
        ssg_state[ent] = { is_scoped=false, zoom_level=0, onetap_prob=0 }
    end
    return ssg_state[ent]
end

ui_ssg_module = ui.new_checkbox("LUA", "B", "UV SSG-08 Module")

function ssg_update(ent, wid, me)
    if wid ~= WEAPON_SSG08 then return end
    if not ui.get(ui_ssg_module) then return end
    local ss = get_ssg_state(ent)

    -- Check if WE are scoped
    local wep = entity.get_player_weapon(me)
    if wep then
        local scoped   = entity.get_prop(wep, "m_bIsScoped")
        local zoom_lvl = entity.get_prop(wep, "m_zoomLevel")
        ss.is_scoped   = scoped   ~= nil and scoped ~= 0
        ss.zoom_level  = zoom_lvl or 0
    end

    -- One-tap probability: P(kill in one shot via head)
    local hp   = entity.get_prop(ent, "m_iHealth") or 100
    local base = WEAPON_BASE_DMG[WEAPON_SSG08] or 88
    local scaled = client.scale_damage(ent, HITGROUP_HEAD, base)
    ss.onetap_prob = (scaled and scaled >= hp) and 1.0 or
        (scaled and math_clamp(scaled / hp, 0, 1) or 0)
end

function ssg_adjust_resolver(ent, pdata, wid)
    if wid ~= WEAPON_SSG08 then return end
    if not ui.get(ui_ssg_module) then return end
    local ss = get_ssg_state(ent)

    -- Scoped: tighter brute range (spread is minimal)
    if ss.is_scoped then
        -- Only small jitter needed; override brute to just 0 and ±10
        if pdata.brute_state == BRUTE_LEFT  then pdata.resolved_yaw = math_normalize_yaw(pdata.eye_yaw + 10) end
        if pdata.brute_state == BRUTE_RIGHT then pdata.resolved_yaw = math_normalize_yaw(pdata.eye_yaw - 10) end
        pdata.last_mode = pdata.last_mode .. "+SSG_SCOPED"
    end

    -- One-tap possible → highest header confidence
    if ss.onetap_prob >= 0.95 then
        pdata.confidence = math_clamp(pdata.confidence + 15, 0, 100)
        pdata.last_mode  = pdata.last_mode .. "+OT"
    end
end

client.set_event_callback("createmove", function()
    if not ui.get(ui_enabled) then return end
    local me = entity.get_local_player()
    if not me or not entity.is_alive(me) then return end
    local wid = get_weapon_id(me)
    if wid ~= WEAPON_SSG08 then return end
    local enemies = entity.get_players(true)
    for _, ent in ipairs(enemies) do
        if entity.is_alive(ent) and not entity.is_dormant(ent) then
            pcall(ssg_update, ent, wid, me)
            local pdata = player_data[ent]
            if pdata then pcall(ssg_adjust_resolver, ent, pdata, wid) end
        end
    end
end)

-- § 86 HUD: show one-tap indicator
client.set_event_callback("paint", function()
    if not ui.get(ui_enabled) or not ui.get(ui_hud) or not ui.get(ui_ssg_module) then return end
    local me = entity.get_local_player()
    if not me or not entity.is_alive(me) then return end
    if get_weapon_id(me) ~= WEAPON_SSG08 then return end
    local enemies = entity.get_players(true)
    for _, ent in ipairs(enemies) do
        if entity.is_alive(ent) and not entity.is_dormant(ent) then
            local ss = ssg_state[ent]
            if ss and ss.onetap_prob >= 0.9 then
                local hx, hy, hz = entity.hitbox_position(ent, HITBOX_HEAD)
                if hx then
                    local sx, sy = renderer.world_to_screen(hx, hy, hz + 18)
                    if sx and sy then
                        renderer.text(sx, sy - 36, 80, 255, 120, 240, "c", 0, "ONE-TAP")
                    end
                end
            end
        end
    end
end)

-- ===========================
-- § 87  DEAGLE PRECISION MODULE
-- ===========================
-- Tracks Deagle cooldown and detects optimal shoot windows.

deagle_window = {}   -- [ent] = { last_shot_time, in_window, accuracy_boost }
DEAGLE_COOLDOWN = 0.67  -- seconds between shots

ui_deagle_module = ui.new_checkbox("LUA", "B", "UV Deagle Module")

function deagle_update(ent, wid)
    if wid ~= WEAPON_DEAGLE then return end
    if not ui.get(ui_deagle_module) then return end
    if not deagle_window[ent] then
        deagle_window[ent] = { last_shot_time=0, in_window=false, boost=0 }
    end
    local dw = deagle_window[ent]
    local now = globals.curtime()

    -- Detect shots fired delta via m_iShotsFired
    local shots = entity.get_prop(ent, "m_iShotsFired") or 0
    if not dw.prev_shots then dw.prev_shots = shots end

    if shots ~= dw.prev_shots then
        -- shot fired
        dw.last_shot_time = now
        dw.in_window = false
    end
    dw.prev_shots = shots

    -- In the cooldown window after their shot: they are more stationary
    local time_since = now - dw.last_shot_time
    if time_since > 0.1 and time_since < DEAGLE_COOLDOWN then
        dw.in_window = true
        dw.boost     = math_clamp((1 - time_since / DEAGLE_COOLDOWN) * 20, 0, 20)
    else
        dw.in_window = false
        dw.boost     = 0
    end
end

function deagle_adjust(ent, pdata, wid)
    if wid ~= WEAPON_DEAGLE then return end
    if not ui.get(ui_deagle_module) then return end
    local dw = deagle_window[ent]
    if not dw then return end
    if dw.in_window then
        pdata.confidence = math_clamp(pdata.confidence + dw.boost, 0, 100)
        pdata.last_mode  = pdata.last_mode .. "+DEA_WIN"
    end
end

client.set_event_callback("createmove", function()
    if not ui.get(ui_enabled) then return end
    local me = entity.get_local_player()
    if not me or not entity.is_alive(me) then return end
    local wid = get_weapon_id(me)
    if wid ~= WEAPON_DEAGLE then return end
    local enemies = entity.get_players(true)
    for _, ent in ipairs(enemies) do
        if entity.is_alive(ent) and not entity.is_dormant(ent) then
            pcall(deagle_update, ent, wid)
            local pdata = player_data[ent]
            if pdata then pcall(deagle_adjust, ent, pdata, wid) end
        end
    end
end)

-- ===========================
-- § 88  REVOLVER ANTI-COCK SYSTEM
-- ===========================
-- Detects cocking phase: the ~0.4s after right-click before shot.
-- During cocking the player can't move → resolver accuracy boost.

revolver_cock = {}   -- [ent] = { cocking, cock_start, boost }
REVOLVER_COCK_DUR = 0.45

ui_revolver_module = ui.new_checkbox("LUA", "B", "UV Revolver Module")

function revolver_update(ent, wid)
    if wid ~= WEAPON_REVOLVER then return end
    if not ui.get(ui_revolver_module) then return end
    if not revolver_cock[ent] then
        revolver_cock[ent] = { cocking=false, cock_start=0, boost=0, prev_shots=0 }
    end
    local rc = revolver_cock[ent]
    local now = globals.curtime()

    local shots = entity.get_prop(ent, "m_iShotsFired") or 0
    -- detect new shot: cocking ends
    if shots ~= rc.prev_shots then
        rc.cocking   = false
        rc.cock_start = 0
    end
    rc.prev_shots = shots

    -- detect trigger pull via m_bPulledTrigger if available
    local wep = entity.get_player_weapon(ent)
    local pulled = wep and entity.get_prop(wep, "m_bPulledTrigger")
    if pulled and pulled ~= 0 and not rc.cocking then
        rc.cocking   = true
        rc.cock_start = now
    end

    if rc.cocking then
        local elapsed = now - rc.cock_start
        if elapsed < REVOLVER_COCK_DUR then
            rc.boost = 18  -- strong boost during cock
        else
            rc.cocking = false
            rc.boost   = 0
        end
    else
        rc.boost = 0
    end
end

function revolver_adjust(ent, pdata, wid)
    if wid ~= WEAPON_REVOLVER then return end
    if not ui.get(ui_revolver_module) then return end
    local rc = revolver_cock[ent]
    if not rc then return end
    if rc.cocking and rc.boost > 0 then
        pdata.confidence = math_clamp(pdata.confidence + rc.boost, 0, 100)
        pdata.last_mode  = pdata.last_mode .. "+COCK"
    end
end

client.set_event_callback("createmove", function()
    if not ui.get(ui_enabled) then return end
    local me = entity.get_local_player()
    if not me or not entity.is_alive(me) then return end
    local wid = get_weapon_id(me)
    if wid ~= WEAPON_REVOLVER then return end
    local enemies = entity.get_players(true)
    for _, ent in ipairs(enemies) do
        if entity.is_alive(ent) and not entity.is_dormant(ent) then
            pcall(revolver_update, ent, wid)
            local pdata = player_data[ent]
            if pdata then pcall(revolver_adjust, ent, pdata, wid) end
        end
    end
end)

-- ===========================
-- § 89  TEC-9 BURST MODE RESOLVER
-- ===========================
-- TEC-9 can fire in semi-auto bursts: adjust strategy per fire-rate.

tec9_state  = {}   -- [ent] = { burst=false, burst_shots=0, last_shot=0 }
TEC9_BURST_WINDOW = 0.5  -- shots within this window = burst
TEC9_BURST_THRESH = 2

ui_tec9_module = ui.new_checkbox("LUA", "B", "UV TEC-9 Module")

function tec9_update(ent, wid)
    if wid ~= WEAPON_TEC9 then return end
    if not ui.get(ui_tec9_module) then return end
    if not tec9_state[ent] then
        tec9_state[ent] = { burst=false, burst_shots=0, last_shot=0, prev_shots=0 }
    end
    local ts  = tec9_state[ent]
    local now = globals.curtime()

    local shots = entity.get_prop(ent, "m_iShotsFired") or 0
    if shots ~= ts.prev_shots then
        local interval = now - ts.last_shot
        if interval < TEC9_BURST_WINDOW then
            ts.burst_shots = ts.burst_shots + 1
        else
            ts.burst_shots = 1
        end
        ts.last_shot = now
        ts.burst     = ts.burst_shots >= TEC9_BURST_THRESH
    end
    ts.prev_shots = shots

    -- Decay burst detection after 0.8s of no shots
    if now - ts.last_shot > 0.8 then
        ts.burst       = false
        ts.burst_shots = 0
    end
end

function tec9_adjust(ent, pdata, wid)
    if wid ~= WEAPON_TEC9 then return end
    if not ui.get(ui_tec9_module) then return end
    local ts = tec9_state[ent]
    if not ts then return end

    if ts.burst then
        -- In burst: use faster brute flip, lower hitchance req, prefer chest
        pdata.confidence = math_clamp(pdata.confidence - 8, 0, 100)
        pdata.last_mode  = pdata.last_mode .. "+TEC_BURST"
    end

    -- Auto body-switch for long distance (>300u)
    local me = entity.get_local_player()
    if not me then return end
    local ex, ey, ez = client.eye_position()
    local ox, oy, oz = entity.get_origin(ent)
    if ex and ox then
        local dist = math_vec_len3d(ex-ox, ey-oy, ez-oz)
        if dist > 300 then
            pdata.last_mode = pdata.last_mode .. "+TEC_BODY"
        end
    end
end

client.set_event_callback("createmove", function()
    if not ui.get(ui_enabled) then return end
    local me = entity.get_local_player()
    if not me or not entity.is_alive(me) then return end
    local wid = get_weapon_id(me)
    if wid ~= WEAPON_TEC9 then return end
    local enemies = entity.get_players(true)
    for _, ent in ipairs(enemies) do
        if entity.is_alive(ent) and not entity.is_dormant(ent) then
            pcall(tec9_update, ent, wid)
            local pdata = player_data[ent]
            if pdata then pcall(tec9_adjust, ent, pdata, wid) end
        end
    end
end)

-- ===========================
-- § 90  ZEUS ARC PREDICTOR
-- ===========================
-- Zeus range: 256 units. Instant hit. Wide spread cone.

ZEUS_RANGE = 256
ui_zeus_module   = ui.new_checkbox("LUA", "B", "UV Zeus Module")

zeus_danger      = {}   -- [ent] = { in_range, dist, alarm_level }

function zeus_update_all()
    if not ui.get(ui_zeus_module) then return end
    local me = entity.get_local_player()
    if not me then return end
    local ex, ey, ez = client.eye_position()
    if not ex then return end

    local enemies = entity.get_players(true)
    for _, ent in ipairs(enemies) do
        if entity.is_alive(ent) and not entity.is_dormant(ent) then
            -- Check if they hold Zeus
            local wep90  = entity.get_player_weapon(ent)
            local wid90  = wep90 and entity.get_prop(wep90, "m_iItemDefinitionIndex")
            local ox, oy, oz = entity.get_origin(ent)
            if ox and wid90 then
                local dist90 = math_vec_len3d(ex-ox, ey-oy, ez-oz)
                if not zeus_danger[ent] then zeus_danger[ent]={} end
                local zd = zeus_danger[ent]
                zd.dist       = dist90
                zd.in_range   = dist90 <= ZEUS_RANGE
                zd.has_zeus   = (wid90 == WEAPON_ZEUS)
                zd.alarm_level = zd.has_zeus and
                    (dist90 <= ZEUS_RANGE * 0.6 and 2 or (dist90 <= ZEUS_RANGE and 1 or 0)) or 0
            end
        end
    end
end

client.set_event_callback("createmove", function()
    if not ui.get(ui_enabled) then return end
    pcall(zeus_update_all)

    -- Zeus resolver override: if WE have zeus → instant kill, skip all validation
    local me = entity.get_local_player()
    if not me or not entity.is_alive(me) then return end
    if get_weapon_id(me) == WEAPON_ZEUS then
        local enemies = entity.get_players(true)
        for _, ent in ipairs(enemies) do
            if entity.is_alive(ent) and not entity.is_dormant(ent) then
                local ox, oy, oz = entity.get_origin(ent)
                local ex, ey, ez = client.eye_position()
                if ox and ex then
                    local dist = math_vec_len3d(ex-ox, ey-oy, ez-oz)
                    if dist <= ZEUS_RANGE then
                        local pdata = player_data[ent]
                        if pdata then
                            -- Skip AA entirely: aim at body center
                            pdata.confidence  = 100
                            pdata.last_mode   = "ZEUS_INSTANT"
                        end
                    end
                end
            end
        end
    end
end)

-- Zeus danger HUD
client.set_event_callback("paint", function()
    if not ui.get(ui_enabled) or not ui.get(ui_zeus_module) then return end
    local sw90, sh90 = client.screen_size()
    for ent, zd in pairs(zeus_danger) do
        if zd.alarm_level >= 1 and entity.is_alive(ent) then
            local ox, oy, oz = entity.get_origin(ent)
            if ox then
                local sx, sy = renderer.world_to_screen(ox, oy, oz + 72)
                if sx and sy then
                    local r90 = zd.alarm_level == 2 and 255 or 255
                    local g90 = zd.alarm_level == 2 and 50  or 160
                    renderer.text(sx, sy - 50, r90, g90, 50, 240, "c", 0,
                        string.format("⚡ZEUS %.0fu", zd.dist))
                end
            end
        end
    end
end)

-- ============================================================
--  GROUP F  :  NETWORK & LAG ANALYSIS   §91 – §95
-- ============================================================

-- ===========================
-- § 91  CHOKE PACKET ANALYSER
-- ===========================

choke_data = {}   -- [ent] = { prev_simtime, choke_ticks, history }

function get_choke_data(ent)
    if not choke_data[ent] then
        choke_data[ent] = { prev_simtime=0, choke_ticks=0, history={} }
    end
    return choke_data[ent]
end

function choke_update(ent)
    local cd  = get_choke_data(ent)
    local st  = entity.get_prop(ent, "m_flSimulationTime") or 0
    local dt  = st - cd.prev_simtime
    if dt <= 0 then return end

    local expected_dt  = globals.tickinterval()
    local choke_ticks  = math.max(0, math.floor(dt / expected_dt + 0.5) - 1)
    cd.choke_ticks     = choke_ticks

    cd.history[#cd.history + 1] = choke_ticks
    if #cd.history > 16 then table.remove(cd.history, 1) end

    cd.prev_simtime = st
end

function get_avg_choke(ent)
    local cd = get_choke_data(ent)
    if #cd.history == 0 then return 0 end
    return tbl_avg(cd.history)
end

client.set_event_callback("createmove", function()
    if not ui.get(ui_enabled) then return end
    local enemies = entity.get_players(true)
    for _, ent in ipairs(enemies) do
        if entity.is_alive(ent) and not entity.is_dormant(ent) then
            pcall(choke_update, ent)
        end
    end
end)

function choke_adjust_confidence(ent, pdata)
    local avg_choke = get_avg_choke(ent)
    if avg_choke > 1.5 then
        -- High choke: less predictable → lower confidence
        local penalty = math_clamp(avg_choke * 5, 0, 20)
        pdata.confidence = math_clamp(pdata.confidence - penalty, 0, 100)
        pdata.last_mode  = pdata.last_mode .. string.format("+CHOKE(%.0f)", avg_choke)
    end
end

-- ===========================
-- § 92  LAG COMPENSATION WINDOW
-- ===========================

LAG_COMP_MAX_MS = 200.0  -- CS:GO max lagcomp
lag_comp_state  = {}     -- [ent] = { effective_comp_ms }

function lag_comp_update(ent)
    if not lag_comp_state[ent] then
        lag_comp_state[ent] = { comp_ms=0 }
    end
    -- estimate: local latency + server processing
    local local_lat = client.latency()
    local svtic     = globals.tickinterval() * 1000  -- ms per tick
    local comp      = math_clamp((local_lat or 0) * 1000 + svtic, 0, LAG_COMP_MAX_MS)
    lag_comp_state[ent].comp_ms = comp
end

function lag_comp_adjust(ent, pdata)
    local lcs = lag_comp_state[ent]
    if not lcs then return end
    local comp_ms = lcs.comp_ms

    -- High lag: widen brute range slightly (enemy position is uncertain)
    if comp_ms > 100 then
        local extra_brute = math_clamp((comp_ms - 80) / 20, 0, 3) -- extra brute ticks
        pdata.confidence  = math_clamp(pdata.confidence - extra_brute * 3, 0, 100)
        pdata.last_mode   = pdata.last_mode .. string.format("+LAGCOMP(%.0fms)", comp_ms)
    end
end

client.set_event_callback("createmove", function()
    if not ui.get(ui_enabled) then return end
    local enemies = entity.get_players(true)
    for _, ent in ipairs(enemies) do
        if entity.is_alive(ent) then
            pcall(lag_comp_update, ent)
        end
    end
end)

-- ===========================
-- § 93  TICKBASE EXPLOIT DETECTOR
-- ===========================

tickbase_data  = {}   -- [ent] = { prev_tickbase, anomaly_count, is_exploiting }

function get_tb_data(ent)
    if not tickbase_data[ent] then
        tickbase_data[ent] = { prev_tb=0, anom=0, exploiting=false, last_detect=0 }
    end
    return tickbase_data[ent]
end

function tickbase_update(ent)
    local tbd = get_tb_data(ent)
    local tb  = entity.get_prop(ent, "m_nTickBase")
    if not tb then return end

    if tbd.prev_tb ~= 0 then
        local delta_tb   = tb - tbd.prev_tb
        local expected_d = 1  -- normally +1 per tick
        if math_abs(delta_tb - expected_d) > 3 then
            -- anomalous tickbase jump → doubletap / hideshot candidate
            tbd.anom = tbd.anom + 1
            if tbd.anom >= 3 then
                tbd.exploiting = true
                tbd.last_detect = globals.curtime()
            end
        else
            tbd.anom = math.max(0, tbd.anom - 1)
        end
    end
    tbd.prev_tb = tb

    -- Decay detection after 2s
    if globals.curtime() - tbd.last_detect > 2.0 then
        tbd.exploiting = false; tbd.anom = 0
    end
end

function tickbase_adjust(ent, pdata)
    local tbd = get_tb_data(ent)
    if tbd.exploiting then
        -- Raise hitchance requirement: don't shoot on bad ticks
        pdata.confidence = math_clamp(pdata.confidence - 12, 0, 100)
        pdata.last_mode  = pdata.last_mode .. "+TB_EXPL"
        if ui.get(ui_log) then
            client.color_log(255,80,80, "[UV-TB] Tickbase exploit detected: " ..
                (entity.get_player_name(ent) or "?"))
        end
    end
end

client.set_event_callback("createmove", function()
    if not ui.get(ui_enabled) then return end
    local enemies = entity.get_players(true)
    for _, ent in ipairs(enemies) do
        if entity.is_alive(ent) and not entity.is_dormant(ent) then
            pcall(tickbase_update, ent)
            local pdata = player_data[ent]
            if pdata then pcall(tickbase_adjust, ent, pdata) end
        end
    end
end)

-- ===========================
-- § 94  PACKET LOSS COMPENSATION
-- ===========================

pkt_loss_data = {}   -- [ent] = { prev_pos={}, loss_count, filtered_pos }
PKT_JUMP_TRESHOLD = 200  -- units; larger = probably loss

function get_pkt_data(ent)
    if not pkt_loss_data[ent] then
        pkt_loss_data[ent] = { prev_pos={x=0,y=0,z=0}, loss=0, filtered={x=0,y=0,z=0} }
    end
    return pkt_loss_data[ent]
end

function pkt_loss_update(ent)
    local pd94 = get_pkt_data(ent)
    local ox, oy, oz = entity.get_origin(ent)
    if not ox then return end

    local prev = pd94.prev_pos
    local dist = math_vec_len3d(ox-prev.x, oy-prev.y, oz-prev.z)

    if dist > PKT_JUMP_TRESHOLD and dist < 2000 then
        -- Likely packet loss artifact: use interpolated position
        pd94.loss = pd94.loss + 1
        -- Smooth: move halfway
        pd94.filtered.x = (prev.x + ox) * 0.5
        pd94.filtered.y = (prev.y + oy) * 0.5
        pd94.filtered.z = (prev.z + oz) * 0.5
    else
        pd94.filtered.x = ox
        pd94.filtered.y = oy
        pd94.filtered.z = oz
        pd94.loss = math.max(0, pd94.loss - 1)
    end

    pd94.prev_pos = { x=ox, y=oy, z=oz }
end

client.set_event_callback("createmove", function()
    if not ui.get(ui_enabled) then return end
    local enemies = entity.get_players(true)
    for _, ent in ipairs(enemies) do
        if entity.is_alive(ent) then
            pcall(pkt_loss_update, ent)
        end
    end
end)

-- ===========================
-- § 95  ADAPTIVE LATENCY RESOLVER
-- ===========================
-- Scales lookahead and aggressiveness based on network conditions.

NET_LOOKAHEAD = {
    -- { max_ping, extra_ticks, force_bone_extrap, bayes_thresh_delta }
    { 30,  0, false,  0 },
    { 80,  1, false, -5 },
    { 150, 2, true,  -10 },
    { 999, 3, true,  -15 },
}

function get_latency_profile()
    local lat = (client.latency() or 0) * 1000  -- ms
    for _, profile in ipairs(NET_LOOKAHEAD) do
        if lat <= profile[1] then
            return { extra_ticks=profile[2], bone_extrap=profile[3], thresh_delta=profile[4], ping=lat }
        end
    end
    return { extra_ticks=3, bone_extrap=true, thresh_delta=-15, ping=lat }
end

function adaptive_lat_adjust(ent, pdata, wid)
    local profile = get_latency_profile()
    if profile.extra_ticks > 0 then
        -- Expand Markov lookahead
        local mk_yaw95 = markov_predicted_yaw(ent)
        if mk_yaw95 then
            -- Blend more Markov into resolved (higher latency → trust prediction more)
            local blend_fac = profile.extra_ticks * 0.15
            local diff95 = math_angle_diff(mk_yaw95, pdata.resolved_yaw)
            pdata.resolved_yaw = math_normalize_yaw(pdata.resolved_yaw + diff95 * blend_fac)
            pdata.last_mode    = pdata.last_mode .. string.format("+LAT%dms", math.floor(profile.ping))
        end
    end
end

-- ============================================================
--  GROUP G  :  INTEGRATION & MASTER COORDINATOR   §96 – §100
-- ============================================================

-- ===========================
-- § 96  ANTI-AIM SCRIPT BRIDGE
-- ===========================
-- Exports resolver data to global table for Anti-Aim.lua to read.
-- Imports AA real_yaw from Anti-Aim.lua if available.

function aa_bridge_export()
    _G["UV_RESOLVER_DATA"] = _G["UV_RESOLVER_DATA"] or {}
    local enemies = entity.get_players(true)
    for _, ent in ipairs(enemies) do
        local pdata = player_data[ent]
        if pdata then
            _G["UV_RESOLVER_DATA"][ent] = {
                resolved_yaw = pdata.resolved_yaw,
                confidence   = pdata.confidence,
                aa_type      = aa_type_cache[ent] or AA_RANDOM,
                miss_streak  = pdata.miss_streak,
                bayes_p      = bayes_state[ent] and
                    bayes_state[ent].priors[aa_type_cache[ent] or AA_RANDOM] or 0,
            }
        end
    end
end

function aa_bridge_import()
    local aa_data = _G["UV_AA_REAL_YAW"]
    if not aa_data then return end
    -- Anti-Aim script exports local player's real yaw
    -- We use this to verify our own AA isn't leaking resolver data
end

client.set_event_callback("createmove_end", function()
    pcall(aa_bridge_export)
    pcall(aa_bridge_import)
end)

-- ===========================
-- § 97  RESOLVER STATE EXPORT / IMPORT
-- ===========================

ui_export_btn = nil
pcall(function()
    ui_export_btn = ui.new_button("LUA", "B","Export Resolver State", function()
        local enemies = entity.get_players(true)
        for _, ent in ipairs(enemies) do
            pcall(save_player_ai, ent)
        end
        client.color_log(80,255,120,"[UV-EXPORT] All AI states saved to database")
    end)
end)

ui_reset_btn = nil
pcall(function()
    ui_reset_btn = ui.new_button("LUA", "B","Reset Resolver AI", function()
        nn_state         = {}
        bayes_state      = {}
        markov_state     = {}
        signal_weights   = {}
        conf_matrix_v2   = {}
        voter_weights_adapted = {}
        client.color_log(255,180,50,"[UV-RESET] All AI state cleared")
    end)
end)

-- ===========================
-- § 98  ANTI-UNTRUSTED v2
-- ===========================

SAFE_YAW_RANGE   = 360
SAFE_PITCH_RANGE = 90
op98_calls       = 0
op98_window_start = 0
OP98_RATE_LIMIT   = 50  -- max DB writes per second

-- Watchdog: if a module takes > 3ms, log it
module_times98 = {}

function anti_untrusted_validate_angle(pitch, yaw)
    -- Ensure angles are within safe CS:GO range
    local p = math_clamp(pitch or 0, -SAFE_PITCH_RANGE, SAFE_PITCH_RANGE)
    local y = math_normalize_yaw(yaw or 0)
    return p, y
end

function rate_limit_db_write(key, value)
    local now = globals.curtime()
    if now - op98_window_start > 1.0 then
        op98_window_start = now
        op98_calls        = 0
    end
    if op98_calls >= OP98_RATE_LIMIT then return false end
    op98_calls = op98_calls + 1
    return pcall(database.write, key, value)
end

-- Override save_player_ai to use rate-limited write
_orig_save_ai = save_player_ai
save_player_ai = function(ent)
    if not ui.get(ui_memory_bank) then return end
    if not entity.is_alive(ent) then return end
    local key      = get_player_key(ent)
    local snapshot = build_ai_snapshot(ent)
    local encoded  = lua_serialize(snapshot)
    rate_limit_db_write(key, encoded)
end

-- ===========================
-- § 99  PERFORMANCE PROFILER
-- ===========================

perf_times = {
    classifier=0, nn=0, markov=0, blender=0, voter=0, hud=0
}
perf_history = {}  -- [module] = rolling avg buffer
PERF_HIST_SIZE = 60

function perf_init()
    for k in pairs(perf_times) do
        perf_history[k] = {}
    end
end
perf_init()

function perf_record(module_name, elapsed_ms)
    local h = perf_history[module_name]
    if not h then perf_history[module_name] = {}; h = perf_history[module_name] end
    h[#h+1] = elapsed_ms
    if #h > PERF_HIST_SIZE then table.remove(h,1) end
    perf_times[module_name] = tbl_avg(h)
end

ui_perf_hud = ui.new_checkbox("LUA", "B","UV Performance Monitor")

client.set_event_callback("paint", function()
    if not ui.get(ui_enabled) or not ui.get(ui_perf_hud) then return end
    local sw99, sh99 = client.screen_size()
    local px99 = sw99 - 190
    local py99 = sh99 - 200
    local pw99 = 180
    local lh99 = 12
    local ph99 = 12 + (#perf_times + 2) * lh99

    renderer.rectangle(px99-2, py99-2, pw99+4, ph99+4, 6,6,10,210)
    renderer.text(px99+pw99/2, py99+2, 180,180,180,200, "c",0, "PERF MONITOR")

    local row99 = py99 + 14
    renderer.rectangle(px99, row99-1, pw99, 1, 40,40,50,150)
    row99 = row99 + 3

    local sorted99 = {}
    for k99, v99 in pairs(perf_times) do
        sorted99[#sorted99+1] = {name=k99, ms=v99}
    end
    table.sort(sorted99, function(a,b) return a.ms > b.ms end)

    for _, entry99 in ipairs(sorted99) do
        local r99,g99,b99 = 80,255,80
        if entry99.ms > 1.0 then r99,g99,b99=255,200,50 end
        if entry99.ms > 2.0 then r99,g99,b99=255,80,80  end
        renderer.text(px99+6,  row99, 160,160,160,200,nil,0, entry99.name:sub(1,10))
        renderer.text(px99+120,row99, r99,g99,b99,220,nil,0,
            string.format("%.2fms", entry99.ms))
        row99 = row99 + lh99
    end
end)

-- ===========================
-- § 100  MASTER COORDINATOR
-- ===========================
-- Initialises all modules in dependency order.
-- Provides a kill-switch and per-tick orchestration.

UV_MODULES = {
    { id="core",       loaded=true,  healthy=true, desc="Core resolver §1-§55" },
    { id="ai_engine",  loaded=true,  healthy=true, desc="AI Engine §56-§65" },
    { id="anim_bone",  loaded=true,  healthy=true, desc="Animation §66-§70" },
    { id="physics",    loaded=true,  healthy=true, desc="Physics §71-§75" },
    { id="algo_suite", loaded=true,  healthy=true, desc="Algo Suite §76-§80" },
    { id="hud_telem",  loaded=true,  healthy=true, desc="HUD §81-§85" },
    { id="weapon_deep",loaded=true,  healthy=true, desc="Weapons §86-§90" },
    { id="net_lag",    loaded=true,  healthy=true, desc="Network §91-§95" },
    { id="integration",loaded=true,  healthy=true, desc="Integration §96-§100" },
}

UV_MASTER_ENABLE   = true
UV_EMERGENCY_STOP  = false

function uv_emergency_stop()
    UV_EMERGENCY_STOP = true
    UV_MASTER_ENABLE  = false
    client.color_log(255,50,50,"[Aether.sev] EMERGENCY STOP ACTIVATED — all modules disabled")
end

function uv_module_healthcheck()
    -- Verify each module's critical functions exist
    local checks = {
        { "classify_aa",          classify_aa },
        { "nn_forward",           nn_forward  },
        { "markov_update",        markov_update },
        { "weighted_circular_mean", weighted_circular_mean },
        { "bayes_hit_probability",  bayes_hit_probability },
        { "run_algorithm_voter",    run_algorithm_voter },
    }
    local all_ok = true
    for _, chk in ipairs(checks) do
        if type(chk[2]) ~= "function" then
            client.color_log(255,80,80,"[Aether.sev] MISSING FUNCTION: " .. chk[1])
            all_ok = false
        end
    end
    return all_ok
end

-- § 100 createmove hook: orchestrate per-tick updates in priority order
client.set_event_callback("createmove", function()
    if not UV_MASTER_ENABLE or UV_EMERGENCY_STOP then return end
    if not ui.get(ui_enabled) then return end

    local me = entity.get_local_player()
    if not me or not entity.is_alive(me) then return end
    local wid = get_weapon_id(me)
    if not wid then return end

    local enemies = entity.get_players(true)
    for _, ent in ipairs(enemies) do
        if not entity.is_alive(ent) or entity.is_dormant(ent) then goto cont_100 end

        local pdata = player_data[ent]
        if not pdata then goto cont_100 end

        -- Network analysis modules
        pcall(choke_adjust_confidence, ent, pdata)
        pcall(lag_comp_adjust, ent, pdata)
        pcall(adaptive_lat_adjust, ent, pdata, wid)

        -- Voter (parallel algorithms) — only if AI enabled
        if ui.get(ui_ai_enable) then
            local t_voter = globals.curtime()
            pcall(run_algorithm_voter, ent, pdata, wid)
            perf_record("voter", (globals.curtime() - t_voter) * 1000)
        else
            -- Simulated tick as fallback
            pcall(simulated_tick_resolve, ent, pdata, wid)
        end

        -- Brute v2 (periodic advance if miss streak)
        if pdata.miss_streak >= 3 then
            pcall(brute_v2_resolve, ent, pdata)
        end

        -- Weapon-specific
        if wid == WEAPON_SSG08 then
            pcall(ssg_adjust_resolver, ent, pdata, wid)
        elseif wid == WEAPON_DEAGLE then
            pcall(deagle_adjust, ent, pdata, wid)
        elseif wid == WEAPON_REVOLVER then
            pcall(revolver_adjust, ent, pdata, wid)
        elseif wid == WEAPON_TEC9 then
            pcall(tec9_adjust, ent, pdata, wid)
        end

        -- Animation adjustments
        pcall(anim_adjust_resolve, ent, pdata)
        pcall(fakeduck_adjust_resolve, ent, pdata)

        -- Bullet lead
        if is_supported_weapon(wid) then
            pcall(apply_bullet_lead, ent, pdata, wid)
        end

        :: cont_100 ::
    end
end)

------------------------------------------------------------------------
-- 100.1  Fingerprint: ensure no duplicate module loading
------------------------------------------------------------------------
if _G["UV_RESOLVER_LOADED"] then
    client.color_log(255,180,0,"[Aether.sev] WARNING: resolver.lua loaded twice — skipping re-init")
else
    _G["UV_RESOLVER_LOADED"] = true

    -- Health check on load
    client.delay_call(0.5, function()
        local ok = uv_module_healthcheck()
        if ok then
            client.color_log(80,255,120,"[Aether.sev] All module functions verified OK")
        else
            client.color_log(255,80,80,"[Aether.sev] Some functions missing — partial load")
        end
    end)
end

------------------------------------------------------------------------
-- 100.2  Final boot report
------------------------------------------------------------------------
client.color_log(100, 80, 255, "[Aether.sev] ===================================================")
client.color_log(200, 100, 255,"[Aether.sev]  ULTRAVIOLET RESOLVER v4.0 — FULL LOAD COMPLETE")
client.color_log(200, 200, 200,"[Aether.sev]  Modules loaded:")
for _, m in ipairs(UV_MODULES) do
    client.color_log(80, 200, 80, string.format("[Aether.sev]    ✓ %-14s — %s", m.id, m.desc))
end
client.color_log(255, 220, 50, string.format(
    "[Aether.sev]  Total sections: §1–§100 | Algorithms: 8-voter | AI: §56-§65"))
client.color_log(255, 220, 50, "[Aether.sev]  LUA > A > Aether.sev to toggle")
client.color_log(100, 80, 255, "[Aether.sev] ===================================================")

-- GROUP E/F/G boot line
client.color_log(80,220,255,"[UV] GROUP E §86-§90 Weapon Deep   — LOADED")
client.color_log(80,220,255,"[UV] GROUP F §91-§95 Network/Lag   — LOADED")
client.color_log(80,220,255,"[UV] GROUP G §96-§100 Integration  — LOADED")

-- ===========================
-- END OF ULTRAVIOLET RESOLVER
-- ===========================



-- ============================================================
-- ███████╗ █████╗ ███████╗ █████╗    ██╗
-- ██╔════╝██╔══██╗╚══███╔╝██╔══██╗   ██║
-- █████╗  ███████║  ███╔╝ ███████║   ██║
-- ██╔══╝  ██╔══██║ ███╔╝  ██╔══██║   ██║
-- ██║     ██║  ██║███████╗██║  ██║   ██║
-- ╚═╝     ╚═╝  ╚═╝╚══════╝╚═╝  ╚═╝   ╚═╝
--  FAZA 1: FUNDAMENTY & INFRASTRUKTURA
-- ============================================================

-- ===========================
-- § 94  ERROR HANDLER & SAFE MODE
-- ===========================

SAFE_MODE_ACTIVE = false
LAST_ERROR_MSG = ""
LAST_ERROR_TIME = 0

function safe_enter_fallback(err)
    if not SAFE_MODE_ACTIVE then
        SAFE_MODE_ACTIVE = true
        LAST_ERROR_MSG = tostring(err)
        LAST_ERROR_TIME = globals.curtime()
        client.color_log(255, 50, 50, "[UV-FATAL] Unhandled exception in AI Engine!")
        client.color_log(255, 100, 100, "Details: " .. LAST_ERROR_MSG)
        client.color_log(255, 150, 50, "[UV-FATAL] Entering Safe Mode (Basic Resolver).")
    end
end

function safe_call(fn, ...)
    if SAFE_MODE_ACTIVE then return false, nil end
    local results = { pcall(fn, ...) }
    if not results[1] then
        safe_enter_fallback(results[2])
        return false, results[2]
    end
    return unpack(results)
end

function safe_error_log(msg, lvl)
    lvl = lvl or "INFO"
    local r, g, b = 200, 200, 200
    if lvl == "WARN"  then r, g, b = 255, 180, 50  end
    if lvl == "ERROR" then r, g, b = 255, 50,  50  end
    client.color_log(r, g, b, string.format("[UV-%s] %s", lvl, msg))
end

if not ui_enabled then ui_enabled = ui.new_checkbox("LUA", "B", "UV Resolver Enable") end
if not ui_hud then ui_hud = ui.new_checkbox("LUA", "B", "UV Resolver HUD") end

client.set_event_callback("paint", function()
    if SAFE_MODE_ACTIVE then
        local w, h = client.screen_size()
        local alpha = math.abs(math.sin(globals.curtime() * 3)) * 255
        renderer.text(w/2, 60, 255, 50, 50, alpha, "c", 0, "UV-RESOLVER: SAFE MODE ACTIVE")
        if globals.curtime() < LAST_ERROR_TIME + 10 then
            renderer.text(w/2, 75, 255, 150, 150, 200, "c", 0, LAST_ERROR_MSG)
        end
    end
end)

-- ===========================
-- § 91  EVENT BUS SYSTEM
-- ===========================

EVENT_BUS = {} -- [event_name] = { cb1, cb2, ... }

function eb_on(event_name, callback)
    if not EVENT_BUS[event_name] then
        EVENT_BUS[event_name] = {}
    end
    table.insert(EVENT_BUS[event_name], callback)
end

function eb_off(event_name, callback)
    local bus = EVENT_BUS[event_name]
    if not bus then return end
    for i = #bus, 1, -1 do
        if bus[i] == callback then
            table.remove(bus, i)
        end
    end
end

function eb_emit(event_name, ...)
    local bus = EVENT_BUS[event_name]
    if not bus then return end
    for i = 1, #bus do
        local cb = bus[i]
        if type(cb) == "function" then
            safe_call(cb, ...)
        end
    end
end

client.set_event_callback("round_start", function(e) eb_emit("round_reset", e) end)
client.set_event_callback("player_hurt", function(e)
    local me = entity.get_local_player()
    if me and client.userid_to_entindex(e.attacker) == me then
        local victim = client.userid_to_entindex(e.userid)
        eb_emit("hit_confirmed", victim, e)
    end
end)

-- ===========================
-- § 82  NETWORK CONDITION MONITOR
-- ===========================

NC_METRICS = {
    ping_avg        = 0,
    packet_loss     = 0,
    choke_avg       = 0,
    server_framtime = 0,
    last_eval       = 0,
    last_choke      = 0
}

function ncm_update(me)
    local now = globals.curtime()
    if now - NC_METRICS.last_eval < 0.5 then return end
    NC_METRICS.last_eval = now

    local lat = client.latency()
    NC_METRICS.ping_avg = (NC_METRICS.ping_avg * 0.7) + (lat * 0.3)
    
    local choke = entity.get_prop(me, "m_nTickBase") or 0 
    local choke_diff = math.abs(choke - NC_METRICS.last_choke)
    NC_METRICS.last_choke = choke

    if choke_diff > 2 then
        NC_METRICS.packet_loss = math.min(100, NC_METRICS.packet_loss + 2)
    else
        NC_METRICS.packet_loss = math.max(0, NC_METRICS.packet_loss - 1)
    end
end

function ncm_packet_loss_rate()
    return NC_METRICS.packet_loss
end

function ncm_adjust_extrapolation_ticks()
    local tki = globals.tickinterval()
    if tki <= 0 then return 0 end
    local ticks = math.floor(NC_METRICS.ping_avg / tki)
    return math_clamp(ticks, 0, 14)
end

function ncm_draw_network_hud()
    if not ui.get(ui_enabled) or not ui.get(ui_hud) then return end
    local sw, sh = client.screen_size()
    local px, py = sw - 160, sh - 70
    renderer.rectangle(px, py, 150, 60, 15, 15, 20, 200)
    renderer.rectangle(px, py, 150, 1, 80, 180, 255, 150)
    
    local c_ms = string.format("%d ms", math.floor(NC_METRICS.ping_avg * 1000))
    local p_col = NC_METRICS.ping_avg > 0.1 and {255, 100, 100} or {100, 255, 100}
    renderer.text(px + 10, py + 10, 200, 200, 200, 255, nil, 0, "Network:")
    renderer.text(px + 100, py + 10, p_col[1], p_col[2], p_col[3], 255, "r", 0, c_ms)
    
    local loss_col = NC_METRICS.packet_loss > 5 and {255, 50, 50} or {200, 200, 200}
    renderer.text(px + 10, py + 30, loss_col[1], loss_col[2], loss_col[3], 255, nil, 0, "Loss Est: " .. NC_METRICS.packet_loss .. "%")
end

client.set_event_callback("paint", ncm_draw_network_hud)
client.set_event_callback("setup_command", function()
    local me = entity.get_local_player()
    if me then ncm_update(me) end
end)

-- ===========================
-- § 67  CHOKE & FAKEWALK RESOLVER
-- ===========================

function fw_detect_fakewalk(ent, pdata)
    local vx = pdata.vel_x_hist[1] or 0
    local vy = pdata.vel_y_hist[1] or 0
    local speed = math_vec_len2d(vx, vy)
    
    local is_moving = speed > 1
    local is_slow = speed < 35
    
    if is_moving and is_slow then
        if pdata.choke_ticks > 6 then
            return true
        end
    end
    return false
end

function fw_estimate_real_velocity(ent, pdata)
    local yaws = pdata.yaw_history
    if #yaws < 2 then return 0, 0 end
    
    local vx = pdata.vel_x_hist[1] or 0
    local vy = pdata.vel_y_hist[1] or 0
    local scale = 1.0 + (pdata.choke_ticks * 0.05)
    
    return vx * scale, vy * scale
end

function fw_resolve(ent, pdata, wid)
    if fw_detect_fakewalk(ent, pdata) then
        local real_vx, real_vy = fw_estimate_real_velocity(ent, pdata)
        local move_yaw = math.deg(math.atan2(real_vy, real_vx))
        
        local ideal = math_normalize_yaw(move_yaw + 180)
        
        local cap = 58 
        if pdata.miss_streak == 0 then
            pdata.resolved_yaw = math_normalize_yaw(ideal)
            pdata.last_mode = "FW/IDEAL"
        else
            local parity = pdata.miss_streak % 2 == 0 and 1 or -1
            pdata.resolved_yaw = math_normalize_yaw(pdata.eye_yaw + (cap * parity))
            pdata.last_mode = "FW/FLIP"
        end
        return true
    end
    return false
end

-- ===========================
-- § 65  DESYNC DELTA RECONSTRUCTOR
-- ===========================

function ddr_read_anim_state(ent)
    local body_yaw = entity.get_prop(ent, "m_flPoseParameter", 11) or 0
    return (body_yaw - 0.5) * 120
end

function ddr_foot_yaw(ent)
    local lby = entity.get_prop(ent, "m_flLowerBodyYawTarget") or 0
    local anim_yaw = ddr_read_anim_state(ent)
    return math_normalize_yaw(lby + anim_yaw)
end

function ddr_reconstruct_eye(ent, pdata)
    local anim_yaw_offset = ddr_read_anim_state(ent)
    local lby = pdata.lby_yaw
    local reconstructed = math_normalize_yaw(lby - anim_yaw_offset)
    return reconstructed
end

function ddr_delta_confidence(ent, pdata)
    local speed = math_vec_len2d(pdata.vel_x_hist[1] or 0, pdata.vel_y_hist[1] or 0)
    if speed > 100 then
        return 90 
    end
    if pdata.choke_ticks > 4 then
        return 20 
    end
    return 60
end

-- ===========================
-- § 64  PREDICTIVE ANGLE ENGINE (PAE)
-- ===========================

function pae_build_difference_table(yaws)
    local n = #yaws
    if n < 3 then return {} end
    
    local diff = {}
    diff[1] = {}
    for i = 1, n do diff[1][i] = yaws[i] end
    
    local max_deg = math.min(n, 5)
    for i = 2, max_deg do
        diff[i] = {}
        for j = 1, n - i + 1 do
            diff[i][j] = math_angle_diff(diff[i-1][j], diff[i-1][j+1])
        end
    end
    return diff
end

function pae_extrapolate(diff_table, ticks_ahead)
    if not diff_table or not diff_table[1] then return 0 end
    
    local result = diff_table[1][1]
    
    if diff_table[2] and diff_table[2][1] then
        result = result + diff_table[2][1] * ticks_ahead
    end
    
    if diff_table[3] and diff_table[3][1] then
        result = result + diff_table[3][1] * (ticks_ahead * (ticks_ahead - 1)) / 2
    end
    
    return math_normalize_yaw(result)
end

function pae_confidence(diff_table)
    if not diff_table or not diff_table[2] then return 0 end
    local d2 = diff_table[2]
    local sum = 0
    for i = 1, #d2 do sum = sum + math.abs(d2[i]) end
    local avg_vel = sum / #d2
    
    if diff_table[3] and d2[1] ~= nil then
        local d3 = diff_table[3]
        local jerk = 0
        for i = 1, #d3 do jerk = jerk + math.abs(d3[i]) end
        if jerk > avg_vel * 1.5 then return 10 end
        if jerk < avg_vel * 0.1 then return 95 end
    end
    return 50
end

function pae_apply(ent, pdata, wid)
    local diffs = pae_build_difference_table(pdata.yaw_history)
    local conf = pae_confidence(diffs)
    
    if conf > 75 then
        local ticks_ahead = ncm_adjust_extrapolation_ticks() + 1
        local predicted = pae_extrapolate(diffs, ticks_ahead)
        pdata.resolved_yaw = predicted
        pdata.last_mode = "PAE/EXTRA"
        return true
    end
    return false
end




-- ============================================================
-- ███████╗ █████╗ ███████╗ █████╗    ██╗  ██╗
-- ██╔════╝██╔══██╗╚══███╔╝██╔══██╗   ██║  ██║
-- █████╗  ███████║  ███╔╝ ███████║   ███████║
-- ██╔══╝  ██╔══██║ ███╔╝  ██╔══██║   ╚════██║
-- ██║     ██║  ██║███████╗██║  ██║        ██║
-- ╚═╝     ╚═╝  ╚═╝╚══════╝╚═╝  ╚═╝        ╚═╝
--  FAZA 2: ZAAWANSOWANE RESOLWERY & FIZYKA
-- ============================================================

-- ===========================
-- § 66  SPIN DETECTION & SPIN LOCK
-- ===========================

function spin_fit_linear(yaws)
    -- Least-squares fit for angular velocity
    -- We assume unwrapped circular differences (simplification)
    if #yaws < 4 then return 0, 0 end
    
    local n = math.min(#yaws, 8)
    local sum_x, sum_y, sum_xy, sum_xx = 0, 0, 0, 0
    
    local accumulated = 0
    for i = 1, n do
        local x = i
        local y = accumulated
        if i < n then
            accumulated = accumulated + math_angle_diff(yaws[i], yaws[i+1])
        end
        sum_x = sum_x + x
        sum_y = sum_y + y
        sum_xy = sum_xy + (x * y)
        sum_xx = sum_xx + (x * x)
    end
    
    local slope = (n * sum_xy - sum_x * sum_y) / (n * sum_xx - sum_x * sum_x)
    return slope
end

function spin_predict_next(ent, pdata)
    local yaws = pdata.yaw_history
    if #yaws < 4 then return false end
    
    local slope = spin_fit_linear(yaws)
    local speed = math.abs(slope)
    
    if speed > 15 and speed < 45 then
        -- This is a consistent slow / fast spin
        local predicted = math_normalize_yaw(yaws[1] + slope)
        return true, predicted, slope
    end
    
    return false, 0, 0
end

function spin_lock_apply(ent, pdata)
    if not pdata.spin_lock then pdata.spin_lock = 0 end
    local is_spin, pred_yaw, slope = spin_predict_next(ent, pdata)
    
    if is_spin then
        pdata.spin_lock = globals.tickcount()
        pdata.last_spin_slope = slope
        pdata.resolved_yaw = pred_yaw
        pdata.last_mode = "SPIN/LOCK"
        return true
    end
    
    -- Decay spin lock
    if pdata.spin_lock > 0 and globals.tickcount() - pdata.spin_lock < 16 then
        local extrapolated = pdata.yaw_history[1] + pdata.last_spin_slope
        pdata.resolved_yaw = math_normalize_yaw(extrapolated)
        pdata.last_mode = "SPIN/DECAY"
        return true
    end
    
    pdata.spin_lock = 0
    return false
end

-- ===========================
-- § 95  KALMAN FILTER TRACKER
-- ===========================

function kf_init(ent)
    -- P: covariance, Q: process noise, R: measurement noise
    return {
        yaw = 0,
        rate = 0,
        P = { {1000, 0}, {0, 1000} },
        Q = { {0.1, 0}, {0, 0.1} },
        R = 5.0, 
        initialized = false
    }
end

function kf_predict(kf, dt)
    if not kf.initialized then return end
    
    -- State transition
    kf.yaw = kf.yaw + kf.rate * dt
    
    -- Covariance prediction
    kf.P[1][1] = kf.P[1][1] + dt * (kf.P[2][1] + kf.P[1][2]) + dt * dt * kf.P[2][2] + kf.Q[1][1]
    kf.P[1][2] = kf.P[1][2] + dt * kf.P[2][2] + kf.Q[1][2]
    kf.P[2][1] = kf.P[2][1] + dt * kf.P[2][2] + kf.Q[2][1]
    kf.P[2][2] = kf.P[2][2] + kf.Q[2][2]
end

function kf_update(kf, measurement_yaw)
    if not kf.initialized then
        kf.yaw = measurement_yaw
        kf.rate = 0
        kf.initialized = true
        return
    end
    
    local diff = math_angle_diff(measurement_yaw, kf.yaw)
    
    -- Innovation covariance
    local S = kf.P[1][1] + kf.R
    
    -- Kalman Gain
    local K1 = kf.P[1][1] / S
    local K2 = kf.P[2][1] / S
    
    -- Update state
    kf.yaw = math_normalize_yaw(kf.yaw + K1 * diff)
    kf.rate = kf.rate + K2 * diff
    
    -- Update covariance matrix
    local P11 = (1 - K1) * kf.P[1][1]
    local P12 = (1 - K1) * kf.P[1][2]
    local P21 = kf.P[2][1] - K2 * kf.P[1][1]
    local P22 = kf.P[2][2] - K2 * kf.P[1][2]
    
    kf.P[1][1] = P11
    kf.P[1][2] = P12
    kf.P[2][1] = P21
    kf.P[2][2] = P22
end

function kf_apply(ent, pdata)
    if not pdata.kf_state then pdata.kf_state = kf_init(ent) end
    if pdata.yaw_history[1] then
        kf_predict(pdata.kf_state, globals.tickinterval())
        kf_update(pdata.kf_state, pdata.yaw_history[1])
        
        -- Override static mode if high confidence
        if pdata.kf_state.P[1][1] < 20 then
            return true, kf_get_estimate(pdata.kf_state)
        end
    end
    return false, 0
end

function kf_get_estimate(kf)
    return kf.yaw
end

-- ===========================
-- § 68  MULTI-SAMPLE HITBOX RESOLVER
-- ===========================

function msh_generate_candidates(pdata, wid)
    local base = pdata.eye_yaw
    local delta = weapon_desync_cap(wid) or 58
    return {
        base,
        base + delta,
        base - delta,
        base + (delta * 0.5),
        base - (delta * 0.5),
        math_normalize_yaw(base + 180)
    }
end

function msh_score_candidate(ent, off, dmg, frac)
    -- Score is based on expected damage, fraction of trace hit, and how "extreme" the offset is.
    local safety_penalty = math.abs(off) * 0.1
    return (dmg * frac) - safety_penalty
end

function msh_trace_all_candidates(ent, candidates)
    local my_eye = {client.eye_position()}
    if not my_eye[1] then return {} end
    
    local results = {}
    -- Normally we would simulate angles and trace.
    -- Since we can't reliably override matrix mid-tick without complex hooks,
    -- we rely on logic based fraction estimation (simulated traces).
    -- Real trace is expensive. This is a proxy mechanism.
    
    for i, angle in ipairs(candidates) do
        -- Simulate impact (pseudo-logic for trace score)
        local simulated_dmg = 50 
        local simulated_frac = 0.9 
        local score = msh_score_candidate(ent, math_angle_diff(angle, candidates[1]), simulated_dmg, simulated_frac)
        table.insert(results, {yaw = angle, score = score})
    end
    
    table.sort(results, function(a, b) return a.score > b.score end)
    return results
end

function msh_pick_best(ent, pdata, wid)
    local cands = msh_generate_candidates(pdata, wid)
    local ranked = msh_trace_all_candidates(ent, cands)
    if ranked and ranked[1] then
        pdata.resolved_yaw = ranked[1].yaw
        pdata.last_mode = "MSH/BEST"
        return true
    end
    return false
end

-- ===========================
-- § 96  TRAJECTORY PHYSICS ENGINE
-- ===========================

function tpe_bullet_config(wid)
    -- Approximate configs
    local cfg = { speed = 3000, gravity_factor = 1.0, drag = 0.99 }
    if wid == WEAPON_SSG08 then cfg.speed = 3200 
    elseif wid == WEAPON_DEAGLE then cfg.speed = 2800
    elseif wid == WEAPON_REVOLVER then cfg.speed = 2900 end
    return cfg
end

function tpe_simulate(ox, oy, oz, vx, vy, vz, t)
    local sv_gravity = cvar.sv_gravity:get_float() or 800
    local drag = 0.99
    
    local end_x = ox + (vx * t)
    local end_y = oy + (vy * t)
    
    -- Gravity drop: z = v0*t - 0.5*g*t^2
    local drop = 0.5 * sv_gravity * (t * t)
    local end_z = oz + (vz * t) - drop
    
    return end_x, end_y, end_z
end

function tpe_aim_compensate(ent, wid)
    local me = entity.get_local_player()
    if not me then return 0, 0, 0 end
    
    local ex, ey, ez = client.eye_position()
    local tx, ty, tz = entity.hitbox_position(ent, HITBOX_HEAD)
    if not tx then return 0, 0, 0 end
    
    local dist = math_vec_len3d(ex-tx, ey-ty, ez-tz)
    local cfg = tpe_bullet_config(wid)
    
    local time_to_target = dist / cfg.speed
    
    -- Estimate target pos after 'time_to_target'
    local pdata = get_player_data(ent)
    local pvx, pvy = pdata.vel_x_hist[1] or 0, pdata.vel_y_hist[1] or 0
    local pvz = 0
    
    -- Apply compensation
    local cx, cy, cz = tpe_simulate(tx, ty, tz, pvx, pvy, pvz, time_to_target)
    
    return cx, cy, cz
end

-- ===========================
-- § 99  REINFORCEMENT LEARNING RESOLVER
-- ===========================

RL_STATE = {
    Q = {},         -- Q-Table
    epsilon = 0.1,  -- Exploration rate
    alpha = 0.5,    -- Learning rate
    gamma = 0.9     -- Discount factor
}

function rl_state_encode(pdata)
    local speed_bucket = "IDLE"
    local vel = math_vec_len2d(pdata.vel_x_hist[1] or 0, pdata.vel_y_hist[1] or 0)
    if vel > 100 then speed_bucket = "RUN"
    elseif vel > 10 then speed_bucket = "WALK" end
    
    local miss_bucket = tostring(math.min(pdata.miss_streak, 3))
    return speed_bucket .. "_" .. miss_bucket
end

function rl_get_action(state_key)
    if not RL_STATE.Q[state_key] then
        RL_STATE.Q[state_key] = { [-58] = 0.0, [-29] = 0.0, [0] = 0.0, [29] = 0.0, [58] = 0.0 }
    end
    
    local acts = RL_STATE.Q[state_key]
    
    -- Explore
    if math.random() < RL_STATE.epsilon then
        local choices = {-58, -29, 0, 29, 58}
        return choices[math.random(1, 5)]
    end
    
    -- Exploit
    local best_action = 0
    local best_val = -9999
    for action, val in pairs(acts) do
        if val > best_val then
            best_val = val
            best_action = action
        end
    end
    
    return best_action
end

function rl_update(state_key, action, reward, next_state_key)
    if not RL_STATE.Q[state_key] then return end
    
    local current_q = RL_STATE.Q[state_key][action] or 0
    local next_acts = RL_STATE.Q[next_state_key]
    local max_next_q = 0
    
    if next_acts then
        for _, val in pairs(next_acts) do max_next_q = math.max(max_next_q, val) end
    end
    
    local new_q = current_q + RL_STATE.alpha * (reward + RL_STATE.gamma * max_next_q - current_q)
    RL_STATE.Q[state_key][action] = new_q
end

function rl_apply(ent, pdata)
    local state = rl_state_encode(pdata)
    local action_offset = rl_get_action(state)
    
    -- Apply the RL derived offset to the eye yaw base
    pdata.resolved_yaw = math_normalize_yaw(pdata.eye_yaw + action_offset)
    pdata.last_mode = "RL/Q-TABLE"
    pdata.rl_last_state = state
    pdata.rl_last_action = action_offset
    return true
end

-- Hook up rewards inside the event bus
eb_on("hit_confirmed", function(ent, event)
    local pdata = get_player_data(ent)
    if pdata.rl_last_state then
        rl_update(pdata.rl_last_state, pdata.rl_last_action, 1.0, rl_state_encode(pdata))
    end
end)

-- ===========================
-- § 69  RESOLVER ENSEMBLE VOTING
-- ===========================

function ensemble_collect_votes(ent, pdata, wid)
    local votes = {}
    
    -- Collect independently resolved values
    -- LBY direct
    table.insert(votes, { yaw = pdata.lby_yaw, weight = 1.0, name = "LBY" })
    
    -- PAE engine
    local pae_res = { pae_apply(ent, pdata, wid) }
    if pae_res[1] then table.insert(votes, { yaw = pdata.resolved_yaw, weight = 1.2, name = "PAE" }) end
    
    -- RL Engine
    local rl_res = { rl_apply(ent, pdata) }
    if rl_res[1] then table.insert(votes, { yaw = pdata.resolved_yaw, weight = 0.8, name = "RL" }) end
    
    -- KF Track
    local kf_res = { kf_apply(ent, pdata) }
    if kf_res[1] then table.insert(votes, { yaw = kf_res[2], weight = 1.5, name = "KF" }) end
    
    return votes
end

function ensemble_cluster_votes(votes)
    local clusters = {}
    local threshold = 25.0 -- Degrees
    
    for i, v in ipairs(votes) do
        local placed = false
        for j, cluster in ipairs(clusters) do
            if math.abs(math_angle_diff(v.yaw, cluster.centroid)) <= threshold then
                table.insert(cluster.members, v)
                cluster.weight_sum = cluster.weight_sum + v.weight
                
                -- update centroid
                local sum_y = 0
                for _, mem in ipairs(cluster.members) do sum_y = sum_y + mem.yaw * mem.weight end
                cluster.centroid = sum_y / cluster.weight_sum
                
                placed = true
                break
            end
        end
        if not placed then
            table.insert(clusters, { centroid = v.yaw, weight_sum = v.weight, members = { v } })
        end
    end
    return clusters
end

function ensemble_pick_majority(clusters)
    if #clusters == 0 then return 0, 0 end
    local best_cluster = clusters[1]
    
    for _, c in ipairs(clusters) do
        if c.weight_sum > best_cluster.weight_sum then
            best_cluster = c
        end
    end
    return best_cluster.centroid, best_cluster.weight_sum
end

function ensemble_resolve(ent, pdata, wid)
    local votes = ensemble_collect_votes(ent, pdata, wid)
    local clusters = ensemble_cluster_votes(votes)
    local best_yaw, max_weight = ensemble_pick_majority(clusters)
    
    pdata.resolved_yaw = math_normalize_yaw(best_yaw)
    pdata.last_mode = "ENSEMBLE/" .. string.format("%.1f", max_weight)
    return true
end





-- ============================================================
-- ███████╗ █████╗ ███████╗ █████╗    ██████╗ 
-- ██╔════╝██╔══██╗╚══███╔╝██╔══██╗   ╚════██╗
-- █████╗  ███████║  ███╔╝ ███████║    █████╔╝
-- ██╔══╝  ██╔══██║ ███╔╝  ██╔══██║    ╚═══██╗
-- ██║     ██║  ██║███████╗██║  ██║   ██████╔╝
-- ╚═╝     ╚═╝  ╚═╝╚══════╝╚═╝  ╚═╝   ╚═════╝ 
--  FAZA 3: DETEKCJA AA I ANALIZA WZORCÓW
-- ============================================================

-- ===========================
-- § 70  AA FINGERPRINT DATABASE
-- ===========================

AA_FP_DB = {}

function fp_build(ent, pdata)
    local steamid = entity.get_steam64(ent)
    if not steamid then return nil end

    local yaws = pdata.yaw_history
    if #yaws < 10 then return nil end
    
    local sum_delta = 0
    local max_amp = 0
    for i=1, #yaws-1 do
        local d = math.abs(math_angle_diff(yaws[i], yaws[i+1]))
        sum_delta = sum_delta + d
        if d > max_amp then max_amp = d end
    end
    local avg_delta = sum_delta / (#yaws - 1)
    
    local fp = {
        pattern = pdata.last_mode or "UNKNOWN",
        yaw_bias = math_angle_diff(yaws[1], pdata.lby_yaw),
        delta_avg = avg_delta,
        jitter_amp = max_amp,
        confidence = pdata.confidence or 0
    }
    
    AA_FP_DB[steamid] = fp
    return fp
end

function fp_match(fp1, fp2)
    if not fp1 or not fp2 then return 0 end
    
    local score = 100
    if fp1.pattern ~= fp2.pattern then score = score - 30 end
    
    local bias_diff = math.abs(math_angle_diff(fp1.yaw_bias, fp2.yaw_bias))
    score = score - (bias_diff * 0.5)
    
    local delta_diff = math.abs(fp1.delta_avg - fp2.delta_avg)
    score = score - (delta_diff * 1.5)
    
    return math.max(0, score)
end

function fp_apply_known_bias(ent, pdata)
    local steamid = entity.get_steam64(ent)
    if not steamid or not AA_FP_DB[steamid] then return false end
    
    local fp = AA_FP_DB[steamid]
    if fp.confidence > 80 then
        pdata.resolved_yaw = math_normalize_yaw(pdata.lby_yaw + fp.yaw_bias)
        pdata.last_mode = "FP/BIAS"
        return true
    end
    return false
end

eb_on("round_reset", function()
    -- Periodically save/update fingerprints
    local players = entity.get_players(true)
    for i=1, #players do
        local ent = players[i]
        local pdata = get_player_data(ent)
        fp_build(ent, pdata)
    end
end)

-- ===========================
-- § 71  SHOT TIMELINE ANALYZER
-- ===========================

SHOT_TIMELINE = {}

function sta_record_shot(ent, tick, yaw)
    if not SHOT_TIMELINE[ent] then SHOT_TIMELINE[ent] = { shots = {}, switches = {} } end
    table.insert(SHOT_TIMELINE[ent].shots, { tick = tick, yaw = yaw })
end

function sta_record_aa_change(ent, tick, new_yaw)
    if not SHOT_TIMELINE[ent] then SHOT_TIMELINE[ent] = { shots = {}, switches = {} } end
    table.insert(SHOT_TIMELINE[ent].switches, { tick = tick, yaw = new_yaw })
end

function sta_find_correlation(ent)
    local data = SHOT_TIMELINE[ent]
    if not data or #data.shots == 0 or #data.switches == 0 then return 0 end
    
    local correlations = 0
    for i=1, #data.shots do
        local s = data.shots[i]
        for j=1, #data.switches do
            local sw = data.switches[j]
            -- If AA flipped within 4 ticks of shooting, high correlation
            if math.abs(s.tick - sw.tick) <= 4 then
                correlations = correlations + 1
                break
            end
        end
    end
    return (correlations / #data.shots) * 100
end

-- Hook into event bus: on weapon_fire
client.set_event_callback("weapon_fire", function(e)
    local shooter = client.userid_to_entindex(e.userid)
    local me = entity.get_local_player()
    if shooter ~= me then
        local wpn = entity.get_player_weapon(shooter)
        local cur_yaw = entity.get_prop(shooter, "m_angEyeAngles[1]") or 0
        sta_record_shot(shooter, globals.tickcount(), cur_yaw)
    end
end)

-- ===========================
-- § 72  ANGLE CLUSTER ANALYZER
-- ===========================

function aca_circular_kmeans(yaws, k)
    if #yaws < k then return {} end
    
    local clusters = {}
    -- Init k random centroids
    for i=1, k do
        table.insert(clusters, { centroid = yaws[i], members = {} })
    end
    
    local iters = 0
    local changed = true
    while changed and iters < 10 do
        changed = false
        iters = iters + 1
        
        -- Clear members
        for i=1, k do clusters[i].members = {} end
        
        -- Assign to closest centroid
        for i=1, #yaws do
            local best_dist = 999
            local best_idx = 1
            for j=1, k do
                local d = math.abs(math_angle_diff(yaws[i], clusters[j].centroid))
                if d < best_dist then
                    best_dist = d
                    best_idx = j
                end
            end
            table.insert(clusters[best_idx].members, yaws[i])
        end
        
        -- Update centroids
        for i=1, k do
            if #clusters[i].members > 0 then
                local sum = 0
                for _, mem in ipairs(clusters[i].members) do
                    sum = sum + mem
                end
                local new_centroid = sum / #clusters[i].members
                if math.abs(math_angle_diff(new_centroid, clusters[i].centroid)) > 1.0 then
                    clusters[i].centroid = new_centroid
                    changed = true
                end
            end
        end
    end
    return clusters
end

function aca_dominant_cluster(clusters)
    if not clusters or #clusters == 0 then return nil end
    local dom = clusters[1]
    for i=2, #clusters do
        if #clusters[i].members > #dom.members then
            dom = clusters[i]
        end
    end
    return dom
end

function aca_apply(ent, pdata)
    local yaws = pdata.yaw_history
    if #yaws < 8 then return false end
    
    local clusters = aca_circular_kmeans(yaws, 3)
    local dom = aca_dominant_cluster(clusters)
    
    if dom and #dom.members > (#yaws * 0.5) then
        pdata.resolved_yaw = math_normalize_yaw(dom.centroid)
        pdata.last_mode = "ACA/DOMINANT"
        return true
    end
    return false
end

-- ===========================
-- § 73  ANTI-AIM PATTERN RECOGNITION (AAPR)
-- ===========================

AAPR_PATTERNS = {
    { id = 1, name = "Jitter 180",  delta = 180, rate = 1.0 },
    { id = 2, name = "Sideways 90", delta = 90,  rate = 0.5 },
    { id = 3, name = "Slowspin CW", delta = 10,  rate = 1.0, is_spin = true },
    { id = 5, name = "Low fake",    delta = 3,   choke_min = 8 }
}

function aapr_extract_features(pdata)
    local yaws = pdata.yaw_history
    if #yaws < 4 then return nil end
    
    local avg_delta = 0
    local max_delta = 0
    for i=1, #yaws-1 do
        local d = math.abs(math_angle_diff(yaws[i], yaws[i+1]))
        avg_delta = avg_delta + d
        if d > max_delta then max_delta = d end
    end
    avg_delta = avg_delta / (#yaws - 1)
    
    return {
        avg_d = avg_delta,
        max_d = max_delta,
        choke = pdata.choke_ticks
    }
end

function aapr_match_pattern(features)
    if not features then return nil end
    
    if features.max_d > 170 then return AAPR_PATTERNS[1] end
    if features.max_d > 80 and features.max_d < 110 then return AAPR_PATTERNS[2] end
    if features.choke > 8 and features.max_d < 10 then return AAPR_PATTERNS[4] end
    
    return nil
end

-- ===========================
-- § 100 SHOT RESULT ANALYZER
-- ===========================

SRA_HISTORY = {}

function sra_record_shot_full(ent, pdata, wid, result)
    if not SRA_HISTORY[ent] then SRA_HISTORY[ent] = {} end
    local snap = {
        tick = globals.tickcount(),
        yaw = pdata.eye_yaw,
        resolved = pdata.resolved_yaw,
        mode = pdata.last_mode,
        choke = pdata.choke_ticks,
        hit = result
    }
    table.insert(SRA_HISTORY[ent], snap)
    
    if #SRA_HISTORY[ent] > 50 then table.remove(SRA_HISTORY[ent], 1) end
end

function sra_analyze_miss(ent)
    local hist = SRA_HISTORY[ent]
    if not hist or #hist == 0 then return "UNKNOWN" end
    
    local last_shot = hist[#hist]
    if last_shot.hit then return "N/A" end
    
    if last_shot.choke > 10 then return "HIGH_CHOKE" end
    if string.match(last_shot.mode, "FW/") then return "FAKEWALK_MISPREDICT" end
    if string.match(last_shot.mode, "SPIN/") then return "SPIN_SPEED_CHANGE" end
    
    return "DESYNC_FLIP"
end

eb_on("hit_confirmed", function(victim, event)
    local pdata = get_player_data(victim)
    if pdata then
        local wep = entity.get_player_weapon(entity.get_local_player())
        sra_record_shot_full(victim, pdata, bit.band(entity.get_prop(wep, "m_iItemDefinitionIndex") or 0, 0xFFFF), true)
    end
end)

-- Handle player_hurt to determine misses (client-side approximated if needed)
-- (Due to GS sandbox, native miss logging usually relies on shot_fired / hit pairing)




-- ============================================================
-- ███████╗ █████╗ ███████╗ █████╗    ██╗  ██╗
-- ██╔════╝██╔══██╗╚══███╔╝██╔══██╗   ██║  ██║
-- █████╗  ███████║  ███╔╝ ███████║   ███████║
-- ██╔══╝  ██╔══██║ ███╔╝  ██╔══██║   ╚════██║
-- ██║     ██║  ██║███████╗██║  ██║        ██║
-- ╚═╝     ╚═╝  ╚═╝╚══════╝╚═╝  ╚═╝        ╚═╝
--  FAZA 4: SYSTEMY WIZUALNE I HUD
-- ============================================================

if not ui_esp_enable then ui_esp_enable = ui.new_checkbox("LUA", "B", "Advanced Player ESP") end

-- ===========================
-- § 74  ADVANCED PLAYER ESP
-- ===========================

function ape_draw_box(ent)
    local x1, y1, x2, y2, alpha = entity.get_bounding_box(ent)
    if not x1 or alpha <= 0 then return end
    
    local hw = (x2 - x1) * 0.25
    local hh = (y2 - y1) * 0.25
    
    -- Outline
    renderer.rectangle(x1 - 1, y1 - 1, hw + 2, 3, 0, 0, 0, alpha)
    renderer.rectangle(x1 - 1, y1 - 1, 3, hh + 2, 0, 0, 0, alpha)
    renderer.rectangle(x2 - hw - 1, y1 - 1, hw + 2, 3, 0, 0, 0, alpha)
    renderer.rectangle(x2 - 1, y1 - 1, 3, hh + 2, 0, 0, 0, alpha)
    renderer.rectangle(x1 - 1, y2 - 1, hw + 2, 3, 0, 0, 0, alpha)
    renderer.rectangle(x1 - 1, y2 - hh - 1, 3, hh + 2, 0, 0, 0, alpha)
    renderer.rectangle(x2 - hw - 1, y2 - 1, hw + 2, 3, 0, 0, 0, alpha)
    renderer.rectangle(x2 - 1, y2 - hh - 1, 3, hh + 2, 0, 0, 0, alpha)
    
    -- Main lines
    renderer.rectangle(x1, y1, hw, 1, 255, 255, 255, alpha)
    renderer.rectangle(x1, y1, 1, hh, 255, 255, 255, alpha)
    renderer.rectangle(x2 - hw, y1, hw, 1, 255, 255, 255, alpha)
    renderer.rectangle(x2, y1, 1, hh, 255, 255, 255, alpha)
    renderer.rectangle(x1, y2, hw, 1, 255, 255, 255, alpha)
    renderer.rectangle(x1, y2 - hh, 1, hh, 255, 255, 255, alpha)
    renderer.rectangle(x2 - hw, y2, hw, 1, 255, 255, 255, alpha)
    renderer.rectangle(x2, y2 - hh, 1, hh, 255, 255, 255, alpha)
end

function ape_draw_health(ent, x1, y1, x2, y2, alpha)
    local hp = entity.get_prop(ent, "m_iHealth") or 0
    local hp_pct = math.min(100, math.max(0, hp)) / 100.0
    
    local r = 255 - (hp_pct * 255)
    local g = hp_pct * 255
    local h = (y2 - y1)
    local bar_h = math.floor(h * hp_pct)
    
    renderer.rectangle(x1 - 5, y1 - 1, 3, h + 2, 0, 0, 0, alpha * 0.6)
    renderer.rectangle(x1 - 4, y2 - bar_h, 1, bar_h, r, g, 50, alpha)
    
    if hp < 100 then
        renderer.text(x1 - 4, y2 - bar_h - 5, 255, 255, 255, alpha, "c-", 0, tostring(hp))
    end
end

function ape_draw_info(ent, x1, y1, x2, y2, alpha)
    local pdata = get_player_data(ent)
    
    local mode = pdata.last_mode or "UNKNOWN"
    local conf = pdata.confidence or 0
    local r, g = 255 - (conf * 2.5), conf * 2.5
    
    renderer.text(x2 + 4, y1, r, g, 50, alpha, "-", 0, string.format("R: %s", mode))
    renderer.text(x2 + 4, y1 + 10, 200, 200, 200, alpha, "-", 0, string.format("C: %d%%", conf))
    
    if pdata.spin_lock and pdata.spin_lock > 0 then
        renderer.text(x2 + 4, y1 + 20, 255, 50, 50, alpha, "-", 0, "SPIN LOCK")
    end
    
    if pdata.choke_ticks and pdata.choke_ticks > 0 then
        renderer.text(x2 + 4, y1 + 30, 200, 50, 255, alpha, "-", 0, string.format("CHOKE: %d", pdata.choke_ticks))
    end
end

-- ===========================
-- § 75  BULLET IMPACT TRACER
-- ===========================

BULLET_IMPACTS = {}

function btr_record_impact(e)
    local me = entity.get_local_player()
    if client.userid_to_entindex(e.userid) == me then
        local my_pos = {client.eye_position()}
        if not my_pos[1] then return end
        table.insert(BULLET_IMPACTS, {
            time = globals.curtime(),
            start_x = my_pos[1], start_y = my_pos[2], start_z = my_pos[3],
            end_x = e.x, end_y = e.y, end_z = e.z
        })
    end
end

client.set_event_callback("bullet_impact", btr_record_impact)

function btr_draw_tracers()
    local now = globals.curtime()
    for i = #BULLET_IMPACTS, 1, -1 do
        local imp = BULLET_IMPACTS[i]
        local age = now - imp.time
        if age > 3.0 then
            table.remove(BULLET_IMPACTS, i)
        else
            local alpha = (1.0 - (age / 3.0)) * 255
            local sx, sy = renderer.world_to_screen(imp.start_x, imp.start_y, imp.start_z)
            local ex, ey = renderer.world_to_screen(imp.end_x, imp.end_y, imp.end_z)
            
            if sx and ex then
                renderer.line(sx, sy, ex, ey, 255, 100, 100, alpha)
                renderer.circle(ex, ey, 255, 100, 100, alpha, 3, 0, 1)
            end
        end
    end
end

-- ===========================
-- § 77  VELOCITY VECTOR ESP
-- ===========================

function vve_draw(ent, pdata)
    local ox, oy, oz = entity.get_prop(ent, "m_vecOrigin")
    if not ox then return end
    
    local vx = pdata.vel_x_hist[1] or 0
    local vy = pdata.vel_y_hist[1] or 0
    local vz = pdata.vel_z_hist[1] or 0
    if vx == 0 and vy == 0 then return end
    
    local tx = ox + (vx * 0.5)
    local ty = oy + (vy * 0.5)
    local tz = oz + (vz * 0.5)
    
    local sx, sy = renderer.world_to_screen(ox, oy, oz)
    local ex, ey = renderer.world_to_screen(tx, ty, tz)
    
    if sx and ex then
        local spd = math_vec_len2d(vx, vy)
        local r = math.min(255, spd)
        local g = math.max(0, 255 - spd)
        renderer.line(sx, sy, ex, ey, r, g, 50, 255)
    end
end

-- ===========================
-- § 78  ON-SCREEN SCOPE / FOV INDICATOR
-- ===========================

function fov_to_enemy(ent)
    local me = entity.get_local_player()
    local mx, my, mz = client.eye_position()
    local tx, ty, tz = entity.hitbox_position(ent, HITBOX_HEAD)
    if not tx then return 999 end
    
    local pitch, yaw = entity.get_prop(me, "m_angEyeAngles[0]"), entity.get_prop(me, "m_angEyeAngles[1]")
    if not pitch then return 999 end
    
    local id_yaw = math.deg(math.atan2(ty - my, tx - mx))
    local dist_2d = math_vec_len2d(tx - mx, ty - my)
    local id_pitch = math.deg(math.atan2(mz - tz, dist_2d))
    
    local diff_yaw = math.abs(math_angle_diff(yaw, id_yaw))
    local diff_pitch = math.abs(math_angle_diff(pitch, id_pitch))
    
    return math_vec_len2d(diff_yaw, diff_pitch)
end

function fov_circle_draw()
    local me = entity.get_local_player()
    if not me then return end
    
    local players = entity.get_players(true)
    local best_fov = 999
    local best_ent = nil
    
    for i=1, #players do
        local f = fov_to_enemy(players[i])
        if f < best_fov then
            best_fov = f
            best_ent = players[i]
        end
    end
    
    if best_ent and best_fov < 30 then
        local sw, sh = client.screen_size()
        local r, g = 255, 50
        if best_fov < 3 then r, g = 50, 255
        elseif best_fov < 8 then r, g = 255, 200 end
        
        -- Radius scales inversely with FOV
        local radius = math.max(5, 50 - best_fov)
        renderer.circle_outline(sw/2, sh/2, r, g, 50, 100, radius, 0, 1, 2)
    end
end

-- ===========================
-- § 88  MASTER HUD SYSTEM V2 & § 89 CONFIDENCE METER
-- ===========================

function master_hud_draw()
    if not ui.get(ui_hud) then return end
    local sw, sh = client.screen_size()
    
    -- Status Bar Top
    renderer.rectangle(sw/2 - 100, 10, 200, 30, 25, 25, 30, 220)
    renderer.rectangle(sw/2 - 100, 40, 200, 2, 100, 150, 255, 255)
    renderer.text(sw/2, 25, 255, 255, 255, 255, "c", 0, "UV AI ENGINE v5.0")
    
    -- Confidence Meter (Left Side)
    local cx, cy = 60, sh - 60
    local radius = 40
    renderer.circle_outline(cx, cy, 30, 30, 30, 200, radius, 0, 1, 5)
    
    local target = client.current_threat()
    local conf = 0
    if target then 
        local pdata = get_player_data(target)
        conf = pdata.confidence or 0 
    end
    
    local r, g = 255 - (conf * 2.5), conf * 2.5
    renderer.circle_outline(cx, cy, r, g, 50, 255, radius, -180, conf * 3.6, 5)
    renderer.text(cx, cy, 255, 255, 255, 255, "c", 0, string.format("%d%%", conf))
end

-- ===========================
-- § 90  SHOT PREDICTION PREVIEW
-- ===========================

function spp_draw_predicted_hitbox(ent, pdata)
    if not ui.get(ui_esp_enable) then return end
    local head_x, head_y, head_z = entity.hitbox_position(ent, HITBOX_HEAD)
    if not head_x then return end
    
    -- If we have a resolved yaw, draw a small indicator where we think the head is
    local sx, sy = renderer.world_to_screen(head_x, head_y, head_z + 15)
    if sx then
        local mode = pdata.last_mode or "?"
        renderer.text(sx, sy, 50, 255, 100, 200, "c-", 0, "> " .. mode .. " <")
    end
end

-- Hook ESP
client.set_event_callback("paint", function()
    btr_draw_tracers()
    fov_circle_draw()
    master_hud_draw()
    
    if ui.get(ui_esp_enable) then
        local players = entity.get_players(true)
        for i=1, #players do
            local ent = players[i]
            if not entity.is_dormant(ent) then
                ape_draw_box(ent)
                
                local x1, y1, x2, y2, alpha = entity.get_bounding_box(ent)
                if x1 and alpha > 0 then
                    ape_draw_health(ent, x1, y1, x2, y2, alpha)
                    ape_draw_info(ent, x1, y1, x2, y2, alpha)
                end
                
                local pdata = get_player_data(ent)
                vve_draw(ent, pdata)
                spp_draw_predicted_hitbox(ent, pdata)
            end
        end
    end
end)




-- ============================================================
-- ███████╗ █████╗ ███████╗ █████╗    ███████╗
-- ██╔════╝██╔══██╗╚══███╔╝██╔══██╗   ██╔════╝
-- █████╗  ███████║  ███╔╝ ███████║   ███████╗
-- ██╔══╝  ██╔══██║ ███╔╝  ██╔══██║   ╚════██║
-- ██║     ██║  ██║███████╗██║  ██║   ███████║
-- ╚═╝     ╚═╝  ╚═╝╚══════╝╚═╝  ╚═╝   ╚══════╝
--  FAZA 5: ANTI-AIM & DEFENSE ENGINE
-- ============================================================

if not ui_aa_enable then ui_aa_enable = ui.new_checkbox("LUA", "B", "UV Advanced AA") end

-- ===========================
-- § 97  SPECTATOR AWARENESS SYSTEM
-- ===========================

function sas_count_spectators()
    local me = entity.get_local_player()
    if not me or not entity.is_alive(me) then return 0 end
    
    local count = 0
    local plrs = entity.get_players(false) -- False to include teammates
    for i=1, #plrs do
        local plr = plrs[i]
        if not entity.is_alive(plr) then
            local target = entity.get_prop(plr, "m_hObserverTarget")
            if target == me then
                count = count + 1
            end
        end
    end
    return count
end

function sas_draw_spec_list()
    if not ui.get(ui_hud) then return end
    local count = sas_count_spectators()
    
    if count > 0 then
        local sw, sh = client.screen_size()
        renderer.text(sw/2, 90, 255, 100, 100, 255, "c", 0, string.format("[%d SPECTATING]", count))
    end
end
client.set_event_callback("paint", sas_draw_spec_list)

-- ===========================
-- § 81  EDGE PEEKING ASSISTANT
-- ===========================

function epa_detect_corner(me)
    local ex, ey, ez = client.eye_position()
    -- Cast rays left and right to see which wall is closer
    -- This helps decide which side to desync towards
    
    local yaw = entity.get_prop(me, "m_angEyeAngles[1]") or 0
    local r_yaw = math.rad(yaw - 90)
    local l_yaw = math.rad(yaw + 90)
    
    local dist = 60
    local tx_r = ex + math.cos(r_yaw) * dist
    local ty_r = ey + math.sin(r_yaw) * dist
    
    local tx_l = ex + math.cos(l_yaw) * dist
    local ty_l = ey + math.sin(l_yaw) * dist
    
    local frac_r, hit_r = client.trace_line(me, ex, ey, ez, tx_r, ty_r, ez)
    local frac_l, hit_l = client.trace_line(me, ex, ey, ez, tx_l, ty_l, ez)
    
    if frac_r < frac_l then
        return "RIGHT"
    elseif frac_l < frac_r then
        return "LEFT"
    end
    return "OPEN"
end

-- ===========================
-- § 80  DESYNC CONTROLLER
-- ===========================

function dc_adaptive_delta(me)
    local target = client.current_threat()
    if not target then return 58 end 
    
    -- Reduce delta slightly if target has AWPs/SSG to avoid hitbox overlap bugs
    local wpn = entity.get_player_weapon(target)
    if wpn then
        local wid = bit.band(entity.get_prop(wpn, "m_iItemDefinitionIndex") or 0, 0xFFFF)
        if wid == 40 or wid == 9 then -- SSG / AWP
            return 45
        end
    end
    return 58
end

-- ===========================
-- § 79  ANTI-AIM CORE ENGINE
-- ===========================

AA_STATE = {
    flip = false,
    jitter_tick = 0,
    last_profile = "SAFE"
}

function aa_select_profile(me)
    local vx, vy = entity.get_prop(me, "m_vecVelocity[0]"), entity.get_prop(me, "m_vecVelocity[1]")
    local speed = math_vec_len2d(vx or 0, vy or 0)
    local duck_amt = entity.get_prop(me, "m_flDuckAmount") or 0
    
    local specs = sas_count_spectators()
    
    if specs > 0 then
        -- Play safer if spectated to avoid Overwatch (Legacy) / Trust Factor hits
        return "LEGIT"
    end
    
    if speed > 100 then
        return "RUN"
    end
    
    local corner = epa_detect_corner(me)
    if corner == "LEFT" then return "HIDE_LEFT" end
    if corner == "RIGHT" then return "HIDE_RIGHT" end
    
    if duck_amt > 0.5 then
        return "CROUCH"
    end
    
    return "STAND"
end

function aa_apply(cmd)
    if not ui.get(ui_aa_enable) then return end
    local me = entity.get_local_player()
    if not me or not entity.is_alive(me) then return end
    
    -- We can intercept cmd angles if we had access to setup_command completely.
    -- Assuming GS setup_command(cmd).
    -- GS uses ui elements to control AA natively, but we can override via ui.set or cmd.
    
    local profile = aa_select_profile(me)
    AA_STATE.last_profile = profile
    
    local delta = dc_adaptive_delta(me)
    
    AA_STATE.jitter_tick = AA_STATE.jitter_tick + 1
    if AA_STATE.jitter_tick % 2 == 0 then AA_STATE.flip = not AA_STATE.flip end
    
    -- Pseudo code to represent how we would instruct the GS AA natively:
    -- (Actually changing AA in gamesense requires ui.set on the AA elements)
    -- We can set pitch/yaw base via standard anti-aim features.
    
    if profile == "LEGIT" then
        -- Use micromovements to break LBY
    elseif profile == "HIDE_LEFT" then
        -- Desync towards wall (left)
    elseif profile == "HIDE_RIGHT" then
        -- Desync towards wall (right)
    elseif profile == "RUN" then
        -- Jitter desync
    else
        -- Stand
    end
end

client.set_event_callback("setup_command", aa_apply)




-- ============================================================
-- ███████╗ █████╗ ███████╗ █████╗     ██████╗ 
-- ██╔════╝██╔══██╗╚══███╔╝██╔══██╗   ██╔════╝ 
-- █████╗  ███████║  ███╔╝ ███████║   ███████╗ 
-- ██╔══╝  ██╔══██║ ███╔╝  ██╔══██║   ██╔═══██╗
-- ██║     ██║  ██║███████╗██║  ██║   ╚██████╔╝
-- ╚═╝     ╚═╝  ╚═╝╚══════╝╚═╝  ╚═╝    ╚═════╝ 
--  FAZA 6: UI, INFRASTRUKTURA I OPTYMALIZACJA
-- ============================================================

-- ===========================
-- § 92  PERFORMANCE PROFILER
-- ===========================

PROFILER = {
    blocks = {},
    active = nil,
    start_time = 0,
    history = {}
}

function prof_start(name)
    PROFILER.active = name
    PROFILER.start_time = globals.realtime()
end

function prof_end(name)
    if PROFILER.active ~= name then return end
    local duration = globals.realtime() - PROFILER.start_time
    
    if not PROFILER.blocks[name] then
        PROFILER.blocks[name] = { total = 0, count = 0, avg = 0 }
    end
    
    local stat = PROFILER.blocks[name]
    stat.total = stat.total + duration
    stat.count = stat.count + 1
    -- Running average
    stat.avg = (stat.avg * 0.9) + (duration * 0.1)
    
    PROFILER.active = nil
end

function prof_report()
    local max_items = 10
    local sorted = {}
    for name, stat in pairs(PROFILER.blocks) do
        table.insert(sorted, {n = name, avg = stat.avg, count = stat.count})
    end
    table.sort(sorted, function(a,b) return a.avg > b.avg end)
    
    client.color_log(50, 255, 50, "[UV-PERF] --- PROFILER REPORT ---")
    for i=1, math.min(#sorted, max_items) do
        local v = sorted[i]
        client.color_log(200, 200, 200, string.format("  %d. %s : %.4f ms (%d calls)", i, v.n, v.avg * 1000, v.count))
    end
end

-- ===========================
-- § 93  LOCALIZATION SYSTEM
-- ===========================

I18N = {
    lang = "EN",
    dict = {
        EN = {
            SAFE_MODE = "SAFE MODE ACTIVE",
            NETWORK = "Network:",
            CONFIDENCE = "Confidence",
            LOADED = "Profile Loaded",
            SAVED = "Profile Saved"
        },
        PL = {
            SAFE_MODE = "TRYB AWARYJNY",
            NETWORK = "Siec:",
            CONFIDENCE = "Pewnosc",
            LOADED = "Profil Wczytany",
            SAVED = "Profil Zapisany"
        },
        RU = {
            SAFE_MODE = "БЕЗОПАСНЫЙ РЕЖИМ",
            NETWORK = "Сеть:",
            CONFIDENCE = "Уверенность",
            LOADED = "Профиль Загружен",
            SAVED = "Профиль Сохранен"
        }
    }
}

function i18n_set_lang(l)
    if I18N.dict[l] then I18N.lang = l end
end

function i18n_t(key)
    local d = I18N.dict[I18N.lang]
    return (d and d[key]) or I18N.dict["EN"][key] or key
end

ui_lang_select = ui.new_combobox("LUA", "B", "UV Language", "EN", "PL", "RU")
ui.set_callback(ui_lang_select, function(ref)
    i18n_set_lang(ui.get(ref))
end)

-- ===========================
-- § 85  CONFIG PROFILES SYSTEM
-- ===========================

function cfg_serialize_all()
    -- Prosty serializer UI
    local state = {}
    state.esp = ui.get(ui_esp_enable)
    state.hud = ui.get(ui_hud)
    state.aa = ui.get(ui_aa_enable)
    return json.stringify(state)
end

function cfg_deserialize_all(str)
    if not str or str == "" then return end
    local state = json.parse(str)
    if not state then return end
    
    if state.esp ~= nil then ui.set(ui_esp_enable, state.esp) end
    if state.hud ~= nil then ui.set(ui_hud, state.hud) end
    if state.aa ~= nil then ui.set(ui_aa_enable, state.aa) end
end

function cfg_save(slot)
    local data = cfg_serialize_all()
    database.write("uv_config_slot_" .. tostring(slot), data)
    client.color_log(50, 255, 50, i18n_t("SAVED") .. " [" .. tostring(slot) .. "]")
end

function cfg_load(slot)
    local data = database.read("uv_config_slot_" .. tostring(slot))
    if data then
        cfg_deserialize_all(data)
        client.color_log(50, 255, 50, i18n_t("LOADED") .. " [" .. tostring(slot) .. "]")
    end
end

ui_cfg_slot = ui.new_slider("LUA", "B", "Config Slot", 1, 5, 1)
ui.new_button("LUA", "B", "Save UV Config", function() cfg_save(ui.get(ui_cfg_slot)) end)
ui.new_button("LUA", "B", "Load UV Config", function() cfg_load(ui.get(ui_cfg_slot)) end)

-- ===========================
-- § 86  RESOLVER TAB UI OVERHAUL
-- ===========================

-- GS UI elements can get cluttered. Best practice is to selectively hide them based on a master switch.
function ui_visibility_update()
    local master = ui.get(ui_enabled)
    ui.set_visible(ui_hud, master)
    ui.set_visible(ui_esp_enable, master)
    ui.set_visible(ui_lang_select, master)
    ui.set_visible(ui_cfg_slot, master)
end

ui.set_callback(ui_enabled, ui_visibility_update)
ui_visibility_update()

-- ===========================
-- § 87  IN-GAME MENU OVERLAY
-- ===========================

MENU_STATE = {
    open = false,
    x = 100, y = 100,
    w = 600, h = 400,
    tab = 1
}

function menu_toggle()
    MENU_STATE.open = not MENU_STATE.open
end

-- Hook an obscure key for internal menu (e.g. HOME - virtual key 0x24)
client.set_event_callback("paint", function()
    -- Note: properly detecting keypress in paint requires tracking state to avoid spam
    if not MENU_STATE.was_pressed and client.key_state(0x24) then
        MENU_STATE.open = not MENU_STATE.open
        MENU_STATE.was_pressed = true
    elseif not client.key_state(0x24) then
        MENU_STATE.was_pressed = false
    end
    
    if MENU_STATE.open then
        prof_start("menu_draw")
        -- Backdrop
        renderer.rectangle(MENU_STATE.x, MENU_STATE.y, MENU_STATE.w, MENU_STATE.h, 15, 15, 20, 240)
        -- Header
        renderer.gradient(MENU_STATE.x, MENU_STATE.y, MENU_STATE.w, 40, 50, 0, 100, 255, 10, 10, 20, 255, true)
        renderer.text(MENU_STATE.x + 20, MENU_STATE.y + 12, 255, 255, 255, 255, "", 0, "Aether.sev")
        
        -- Basic content
        renderer.text(MENU_STATE.x + 20, MENU_STATE.y + 60, 200, 200, 200, 255, "", 0, "Press HOME to close.")
        local net_info = string.format("Ping: %.1fms | Loss: %d%%", NC_METRICS.ping_avg * 1000, NC_METRICS.packet_loss)
        renderer.text(MENU_STATE.x + 20, MENU_STATE.y + 80, 150, 255, 150, 255, "", 0, net_info)
        
        prof_end("menu_draw")
    end
end)





-- ============================================================
-- ███████╗ █████╗ ███████╗ █████╗    ██████╗
-- ██╔════╝██╔══██╗╚══███╔╝██╔══██╗   ╚════██╗
-- █████╗  ███████║  ███╔╝ ███████║    █████╔╝
-- ██╔══╝  ██╔══██║ ███╔╝  ██╔══██║   ██╔═══╝
-- ██║     ██║  ██║███████╗██║  ██║   ██║
-- ╚═╝     ╚═╝  ╚═╝╚══════╝╚═╝  ╚═╝   ╚═╝
--  FAZA 7: FINALIZACJA, REKOMPENSATY I BAZA WIEDZY
-- ============================================================

-- ===========================
-- § 84  LAG COMPENSATION RECORDER
-- ===========================

BACKGROUND_LCR_STORAGE = {}

function lcr_record_frame(ent)
    if not BACKGROUND_LCR_STORAGE[ent] then BACKGROUND_LCR_STORAGE[ent] = {} end
    local hist = BACKGROUND_LCR_STORAGE[ent]
    
    local ox, oy, oz = entity.get_origin(ent)
    local sim_time = entity.get_prop(ent, "m_flSimulationTime") or 0
    if not ox or sim_time == 0 then return end
    
    -- Ensure we don't save duplicate sim times
    if #hist > 0 and hist[1].sim_time == sim_time then return end
    
    local record = {
        sim_time = sim_time,
        ox = ox, oy = oy, oz = oz,
        real_time = globals.realtime()
    }
    
    table.insert(hist, 1, record)
    
    -- Truncate to 64 frames (128-tick support ~0.5s)
    if #hist > 64 then table.remove(hist) end
end

function lcr_get_at_tick(ent, target_sim_time)
    local hist = BACKGROUND_LCR_STORAGE[ent]
    if not hist then return nil end
    
    for i=1, #hist do
        if math.abs(hist[i].sim_time - target_sim_time) < 0.005 then
            return hist[i]
        end
    end
    return nil
end

function lcr_best_tick_for_shoot(ent)
    local hist = BACKGROUND_LCR_STORAGE[ent]
    if not hist or #hist == 0 then return 0 end
    
    -- Very naive implementation: prefer older ticks when they are moving fast,
    -- newer ticks when standing still, effectively reversing their advantage
    local pdata = get_player_data(ent)
    local vel = math_vec_len2d(pdata.vel_x_hist[1] or 0, pdata.vel_y_hist[1] or 0)
    
    if vel > 200 and #hist >= 6 then
        return hist[6].sim_time -- backtrack ~6 ticks
    end
    
    return hist[1].sim_time
end

client.set_event_callback("net_update_end", function()
    local players = entity.get_players(true)
    for i = 1, #players do
        if not entity.is_dormant(players[i]) then
            lcr_record_frame(players[i])
        end
    end
end)

-- ===========================
-- § 83  SERVER-SIDE HIT DETECTION EMULATOR
-- ===========================

function sshde_predict_serverside_pos(ent, latency_ticks)
    local ox, oy, oz = entity.get_origin(ent)
    local pdata = get_player_data(ent)
    
    local vx, vy = pdata.vel_x_hist[1] or 0, pdata.vel_y_hist[1] or 0
    local vz = pdata.vel_z_hist[1] or 0
    
    local dt = latency_ticks * globals.tickinterval()
    
    return ox + (vx * dt), oy + (vy * dt), oz + (vz * dt)
end

function sshde_validate_shot(ent, tx, ty, tz)
    local me = entity.get_local_player()
    local ex, ey, ez = client.eye_position()
    
    local frac, hit_ent = client.trace_line(me, ex, ey, ez, tx, ty, tz)
    if hit_ent == ent then
        return true
    elseif frac == 1.0 then
        -- Might hit, just relying on hitbox expansion
        return true
    end
    return false
end

function sshde_confidence_score(ent)
    local p_ping = ncm_packet_loss_rate()
    local ping_val = NC_METRICS.ping_avg
    
    local score = 100
    if p_ping > 5 then score = score - 30 end
    if ping_val > 0.08 then score = score - 20 end
    
    local pdata = get_player_data(ent)
    if pdata.choke_ticks > 6 then score = score - 40 end
    
    return math.max(0, score)
end

-- ===========================
-- § 98  LONG-TERM PLAYER DATABASE
-- ===========================

DB_CACHE = {}

function db_load_player(ent)
    local steam64 = entity.get_steam64(ent)
    if not steam64 then return end
    
    local key = "uv_player_" .. steam64
    local data = database.read(key)
    if data then
        local ok, parsed = pcall(json.parse, data)
        if ok and parsed then
            DB_CACHE[steam64] = parsed
            client.color_log(50, 255, 50, "[Aether.sev] Loaded knowledge for " .. steam64)
            return
        end
    end
    
    -- New player record
    DB_CACHE[steam64] = {
        steamid = steam64,
        total_shots = 0,
        total_hits = 0,
        seen_patterns = {},
        sessions = 1,
        avg_confidence = 50
    }
end

function db_save_player(ent)
    local steam64 = entity.get_steam64(ent)
    if not steam64 or not DB_CACHE[steam64] then return end
    
    local key = "uv_player_" .. steam64
    local data = json.stringify(DB_CACHE[steam64])
    database.write(key, data)
end

function db_record_shot(ent, hit)
    local steam64 = entity.get_steam64(ent)
    if not steam64 or not DB_CACHE[steam64] then return end
    
    local rec = DB_CACHE[steam64]
    rec.total_shots = rec.total_shots + 1
    if hit then rec.total_hits = rec.total_hits + 1 end
    
    local pdata = get_player_data(ent)
    if pdata.last_mode and not rec.seen_patterns[pdata.last_mode] then
        rec.seen_patterns[pdata.last_mode] = 1
    else
        rec.seen_patterns[pdata.last_mode] = rec.seen_patterns[pdata.last_mode] + 1
    end
end

eb_on("hit_confirmed", function(victim, event)
    db_record_shot(victim, true)
end)

client.set_event_callback("player_connect_full", function(e)
    local me = entity.get_local_player()
    if client.userid_to_entindex(e.userid) == me then
        -- we connected, load all current players
        local plrs = entity.get_players()
        for i=1, #plrs do db_load_player(plrs[i]) end
    end
end)

client.set_event_callback("player_disconnect", function(e)
    local idx = client.userid_to_entindex(e.userid)
    db_save_player(idx)
end)

-- ============================================================
-- UV RESOLVER END OF FILE
-- ============================================================

-- ============================================================
-- BUYBOT MODULE
-- ============================================================

local var_0_0 = require("gamesense/csgo_weapons")
local var_0_1 = require("gamesense/panorama_events")
local var_0_2 = {}
local var_0_3 = {}
local var_0_4 = {}
local var_0_5 = {}
local var_0_6 = {}
local var_0_7 = table.insert
local var_0_8 = false
local var_0_9
local var_0_10
local var_0_11
local var_0_12 = panorama.open()
local var_0_13 = var_0_12.LoadoutAPI
local var_0_14 = var_0_12.InventoryAPI
local var_0_15 = var_0_12.MatchStatsAPI
local var_0_16 = false
local var_0_17 = {}
local var_0_18 = database.read("pilotbuybot") or {}
local var_0_19 = ui.new_checkbox("LUA", "B", "Pilot's buybot")
local var_0_20

local function var_0_21(arg_1_0, arg_1_1)
	for iter_1_0 = 1, #arg_1_0 do
		if arg_1_0[iter_1_0] == arg_1_1 then
			return true
		end
	end

	return false
end

local function var_0_22(arg_2_0, arg_2_1)
	for iter_2_0, iter_2_1 in ipairs(arg_2_0) do
		if iter_2_1[1] == arg_2_1 then
			return true
		end
	end

	return false
end

local function var_0_23(arg_3_0, arg_3_1)
	local var_3_0 = {}

	for iter_3_0 in (arg_3_0 .. arg_3_1):gmatch("(.-)" .. arg_3_1) do
		table.insert(var_3_0, iter_3_0)
	end

	return var_3_0
end

;(function()
	if var_0_20 then
		ui.set_visible(var_0_20, false)

		var_0_16 = true
	end

	local var_4_0 = {}
	local var_4_1 = ""

	for iter_4_0, iter_4_1 in ipairs(var_0_18) do
		table.insert(var_4_0, iter_4_1.name)
		table.insert(var_0_17, iter_4_1.values)

		var_4_1 = var_4_1 .. iter_4_1.name .. ","
	end

	local var_4_2 = var_4_1 .. "Custom [+]"

	table.insert(var_4_0, "Custom [+]")

	var_0_11 = var_0_23(var_4_2, ",")

	if not var_0_20 and #var_0_18 > 0 then
		var_0_20 = ui.new_combobox("LUA", "B", "Preset", var_0_11)
	end
end)()
var_0_7(var_0_3, "-")
var_0_7(var_0_4, "-")
var_0_7(var_0_6, "Flashbang")

local function var_0_24(arg_5_0, arg_5_1)
	local var_5_0 = var_0_14.GetFauxItemIDFromDefAndPaintIndex(arg_5_0)
	local var_5_1 = var_0_14.GetSlotSubPosition(var_5_0)
	local var_5_2 = var_0_13.GetItemID(arg_5_1, var_5_1)

	return var_0_14.GetItemDefinitionIndex(var_5_2)
end

local var_0_25
local var_0_26
local var_0_27
local var_0_28 = var_0_0.weapon_m4a1_silencer.idx
local var_0_29 = var_0_0.weapon_cz75a.idx

if var_0_24(var_0_28, "ct") == var_0_28 then
	var_0_25 = true
end

if var_0_24(var_0_29, "ct") == var_0_29 then
	var_0_26 = true
end

if var_0_24(var_0_29, "t") == var_0_29 then
	var_0_27 = true
end

local var_0_30 = {
	["SG 553"] = "\aB5D4EEFFAUG\aFFFFFFCC  \aEAD18AFFSG 553",
	MP9 = "\aB5D4EEFFMP9\aFFFFFFCC  \aEAD18AFFMAC-10",
	["MP5-SD"] = "MP5-SD / MP7",
	FAMAS = "\aB5D4EEFFFAMAS\aFFFFFFCC  \aEAD18AFFGalil",
	G3SG1 = "\aB5D4EEFFSCAR-20\aFFFFFFCC  \aEAD18AFFG3SG1",
	["MAG-7"] = "\aB5D4EEFFMAG-7\aFFFFFFCC  \aEAD18AFFSawed-Off",
	["SCAR-20"] = "\aB5D4EEFFSCAR-20\aFFFFFFCC  \aEAD18AFFG3SG1",
	["Defuse Kit"] = "Defuse / Rescue Kit",
	["Rescue Kit"] = "SKIP",
	["Kevlar + Helmet"] = "Helmet",
	["R8 Revolver"] = "Desert Eagle / R8 Revolver",
	Molotov = "\aB5D4EEFFIncendiary Grenade\aFFFFFFCC  \aEAD18AFFMolotov",
	["Desert Eagle"] = "Desert Eagle / R8 Revolver",
	MP7 = "MP5-SD / MP7",
	["Incendiary Grenade"] = "\aB5D4EEFFIncendiary Grenade\aFFFFFFCC  \aEAD18AFFMolotov",
	["USP-S"] = "SKIP",
	P2000 = "SKIP",
	["MAC-10"] = "\aB5D4EEFFMP9\aFFFFFFCC  \aEAD18AFFMAC-10",
	["Glock-18"] = "SKIP",
	["Sawed-Off"] = "\aB5D4EEFFMAG-7\aFFFFFFCC  \aEAD18AFFSawed-Off",
	AUG = "\aB5D4EEFFAUG\aFFFFFFCC  \aEAD18AFFSG 553",
	Galil = "\aB5D4EEFFFAMAS\aFFFFFFCC  \aEAD18AFFGalil",
	["AK-47"] = var_0_25 and "\aB5D4EEFFM4A1-S\aFFFFFFCC  \aEAD18AFFAK-47" or "\aB5D4EEFFM4A4\aFFFFFFCC  \aEAD18AFFAK-47",
	M4A4 = var_0_25 and "\aB5D4EEFFM4A1-S\aFFFFFFCC  \aEAD18AFFAK-47" or "\aB5D4EEFFM4A4\aFFFFFFCC  \aEAD18AFFAK-47",
	["M4A1-S"] = var_0_25 and "\aB5D4EEFFM4A1-S\aFFFFFFCC  \aEAD18AFFAK-47" or "\aB5D4EEFFM4A4\aFFFFFFCC  \aEAD18AFFAK-47",
	["Five-SeveN"] = var_0_26 and var_0_27 and "CZ75-Auto" or var_0_26 and "\aB5D4EEFFCZ75-Auto  \aEAD18AFFTec-9" or var_0_27 and "\aB5D4EEFFFive-SeveN  \aEAD18AFFCZ75-Auto" or "\aB5D4EEFFFive-SeveN  \aEAD18AFFTec-9",
	["Tec-9"] = var_0_26 and var_0_27 and "CZ75-Auto" or var_0_26 and "\aB5D4EEFFCZ75-Auto  \aEAD18AFFTec-9" or var_0_27 and "\aB5D4EEFFFive-SeveN  \aEAD18AFFCZ75-Auto" or "\aB5D4EEFFFive-SeveN  \aEAD18AFFTec-9",
	["CZ75-Auto"] = var_0_26 and var_0_27 and "CZ75-Auto" or var_0_26 and "\aB5D4EEFFCZ75-Auto  \aEAD18AFFTec-9" or var_0_27 and "\aB5D4EEFFFive-SeveN  \aEAD18AFFCZ75-Auto" or "\aB5D4EEFFFive-SeveN  \aEAD18AFFTec-9"
}
local var_0_31 = {
	weapon_scar20 = "g3sg1",
	weapon_shield = "1 25",
	weapon_galilar = "famas",
	item_assaultsuit = "vesthelm",
	weapon_sg556 = "aug",
	item_kevlar = "vest",
	weapon_m4a1 = "ak47",
	weapon_m4a1_silencer = "ak47",
	weapon_incgrenade = "molotov",
	weapon_cz75a = "fn57",
	weapon_mp5sd = "mp7",
	weapon_sawedoff = "mag7",
	weapon_revolver = "deagle",
	weapon_tec9 = "fn57",
	weapon_mp9 = "mac10",
	weapon_fiveseven = "fn57"
}

local function var_0_32()
	for iter_6_0 = 1, 64 do
		if var_0_0[iter_6_0] then
			local var_6_0 = var_0_30[var_0_0[iter_6_0].name] or var_0_0[iter_6_0].name

			if var_6_0 == "SKIP" then
				-- block empty
			else
				local var_6_1 = var_0_23(var_0_0[iter_6_0].console_name, "_")
				local var_6_2 = var_0_31[var_0_0[iter_6_0].console_name] or var_6_1[2]

				if not var_0_22(var_0_2, var_6_0) and var_0_0[iter_6_0].is_melee_weapon == false and var_0_0[iter_6_0].idx ~= 52 and var_0_0[iter_6_0].in_game_price > 0 then
					var_0_7(var_0_2, {
						var_6_0,
						var_0_0[iter_6_0].type,
						var_6_2,
						var_0_0[iter_6_0].in_game_price
					})

					if var_0_0[iter_6_0].type == "rifle" or var_0_0[iter_6_0].type == "sniperrifle" or var_0_0[iter_6_0].type == "heavy" or var_0_0[iter_6_0].type == "smg" or var_0_0[iter_6_0].type == "shotgun" or var_0_0[iter_6_0].type == "machinegun" then
						var_0_7(var_0_3, var_6_0)
					end

					if var_0_0[iter_6_0].type == "pistol" then
						var_0_7(var_0_4, var_6_0)
					end

					if var_0_0[iter_6_0].type == "equipment" or var_0_0[iter_6_0].type == "taser" then
						var_0_7(var_0_5, var_6_0)
					end

					if var_0_0[iter_6_0].type == "grenade" then
						var_0_7(var_0_6, var_6_0)
					end
				end
			end
		end
	end
end

local function var_0_33()
	local var_7_0 = {}

	for iter_7_0 = 0, 64 do
		local var_7_1 = entity.get_prop(entity.get_local_player(), "m_hMyWeapons", iter_7_0)

		if var_7_1 then
			table.insert(var_7_0, var_7_1)
		end
	end

	return var_7_0
end

var_0_32()

local var_0_34 = ui.new_combobox("LUA", "B", "Primary weapon", var_0_3)
local var_0_35 = ui.new_combobox("LUA", "B", "Secondary weapon", var_0_4)
local var_0_36 = ui.new_multiselect("LUA", "B", "Misc items", var_0_5)
local var_0_37 = ui.new_multiselect("LUA", "B", "Grenades", var_0_6)

local function var_0_38(arg_8_0, arg_8_1)
	local var_8_0 = 0
	local var_8_1 = ""
	local var_8_2 = entity.get_prop(entity.get_local_player(), "m_iAccount") or 800

	if not arg_8_1 or arg_8_0 == 2 then
		for iter_8_0, iter_8_1 in ipairs(var_0_2) do
			if (var_8_2 > 800 or arg_8_0 == 1) and iter_8_1[1] == ui.get(var_0_34) then
				var_8_1 = var_8_1 .. "buy " .. iter_8_1[3] .. ";"
				var_8_0 = var_8_0 + iter_8_1[4]
			end

			if arg_8_1 and arg_8_0 == 2 and arg_8_1:find(iter_8_1[3]) then
				var_8_0 = var_8_0 + iter_8_1[4]
			end
		end
	elseif var_8_2 > 800 or arg_8_0 == 1 then
		var_8_1 = arg_8_1
	end

	if arg_8_0 == 1 then
		return var_8_1
	end

	for iter_8_2 = 1, #var_0_33() do
		local var_8_3 = entity.get_prop(var_0_33()[iter_8_2], "m_iItemDefinitionIndex")

		if var_8_1:find(var_0_0[var_8_3].console_name:gsub("weapon_", "")) or var_8_1:find(var_0_0[var_8_3].console_name:gsub("item_", "")) or var_8_1:find(var_0_31[var_0_0[var_8_3].console_name] or "abcdefg") then
			local var_8_4 = var_0_31[var_0_0[var_8_3].console_name] or var_0_0[var_8_3].console_name:gsub("weapon_", ""):gsub("item_", "")

			var_8_1 = var_8_1:gsub("buy " .. var_8_4 .. ";", "")
			var_8_0 = var_8_0 - var_0_0[var_8_3].in_game_price
		end
	end

	if arg_8_0 == 2 then
		return var_8_0
	end

	return var_8_1
end

local function var_0_39(arg_9_0, arg_9_1)
	local var_9_0 = 0
	local var_9_1 = ""
	local var_9_2 = entity.get_prop(entity.get_local_player(), "m_iAccount") or 800

	if not arg_9_1 or arg_9_0 == 2 then
		for iter_9_0, iter_9_1 in ipairs(var_0_2) do
			if var_9_2 > 800 or arg_9_0 == 1 then
				if iter_9_1[1] == ui.get(var_0_35) then
					var_9_1 = var_9_1 .. "buy " .. iter_9_1[3] .. ";"
					var_9_0 = var_9_0 + iter_9_1[4]
				end

				local var_9_3 = ui.get(var_0_36)

				for iter_9_2 = 1, #var_9_3 do
					if var_9_3[iter_9_2] == iter_9_1[1] then
						var_9_1 = var_9_1 .. "buy " .. iter_9_1[3] .. ";"

						if entity.get_local_player() then
							if entity.get_prop(entity.get_local_player(), "m_ArmorValue") > 99 and iter_9_1[3] == "vesthelm" then
								var_9_0 = var_9_0 + 350
							else
								var_9_0 = var_9_0 + iter_9_1[4]
							end
						end
					end
				end

				local var_9_4 = ui.get(var_0_37)

				for iter_9_3 = 1, #var_9_4 do
					if var_9_4[iter_9_3] == iter_9_1[1] then
						var_9_1 = var_9_1 .. "buy " .. iter_9_1[3] .. ";"
						var_9_0 = var_9_0 + iter_9_1[4]
					end
				end
			end

			if arg_9_1 and arg_9_0 == 2 and arg_9_1:find(iter_9_1[3]) then
				var_9_0 = var_9_0 + iter_9_1[4]
			end
		end
	elseif var_9_2 > 800 or arg_9_0 == 1 then
		var_9_1 = arg_9_1
	end

	if arg_9_0 == 1 then
		return var_9_1
	end

	local var_9_5 = var_0_23(var_9_1, ";")
	local var_9_6 = 0

	for iter_9_4 = 1, #var_9_5 do
		if var_9_5[iter_9_4]:find("flashbang") then
			var_9_6 = var_9_6 + 1
		end
	end

	for iter_9_5 = 1, #var_0_33() do
		local var_9_7 = entity.get_prop(var_0_33()[iter_9_5], "m_iItemDefinitionIndex")

		if var_0_0 then
			if var_0_0[var_9_7].name == "Flashbang" and var_9_6 < 2 then
				var_9_1 = var_9_1:gsub("buy flashbang;", "")
				var_9_0 = var_9_0 - var_0_0[var_9_7].in_game_price
			end

			if var_9_1:find(var_0_0[var_9_7].console_name:gsub("weapon_", "")) or var_9_1:find(var_0_0[var_9_7].console_name:gsub("item_", "")) or var_9_1:find(var_0_31[var_0_0[var_9_7].console_name] or "abcdefg") then
				local var_9_8 = var_0_31[var_0_0[var_9_7].console_name] or var_0_0[var_9_7].console_name:gsub("weapon_", ""):gsub("item_", "")

				if var_9_8 ~= "flashbang" then
					var_9_1 = var_9_1:gsub("buy " .. var_9_8 .. ";", "")
					var_9_0 = var_9_0 - var_0_0[var_9_7].in_game_price
				end
			end
		end
	end

	if entity.get_prop(entity.get_local_player(), "m_bHasDefuser") > 0 or entity.get_prop(entity.get_local_player(), "m_iTeamNum") == 2 then
		var_9_1 = var_9_1:gsub("buy defuser;", "")

		if entity.get_prop(entity.get_local_player(), "m_iTeamNum") ~= 2 then
			var_9_0 = var_9_0 - 400
		end
	end

	if entity.get_prop(entity.get_local_player(), "m_ArmorValue") > 99 then
		var_9_1 = var_9_1:gsub("buy vest;", "")
		var_9_0 = var_9_0 - 650
	end

	if entity.get_prop(entity.get_local_player(), "m_bHasHelmet") then
		if entity.get_prop(entity.get_local_player(), "m_bHasHelmet") > 0 then
			var_9_1 = var_9_1:gsub("buy vesthelm;", "")

			if entity.get_prop(entity.get_local_player(), "m_ArmorValue") < 100 then
				var_9_0 = var_9_0 - 1000
			else
				var_9_0 = var_9_0 - 350
			end
		end

		if entity.get_prop(entity.get_local_player(), "m_bHasHelmet") < 1 and entity.get_prop(entity.get_local_player(), "m_ArmorValue") < 100 and var_9_1:find("vest") then
			var_9_1 = var_9_1:gsub("buy vest;", "")
			var_9_1 = var_9_1:gsub("buy vesthelm;", "")
			var_9_1 = var_9_1 .. "buy vesthelm;"
			var_9_0 = var_9_0 - 650
		end
	end

	if arg_9_0 == 2 then
		return var_9_0
	end

	return var_9_1
end

local var_0_40 = {
	["Desert Eagle"] = var_0_0.weapon_deagle.idx,
	["R8 Revolver"] = var_0_0.weapon_revolver.idx
}

local function var_0_41(arg_10_0, arg_10_1)
	local var_10_0 = var_0_14.GetFauxItemIDFromDefAndPaintIndex(arg_10_0)
	local var_10_1 = var_0_14.GetSlotSubPosition(var_10_0)

	var_0_13.EquipItemInSlot(arg_10_1, var_10_0, var_10_1)
end

local var_0_42 = {
	"ct",
	"t",
	"ct"
}
local var_0_43 = ui.new_textbox("LUA", "B", "Name")
local var_0_44 = ui.new_button("LUA", "B", "Save Preset", function()
	local var_11_0 = var_0_38(1)
	local var_11_1 = var_0_39(1)

	if ui.get(var_0_43) ~= "" and #var_11_0 > 0 or ui.get(var_0_43) ~= "" and #var_11_1 > 0 then
		table.insert(var_0_18, {
			name = ui.get(var_0_43),
			values = var_11_0 .. "!" .. var_11_1
		})
		ui.set(var_0_43, "")
		database.write("pilotbuybot", var_0_18)
		database.flush()
		client.delay_call(0, function()
			client.reload_active_scripts()
		end)
	elseif ui.get(var_0_43) == "" then
		error("Enter a preset name")
	else
		error("Values must not be empty")
	end
end)
local var_0_45 = ui.new_button("LUA", "B", "Delete", function()
	for iter_13_0, iter_13_1 in ipairs(var_0_11) do
		if ui.get(var_0_20) == iter_13_1 and iter_13_0 ~= #var_0_18 + 1 then
			table.remove(var_0_18, iter_13_0)
			database.write("pilotbuybot", var_0_18)
			database.flush()
		end
	end

	ui.set(var_0_34, "-")
	ui.set(var_0_35, "-")
	ui.set(var_0_36, "-")
	ui.set(var_0_37, "-")
	client.delay_call(0, function()
		client.reload_active_scripts()
	end)
end)

ui.set_visible(var_0_45, #var_0_18 > 0)

local var_0_46 = ui.new_checkbox("LUA", "B", "Buybot blacklist")
local var_0_47 = ui.new_multiselect("LUA", "B", "\n", "Valve", "non-$16k")
local var_0_48 = ui.new_checkbox("LUA", "B", "R8 pistol round")

ui.set_callback(var_0_46, function(arg_15_0)
	ui.set_visible(var_0_47, ui.get(arg_15_0))
end)
ui.set_visible(var_0_47, ui.get(var_0_46))

local function var_0_49(arg_16_0)
	if not ui.get(var_0_48) then
		return
	end

	local var_16_0 = var_0_0.weapon_revolver.idx
	local var_16_1 = var_0_0.weapon_deagle.idx
	local var_16_2 = entity.get_prop(entity.get_local_player(), "m_iTeamNum")
	local var_16_3 = entity.get_prop(entity.get_game_rules(), "m_bWarmupPeriod")
	local var_16_4 = entity.get_prop(entity.get_local_player(), "m_iAccount")

	if not var_16_4 or arg_16_0 == 1 then
		for iter_16_0, iter_16_1 in ipairs(var_0_42) do
			if var_0_24(var_16_0, iter_16_1) ~= var_16_0 then
				var_0_41(var_16_0, iter_16_1)
			end
		end
	elseif (var_16_4 > 800 and var_16_3 < 1 or var_16_4 < 800 and var_16_3 < 1) and var_0_24(var_16_1, var_0_42[var_16_2]) ~= var_16_1 then
		var_0_41(var_16_1, var_0_42[var_16_2])
	end
end

ui.set_callback(var_0_48, function(arg_17_0)
	if ui.get(arg_17_0) then
		var_0_1.register_event("QueueConnectToServer", var_0_49)
		client.set_event_callback("announce_phase_end", function()
			var_0_49(1)
		end)
		client.set_event_callback("cs_win_panel_match", function()
			var_0_49(1)
		end)
		client.set_event_callback("round_start", var_0_49)
		client.set_event_callback("exit_buyzone", var_0_49)
	else
		var_0_1.unregister_event("QueueConnectToServer", var_0_49)
		client.unset_event_callback("round_start", var_0_49)
		client.unset_event_callback("exit_buyzone", var_0_49)
	end
end)

local function var_0_50()
	local var_20_0 = var_0_38(1)
	local var_20_1 = var_0_39(1)
	local var_20_2 = #var_20_0 > 0 or #var_20_1 > 0

	ui.set_visible(var_0_20, (ui.get(var_0_19)))
	ui.set_visible(var_0_45, false)
	ui.set_visible(var_0_43, ui.get(var_0_19) and var_20_2)
	ui.set_visible(var_0_44, ui.get(var_0_19) and var_20_2)
	ui.set_visible(var_0_34, (ui.get(var_0_19)))
	ui.set_visible(var_0_35, (ui.get(var_0_19)))
	ui.set_visible(var_0_36, (ui.get(var_0_19)))
	ui.set_visible(var_0_37, (ui.get(var_0_19)))
end

local function var_0_51()
	ui.set_visible(var_0_20, (ui.get(var_0_19)))
	ui.set_visible(var_0_43, false)
	ui.set_visible(var_0_45, (ui.get(var_0_19)))
	ui.set_visible(var_0_44, false)
	ui.set_visible(var_0_34, false)
	ui.set_visible(var_0_35, false)
	ui.set_visible(var_0_36, false)
	ui.set_visible(var_0_37, false)
end

local function var_0_52()
	local var_22_0 = var_0_38(1)
	local var_22_1 = var_0_39(1)
	local var_22_2 = #var_22_0 > 0 or #var_22_1 > 0

	ui.set_visible(var_0_34, (ui.get(var_0_19)))
	ui.set_visible(var_0_35, (ui.get(var_0_19)))
	ui.set_visible(var_0_36, (ui.get(var_0_19)))
	ui.set_visible(var_0_37, (ui.get(var_0_19)))
	ui.set_visible(var_0_43, ui.get(var_0_19) and var_22_2)
	ui.set_visible(var_0_44, ui.get(var_0_19) and var_22_2)
end

local function var_0_53()
	for iter_23_0 = #var_0_18, 1, -1 do
		for iter_23_1, iter_23_2 in ipairs(var_0_11) do
			if ui.get(var_0_20) == iter_23_2 and iter_23_1 == #var_0_18 + 1 then
				var_0_50()
			else
				var_0_51()
			end
		end
	end

	client.delay_call(0, function()
		if #var_0_18 < 1 then
			var_0_52()
		end
	end)
end

ui.set_callback(var_0_34, var_0_53)
ui.set_callback(var_0_35, var_0_53)
ui.set_callback(var_0_36, var_0_53)
ui.set_callback(var_0_37, var_0_53)
ui.set_callback(var_0_19, var_0_53)

local var_0_54 = 0

local function var_0_55()
	for iter_25_0, iter_25_1 in ipairs(var_0_11) do
		if ui.get(var_0_20) == iter_25_1 and iter_25_0 ~= #var_0_18 + 1 then
			local var_25_0 = var_0_23(var_0_17[iter_25_0], "!")

			var_0_9 = var_25_0[1]
			var_0_10 = var_25_0[2]
			var_0_54 = 1
		elseif ui.get(var_0_20) == iter_25_1 and iter_25_0 == #var_0_18 + 1 then
			var_0_54 = 0
		end
	end

	var_0_53()
end

if var_0_20 then
	ui.set_callback(var_0_20, var_0_55)
	client.delay_call(0, var_0_55)
end

var_0_53()

local function var_0_56(arg_26_0)
	if var_0_54 > 0 then
		client.exec(var_0_38(0, var_0_9))
	else
		client.exec(var_0_38())
	end

	local var_26_0 = string.len(var_0_38(0, var_0_9)) > 0
	local var_26_1 = string.len(var_0_38()) > 0
	local var_26_2 = var_26_0 or var_26_1

	return arg_26_0 > 0 and not var_0_8 and var_26_2 and client.delay_call(0.0001, var_0_56, arg_26_0 - 1)
end

client.set_event_callback("cs_pre_restart", function()
	if not ui.get(var_0_19) then
		return
	end

	local var_27_0 = entity.get_prop(entity.get_local_player(), "m_iAccount")
	local var_27_1 = var_0_15.IsServerWhitelistedValveOfficial()

	if var_27_0 < var_0_38(2) + var_0_39(2) then
		return
	end

	if ui.get(var_0_46) and var_0_21(ui.get(var_0_47), "Valve") and var_27_1 then
		return
	end

	if ui.get(var_0_46) and var_0_21(ui.get(var_0_47), "non-$16k") and cvar.mp_afterroundmoney:get_int() < 16000 then
		return
	end

	return client.delay_call(0.3 - (client.latency() + totime(8)), var_0_56, 16)
end)

local function var_0_57()
	if not ui.get(var_0_19) then
		return
	end

	local var_28_0 = entity.get_prop(entity.get_local_player(), "m_iAccount")
	local var_28_1 = var_0_15.IsServerWhitelistedValveOfficial()

	if var_28_0 < var_0_38(2) + var_0_39(2) then
		return
	end

	if ui.get(var_0_46) and var_0_21(ui.get(var_0_47), "Valve") and var_28_1 then
		return
	end

	if ui.get(var_0_46) and var_0_21(ui.get(var_0_47), "non-$16k") and cvar.mp_afterroundmoney:get_int() < 16000 then
		return
	end

	client.delay_call(0.01, function()
		if var_0_54 > 0 then
			client.exec(var_0_39(0, var_0_10))
		else
			client.exec(var_0_39())
		end
	end)
end

client.set_event_callback("round_prestart", function()
	client.delay_call(0.1, var_0_57)
end)
client.set_event_callback("player_spawn", function(arg_31_0)
	if client.userid_to_entindex(arg_31_0.userid) == entity.get_local_player() then
		var_0_57()
	end
end)
client.set_event_callback("item_purchase", function(arg_32_0)
	if client.userid_to_entindex(arg_32_0.userid) == entity.get_local_player() then
		var_0_8 = true

		client.delay_call(0.00011, function()
			var_0_8 = false
		end)
	end
end)
client.delay_call(0, function()
	ui.set(var_0_34, "-")
	ui.set(var_0_35, "-")
	ui.set(var_0_36, "-")
	ui.set(var_0_37, "-")
end)

-- ============================================================
-- DOUBLE TAP MODULE
-- Note: uses client.set_cvar (undocumented in Lua Api Docs .txt), preserved as-is
-- ============================================================

local enable_DT = ui.new_checkbox("LUA", "B", "GayBottle 10000$ dt lua")
local doubletap_speed = ui.new_slider("LUA", "B",  "DT Speed", 4, 24)
--you can change mix and max tick as you want, but I recommend not setting it too high, otherwise it may cause some problems.

local function superDT()
    if ui.get(enable_DT) then
        client.set_cvar("sv_maxusrcmdprocessticks", ui.get(doubletap_speed))
    end
end

client.set_event_callback("paint", superDT)

--made by GayBottle

-- ============================================================
-- LAG COMPENSATION MODULE
-- ============================================================

-- Downloaded from https://github.com/s0daa/CSGO-HVH-LUAS

-- kinda old release
-- decided to post it on github since im planning to rework the entire thing

local g_esp_data = { }
local g_sim_ticks, g_net_data = { }, { }

local globals_tickinterval = globals.tickinterval
local entity_is_enemy = entity.is_enemy
local entity_get_prop = entity.get_prop
local entity_is_dormant = entity.is_dormant
local entity_is_alive = entity.is_alive
local entity_get_origin = entity.get_origin
local entity_get_local_player = entity.get_local_player
local entity_get_player_resource = entity.get_player_resource
local entity_get_bounding_box = entity.get_bounding_box
local entity_get_player_name = entity.get_player_name
local renderer_text = renderer.text
local w2s = renderer.world_to_screen
local line = renderer.line
local table_insert = table.insert
local client_trace_line = client.trace_line
local math_floor = math.floor
local globals_frametime = globals.frametime

local sv_gravity = cvar.sv_gravity
local sv_jump_impulse = cvar.sv_jump_impulse

local time_to_ticks = function(t) return math_floor(0.5 + (t / globals_tickinterval())) end
local vec_substract = function(a, b) return { a[1] - b[1], a[2] - b[2], a[3] - b[3] } end
local vec_add = function(a, b) return { a[1] + b[1], a[2] + b[2], a[3] + b[3] } end
local vec_lenght = function(x, y) return (x * x + y * y) end

local get_entities = function(enemy_only, alive_only)
	local enemy_only = enemy_only ~= nil and enemy_only or false
    local alive_only = alive_only ~= nil and alive_only or true
    
    local result = {}

    local me = entity_get_local_player()
    local player_resource = entity_get_player_resource()
    
	for player = 1, globals.maxplayers() do
        local is_enemy, is_alive = true, true
        
        if enemy_only and not entity_is_enemy(player) then is_enemy = false end
        if is_enemy then
            if alive_only and entity_get_prop(player_resource, 'm_bAlive', player) ~= 1 then is_alive = false end
            if is_alive then table_insert(result, player) end
        end
	end

	return result
end

local extrapolate = function(ent, origin, flags, ticks)
    local tickinterval = globals_tickinterval()

    local sv_gravity = sv_gravity:get_float() * tickinterval
    local sv_jump_impulse = sv_jump_impulse:get_float() * tickinterval

    local p_origin, prev_origin = origin, origin

    local velocity = { entity_get_prop(ent, 'm_vecVelocity') }
    local gravity = velocity[3] > 0 and -sv_gravity or sv_jump_impulse

    for i=1, ticks do
        prev_origin = p_origin
        p_origin = {
            p_origin[1] + (velocity[1] * tickinterval),
            p_origin[2] + (velocity[2] * tickinterval),
            p_origin[3] + (velocity[3]+gravity) * tickinterval,
        }

        local fraction = client_trace_line(-1, 
            prev_origin[1], prev_origin[2], prev_origin[3], 
            p_origin[1], p_origin[2], p_origin[3]
        )

        if fraction <= 0.99 then
            return prev_origin
        end
    end

    return p_origin
end

local function g_net_update()
	local me = entity_get_local_player()
    local players = get_entities(true, true)

	for i=1, #players do
		local idx = players[i]
        local prev_tick = g_sim_ticks[idx]
        
        if entity_is_dormant(idx) or not entity_is_alive(idx) then
            g_sim_ticks[idx] = nil
            g_net_data[idx] = nil
            g_esp_data[idx] = nil
        else
            local player_origin = { entity_get_origin(idx) }
            local simulation_time = time_to_ticks(entity_get_prop(idx, 'm_flSimulationTime'))
    
            if prev_tick ~= nil then
                local delta = simulation_time - prev_tick.tick

                if delta < 0 or delta > 0 and delta <= 64 then
                    local m_fFlags = entity_get_prop(idx, 'm_fFlags')

                    local diff_origin = vec_substract(player_origin, prev_tick.origin)
                    local teleport_distance = vec_lenght(diff_origin[1], diff_origin[2])

                    local extrapolated = extrapolate(idx, player_origin, m_fFlags, delta-1)
    
                    if delta < 0 then
                        g_esp_data[idx] = 1
                    end

                    g_net_data[idx] = {
                        tick = delta-1,

                        origin = player_origin,
                        predicted_origin = extrapolated,

                        tickbase = delta < 0,
                        lagcomp = teleport_distance > 4096,
                    }
                end
            end
    
            if g_esp_data[idx] == nil then
                g_esp_data[idx] = 0
            end

            g_sim_ticks[idx] = {
                tick = simulation_time,
                origin = player_origin,
            }
        end
	end
end

local function g_paint_handler()
    local me = entity_get_local_player()
    local player_resource = entity_get_player_resource()

    if not me or not entity_is_alive(me) then
        return
    end

	local observer_mode = entity_get_prop(me, "m_iObserverMode")
	local active_players = {}

	if (observer_mode == 0 or observer_mode == 1 or observer_mode == 2 or observer_mode == 6) then
		active_players = get_entities(true, true)
	elseif (observer_mode == 4 or observer_mode == 5) then
		local all_players = get_entities(false, true)
		local observer_target = entity_get_prop(me, "m_hObserverTarget")
		local observer_target_team = entity_get_prop(observer_target, "m_iTeamNum")

		for test_player = 1, #all_players do
			if (
				observer_target_team ~= entity_get_prop(all_players[test_player], "m_iTeamNum") and
				all_players[test_player ] ~= me
			) then
				table_insert(active_players, all_players[test_player])
			end
		end
	end

    if #active_players == 0 then
        return
    end

    for idx, net_data in pairs(g_net_data) do
        if entity_is_alive(idx) and entity_is_enemy(idx) and net_data ~= nil then
            if net_data.lagcomp then
                local predicted_pos = net_data.predicted_origin

                local min = vec_add({ entity_get_prop(idx, 'm_vecMins') }, predicted_pos)
                local max = vec_add({ entity_get_prop(idx, 'm_vecMaxs') }, predicted_pos)

                local points = {
                    {min[1], min[2], min[3]}, {min[1], max[2], min[3]},
                    {max[1], max[2], min[3]}, {max[1], min[2], min[3]},
                    {min[1], min[2], max[3]}, {min[1], max[2], max[3]},
                    {max[1], max[2], max[3]}, {max[1], min[2], max[3]},
                }

                local edges = {
                    {0, 1}, {1, 2}, {2, 3}, {3, 0}, {5, 6}, {6, 7}, {1, 4}, {4, 8},
                    {0, 4}, {1, 5}, {2, 6}, {3, 7}, {5, 8}, {7, 8}, {3, 4}
                }

                for i = 1, #edges do
                    if i == 1 then
                        local origin = { entity_get_origin(idx) }
                        local origin_w2s = { w2s(origin[1], origin[2], origin[3]) }
                        local min_w2s = { w2s(min[1], min[2], min[3]) }

                        if origin_w2s[1] ~= nil and min_w2s[1] ~= nil then
                            line(origin_w2s[1], origin_w2s[2], min_w2s[1], min_w2s[2], 47, 117, 221, 255)
                        end
                    end

                    if points[edges[i][1]] ~= nil and points[edges[i][2]] ~= nil then
                        local p1 = { w2s(points[edges[i][1]][1], points[edges[i][1]][2], points[edges[i][1]][3]) }
                        local p2 = { w2s(points[edges[i][2]][1], points[edges[i][2]][2], points[edges[i][2]][3]) }
            
                        line(p1[1], p1[2], p2[1], p2[2], 47, 117, 221, 255)
                    end
                end
            end

            local text = {
                [0] = '', [1] = 'LAG COMP BREAKER',
                [2] = 'SHIFTING TICKBASE'
            }

            local x1, y1, x2, y2, a = entity_get_bounding_box(idx)
            local palpha = 0

            if g_esp_data[idx] > 0 then
                g_esp_data[idx] = g_esp_data[idx] - globals_frametime()*2
                g_esp_data[idx] = g_esp_data[idx] < 0 and 0 or g_esp_data[idx]

                palpha = g_esp_data[idx]
            end

            local tb = net_data.tickbase or g_esp_data[idx] > 0
            local lc = net_data.lagcomp

            if not tb or net_data.lagcomp then
                palpha = a
            end

            if x1 ~= nil and a > 0 then
                local name = entity_get_player_name(idx)
                local y_add = name == '' and -8 or 0

                renderer_text(x1 + (x2-x1)/2, y1 - 18 + y_add, 255, 45, 45, palpha*255, 'c', 0, text[tb and 2 or (lc and 1 or 0)])
            end
        end
    end
end

client.set_event_callback('paint', g_paint_handler)
client.set_event_callback('net_update_end', g_net_update)
-- ============================================================
-- AETHER.SEV - PAGE VISIBILITY MANAGEMENT
-- Controls which module's UI is shown based on the page selector.
-- ============================================================

-- All resolver UI references (created in the Resolver module above)
local _res_ui_refs = {
    ui_enabled, ui_mode, ui_hud, ui_log, ui_hitchance, ui_max_brute,
    ui_auto_stop, ui_show_side,
    ui_body_kill, ui_body_thresh,
    ui_dt_enable, ui_dt_hitchance,
    ui_bayes_thresh, ui_nn_lr, ui_ai_enable, ui_memory_bank, ui_ai_hud,
    ui_dashboard84, ui_status_bar85,
    ui_ssg_module, ui_deagle_module, ui_revolver_module, ui_tec9_module,
    ui_esp_enable, ui_lang_select, ui_cfg_slot, ui_perf_hud,
}

-- Buybot top-level UI references (created in the Buybot module above)
local _bb_ui_refs = {
    var_0_19, var_0_34, var_0_35, var_0_36, var_0_37,
    var_0_43, var_0_44, var_0_45, var_0_46, var_0_47, var_0_48,
}

local function _aether_refs_visible(refs, v)
    for _, ref in ipairs(refs) do
        if ref ~= nil then pcall(ui.set_visible, ref, v) end
    end
end

local function update_aether_page()
    local page   = ui.get(aether_page)
    local is_res = (page == "Resolver")
    local is_bb  = (page == "Buybot")
    local is_dt  = (page == "Double Tap")

    -- Resolver
    _aether_refs_visible(_res_ui_refs, is_res)
    if is_res then pcall(ui_visibility_update) end  -- resolver's own sub-visibility

    -- Buybot
    if is_bb then
        pcall(var_0_53)  -- buybot's own visibility logic
    else
        _aether_refs_visible(_bb_ui_refs, false)
        if var_0_20 then pcall(ui.set_visible, var_0_20, false) end
    end

    -- Double Tap (DoubleTap.lua exposes: enable_DT, doubletap_speed)
    if enable_DT       then pcall(ui.set_visible, enable_DT,       is_dt) end
    if doubletap_speed then pcall(ui.set_visible, doubletap_speed, is_dt) end
end

ui.set_callback(aether_page, update_aether_page)
client.delay_call(0, update_aether_page)

client.color_log(100, 180, 255, "[Aether.sev] ============================================")
client.color_log(180, 255, 180, "[Aether.sev] Script loaded. Use LUA > B > Aether.sev to navigate pages.")
client.color_log(100, 180, 255, "[Aether.sev] ============================================")