
AddCSLuaFile()

DEFINE_BASECLASS( "base_anim" )

ENT.PrintName = "Screen Test"
ENT.Author = "Kaz"
ENT.Information = "Testing Screens"
ENT.Category = "#spawnmenu.category.fun_games"

ENT.Editable = false
ENT.Spawnable = true
ENT.AdminOnly = false
ENT.RenderGroup = RENDERGROUP_OPAQUE

function ENT:Initialize()

    if SERVER then
        self:SetModel( "models/blacknecro/tv_plasma_4_3.mdl" )
        self:PhysicsInit(SOLID_VPHYSICS)
    end

end

function ENT:GetOrCreateGUI()

    if not IsValid(self.vgui) then
        self.vgui = vgui.Create("DPanel")
        local btn = vgui.Create("DButton", self.vgui)
        btn:SetText("PRESS")
        btn:Dock(FILL)
        local btn = vgui.Create("DButton", self.vgui)
        btn:SetText("DO NOT PRESS")
        btn:Dock(BOTTOM)
    end
    return self.vgui

end

function ENT:OnRemove(full_update)

    if IsValid(self.vgui) then 
        self.vgui:Remove()
        self.vgui = nil
    end

end

function ENT:Draw()

    self:DrawModel()

end

function ENT:ProcessScreens(s)

    local t = CurTime()
    if s.start(self:GetPos(), self:GetAngles(), 56, 43) then
        s.set_res(400,200)
        s.set_anchor(0.5,0.5,0.5)

        local w,h = s.get_res()
        s.vgui(self:GetOrCreateGUI())
        s.set_color(0,0,0,200)
        s.rect(0,0,w,h)
    end
    s.finish()

end