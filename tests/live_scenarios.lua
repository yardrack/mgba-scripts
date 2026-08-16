-- Real-mGBA behavior matrix: full-bag Pickup -> PC, one automated battle, and
-- one Hunter encounter/flee. Each process runs against a disposable savestate.
local root=os.getenv("GEN3_TEST_ROOT")
local resultPath=os.getenv("GEN3_TEST_RESULT")
local checkpoint=os.getenv("GEN3_TEST_STATE")
local encounterCheckpoint=os.getenv("GEN3_TEST_ENCOUNTER_STATE") or checkpoint
local names={BPEE="Emerald",AXVE="Ruby",AXPE="Sapphire",BPRE="FireRed",BPGE="LeafGreen"}
local finished=false
local progressPath=resultPath and (resultPath..".progress")
local function progress(text)
    local file=progressPath and io.open(progressPath,"w"); if file then file:write(text.."\n"); file:close() end
end
local function finish(text)
    if finished then return end
    local file=io.open(resultPath,"w"); if file then file:write(text.."\n"); file:close() end
    finished=true
end
local code=dofile(root.."/lib/GameCode.lua").current(emu)
if not root or not resultPath or not checkpoint or not names[code] then finish("FAIL environment"); return end

GEN3_SUITE_GAME=code; GEN3_SUITE_NAME=names[code]; GEN3_SUITE_DIR=root; STARTER_HUNTER_DIR=root
PICKUP_ENABLE_TEST_API=true
STARTER_HUNTER_HEADLESS=true
EMERALD_AUTOMATION_HEADLESS=true
local ok,problem=xpcall(function() dofile(root.."/lib/GameSuite.lua") end,debug.traceback)
if not ok then finish("FAIL load "..tostring(problem)); return end
local profile=dofile(root.."/lib/GameProfiles.lua").resolve(code,emu:read8(0x080000BC))
local Inventory=dofile(root.."/lib/InventoryCore.lua")
local inventory=Inventory.new({emu=emu,profile=profile})
local orders={
 {0,1,2,3},{0,1,3,2},{0,2,1,3},{0,3,1,2},{0,2,3,1},{0,3,2,1},
 {1,0,2,3},{1,0,3,2},{2,0,1,3},{3,0,1,2},{2,0,3,1},{3,0,2,1},
 {1,2,0,3},{1,3,0,2},{2,1,0,3},{3,1,0,2},{2,3,0,1},{3,2,0,1},
 {1,2,3,0},{1,3,2,0},{2,1,3,0},{3,1,2,0},{2,3,1,0},{3,2,1,0}}
local function validRam(a) return a and a>=0x02000000 and a<0x02040000 end
local function save1()
    local a=profile.save1 or emu:read32(profile.save1Ptr)
    return validRam(a) and a or nil
end
local function save2()
    local a=profile.save2 or emu:read32(profile.save2Ptr)
    return validRam(a) and a or nil
end
local function bagKey()
    if profile.bagKey~=nil then return profile.bagKey end
    return emu:read16(assert(save2())+profile.bagKeyOffset)
end
local function injectPickupMon(item)
    assert(emu:read8(profile.partyCount)>0,"checkpoint has no party")
    local address=profile.party
    local pid,ot=emu:read32(address),emu:read32(address+4)
    assert(pid~=0 or ot~=0,"party slot 1 is empty")
    local order,key=orders[(pid%24)+1],pid~ot
    local words={}
    for i=0,11 do words[i]=emu:read32(address+0x20+i*4)~key end
    local growth,misc=order[1]*3,order[4]*3+1
    words[growth]=((item&0xFFFF)<<16)|288 -- internal Zigzagoon species
    words[misc]=words[misc]&0x7FFFFFFF -- ability slot 0 = Pickup
    local checksum=0
    for i=0,11 do
        checksum=(checksum+(words[i]&0xFFFF)+((words[i]>>16)&0xFFFF))&0xFFFF
        emu:write32(address+0x20+i*4,words[i]~key)
    end
    emu:write16(address+0x1C,checksum)
