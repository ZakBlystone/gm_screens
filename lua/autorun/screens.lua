
if SERVER then
    AddCSLuaFile()
    return
end

module("screens", package.seeall)

local function vec_new() return {0,0,0} end
local function vec_set(v, ...) v[1], v[2], v[3] = ... end
local function vec_dot(a, b) return a[1] * b[1] + a[2] * b[2] + a[3] * b[3] end
local function vec_len(a) return math.sqrt(vec_dot(a,a)) end
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
        behind = false,            -- camera is behind screen
        first_command = 0,         -- first command to process for rendering
        last_command = 0,          -- last command to process for rendering
    }

end

local command_list = {}
local screen_states = {}
for i=1, 4096 do screen_states[i] = make_screen_state() end

local PASS_COMPUTE = 1
local PASS_EXECUTE = 2
local PASS_ALL = 0xFF
local PASS_COUNT = 2

local CMF_NONE = 0
local CMF_NOREPEAT = 1

local CMD_RESET = 0
local CMD_SETCOLOR = 1
local CMD_SETFONT = 2
local CMD_SETMATERIAL = 3
local CMD_DRAWRECT = 4
local CMD_DRAWIMAGE = 5
local CMD_TEXT = 6

local draw_state = {
    color = {255,255,255,255},
    font = "DermaDefault",
    material = nil,
}

local command_functors = {
    [CMD_RESET] = function(cmd)
        for i=1, 4 do draw_state.color[i] = 255 end
        draw_state.font = "DermaDefault"
        draw_state.material = nil
    end,
    [CMD_SETCOLOR] = function(cmd)
        draw_state.color[1] = cmd.r
        draw_state.color[2] = cmd.g
        draw_state.color[3] = cmd.b
        draw_state.color[4] = cmd.a
    end,
    [CMD_SETFONT] = function(cmd)
        draw_state.font = cmd.font
    end,
    [CMD_SETMATERIAL] = function(cmd)
        draw_state.material = cmd.material
    end,
    [CMD_DRAWRECT] = function(cmd)
        surface.SetDrawColor(unpack(draw_state.color))
        surface.DrawRect(cmd.x, cmd.y, cmd.w, cmd.h)
    end,
    [CMD_DRAWIMAGE] = function(cmd)
        surface.SetDrawColor(unpack(draw_state.color))
        if cmd.material or draw_state.material then
            surface.SetMaterial(cmd.material or draw_state.material)
            surface.DrawTexturedRect(cmd.x, cmd.y, cmd.w, cmd.h)
        else
            surface.DrawRect(cmd.x, cmd.y, cmd.w, cmd.h)
        end
    end,
    [CMD_TEXT] = function(cmd)
        surface.SetFont(draw_state.font)
        surface.SetTextColor(unpack(draw_state.color))
        local w,h = surface.GetTextSize(cmd.str)
        local x,y = cmd.x, cmd.y
        if cmd.xalign == TEXT_ALIGN_CENTER then x = x - w/2
        elseif cmd.xalign == TEXT_ALIGN_RIGHT then x = x - w end
        if cmd.yalign == TEXT_ALIGN_CENTER then y = y - h/2
        elseif cmd.yalign == TEXT_ALIGN_BOTTOM then y = y - h end
        surface.SetTextPos(x, y)
        surface.DrawText(cmd.str)
    end,
}

local system_state = {
    eye_pos = vec_new(),        -- camera position
    eye_dir = vec_new(),        -- camera forward direction
    pressed = {false,false},    -- inputs being pressed this frame
    released = {false, false},  -- inputs being released this frame
    prev_down = {false, false}, -- inputs previous held down
    down = {false, false},      -- inputs being held down this frame
    pass = 1,                   -- current pass being computed
    screen_index = 1,           -- current index being processed
    screen_state = nil,         -- the current screen being processed
    screen_interact = nil,      -- the current screen being interacted with
    screen_interact_prev = nil, -- the previous screen being interacted with
    num_processed = 0,          -- number of screens processed
    num_rendered = 0,           -- number of screens rendered (all passes)
    num_commands = 0,           -- number of queued commands
    command_list = {},          -- command list
}

