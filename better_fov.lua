local GAME_NAME = reframework:get_game_name()

if GAME_NAME ~= "re9" then
    return
end

local CFG_PATH = "better_fov.json"
local DEBUG_LOG_PATH = "better_fov_debug_log.json"

local cfg = {
    enabled = true,
    exploration_fov = 81.0,
    aiming_fov = 74.0,
    sprinting_fov = 88.0,
    cutscene_fov = 75.0,
    normal_fov_during_cutscene = true,
    smooth_fov_transitions = true,
    fov_transition_speed = 18.0,
    fov_return_speed = 11.0,

    use_crouch_fov = false,
    crouch_fov = 78.0,

    use_reload_fov = false,
    reload_fov = 72.0,

    use_melee_fov = false,
    melee_fov = 82.0,

    debug_ui = false,
}

local state = {
    active_tasks = {},
    active_task_count = 0,

    in_cutscene = false,
    camera_non_controllable = false,
    has_vehicle = false,
    last_non_controllable_time = -1000.0,
    cutscene_hold_seconds = 1.0,

    is_aiming = false,
    is_sprinting = false,
    last_sprinting_true_time = -1000.0,
    sprint_candidate_frames = 0,
    last_sprint_speed_time = -1000.0,
    sprint_flag = false,
    sprint_key_down = false,
    prev_sprint_key_down = false,
    sprint_key_down_start_time = -1000.0,
    sprint_user_latched = false,
    walk_like_start_time = -1000.0,
    stop_like_start_time = -1000.0,
    move_input_down = false,
    sprint_intent = false,
    sprint_speed_trigger = false,
    last_sprint_keep_time = -1000.0,

    last_player_context_seen_time = -1000.0,
    context_missing_cutscene_seconds = 0.65,
    last_player_camera_update_time = -1000.0,

    last_cutscene_true_time = -1000.0,
    cutscene_release_seconds = 1.0,

    skip_fov_override = false,

    has_prev_pos = false,
    prev_pos_x = 0.0,
    prev_pos_y = 0.0,
    prev_pos_z = 0.0,
    prev_pos_time = -1000.0,
    move_speed = 0.0,
    smoothed_move_speed = 0.0,

    last_no_playercam_control_time = -1000.0,

    last_event_task_time = -1000.0,

    debug_log_entries = {},
    last_debug_log_time = -1000.0,
    last_debug_heartbeat_time = -1000.0,
    last_debug_log_dump_time = -1000.0,
    last_logged_mode = "",
    last_logged_sprinting = false,
    last_logged_cutscene = false,
    last_logged_skip = false,

    blended_fov = nil,
    last_fov_apply_time = -1000.0,
}

local script_start_time = os.clock()

local camera_t = sdk.find_type_definition("via.Camera")
local camera_get_fov = camera_t and camera_t:get_method("get_FOV") or nil
local camera_set_fov = camera_t and camera_t:get_method("set_FOV") or nil

local last_player_camera_update_args = nil

local function safe_get_field(obj, field_name)
    if obj == nil then
        return nil
    end

    local ok, result = pcall(function()
        return obj:get_field(field_name)
    end)

    if not ok then
        return nil
    end

    return result
end

local function safe_call(obj, method_name, ...)
    if obj == nil then
        return nil
    end

    local args = { ... }

    local ok, result = pcall(function()
        return obj:call(method_name, table.unpack(args))
    end)

    if not ok then
        return nil
    end

    return result
end

local function safe_get_member(obj, name)
    if obj == nil or name == nil then
        return nil
    end

    local v = safe_get_field(obj, name)
    if v ~= nil then
        return v
    end

    v = safe_get_field(obj, "_" .. name)
    if v ~= nil then
        return v
    end

    v = safe_get_field(obj, "<" .. name .. ">k__BackingField")
    if v ~= nil then
        return v
    end

    v = safe_call(obj, "get_" .. name)
    if v ~= nil then
        return v
    end

    v = safe_call(obj, "get" .. name)
    if v ~= nil then
        return v
    end

    return nil
end

local function safe_get_bool_member(obj, name)
    local v = safe_get_member(obj, name)

    if type(v) == "boolean" then
        return v
    end

    if type(v) == "number" then
        return v ~= 0
    end

    return false
end

local function safe_set_member(obj, name, value)
    if obj == nil or name == nil then
        return
    end

    local td = obj:get_type_definition()
    if td == nil then
        return
    end

    local field_names = {
        name,
        "_" .. name,
        "<" .. name .. ">k__BackingField",
    }

    for _, f in ipairs(field_names) do
        local field = td:get_field(f)
        if field ~= nil then
            pcall(function()
                obj:set_field(f, value)
            end)
        end
    end

    local method_names = {
        "set_" .. name,
        "set" .. name,
    }

    for _, m in ipairs(method_names) do
        local method = td:get_method(m)
        if method ~= nil then
            pcall(function()
                obj:call(m, value)
            end)
        end
    end
end

local function to_bool(v)
    return v == true