end
local function makeFullBag()
    local s1,key=assert(save1()),bagKey()
    for slot=0,profile.pcItemsCapacity-1 do emu:write16(s1+profile.pcItemsOffset+slot*4,0); emu:write16(s1+profile.pcItemsOffset+slot*4+2,0) end
    for pocketId=1,5 do
        local pocket=profile.bagPockets[pocketId]
        for slot=0,pocket.capacity-1 do
            local id=pocket.protected and 50 or ((pocketId==3 and slot==0) and 339 or 13)
            local address=s1+pocket.offset+slot*4
            emu:write16(address,id); emu:write16(address+2,1~key)
        end
    end
end
local function pickupFullBagScenario()
    makeFullBag(); injectPickupMon(14)
    local collected
    if code=="BPEE" then collected=select(1,Pickup:collect()) else collected=Pickup:testCollect() end
    assert(collected,"Pickup collection failed: "..tostring(Pickup:getStatus()))
    local bag,pc=inventory:scanBag(),inventory:scanPc()
    assert((bag.byId[14] or 0)>=1,"held Pickup item was not added after evacuation")
    assert((pc.byId[13] or 0)>0,"full bag was not moved to PC")
    assert((bag.byId[50] or 0)>0 and (bag.byId[339] or 0)>0,"protected key/HM moved to PC")
    assert(Pickup:testHeldItem(0)==0,"held item was not cleared after successful collection")
    return pc.byId[13]
end
local function forceWildEncounter()
    local pc=emu:readRegister("pc")
    if not pc or not profile.sweetScentEncounter then return false end
    emu:writeRegister("lr",pc|1)
    emu:writeRegister("pc",profile.sweetScentEncounter)
    return true
end
local function ensureEnemyIsNotShiny()
    local s2=save2(); if s2 then emu:write16(s2+0x0A,emu:read16(s2+0x0A)~0x0100) end
end