local trace_result_table = {}
local trace_table = {
    start = Vector(),
    endpos = Vector(),
    filter = {},
    output = trace_result_table,
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
        if not local_out then state.behind = true end
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

local function alloc_command(cmd, flags)

    flags = flags or CMF_NONE
    if bit.band(flags, CMF_NOREPEAT) ~= 0 then

        local last = system_state.command_list[system_state.num_commands]
        if last and last.cmd == cmd then return last end

    end

    local n = system_state.num_commands + 1
    local tbl = system_state.command_list[n] or {}
    tbl.cmd = cmd
    system_state.command_list[n] = tbl
    system_state.num_commands = n

    return tbl

end

local function process_command(cmd)

    local functor = command_functors[cmd.cmd]
    if functor then
        local b,e = pcall(functor, cmd)
        if not b then print(e) end
    else
        ErrorNoHalt("NO FUNCTOR FOR COMMAND: " .. tostring(cmd.cmd))
    end

end

local render_mtx = Matrix()
local function scr_start(position, rotation, width, height, owning_entity)

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
        state.behind = false
        vec_set(state.position, position:Unpack())
        vec_set(state.rotation, rotation:Unpack())

    elseif system_state.pass == PASS_EXECUTE then

        alloc_command(CMD_RESET)
        state.first_command = system_state.num_commands

    end

end

local function scr_finish()

    if system_state.screen_state ~= nil then

        local state = system_state.screen_state
        if system_state.pass == PASS_COMPUTE then

            system_state.num_processed = system_state.num_processed + 1
            system_state.screen_state.valid = true
            compute_screen_matrices(state)
            compute_screen_trace(state)
            system_state.screen_state = nil
            system_state.screen_index = system_state.screen_index + 1

        elseif system_state.pass == PASS_EXECUTE then

            state.last_command = system_state.num_commands
            system_state.screen_state = nil
            system_state.screen_index = system_state.screen_index + 1

        end

    end

end

local function scr_set_anchor(x,y,z_offset)

    local state = system_state.screen_state
    if not state then return end

    state.xanchor = tonumber(x)
    state.yanchor = tonumber(y)
    if z_offset then
        state.zoffset = tonumber(z_offset)
    else
        state.zoffset = 0
    end

end

local function scr_set_res(xres, yres)

    local state = system_state.screen_state
    if not state then return end

    state.xres = tonumber(xres)
    state.yres = tonumber(yres)

end

local function scr_get_res(xres, yres)

    local state = system_state.screen_state
    if not state then return 0,0 end

    return state.xres, state.yres

end

local function scr_get_cursor()

    local state = system_state.screen_state
    if not state then return 0,0 end

    return unpack(state.cursor)

end

local function scr_is_down(i) 
    
    local state = system_state.screen_state
    return system_state.screen_interact == state and system_state.down[i]

end

local function scr_is_pressed(i) 
    
    local state = system_state.screen_state
    return system_state.screen_interact == state and system_state.pressed[i]

end

local function scr_is_released(i) 
    
    local state = system_state.screen_state
    return system_state.screen_interact == state and system_state.released[i]

end

local function scr_is_interacting()

    local state = system_state.screen_state
    if not state then return 0,0 end

    return system_state.screen_interact == state

end

local function scr_has_entered()

    local state = system_state.screen_state
    return system_state.screen_interact_prev ~= state and 
           system_state.screen_interact == state

end

local function scr_has_exited()

    local state = system_state.screen_state
    return system_state.screen_interact_prev == state and 
           system_state.screen_interact ~= state

end

local function scr_set_color(r, g, b, a)

    if type(r) == "table" then r,g,b,a = r.r, r.g, r.b, r.a end

    local cmd = alloc_command(CMD_SETCOLOR, CMF_NOREPEAT)
    cmd.r = r
    cmd.g = g
    cmd.b = b
    cmd.a = a

end

local function scr_set_font(font)

    local cmd = alloc_command(CMD_SETFONT, CMF_NOREPEAT)
    cmd.font = font

end

local function scr_set_material(m)

    local cmd = alloc_command(CMD_SETMATERIAL, CMF_NOREPEAT)
    cmd.material = m

end

local function scr_rect(x, y, w, h)

    local cmd = alloc_command(CMD_DRAWRECT)
    cmd.x = x
    cmd.y = y
    cmd.w = w
    cmd.h = h

end

local function scr_image(x, y, w, h, material)

    local cmd = alloc_command(CMD_DRAWIMAGE)
    cmd.x = x
    cmd.y = y
    cmd.w = w
    cmd.h = h
    cmd.material = material

end

local function scr_text(str, x, y, xalign, yalign)

    local cmd = alloc_command(CMD_TEXT)
    cmd.str = str
    cmd.x = x or 0
    cmd.y = y or 0
    cmd.xalign = xalign or TEXT_ALIGN_LEFT
    cmd.yalign = yalign or TEXT_ALIGN_TOP

end

local function scr_text_center(str, x, y)

    local cmd = alloc_command(CMD_TEXT)
    cmd.str = str
    cmd.x = x or 0
    cmd.y = y or 0
    cmd.xalign = TEXT_ALIGN_CENTER
    cmd.yalign = TEXT_ALIGN_CENTER

end

local function create_nop(...)
    local t = {...}
    return function() return unpack(t) end 
end

-- hook pass matrix
local apis = {}
local function api_register(name, func, passes, ...)

    for i=0, PASS_COUNT-1 do
        local idx = bit.lshift(1, i)
        apis[idx] = apis[idx] or {}
        apis[idx][name] = bit.band(passes, idx) ~= 0 and func or create_nop(...)
    end

end

api_register("start", scr_start, PASS_ALL)
api_register("finish", scr_finish, PASS_ALL)
api_register("set_anchor", scr_set_anchor, PASS_COMPUTE)
api_register("set_res", scr_set_res, PASS_COMPUTE)
api_register("get_res", scr_get_res, PASS_ALL)
api_register("get_cursor", scr_get_cursor, PASS_EXECUTE, 0, 0)
api_register("is_interacting", scr_is_interacting, PASS_EXECUTE, false)
api_register("is_down", scr_is_down, PASS_EXECUTE, false)
api_register("is_pressed", scr_is_pressed, PASS_EXECUTE, false)
api_register("is_released", scr_is_released, PASS_EXECUTE, false)
api_register("has_entered", scr_has_entered, PASS_EXECUTE, false)
api_register("has_exited", scr_has_exited, PASS_EXECUTE, false)
api_register("set_color", scr_set_color, PASS_EXECUTE)
api_register("set_font", scr_set_font, PASS_EXECUTE)
api_register("set_material", scr_set_material, PASS_EXECUTE)
api_register("rect", scr_rect, PASS_EXECUTE)
api_register("image", scr_image, PASS_EXECUTE)
api_register("text", scr_text, PASS_EXECUTE)
api_register("text_center", scr_text_center, PASS_EXECUTE)

local function run_pass(pass)

    system_state.screen_index = 1
    system_state.pass = pass

    hook.Run("ProcessScreens", apis[pass])

end

hook.Add("HUDPaint", "hi", function()

    draw.SimpleText(
        "Screens Processed: " .. system_state.num_processed,
        "DermaLarge",
        500, 0)

    draw.SimpleText(
        "Screens Rendered: " .. system_state.num_rendered,
        "DermaLarge",
        500, 30)

    draw.SimpleText(
        "Render Commands Queued: " .. system_state.num_commands,
        "DermaLarge",
        500, 60)

end)

hook.Add("PreDrawEffects", "hi", function() end)
hook.Add("PreRender", "hi", function()
    system_state.num_processed = 0
    system_state.num_rendered = 0
    system_state.first_view = true
    --print("BEGIN RENDER:")
end)

local function process_screens(view)

    local eye_pos = view.origin 
    local eye_dir = view.angles:Forward()

    if vgui.CursorVisible() then
        eye_dir = gui.ScreenToVector(gui.MousePos())
    end

    for i=1, 2 do
        system_state.pressed[i] = false
        system_state.released[i] = false
        local prev_down_state = system_state.prev_down[i]
        local curr_down_state = system_state.down[i]
        system_state.prev_down[i] = system_state.down[i]

        if prev_down_state == false and curr_down_state == true then
            system_state.pressed[i] = true
        end
        if prev_down_state == true and curr_down_state == false then
            system_state.released[i] = true
        end
    end

    vec_set(system_state.eye_pos, eye_pos:Unpack())
    vec_set(system_state.eye_dir, eye_dir:Unpack())

    run_pass(PASS_COMPUTE)

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

        trace_table.start = eye_pos
        trace_table.mask = 1
        trace_table.endpos:SetUnpacked(unpack(closest_screen.world_cursor))
        trace_table.filter[1] = LocalPlayer()
        trace_table.filter[2] = closest_screen.owning_entity
        local tr = util.TraceLine(trace_table)
        if tr.Fraction ~= 1.0 then closest_screen = nil end
    end

    system_state.screen_interact_prev = system_state.screen_interact
    system_state.screen_interact = closest_screen
    system_state.num_commands = 0

    run_pass(PASS_EXECUTE)

end

local function render_screens()

    render.SetStencilEnable(true)
    render.SetStencilReferenceValue( 1 )
    render.SetStencilWriteMask( 1 )
    render.SetStencilTestMask( 1 )
    render.SetStencilPassOperation( STENCILOPERATION_REPLACE )
    render.SetStencilFailOperation( STENCILOPERATION_KEEP )
    render.SetStencilZFailOperation( STENCILOPERATION_KEEP )

    render.PushFilterMag( TEXFILTER.ANISOTROPIC )
    render.PushFilterMin( TEXFILTER.ANISOTROPIC )

    for i=1, system_state.screen_index-1 do

        local state = screen_states[i]
        if not state.valid then continue end
        if state.behind then continue end

        render_mtx:SetUnpacked( unpack(state.to_world) )
        cam.PushModelMatrix(render_mtx, true)

        render.ClearStencil()
        render.SetStencilCompareFunction( STENCILCOMPARISONFUNCTION_ALWAYS )
        render.OverrideDepthEnable( true, true )
        render.OverrideColorWriteEnable( true, false )
        render.SetColorMaterial()
        surface.SetDrawColor(0, 0, 0, 1)
        surface.DrawRect(0, 0, state.xres, state.yres )
        render.OverrideColorWriteEnable( false, false )
        render.OverrideDepthEnable( false, false )
        render.SetStencilCompareFunction( STENCILCOMPARISONFUNCTION_EQUAL )
        cam.IgnoreZ(true)

        for j=state.first_command, state.last_command do
            process_command(system_state.command_list[j])
        end

        system_state.num_rendered = system_state.num_rendered + 1

        cam.IgnoreZ(false)
        cam.PopModelMatrix()

    end

    render.PopFilterMag()
    render.PopFilterMin()

    render.SetStencilEnable(false)

end

hook.Add("PostDrawOpaqueRenderables", "hi", function()

    local view = render.GetViewSetup()
    if view.viewid == VIEW_3DSKY then return end
    if view.viewid ~= 0 then return end

    if system_state.first_view then

        system_state.first_view = false
        process_screens(view)

    end

    render_screens()

end)

hook.Add("PlayerBindPress", "hi", function(ply, bind, pressed, code)

    if bind == "+attack" then

        local interact = system_state.screen_interact
        if interact then
            system_state.down[1] = pressed
            return true
        end

    end

end)

local lmb_material = Material("gui/lmb.png")
hook.Add("ProcessScreens", "hi", function(s)

    local t = CurTime()
    local ply = LocalPlayer()
    for _, ent in ents.Iterator() do
        if ent:IsDormant() then continue end
        if ent:GetClass() ~= "prop_physics" then continue end
        if ent:GetModel() == "models/props_c17/tv_monitor01.mdl" then

            s.start(ent:GetPos(), ent:GetAngles(), 15, 10.5, ent)
            s.set_res(320,240)
            s.set_anchor(0.62,0.565,6)
            local x,y = s.get_cursor()
            local w,h = s.get_res()
            local interact = s.is_interacting()
            if s.is_pressed(1) then
                ent.__toggle = not ent.__toggle
                ent:EmitSound("buttons/button1.wav")
            end
            s.set_color(46,80,120)
            if ent.__toggle then 
                s.set_color(165,74,71)
                if interact then s.set_color(80,20,20) end
            elseif interact then
                s.set_color(73,197,129)
            end
            s.rect(0,0,w,h)
            if interact then
                s.set_color(255,255,255)
                s.image(x-20,y-20,40,40,lmb_material)
            end
            s.set_font("DermaLarge")
            s.set_color(255,255,255)
            s.text_center("Toggled: " .. tostring(ent.__toggle or false), w/2, h/2)

            for i=1, 30 do
                s.rect(i*10, 20 + math.sin(t*4+i) * 10, 8, 8)
            end

            s.finish()

        end
    end

end)