end

local function clamp(v, min_v, max_v)
    if v < min_v then
        return min_v
    end

    if v > max_v then
        return max_v
    end

    return v
end

local function smooth_towards(current_value, target_value, speed, dt)
    if current_value == nil then
        return target_value
    end

    if speed == nil or speed <= 0.0 then
        return target_value
    end

    local alpha = 1.0 - math.exp(-speed * dt)
    return current_value + ((target_value - current_value) * alpha)
end

local function load_cfg()
    local loaded_cfg = json.load_file(CFG_PATH)

    if loaded_cfg == nil then
        json.dump_file(CFG_PATH, cfg)
        return
    end

    for k, v in pairs(loaded_cfg) do
        cfg[k] = v
    end
end

load_cfg()
log.info("[Better FOV] Loaded for RE9")
json.dump_file(DEBUG_LOG_PATH, {
    updated_at_seconds = os.clock(),
    entry_count = 0,
    entries = {},
})

re.on_config_save(function()
    json.dump_file(CFG_PATH, cfg)
end)

local function get_ptr_key(arg)
    if arg == nil then
        return nil
    end

    local ptr = sdk.to_ptr(arg)
    if ptr == nil then
        return nil
    end

    return tostring(sdk.to_int64(ptr))
end

local function set_task_active(task_key, active)
    if task_key == nil then
        return
    end

    local was_active = state.active_tasks[task_key] == true

    if active and not was_active then
        state.active_tasks[task_key] = true
        state.active_task_count = state.active_task_count + 1
        state.last_event_task_time = os.clock()
    elseif not active and was_active then
        state.active_tasks[task_key] = nil
        state.active_task_count = state.active_task_count - 1
        if state.active_task_count < 0 then
            state.active_task_count = 0
        end
    end
end

local function string_contains_any(haystack, needles)
    if haystack == nil then
        return false
    end

    local s = string.lower(tostring(haystack))
    for _, n in ipairs(needles) do
        if string.find(s, n, 1, true) then
            return true
        end
    end

    return false
end

local function dump_debug_log(force)
    local now = os.clock()
    if not force and (now - state.last_debug_log_dump_time) < 1.5 then
        return
    end

    state.last_debug_log_dump_time = now

    local payload = {
        updated_at_seconds = now,
        entry_count = #state.debug_log_entries,
        entries = state.debug_log_entries,
    }

    json.dump_file(DEBUG_LOG_PATH, payload)
end

local function append_debug_log(reason)
    local now = os.clock()

    local entry = {
        t = now,
        reason = reason,
        mode = state.selected_mode,
        selected_fov = state.selected_fov,
        applied_fov = state.last_applied_fov,
        baseline_fov = state.baseline_fov,
        cutscene = state.in_cutscene,
        skip_override = state.skip_fov_override,
        player_context_ok = state.player_context_available,
        move_speed = state.move_speed,
        smoothed_speed = state.smoothed_move_speed,
        sprint_flag = state.sprint_flag,
        sprint_key_down = state.sprint_key_down,
        move_input_down = state.move_input_down,
        sprint_intent = state.sprint_intent,
        sprint_speed_trigger = state.sprint_speed_trigger,
        sprint_candidate_frames = state.sprint_candidate_frames,
        sprint_last_speed_ago = now - state.last_sprint_speed_time,
        sprinting = state.is_sprinting,
        aiming = state.is_aiming,
        event_tasks = state.active_task_count,
        event_current_task = state.current_task_exists,
        motion_play = state.game_event_motion_play,
        camera_non_controllable = state.camera_non_controllable,
        controller = state.current_controller_name,
        camera_name = state.primary_camera_name,
        cam_name_cutscene = state.camera_name_looks_like_cutscene,
        player_ctx_seen_ago = now - state.last_player_context_seen_time,
        camera_update_seen_ago = now - state.last_player_camera_update_time,
    }

    table.insert(state.debug_log_entries, entry)

    if #state.debug_log_entries > 300 then
        table.remove(state.debug_log_entries, 1)
    end

    dump_debug_log(reason ~= "heartbeat")
end

do
    local event_action_controller_t = sdk.find_type_definition("app.EventActionController")

    if event_action_controller_t ~= nil then
        local request_task_method = event_action_controller_t:get_method("requestTask")

        if request_task_method ~= nil then
            sdk.hook(request_task_method,
                function(args)
                    set_task_active(get_ptr_key(args[3]), true)
                end,
                function(retval)
                    return retval
                end
            )
        end
    end
end

do
    local event_action_task_t = sdk.find_type_definition("app.EventActionTask")

    if event_action_task_t ~= nil then
        local terminate_method = event_action_task_t:get_method("terminate")

        if terminate_method ~= nil then
            sdk.hook(terminate_method,
                function(args)
                    set_task_active(get_ptr_key(args[2]), false)
                end,
                function(retval)
                    return retval
                end
            )
        end
    end
end

