-- Standalone manual RNG-frame jump and calibration tool.
--
-- Stable mGBA Lua cannot pause the Qt frontend. Instead, this tool holds the
-- corrected RNG state until the mapped GBA A button is observed by keysRead.
-- The user can therefore take as long as needed before pressing X/A without
-- drifting away from the selected frame.

local suiteDir=GEN3_SUITE_DIR or STARTER_HUNTER_DIR or (script and script.dir)
if not suiteDir or not starterHunter then error("Jump requires the loaded Gen 3 RNG core.") end
local frameClock=GEN3_FRAME_CLOCK or dofile(suiteDir.."/lib/FrameClock.lua")
local panel=STARTER_HUNTER_HEADLESS and {
    setSize=function() end,moveCursor=function() end,print=function() end
} or console:createBuffer("Jump")
local WIDTH,HEIGHT=64,17
panel:setSize(WIDTH,HEIGHT)

local jumpMode="starter"
local phase="idle"
local status="Press G for a target, then R when the final A press is ready."
local targetInfo=nil
local jumpTargetFrame=nil
local editing=false
local editText=""
local searching=false
local actualPokemon=nil
local initialPartyCount=0
local initialEnemyPid=0
local lastText=""
local frameCounter=0
local KEY_A_MASK=1

local function activeTool()
    return not GEN3_SUITE_ACTIVE_TOOL or GEN3_SUITE_ACTIVE_TOOL=="Jump"
end

