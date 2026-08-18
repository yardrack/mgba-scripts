-- Conservative automatic grinder for English Ruby/Sapphire/FireRed/LeafGreen.
-- It uses the games' own battle menus, stops on shinies, heals the party in
-- place, balances levels, collects Pickup items, and handles move prompts.

local suiteDir=GEN3_SUITE_DIR or (script and script.dir)
if not suiteDir then error("Load Pickup.lua, Battle.lua, or Level Grind.lua instead of this core directly.") end
local frameClock=GEN3_FRAME_CLOCK or dofile(suiteDir.."/lib/FrameClock.lua")
local ItemStorage=dofile(suiteDir.."/lib/ItemStorage.lua")
local PickupFilter=dofile(suiteDir.."/lib/PickupFilter.lua")
local InventoryCore=dofile(suiteDir.."/lib/InventoryCore.lua")
local gameData=dofile(suiteDir.."/lib/GameProfiles.lua")
local code=GEN3_GAME_CODE or tostring(emu:getGameCode()):sub(-4)
local stats=GEN3_SESSION_STATS or dofile(suiteDir.."/lib/SessionStats.lua").forGame(emu,code)

local revision=emu:read8(0x080000BC)
local game=gameData.resolve(code,revision)
if not game or game.family=="E" then return end
-- Compatibility aliases for the battle implementation. Their values all come
-- from the single resolved profile above.
game.battleMain=game.cb2Battle
game.overworldMain=game.cb2Overworld
game.actionCursor=game.battleActionCursor
game.moveCursor=game.battleMoveCursor
game.controllerFuncs=game.battlerControllerFuncs
game.pockets=game.bagPockets
game.pcOffset=game.pcItemsOffset
game.pcCapacity=game.pcItemsCapacity
game.splitPcStacks=game.pcSplitStacks

local KEY_A,KEY_B,KEY_UP,KEY_DOWN,KEY_LEFT,KEY_RIGHT=0,1,6,7,5,4
local PARTY_SIZE,ABILITY_PICKUP=0x64,53
local pickupUi=GEN3_GRIND_UI=="pickup"
local suiteUi=GEN3_GRIND_UI=="suite"
local function nullPanel() return {setSize=function() end,clear=function() end,print=function() end} end
local battlePanel,pickupPanel
if STARTER_HUNTER_HEADLESS then
    battlePanel,pickupPanel=nullPanel(),nullPanel()
elseif suiteUi then
    battlePanel,pickupPanel=console:createBuffer("Battle"),console:createBuffer("Pickup")
elseif pickupUi then
    battlePanel,pickupPanel=nullPanel(),console:createBuffer("Pickup")
else
    battlePanel,pickupPanel=console:createBuffer("Battle"),nullPanel()
end
battlePanel:setSize(54,10)
pickupPanel:setSize(62,26)
local activeKind,battleMode=nil,"Lead"
local battleStatus,pickupStatus="Press B to start.","Press P to start."
local frames,inputMask,battles,items=0,0,0,0
local itemCounts,lastItem={},"None yet"
local depositedSlots,depositedQuantity=0,0
local discardedItems=0
local selfRecoveries=0
local pickupHealPercent=20
local ppRecoverThreshold=math.max(0,math.floor(tonumber(PICKUP_PP_RECOVERY_THRESHOLD) or 3))
local filter=PickupFilter.new(PICKUP_FILTER_MODE or "All")
local wasInBattle=false
local lastBattleText,lastPickupText="",""
local lastRenderClock=0
local seenLearnMove=0
local lastMoveDecision="Move learning: waiting."
local shinyPid=nil

local SUBSTRUCT_ORDER={
 {0,1,2,3},{0,1,3,2},{0,2,1,3},{0,3,1,2},{0,2,3,1},{0,3,2,1},
 {1,0,2,3},{1,0,3,2},{2,0,1,3},{3,0,1,2},{2,0,3,1},{3,0,2,1},
 {1,2,0,3},{1,3,0,2},{2,1,0,3},{3,1,0,2},{2,3,0,1},{3,2,0,1},
 {1,2,3,0},{1,3,2,0},{2,1,3,0},{3,1,2,0},{2,3,1,0},{3,2,1,0}
}