local phase,phaseFrames="boot",0
local captureFrame,pickupMoved,battleWins,hunterEncounters,hunterFled=0,0,0,0,0
local lastFacing,facingChanges=nil,0
local testWalkMask=0
callbacks:add("keysRead",function() if testWalkMask~=0 then emu:setKeys(testWalkMask) end end)
callbacks:add("frame",function()
    if finished then return end
    phaseFrames=phaseFrames+1
    local liveObject=emu:read8(profile.playerAvatar+5)
    local liveFacing=liveObject<16 and (emu:read16(profile.objectEvents+liveObject*0x24+0x18)&0xF) or -1
    if lastFacing~=nil and liveFacing~=lastFacing then facingChanges=facingChanges+1 end
    lastFacing=liveFacing
    local stepOk,stepProblem=xpcall(function()
        if phase=="boot" and phaseFrames>=30 then
            phase,phaseFrames="settle",0
            progress("loading initial checkpoint")
            emu:loadStateFile(checkpoint); return
        elseif phase=="settle" and phaseFrames>=90 then
            local capture=assert(ManualMonitor:snapshot(),"Capture snapshot unavailable")
            assert(capture.kind=="starter" or capture.kind=="wild","Capture mode invalid")
            captureFrame=assert(capture.videoFrame,"Capture frame unavailable")
            pickupMoved=pickupFullBagScenario()
            phase,phaseFrames="battle-settle",0
            progress("Pickup passed; reloading for Battle")
            emu:loadStateFile(encounterCheckpoint); return
        elseif phase=="battle-settle" and phaseFrames>=90 then
            ensureEnemyIsNotShiny()
            Gen3Suite.selectTool("Battle"); Battle:setMode("Lead"); Battle:start()
            assert(Battle:getState().active,"Battle did not start: "..tostring(Battle:getState().status))
            phase,phaseFrames="battle",0
            progress("Battle running")
        elseif phase=="battle" then
            local battleState=Battle:getState()
            battleWins=battleState.battlesWon or 0
            if code=="AXPE" and not battleState.inBattle then
                local keys={4,5,6,7}; testWalkMask=1<<keys[(math.floor(phaseFrames/45)%4)+1]
            else testWalkMask=0 end
            if battleWins>=1 then
                Battle:stop()
                phase,phaseFrames="hunter-settle",0
                progress("Battle passed; reloading for Hunter")
                emu:loadStateFile(encounterCheckpoint); return
            elseif phaseFrames>9000 then error("Battle timeout: "..tostring(Battle:getState().status)) end
        elseif phase=="hunter-settle" and phaseFrames>=90 then
            ensureEnemyIsNotShiny()
            Gen3Suite.selectTool("Hunter")
            if code=="AXPE" then
                phase,phaseFrames="hunter-encounter",0
                progress("Walking Sapphire encounter tile for Hunter")
            else
                Hunter:start(); assert(Hunter:getState().active,"Hunter did not start")
                phase,phaseFrames="hunter",0
                progress("Hunter running")
            end
        elseif phase=="hunter-encounter" then
            local keys={4,5,6,7}; testWalkMask=1<<keys[(math.floor(phaseFrames/45)%4)+1]
            local callback=emu:read32(profile.gMain+4)
            if callback==profile.cb2Battle or callback==profile.cb2Battle+1 then
                testWalkMask=0; Hunter:start(); assert(Hunter:getState().active,"Hunter did not start in battle")
                phase,phaseFrames="hunter",0; progress("Hunter entered battle")
            elseif phaseFrames>9000 then error("Sapphire Hunter encounter timeout") end
        elseif phase=="hunter" then
            local state=Hunter:getState(); hunterEncounters,hunterFled=state.encounters or 0,state.fled or 0
            if code=="AXPE" and state.state~="battle" then
                local keys={4,5,6,7}; testWalkMask=1<<keys[(math.floor(phaseFrames/45)%4)+1]
            else testWalkMask=0 end
            if hunterEncounters>=1 and hunterFled>=1 then
                Hunter:stop()
                finish(string.format("PASS code=%s captureFrame=%d pickupPc=%d battleWins=%d hunterEncounters=%d hunterFled=%d",
                    code,captureFrame,pickupMoved,battleWins,hunterEncounters,hunterFled))
            elseif not state.active then error("Hunter stopped early: "..tostring(state.status))
            elseif phaseFrames>9000 then error("Hunter timeout: "..tostring(state.status)) end
        end
        if phaseFrames%600==0 then
            local battleState=Battle and Battle:getState() or {}
            local objectId=emu:read8(profile.playerAvatar+5)
            local facing=objectId<16 and (emu:read16(profile.objectEvents+objectId*0x24+0x18)&0xF) or -1
            local controller=profile.battlerControllerFuncs and emu:read32(profile.battlerControllerFuncs) or 0
            progress(string.format("phase=%s frames=%d wins=%d encounters=%d fled=%d turns=%s keyPolls=%s facing=%d facingChanges=%d keys=%d inBattle=%s callback=%s enemyHp=%s controller=%08X chooseAction=%08X chooseMove=%08X action=%d move=%d battleState=%s battleStatus=%s",
                phase,phaseFrames,battleWins,hunterEncounters,hunterFled,tostring(battleState.turns),tostring(battleState.keyPolls),facing,facingChanges,emu:getKeys(),tostring(battleState.inBattle),tostring(battleState.callback),tostring(battleState.enemyHp),controller,profile.chooseAction or 0,profile.chooseMove or 0,emu:read8(profile.battleActionCursor),emu:read8(profile.battleMoveCursor),tostring(battleState.state),tostring(battleState.status)))
        end
    end,debug.traceback)
    if not stepOk then finish("FAIL phase="..phase.." "..tostring(stepProblem)) end
end)
