-- Roaming-Pokemon save structure reader and validation.

local Roamer={}
Roamer.__index=Roamer
local IDS={Latias=380,Latios=381,Raikou=243,Entei=244,Suicune=245}
local HOENN_IDS={Latias=407,Latios=408}

function Roamer.new(options)
    return setmetatable({emu=options.emu,game=options.game,save1=options.save1,shinyValue=options.shinyValue},Roamer)
end
function Roamer:address()
    local base=self.save1(); return base and (base+self.game.roamerOffset) or nil
end
function Roamer:read()
    local address=self:address(); if not address then return nil end
    local rawIvs=self.emu:read32(address)
    return {
        address=address,ivs=rawIvs,pid=self.emu:read32(address+4),species=self.emu:read16(address+8),
        level=self.emu:read8(address+0xA),hp=self.emu:read16(address+0xE),status=self.emu:read8(address+0x10),
        active=self.emu:read8(address+0x13)==1,buggedIvs=self.game.buggedRoamer==true
    }
end
function Roamer:expectedSpecies(index)
    local name=self.game.roamers[index or 1]
    return (not self.game.frlgMapAttributes and HOENN_IDS[name]) or IDS[name],name
end
function Roamer:preflight(index)
    local current=self:read()
    if not current then return false,"Load the save so the roamer data can be read." end
    if current.active then
        return false,string.format("A roamer already exists (PID %08X). Use a save from before it was released.",current.pid)
    end
    local species,name=self:expectedSpecies(index)
    if not species then return false,"The selected roamer is not available in this game." end
    return true,"Ready to create shiny "..name.."."
end
function Roamer:matches(index,pid,tid,sid)
    local current=self:read(); local species=self:expectedSpecies(index)
    return current and current.active and current.species==species and current.pid==pid
        and self.shinyValue(tid,sid,current.pid)<8,current
end

return Roamer
