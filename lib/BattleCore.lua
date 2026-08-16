-- Standalone Emerald battle-grinding core for mGBA.
-- B starts/stops. 1/2 select Lead/Balanced. H toggles 20/30% healing.

if emu:getGameCode()~="BPEE" then return end
local suiteDir=GEN3_SUITE_DIR or (script and script.dir)
local frameClock=GEN3_FRAME_CLOCK or dofile(suiteDir.."/lib/FrameClock.lua")
local stats=GEN3_SESSION_STATS or dofile(suiteDir.."/lib/SessionStats.lua").forGame(emu,"BPEE")

local KEY_A,KEY_B,KEY_UP,KEY_DOWN,KEY_LEFT,KEY_RIGHT=0,1,6,7,5,4
local GMAIN,GPLAYER_COUNT,GPLAYER_PARTY=0x030022C0,0x020244E9,0x020244EC
local GPARTY_MENU=0x0203CEC8
local SENT_POKES_TO_OPPONENT=0x020243FE
local GOBJECT_EVENTS,GPLAYER_AVATAR=0x02037350,0x02037590
local SAVE1_PTR,SAVE2_PTR,BATTLE_FLAGS,BATTLE_OUTCOME=0x03005D8C,0x03005D90,0x02022FEC,0x0202433A
local ENEMY_PARTY,SPECIES_NAMES=0x02024744,0x083185C8
local CB2_OVERWORLD,CB2_BATTLE,CB2_LOAD_MAP=0x08085E5C,0x08038420,0x08085FCC
local CB2_PARTY_MENU,CB2_PARTY_MENU_INIT=0x081B01B0,0x081B01E0
local WARP_DEST,WARP_INTO_MAP=0x020322E4,0x08084BD8
local PARTY_SIZE=0x64
local BATTLE_MONS,ACTION_CURSOR,MOVE_CURSOR,CONTROLLER_FUNCS=0x02024084,0x020244AC,0x020244B0,0x03005D60
local CHOOSE_ACTION,CHOOSE_MOVE=0x08057588,0x08057BFC
local TASKS,TASK_EVOLUTION,TASK_REPLACE_MOVE=0x03005E00,0x0813E570,0x081C174C
local BATTLE_SCRIPT_PTR,MOVE_TO_LEARN,BATTLE_STRUCT_PTR,SUMMARY_PTR=0x02024214,0x020244E2,0x0202449C,0x0203CF1C
local ASK_LEARN_MOVE,FINISHED_LEARN_MOVE=0x082DABE3,0x082DAC10
local BATTLE_MOVES,MOVE_NAMES=0x0831C898,0x0831977C
local BEGIN_EVOLUTION,AFTER_EVOLUTION_CALLBACK=0x0813DA40,0x030061E8

local panel
if EMERALD_AUTOMATION_HEADLESS or BATTLE_HIDE_UI then
    panel={setSize=function() end,clear=function() end,print=function() end}
else
    panel=console:createBuffer("Battle")
end
panel:setSize(54,11)
local active=false
local grindMode="Lead"
local healPercent=30
local state="idle"
local status="Stand on an encounter tile, then press B."
local inputMask,keyPolls,frames=0,0,0
local startWarp,startMapGroup,startMapNum,startX,startY=nil,nil,nil,nil,nil
local battlesWon=0
local centerTrips=0
local wasInBattle=false
local callReturnFrames=0
local lastText=""
local lastRenderClock=0
local turns=0
local testWarpFrames=0
local emergencyEscape,needsCenter=false,false
local faintReplacementSlot=nil
local faintSwitches=0
local learnDecision,learnMoveId,learnPartySlot=nil,nil,nil
local lastMoveDecision="Move learning: automatic best-set decisions enabled."
local evolutionDecisionKey=nil
local lastEvolutionDecision="Evolution decision: automatic Pickup-safe evolutions enabled."
local stop
local shinyStoppedPid=nil
local statsMode="Battle"

local SUBSTRUCT_ORDER={
    {0,1,2,3},{0,1,3,2},{0,2,1,3},{0,3,1,2},{0,2,3,1},{0,3,2,1},
    {1,0,2,3},{1,0,3,2},{2,0,1,3},{3,0,1,2},{2,0,3,1},{3,0,2,1},
    {1,2,0,3},{1,3,0,2},{2,1,0,3},{3,1,0,2},{2,3,0,1},{3,2,0,1},
    {1,2,3,0},{1,3,2,0},{2,1,3,0},{3,1,2,0},{2,3,1,0},{3,2,1,0}
}
local HM_MOVES={[15]=true,[19]=true,[57]=true,[70]=true,[127]=true,[148]=true,[249]=true,[291]=true}
local ABILITY_PICKUP=53

-- Local, lag-free move preferences.  Linoone's core is adapted from Smogon's
-- ADV recommendations; the reliable in-game moves cover ordinary level-up
-- prompts where event-only ExtremeSpeed is unavailable.  The strict flag
-- declines its weak filler moves instead of filling an empty slot with them.
local MOVE_PRESETS={
    [288]={strict=true,scores={ -- Zigzagoon (Emerald internal species id)
        [29]=14000,[38]=18000,[70]=100000,[91]=15000,[163]=21000,[168]=15000,
        [187]=50000,[216]=46000,[237]=47000,[245]=55000,[247]=52000,[290]=19000,[343]=16000,
    }},
    [289]={strict=true,scores={ -- Linoone
        [29]=14000,[38]=18000,[70]=100000,[91]=15000,[163]=21000,[168]=15000,
        [187]=50000,[216]=46000,[237]=47000,[245]=55000,[247]=52000,[290]=19000,[343]=16000,
    }},
}

