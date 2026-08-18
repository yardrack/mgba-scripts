-- Standalone Emerald Pickup farmer for normal mGBA.
-- P starts/stops. It reuses BattleCore for encounters and quietly moves items
-- found by Pickup into the Bag after each won battle. The strongest healthy
-- battler stays in front while healthy Pickup Pokemon share battle experience.

local code=GEN3_GAME_CODE or tostring(emu:getGameCode()):sub(-4)
if code~="BPEE" then return end

local suiteDir=GEN3_SUITE_DIR or (script and script.dir)
if not suiteDir then error("Load Pickup.lua instead of lib/PickupCore.lua directly.") end
local frameClock=GEN3_FRAME_CLOCK or dofile(suiteDir.."/lib/FrameClock.lua")
local ItemStorage=dofile(suiteDir.."/lib/ItemStorage.lua")
local PickupFilter=dofile(suiteDir.."/lib/PickupFilter.lua")
local InventoryCore=dofile(suiteDir.."/lib/InventoryCore.lua")
local gameData=dofile(suiteDir.."/lib/GameProfiles.lua")
local game=assert(gameData.resolve(code,emu:read8(0x080000BC)),"No Emerald memory profile")
local stats=GEN3_SESSION_STATS or dofile(suiteDir.."/lib/SessionStats.lua").forGame(emu,"BPEE")

local PARTY_COUNT,PARTY=0x020244E9,0x020244EC
local SAVE1_PTR,SAVE2_PTR=0x03005D8C,0x03005D90
local PARTY_SIZE,SPECIES_INFO,SPECIES_NAMES,ITEMS=0x64,0x083203CC,0x083185C8,0x085839A0
local ABILITY_PICKUP=53

local panel
if EMERALD_AUTOMATION_HEADLESS then
    panel={setSize=function() end,clear=function() end,print=function() end}
else
    panel=console:createBuffer("Pickup")
end
panel:setSize(64,26)

local enabled=false
local status="Stand on a wild encounter tile, then press P."
local totalItems=0
local itemCounts={}
local lastItem="None yet"
local depositedSlots,depositedQuantity=0,0
local discardedItems=0
local filter=PickupFilter.new(PICKUP_FILTER_MODE or "All")
local lastText=""
local lastRenderClock=0
local frames=0

-- Exact Emerald Pickup tables from battle_script_commands.c. A Pickup mon has
-- a 10% chance after a won battle; its level band then selects from these.
local PICKUP_ITEMS={13,14,22,3,86,85,75,23,2,21,68,64,24,63,19,25,69,37}
local RARE_PICKUP_ITEMS={21,110,187,19,34,180,332,36,289,200,314}

local SUBSTRUCT_ORDER={
    {0,1,2,3},{0,1,3,2},{0,2,1,3},{0,3,1,2},{0,2,3,1},{0,3,2,1},
    {1,0,2,3},{1,0,3,2},{2,0,1,3},{3,0,1,2},{2,0,3,1},{3,0,2,1},
    {1,2,0,3},{1,3,0,2},{2,1,0,3},{3,1,0,2},{2,3,0,1},{3,2,0,1},
    {1,2,3,0},{1,3,2,0},{2,1,3,0},{3,1,2,0},{2,3,1,0},{3,2,1,0}
}

local POCKETS=game.bagPockets

local storage=ItemStorage.new({
    emu=emu,
    getSave1=function() return emu:read32(SAVE1_PTR) end,
    getBagKey=function()
        local address=emu:read32(SAVE2_PTR)
        return address>=0x02000000 and address<0x02040000 and emu:read16(address+0xAC) or 0
    end,
    pockets=POCKETS,pcOffset=game.pcItemsOffset,pcCapacity=game.pcItemsCapacity,splitPcStacks=game.pcSplitStacks,
    protectItem=function(itemId,pocketId)
        return (POCKETS[pocketId] and POCKETS[pocketId].protected==true) or (itemId>=339 and itemId<=346)
    end,
})
local inventory=InventoryCore.new({emu=emu,profile=game})