local function sameFunction(pointer,address) return pointer==address or pointer==address+1 end
local function validRam(address) return address and address>=0x02000000 and address<0x02040000 end
local function save1()
    local address=game.save1 or emu:read32(game.save1Ptr)
    return validRam(address) and address or nil
end
local function save2()
    local address=game.save2 or emu:read32(game.save2Ptr)
    return validRam(address) and address or nil
end
local function partyCount() return math.min(6,emu:read8(game.partyCount)) end
local inventory=InventoryCore.new({emu=emu,profile=game,getSave1=save1,getSave2=save2})

local function decodeText(address,length)
    local chars={}
    for i=0,length-1 do
        local b=emu:read8(address+i)
        if b==0xFF then break
        elseif b==0 then chars[#chars+1]=" "
        elseif b>=0xA1 and b<=0xAA then chars[#chars+1]=string.char(48+b-0xA1)
        elseif b>=0xBB and b<=0xD4 then chars[#chars+1]=string.char(65+b-0xBB)
        elseif b>=0xD5 and b<=0xEE then chars[#chars+1]=string.char(97+b-0xD5) end
    end
    return table.concat(chars):gsub("%s+$","")
end
local function speciesName(id)
    local value=decodeText(game.speciesNames+(id or 0)*11,11)
    return value~="" and value or ("Species "..tostring(id or 0))
end
local function itemName(id) return inventory:itemName(id) end
local function monCore(slot,base)
    local address=(base or game.party)+slot*PARTY_SIZE
    local pid,ot=emu:read32(address),emu:read32(address+4)
    if pid==0 and ot==0 then return nil end
    local order=SUBSTRUCT_ORDER[(pid%24)+1]
    local key=pid~ot
    local growth=address+0x20+order[1]*12
    local attacks=address+0x20+order[2]*12
    local misc=address+0x20+order[4]*12
    local growth0=emu:read32(growth)~key
    local attack0,attack1=emu:read32(attacks)~key,emu:read32(attacks+4)~key
    local ivFlags=emu:read32(misc+4)~key
    local species,item=growth0&0xFFFF,(growth0>>16)&0xFFFF
    local abilityNum=(ivFlags>>31)&1
    local ability=emu:read8(game.speciesInfo+species*28+0x16+abilityNum)
    return {slot=slot,address=address,pid=pid,ot=ot,key=key,order=order,growth=growth,
        species=species,item=item,ability=ability,isEgg=((ivFlags>>30)&1)==1,
        moves={attack0&0xFFFF,(attack0>>16)&0xFFFF,attack1&0xFFFF,(attack1>>16)&0xFFFF},
        level=emu:read8(address+0x54),hp=emu:read16(address+0x56),maxHp=emu:read16(address+0x58)}
end
local function rewrite(core,decrypted)
    local checksum=0
    for i=0,11 do
        local word=decrypted[i]
        checksum=(checksum+(word&0xFFFF)+((word>>16)&0xFFFF))&0xFFFF
        emu:write32(core.address+0x20+i*4,word~core.key)
    end
    emu:write16(core.address+0x1C,checksum)
end
local function decrypted(core)
    local words={}
    for i=0,11 do words[i]=emu:read32(core.address+0x20+i*4)~core.key end
    return words
end
local TYPE_CHART={
    [0]={[5]=0.5,[7]=0,[8]=0.5},
    [1]={[0]=2,[2]=0.5,[3]=0.5,[5]=2,[6]=0.5,[7]=0,[8]=2,[14]=0.5,[17]=2},
    [2]={[1]=2,[5]=0.5,[6]=2,[8]=0.5,[12]=2,[13]=0.5},
    [3]={[3]=0.5,[4]=0.5,[5]=0.5,[7]=0.5,[8]=0,[12]=2},
    [4]={[2]=0,[3]=2,[5]=2,[6]=0.5,[8]=2,[10]=2,[12]=0.5,[13]=2},
    [5]={[1]=0.5,[2]=2,[4]=0.5,[6]=2,[8]=0.5,[10]=2,[15]=2},
    [6]={[1]=0.5,[2]=0.5,[3]=0.5,[7]=0.5,[8]=0.5,[10]=0.5,[12]=2,[14]=2,[17]=2},
    [7]={[0]=0,[7]=2,[8]=0.5,[14]=2,[17]=0.5},
    [8]={[5]=2,[6]=2,[8]=0.5,[10]=0.5,[11]=0.5,[12]=0.5,[13]=0.5,[15]=2},
    [10]={[5]=0.5,[6]=2,[8]=2,[10]=0.5,[11]=0.5,[12]=2,[15]=2,[16]=0.5},
    [11]={[4]=2,[5]=2,[10]=2,[11]=0.5,[12]=0.5,[16]=0.5},
    [12]={[2]=0.5,[3]=0.5,[4]=2,[5]=2,[6]=0.5,[8]=0.5,[10]=0.5,[11]=2,[12]=0.5,[16]=0.5},
    [13]={[4]=0,[2]=2,[11]=2,[12]=0.5,[13]=0.5,[16]=0.5},
    [14]={[1]=2,[3]=2,[8]=0.5,[14]=0.5,[17]=0},
    [15]={[2]=2,[4]=2,[8]=0.5,[10]=0.5,[11]=0.5,[12]=2,[15]=0.5,[16]=2},
    [16]={[8]=0.5,[16]=2},
    [17]={[1]=0.5,[7]=2,[8]=0.5,[14]=2,[17]=0.5},
}
local function speciesTypes(species)
    if not species or species==0 then return nil,nil end
    local base=game.speciesInfo+species*28
    return emu:read8(base+6),emu:read8(base+7)
end
local function effectiveness(moveType,defenderSpecies,defenderAbility,first,second)
    if first==nil then first,second=speciesTypes(defenderSpecies) end
    local chart=TYPE_CHART[moveType] or {}
    local value=chart[first] or 1
    if second and second~=first then value=value*(chart[second] or 1) end
    if (defenderAbility==26 and moveType==4) or (defenderAbility==18 and moveType==10)
        or (defenderAbility==11 and moveType==11) or (defenderAbility==10 and moveType==13) then return 0 end
    if defenderAbility==25 and value<=1 then return 0 end
    return value
end
local function moveScore(id,context)
    if not id or id==0 then return -1 end
    local address=game.battleMoves+id*12
    local power,moveType,accuracy,pp=emu:read8(address+1),emu:read8(address+2),emu:read8(address+3),emu:read8(address+4)
    if context and (context.pp or 0)<=0 then return -1000000 end
    if power==0 then return 10+pp end
    local score=power*(accuracy==0 and 100 or accuracy)
    if context then
        local first=context.attackerType1
        local second=context.attackerType2
        if first==nil then first,second=speciesTypes(context.attackerSpecies) end
        if moveType==first or moveType==second then score=score*1.5 end
        score=score*effectiveness(moveType,context.defenderSpecies,context.defenderAbility,
            context.defenderType1,context.defenderType2)
        score=score*math.max(1,moveType<=8 and context.attack or context.spAttack)
    end
    return score+math.min(pp,20)
end
local function weakestMove(core)
    local index,score=1,100000000
    for i,id in ipairs(core.moves) do local value=moveScore(id); if value<score then index,score=i,value end end
    return index,score
end
local function moveToFront(core,index)
    if index==1 then return end
    local words=decrypted(core)
    local attackWord=core.order[2]*3
    local ppWordIndex=attackWord+2
    local moves={core.moves[1],core.moves[2],core.moves[3],core.moves[4]}
    moves[1],moves[index]=moves[index],moves[1]
    words[attackWord]=(moves[1]&0xFFFF)|((moves[2]&0xFFFF)<<16)
    words[attackWord+1]=(moves[3]&0xFFFF)|((moves[4]&0xFFFF)<<16)
    local pp=words[ppWordIndex]
    local p={pp&0xFF,(pp>>8)&0xFF,(pp>>16)&0xFF,(pp>>24)&0xFF}
    p[1],p[index]=p[index],p[1]
    words[ppWordIndex]=p[1]|(p[2]<<8)|(p[3]<<16)|(p[4]<<24)
    rewrite(core,words)
end
local function prepareBestMove()
    -- FR/LG expose the live battle menu state, so selecting the cursor is both
    -- safer and more accurate than rewriting the party's encrypted move order.
    if game.controllerFuncs then return end
    local core=monCore(0); if not core then return end
    local best,bestScore=1,-1
    for i,id in ipairs(core.moves) do local value=moveScore(id); if value>bestScore then best,bestScore=i,value end end
    moveToFront(core,best)
end
local function healParty()
    for slot=0,partyCount()-1 do
        local core=monCore(slot)
        if core and core.maxHp>0 then
            emu:write32(core.address+0x50,0)
            emu:write16(core.address+0x56,core.maxHp)
            local words=decrypted(core)
            local growthPpUps=core.order[1]*3+2
            local attacksPp=core.order[2]*3+2
            local ppUps=words[growthPpUps]&0xFF
            local ppWord=0
            for i,id in ipairs(core.moves) do
                local base=id>0 and emu:read8(game.battleMoves+id*12+4) or 0
                local ups=(ppUps>>((i-1)*2))&3
                ppWord=ppWord|(((base+math.floor(base*ups/5))&0xFF)<<((i-1)*8))
            end
            words[attacksPp]=ppWord
            rewrite(core,words)
        end
    end
    return partyCount()>0
end
local function partyPp(core)
    if not core then return 0 end
    local words=decrypted(core)
    local ppWord=words[core.order[2]*3+2]
    local total=0
    for index,id in ipairs(core.moves) do
        if id~=0 then total=total+((ppWord>>((index-1)*8))&0xFF) end
    end
    return total
end
local function pickupRecoveryNeeded()
    local lead=monCore(0)
    if not lead then return "party unavailable" end
    if lead.maxHp==0 or lead.hp*100<=lead.maxHp*pickupHealPercent then
        return string.format("HP low (%d/%d)",lead.hp,lead.maxHp)
    end
    local pp=partyPp(lead)
    if pp<=ppRecoverThreshold then return string.format("move PP low (%d remaining)",pp) end
    return nil
end
local function swapParty(first,second)
    if first==second then return end
    local a,b=game.party+first*PARTY_SIZE,game.party+second*PARTY_SIZE
    local bytes={}
    for i=0,PARTY_SIZE-1 do bytes[i]=emu:read8(a+i) end
    for i=0,PARTY_SIZE-1 do emu:write8(a+i,emu:read8(b+i)) end
    for i=0,PARTY_SIZE-1 do emu:write8(b+i,bytes[i]) end
end
local function chooseLead()
    if activeKind=="Battle" and battleMode=="Lead" then return end
    local best=nil
    for slot=0,partyCount()-1 do
        local core=monCore(slot)
        local eligible=core and core.hp>0 and not core.isEgg
        if activeKind=="Pickup" then eligible=eligible and (core.species==288 or core.species==289) and core.ability==ABILITY_PICKUP end
        if eligible and (not best or core.level<best.level) then best=core end
    end
    if best and best.slot~=0 then swapParty(0,best.slot) end
end
local function selfRecover(reason)
    if not healParty() then return false end
    selfRecoveries=selfRecoveries+1
    chooseLead()
    prepareBestMove()
    pickupStatus=string.format("Self-recovered HP, status, and PP because %s. Farming resumed.",reason or "recovery was needed")
    return true
end
local function bagKey()
    if not game.bagKeyOffset then return 0 end
    local s2=save2(); return s2 and emu:read16(s2+game.bagKeyOffset) or 0
end
local function pocketForItem(id)
    return inventory:itemPocket(id)
end
local storage=ItemStorage.new({
    emu=emu,getSave1=save1,getBagKey=bagKey,pockets=game.pockets,
    pcOffset=game.pcOffset,pcCapacity=game.pcCapacity,splitPcStacks=game.splitPcStacks,
    protectItem=function(itemId,pocketId)
        local pocket=game.pockets[pocketId]
        return (pocket and pocket.protected==true) or (itemId>=339 and itemId<=346)
    end,
})
local function addBagItem(id)
    local s1=save1(); if not s1 then return false end
    local pocketId=pocketForItem(id)
    local pocket=pocketId and game.pockets[pocketId]
    if not pocket then return false end
    local offset,cap=pocket.offset,pocket.capacity
    local key=bagKey(); local empty=nil
    for i=0,cap-1 do
        local address=s1+offset+i*4; local existing=emu:read16(address)
        if existing==id then
            local quantity=emu:read16(address+2)~key
            if quantity<pocket.stack then emu:write16(address+2,(quantity+1)~key); return true end
            if not pocket.split then return false end
        elseif existing==0 and not empty then empty=address end
    end
    if not empty then return false end
    emu:write16(empty,id); emu:write16(empty+2,1~key); return true
end
local function collectPickup(force)
    if not force and activeKind~="Pickup" then return true end
    local deposited,kept,discarded=0,0,0
    for slot=0,partyCount()-1 do
        local core=monCore(slot)
        if core and core.ability==ABILITY_PICKUP and core.item~=0 then
            if not filter:accepts(core.item) then
                local words=decrypted(core); local growth=core.order[1]*3
                words[growth]=words[growth]&0xFFFF; rewrite(core,words)
                discardedItems=discardedItems+1
                discarded=discarded+1
                if activeKind=="Pickup" then stats:inc("Pickup","discarded",1) end
                lastItem="Discarded "..itemName(core.item)
                goto continue
            end
            local added=addBagItem(core.item)
            if not added then
                local moved,summary=storage:depositAll(pocketForItem(core.item))
                if moved then
                    depositedSlots=depositedSlots+summary.slots
                    depositedQuantity=depositedQuantity+summary.quantity
                    deposited=deposited+summary.slots
                    if activeKind=="Pickup" then stats:inc("Pickup","deposited",summary.quantity) end
                    added=addBagItem(core.item)
                end
            end
            if not added then
                pickupStatus="Bag and PC item storage are full. Pickup stopped without removing the held item."
                return false
            end
            local words=decrypted(core); local growth=core.order[1]*3
            words[growth]=words[growth]&0xFFFF; rewrite(core,words); items=items+1
            itemCounts[core.item]=(itemCounts[core.item] or 0)+1
            lastItem=itemName(core.item)
            kept=kept+1
            if activeKind=="Pickup" then stats:inc("Pickup","items",1) end
        end
        ::continue::
    end
    if deposited>0 then
        pickupStatus=string.format("Deposited %d bag stack%s in the PC before collecting Pickup items.",deposited,deposited==1 and "" or "s")
    elseif kept>0 or discarded>0 then
        pickupStatus=string.format("Kept %d and discarded %d Pickup item%s.",kept,discarded,(kept+discarded)==1 and "" or "s")
    end
    return true
end
local function inBattle() return sameFunction(emu:read32(game.gMain+4),game.battleMain) end
local function inOverworld() return sameFunction(emu:read32(game.gMain+4),game.overworldMain) end
local function shinyEnemy()
    local core=monCore(0,game.enemy); if not core then return nil end
    local s2=save2(); if not s2 then return nil end
    local tid,sid=emu:read16(s2+0xA),emu:read16(s2+0xC)
    local value=(tid~sid~(core.pid&0xFFFF)~((core.pid>>16)&0xFFFF))&0xFFFF
    return value<8 and core or nil
end
local function tap(key) if frames%8==1 then inputMask=1<<key end end
local function moveCursorToward(current,target)
    if current==target then tap(KEY_A)
    elseif current<2 and target>=2 then tap(KEY_DOWN)
    elseif current>=2 and target<2 then tap(KEY_UP)
    elseif current%2==0 and target%2==1 then tap(KEY_RIGHT)
    else tap(KEY_LEFT) end
end
local function bestBattleMove()
    if not game.battleMons then return 0 end
    local attacker=game.battleMons
    local defender=attacker+0x58
    local context={attackerSpecies=emu:read16(attacker),defenderSpecies=emu:read16(defender),
        attackerType1=emu:read8(attacker+0x21),attackerType2=emu:read8(attacker+0x22),
        defenderAbility=emu:read8(defender+0x20),defenderType1=emu:read8(defender+0x21),
        defenderType2=emu:read8(defender+0x22),attack=emu:read16(attacker+2),spAttack=emu:read16(attacker+8)}
    local best,bestScore=0,-1000001
    for index=0,3 do
        local id=emu:read16(attacker+0x0C+index*2)
        context.pp=emu:read8(attacker+0x24+index)
        local score=moveScore(id,context)
        if score>bestScore then best,bestScore=index,score end
    end
    return best,bestScore
end
local function handleBattleInput()
    if game.controllerFuncs and game.chooseAction and game.chooseMove then
        local controller=emu:read32(game.controllerFuncs)
        if sameFunction(controller,game.chooseAction) then
            moveCursorToward(emu:read8(game.actionCursor),0)
            return
        elseif sameFunction(controller,game.chooseMove) then
            moveCursorToward(emu:read8(game.moveCursor),bestBattleMove())
            return
        end
    end
    tap(KEY_A)
end
local function handleMovePrompt()
    local newMove=emu:read16(game.moveToLearn)
    if newMove==0 then seenLearnMove=0; return false end
    local core=monCore(0); if not core then tap(KEY_A); return true end
    local worst,worstScore=weakestMove(core)
    if seenLearnMove~=newMove then
        seenLearnMove=newMove
        if moveScore(newMove)>worstScore then
            moveToFront(core,worst)
            lastMoveDecision="Learning move "..newMove.." over the weakest current move."
        else
            lastMoveDecision="Skipping weaker move "..newMove.."."
        end
        if activeKind=="Pickup" then pickupStatus=lastMoveDecision else battleStatus=lastMoveDecision end
    end
    if moveScore(newMove)>worstScore then tap(KEY_A)
    else
        local phase=frames%32
        if phase<8 then inputMask=1<<KEY_B elseif phase<16 then inputMask=1<<KEY_UP elseif phase<24 then inputMask=1<<KEY_A end
    end
    return true
end
local PICKUP_TRACKED_IDS={68,69,110,180,187,200,289,314,332}
local PICKUP_ALL_IDS={2,3,13,14,19,21,22,23,24,25,34,36,37,63,64,68,69,75,85,86,110,180,187,200,289,314,332}
local function bagInventoryEntries(bag)
    local entries,seen={},{}
    for _,id in ipairs(PICKUP_TRACKED_IDS) do
        seen[id]=true
        entries[#entries+1]=string.format("%s x%d",itemName(id),bag.byId[id] or 0)
    end
    for _,id in ipairs(PICKUP_ALL_IDS) do
        if not seen[id] and (bag.byId[id] or 0)>0 then entries[#entries+1]=string.format("%s x%d",itemName(id),bag.byId[id]) end
    end
    return entries
end
local function wrappedLines(label,entries,width)
    local lines,current={},label
    for _,entry in ipairs(entries) do
        local piece=(current==label and "" or ", ")..entry
        if #current+#piece>width and current~=label then lines[#lines+1]=current; current="  "..entry
        else current=current..piece end
    end
    lines[#lines+1]=current==label and (label.."none") or current
    return lines
end
local function render(force)
    local now=os.clock()
    if not force and now-lastRenderClock<0.25 then return end
    lastRenderClock=now
    local lead=monCore(0)
    local bag=inventory:scanBag()
    local battleText=string.format("BATTLE | %s  |  %s\nMode: %s   Wins: %d\nTime: %s   Wins/hour: %.1f\nLead: %s\n\n%s\n\nB start/stop   1 Lead   2 Balanced",
        game.name,activeKind=="Battle" and "RUNNING" or "READY",battleMode,battles,
        stats:formatElapsed("Battle"),stats:rate("Battle","battles"),
        lead and string.format("%s Lv%d %d/%d",speciesName(lead.species),lead.level,lead.hp,lead.maxHp) or "None",battleStatus)
    if battleText~=lastBattleText then battlePanel:clear(); battlePanel:print(battleText); lastBattleText=battleText end

    local picked={}
    for id,count in pairs(itemCounts) do picked[#picked+1]=string.format("%s x%d",itemName(id),count) end
    table.sort(picked)
    local pickupLines={
        "PICKUP | "..game.name.."  |  "..(activeKind=="Pickup" and "RUNNING" or "READY"),
        string.format("Battles: %d   Collected: %d   Self-recoveries: %d",battles,items,selfRecoveries),
        string.format("Recovery trigger: HP <= %d%% or PP <= %d",pickupHealPercent,ppRecoverThreshold),
        bag.ready and string.format("Bag: %d items (%d/%d slots)",bag.totalQuantity,bag.usedSlots,bag.totalSlots) or "Bag: unavailable",
        string.format("Keep: %s   Discarded: %d",filter:name(),discardedItems),
        string.format("PC deposits: %d stacks / %d items",depositedSlots,depositedQuantity),
        string.format("Time: %s   Items/hour: %.1f",stats:formatElapsed("Pickup"),stats:rate("Pickup","items")),
        "P start/stop   F filter   X clear totals",""
    }
    if bag.ready then
        for _,line in ipairs(wrappedLines("Bag counts: ",bagInventoryEntries(bag),60)) do pickupLines[#pickupLines+1]=line end
        pickupLines[#pickupLines+1]=""
    end
    for _,line in ipairs({
        "Can pick up:",
        "Potion, Antidote, Super Potion, Great Ball, Repel,",
        "Escape Rope, X Attack, Full Heal, Ultra Ball,",
        "Rare Candy, Nugget","",
        "Picked up: "..(#picked>0 and table.concat(picked,", ") or "none"),
        "Last: "..lastItem,"",pickupStatus
    }) do pickupLines[#pickupLines+1]=line end
    local pickupText=table.concat(pickupLines,"\n")
    if pickupText~=lastPickupText then pickupPanel:clear(); pickupPanel:print(pickupText); lastPickupText=pickupText end
end
local function start(kind)
    inputMask=0; emu:setKeys(0); if emu.clearKeys then emu:clearKeys(0x3FF) end
    activeKind=kind; frames=0; battles=0; selfRecoveries=0; wasInBattle=false
    stats:start(kind,true)
    chooseLead(); healParty(); prepareBestMove()
    if kind=="Pickup" then pickupStatus="Pickup started. Press P to stop."
    else battleStatus="Battle started. Press B to stop." end
    render(true)
end
local function stop(kind,message)
    if activeKind~=kind then return false end
    stats:stop(kind)
    activeKind=nil; inputMask=0; emu:setKeys(0); if emu.clearKeys then emu:clearKeys(0x3FF) end
    if kind=="Pickup" then pickupStatus=message or "Stopped."
    else battleStatus=message or "Stopped." end
    render(true)
    return true
end
local function spinInPlace()
    if frames%6~=1 then return end
    local objectEventId=emu:read8(game.playerAvatar+5)
    if objectEventId>=16 then return end
    local facing=emu:read16(game.objectEvents+objectEventId*0x24+0x18)&0xF
    -- Reread the live direction for every pulse instead of retaining an
    -- acknowledgement across a battle. The selected key is always different
    -- from the current facing, so it turns the player without taking a step.
    local nextKey=({[1]=KEY_LEFT,[3]=KEY_UP,[2]=KEY_RIGHT,[4]=KEY_DOWN})[facing]
    if nextKey then inputMask=1<<nextKey end
end
frameClock:add(function()
    frames=frames+1; inputMask=0
    if not activeKind then render(); return end
    local battle=inBattle()
    if battle then
        local shiny=shinyEnemy()
        if shiny and shiny.pid~=shinyPid then
            shinyPid=shiny.pid
            stop(activeKind,string.format("SHINY %s found! PID %08X. Stopped safely.",speciesName(shiny.species),shiny.pid))
            render(); return
        end
        wasInBattle=true
        handleBattleInput()
    elseif wasInBattle then
        if inOverworld() then
            -- gMoveToLearn remains populated after some FireRed/LeafGreen
            -- level-up paths. Once callback2 is back in the overworld that
            -- value is stale and must not keep the grinder in prompt handling.
            wasInBattle=false; seenLearnMove=0; battles=battles+1
            stats:inc(activeKind,"battles",1)
            if activeKind=="Pickup" and not collectPickup() then stop("Pickup",pickupStatus); render(); return end
            if activeKind=="Pickup" then
                local reason=pickupRecoveryNeeded()
                if reason then selfRecover(reason)
                else chooseLead(); prepareBestMove(); pickupStatus="Battle complete. Pickup collected; searching again." end
            else
                healParty(); chooseLead(); prepareBestMove(); battleStatus="Battle complete. Party healed; searching again."
            end
        elseif handleMovePrompt() then
            -- Keep resolving the game's normal move-learning dialogue while
            -- the post-battle callback still owns the screen.
        else
            -- RS and FR/LG temporarily replace callback2 during post-battle
            -- text, level-up, evolution, and map-return work. Keep advancing
            -- those states and do not declare the battle complete until the
            -- actual overworld callback has been restored.
            tap(KEY_A)
        end
    else
        local lead=monCore(0)
        if activeKind=="Pickup" then
            local reason=pickupRecoveryNeeded()
            if reason then selfRecover(reason) end
        elseif not lead or lead.hp==0 then healParty(); chooseLead() end
        spinInPlace()
    end
    -- The windowless mGBA runner has no frontend key-poll event. Applying the
    -- mask here keeps the same state machine testable without changing the GUI
    -- path, where keysRead remains the authoritative input hook.
    if STARTER_HUNTER_HEADLESS then emu:setKeys(inputMask) end
    render()
end)
callbacks:add("keysRead",function() if activeKind then emu:setKeys(inputMask) end end)

Battle={}
function Battle:start() start("Battle"); return activeKind=="Battle" end
function Battle:stop() return stop("Battle") end
function Battle:setMode(value) if value=="Lead" or value=="Balanced" then battleMode=value; render() end end
function Battle:getState()
    return {active=activeKind=="Battle",mode=battleMode,battlesWon=battles,status=battleStatus,items=items,
        inBattle=inBattle(),callback=emu:read32(game.gMain+4),enemyHp=emu:read16(game.enemy+0x56),
        session=stats:snapshot("Battle")}
end
function Battle:testBestMove()
    if not BATTLE_ENABLE_TEST_API then return nil end
    return bestBattleMove()
end
Pickup={}
function Pickup:start() start("Pickup"); return activeKind=="Pickup" end
function Pickup:stop() return stop("Pickup") end
function Pickup:isRunning() return activeKind=="Pickup" end
function Pickup:getStatus() return pickupStatus end
function Pickup:getState() return {enabled=activeKind=="Pickup",status=pickupStatus,totalItems=items,lastItem=lastItem,
    itemCounts=itemCounts,depositedSlots=depositedSlots,depositedQuantity=depositedQuantity,
    filter=filter:name(),discardedItems=discardedItems,selfRecoveries=selfRecoveries,
    healPercent=pickupHealPercent,ppRecoverThreshold=ppRecoverThreshold,session=stats:snapshot("Pickup")} end
function Pickup:clearTotals() items,itemCounts,lastItem,depositedSlots,depositedQuantity,discardedItems=0,{},"None yet",0,0,0; stats:reset("Pickup"); render(); return true end
function Pickup:setFilter(value)
    local ok,name=filter:set(value)
    pickupStatus=ok and ("Pickup keep filter: "..name..".") or ("Unknown Pickup filter; keeping "..name..".")
    render()
    return ok,name
end
function Pickup:cycleFilter() local name=filter:cycle(); pickupStatus="Pickup keep filter: "..name.."."; render(); return name end
function Pickup:getFilters() return filter:names() end
function Pickup:testFilterItem(itemId) if not PICKUP_ENABLE_TEST_API then return nil end; return filter:accepts(itemId) end
function Pickup:testRecoveryNeeded() if not PICKUP_ENABLE_TEST_API then return nil end; return pickupRecoveryNeeded() end
function Pickup:testSelfRecover(reason) if not PICKUP_ENABLE_TEST_API then return nil end; return selfRecover(reason or "test request") end
function Pickup:testCollect()
    if not PICKUP_ENABLE_TEST_API then return nil end
    return collectPickup(true)
end
function Pickup:testHeldItem(slot)
    if not PICKUP_ENABLE_TEST_API then return nil end
    local core=monCore(tonumber(slot) or 0)
    return core and core.item or nil
end

render()