local function get_solver_current_type_value(base_transform_solver)
    if base_transform_solver == nil then
        return nil
    end

    local current_type = safe_get_member(base_transform_solver, "currentType")
    if current_type == nil then
        current_type = safe_get_member(base_transform_solver, "CurrentType")
    end

    if current_type == nil then
        return nil
    end

    if type(current_type) == "number" then
        return current_type
    end

    local boxed_value = safe_get_member(current_type, "Value")
    if boxed_value ~= nil then
        return boxed_value
    end

    return nil
end

local function on_pre_player_camera_update(args)
    last_player_camera_update_args = args
end

local function on_post_player_camera_update(retval)
    local args = last_player_camera_update_args
    if args == nil then
        return retval
    end

    local player_camera = sdk.to_managed_object(args[2])
    if player_camera == nil then
        return retval
    end

    state.player_camera_ref = player_camera
    state.last_player_camera_update_time = os.clock()

    local has_vehicle = safe_get_member(player_camera, "RideVehicleObject") ~= nil
    state.has_vehicle = has_vehicle

    local base_transform_solver = safe_get_member(player_camera, "BaseTransSolver")
    local current_type_value = get_solver_current_type_value(base_transform_solver)
    local non_controllable = current_type_value ~= nil and current_type_value ~= 0 and not has_vehicle

    local camera_controller = safe_get_member(base_transform_solver, "CurrentController")
    state.current_controller_name = ""

    if camera_controller ~= nil then
        local td = camera_controller:get_type_definition()
        if td ~= nil then
            local name = td:get_full_name()
            if name ~= nil then
                state.current_controller_name = tostring(name)
                local lname = string.lower(state.current_controller_name)

                if string.find(lname, "event", 1, true)
                    or string.find(lname, "demo", 1, true)
                    or string.find(lname, "cinema", 1, true)
                    or string.find(lname, "cut", 1, true)
                then
                    non_controllable = true
                end

                if string.find(lname, "aim", 1, true)
                    or string.find(lname, "scope", 1, true)
                    or string.find(lname, "shoot", 1, true)
                then
                    state.last_hint_aiming_time = os.clock()
                end

                if string.find(lname, "sprint", 1, true)
                    or string.find(lname, "run", 1, true)
                    or string.find(lname, "dash", 1, true)
                then
                    state.last_hint_sprinting_time = os.clock()
                end
            end
        end
    end

    if non_controllable then
        state.last_non_controllable_time = os.clock()
    end

    if has_vehicle then
        state.camera_non_controllable = false
    else
        state.camera_non_controllable = non_controllable or ((os.clock() - state.last_non_controllable_time) <= state.cutscene_hold_seconds)
    end

    return retval
end

local function try_hook_camera_type(type_name)
    local t = sdk.find_type_definition(type_name)
    if t == nil then
        return false
    end

    local method = t:get_method("lateUpdate")
    if method == nil then
        method = t:get_method("doLateUpdate")
    end

    if method == nil then
        return false
    end

    sdk.hook(method, on_pre_player_camera_update, on_post_player_camera_update)
    return true
end

try_hook_camera_type("app.PlayerCamera")
try_hook_camera_type("app.CH8PlayerCamera")
try_hook_camera_type("app.CH9PlayerCamera")

local SPRINT_ENTER_SPEED_RAW = 2.20
local SPRINT_ENTER_FROM_KEY_SPEED = 1.95
local SPRINT_ENTER_FROM_FLAG_SPEED = 1.90
local SPRINT_KEEP_SPEED_RAW = 2.00
local SPRINT_WALL_KEEP_SECONDS = 3.00
local SPRINT_EXIT_DELAY = 0.03
local SPRINT_TAP_MAX_SECONDS = 0.22
local SPRINT_WALK_MIN_SPEED = 1.35
local SPRINT_WALK_MAX_SPEED = 2.02
local SPRINT_WALK_CANCEL_DELAY = 0.10
local SPRINT_STOP_CANCEL_DELAY = 0.12

