
if SERVER then
    AddCSLuaFile()
    return
end

module("screens", package.seeall)

local function vec_new() return {0,0,0} end
local function vec_set(v, ...) v[1], v[2], v[3] = ... end
local function vec_ma(v, a, s, o)

    o[1] = v[1] + a[1] * s
    o[2] = v[2] + a[2] * s
    o[3] = v[3] + a[3] * s

end

local function mtx_new() return {1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1} end
local function mtx_set(m, ...)

    m[1 ], m[2 ], m[3 ], m[4 ],
    m[5 ], m[6 ], m[7 ], m[8 ],
    m[9 ], m[10], m[11], m[12],
    m[13], m[14], m[15], m[16] = ...

end

local function mtx_vmul(m, v, w, o)

    o[1] = v[1] * m[1 ] + v[2] * m[2 ] + v[3] * m[3 ] + w * m[4 ]
    o[2] = v[1] * m[5 ] + v[2] * m[6 ] + v[3] * m[7 ] + w * m[8 ]
    o[3] = v[1] * m[9 ] + v[2] * m[10] + v[3] * m[11] + w * m[12]

end

local function make_screen_state()

    return {
        owning_entity = nil,       -- the entity that owns this (if applicable)
        position = vec_new(),      -- position of screen in world-space
        rotation = vec_new(),      -- rotation of screen in world-space
        cursor = vec_new(),        -- last valid cursor coordinates
        world_cursor = vec_new(),  -- last valid cursor world coordinates
        trace_toi = math.huge,     -- last trace distance to surface
        width = 0,                 -- width of screen
        height = 0,                -- height of screen
        xres = 0,                  -- horizontal screen resolution
        yres = 0,                  -- vertical screen resoltution
        xanchor = 0,               -- x anchor offset of screen (0,1)
        yanchor = 0,               -- y anchor offset of screen (0,1)
        zoffset = 0,               -- z offset of screen
        to_world = mtx_new(),      -- screen-to-world matrix
        to_screen = mtx_new(),     -- world-to-screen matrix
    }

end

local screen_states = {}
for i=1, 4096 do screen_states[i] = make_screen_state() end

local PASS_COMPUTE = 1
local PASS_EXECUTE = 2

local system_state = {
    eye_pos = vec_new(),        -- camera position
    eye_dir = vec_new(),        -- camera forward direction
    pressed = {0,0},            -- inputs being pressed this frame
    down = {0,0},               -- inputs being held down this frame
    pass = 1,                   -- current pass being computed
    screen_index = 1,           -- current index being processed
    screen_state = nil,         -- the current screen being processed
    screen_interact = nil,      -- the current screen being interacted with
    screen_interact_prev = nil, -- the previous screen being interacted with
}

local function compute_screen_matrices(state)

    local px, py, pz = unpack(state.position)
    local pitch, yaw, roll = unpack(state.rotation)

    roll = roll * math.pi / 180
    pitch = pitch * math.pi / 180
    yaw = yaw * math.pi / 180

    local sx, cx = math.sin(roll), math.cos(roll)
    local sy, cy = math.sin(pitch), math.cos(pitch)
    local sz, cz = math.sin(yaw), math.cos(yaw)

    local xscale = state.width / state.xres
    local yscale = state.height / state.yres

    -- offset in local coordinates
    local ox, oy, oz = 
        -state.xres * state.xanchor, 
        -state.yres * state.yanchor, 
        state.zoffset

    -- compute to_world matrix (screen to world)
    local r0x = (sx*sy*cz+cx*-sz) * xscale
    local r0y = (sx*sy*sz+cx*cz) * xscale
    local r0z = (sx*cy) * xscale
    local r1x = -(cx*sy*cz-sx*-sz) * yscale
    local r1y = -(cx*sy*sz-sx*cz) * yscale
    local r1z = -(cx*cy) * yscale
    local r2x = (cy*cz)
    local r2y = (cy*sz)
    local r2z = (-sy)

    local wx, wy, wz = 
        px + ox * r0x + oy * r1x + oz * r2x,
        py + ox * r0y + oy * r1y + oz * r2y,
        pz + ox * r0z + oy * r1z + oz * r2z

    mtx_set(state.to_world,
        r0x, r1x, r2x, wx,
        r0y, r1y, r2y, wy,
        r0z, r1z, r2z, wz,
        0, 0, 0, 1)

    -- compute to_screen matrix (world to screen)
    r0x = r0x / (xscale^2)
    r0y = r0y / (xscale^2)
    r0z = r0z / (xscale^2)
    r1x = r1x / (yscale^2)
    r1y = r1y / (yscale^2)
    r1z = r1z / (yscale^2)

    mtx_set(state.to_screen,
        r0x, r0y, r0z, r0x * -wx + r0y * -wy + r0z * -wz,
        r1x, r1y, r1z, r1x * -wx + r1y * -wy + r1z * -wz,
        r2x, r2y, r2z, r2x * -wx + r2y * -wy + r2z * -wz,
        0, 0, 0, 1)