-- Strong utility moves worth learning for other party species.  Battle mode
-- still favours attacks, so these do not create an AFK setup/status loop.
local UTILITY_MOVE_SCORES={
    [14]=4500,[73]=4000,[79]=4500,[86]=4200,[92]=4000,[95]=3500,[97]=3000,
    [105]=5000,[113]=3000,[115]=3000,[135]=5000,[147]=6000,[164]=3500,
    [182]=2500,[208]=5000,[234]=5000,[235]=5000,[236]=5000,[261]=4500,
    [339]=4500,[347]=4500,[349]=5500,
}

-- Roles stop the learner from replacing useful coverage with several moves
-- that all do the same job.  Unknown status moves remain low priority.
local MOVE_ROLES={
    [14]="setup",[97]="setup",[147]="setup",[164]="setup",[187]="setup",[339]="setup",[347]="setup",[349]="setup",
    [73]="status",[79]="status",[86]="status",[92]="status",[95]="status",[261]="status",
    [105]="heal",[135]="heal",[208]="heal",[234]="heal",[235]="heal",[236]="heal",
    [113]="screen",[115]="screen",[182]="protect",
}

local function sameFunction(pointer,address) return pointer==address or pointer==address+1 end
local function save1()
    local address=emu:read32(SAVE1_PTR)
    return address>=0x02000000 and address<0x02040000 and address or nil
end
local function partyCount() return math.min(6,emu:read8(GPLAYER_COUNT)) end
local function findTask(func)
    for id=0,15 do
        local address=TASKS+id*40
        if emu:read8(address+4)~=0 and sameFunction(emu:read32(address),func) then return address,id end
    end
    return nil
end
local function pokemonCore(address)
    local pid,ot=emu:read32(address),emu:read32(address+4)
    if pid==0 and ot==0 then return nil end
    local order=SUBSTRUCT_ORDER[(pid%24)+1]; if not order then return nil end
    local key=pid~ot
    local growth=address+32+order[1]*12
    local attacks=address+32+order[2]*12
    local misc=address+32+order[4]*12
    local g0=emu:read32(growth)~key
    local a0,a1=emu:read32(attacks)~key,emu:read32(attacks+4)~key
    local ivFlags=emu:read32(misc+4)~key
    local species=g0&0xFFFF
    local abilityNum=(ivFlags>>31)&1
    local ability=emu:read8(0x083203CC+species*28+0x16+abilityNum)
    return {address=address,pid=pid,ot=ot,key=key,order=order,growth=growth,attacks=attacks,
        species=species,ability=ability,isEgg=((ivFlags>>30)&1)==1,
        moves={a0&0xFFFF,(a0>>16)&0xFFFF,a1&0xFFFF,(a1>>16)&0xFFFF}}