local function refresh_player_state()
    local now = os.clock()

    local prev_sprinting = state.is_sprinting
    local next_aiming = false
    local next_sprinting = false
    local next_reloading = false
    local next_crouching = false
    local next_melee = false
    
    local character_manager = sdk.get_managed_singleton("app.CharacterManager")
    if character_manager == nil then
        state.player_context_available = false
        return
    end

    local player_context = safe_call(character_manager, "getPlayerContextRefFast")
    if player_context == nil then
        player_context = safe_call(character_manager, "getPlayerContextRef")
    end
    if player_context == nil then
        state.player_context_available = false
        state.is_aiming = false
        state.is_sprinting = false
        state.is_reloading = false
        state.is_crouching = false
        state.is_melee = false
        state.sprint_flag = false
        state.sprint_key_down = false
        state.prev_sprint_key_down = false
        state.sprint_key_down_start_time = -1000.0
        state.sprint_intent = false
        state.sprint_speed_trigger = false
        state.sprint_candidate_frames = 0
        state.last_sprint_keep_time = -1000.0
        state.walk_like_start_time = -1000.0
        state.stop_like_start_time = -1000.0
        state.move_input_down = false
        return
    end
    
    state.player_context_available = true
    state.last_player_context_seen_time = now

    local pos = safe_get_member(player_context, "PositionFast")
    if pos ~= nil and type(pos.x) == "number" and type(pos.y) == "number" and type(pos.z) == "number" then
        if state.has_prev_pos and state.prev_pos_time > 0.0 then
            local dt = now - state.prev_pos_time
            if dt > 0.0001 then
                local dx = pos.x - state.prev_pos_x
                local dy = pos.y - state.prev_pos_y
                local dz = pos.z - state.prev_pos_z
                local dist = math.sqrt((dx * dx) + (dy * dy) + (dz * dz))
                state.move_speed = dist / dt
                state.smoothed_move_speed = (state.smoothed_move_speed * 0.70) + (state.move_speed * 0.30)
            end
        end

        state.has_prev_pos = true
        state.prev_pos_x = pos.x
        state.prev_pos_y = pos.y
        state.prev_pos_z = pos.z
        state.prev_pos_time = now
    end

    local common = safe_get_member(player_context, "Common")
    if common == nil then
        state.is_aiming = false
        state.is_sprinting = false
        state.is_reloading = false
        state.is_crouching = false
        state.is_melee = false
        state.sprint_flag = false
        state.sprint_key_down = false
        state.prev_sprint_key_down = false
        state.sprint_key_down_start_time = -1000.0
        state.sprint_intent = false
        state.sprint_speed_trigger = false
        state.sprint_candidate_frames = 0
        state.last_sprint_keep_time = -1000.0
        state.walk_like_start_time = -1000.0
        state.stop_like_start_time = -1000.0
        state.move_input_down = false
        return
    end

    local is_aiming_raw = safe_get_bool_member(common, "IsAiming")
        or safe_get_bool_member(common, "IsAim")
        or safe_get_bool_member(common, "IsHolding")
        or safe_get_bool_member(common, "IsShooting")
    next_aiming = is_aiming_raw

    local sprint_flag = safe_get_bool_member(common, "IsDash")
        or safe_get_bool_member(common, "IsMoveDash")
        or safe_get_bool_member(common, "IsRunFast")

    local sprint_key_down = reframework:is_key_down(0x10)
        or reframework:is_key_down(0xA0)
        or reframework:is_key_down(0xA1)

    local move_input_down = reframework:is_key_down(0x57)
        or reframework:is_key_down(0x41)
        or reframework:is_key_down(0x53)
        or reframework:is_key_down(0x44)
        or reframework:is_key_down(0x26)
        or reframework:is_key_down(0x28)
        or reframework:is_key_down(0x25)
        or reframework:is_key_down(0x27)
    state.move_input_down = move_input_down

    local sprint_key_pressed = sprint_key_down and (not state.prev_sprint_key_down)
    local sprint_key_released = (not sprint_key_down) and state.prev_sprint_key_down

    if sprint_key_pressed then
        state.sprint_key_down_start_time = now
    end

    if sprint_key_released then
        local held_for = now - state.sprint_key_down_start_time

        if held_for <= SPRINT_TAP_MAX_SECONDS then
            state.sprint_user_latched = true
        else
            state.sprint_user_latched = false
        end
    end

    state.prev_sprint_key_down = sprint_key_down

    local sprint_intent = sprint_flag or state.sprint_user_latched or sprint_key_down

    state.sprint_flag = sprint_flag
    state.sprint_key_down = sprint_key_down
    state.sprint_intent = sprint_intent

    if next_aiming then
        state.sprint_candidate_frames = 0
        state.sprint_speed_trigger = false
        state.sprint_user_latched = false
        state.sprint_key_down_start_time = -1000.0
        state.last_sprint_keep_time = -1000.0
        state.walk_like_start_time = -1000.0
        state.stop_like_start_time = -1000.0
        state.move_input_down = false
        next_sprinting = false
    else
        local sprint_enter_trigger = sprint_intent and (
            state.move_speed >= SPRINT_ENTER_SPEED_RAW
            or (sprint_key_pressed and state.move_speed >= SPRINT_ENTER_FROM_KEY_SPEED)
            or (sprint_flag and state.move_speed >= SPRINT_ENTER_FROM_FLAG_SPEED)
        )
        state.sprint_speed_trigger = sprint_enter_trigger

        if sprint_enter_trigger then
            state.last_sprint_speed_time = now
            state.sprint_candidate_frames = math.min(state.sprint_candidate_frames + 1, 3)
        else
            state.sprint_candidate_frames = 0
        end

        local is_walk_like = state.move_speed >= SPRINT_WALK_MIN_SPEED and state.move_speed <= SPRINT_WALK_MAX_SPEED

        if is_walk_like then
            if state.walk_like_start_time <= 0.0 then
                state.walk_like_start_time = now
            end
        else
            state.walk_like_start_time = -1000.0
        end

        local keep_from_speed = sprint_intent and (state.move_speed >= SPRINT_KEEP_SPEED_RAW)
        if keep_from_speed then
            state.last_sprint_keep_time = now
            state.last_sprinting_true_time = now
        end

        local keep_from_wall = sprint_intent and prev_sprinting and ((now - state.last_sprint_keep_time) <= SPRINT_WALL_KEEP_SECONDS)

        if not prev_sprinting then
            if state.sprint_candidate_frames >= 2 then
                next_sprinting = true
                state.last_sprinting_true_time = now
            else
                next_sprinting = false
            end
        else
            next_sprinting = (keep_from_speed or keep_from_wall)
                or ((now - state.last_sprinting_true_time) <= SPRINT_EXIT_DELAY)

            if state.sprint_user_latched then
                if (not move_input_down) and (not sprint_key_down) then
                    state.sprint_user_latched = false
                    state.last_sprint_keep_time = -1000.0
                    if not sprint_flag then
                        next_sprinting = false
                    end
                end

                local walk_too_long = state.walk_like_start_time > 0.0 and ((now - state.walk_like_start_time) >= SPRINT_WALK_CANCEL_DELAY)
                local is_stop_like = (not move_input_down) and (state.move_speed <= SPRINT_WALK_MIN_SPEED)

                if is_stop_like then
                    if state.stop_like_start_time <= 0.0 then
                        state.stop_like_start_time = now
                    end
                else
                    state.stop_like_start_time = -1000.0
                end

                local stop_too_long = state.stop_like_start_time > 0.0 and ((now - state.stop_like_start_time) >= SPRINT_STOP_CANCEL_DELAY)

                if walk_too_long or stop_too_long then
                    state.sprint_user_latched = false
                    state.last_sprint_keep_time = -1000.0
                    if not sprint_flag and not sprint_key_down then
                        next_sprinting = false
                    end
                end
            end
        end
    end

    next_reloading = safe_get_bool_member(common, "IsReloading")
    next_crouching = safe_get_bool_member(common, "IsCrouch")
    next_melee = safe_get_bool_member(common, "IsMeleeAttack")

    state.is_aiming = next_aiming
    state.is_sprinting = next_sprinting
    state.is_reloading = next_reloading
    state.is_crouching = next_crouching
    state.is_melee = next_melee