end

local trace_dir = vec_new()
local trace_org = vec_new()
local trace_cursor = vec_new()
local function compute_screen_trace(state, local_out)

    mtx_vmul(state.to_screen, system_state.eye_pos, 1, trace_org)
    mtx_vmul(state.to_screen, system_state.eye_dir, 0, trace_dir)

    if trace_org[3] - 1e-4 < 0 then
        state.trace_toi = math.huge -- didn't hit front
        return
    else
        state.trace_toi = -trace_org[3] / trace_dir[3] -- hit
    end

    local v = local_out or trace_cursor
    vec_ma(trace_org, trace_dir, state.trace_toi, v)

    if v[1] < 0 or v[2] < 0 or v[1] > state.xres or v[2] > state.yres then
        state.trace_toi = math.huge -- didn't hit interior
    end

end

local function push_screenmode(xres, yres)

    render.ClearStencil()
    render.SetStencilEnable(true)
    render.SetStencilCompareFunction( STENCILCOMPARISONFUNCTION_ALWAYS )
    render.SetStencilReferenceValue( 1 )
    render.SetStencilWriteMask( 1 )
    render.SetStencilTestMask( 1 )
    render.SetStencilPassOperation( STENCILOPERATION_REPLACE )
    render.SetStencilFailOperation( STENCILOPERATION_KEEP )
    render.SetStencilZFailOperation( STENCILOPERATION_KEEP )

    render.OverrideDepthEnable( true, true )
    render.OverrideColorWriteEnable( true, false )
    render.SetColorMaterial()
    surface.SetDrawColor(0, 0, 0, 1)
    surface.DrawRect(0, 0, xres, yres )
    render.OverrideColorWriteEnable( false, false )
    render.OverrideDepthEnable( false, false )

    render.SetStencilReferenceValue( 1 )
    render.SetStencilCompareFunction( STENCILCOMPARISONFUNCTION_EQUAL )

    cam.IgnoreZ(true)

    render.PushFilterMag( TEXFILTER.ANISOTROPIC )
    render.PushFilterMin( TEXFILTER.ANISOTROPIC )

end

local function pop_screenmode()

    render.PopFilterMag()
    render.PopFilterMin()

    cam.IgnoreZ(false)

    render.SetStencilEnable(false)

end


local render_mtx = Matrix()
function start(position, rotation, width, height, owning_entity)

    local unfinished = system_state.screen_state ~= nil
    local idx = system_state.screen_index
    local state = screen_states[idx]

    system_state.screen_state = state

    if system_state.pass == PASS_COMPUTE then

        state.owning_entity = owning_entity
        state.valid = false
        state.width = width
        state.height = height
        state.xres = width
        state.yres = height
        state.xanchor = 0
        state.yanchor = 0
        state.zoffset = 0
        vec_set(state.position, position:Unpack())
        vec_set(state.rotation, rotation:Unpack())
        return false

    elseif system_state.pass == PASS_EXECUTE then

        if not state.valid then
            system_state.screen_state = nil
            return false
        end

        render_mtx:SetUnpacked( unpack(state.to_world) )
        cam.PushModelMatrix(render_mtx, true)
        push_screenmode(state.xres, state.yres)
        return true

    end

end

function finish()

    if system_state.screen_state ~= nil then

        local state = system_state.screen_state
        if system_state.pass == PASS_COMPUTE then
            system_state.screen_state.valid = true
            compute_screen_matrices(state)
            compute_screen_trace(state)
        elseif system_state.pass == PASS_EXECUTE then
            pop_screenmode()
            cam.PopModelMatrix()
        end

        system_state.screen_state = nil
        system_state.screen_index = system_state.screen_index + 1

    end