end
local function partyCore(slot) return pokemonCore(GPLAYER_PARTY+slot*PARTY_SIZE) end
local function decodeGameText(address,length)
    local chars={}
    for i=0,length-1 do
        local b=emu:read8(address+i); if b==0xFF then break end
        if b==0 then chars[#chars+1]=" "
        elseif b>=0xA1 and b<=0xAA then chars[#chars+1]=string.char(48+b-0xA1)
        elseif b>=0xBB and b<=0xD4 then chars[#chars+1]=string.char(65+b-0xBB)
        elseif b>=0xD5 and b<=0xEE then chars[#chars+1]=string.char(97+b-0xD5)
        elseif b==0xAB then chars[#chars+1]="!" elseif b==0xAC then chars[#chars+1]="?"
        elseif b==0xAD then chars[#chars+1]="." elseif b==0xAE then chars[#chars+1]="-"
        elseif b==0xB8 then chars[#chars+1]="," elseif b==0xB4 then chars[#chars+1]="'" end
    end
    return (#chars>0 and table.concat(chars) or "Move")
end
local function moveName(id) return id and id>0 and decodeGameText(MOVE_NAMES+id*13,13) or "None" end
local function speciesName(id)
    local name=decodeGameText(SPECIES_NAMES+(id or 0)*11,11):gsub("%s+$","")
    return name~="" and name or ("Species "..tostring(id or 0))
end
local function moveInfo(id)
    local a=BATTLE_MOVES+(id or 0)*12
    return {id=id or 0,effect=emu:read8(a),power=emu:read8(a+1),type=emu:read8(a+2),accuracy=emu:read8(a+3),pp=emu:read8(a+4)}
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
    [13]={[2]=2,[4]=0,[11]=2,[12]=0.5,[13]=0.5,[16]=0.5},
    [14]={[1]=2,[3]=2,[8]=0.5,[14]=0.5,[17]=0},
    [15]={[2]=2,[4]=2,[8]=0.5,[10]=0.5,[11]=0.5,[12]=2,[15]=0.5,[16]=2},
    [16]={[8]=0.5,[16]=2},
    [17]={[1]=0.5,[7]=2,[8]=0.5,[14]=2,[17]=0.5},
}
local function battleEffectiveness(moveType,defender)
    local chart=TYPE_CHART[moveType] or {}
    local first,second=emu:read8(defender+0x21),emu:read8(defender+0x22)
    local value=chart[first] or 1
    if second~=first then value=value*(chart[second] or 1) end
    local ability=emu:read8(defender+0x20)
    if (ability==26 and moveType==4) or (ability==18 and moveType==10)
        or (ability==11 and moveType==11) or (ability==10 and moveType==13) then return 0 end
    if ability==25 and value<=1 then return 0 end
    return value
end
local function moveScore(id,slot,species,purpose)
    if not id or id==0 then return -100000 end
    if purpose=="learn" and HM_MOVES[id] then return 100000 end
    local preset=MOVE_PRESETS[species or 0]
    if purpose=="learn" and preset and preset.scores[id] then return preset.scores[id] end
    local info=moveInfo(id)
    if info.power==0 then
        if purpose=="learn" then
            if preset and preset.strict then return -50000 end
            return UTILITY_MOVE_SCORES[id] or -2000
        end
        return 5+math.min(info.pp,20)/20
    end
    if purpose=="learn" and preset and preset.strict then return -50000 end
    local address=GPLAYER_PARTY+slot*PARTY_SIZE
    local battle=purpose=="battle"
    local attacker=BATTLE_MONS
    local attack=battle and emu:read16(attacker+2) or emu:read16(address+0x5A)
    local special=battle and emu:read16(attacker+8) or emu:read16(address+0x60)
    local stat=info.type<9 and attack or special
    local speciesInfo=0x083203CC+(species or 0)*28
    local first=battle and emu:read8(attacker+0x21) or emu:read8(speciesInfo+6)
    local second=battle and emu:read8(attacker+0x22) or emu:read8(speciesInfo+7)
    local stab=(first==info.type or second==info.type) and 1.5 or 1
    local accuracy=info.accuracy==0 and 100 or info.accuracy
    local endurance=0.75+math.min(info.pp,30)/120
    local effectiveness=battle and battleEffectiveness(info.type,attacker+0x58) or 1
    return info.power*accuracy*math.max(stat,1)*stab*effectiveness*endurance/100
end
local function moveSetScore(moves,slot,species)
    local total,damaging=0,0
    local seenMoves,seenTypes,seenRoles={},{},{}
    for _,id in ipairs(moves) do
        local score=moveScore(id,slot,species,"learn")
        if id==0 then
            total=total-25000
        elseif seenMoves[id] then
            total=total-50000
        else
            seenMoves[id]=true
            local info=moveInfo(id)
            if info.power>0 then
                damaging=damaging+1
                if seenTypes[info.type] and not HM_MOVES[id] then score=score*0.78
                else seenTypes[info.type]=true; score=score+750 end
            else
                local role=MOVE_ROLES[id] or "utility"
                if seenRoles[role] then score=score-3000 else seenRoles[role]=true end
            end
            total=total+score
        end
    end
    if damaging==0 then total=total-50000 elseif damaging==1 then total=total-4000 end
    return total
end
local function chooseMoveReplacement(slot,newMove)
    local core=partyCore(slot); if not core then return 4,"could not read party data" end
    local preset=MOVE_PRESETS[core.species]
    if preset and preset.strict and not preset.scores[newMove] and not HM_MOVES[newMove] then
        return 4,string.format("skipped %s; it is not on the recommended Pickup set",moveName(newMove))
    end
    for _,id in ipairs(core.moves) do
        if id==newMove then return 4,string.format("skipped duplicate %s",moveName(newMove)) end
    end
    local currentScore=moveSetScore(core.moves,slot,core.species)
    local bestSlot,bestScore=nil,currentScore
    for i=1,4 do
        if not HM_MOVES[core.moves[i]] then
            local proposed={core.moves[1],core.moves[2],core.moves[3],core.moves[4]}
            proposed[i]=newMove
            local score=moveSetScore(proposed,slot,core.species)
            if score>bestScore then bestSlot,bestScore=i,score end
        end
    end
    local margin=math.max(100,math.abs(currentScore)*0.01)
    if not bestSlot or bestScore<currentScore+margin then
        return 4,string.format("kept the current set; %s did not improve power, coverage, or utility",moveName(newMove))
    end
    return bestSlot-1,string.format("learn %s over %s for the stronger overall set",moveName(newMove),moveName(core.moves[bestSlot]))
end
local function speciesHasAbility(species,ability)
    local address=0x083203CC+(species or 0)*28+0x16
    return emu:read8(address)==ability or emu:read8(address+1)==ability
end
local function shouldAcceptEvolution(slot,preSpecies,postSpecies)
    if not (Pickup and Pickup.isRunning and Pickup:isRunning()) then
        return true,"accepted for better stats"
    end
    local core=partyCore(slot)
    if not core or core.ability~=ABILITY_PICKUP then
        return true,"accepted; this is not a Pickup member"
    end
    if speciesHasAbility(postSpecies,ABILITY_PICKUP) then
        return true,"accepted; the evolution keeps Pickup"
    end
    return false,"stopped; the evolution would lose Pickup"
end
local function mon(slot)
    local a=GPLAYER_PARTY+slot*PARTY_SIZE
    return {slot=slot,level=emu:read8(a+0x54),hp=emu:read16(a+0x56),maxHp=emu:read16(a+0x58)}
end
local function partySummary()
    local result={}
    for slot=0,partyCount()-1 do
        local p=mon(slot)
        result[#result+1]=string.format("%d: Lv%-3d %d/%d HP",slot+1,p.level,p.hp,p.maxHp)
    end
    return #result>0 and table.concat(result,"  |  ") or "No party Pokemon"
end
local function shouldHeal()
    if partyCount()==0 then return true end
    if grindMode=="Lead" then
        local p=mon(0); return p.maxHp==0 or p.hp*100<=p.maxHp*healPercent
    end
    for slot=0,partyCount()-1 do
        local p=mon(slot)
        if p.maxHp>0 and p.hp*100<=p.maxHp*healPercent then return true end
    end
    return false
end
local function partyFullyHealed()
    if partyCount()==0 then return false end
    for slot=0,partyCount()-1 do local p=mon(slot); if p.hp<p.maxHp then return false end end
    return true
end
local function rewriteChecksum(core,decrypted)
    local checksum=0
    for i=0,11 do
        local word=decrypted[i]
        checksum=(checksum+(word&0xFFFF)+((word>>16)&0xFFFF))&0xFFFF
        emu:write32(core.address+0x20+i*4,word~core.key)
    end
    emu:write16(core.address+0x1C,checksum)
end
local function healPartyDirect()
    -- Calling Emerald's HealPlayerParty routine by replacing PC/LR can strand
    -- the emulator in a game callback.  These are the unencrypted party status
    -- fields the routine ultimately restores, so writing them directly is both
    -- quicker and safe while the overworld callback is active in the Center.
    local healed=0
    for slot=0,partyCount()-1 do
        local address=GPLAYER_PARTY+slot*PARTY_SIZE
        local maximum=emu:read16(address+0x58)
        if maximum>0 then
            emu:write32(address+0x50,0)
            emu:write16(address+0x56,maximum)
            -- Restore PP using the move PP and PP-Up data stored by Emerald.
            local core=partyCore(slot)
            if core then
                local decrypted={}
                for i=0,11 do decrypted[i]=emu:read32(address+0x20+i*4)~core.key end
                local growthWord=core.order[1]*3+2
                local attacksWord=core.order[2]*3+2
                local ppUps=decrypted[growthWord]&0xFF
                local ppWord=0
                for i=0,3 do
                    local id=core.moves[i+1]
                    local base=id>0 and emu:read8(BATTLE_MOVES+id*12+4) or 0
                    local ups=(ppUps>>(i*2))&3
                    local maximumPp=base+math.floor(base*ups/5)
                    ppWord=ppWord|((maximumPp&0xFF)<<(i*8))
                end
                decrypted[attacksWord]=ppWord
                rewriteChecksum(core,decrypted)
            end
            healed=healed+1
        end
    end
    return healed>0 and partyFullyHealed()
end
local function strongestHealthyPartySlot()
    local best=nil
    for slot=0,partyCount()-1 do
        local p=mon(slot)
        local core=partyCore(slot)
        if p.hp>0 and p.maxHp>0 and core and core.species~=0 and not core.isEgg then
            if not best or p.level>best.level
                or (p.level==best.level and p.hp*best.maxHp>best.hp*p.maxHp) then
                best=p
            end
        end
    end
    return best and best.slot or nil
end
local function swapPartySlots(first,second)
    if first==second then return end
    local a,b=GPLAYER_PARTY+first*PARTY_SIZE,GPLAYER_PARTY+second*PARTY_SIZE
    local bytes={}
    for i=0,PARTY_SIZE-1 do bytes[i]=emu:read8(a+i) end
    for i=0,PARTY_SIZE-1 do emu:write8(a+i,emu:read8(b+i)) end
    for i=0,PARTY_SIZE-1 do emu:write8(b+i,bytes[i]) end
end
local function balanceLead()
    if grindMode=="Lead" then return end
    local best=nil
    local pickupSafe=grindMode=="Pickup"
    if pickupSafe then
        -- Pickup mode deliberately puts a healthy Zigzagoon/Linoone in front.
        -- Among multiple candidates, level the lowest one first.
        for slot=0,partyCount()-1 do
            local p=mon(slot)
            local core=partyCore(slot)
            if p.hp>0 and core and (core.species==288 or core.species==289) and core.ability==ABILITY_PICKUP
                and (not best or p.level<best.level or (p.level==best.level and p.hp*best.maxHp>best.hp*p.maxHp)) then best=p end
        end
    else
        for slot=0,partyCount()-1 do
            local p=mon(slot)
            if p.hp>0 and (not best or p.level<best.level or (p.level==best.level and p.hp*best.maxHp>best.hp*p.maxHp)) then best=p end
        end
    end
    if best and best.slot~=0 then
        swapPartySlots(0,best.slot)
        status=pickupSafe and string.format("Pickup: moved a healthy Zigzagoon/Linoone (Lv%d) into lead.",best.level)
            or string.format("Balanced: rotated the lowest-level usable Pokemon (Lv%d) into lead.",best.level)
    end
end
local function sharePickupExperience()
    if not (Pickup and Pickup.isRunning and Pickup:isRunning() and Pickup.experienceMask) then return 0 end
    local mask=Pickup:experienceMask()&0x3F
    if mask~=0 then
        -- Emerald records which party slots participated against each foe.
        -- Adding healthy Pickup slots makes the game perform its own split-EXP
        -- calculation without exposing a level-5 member to an attack.
        emu:write8(SENT_POKES_TO_OPPONENT,emu:read8(SENT_POKES_TO_OPPONENT)|mask)
        emu:write8(SENT_POKES_TO_OPPONENT+1,emu:read8(SENT_POKES_TO_OPPONENT+1)|mask)
    end
    return mask
end
local function readWarp(address)
    local result={}; for i=0,7 do result[i]=emu:read8(address+i) end; return result
end
local function writeWarp(address,data)
    for i=0,7 do emu:write8(address+i,data[i] or 0) end
end
local function makeWarp(group,num,x,y)
    return {[0]=group,[1]=num,[2]=0xFF,[3]=0,[4]=x&0xFF,[5]=(x>>8)&0xFF,[6]=y&0xFF,[7]=(y>>8)&0xFF}
end
local function callGame(address)
    local pc=emu:readRegister("pc")
    if not pc then return false end
    emu:writeRegister("lr",pc|1)
    emu:writeRegister("pc",address)
    callReturnFrames=2
    return true
end
local CENTERS={
    oldale={2,2},petalburg={8,4},rustboro={11,5},dewford={3,1},slateport={9,11},mauville={10,5},
    verdanturf={6,4},lavaridge={4,5},fallarbor={5,4},fortree={12,2},lilycove={13,6},mossdeep={14,3},
    evergrande={16,12},pacifidlog={7,0}
}
local ROUTE_CENTER={
    [0]="oldale",[1]="oldale",[2]="oldale",[3]="petalburg",[4]="dewford",[5]="mauville",[6]="mauville",
    [7]="lavaridge",[8]="fallarbor",[9]="fallarbor",[10]="rustboro",[11]="mauville",[12]="mauville",
    [13]="fortree",[14]="fortree",[15]="lilycove",[16]="lilycove",[17]="lilycove",[18]="lilycove",
    [19]="mossdeep",[20]="mossdeep",[21]="mossdeep",[22]="evergrande",[23]="evergrande",
    [24]="pacifidlog",[25]="pacifidlog",[26]="pacifidlog",[27]="pacifidlog",[28]="slateport"
}
local function nearestCenterWarp()
    -- Outdoor routes are map numbers 20..53 in map group 0; encounter header
    -- IDs 0..28 cover Routes 101..134 with a few gaps represented above.
    local s=save1(); if not s then return nil,"unknown" end
    local group,num=emu:read8(s+4),emu:read8(s+5)
    local centerName
    if group==0 and num>=16 and num<=49 then centerName=ROUTE_CENTER[num-16] end
    if group==0 and num==25 then
        -- Route 110: use Mauville for the northern half, Slateport for south.
        local y=emu:read16(s+2); centerName=y>55 and "slateport" or "mauville"
    end
    local center=CENTERS[centerName or ""]
    if center then return makeWarp(center[1],center[2],7,8),centerName end
    return readWarp(s+0x1C),"last visited"
end
local function inBattle()
    -- gBattleTypeFlags remains populated briefly after returning to the field,
    -- so the live callback is the reliable boundary for a finished battle.
    return sameFunction(emu:read32(GMAIN+4),CB2_BATTLE)
end
local function shinyEnemy()
    local core=pokemonCore(ENEMY_PARTY)
    if not core or core.species==0 or core.isEgg then return nil end
    local s2=emu:read32(SAVE2_PTR)
    if s2<0x02000000 or s2>=0x02040000 then return nil end
    local tid,sid=emu:read16(s2+0xA),emu:read16(s2+0xC)
    local value=tid~sid~(core.pid&0xFFFF)~((core.pid>>16)&0xFFFF)
    return value<8 and core or nil
end
local function tap(key)
    if frames%6==1 then inputMask=1<<key end
end
local function moveCursorToward(current,target)
    if current==target then tap(KEY_A)
    elseif current<2 and target>=2 then tap(KEY_DOWN)
    elseif current>=2 and target<2 then tap(KEY_UP)
    elseif current%2==0 and target%2==1 then tap(KEY_RIGHT)
    else tap(KEY_LEFT) end
end
local function moveListCursorKey(current,target)
    if current==target then return KEY_A end
    local down=(target-current)%5
    local up=(current-target)%5
    return down<=up and KEY_DOWN or KEY_UP
end
local function moveListCursorToward(current,target)
    tap(moveListCursorKey(current,target))
end
local function partyCursorKey(current,target)
    -- Emerald's single-battle party screen is a linear 0..5 list. Cancel is
    -- slot 7, and Down wraps it back to slot 0.
    if current==target then return KEY_A end
    if current>5 or current<0 then return KEY_DOWN end
    return current<target and KEY_DOWN or KEY_UP
end
local function faintPartyMenuOpen()
    return (emu:read8(GPARTY_MENU+8)&0xF)==1 and emu:read8(GPARTY_MENU+11)==1
end
local function handleFaintReplacement()
    if not faintPartyMenuOpen() then return false end

    local target=faintReplacementSlot
    if target==nil or target>=partyCount() or mon(target).hp==0 then
        target=strongestHealthyPartySlot()
        if target==nil then
            stop("No healthy Pokemon can replace the fainted battler. Pickup stopped safely.")
            return true
        end
        faintReplacementSlot=target
        faintSwitches=faintSwitches+1
    end

    needsCenter=true
    if (emu:read32(BATTLE_FLAGS)&(1<<3))==0 then emergencyEscape=true end
    status=string.format("A Pokemon fainted. Choosing party slot %d automatically.",target+1)
    tap(partyCursorKey(emu:read8(GPARTY_MENU+9),target))
    return true
end
local function ensureLearnDecision(slot,newMove)
    if newMove==0 then return false end
    if learnMoveId~=newMove or learnPartySlot~=slot or learnDecision==nil then
        learnMoveId,learnPartySlot=newMove,slot
        local detail; learnDecision,detail=chooseMoveReplacement(slot,newMove)
        lastMoveDecision="Move decision: "..detail.."."
        status=lastMoveDecision
    end
    return true
end
local function handleEvolutionChoice(evolutionTask)
    local evoState=emu:read16(evolutionTask+8)
    if evoState>14 then return false end
    local preSpecies=emu:read16(evolutionTask+10)
    local postSpecies=emu:read16(evolutionTask+12)
    local slot=emu:read16(evolutionTask+28)&0xFF
    local key=string.format("%d:%d:%d",slot,preSpecies,postSpecies)
    local accept,detail=shouldAcceptEvolution(slot,preSpecies,postSpecies)
    if evolutionDecisionKey~=key then
        evolutionDecisionKey=key
        lastEvolutionDecision="Evolution decision: "..detail.."."
        status=lastEvolutionDecision
    end
    if accept then return false end
    -- Emerald only permits cancelling while the two sprites are cycling.
    -- Holding B here uses the game's normal cancellation path.
    if evoState==8 then tap(KEY_B) end
    return true
end
local function handleMoveLearning()
    local evolutionTask=findTask(TASK_EVOLUTION)
    local replaceTask=findTask(TASK_REPLACE_MOVE)
    local script=emu:read32(BATTLE_SCRIPT_PTR)
    local newMove=emu:read16(MOVE_TO_LEARN)
    local slot=0
    if evolutionTask then
        slot=emu:read16(evolutionTask+28)&0xFF
        if handleEvolutionChoice(evolutionTask) then return true end
    else
        local bs=emu:read32(BATTLE_STRUCT_PTR)
        if bs>=0x02000000 and bs<0x02040000 then slot=emu:read8(bs+8) end
    end
    if replaceTask then
        if not ensureLearnDecision(slot,newMove) then return true end
        if learnDecision==4 then
            -- The source uses B as the direct Cancel path on this five-row
            -- screen.  This also avoids ever attempting to delete an HM.
            tap(KEY_B)
        else
            local summary=emu:read32(SUMMARY_PTR)
            if summary>=0x02000000 and summary<0x02040000 then
                local cursor=emu:read8(summary+0x40C6)
                moveListCursorToward(cursor,learnDecision)
            end
        end
        return true
    end
    local ask=false; local confirm=false
    if script==ASK_LEARN_MOVE+0x11 then ask=true elseif script==ASK_LEARN_MOVE+0x20 then confirm=true end
    if evolutionTask and emu:read16(evolutionTask+8)==22 then
        local d6,d7=emu:read16(evolutionTask+8+12),emu:read16(evolutionTask+8+14)
        if d6==4 and d7==5 then ask=true elseif d6==4 and d7==11 then confirm=true end
    end
    if ask then
        if not ensureLearnDecision(slot,newMove) then return true end
        tap(learnDecision<=3 and KEY_A or KEY_B); return true
    elseif confirm then
        tap(KEY_A); return true
    end
    return false
end
local function bestBattleMove()
    local slot=emu:read8(0x0202406E)
    local species=emu:read16(BATTLE_MONS)
    local best,bestScore=nil,-100001
    for index=0,3 do
        local id=emu:read16(BATTLE_MONS+0x0C+index*2)
        local pp=emu:read8(BATTLE_MONS+0x24+index)
        if id~=0 and pp>0 then
            local score=moveScore(id,slot,species,"battle")
            if score>bestScore then best,bestScore=index,score end
        end
    end
    return best or 0
end
local function handleBattleInput()
    local hp,maxHp=emu:read16(BATTLE_MONS+0x28),emu:read16(BATTLE_MONS+0x2C)
    if maxHp>0 and hp*100<=maxHp*healPercent then
        needsCenter=true
        if (emu:read32(BATTLE_FLAGS)&(1<<3))==0 then
            emergencyEscape=true
            status=string.format("HP is %d/%d. Running from this wild battle, then healing.",hp,maxHp)
        else
            status="HP is low in a Trainer battle. Finishing it, then healing."
        end
    end
    if handleMoveLearning() then return end
    local controller=emu:read32(CONTROLLER_FUNCS)
    if emergencyEscape then
        if sameFunction(controller,CHOOSE_MOVE) then tap(KEY_B)
        elseif sameFunction(controller,CHOOSE_ACTION) then moveCursorToward(emu:read8(ACTION_CURSOR),3)
        else tap(KEY_A) end
    elseif sameFunction(controller,CHOOSE_ACTION) then
        moveCursorToward(emu:read8(ACTION_CURSOR),0)
    elseif sameFunction(controller,CHOOSE_MOVE) then
        moveCursorToward(emu:read8(MOVE_CURSOR),bestBattleMove())
    else
        tap(KEY_A)
    end
end
local function render(force)
    local now=os.clock()
    if not force and now-lastRenderClock<0.20 then return end
    lastRenderClock=now
    local lines={"BATTLE | Emerald  |  "..(active and "RUNNING" or "READY"),
        string.format("Mode: %s   Wins: %d   Heal: %d%%",grindMode,battlesWon,healPercent),
        string.format("Time: %s   Wins/hour: %.1f",stats:formatElapsed(statsMode),stats:rate(statsMode,"battles")),
        partySummary(),"",status,"",
        "B start/stop   1 Lead   2 Balanced   H heal limit"}
    local text=table.concat(lines,"\n")
    if force or text~=lastText then panel:clear(); panel:print(text); lastText=text end
end
stop=function(message)
    active,state,inputMask=false,"idle",0; BATTLE_AUTOMATION_ACTIVE=false; emu:clearKeys(0x3FF)
    stats:stop(statsMode)
    status=message or "Stopped. Press B to start again."; render(true)
end
local function start()
    if active then stop(); return end
    if starterHunter then local r=starterHunter:getRuntimeState(); if r and r.mode~="idle" and r.mode~="error" and r.mode~="success" then status="Stop the RNG tool first."; render(true); return end end
    local s=save1(); if not s or partyCount()==0 then status="Load an Emerald save with at least one party Pokemon."; render(true); return end
    if not BATTLE_TEST_ALLOW_NON_ENCOUNTER and starterHunter then
        local environment=starterHunter:getEnvironmentDiagnostics()
        if not environment or not environment.encounter then
            status="Stand on a wild encounter tile (grass, cave floor, or water), then press Q."
            render(true); return
        end
    end
    startMapGroup,startMapNum=emu:read8(s+4),emu:read8(s+5)
    startX,startY=emu:read16(s),emu:read16(s+2)
    startWarp=makeWarp(startMapGroup,startMapNum,startX,startY)
    active,state,frames,battlesWon,centerTrips,turns=true,"grinding",0,0,0,0
    statsMode=grindMode=="Pickup" and "Pickup" or "Battle"
    stats:start(statsMode,not stats:snapshot(statsMode).active)
    emergencyEscape,needsCenter,learnDecision,learnMoveId,learnPartySlot=false,false,nil,nil,nil; BATTLE_AUTOMATION_ACTIVE=true
    evolutionDecisionKey=nil
    faintReplacementSlot,faintSwitches=nil,0
    balanceLead(); status=string.format("Grinding on map %d:%d, tile %d,%d.",startMapGroup,startMapNum,startX,startY); render(true)
end
local function beginHealTrip()
    centerTrips=centerTrips+1
    -- ROM callback warps can leave mGBA stuck after the Center map loads.
    -- Restore the same party fields safely and stay on the remembered tile.
    if not healPartyDirect() then stop("Could not heal the party safely."); return end
    state,frames="grinding",0
    balanceLead()
    status="Party healed safely. Grinding resumed on the saved tile."
end
local function onKey(event)
    if BATTLE_DISABLE_KEYS then return end
    if event.state~=1 or ((event.modifiers or 0)&0xC)~=0 or event.key<32 or event.key>126 then return end
    local c=string.char(event.key):lower()
    if c=="b" or c=="q" then start()
    elseif c=="r" and active then stop()
    elseif c=="1" and not active then grindMode="Lead"; status="Lead mode selected."; render(true)
    elseif c=="2" and not active then grindMode="Balanced"; status="Balanced mode selected."; render(true)
    elseif c=="h" and not active then healPercent=healPercent==30 and 20 or 30; status=string.format("Healing threshold set to %d%%.",healPercent); render(true) end
end
local spinKeys={KEY_UP,KEY_RIGHT,KEY_DOWN,KEY_LEFT}
local function tick()
    frames=frames+1; inputMask=0
    if testWarpFrames>0 then
        testWarpFrames=testWarpFrames-1
        if testWarpFrames==0 then emu:write32(GMAIN+4,CB2_LOAD_MAP+1) end
        return
    end
    if not active then if frames%60==0 then render(false) end; return end
    if callReturnFrames>0 then callReturnFrames=callReturnFrames-1; return end
    local battle=inBattle()
    if battle then
        local shiny=shinyEnemy()
        if shiny and shiny.pid~=shinyStoppedPid then
            shinyStoppedPid=shiny.pid
            stop(string.format("SHINY %s found! PID %08X. Automation stopped before choosing a move.",speciesName(shiny.species),shiny.pid))
            return
        end
        faintReplacementSlot=nil
        state="battle"
        sharePickupExperience()
        handleBattleInput()
        wasInBattle=true
    elseif wasInBattle then
        local callback=emu:read32(GMAIN+4)
        local evolutionTask=findTask(TASK_EVOLUTION)
        local replaceTask=findTask(TASK_REPLACE_MOVE)
        local overworld=sameFunction(callback,CB2_OVERWORLD)
        local partyScreen=sameFunction(callback,CB2_PARTY_MENU) or sameFunction(callback,CB2_PARTY_MENU_INIT)
        if partyScreen and faintPartyMenuOpen() then
            -- Do not send the generic post-battle A input while Emerald is
            -- constructing this menu; wait until its input callback is live.
            if sameFunction(callback,CB2_PARTY_MENU) and handleFaintReplacement() then state="faint_switch"
            else state="faint_switch_wait" end
        elseif evolutionTask or replaceTask or not overworld then
            state="post_battle"
            if not handleMoveLearning() then tap(KEY_A) end
        else
            wasInBattle=false
            if emu:read8(BATTLE_OUTCOME)==1 then
                battlesWon=battlesWon+1
                stats:inc(statsMode,"battles",1)
                -- Pickup is a separate panel, but it deliberately reuses this
                -- proven battle loop. Emerald has already performed its normal
                -- post-battle Pickup rolls by the time this hook runs.
                if Pickup and Pickup.onBattleFinished and Pickup:onBattleFinished()==false then
                    stop(Pickup:getStatus())
                    return
                end
            end
            balanceLead()
            learnDecision,learnMoveId,learnPartySlot=nil,nil,nil
            if needsCenter or emergencyEscape or shouldHeal() then
                emergencyEscape,needsCenter=false,false; beginHealTrip()
            else
                state="grinding"; status="Battle finished. Spinning for the next encounter."
            end
        end
    elseif state=="grinding" then
        if shouldHeal() then beginHealTrip()
        elseif frames%6==1 then
            local objectEventId=emu:read8(GPLAYER_AVATAR+5)
            local facing=objectEventId<16 and emu:read16(GOBJECT_EVENTS+objectEventId*0x24+0x18)&0xF or 0
            -- Derive every turn from the current object state. No spin state is
            -- carried through a battle, and the chosen direction cannot move
            -- the player because it is always different from the live facing.
            local nextKey=({[1]=KEY_LEFT,[3]=KEY_UP,[2]=KEY_RIGHT,[4]=KEY_DOWN})[facing]
            if nextKey then inputMask=1<<nextKey; turns=turns+1 end
        end
    elseif state=="warp_center" and frames>=4 then
        emu:write32(GMAIN+4,CB2_LOAD_MAP+1); state,frames="wait_center",0
    elseif state=="wait_center" then
        if sameFunction(emu:read32(GMAIN+4),CB2_OVERWORLD) and frames>60 then
            state,frames="heal_center",0; status="At the Pokemon Center. Healing the party."
            if not healPartyDirect() then stop("Could not heal the party safely.") end
        elseif frames==600 then
            -- Recover if a map-load callback was missed instead of waiting forever.
            emu:write32(GMAIN+4,CB2_LOAD_MAP+1)
        elseif frames>1200 then stop("The Pokemon Center did not finish loading. Battle stopped safely.") end
    elseif state=="heal_center" then
        if partyFullyHealed() and frames>15 then
            status="Healed. Returning to the saved grinding tile."
            writeWarp(WARP_DEST,startWarp); state,frames="warp_return",0
            if not callGame(WARP_INTO_MAP) then stop("Could not return to the grinding tile.") end
        elseif frames>180 then stop("Healing did not finish. Battle stopped safely.") end
    elseif state=="warp_return" and frames>=4 then
        emu:write32(GMAIN+4,CB2_LOAD_MAP+1); state,frames="wait_return",0
    elseif state=="wait_return" then
        local s=save1()
        if s and sameFunction(emu:read32(GMAIN+4),CB2_OVERWORLD) and emu:read8(s+4)==startMapGroup and emu:read8(s+5)==startMapNum and frames>60 then
            state,frames="grinding",0; balanceLead(); status="Back on the saved tile. Grinding resumed."
        elseif frames==600 then emu:write32(GMAIN+4,CB2_LOAD_MAP+1)
        elseif frames>1200 then stop("Could not return to the grinding tile. Battle stopped safely.") end
    end
    if STARTER_HUNTER_HEADLESS then emu:setKeys(inputMask) end
    render(false)
end

Battle={}
function Battle:start() start(); return active end
function Battle:stop() stop(); return true end
function Battle:setMode(value)
    if active then return false end
    local v=tostring(value):lower()
    grindMode=v:find("pick") and "Pickup" or (v:find("bal") and "Balanced" or "Lead")
    render(true); return true
end
function Battle:setHealPercent(value) local n=tonumber(value); if active or (n~=20 and n~=30) then return false end; healPercent=n; render(true); return true end
function Battle:getState() return {active=active,state=state,status=status,mode=grindMode,healPercent=healPercent,battlesWon=battlesWon,centerTrips=centerTrips,turns=turns,keyPolls=keyPolls,emergencyEscape=emergencyEscape,needsCenter=needsCenter,faintSwitches=faintSwitches,faintReplacementSlot=faintReplacementSlot,lastMoveDecision=lastMoveDecision,lastEvolutionDecision=lastEvolutionDecision,startMapGroup=startMapGroup,startMapNum=startMapNum,startX=startX,startY=startY,session=stats:snapshot(statsMode)} end
function Battle:testSharePickupExperience() if not BATTLE_TEST_ALLOW_NON_ENCOUNTER then return 0 end; return sharePickupExperience() end
function Battle:testChooseMove(slot,newMove)
    local decision,detail=chooseMoveReplacement(tonumber(slot) or 0,tonumber(newMove) or 0)
    return decision,detail
end
function Battle:testMoveScore(slot,moveId,purpose)
    if not BATTLE_TEST_ALLOW_NON_ENCOUNTER then return nil end
    local core=partyCore(tonumber(slot) or 0)
    return core and moveScore(tonumber(moveId) or 0,tonumber(slot) or 0,core.species,purpose or "learn") or nil
end
function Battle:testEvolutionPolicy(slot,preSpecies,postSpecies)
    if not BATTLE_TEST_ALLOW_NON_ENCOUNTER then return nil end
    return shouldAcceptEvolution(tonumber(slot) or 0,tonumber(preSpecies) or 0,tonumber(postSpecies) or 0)
end
function Battle:testPartySpecies(slot)
    local core=partyCore(tonumber(slot) or 0); return core and core.species or 0
end
function Battle:testStrongestHealthySlot()
    if not BATTLE_TEST_ALLOW_NON_ENCOUNTER then return nil end
    return strongestHealthyPartySlot()
end
function Battle:testDirectHeal()
    if not PICKUP_ENABLE_TEST_API then return false end
    return healPartyDirect()
end
function Battle:testPartyCursorKey(current,target)
    if not BATTLE_TEST_ALLOW_NON_ENCOUNTER then return nil end
    return partyCursorKey(tonumber(current) or 0,tonumber(target) or 0)
end
function Battle:testMoveListCursorKey(current,target)
    if not BATTLE_TEST_ALLOW_NON_ENCOUNTER then return nil end
    return moveListCursorKey((tonumber(current) or 0)%5,(tonumber(target) or 0)%5)
end
function Battle:testPrepareMoveLearning(slot,level,moves)
    if not BATTLE_TEST_ALLOW_NON_ENCOUNTER then return false end
    local core=partyCore(tonumber(slot) or 0); if not core then return false end
    local targetLevel=math.max(2,math.min(99,tonumber(level) or 40))
    local list=type(moves)=="table" and moves or {33,45,39,29}
    local decrypted={}
    for i=0,11 do decrypted[i]=emu:read32(core.address+0x20+i*4)~core.key end
    local growthBase=core.order[1]*3
    local attacksBase=core.order[2]*3
    -- The live test uses Zigzagoon's Medium Fast curve and stops one EXP
    -- before the requested next level so the next battle triggers the prompt.
    decrypted[growthBase+1]=(targetLevel+1)^3-1
    decrypted[growthBase+2]=decrypted[growthBase+2]&0xFFFFFF00
    decrypted[attacksBase]=((tonumber(list[2]) or 0)&0xFFFF)<<16|((tonumber(list[1]) or 0)&0xFFFF)
    decrypted[attacksBase+1]=((tonumber(list[4]) or 0)&0xFFFF)<<16|((tonumber(list[3]) or 0)&0xFFFF)
    local pp=0
    for i=1,4 do
        local id=tonumber(list[i]) or 0
        pp=pp|(((id>0 and emu:read8(BATTLE_MOVES+id*12+4) or 0)&0xFF)<<((i-1)*8))
    end
    decrypted[attacksBase+2]=pp
    rewriteChecksum(core,decrypted)
    emu:write8(core.address+0x54,targetLevel)
    return true
end
function Battle:testPartyMoves(slot)
    if not BATTLE_TEST_ALLOW_NON_ENCOUNTER then return nil end
    local core=partyCore(tonumber(slot) or 0); return core and core.moves or nil
end
function Battle:testBeginEvolution(targetSpecies)
    if not active then return false end
    emu:write32(AFTER_EVOLUTION_CALLBACK,CB2_OVERWORLD+1)
    emu:writeRegister("r0",GPLAYER_PARTY)
    emu:writeRegister("r1",tonumber(targetSpecies) or 259)
    emu:writeRegister("r2",1)
    emu:writeRegister("r3",0)
    wasInBattle=true; state="post_battle"
    return callGame(BEGIN_EVOLUTION)
end
function Battle:testBeginHeal() if not active then start() end; if active then beginHealTrip() end; return active end
function Battle:testWarpTo(x,y)
    if active then return false end
    local s=save1(); if not s then return false end
    writeWarp(WARP_DEST,makeWarp(emu:read8(s+4),emu:read8(s+5),tonumber(x),tonumber(y)))
    if not callGame(WARP_INTO_MAP) then return false end
    testWarpFrames=4
    return true
end

callbacks:add("key",onKey)
callbacks:add("keysRead",function() if active then keyPolls=keyPolls+1; emu:setKeys(inputMask) end end)
frameClock:add(tick)
render(true)
