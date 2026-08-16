-- Atomic Gen III bag-pocket deposits into the PC item storage.
-- Bag quantities may be XOR encrypted; PC quantities are always plain u16.

local ItemStorage={}
ItemStorage.__index=ItemStorage

local function copySlots(source)
    local result={}
    for i,slot in ipairs(source) do result[i]={id=slot.id,quantity=slot.quantity} end
    return result
end

function ItemStorage.new(config)
    assert(type(config)=="table" and config.emu,"ItemStorage requires an emulator")
    assert(type(config.pockets)=="table" and config.pcOffset and config.pcCapacity,"ItemStorage layout is incomplete")
    return setmetatable({
        emu=config.emu,getSave1=config.getSave1,getBagKey=config.getBagKey,
        pockets=config.pockets,pcOffset=config.pcOffset,pcCapacity=config.pcCapacity,
        splitPcStacks=config.splitPcStacks~=false,protectItem=config.protectItem,
    },ItemStorage)
end

function ItemStorage:readSlots(base,offset,capacity,key)
    local slots={}
    for i=0,capacity-1 do
        local address=base+offset+i*4
        slots[i+1]={id=self.emu:read16(address),quantity=self.emu:read16(address+2)~(key or 0)}
    end
    return slots
end

function ItemStorage:writeSlots(base,offset,slots,key)
    for i,slot in ipairs(slots) do
        local address=base+offset+(i-1)*4
        self.emu:write16(address,slot.id)
        self.emu:write16(address+2,slot.quantity~(key or 0))
    end
end

function ItemStorage:addPc(plan,itemId,count)
    if itemId==0 or count<=0 then return true end
    for _,slot in ipairs(plan) do
        if slot.id==itemId then
            local room=999-slot.quantity
            if count<=room then slot.quantity=slot.quantity+count; return true end
            if not self.splitPcStacks then return false end
            slot.quantity=999
            count=count-room
        end
    end
    for _,slot in ipairs(plan) do
        if slot.id==0 then
            local added=math.min(999,count)
            slot.id,slot.quantity=itemId,added
            count=count-added
            if count==0 then return true end
        end
    end
    return false
end

function ItemStorage:depositPocket(pocketId)
    local pocket=self.pockets[pocketId]
    local save1=self.getSave1 and self.getSave1() or nil
    if not pocket or not save1 or save1<0x02000000 or save1>=0x02040000 then
        return false,{error="save unavailable"}
    end
    local key=self.getBagKey and self.getBagKey() or 0
    local bag=self:readSlots(save1,pocket.offset,pocket.capacity,key)
    local pc=self:readSlots(save1,self.pcOffset,self.pcCapacity,0)
    local plan=copySlots(pc)
    local kept,movedSlots,movedQuantity={},0,0

    for _,slot in ipairs(bag) do
        local protected=slot.id~=0 and self.protectItem and self.protectItem(slot.id,pocketId)
        if slot.id==0 or slot.quantity==0 then
            -- Empty and corrupt zero-quantity slots are normalized on commit.
        elseif protected then
            kept[#kept+1]={id=slot.id,quantity=slot.quantity}
        else
            local trial=copySlots(plan)
            if self:addPc(trial,slot.id,slot.quantity) then
                plan=trial
                movedSlots=movedSlots+1
                movedQuantity=movedQuantity+slot.quantity
            else
                kept[#kept+1]={id=slot.id,quantity=slot.quantity}
            end
        end
    end
    if movedSlots==0 then return false,{error="PC item storage is full",pocketId=pocketId} end

    local compact={}
    for i=1,pocket.capacity do compact[i]=kept[i] or {id=0,quantity=0} end
    -- Commit only after the entire transfer has been proven to fit.
    self:writeSlots(save1,self.pcOffset,plan,0)
    self:writeSlots(save1,pocket.offset,compact,key)
    return true,{pocketId=pocketId,slots=movedSlots,quantity=movedQuantity}
end

function ItemStorage:depositAll(preferredPocket)
    local order,seen={},{}
    if self.pockets[preferredPocket] then order[#order+1]=preferredPocket; seen[preferredPocket]=true end
    local ids={}; for pocketId in pairs(self.pockets) do ids[#ids+1]=pocketId end; table.sort(ids)
    for _,pocketId in ipairs(ids) do if not seen[pocketId] then order[#order+1]=pocketId end end
    local total={pockets=0,slots=0,quantity=0,byPocket={}}
    for _,pocketId in ipairs(order) do
        local moved,summary=self:depositPocket(pocketId)
        if moved then
            total.pockets=total.pockets+1
            total.slots=total.slots+summary.slots
            total.quantity=total.quantity+summary.quantity
            total.byPocket[pocketId]=summary
        end
    end
    if total.slots==0 then return false,{error="PC item storage is full or the Bag has no movable items"} end
    return true,total
end

return ItemStorage