end

local function refresh_camera_context()
    state.primary_camera_name = ""
    state.camera_name_looks_like_cutscene = false

    local camera = sdk.get_primary_camera()
    if camera == nil then
        return
    end

    local go = safe_call(camera, "get_GameObject")
    local name = nil

    if go ~= nil then
        name = safe_call(go, "get_Name")
    end

    if name ~= nil then
        state.primary_camera_name = tostring(name)
        state.camera_name_looks_like_cutscene = string_contains_any(state.primary_camera_name, {
            "cut",
            "cinema",
            "event",
            "demo",
            "movie",
            "sequence",
        })
    end

    state.game_event_motion_play = false
    state.current_task_exists = false

    local game_event_action_controller = sdk.get_managed_singleton("app.GameEventActionController")
    if game_event_action_controller ~= nil then
        state.game_event_motion_play = safe_get_bool_member(game_event_action_controller, "isMotionPlay")
            or safe_get_bool_member(game_event_action_controller, "IsMotionPlay")
            or safe_get_bool_member(game_event_action_controller, "_isMotionPlay")
    end

    local event_action_controller = sdk.get_managed_singleton("app.EventActionController")
    if event_action_controller ~= nil then
        local current_task = safe_get_member(event_action_controller, "CurrentTask")
        if current_task == nil then
            current_task = safe_get_member(event_action_controller, "currentTask")
        end

        state.current_task_exists = current_task ~= nil
    end
end

local function read_current_fov(camera)
    if camera == nil then
        return nil
    end

    local current_fov = nil

    if camera_get_fov ~= nil then
        pcall(function()
            current_fov = camera_get_fov:call(sdk.get_thread_context(), camera)
        end)
    end

    if current_fov == nil then
        pcall(function()
            current_fov = camera:call("get_FOV")
        end)
    end

    if current_fov == nil then
        current_fov = safe_get_member(camera, "FOV")
    end

    if current_fov == nil and state.player_camera_ref ~= nil then
        current_fov = safe_get_member(state.player_camera_ref, "FOV")
        if current_fov == nil then
            current_fov = safe_get_member(state.player_camera_ref, "CameraFOV")
        end
    end

    if current_fov == nil then
        return nil
    end

    if type(current_fov) ~= "number" then
        return nil
    end

    if current_fov ~= current_fov or current_fov <= 1.0 or current_fov > 179.0 then
        return nil
    end

    return current_fov
end

