
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

local function vec_dist_sqr(a, b)

    return (a[1] - b[1]) ^ 2 + (a[2] - b[2]) ^ 2 + (a[3] - b[3]) ^ 2

end

local function mtx_new() return {1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1} end
local function mtx_set(m, ...)

    m[1 ], m[2 ], m[3 ], m[4 ],
    m[5 ], m[6 ], m[7 ], m[8 ],
    m[9 ], m[10], m[11], m[12],
    m[13], m[14], m[15], m[16] = ...

end

local function mtx_vmul(m, v, w, o)

    o[1], o[2], o[3] = 
        v[1] * m[1 ] + v[2] * m[2 ] + v[3] * m[3 ] + w * m[4 ],
        v[1] * m[5 ] + v[2] * m[6 ] + v[3] * m[7 ] + w * m[8 ],
        v[1] * m[9 ] + v[2] * m[10] + v[3] * m[11] + w * m[12]

end

local function atlas_packer(w, h, pad)

	pad = pad or 0
    local free = { x=0, y=0, w=w, h=h }
    return function(width, height)

        local node, prev = free, nil
        while node ~= nil do
            if width <= node.w and height <= node.h then break end
            prev, node = node, node.next
        end
        if node == nil then return end
    
        local rwidth = node.w - width
        local rheight = node.h - height
        local l, r
    
        if rwidth >= rheight then
            l = { x=node.x, y=node.y + height + pad, w=width, h=rheight - pad }
            r = { x=node.x + width + pad, y=node.y, w=rwidth - pad, h=node.h }
        else
            l = { x=node.x + width + pad, y=node.y, w=rwidth - pad, h=height }
            r = { x=node.x, y=node.y + height + pad, w=node.w, h=rheight - pad }
        end
    
        if prev then prev.next = l else free = l end
        l.next = r
        r.next = node.next
        node.w, node.h, node.next = width, height, nil
        return node

    end

end

local function make_screen_state()

    return {
        pixel_vis = util.GetPixelVisibleHandle(),
        rt_id = nil,               -- allocated rendertarget id
        rt_rect = nil,             -- allocated rendertarget rectangle
        owning_entity = nil,       -- the entity that owns this (if applicable)
        active_panel = nil,        -- the active vgui panel on this screen
        position = vec_new(),      -- position of screen in world-space
        rotation = vec_new(),      -- rotation of screen in world-space
        last_cursor = vec_new(),   -- previous valid cursor coordinates
        cursor = vec_new(),        -- current valid cursor coordinates
        world_cursor = vec_new(),  -- last valid cursor world coordinates
        trace_toi = math.huge,     -- last trace distance to surface
        capture_mouse = false,     -- should this screen capture mouse inputs
        capture_use = false,       -- should this screen capture +use bind
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
        center = vec_new(),        -- center of screen bounding sphere
        radius = 0,                -- radius of screen bounding sphere
        vertices = {               -- screen-space vertices
            vec_new(),
            vec_new(),
            vec_new(),
            vec_new(),
        },
        w_vertices = {             -- world-space vertices
            vec_new(),
            vec_new(),
            vec_new(),
            vec_new(),
        },
    }

end

local command_list = {}
local screen_states = {}
for i=1, 4096 do screen_states[i] = make_screen_state() end

local RENDERTARGET_SIZE = 2048

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
local CMD_PAINTVGUI = 7

local draw_state = {
    color = {255,255,255,255},
    font = "DermaDefault",
    material = nil,
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
    num_render_passes = 0,      -- number of render passes last frame
    command_list = {},          -- command list
    hovered_panel,              -- the currently hovered vgui panel
    captured_panels = {},       -- panels requesting input capture
    render_targets = {},        -- cached off-screen rendertargets
    num_render_targets = 0,     -- number of rendertargets
    perf_stat_count = {},       -- number of samples for performance counters
    perf_stat_start = {},       -- starttimes for performance counters
    perf_stat_depth = {},       -- depth of each stat
    perf_stats = {},            -- performance counters
    perf_depth = 1,             -- performance counter depth
    sorted_perf_stats = {},     -- sorted performance counters for UI
}