local function decodeText(address,length)
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
        elseif b==0xB8 then chars[#chars+1]=","
        elseif b==0xB4 then chars[#chars+1]="'" end
    end
    return table.concat(chars):gsub("%s+$","")
end

local function speciesName(id)
    local name=decodeText(SPECIES_NAMES+(id or 0)*11,11)
    return name~="" and name or ("Species "..tostring(id or 0))
end

local function itemName(id)
    return inventory:itemName(id)
end

local function partyCount()
    return math.min(6,emu:read8(PARTY_COUNT))
end

local function readMon(slot)
    if slot<0 or slot>=partyCount() then return nil end
    local address=PARTY+slot*PARTY_SIZE
    local pid,ot=emu:read32(address),emu:read32(address+4)
    if pid==0 and ot==0 then return nil end
    local order=SUBSTRUCT_ORDER[(pid%24)+1]
    local key=pid~ot
    local growthIndex,miscIndex=order[1],order[4]
    local growth=emu:read32(address+0x20+growthIndex*12)~key
    local miscIvs=emu:read32(address+0x20+miscIndex*12+4)~key
    local species,item=growth&0xFFFF,(growth>>16)&0xFFFF
    local abilityNum=(miscIvs>>31)&1
    local ability=emu:read8(SPECIES_INFO+species*28+0x16+abilityNum)
    return {
        slot=slot,address=address,pid=pid,ot=ot,key=key,order=order,
        growthIndex=growthIndex,species=species,item=item,ability=ability,
        level=emu:read8(address+0x54),hp=emu:read16(address+0x56),maxHp=emu:read16(address+0x58)
    }
end

local function writeGrowth(mon,species,item)
    local decrypted={}
    for i=0,11 do decrypted[i]=emu:read32(mon.address+0x20+i*4)~mon.key end
    local wordIndex=mon.growthIndex*3
    decrypted[wordIndex]=((item or 0)&0xFFFF)<<16|((species or mon.species)&0xFFFF)
    local checksum=0
    for i=0,11 do
        local word=decrypted[i]
        checksum=(checksum+(word&0xFFFF)+((word>>16)&0xFFFF))&0xFFFF
        emu:write32(mon.address+0x20+i*4,word~mon.key)
    end
    emu:write16(mon.address+0x1C,checksum)
end

local function pickupMons()
    local result={}
    for slot=0,partyCount()-1 do
        local mon=readMon(slot)
        if mon and mon.ability==ABILITY_PICKUP then result[#result+1]=mon end
    end
    return result
end
local function pickupBattlers()
    local result={}
    for _,mon in ipairs(pickupMons()) do
        if mon.species==288 or mon.species==289 then result[#result+1]=mon end
    end
    return result
end

local function bagQuantity(itemId)
    local save1,save2=emu:read32(SAVE1_PTR),emu:read32(SAVE2_PTR)
    local pocketId=emu:read8(ITEMS+itemId*44+26)
    local pocket=POCKETS[pocketId]
    if not pocket or save1<0x02000000 or save1>=0x02040000 or save2<0x02000000 or save2>=0x02040000 then return nil end
    local key=emu:read16(save2+0xAC)
    local total=0
    for i=0,pocket.capacity-1 do
        local address=save1+pocket.offset+i*4
        if emu:read16(address)==itemId then total=total+(emu:read16(address+2)~key) end
    end
    return total
end

local function addBagItem(itemId)
    local save1,save2=emu:read32(SAVE1_PTR),emu:read32(SAVE2_PTR)
    local pocketId=emu:read8(ITEMS+itemId*44+26)
    local pocket=POCKETS[pocketId]
    if not pocket or save1<0x02000000 or save1>=0x02040000 or save2<0x02000000 or save2>=0x02040000 then return false end
    local key=emu:read16(save2+0xAC)
    local empty=nil
    for i=0,pocket.capacity-1 do
        local address=save1+pocket.offset+i*4
        local id=emu:read16(address)
        if id==itemId then
            local quantity=emu:read16(address+2)~key
            if quantity<pocket.stack then
                emu:write16(address+2,(quantity+1)~key)
                return true
            elseif not pocket.split then
                return false
            end
        elseif id==0 and not empty then
            empty=address
        end
    end
    if not empty then return false end
    emu:write16(empty,itemId)
    emu:write16(empty+2,1~key)
    return true
end

local function collectItems()
    local collected,deposited,discarded=0,0,0
    for _,mon in ipairs(pickupMons()) do
        if mon.item~=0 then
            local name=itemName(mon.item)
            if not filter:accepts(mon.item) then
                writeGrowth(mon,mon.species,0)
                discardedItems=discardedItems+1
                discarded=discarded+1
                stats:inc("Pickup","discarded",1)
                lastItem="Discarded "..name.." from "..speciesName(mon.species)
                goto continue
            end
            local added=addBagItem(mon.item)
            if not added then
                local pocketId=emu:read8(ITEMS+mon.item*44+26)
                local moved,summary=storage:depositAll(pocketId)
                if moved then
                    depositedSlots=depositedSlots+summary.slots
                    depositedQuantity=depositedQuantity+summary.quantity
                    deposited=deposited+summary.slots
                    stats:inc("Pickup","deposited",summary.quantity)
                    added=addBagItem(mon.item)
                end
            end
            if not added then
                status="Bag full: could not take "..name.." from party slot "..(mon.slot+1).."."
                return false,collected
            end
            writeGrowth(mon,mon.species,0)
            totalItems=totalItems+1
            collected=collected+1
            stats:inc("Pickup","items",1)
            itemCounts[mon.item]=(itemCounts[mon.item] or 0)+1
            lastItem=name.." from "..speciesName(mon.species)
        end
        ::continue::
    end
    if collected>0 or discarded>0 then
        status=deposited>0
            and string.format("Deposited %d bag stack%s in the PC, then collected %d Pickup item%s.",
                deposited,deposited==1 and "" or "s",collected,collected==1 and "" or "s")
            or string.format("Kept %d and discarded %d Pickup item%s.",collected,discarded,(collected+discarded)==1 and "" or "s")
    end
    return true,collected
end

local function possibleItems()
    local ids,seen={},{}
    local minLevel,maxLevel=nil,nil
    for _,mon in ipairs(pickupMons()) do
        local level=math.max(1,math.min(100,mon.level or 1))
        minLevel=not minLevel and level or math.min(minLevel,level)
        maxLevel=not maxLevel and level or math.max(maxLevel,level)
        local tier=math.min(9,math.floor((level-1)/10))
        for offset=0,8 do
            local id=PICKUP_ITEMS[tier+offset+1]
            if id and not seen[id] then seen[id]=true; ids[#ids+1]=id end
        end
        for offset=0,1 do
            local id=RARE_PICKUP_ITEMS[tier+offset+1]
            if id and not seen[id] then seen[id]=true; ids[#ids+1]=id end
        end
    end
    table.sort(ids,function(a,b) return itemName(a)<itemName(b) end)
    return ids,minLevel,maxLevel
end

local function wrappedItemLines(label,entries,width)
    local lines,current={},label
    if #entries==0 then return {label.."none"} end
    for _,entry in ipairs(entries) do
        local piece=(current==label and "" or ", ")..entry
        if #current+#piece>width and current~=label then
            lines[#lines+1]=current
            current="  "..entry
        else
            current=current..piece
        end
    end
    lines[#lines+1]=current
    return lines
end

local PICKUP_TRACKED_IDS={68,69,110,180,187,200,289,314,332}
local PICKUP_ALL_IDS={}
do
    local seen={}
    for _,id in ipairs(PICKUP_ITEMS) do if not seen[id] then seen[id]=true; PICKUP_ALL_IDS[#PICKUP_ALL_IDS+1]=id end end
    for _,id in ipairs(RARE_PICKUP_ITEMS) do if not seen[id] then seen[id]=true; PICKUP_ALL_IDS[#PICKUP_ALL_IDS+1]=id end end
end
local function bagInventoryEntries(bag)
    local entries,seen={},{}
    for _,id in ipairs(PICKUP_TRACKED_IDS) do
        seen[id]=true
        entries[#entries+1]=string.format("%s x%d",itemName(id),bag.byId[id] or 0)
    end
    for _,id in ipairs(PICKUP_ALL_IDS) do
        if not seen[id] and (bag.byId[id] or 0)>0 then
            entries[#entries+1]=string.format("%s x%d",itemName(id),bag.byId[id])
        end
    end
    return entries
end

local function pickedItemEntries()
    local values={}
    for id,count in pairs(itemCounts) do values[#values+1]={id=id,count=count,name=itemName(id)} end
    table.sort(values,function(a,b) return a.count==b.count and a.name<b.name or a.count>b.count end)
    local result={}
    for _,value in ipairs(values) do result[#result+1]=value.name.." x"..value.count end
    return result
end

local function partyLines()
    local mons=pickupMons()
    if #mons==0 then return {"No party Pokemon currently has Pickup."},0 end
    local lines={}
    for _,mon in ipairs(mons) do
        local held=mon.item~=0 and itemName(mon.item) or "empty"
        local marker=mon.slot==0 and ">" or " "
        lines[#lines+1]=string.format("%s%d. %-10s Lv%-3d  Held: %s",marker,mon.slot+1,speciesName(mon.species),mon.level,held)
    end
    return lines,#mons
end

local function render(force)
    local now=os.clock()
    if not force and now-lastRenderClock<0.20 then return end
    lastRenderClock=now
    local battle=Battle and Battle:getState() or {active=false,battlesWon=0}
    local _,count=partyLines()
    local bag=inventory:scanBag()
    local possible,minLevel,maxLevel=possibleItems()
    local possibleNames={}
    for _,id in ipairs(possible) do possibleNames[#possibleNames+1]=itemName(id) end
    local levelText=minLevel and (minLevel==maxLevel and ("Lv"..minLevel) or ("Lv"..minLevel.."-"..maxLevel)) or "no Pickup mon"
    local lines={"PICKUP | Emerald  |  "..(enabled and battle.active and "RUNNING" or "READY"),
        string.format("Party: %d Pickup   Wins: %d   Collected: %d",count,battle.battlesWon or 0,totalItems),
        string.format("Self-recoveries: %d   Trigger: HP <= %d%% or PP <= %d",battle.selfRecoveries or 0,battle.healPercent or 20,battle.ppRecoverThreshold or 3),
        bag.ready and string.format("Bag: %d items (%d/%d slots)",bag.totalQuantity,bag.usedSlots,bag.totalSlots) or "Bag: unavailable",
        string.format("Keep: %s   Discarded: %d",filter:name(),discardedItems),
        string.format("PC deposits: %d stacks / %d items",depositedSlots,depositedQuantity),
        string.format("Time: %s   Items/hour: %.1f",stats:formatElapsed("Pickup"),stats:rate("Pickup","items")),
        "P start/stop   F filter   C collect now   X clear totals",""}
    if bag.ready then
        for _,line in ipairs(wrappedItemLines("Bag counts: ",bagInventoryEntries(bag),62)) do lines[#lines+1]=line end
        lines[#lines+1]=""
    end
    for _,line in ipairs(wrappedItemLines("Can pick up ("..levelText.."): ",possibleNames,62)) do lines[#lines+1]=line end
    lines[#lines+1]=""
    for _,line in ipairs(wrappedItemLines("Picked up: ",pickedItemEntries(),62)) do lines[#lines+1]=line end
    lines[#lines+1]="Last: "..lastItem
    lines[#lines+1]=""
    lines[#lines+1]=status
    local text=table.concat(lines,"\n")
    if force or text~=lastText then panel:clear(); panel:print(text); lastText=text end
end

local function stop(message)
    if Battle and Battle:getState().active then Battle:stop() end
    stats:stop("Pickup")
    enabled=false
    status=message or "Stopped. Press P to start again."
    render(true)
end

local function start()
    if enabled then stop(); return end
    if not Battle then status="Battle tool is not loaded."; render(true); return end
    if Battle:getState().active then status="Stop Battle before starting Pickup."; render(true); return end
    local mons=pickupMons()
    if #pickupBattlers()==0 then status="Put a Zigzagoon or Linoone with Pickup in the party first."; render(true); return end
    stats:start("Pickup",true)
    local ok=collectItems()
    if not ok then stats:stop("Pickup"); render(true); return end
    Battle:setMode("Pickup")
    Battle:setHealPercent(20)
    enabled=true
    Battle:start()
    if not Battle:getState().active then
        enabled=false
        status=Battle:getState().status
    else
        status=string.format("Running with %d Pickup Pokemon. Self-recovers HP/status/PP at 20%% HP or 3 PP.",#mons)
    end
    render(true)
end

local function onKey(event)
    if GEN3_SUITE_MANAGED then return end
    if event.state~=1 or ((event.modifiers or 0)&0xC)~=0 or event.key<32 or event.key>126 then return end
    local key=string.char(event.key):lower()
    if key=="p" then start()
    elseif key=="f" then
        status="Pickup keep filter: "..filter:cycle().."."
        render(true)
    elseif key=="c" and not enabled then collectItems(); render(true)
    elseif key=="x" and not enabled then
        totalItems,itemCounts,lastItem,depositedSlots,depositedQuantity,discardedItems=0,{},"None yet",0,0,0
        stats:reset("Pickup")
        status="Pickup totals cleared."
        render(true)
    end
end

Pickup={}
function Pickup:onBattleFinished()
    if not enabled then return true end
    local ok=collectItems()
    render(true)
    return ok
end
function Pickup:getStatus() return status end
function Pickup:isRunning() return enabled end
function Pickup:experienceMask()
    if not enabled then return 0 end
    local mask=0
    for _,mon in ipairs(pickupMons()) do
        if mon.hp>0 then mask=mask|(1<<mon.slot) end
    end
    return mask
end
function Pickup:getState()
    local _,count=partyLines()
    local possible=possibleItems()
    local battle=Battle and Battle:getState() or {}
    return {enabled=enabled,status=status,totalItems=totalItems,lastItem=lastItem,pickupCount=count,itemCounts=itemCounts,
        possibleItems=possible,depositedSlots=depositedSlots,depositedQuantity=depositedQuantity,
        filter=filter:name(),discardedItems=discardedItems,selfRecoveries=battle.selfRecoveries or 0,
        ppRecoverThreshold=battle.ppRecoverThreshold or 3,session=stats:snapshot("Pickup")}
end
function Pickup:start() start(); return enabled end
function Pickup:stop() stop(); return true end
function Pickup:collect() local ok,count=collectItems(); render(true); return ok,count end
function Pickup:clearTotals()
    totalItems,itemCounts,lastItem,depositedSlots,depositedQuantity,discardedItems=0,{},"None yet",0,0,0
    stats:reset("Pickup"); status="Pickup totals cleared."; render(true); return true
end
function Pickup:setFilter(value)
    local ok,name=filter:set(value)
    status=ok and ("Pickup keep filter: "..name..".") or ("Unknown Pickup filter; keeping "..name..".")
    render(true)
    return ok,name
end
function Pickup:cycleFilter() local name=filter:cycle(); status="Pickup keep filter: "..name.."."; render(true); return name end
function Pickup:getFilters() return filter:names() end
function Pickup:testFilterItem(itemId) if not PICKUP_ENABLE_TEST_API then return nil end; return filter:accepts(itemId) end
function Pickup:testBagQuantity(itemId) if not PICKUP_ENABLE_TEST_API then return nil end; return bagQuantity(tonumber(itemId) or 0) end
function Pickup:testInject(slot,species,item)
    if not PICKUP_ENABLE_TEST_API then return false end
    local mon=readMon(tonumber(slot) or 0); if not mon then return false end
    writeGrowth(mon,tonumber(species) or 288,tonumber(item) or 13)
    -- Force ability slot 0 so the disposable test mon uses Pickup.
    mon=readMon(tonumber(slot) or 0)
    local decrypted={}
    for i=0,11 do decrypted[i]=emu:read32(mon.address+0x20+i*4)~mon.key end
    local miscWord=mon.order[4]*3+1
    decrypted[miscWord]=decrypted[miscWord]&0x7FFFFFFF
    local checksum=0
    for i=0,11 do
        local word=decrypted[i]
        checksum=(checksum+(word&0xFFFF)+((word>>16)&0xFFFF))&0xFFFF
        emu:write32(mon.address+0x20+i*4,word~mon.key)
    end
    emu:write16(mon.address+0x1C,checksum)
    return true
end
function Pickup:testInjectItem(slot,item)
    if not PICKUP_ENABLE_TEST_API then return false end
    local mon=readMon(tonumber(slot) or 0); if not mon then return false end
    writeGrowth(mon,mon.species,tonumber(item) or 13)
    return true
end
function Pickup:testHeldItem(slot)
    if not PICKUP_ENABLE_TEST_API then return nil end
    local mon=readMon(tonumber(slot) or 0); return mon and mon.item or nil
end

callbacks:add("key",onKey)
frameClock:add(function()
    frames=frames+1
    if enabled and Battle and not Battle:getState().active then
        enabled=false
        status="Pickup stopped because the battle loop stopped."
        render(true)
    elseif frames%60==0 then render(false) end
end)
render(true)
