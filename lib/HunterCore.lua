-- Automatic shiny encounter hunter core for English Gen 3 Pokemon games.
-- H starts or stops. The script spins in place, flees ordinary wild battles,
-- and releases every automated input as soon as a shiny opponent is resolved.

local code=GEN3_GAME_CODE or tostring(emu:getGameCode()):sub(-4)
local supported={BPEE=true,AXVE=true,AXPE=true,BPRE=true,BPGE=true}
if not supported[code] then error("Hunter requires an English Gen 3 Pokemon game.") end

local suiteDir=GEN3_SUITE_DIR or (script and script.dir)
if not suiteDir then error("Hunter could not locate the suite folder.") end
STARTER_HUNTER_DIR=suiteDir
local frameClock=GEN3_FRAME_CLOCK or dofile(suiteDir.."/lib/FrameClock.lua")
local revision=emu:read8(0x080000BC)
local game=dofile(suiteDir.."/lib/GameProfiles.lua").resolve(code,revision)
local stats=GEN3_SESSION_STATS or dofile(suiteDir.."/lib/SessionStats.lua").forGame(emu,code)

if not game.gMain or not game.cb2Overworld or not game.cb2Battle or not game.objectEvents or
   not game.enemy or (not game.save2 and not game.save2Ptr) or
   not game.actionSelectionCursor or not game.battlerControllerFuncs or not game.chooseAction then
    error("Hunter has no complete memory profile for this ROM revision.")
end

local KEY_A,KEY_B,KEY_UP,KEY_DOWN,KEY_LEFT,KEY_RIGHT=0,1,6,7,5,4
local MAX_RUN_ATTEMPTS=8
local SUBSTRUCT_ORDER={
    {0,1,2,3},{0,1,3,2},{0,2,1,3},{0,3,1,2},{0,2,3,1},{0,3,2,1},
    {1,0,2,3},{1,0,3,2},{2,0,1,3},{3,0,1,2},{2,0,3,1},{3,0,2,1},
    {1,2,0,3},{1,3,0,2},{2,1,0,3},{3,1,0,2},{2,3,0,1},{3,2,0,1},
    {1,2,3,0},{1,3,2,0},{2,1,3,0},{3,1,2,0},{2,3,1,0},{3,2,1,0}
}

local panel=console:createBuffer("Hunter")
panel:setSize(58,11)
local active=false
local state="idle"
local status="Stand on an encounter tile, then press H."
local frames,inputMask=0,0
local encounters,fled=0,0
local encounterPid=nil
local runAttempts=0
local lastRunFrame=-1000
local wasInBattle=false
local pendingFacing,pendingKey,pendingFrames=nil,nil,0
local lastText=""

local function sameFunction(pointer,address)
    return pointer==address or pointer==address+1
end

local function validRam(address)
    return address and address>=0x02000000 and address<0x02040000
end

local function save2Address()
    if game.save2 then return game.save2 end
    local address=emu:read32(game.save2Ptr)
    return validRam(address) and address or nil
end

local function readEnemy()
    local address=game.enemy
    local pid,ot=emu:read32(address),emu:read32(address+4)
    if pid==0 and ot==0 then return nil end
    local order=SUBSTRUCT_ORDER[(pid%24)+1]
    local key=pid~ot
    local growth=address+0x20+order[1]*12
    local species=(emu:read32(growth)~key)&0xFFFF
    if species==0 or species>411 then return nil end
    return {pid=pid,ot=ot,species=species,address=address}
end

local function shinyValue(pid)
    local save2=save2Address()
    if not save2 then return nil end
    local tid,sid=emu:read16(save2+0xA),emu:read16(save2+0xC)
    return (tid~sid~(pid&0xFFFF)~((pid>>16)&0xFFFF))&0xFFFF
end

local function inBattle()
    return sameFunction(emu:read32(game.gMain+4),game.cb2Battle)
end

local function inOverworld()
    return sameFunction(emu:read32(game.gMain+4),game.cb2Overworld)
end

local function tap(key)
    if frames%6==1 then inputMask=1<<key; return true end
    return false
end

local function moveCursorToward(current,target)
    if current==target then return tap(KEY_A) end
    if current<2 and target>=2 then tap(KEY_DOWN)
    elseif current>=2 and target<2 then tap(KEY_UP)
    elseif current%2==0 and target%2==1 then tap(KEY_RIGHT)
    else tap(KEY_LEFT) end
    return false
end

local function releaseInput()
    inputMask=0
    emu:setKeys(0)
    emu:clearKeys(0x3FF)
end

local function stop(message)
    stats:stop("Hunter")
    active=false
    state="idle"
    releaseInput()
    status=message or "Stopped."
end