local function fit(text)
    local rows={}
    for line in (text.."\n"):gmatch("(.-)\n") do
        local clipped=line:sub(1,WIDTH)
        rows[#rows+1]=clipped..string.rep(" ",WIDTH-#clipped)
    end
    while #rows<HEIGHT do rows[#rows+1]=string.rep(" ",WIDTH) end
    while #rows>HEIGHT do table.remove(rows) end
    return table.concat(rows,"\n")
end

local function snapshot()
    local hit=starterHunter:getFrameHitState()
    local runtime=starterHunter:getRuntimeState()
    local result=hit.result
    local targetText=editing and ((editText or "").."_")
        or (jumpTargetFrame~=nil and tostring(jumpTargetFrame) or "G to enter")
    return {
        mode=jumpMode,phase=phase,status=status,
        currentFrame=hit.currentFrame,targetFrame=hit.targetFrame,
        targetText=targetText,
        correction=hit.correction or 0,correctedFrame=hit.nextAttemptFrame,
        targetPid=targetInfo and targetInfo.pid or hit.targetPid,
        targetShiny=targetInfo and targetInfo.shinyValue<8 or hit.targetShiny,
        method=targetInfo and targetInfo.method or hit.method,
        pokemon=targetInfo and targetInfo.pokemon or hit.targetPokemon,
        currentSeed=runtime.currentSeed,result=result,actual=actualPokemon,
        resolving=hit.resolving or phase=="resolving"
    }
end

local function render(force)
    local s=snapshot()
    local result=s.result
    local resultText=result and result.landedFrame and string.format("%d (%+d)",result.landedFrame,result.miss or 0) or "--"
    local text=table.concat({
        "JUMP  |  "..(s.mode=="starter" and "Starter" or "Wild").." mode  |  "..s.phase:upper(),
        "",
        string.format("Current RNG frame  %d",s.currentFrame or 0),
        "Shiny target      "..s.targetText.."  (G edit)",
        string.format("Adjusted target   %d  (%+d correction)",s.correctedFrame or 0,s.correction or 0),
        "Target Pokemon    "..tostring(s.pokemon or "--"),
        "Target PID        "..(s.targetPid and string.format("%08X",s.targetPid) or "--"),
        "Method            H-"..tostring(s.method or 1).."  |  Shiny "..(s.targetShiny and "YES" or "NO"),
        "Result frame      "..resultText,
        "",
        s.status,
        "",
        "G target   F find shiny   M Starter/Wild   R arm/re-arm",
        "Q clear calibration   Esc stop   X = your mapped GBA A",
        "",
        phase=="armed" and "RNG HOLD ACTIVE: press X (A) when ready." or
            "Jump holds RNG instead of controlling mGBA frontend pause."
    },"\n")
    if force or text~=lastText then panel:moveCursor(0,0); panel:print(fit(text)); lastText=text end
end

local function setMode(value)
    if phase=="armed" or phase=="waiting" or phase=="resolving" then return false,"Stop the active attempt first." end
    jumpMode=tostring(value):lower()=="wild" and "wild" or "starter"
    starterHunter:setMode(jumpMode)
    if jumpMode=="wild" then starterHunter:detectWildArea(true) end
    targetInfo,actualPokemon,jumpTargetFrame=nil,nil,nil
    editing,editText,searching=false,"",false
    phase="idle"
    status=(jumpMode=="wild")
        and "Hover over Sweet Scent, choose a shiny target, then press R."
        or "Stop on the final Yes button, choose a shiny target, then press R."
    render(true)
    return true
end

local function stop(message)
    starterHunter:cancelFrameResolve()
    phase="idle"
    targetInfo,actualPokemon=nil,nil
    status=message or "Stopped. No RNG state is being held."
    render(true)
    return true
end

local function arm(value)
    local requested=value~=nil and value or jumpTargetFrame
    if requested==nil then status="Press G and enter a target frame first."; render(true); return false,status end
    if not starterHunter:setFrame(requested) then status="Invalid target frame."; render(true); return false,status end
    jumpTargetFrame=math.floor(tonumber(requested))
    if jumpMode=="wild" then starterHunter:detectWildArea(false) end
    local ok,info=starterHunter:lockTargetFrame()
    if not ok then status=tostring(info); phase="idle"; render(true); return false,info end
    targetInfo=info
    actualPokemon=nil
    initialPartyCount=starterHunter:getPartyCount()
    initialEnemyPid=starterHunter:getEnemyPid()
    phase="armed"
    status=string.format("Frame %d is held at corrected frame %d. Press X (A) now.",info.targetFrame,info.correctedFrame)
    render(true)
    return true,info
end

local function finishResult(actual)
    local hit=starterHunter:getFrameHitState()
    local result=hit.result
    if not result or result.pid~=actual.pid or hit.resolving then return false end
    actualPokemon=actual
    if actual.shiny then
        phase="success"
        status=string.format("SHINY VERIFIED: PID %08X on frame %s. Save now.",actual.pid,tostring(result.landedFrame or "--"))
    else
        phase="retry"
        status=string.format("Missed by %+d. Soft reset, return to the ready %s, then press R; next target is %d.",
            result.miss or 0,jumpMode=="wild" and "Sweet Scent action" or "Yes button",hit.nextAttemptFrame or hit.targetFrame)
    end
    render(true)
    return true
end

local function detectResult()
    if phase=="waiting" then
        local actual
        if jumpMode=="starter" then
            local count=starterHunter:getPartyCount()
            if count>initialPartyCount then actual=starterHunter:getPartyPokemon(count) end
        else
            actual=starterHunter:getEnemyPokemon()
            if actual and actual.pid==initialEnemyPid then actual=nil end
        end
        if actual then
            actualPokemon=actual
            local ok,detail
            if jumpMode=="starter" then ok=starterHunter:resolveStarterPid(actual.pid,targetInfo.targetFrame,true)
            else ok,detail=starterHunter:resolveManualPokemon(actual,targetInfo.targetFrame) end
            -- Capture's passive monitor and Jump observe the same enemy.  The
            -- passive callback can win by one poll and start the resolver
            -- first; adopt that job instead of reporting a false failure.
            local hit=starterHunter:getFrameHitState()
            if not ok and hit.resolving then ok=true; detail="existing resolver" end
            if not ok then phase="retry"; status="The generated Pokemon could not be resolved: "..tostring(detail or "verify mode and initial seed")
            else phase="resolving"; status=string.format("Reading PID %08X and calibrating the frame...",actual.pid) end
            render(true)
        end
    elseif phase=="resolving" and actualPokemon then
        finishResult(actualPokemon)
    end
end

callbacks:add("keysRead",function()
    if not activeTool() or phase~="armed" then return end
    local ok,info=starterHunter:lockTargetFrame()
    if not ok then phase="idle"; status=tostring(info); render(true); return end
    targetInfo=info
    local keys=emu.getKeys and (emu:getKeys()&0x3FF) or 0
    if (keys&KEY_A_MASK)~=0 then
        -- Apply the corrected state on the exact input poll that receives A,
        -- then release the hold so the game's normal generation path continues.
        starterHunter:lockTargetFrame()
        phase="waiting"
        status="A received at the held RNG state. Waiting for the Pokemon..."
        render(true)
    end
end)

callbacks:add("reset",function()
    if phase=="idle" then return end
    starterHunter:cancelFrameResolve()
    phase="waiting_ready"
    actualPokemon=nil
    status="Reset detected. Return to the final Yes/Sweet Scent action, then press R."
    render(true)
end)

local function handleKey(event)
    if not activeTool() or event.state~=1 or ((event.modifiers or 0)&0xC)~=0 then return end
    local key=event.key
    if editing then
        if key>=48 and key<=57 then
            if #editText<7 then editText=editText..string.char(key) end
        elseif key==0x08 then
            editText=editText:sub(1,-2)
        elseif key==0x0A or key==0x0D or key==0x800050 then
            local value=tonumber(editText)
            if value and value>=0 and value<=5000000 and starterHunter:setFrame(value) then
                jumpTargetFrame=math.floor(value)
                targetInfo,actualPokemon=nil,nil
                status=string.format("Target frame %d selected. Press R when the final A action is ready.",jumpTargetFrame)
            else
                status="Invalid frame. Enter a value from 0 to 5000000."
            end
            editing,editText=false,""
        elseif key==0x1B then
            editing,editText=false,""
            status="Target edit cancelled."
        end
        render(true)
        return
    end
    if key==0x1B then stop(); return end
    if key<32 or key>126 then render(true); return end
    local c=string.char(key):lower()
    if c=="m" then setMode(jumpMode=="starter" and "wild" or "starter")
    elseif c=="r" then arm()
    elseif c=="f" then
        local hit=starterHunter:getFrameHitState()
        if starterHunter:findAsyncFrom(math.max(0,hit.currentFrame or 0)) then
            searching=true
            status="Searching for the next matching shiny frame..."
        end
        render(true)
    elseif c=="q" then starterHunter:resetFrameDiagnostics(); status="Calibration cleared."; render(true)
    elseif c=="g" then
        editing,editText=true,""
        status="Type the target RNG frame, then press Enter."
        render(true)
    end
end
callbacks:add("key",handleKey)

frameClock:add(function()
    if not activeTool() then return end
    frameCounter=frameCounter+1
    if searching then
        local runtime=starterHunter:getRuntimeState()
        if runtime.mode~="searching" then
            local hit=starterHunter:getFrameHitState()
            searching=false
            if hit.targetArmed and hit.targetShiny then
                jumpTargetFrame=hit.targetFrame
                status=string.format("Found shiny frame %d. Press R when the final A action is ready.",jumpTargetFrame)
            else
                status="No matching shiny frame was found in the search range."
            end
            render(true)
        end
    end
    if phase=="armed" then
        local ok,info=starterHunter:lockTargetFrame()
        if ok then targetInfo=info else phase="idle"; status=tostring(info) end
    elseif phase=="waiting" or phase=="resolving" then detectResult() end
    if frameCounter%6==0 then render(false) end
end)

Jump={}
function Jump:setMode(value) return setMode(value) end
function Jump:arm(value) return arm(value) end
function Jump:stop(message) return stop(message) end
function Jump:find(startAt) return starterHunter:findAsyncFrom(startAt) end
function Jump:setFrame(value)
    local number=tonumber(value)
    local ok=number and number>=0 and number<=5000000 and starterHunter:setFrame(number) or false
    if ok then jumpTargetFrame=math.floor(number) end
    render(true)
    return ok
end
function Jump:getState() return snapshot() end
function Jump:testPressA()
        if phase~="armed" then return false end
        starterHunter:lockTargetFrame(); phase="waiting"; status="Test A received."; return true
end
function Jump:testTick() return detectResult() end
function Jump:testKey(key)
    if not STARTER_HUNTER_ENABLE_TEST_API then return false end
    handleKey({key=key,state=1,modifiers=0})
    return true
end

setMode("starter")
