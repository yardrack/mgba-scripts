local root=assert((...),"suite root required")
STARTER_HUNTER_DIR=root
local Profiles=dofile(root.."/lib/GameProfiles.lua")
local Inventory=dofile(root.."/lib/InventoryCore.lua")
local ItemStorage=dofile(root.."/lib/ItemStorage.lua")

local function memoryEmu()
    local mem={}
    local function r8(a) return mem[a] or 0 end
    local function w8(a,v) mem[a]=v&0xFF end
    local emu={}
    function emu:read8(a) return r8(a) end
    function emu:read16(a) return r8(a)|(r8(a+1)<<8) end
    function emu:read32(a) return (self:read16(a)|(self:read16(a+2)<<16))&0xFFFFFFFF end
    function emu:write8(a,v) w8(a,v) end
    function emu:write16(a,v) w8(a,v); w8(a+1,v>>8) end
    function emu:write32(a,v) self:write16(a,v); self:write16(a+2,v>>16) end
    return emu,mem
end

local cases={{"BPEE",0},{"AXVE",0},{"AXVE",1},{"AXVE",2},{"AXPE",0},{"AXPE",1},{"AXPE",2},{"BPRE",0},{"BPRE",1},{"BPGE",0},{"BPGE",1}}
local scenarios=0
for _,case in ipairs(cases) do
    local code,revision=case[1],case[2]
    local p=Profiles.resolve(code,revision)
    local emu=memoryEmu()
    local save1,save2=0x02010000,0x02030000
    if p.save1 then save1=p.save1 else emu:write32(p.save1Ptr,save1) end
    if p.save2 then save2=p.save2 else emu:write32(p.save2Ptr,save2) end
    local key=p.bagKey or (p.family=="RS" and 0 or 0x5A5A)
    if p.bagKeyOffset then emu:write16(save2+p.bagKeyOffset,key) end

    -- Confirm item-table routing for every family-specific pocket number.
    for pocketId=1,5 do
        local id=20+pocketId
        emu:write8(p.items+id*44+26,pocketId)
    end
    local inventory=Inventory.new({emu=emu,profile=p})
    for pocketId=1,5 do assert(inventory:itemPocket(20+pocketId)==pocketId,code.." item routing") end

    -- Fill every bag slot. Key items and one HM are protected; all other
    -- stacks must be evacuated to the PC when depositAll is requested.
    local movable,protected=0,0
    for pocketId=1,5 do
        local pocket=p.bagPockets[pocketId]
        for slot=0,pocket.capacity-1 do
            local id=10
            if pocket.protected then id=50
            elseif pocketId==3 and slot==0 then id=339 end
            local address=save1+pocket.offset+slot*4
            emu:write16(address,id); emu:write16(address+2,1~key)
            if pocket.protected or id==339 then protected=protected+1 else movable=movable+1 end
        end
    end
    local before=inventory:scanBag()
    assert(before.ready and before.usedSlots==before.totalSlots,code.." bag fixture is not full")
    local storage=ItemStorage.new({
        emu=emu,getSave1=function() return save1 end,getBagKey=function() return key end,
        pockets=p.bagPockets,pcOffset=p.pcItemsOffset,pcCapacity=p.pcItemsCapacity,splitPcStacks=p.pcSplitStacks,
        protectItem=function(id,pocketId) return p.bagPockets[pocketId].protected==true or (id>=339 and id<=346) end,
    })
    local ok,summary=storage:depositAll(1)
    assert(ok and summary.quantity==movable and summary.slots==movable,code.." full bag evacuation failed")
    local after,pc=inventory:scanBag(),inventory:scanPc()
    assert(after.usedSlots==protected and (after.byId[10] or 0)==0,code.." movable bag data remained")
    assert((after.byId[50] or 0)+(after.byId[339] or 0)==protected,code.." protected data moved")
    assert(pc.byId[10]==movable and pc.totalQuantity==movable,code.." PC quantities wrong")
    scenarios=scenarios+1

    -- A completely full PC must leave a full bag byte-for-byte unchanged.
    local emu2,mem2=memoryEmu()
    local s1,s2=0x02010000,0x02030000
    if p.save1 then s1=p.save1 else emu2:write32(p.save1Ptr,s1) end
    if p.save2 then s2=p.save2 else emu2:write32(p.save2Ptr,s2) end
    if p.bagKeyOffset then emu2:write16(s2+p.bagKeyOffset,key) end
    local first=p.bagPockets[1]
    for slot=0,first.capacity-1 do
        emu2:write16(s1+first.offset+slot*4,10); emu2:write16(s1+first.offset+slot*4+2,1~key)
    end
    for slot=0,p.pcItemsCapacity-1 do
        emu2:write16(s1+p.pcItemsOffset+slot*4,100+slot); emu2:write16(s1+p.pcItemsOffset+slot*4+2,999)
    end
    local snapshot={}; for address,value in pairs(mem2) do snapshot[address]=value end
    local storage2=ItemStorage.new({emu=emu2,getSave1=function() return s1 end,getBagKey=function() return key end,
        pockets=p.bagPockets,pcOffset=p.pcItemsOffset,pcCapacity=p.pcItemsCapacity,splitPcStacks=p.pcSplitStacks,
        protectItem=function(id,pocketId) return p.bagPockets[pocketId].protected==true or (id>=339 and id<=346) end})
    assert(not storage2:depositAll(1),code.." full PC unexpectedly accepted bag")
    for address,value in pairs(snapshot) do assert(mem2[address]==value,code.." full-PC path partially mutated memory") end
    scenarios=scenarios+1
end
print(string.format("PASS inventory/storage: %d full-bag and full-PC scenarios across %d ROM profiles",scenarios,#cases))