local function choose_target_fov()
    local now = os.clock()
    local recent_event = (now - state.last_event_task_time) <= 1.2
    local context_missing_long = state.last_player_context_seen_time > 0.0
        and not state.player_context_available
        and ((now - state.last_player_context_seen_time) >= state.context_missing_cutscene_seconds)
    local context_never_seen_yet = state.last_player_context_seen_time <= 0.0
        and ((now - script_start_time) >= 4.0)
    local camera_update_stale = state.last_player_camera_update_time > 0.0
        and ((now - state.last_player_camera_update_time) >= 0.9)
    local camera_never_updated_yet = state.last_player_camera_update_time <= 0.0
        and ((now - script_start_time) >= 4.0)
    local no_player_control_signals = (not state.player_context_available)
        and (camera_update_stale or camera_never_updated_yet)
    local playercam_not_updating_while_passive = state.player_context_available
        and camera_update_stale
        and state.move_speed <= 0.12
        and (not state.is_aiming)
        and (not state.is_sprinting)
        and (not state.is_reloading)
        and (not state.is_melee)

    if playercam_not_updating_while_passive then
        if state.last_no_playercam_control_time <= 0.0 then
            state.last_no_playercam_control_time = now
        end
    else
        state.last_no_playercam_control_time = -1000.0
    end

    local long_playercam_no_update_window = state.last_no_playercam_control_time > 0.0
        and ((now - state.last_no_playercam_control_time) >= 1.25)

    local in_cutscene = state.active_task_count > 0
        or recent_event
        or state.current_task_exists
        or state.game_event_motion_play
        or state.camera_non_controllable
        or state.camera_name_looks_like_cutscene
        or context_missing_long
        or (context_never_seen_yet and no_player_control_signals)
        or long_playercam_no_update_window
        or (camera_update_stale and not state.player_context_available)

    if not state.player_context_available and (state.active_task_count > 0 or state.camera_name_looks_like_cutscene) then
        in_cutscene = true
    end

    if in_cutscene then
        state.last_cutscene_true_time = now
    elseif (now - state.last_cutscene_true_time) <= state.cutscene_release_seconds then
        in_cutscene = true
    end

    state.in_cutscene = in_cutscene
    state.skip_fov_override = false

    if in_cutscene then
        if cfg.normal_fov_during_cutscene then
            state.selected_mode = "Cutscene (Normal)"
            state.selected_fov = nil
            state.skip_fov_override = true
            return
        end

        state.selected_mode = "Cutscene"
        state.selected_fov = cfg.cutscene_fov
        return
    end

    if cfg.use_reload_fov and state.is_reloading then
        state.selected_mode = "Reload"
        state.selected_fov = cfg.reload_fov
        return
    end

    if cfg.use_melee_fov and state.is_melee then
        state.selected_mode = "Melee"
        state.selected_fov = cfg.melee_fov
        return
    end

    if state.is_aiming then
        state.selected_mode = "Aiming"
        state.selected_fov = cfg.aiming_fov
        return
    end

    if state.is_sprinting then
        state.selected_mode = "Sprinting"
        state.selected_fov = cfg.sprinting_fov
        return
    end

    if cfg.use_crouch_fov and state.is_crouching then
        state.selected_mode = "Crouching"
        state.selected_fov = cfg.crouch_fov
        return
    end

    state.selected_mode = "Exploration"
    state.selected_fov = cfg.exploration_fov
end

local function update_baseline(camera)
    local current_fov = read_current_fov(camera)
    if current_fov == nil then
        return
    end

    if state.baseline_fov == nil or state.camera_ref ~= camera then
        state.baseline_fov = current_fov
        state.camera_ref = camera
        state.blended_fov = current_fov
    end
end