local function perf_start(id)

    local s = system_state
    s.perf_stat_start[id] = SysTime()
    s.perf_stats[id] = s.perf_stats[id] or 0
    s.perf_stat_depth[id] = s.perf_depth
    s.perf_depth = s.perf_depth + 1

end

local function perf_end(id)

    local s = system_state
    s.perf_depth = s.perf_depth - 1
    if s.perf_stat_start[id] then
        s.perf_stats[id] = s.perf_stats[id] + SysTime() - s.perf_stat_start[id]
        s.perf_stat_count[id] = (s.perf_stat_count[id] or 0) + 1
    end

end

local command_functors = {
    [CMD_RESET] = function(cmd)
        perf_start("command_reset")
        for i=1, 4 do draw_state.color[i] = 255 end
        draw_state.font = "DermaDefault"
        draw_state.material = nil
        perf_end("command_reset")
    end,
    [CMD_SETCOLOR] = function(cmd)
        perf_start("command_set_color")
        draw_state.color[1] = cmd.r
        draw_state.color[2] = cmd.g
        draw_state.color[3] = cmd.b
        draw_state.color[4] = cmd.a
        perf_end("command_set_color")
    end,
    [CMD_SETFONT] = function(cmd)
        draw_state.font = cmd.font
    end,
    [CMD_SETMATERIAL] = function(cmd)
        draw_state.material = cmd.material
    end,
    [CMD_DRAWRECT] = function(cmd)
        perf_start("command_rect")
        surface.SetDrawColor(unpack(draw_state.color))
        surface.DrawRect(cmd.x, cmd.y, cmd.w, cmd.h)
        perf_end("command_rect")
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
        perf_start("command_text")
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
        perf_end("command_text")
    end,
    [CMD_PAINTVGUI] = function(cmd)
        local panel = cmd.panel
        if IsValid(panel) then
            perf_start("PANEL:PaintManual")
            panel:PaintManual()
            perf_end("PANEL:PaintManual")
        end
    end,
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

    perf_start("command_time")

    local functor = command_functors[cmd.cmd]
    if functor then
        local b,e = pcall(functor, cmd)
        if not b then print(e) end
    else
        ErrorNoHalt("NO FUNCTOR FOR COMMAND: " .. tostring(cmd.cmd))
    end

    perf_end("command_time")

end

local render_mtx = Matrix()
local fmt_unfinished_screen = "WARNING: Unfinished screen, check your code"
local function scr_start(position, rotation, width, height, owning_entity)

    local unfinished = system_state.screen_state ~= nil
    if unfinished then print(fmt_unfinished_screen) end

    local idx = system_state.screen_index
    local state = screen_states[idx]

    system_state.screen_state = state

    if system_state.pass == PASS_COMPUTE then

        state.capture_mouse = false
        state.capture_use = false
        state.active_panel = nil
        state.owning_entity = owning_entity or system_state.current_entity
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
        return true

    elseif system_state.pass == PASS_EXECUTE then

        if not state.should_render then return false end
        alloc_command(CMD_RESET)
        state.first_command = system_state.num_commands
        return true

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

local function scr_capture_mouse()

    system_state.screen_state.capture_mouse = true

end

local function scr_capture_use()

    system_state.screen_state.capture_use = true

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
    cmd.r = tonumber(r) or 0
    cmd.g = tonumber(g) or 0
    cmd.b = tonumber(b) or 0
    cmd.a = tonumber(a) or 255

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
    cmd.x = tonumber(x) or 0
    cmd.y = tonumber(y) or 0
    cmd.w = tonumber(w) or 0
    cmd.h = tonumber(h) or 0

end

local function scr_image(x, y, w, h, material)

    local cmd = alloc_command(CMD_DRAWIMAGE)
    cmd.x = tonumber(x) or 0
    cmd.y = tonumber(y) or 0
    cmd.w = tonumber(w) or 0
    cmd.h = tonumber(h) or 0
    cmd.material = material

end

local function scr_text(str, x, y, xalign, yalign)

    local cmd = alloc_command(CMD_TEXT)
    cmd.str = tostring(str)
    cmd.x = tonumber(x) or 0
    cmd.y = tonumber(y) or 0
    cmd.xalign = xalign or TEXT_ALIGN_LEFT
    cmd.yalign = yalign or TEXT_ALIGN_TOP

end

local function scr_text_center(str, x, y)

    local cmd = alloc_command(CMD_TEXT)
    cmd.str = tostring(str)
    cmd.x = tonumber(x) or 0
    cmd.y = tonumber(y) or 0
    cmd.xalign = TEXT_ALIGN_CENTER
    cmd.yalign = TEXT_ALIGN_CENTER

end

local function scr_vgui(panel)

    local state = system_state.screen_state
    if not state then return end

    if system_state.pass == PASS_COMPUTE then
        if IsValid(panel) then
            panel:SetSize( state.xres, state.yres )
            panel:SetPaintedManually(true)
            panel:SetMouseInputEnabled(false)
            state.active_panel = panel
        else
            state.active_panel = nil
        end
    elseif system_state.pass == PASS_EXECUTE then
        if IsValid(panel) then
            local cmd = alloc_command(CMD_PAINTVGUI)
            cmd.panel = panel
        end
    end

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
api_register("capture_mouse", scr_capture_mouse, PASS_COMPUTE)
api_register("capture_use", scr_capture_use, PASS_COMPUTE)
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
api_register("vgui", scr_vgui, PASS_COMPUTE + PASS_EXECUTE)

local function run_pass(pass)

    system_state.screen_index = 1
    system_state.pass = pass

    hook.Run("ProcessScreens", apis[pass])

end

local function get_active_screen_and_panel()

    local screen = system_state.screen_interact
    if not screen then return nil end
    local panel = screen.active_panel
    if not IsValid(panel) then return screen, nil end
    return screen, panel

end

local function recursive_send_cursor_move(panel, cx, cy)

    if not panel:IsVisible() or not panel:IsMouseInputEnabled() then return end

    local w, h = panel:GetSize()
    local x, y = panel:GetPos()

    --if cx < x or cy < y or cx > x + w or cy > y + h then return end

    cx = cx - x
    cy = cy - y

    if panel.OnCursorMoved then panel:OnCursorMoved( cx, cy ) end

    for i=0, panel:ChildCount()-1 do
        recursive_send_cursor_move(panel:GetChild(i), cx, cy)
    end

end

local function recursive_update_hovered_panels(panel, cx, cy, enable)

    if not panel:IsVisible() 
    or not panel:IsMouseInputEnabled() then 

        enable = false

    end

    local w, h = panel:GetSize()
    local x, y = panel:GetPos()

    if cx < x or cy < y or cx > x + w or cy > y + h then enable = false end

    panel.Hovered = enable

    cx = cx - x
    cy = cy - y

    local hovered_panel = nil
    if enable then hovered_panel = panel end
    for i=0, panel:ChildCount()-1 do
        local child = panel:GetChild(i)
        local hovered = recursive_update_hovered_panels(child, cx, cy, enable)
        if hovered then hovered_panel = hovered end
    end

    return hovered_panel

end

local function update_hovered_panels(screen, panel, enable)

    system_state.hovered_panel = recursive_update_hovered_panels(
        panel, 
        screen.cursor[1], 
        screen.cursor[2], 
        enable)

end

local function vgui_get_hovered_panel()

    return system_state.hovered_panel

end

local function gui_mouse_pos()

    local screen, panel = get_active_screen_and_panel()
    if not screen then return 0,0 end
    return screen.cursor[1], screen.cursor[2]

end

local function gui_mouse_x()

    local screen, panel = get_active_screen_and_panel()
    return screen.cursor[1]

end

local function gui_mouse_y()

    local screen, panel = get_active_screen_and_panel()
    return screen.cursor[2]

end

local function input_get_cursor()

    local screen, panel = get_active_screen_and_panel()
    return screen.cursor[1], screen.cursor[2]

end

local function panel_mouse_capture(panel, capture)

    if capture then
        system_state.captured_panels[panel] = true
    else
        system_state.captured_panels[panel] = nil
    end

end

local function panel_cursor_pos(panel)

    local x,y = gui_mouse_pos()
    return panel:ScreenToLocal(x,y)

end

local function run_vgui_input()

    local screen, panel = get_active_screen_and_panel()
    if not IsValid(panel) then return end

    local hovered = vgui.GetHoveredPanel()
    if hovered ~= screen.last_hovered then
        if IsValid(screen.last_hovered) 
        and screen.last_hovered.OnCursorExited then
            screen.last_hovered:OnCursorExited()
        end
        if IsValid(hovered) 
        and hovered.OnCursorEntered then
            hovered:OnCursorEntered()
        end
        screen.last_hovered = hovered
    end

    if system_state.pressed[1] then
        for panel, _ in pairs(system_state.captured_panels) do
            panel:OnMousePressed(MOUSE_LEFT)
        end
        if IsValid(hovered) 
        and hovered.OnMousePressed then
            hovered:OnMousePressed(MOUSE_LEFT)
            screen.last_pressed = hovered
        end
    end

    if system_state.released[1] then
        if IsValid(screen.last_pressed) 
        and screen.last_pressed.OnMouseReleased then
            screen.last_pressed:OnMouseReleased(MOUSE_LEFT)
            screen.last_pressed = nil
        end
        for panel, _ in pairs(system_state.captured_panels) do
            panel:OnMouseReleased(MOUSE_LEFT)
        end
    end

    if screen.last_cursor[1] ~= screen.cursor[1]
    or screen.last_cursor[2] ~= screen.cursor[2] then

        recursive_send_cursor_move(
            panel, 
            screen.cursor[1], 
            screen.cursor[2])

    end

end

local panel_meta = FindMetaTable("Panel")
local detour_hovered_panel = vgui.GetHoveredPanel
local detour_mouse_pos = gui.MousePos
local detour_mouse_x = gui.MouseX
local detour_mouse_y = gui.MouseY
local detour_cursor = input.GetCursorPos
local detour_mouse_capture = panel_meta.MouseCapture
local detour_cursor_pos = panel_meta.CursorPos

local function vgui_enable_detours(enable)

    if enable then

        vgui.GetHoveredPanel = vgui_get_hovered_panel
        gui.MousePos = gui_mouse_pos
        gui.MouseX = gui_mouse_x
        gui.MouseY = gui_mouse_y
        input.GetCursorPos = input_get_cursor
        panel_meta.MouseCapture = panel_mouse_capture
        panel_meta.CursorPos = panel_cursor_pos

    else

        vgui.GetHoveredPanel = detour_hovered_panel
        gui.MousePos = detour_mouse_pos
        gui.MouseX = detour_mouse_x
        gui.MouseY = detour_mouse_y
        input.GetCursorPos = detour_cursor
        panel_meta.MouseCapture = detour_mouse_capture
        panel_meta.CursorPos = detour_cursor_pos

    end

end

local function get_cached_rendertarget(index)

    local rt_size = RENDERTARGET_SIZE
    local rt_list = system_state.render_targets
    if not rt_list[index] then
        local rt_prefix = "screenatlas_rt_"
        local rt_name = rt_prefix .. (index-1)
        local rt_params = {
            rt_size, 
            rt_size, 
            RT_SIZE_LITERAL, 
            MATERIAL_RT_DEPTH_NONE, 
            0, 
            CREATERENDERTARGETFLAGS_UNFILTERABLE_OK, 
            IMAGE_FORMAT_ABGR8888
        }
        rt_list[index] = GetRenderTargetEx(rt_name, unpack(rt_params))
    end
    return rt_list[index], rt_size

end

local function allocate_screen_rendertargets()

    if system_state.screen_index == 1 then return end
    perf_start("rt_allocate")

    local rt_num = 1
    local rt, rt_size = get_cached_rendertarget(rt_num)

    local packer = atlas_packer(rt_size, rt_size, 1)
    for i=1, system_state.screen_index-1 do

        local state = screen_states[i]
        state.rt_id = nil
        state.rt_rect = nil

        if not state.should_render then continue end

        local node = packer(state.xres, state.yres)
        if not node then
            local new_packer = atlas_packer(rt_size, rt_size, 1)
            node = new_packer(state.xres, state.yres)
            if not node then continue end
            packer = new_packer
            rt_num = rt_num + 1
            rt, rt_size = get_cached_rendertarget(rt_num)
        end

        state.rt_id = rt_num
        state.rt_rect = node

    end

    system_state.num_render_targets = rt_num
    perf_end("rt_allocate")

end

local center_vec = Vector()

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
        system_state.pressed[i] = not prev_down_state and curr_down_state
        system_state.released[i] = prev_down_state and not curr_down_state
    end

    vec_set(system_state.eye_pos, eye_pos:Unpack())
    vec_set(system_state.eye_dir, eye_dir:Unpack())

    perf_start("pass_compute")
    run_pass(PASS_COMPUTE)
    perf_end("pass_compute")

    perf_start("transform_screens")
    for i=1, system_state.screen_index-1 do

        local state = screen_states[i]
        vec_set(state.center, 0, 0, 0)
        vec_set(state.vertices[1], 0, 0, 0)
        vec_set(state.vertices[2], state.xres, 0, 0)
        vec_set(state.vertices[3], state.xres, state.yres, 0)
        vec_set(state.vertices[4], 0, state.yres, 0)

        for j=1, 4 do
            mtx_vmul(state.to_world, state.vertices[j], 1, state.w_vertices[j])
            vec_ma(state.center, state.w_vertices[j], 0.25, state.center)
        end

        local radius_sqr = 0
        local center = state.center
        for j=1, 4 do
            local dist_sqr = vec_dist_sqr(center, state.w_vertices[j])
            radius_sqr = math.max(radius_sqr, dist_sqr)
        end
        state.radius = math.sqrt(radius_sqr)
        state.visible = (not state.behind)

        if state.visible then

            center_vec:SetUnpacked(unpack(center))

            local vis = util.PixelVisible(
                center_vec,
                state.radius * 2,
                state.pixel_vis
            )

            -- not sure why, but in the most recent update; pixelvis
            -- diminishes toward 0 as you get closer, so override
            -- if eye is close
            local eye_distance = vec_dist_sqr(center, system_state.eye_pos)
            if eye_distance < radius_sqr * 16 then vis = 1 end

            state.visible = vis > 0

        end

        state.should_render = state.visible and (not state.behind)

    end
    perf_end("transform_screens")

    perf_start("trace_screens")
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
        vec_set(closest_screen.last_cursor, unpack(closest_screen.cursor))
        compute_screen_trace(closest_screen, closest_screen.cursor)
        mtx_vmul(
            closest_screen.to_world, 
            closest_screen.cursor, 1, 
            closest_screen.world_cursor)

        trace_table.start = eye_pos
        trace_table.endpos:SetUnpacked(unpack(closest_screen.world_cursor))
        trace_table.filter[1] = LocalPlayer()
        trace_table.filter[2] = closest_screen.owning_entity
        local tr = util.TraceLine(trace_table)
        if tr.Fraction ~= 1.0 then closest_screen = nil end
    end
    perf_end("trace_screens")

    system_state.screen_interact_prev = system_state.screen_interact
    system_state.screen_interact = closest_screen
    system_state.num_commands = 0

    local active_panel = nil
    if closest_screen and IsValid(closest_screen.active_panel) then
        active_panel = closest_screen.active_panel
    end
    system_state.prev_active_panel = system_state.active_panel
    system_state.active_panel = active_panel

    if system_state.screen_interact_prev 
    and IsValid(system_state.prev_active_panel) then

        perf_start("vgui_update_hovered")
        update_hovered_panels(
            system_state.screen_interact_prev, 
            system_state.prev_active_panel, 
            false)
        perf_end("vgui_update_hovered")

    end

    if active_panel then

        perf_start("vgui_input")
        active_panel:SetMouseInputEnabled(true)
        active_panel:InvalidateLayout(true)

        update_hovered_panels(
            system_state.screen_interact, 
            active_panel, 
            true)

        vgui_enable_detours(true)

        local b,e = pcall(run_vgui_input)
        if not b then print(e) end

        active_panel:InvalidateLayout(true)
        perf_end("vgui_input")

    elseif IsValid(system_state.prev_active_panel) then

        system_state.captured_panels = {}

    end

    perf_start("pass_execute")
    run_pass(PASS_EXECUTE)
    perf_end("pass_execute")

    if active_panel then

        active_panel:SetMouseInputEnabled(false)

        vgui_enable_detours(false)

    end

    allocate_screen_rendertargets()

end

local rt_material = CreateMaterial(
    "screenatlasrt_material3", 
    "UnlitGeneric", 
    {
        ["$translucent"] = 1,
        ["$vertexcolor"] = 0,
    })

local mesh_begin = mesh.Begin
local mesh_pos = mesh.Position
local mesh_texcoord = mesh.TexCoord
local mesh_end = mesh.End
local mesh_advance = mesh.AdvanceVertex

local function draw_screen_textured_quad(state)

    local rt_id, rect = state.rt_id, state.rt_rect
    if not rt_id or not rect then return end

    local rt, rt_size = get_cached_rendertarget(rt_id)
    local x,y,w,h = rect.x, rect.y, rect.w, rect.h

    mesh_begin(MATERIAL_QUADS, 1)
    mesh_pos(unpack(state.w_vertices[1]))
    mesh_texcoord(0, x / rt_size, y / rt_size)
    mesh_advance()

    mesh_pos(unpack(state.w_vertices[2]))
    mesh_texcoord(0, (x + w) / rt_size, y / rt_size)
    mesh_advance()

    mesh_pos(unpack(state.w_vertices[3]))
    mesh_texcoord(0, (x + w) / rt_size, (y + h) / rt_size)
    mesh_advance()

    mesh_pos(unpack(state.w_vertices[4]))
    mesh_texcoord(0, (x) / rt_size, (y + h) / rt_size)
    mesh_advance()
    mesh_end()

end

local clear_color = Color(0,0,0,0)
local function draw_screens_to_rendertargets()

    if system_state.screen_index == 1 then return end

    perf_start("rt_render")

    -- draw each screen to its designated location 
    -- within its rendertarget
    local clear_bits = 0
    local main_rt = render.GetRenderTarget()
    local scr_w, scr_h = ScrW(), ScrH()
    local current_rt = main_rt
    for i=1, system_state.screen_index-1 do

        local state = screen_states[i]
        local rt_id, rect = state.rt_id, state.rt_rect
        if not rt_id then continue end

        -- update current rendertarget
        local rt = get_cached_rendertarget(rt_id)
        if rt ~= current_rt then
            current_rt = rt
            render.SetRenderTarget(current_rt)
        end

        -- clear rendertarget on its first write this frame
        local rt_bit = bit.lshift(1, state.rt_id-1)
        if bit.band(clear_bits, rt_bit) == 0 then
            render.Clear(0, 0, 0, 0)
            clear_bits = bit.bor(clear_bits, rt_bit)
        end

        -- work within allocated rectangle inside rendertarget
        -- for this screen
        render.SetViewPort(rect.x, rect.y, rect.w, rect.h)
        cam.Start2D()

        local old = DisableClipping( false )

        -- process drawing commands
        for j=state.first_command, state.last_command do
            process_command(system_state.command_list[j])
        end

        DisableClipping(old)

        cam.End2D()

        system_state.num_rendered = system_state.num_rendered + 1

    end

    if current_rt ~= main_rt then
        render.SetRenderTarget(main_rt)
        render.SetViewPort(0, 0, scr_w, scr_h)
    end

    perf_end("rt_render")

end

local function render_screens()

    perf_start("screen_render")

    render.SetMaterial(rt_material)
    local last_rt_texture = nil

    -- draw textured quads for each screen's sub-rectangle
    for i=1, system_state.screen_index-1 do

        local rt_size = RENDERTARGET_SIZE
        local state = screen_states[i]
        local rt_id, rect = state.rt_id, state.rt_rect
        if not rt_id then continue end

        local rt = get_cached_rendertarget(rt_id)
        local x,y,w,h = rect.x, rect.y, rect.w, rect.h
        if rt ~= last_rt_texture then
            last_rt_texture = rt
            rt_material:SetTexture("$basetexture", rt)
        end

        perf_start("screen_render_quad")
        draw_screen_textured_quad(state)
        perf_end("screen_render_quad")

    end

    perf_end("screen_render")

end

hook.Add("PreRender", "hi", function()

    system_state.sorted_perf_stats = {}

    for k,v in pairs(system_state.perf_stats) do
        local count = system_state.perf_stat_count[k]
        local depth = system_state.perf_stat_depth[k] or 0
        table.insert(system_state.sorted_perf_stats, {
            name = string.rep("-",depth) .. k, 
            time = v,
            count = count or 0
        })
    end

    table.sort(system_state.sorted_perf_stats, function(a,b)
        return a.name < b.name
    end)

    system_state.num_processed = 0
    system_state.num_rendered = 0
    system_state.num_render_passes = 0
    system_state.first_view = true
    system_state.perf_stats = {}
    system_state.perf_stat_count = {}
    --print("BEGIN RENDER:")

    perf_start("main")

    local view = render.GetViewSetup()
    process_screens(view)
    draw_screens_to_rendertargets()

    perf_end("main")

end)

hook.Add("PostDrawOpaqueRenderables", "hi", function()

    local view = render.GetViewSetup()
    if view.viewid == VIEW_3DSKY then return end
    --if view.viewid ~= 0 then return end

    system_state.num_render_passes = system_state.num_render_passes + 1

    --if system_state.first_view then process_screens(view) end

    perf_start("main")

    vgui_enable_detours(true)
    local b,e = pcall(render_screens, system_state.first_view)
    if not b then print(e) end
    vgui_enable_detours(false)

    system_state.first_view = false

    perf_end("main")

end)

hook.Add("HUDPaint", "hi", function()

    local y = 0
    local function count(name, num)
        draw.SimpleText(
            name .. ": " .. num,
            "DermaLarge",
            500, y)
        y = y + 30
    end

    count("Screens Processed", system_state.num_processed)
    count("Screens Rendered", system_state.num_rendered)
    count("Render Commands Queued", system_state.num_commands)
    count("Render Targets Used", system_state.num_render_targets)
    count("Render Passes", system_state.num_render_passes)

    for _,v in ipairs(system_state.sorted_perf_stats) do
        local t = v.time
        local tc = math.min(t * 100000, 255)
        surface.SetDrawColor(tc,255 - tc,0,255)
        surface.DrawRect(500, y, t * 100000, 15)
        draw.SimpleText(("%s: %0.2fms [%i]"):format(
            v.name, 
            t * 1000, 
            v.count), 
        "DermaDefault", 500, y)
        y = y + 15
    end

end)

local function handle_binds(ply, bind, pressed, code)

    local interact = system_state.screen_interact
    if not interact then return end

    if bind == "+attack" or bind == "+attack2" then

        if interact.capture_mouse then return true end

    elseif bind == "+use" then

        if interact.capture_use then return true end

    end

end

hook.Add("PlayerBindPress", "screens_handle_binds", handle_binds)

local function binding_to_key( bind )

    return input.GetKeyCode( input.LookupBinding(bind) )

end

local function handle_inputs()

    perf_start("handle_inputs")

    local k_use = input.IsKeyDown( binding_to_key("+use") )
    local k_attack1 = input.IsKeyDown( binding_to_key("+attack") )
    local k_attack2 = input.IsKeyDown( binding_to_key("+attack2") )
    local m_left = input.IsMouseDown(MOUSE_LEFT)
    local m_right = input.IsMouseDown(MOUSE_RIGHT)

    local interact = system_state.screen_interact
    system_state.down[1] = k_use

    if interact and interact.capture_mouse then
        system_state.down[1] = system_state.down[1] or k_attack1 or m_left
        system_state.down[2] = k_attack2 or m_right
    else
        system_state.down[2] = false
    end

    perf_end("handle_inputs")

end

hook.Add("Think", "screens_handle_inputs", handle_inputs)

__screen_SENT_classes = __screen_SENT_classes or {}
__screen_SENTS = __screen_SENTS or {}

local pending_refresh_entity_list = false

local function refresh_entity_list()

    __screen_SENTS = {}
    for _, ent in ents.Iterator() do
        local class = ent:GetClass()
        local func = __screen_SENT_classes[class]
        if not func then continue end
        __screen_SENTS[#__screen_SENTS+1] = {
            ent = ent,
            func = func,
        }
    end
    print("Refreshed " .. #__screen_SENTS .. " screen entities")

end

local function handle_register_entity(ent_table, class)

    if ent_table.ProcessScreens then
        __screen_SENT_classes[class] = ent_table.ProcessScreens
        print("REGISTER SCREEN ENTITY CLASS: " .. tostring(class))
        pending_refresh_entity_list = true
    else
        print("UNREGISTER SCREEN ENTITY CLASS: " .. tostring(class))
        __screen_SENT_classes[class] = nil
        pending_refresh_entity_list = true
    end

end

local function check_for_entity_list_refresh()

    if pending_refresh_entity_list then
        pending_refresh_entity_list = false
        refresh_entity_list()
    end

end

local function handle_entity_created(ent)

    if not IsValid(ent) then return end
    local func = __screen_SENT_classes[ent:GetClass()]
    if not func then return end
    if table.HasValue(__screen_SENTS, ent) then return end
    __screen_SENTS[#__screen_SENTS+1] = {
        ent = ent,
        func = func,
    }

end

local function handle_entity_removed(ent, full_update)

    if full_update then return end
    if not IsValid(ent) then return end
    for i=#__screen_SENTS, 1, -1 do
        if __screen_SENTS[i].ent ~= ent then continue end
        table.remove(__screen_SENTS, i) 
    end

end

local err_fmt = "Error on screen %s: \"%s\"\n"
local function handle_process_screens_ents(api)

    -- If waiting for a refresh, don't process screens
    if pending_refresh_entity_list then return end
    for i=1, #__screen_SENTS do
        local entry = __screen_SENTS[i]
        local ent = entry.ent
        local func = entry.func

        -- skip entities outside of PVS
        if ent:IsDormant() then continue end

        -- run the entity
        system_state.current_entity = ent
        local b,e = pcall( func, ent, api )
        if not b then 
            ErrorNoHalt(err_fmt:format(tostring(ent),  tostring(e))) 
        end
        system_state.current_entity = nil
    end

end

hook.Add("OnEntityCreated", "screens_entity_created", handle_entity_created)
hook.Add("EntityRemoved", "screens_entity_removed", handle_entity_removed)

hook.Add("PreRegisterSENT", "screens_register_sent", handle_register_entity)
hook.Add("Think", "screens_check_refresh", check_for_entity_list_refresh)
hook.Add("ProcessScreens", "screens_process_ents", handle_process_screens_ents)