end

function set_anchor(x,y)

    local state = system_state.screen_state
    if not state or system_state.pass ~= PASS_COMPUTE then return end

    state.xanchor = tonumber(x)
    state.yanchor = tonumber(y)

end

function set_res(xres, yres)

    local state = system_state.screen_state
    if not state or system_state.pass ~= PASS_COMPUTE then return end

    state.xres = tonumber(xres)
    state.yres = tonumber(yres)

end

function get_res(xres, yres)

    local state = system_state.screen_state
    if not state then return 0,0 end

    return state.xres, state.yres

end

function get_cursor()

    local state = system_state.screen_state
    if not state or system_state.pass ~= PASS_EXECUTE then return 0,0 end

    return unpack(state.cursor)

end

function is_interacting()

    local state = system_state.screen_state
    if not state or system_state.pass ~= PASS_EXECUTE then return false end

    return system_state.screen_interact == state

end

function has_started_interacting()

    local state = system_state.screen_state
    if not state or system_state.pass ~= PASS_EXECUTE then return false end

    return system_state.screen_interact_prev ~= state and 
           system_state.screen_interact == state

end

function has_stopped_interacting()

    local state = system_state.screen_state
    if not state or system_state.pass ~= PASS_EXECUTE then return false end

    return system_state.screen_interact_prev == state and 
           system_state.screen_interact ~= state

end

hook.Add("PreDrawEffects", "hi", function()

    local origin = EyePos()
    local angles = EyeAngles()
    vec_set(system_state.eye_pos, origin:Unpack())
    vec_set(system_state.eye_dir, angles:Forward():Unpack())

    system_state.screen_index = 1
    system_state.pass = PASS_COMPUTE

    hook.Run("ProcessScreens")

    -- find the screen we're most likely interacting with
    local closest_screen = nil
    local closest_dist = math.huge
    for i=1, system_state.screen_index-1 do
        local state = screen_states[i]
        if state.trace_toi < closest_dist then
            closest_screen = state
            closest_dist = state.trace_toi
        end
    end

    -- compute the local trace and world trace
    if closest_screen then
        compute_screen_trace(closest_screen, closest_screen.cursor)
        mtx_vmul(
            closest_screen.to_world, 
            closest_screen.cursor, 1, 
            closest_screen.world_cursor)
    end

    system_state.screen_interact_prev = system_state.screen_interact
    system_state.screen_interact = closest_screen

    system_state.screen_index = 1
    system_state.pass = PASS_EXECUTE

    hook.Run("ProcessScreens")

end)

local cursor_flash_0 = 0
local cursor_flash_1 = 0
hook.Add("ProcessScreens", "hi", function()

    local drawing = start(Vector(0,0,100), Angle(0,0,0), 200, 200)
    set_anchor(0.5, 0.5)
    set_res(600,600)

    if drawing then

        local x,y = get_cursor()
        local r,g,b = 43,64,133
        if is_interacting() then r,g,b = 80, 196, 70 end
        if has_started_interacting() then cursor_flash_0 = 1 end
        if has_stopped_interacting() then cursor_flash_0 = 1 end
        surface.SetDrawColor(r + cursor_flash_0 * 100,g - cursor_flash_0 * 100,b)
        surface.DrawRect(0,0,get_res())
        surface.SetDrawColor(255,255,255)
        surface.DrawRect(x,y,40,40)
        cursor_flash_0 = math.max(cursor_flash_0 - FrameTime(), 0)

    end

    finish()

    local drawing = start(Vector(0,0,100), Angle(0,50,0), 200, 200)
    set_anchor(0.5, 0.5)
    set_res(600,600)

    if drawing then

        local x,y = get_cursor()
        local r,g,b = 43,64,133
        if is_interacting() then r,g,b = 80, 196, 70 end
        if has_started_interacting() then cursor_flash_1 = 1 end
        if has_stopped_interacting() then cursor_flash_1 = 1 end
        surface.SetDrawColor(r + cursor_flash_1 * 100,g - cursor_flash_1 * 100,b)
        surface.DrawRect(0,0,get_res())
        surface.SetDrawColor(255,255,255)
        surface.DrawRect(x,y,40,40)
        cursor_flash_1 = math.max(cursor_flash_1 - FrameTime(), 0)

    end

    finish()

end)