local function start()
    stats:start("Hunter",true)
    active=true
    state=inBattle() and "battle" or "searching"
    frames,inputMask=0,0
    encounterPid=nil
    runAttempts=0
    lastRunFrame=-1000
    wasInBattle=false
    pendingFacing,pendingKey,pendingFrames=nil,nil,0
    status="Spinning for a wild encounter. Press H to stop."
end

local function spin()
    local objectEventId=emu:read8(game.playerAvatar+5)
    if objectEventId>=16 then return end
    local facing=emu:read16(game.objectEvents+objectEventId*0x24+0x18)&0xF
    if pendingFacing then
        if facing~=pendingFacing then
            pendingFacing,pendingKey,pendingFrames=nil,nil,0
        else
            pendingFrames=pendingFrames+1
            if pendingFrames>=12 then inputMask=1<<pendingKey; pendingFrames=0 end
        end
    end
    if not pendingFacing and frames%6==1 then
        local nextKey=({[1]=KEY_LEFT,[3]=KEY_UP,[2]=KEY_RIGHT,[4]=KEY_DOWN})[facing] or KEY_RIGHT
        inputMask=1<<nextKey
        pendingFacing,pendingKey,pendingFrames=facing,nextKey,0
    end
end

local function handleBattle()
    state="battle"
    pendingFacing,pendingKey,pendingFrames=nil,nil,0
    wasInBattle=true

    local enemy=readEnemy()
    if enemy and enemy.pid~=encounterPid then
        encounterPid=enemy.pid
        encounters=encounters+1
        stats:inc("Hunter","encounters",1)
        runAttempts=0
        local value=shinyValue(enemy.pid)
        if not value then
            stop("Could not read the live trainer IDs. Hunter stopped before choosing an action.")
            return
        elseif value<8 then
            stats:inc("Hunter","shinies",1)
            stop(string.format("SHINY FOUND | Species %d | PID %08X | SV %d",enemy.species,enemy.pid,value))
            return
        end
        status=string.format("Encounter %d | Species %d | PID %08X | fleeing",encounters,enemy.species,enemy.pid)
    end

    if not enemy then tap(KEY_B); return end
    local controller=emu:read32(game.battlerControllerFuncs)
    if sameFunction(controller,game.chooseAction) then
        local cursor=emu:read8(game.actionSelectionCursor)
        if cursor==3 then
            if runAttempts>=MAX_RUN_ATTEMPTS then
                stop("Could not flee after eight attempts. Hunter stopped safely.")
            elseif frames-lastRunFrame>=24 and moveCursorToward(cursor,3) then
                runAttempts=runAttempts+1
                lastRunFrame=frames
            end
        else
            moveCursorToward(cursor,3)
        end
    else
        -- B advances battle text and also backs out of Fight, Bag, or Party if
        -- the script is loaded while one of those menus is already open.
        tap(KEY_B)
    end
end

local function render(force)
    if not force and frames%15~=0 then return end
    local text=table.concat({
        "HUNTER | "..game.name.." | "..(active and "RUNNING" or "READY"),
        string.format("Encounters: %d   Fled: %d",encounters,fled),
        string.format("Time: %s   Encounters/hour: %.1f",stats:formatElapsed("Hunter"),stats:rate("Hunter","encounters")),
        "State: "..state,
        "",
        status,
        "",
        "H start/stop"
    },"\n")
    if force or text~=lastText then panel:clear(); panel:print(text); lastText=text end
end

local function tick()
    frames=frames+1
    inputMask=0
    if not active then render(false); return end

    if inBattle() then
        handleBattle()
    elseif inOverworld() then
        if wasInBattle then
            if runAttempts>0 then fled=fled+1; stats:inc("Hunter","fled",1) end
            wasInBattle=false
            encounterPid=nil
            runAttempts=0
            state="searching"
            status="Fled safely. Spinning for the next encounter."
        end
        spin()
    else
        state="transition"
    end
    if STARTER_HUNTER_HEADLESS then emu:setKeys(inputMask) end
    render(false)
end

callbacks:add("key",function(event)
    if GEN3_SUITE_ACTIVE_TOOL and GEN3_SUITE_ACTIVE_TOOL~="Hunter" then return end
    if event.state~=1 or ((event.modifiers or 0)&0xC)~=0 or event.key<32 or event.key>126 then return end
    if string.char(event.key):lower()=="h" then
        if active then stop("Stopped. All automated input was released.") else start() end
        render(true)
    end
end)
callbacks:add("keysRead",function() if active then emu:setKeys(inputMask) end end)
frameClock:add(tick)

Hunter={
    start=function() start(); render(true); return true end,
    stop=function() stop("Stopped. All automated input was released."); render(true); return true end,
    getState=function() return {active=active,state=state,status=status,encounters=encounters,fled=fled,pid=encounterPid,
        session=stats:snapshot("Hunter")} end
}

render(true)