local function apply_fov_for_current_state()
    local camera = sdk.get_primary_camera()
    if camera == nil then
        return
    end

    local now = os.clock()
    local dt = 0.016
    if state.last_fov_apply_time > 0.0 then
        dt = now - state.last_fov_apply_time
        if dt < 0.001 then
            dt = 0.001
        elseif dt > 0.05 then
            dt = 0.05
        end
    end
    state.last_fov_apply_time = now

    update_baseline(camera)

    if not cfg.enabled then
        if state.was_enabled and state.baseline_fov ~= nil then
            local restore_fov = state.baseline_fov

            pcall(function()
                if camera_set_fov ~= nil then
                    camera_set_fov:call(sdk.get_thread_context(), camera, restore_fov)
                end
            end)

            pcall(function()
                camera:call("set_FOV", restore_fov)
            end)

            safe_set_member(camera, "FOV", restore_fov)

            if state.player_camera_ref ~= nil then
                safe_set_member(state.player_camera_ref, "FOV", restore_fov)
                safe_set_member(state.player_camera_ref, "CameraFOV", restore_fov)
                safe_set_member(state.player_camera_ref, "TargetFOV", restore_fov)
            end
        end

        state.was_enabled = false
        state.last_applied_fov = nil
        state.blended_fov = nil
        return
    end

    state.was_enabled = true

    if state.skip_fov_override then
        state.last_applied_fov = nil
        state.blended_fov = nil
        return
    end

    local target_fov = clamp(state.selected_fov, 20.0, 170.0)
    local applied_fov = target_fov

    if cfg.smooth_fov_transitions then
        local starting_fov = state.blended_fov
        if starting_fov == nil then
            starting_fov = read_current_fov(camera)
        end

        local delta = 0.0
        if starting_fov ~= nil then
            delta = target_fov - starting_fov
        end

        local speed = (delta < 0.0) and cfg.fov_return_speed or cfg.fov_transition_speed

        applied_fov = smooth_towards(starting_fov, target_fov, speed, dt)

        if math.abs(target_fov - applied_fov) < 0.01 then
            applied_fov = target_fov
        end
    end

    state.blended_fov = applied_fov

    pcall(function()
        if camera_set_fov ~= nil then
            camera_set_fov:call(sdk.get_thread_context(), camera, applied_fov)
        end
    end)

    pcall(function()
        camera:call("set_FOV", applied_fov)
    end)

    safe_set_member(camera, "FOV", applied_fov)

    if state.player_camera_ref ~= nil then
        safe_set_member(state.player_camera_ref, "FOV", applied_fov)
        safe_set_member(state.player_camera_ref, "CameraFOV", applied_fov)
        safe_set_member(state.player_camera_ref, "TargetFOV", applied_fov)

        pcall(function()
            local param_container = safe_get_member(state.player_camera_ref, "CurrentParamContainer")
            if param_container == nil then
                param_container = safe_get_member(state.player_camera_ref, "currentParamContainer")
            end

            if param_container ~= nil then
                local posture_param = safe_get_member(param_container, "PostureParam")
                if posture_param ~= nil then
                    safe_set_member(posture_param, "FOV", applied_fov)
                    safe_set_member(posture_param, "CameraFOV", applied_fov)
                end
            end
        end)
    end

    state.last_applied_fov = applied_fov
end

re.on_pre_application_entry("BeginRendering", function()
    refresh_player_state()
    refresh_camera_context()
    choose_target_fov()
    apply_fov_for_current_state()

    local now = os.clock()
    local mode_changed = state.selected_mode ~= state.last_logged_mode
    local sprint_changed = state.is_sprinting ~= state.last_logged_sprinting
    local cutscene_changed = state.in_cutscene ~= state.last_logged_cutscene
    local skip_changed = state.skip_fov_override ~= state.last_logged_skip

    if mode_changed or sprint_changed or cutscene_changed or skip_changed then
        append_debug_log("state-change")
        state.last_logged_mode = state.selected_mode
        state.last_logged_sprinting = state.is_sprinting
        state.last_logged_cutscene = state.in_cutscene
        state.last_logged_skip = state.skip_fov_override
        state.last_debug_log_time = now
    elseif (now - state.last_debug_heartbeat_time) >= 2.0 then
        append_debug_log("heartbeat")
        state.last_debug_heartbeat_time = now
        state.last_debug_log_time = now
    end
end)

re.on_application_entry("BeginRendering", function()
    apply_fov_for_current_state()
end)

re.on_application_entry("LockScene", function()
    apply_fov_for_current_state()
end)

re.on_script_reset(function()
    local camera = sdk.get_primary_camera()
    if camera ~= nil and state.baseline_fov ~= nil then
        pcall(function()
            if camera_set_fov ~= nil then
                camera_set_fov:call(sdk.get_thread_context(), camera, state.baseline_fov)
            end
        end)

        pcall(function()
            camera:call("set_FOV", state.baseline_fov)
        end)

        safe_set_member(camera, "FOV", state.baseline_fov)

        if state.player_camera_ref ~= nil then
            safe_set_member(state.player_camera_ref, "FOV", state.baseline_fov)
            safe_set_member(state.player_camera_ref, "CameraFOV", state.baseline_fov)
            safe_set_member(state.player_camera_ref, "TargetFOV", state.baseline_fov)
        end
    end

    state.blended_fov = nil
    state.last_fov_apply_time = -1000.0

    append_debug_log("script-reset")
    dump_debug_log(true)
end)

