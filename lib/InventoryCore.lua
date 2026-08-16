-- Shared read-only Gen III bag/PC inventory scanner.
-- All offsets come from the resolved game profile; quantities in the Bag are
-- decrypted with the live save key while PC item quantities are plain u16.

local Inventory={}
Inventory.__index=Inventory

local function validRam(address)
    return address and address>=0x02000000 and address<0x02040000
end

local function decodeText(emu,address,length)
    local chars={}
    for i=0,length-1 do
        local b=emu:read8(address+i)
        if b==0xFF then break
        elseif b==0 then chars[#chars+1]=" "
        elseif b>=0xA1 and b<=0xAA then chars[#chars+1]=string.char(48+b-0xA1)
        elseif b>=0xBB and b<=0xD4 then chars[#chars+1]=string.char(65+b-0xBB)
        elseif b>=0xD5 and b<=0xEE then chars[#chars+1]=string.char(97+b-0xD5)
        elseif b==0xAB then chars[#chars+1]="!"
        elseif b==0xAC then chars[#chars+1]="?"
        elseif b==0xAD then chars[#chars+1]="."
        elseif b==0xAE then chars[#chars+1]="-"
        elseif b==0xB4 then chars[#chars+1]="'"
        elseif b==0xB8 then chars[#chars+1]="," end
    end
    return table.concat(chars):gsub("%s+$","")
end

local function addCount(target,id,quantity)
    target[id]=(target[id] or 0)+quantity
end

function Inventory.new(config)
    assert(type(config)=="table" and config.emu and config.profile,"InventoryCore requires emu and profile")
    local profile=config.profile
    assert(profile.bagPockets and profile.items,"Inventory profile is missing bag pockets or the item table")
    return setmetatable({
        emu=config.emu,profile=profile,
        getSave1=config.getSave1,getSave2=config.getSave2,
        nameCache={},maxItemId=profile.maxItemId or 376,
    },Inventory)
end

function Inventory:_save1()
    local address=self.getSave1 and self.getSave1()
        or self.profile.save1
        or (self.profile.save1Ptr and self.emu:read32(self.profile.save1Ptr))
    return validRam(address) and address or nil
end

function Inventory:_save2()
    local address=self.getSave2 and self.getSave2()
        or self.profile.save2
        or (self.profile.save2Ptr and self.emu:read32(self.profile.save2Ptr))
    return validRam(address) and address or nil
end

function Inventory:_bagKey()
    if self.profile.bagKey~=nil then return self.profile.bagKey&0xFFFF end
    if not self.profile.bagKeyOffset then return 0 end
    local save2=self:_save2()
    return save2 and self.emu:read16(save2+self.profile.bagKeyOffset) or nil
end

function Inventory:itemName(id)
    id=tonumber(id) or 0
    if self.nameCache[id] then return self.nameCache[id] end
    local name=""
    if id>0 and id<=self.maxItemId then
        name=decodeText(self.emu,self.profile.items+id*44,14)
    end
    if name=="" then name="Item "..tostring(id) end
    self.nameCache[id]=name
    return name
end

function Inventory:itemPocket(id)
    id=tonumber(id) or 0
    if id<=0 or id>self.maxItemId then return nil end
    local pocket=self.emu:read8(self.profile.items+id*44+26)
    return self.profile.bagPockets[pocket] and pocket or nil
end

function Inventory:_entries(byId)
    local result={}
    for id,quantity in pairs(byId) do
        result[#result+1]={id=id,name=self:itemName(id),quantity=quantity}
    end
    table.sort(result,function(a,b)
        if a.name==b.name then return a.id<b.id end
        return a.name<b.name
    end)
    return result
end

function Inventory:scanBag()
    local save1,key=self:_save1(),self:_bagKey()
    if not save1 or key==nil then
        return {ready=false,error="save unavailable",usedSlots=0,totalSlots=0,totalQuantity=0,byId={},items={},pockets={}}
    end
    local result={ready=true,usedSlots=0,totalSlots=0,totalQuantity=0,byId={},pockets={}}
    for pocketId=1,5 do
        local pocket=self.profile.bagPockets[pocketId]
        if pocket then
            local summary={id=pocketId,name=pocket.name or ("Pocket "..pocketId),usedSlots=0,totalSlots=pocket.capacity,totalQuantity=0,byId={}}
            result.totalSlots=result.totalSlots+pocket.capacity
            for slot=0,pocket.capacity-1 do
                local address=save1+pocket.offset+slot*4
                local id=self.emu:read16(address)
                local quantity=(self.emu:read16(address+2)~key)&0xFFFF
                if id>0 and id<=self.maxItemId and quantity>0 then
                    summary.usedSlots=summary.usedSlots+1
                    summary.totalQuantity=summary.totalQuantity+quantity
                    result.usedSlots=result.usedSlots+1
                    result.totalQuantity=result.totalQuantity+quantity
                    addCount(summary.byId,id,quantity)
                    addCount(result.byId,id,quantity)
                end
            end
            summary.items=self:_entries(summary.byId)
            result.pockets[pocketId]=summary
        end
    end
    result.items=self:_entries(result.byId)
    return result
end

function Inventory:scanPc()
    local save1=self:_save1()
    local offset,capacity=self.profile.pcItemsOffset,self.profile.pcItemsCapacity
    if not save1 or not offset or not capacity then
        return {ready=false,error="PC storage unavailable",usedSlots=0,totalSlots=capacity or 0,totalQuantity=0,byId={},items={}}
    end
    local result={ready=true,usedSlots=0,totalSlots=capacity,totalQuantity=0,byId={}}
    for slot=0,capacity-1 do
        local address=save1+offset+slot*4
        local id,quantity=self.emu:read16(address),self.emu:read16(address+2)
        if id>0 and id<=self.maxItemId and quantity>0 then
            result.usedSlots=result.usedSlots+1
            result.totalQuantity=result.totalQuantity+quantity
            addCount(result.byId,id,quantity)
        end
    end
    result.items=self:_entries(result.byId)
    return result
end

function Inventory:snapshot()
    local bag,pc=self:scanBag(),self:scanPc()
    local combined={}
    for id,quantity in pairs(bag.byId) do addCount(combined,id,quantity) end
    for id,quantity in pairs(pc.byId) do addCount(combined,id,quantity) end
    return {ready=bag.ready,bag=bag,pc=pc,byId=combined,items=self:_entries(combined)}
end

function Inventory:bagQuantity(itemId)
    return self:scanBag().byId[tonumber(itemId) or 0] or 0
end

function Inventory:tracked(itemIds,includeZero)
    local bag=self:scanBag()
    local result={}
    for _,id in ipairs(itemIds or {}) do
        local quantity=bag.byId[id] or 0
        if includeZero or quantity>0 then result[#result+1]={id=id,name=self:itemName(id),quantity=quantity} end
    end
    return result,bag
end

return Inventory
