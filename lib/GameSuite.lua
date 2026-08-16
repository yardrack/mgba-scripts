-- Combined entry point for one English Gen 3 game.  The wrapper sets
-- GEN3_SUITE_GAME before loading this file.

local suiteDir=GEN3_SUITE_DIR or STARTER_HUNTER_DIR or (script and script.dir)
if not suiteDir then error("The game suite could not locate its script folder.") end
local code=emu:getGameCode()
if code~=GEN3_SUITE_GAME then
    error(string.format("This suite is for %s, not ROM code %s.",GEN3_SUITE_NAME or GEN3_SUITE_GAME,code))
end

GEN3_SUITE_DIR=suiteDir
STARTER_HUNTER_DIR=suiteDir
GEN3_SUITE_MANAGED=true
GEN3_SUITE_ACTIVE_TOOL="Capture"
STARTER_HUNTER_CAPTURE_ONLY=true
MANUAL_MONITOR_SHOW_RNG_PANELS=false
MANUAL_MONITOR_REQUIRE_INPUT=true
POKEMON_INFO_HIDE_UI=true
RNG_COMPACT_UI=true
GEN3_FRAME_CLOCK=dofile(suiteDir.."/lib/FrameClock.lua")
GEN3_SESSION_STATS=dofile(suiteDir.."/lib/SessionStats.lua").forGame(emu,code)

-- Capture retains the shared seed and PID readers, but the automatic shiny
-- search, input scheduler, command bridge, and separate RNG panel are disabled.
dofile(suiteDir.."/lib/PokemonInfoCore.lua")
MANUAL_MONITOR_KIND="combined"
MANUAL_MONITOR_PANEL_NAME="Capture"
MANUAL_MONITOR_DEFAULT_KIND="starter"
dofile(suiteDir.."/lib/ManualMonitor.lua")

-- Battle and Pickup share one automation core.  Emerald retains its richer
-- battle implementation while the other games use the common profile core.
if code=="BPEE" then
    BATTLE_DISABLE_KEYS=true
    dofile(suiteDir.."/lib/BattleCore.lua")
    dofile(suiteDir.."/lib/PickupCore.lua")
else
    GEN3_GRIND_UI="suite"
    dofile(suiteDir.."/lib/UniversalBattleCore.lua")
end
dofile(suiteDir.."/lib/HunterCore.lua")

local tools={"Capture","Battle","Pickup","Hunter"}
local toolIndex=1

local function battleActive()
    return Battle and Battle.getState and Battle:getState().active or false
end

local function hunterActive()
    return Hunter and Hunter.getState and Hunter:getState().active or false
end

local function pickupActive()
    return Pickup and Pickup.isRunning and Pickup:isRunning() or false
end

local function stopAutomation()
    if battleActive() then Battle:stop() end
    if pickupActive() and Pickup.stop then Pickup:stop() end
    if hunterActive() then Hunter:stop() end
    emu:setKeys(0)
    if emu.clearKeys then emu:clearKeys(0x3FF) end
end

local function selectTool(value)
    local found
    if type(value)=="number" then
        found=((math.floor(value)-1)%#tools)+1
    else
        for i,name in ipairs(tools) do if name==value then found=i; break end end
    end
    if not found then return false end
    if found~=toolIndex then stopAutomation() end
    toolIndex=found
    GEN3_SUITE_ACTIVE_TOOL=tools[toolIndex]
    if GEN3_SUITE_ACTIVE_TOOL=="Battle" and Battle and Battle.getState and Battle:getState().mode=="Pickup" then
        Battle:setMode("Lead")
    end
    return true
end

local function onKey(event)
    if event.state~=1 or ((event.modifiers or 0)&0xC)~=0 then return end
    local key=event.key
    if key>=8388609 and key<=8388612 then selectTool(key-8388608); return end
    if key<32 or key>126 then return end
    local c=string.char(key):lower()
    local current=tools[toolIndex]
    if c=="c" and current~="Capture" and current~="Pickup" then
        selectTool("Capture"); return
    elseif c=="b" and current~="Battle" then
        selectTool("Battle"); Battle:start(); return
    elseif c=="p" and current~="Pickup" then
        selectTool("Pickup"); Pickup:start(); return
    elseif c=="h" and current~="Hunter" and not (current=="Battle" and code=="BPEE") then
        selectTool("Hunter"); Hunter:start(); return
    end
    if current=="Battle" then
        if c=="b" then if battleActive() then Battle:stop() else Battle:start() end
        elseif c=="1" and not battleActive() then Battle:setMode("Lead")
        elseif c=="2" and not battleActive() then Battle:setMode("Balanced")
        elseif c=="h" and code=="BPEE" and not battleActive() then
            local currentHeal=Battle:getState().healPercent
            Battle:setHealPercent(currentHeal==30 and 20 or 30)
        else return end
    elseif current=="Pickup" then
        if c=="p" then if pickupActive() then Pickup:stop() else Pickup:start() end
        elseif c=="f" and Pickup.cycleFilter then Pickup:cycleFilter()
        elseif c=="c" and not pickupActive() and Pickup.collect then Pickup:collect()
        elseif c=="x" and not pickupActive() and Pickup.clearTotals then Pickup:clearTotals()
        else return end
    elseif current=="Hunter" then
        return
    else
        -- Capture retains its G/M/Q/I controls. Hunter owns H while selected.
        return
    end
end
callbacks:add("key",onKey)

-- There is deliberately no suite console tab. Individual tools render their
-- own buffers, so rebuilding the hidden router text every 30 frames only adds
-- formatting and memory-read work.

Gen3Suite={
    selectTool=selectTool,
    handleKey=onKey,
    currentTool=function() return tools[toolIndex] end,
    tools=function() local copy={} for i,v in ipairs(tools) do copy[i]=v end; return copy end,
    stop=stopAutomation,
    getState=function()
        return {game=GEN3_SUITE_NAME or code,code=code,tool=tools[toolIndex],
            battle=battleActive(),pickup=pickupActive(),hunter=hunterActive(),
            stats=GEN3_SESSION_STATS:all()}
    end
}