re.on_draw_ui(function()
    if not imgui.tree_node("Better FOV") then
        return
    end

    local changed = false

    local did_change = false
    did_change, cfg.enabled = imgui.checkbox("Enabled", cfg.enabled)
    changed = changed or did_change

    did_change, cfg.exploration_fov = imgui.drag_float("Exploration FOV", cfg.exploration_fov, 0.05, 20.0, 170.0)
    changed = changed or did_change

    did_change, cfg.aiming_fov = imgui.drag_float("Aiming FOV", cfg.aiming_fov, 0.05, 20.0, 170.0)
    changed = changed or did_change

    did_change, cfg.sprinting_fov = imgui.drag_float("Sprinting FOV", cfg.sprinting_fov, 0.05, 20.0, 170.0)
    changed = changed or did_change

    did_change, cfg.cutscene_fov = imgui.drag_float("Cutscene FOV", cfg.cutscene_fov, 0.05, 20.0, 170.0)
    changed = changed or did_change

    did_change, cfg.normal_fov_during_cutscene = imgui.checkbox("Normal FOV during cutscene", cfg.normal_fov_during_cutscene)
    changed = changed or did_change

    did_change, cfg.smooth_fov_transitions = imgui.checkbox("Smooth FOV transitions", cfg.smooth_fov_transitions)
    changed = changed or did_change

    if cfg.smooth_fov_transitions then
        did_change, cfg.fov_transition_speed = imgui.drag_float("Transition Speed", cfg.fov_transition_speed, 0.05, 1.0, 40.0)
        changed = changed or did_change

        did_change, cfg.fov_return_speed = imgui.drag_float("Return Speed", cfg.fov_return_speed, 0.05, 1.0, 40.0)
        changed = changed or did_change
    end

    if imgui.tree_node("Extra Situational FOV") then
        did_change, cfg.use_crouch_fov = imgui.checkbox("Use Crouch FOV", cfg.use_crouch_fov)
        changed = changed or did_change
        if cfg.use_crouch_fov then
            did_change, cfg.crouch_fov = imgui.drag_float("Crouch FOV", cfg.crouch_fov, 0.05, 20.0, 170.0)
            changed = changed or did_change
        end

        did_change, cfg.use_reload_fov = imgui.checkbox("Use Reload FOV", cfg.use_reload_fov)
        changed = changed or did_change
        if cfg.use_reload_fov then
            did_change, cfg.reload_fov = imgui.drag_float("Reload FOV", cfg.reload_fov, 0.05, 20.0, 170.0)
            changed = changed or did_change
        end

        did_change, cfg.use_melee_fov = imgui.checkbox("Use Melee FOV", cfg.use_melee_fov)
        changed = changed or did_change
        if cfg.use_melee_fov then
            did_change, cfg.melee_fov = imgui.drag_float("Melee FOV", cfg.melee_fov, 0.05, 20.0, 170.0)
            changed = changed or did_change
        end

        imgui.tree_pop()
    end

    did_change, cfg.debug_ui = imgui.checkbox("Debug UI", cfg.debug_ui)
    changed = changed or did_change

    if cfg.debug_ui then
        imgui.separator()
        imgui.text("Mode: " .. tostring(state.selected_mode))
        imgui.text("Applied FOV: " .. tostring(state.last_applied_fov))
        imgui.text("Baseline FOV: " .. tostring(state.baseline_fov))
        imgui.text("Skip Override: " .. tostring(state.skip_fov_override))
        imgui.text("Cutscene: " .. tostring(state.in_cutscene))
        imgui.text("EventAction Tasks: " .. tostring(state.active_task_count))
        imgui.text("EventAction CurrentTask: " .. tostring(state.current_task_exists))
        imgui.text("GameEvent MotionPlay: " .. tostring(state.game_event_motion_play))
        imgui.text("Camera Non-Controllable: " .. tostring(state.camera_non_controllable))
        imgui.text("Has Vehicle: " .. tostring(state.has_vehicle))
        imgui.text("Controller: " .. tostring(state.current_controller_name))
        imgui.text("Primary Camera: " .. tostring(state.primary_camera_name))
        imgui.text("CameraNameCutscene: " .. tostring(state.camera_name_looks_like_cutscene))
        imgui.text("PlayerContext OK: " .. tostring(state.player_context_available))
        imgui.text("PlayerContext Last Seen Ago: " .. tostring(os.clock() - state.last_player_context_seen_time))
        imgui.text("PlayerCamera Last Update Ago: " .. tostring(os.clock() - state.last_player_camera_update_time))
        imgui.text("Aiming: " .. tostring(state.is_aiming))
        imgui.text("Sprinting: " .. tostring(state.is_sprinting))
        imgui.text("Move Speed: " .. tostring(state.move_speed))
        imgui.text("Smoothed Speed: " .. tostring(state.smoothed_move_speed))
        imgui.text("Sprint Flag: " .. tostring(state.sprint_flag))
        imgui.text("Sprint Key Down: " .. tostring(state.sprint_key_down))
        imgui.text("Move Input Down: " .. tostring(state.move_input_down))
        imgui.text("Sprint Intent: " .. tostring(state.sprint_intent))
        imgui.text("Sprint Speed Trigger: " .. tostring(state.sprint_speed_trigger))
        imgui.text("Sprint Candidate Frames: " .. tostring(state.sprint_candidate_frames))
        imgui.text("Sprint Last Speed Ago: " .. tostring(os.clock() - state.last_sprint_speed_time))
        imgui.text("Debug Log: " .. DEBUG_LOG_PATH)
        imgui.text("Reloading: " .. tostring(state.is_reloading))
        imgui.text("Crouching: " .. tostring(state.is_crouching))
        imgui.text("Melee: " .. tostring(state.is_melee))
    end

    if changed then
        json.dump_file(CFG_PATH, cfg)
        refresh_player_state()
        choose_target_fov()
        apply_fov_for_current_state()
        append_debug_log("ui-change")
        dump_debug_log(true)
    end

    imgui.tree_pop()
end)
