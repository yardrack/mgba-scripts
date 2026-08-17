-- Standalone RNG-frame jump tool.
-- Entering a frame writes that frame's exact RNG state immediately. It does
-- not inspect Pokemon, hold the seed, automate input, or change mGBA's
-- separate video-frame counter.

local suiteDir=GEN3_SUITE_DIR or STARTER_HUNTER_DIR or (script and script.dir)
if not suiteDir or not starterHunter then error("Jump requires the loaded Gen 3 RNG core.") end
local frameClock=GEN3_FRAME_CLOCK or dofile(suiteDir.."/lib/FrameClock.lua")
local panel=STARTER_HUNTER_HEADLESS and {
    setSize=function() end,moveCursor=function() end,print=function() end
} or console:createBuffer("Jump")
local WIDTH,HEIGHT=58,12
panel:setSize(WIDTH,HEIGHT)

local editing=false
local editText=""
local selectedFrame=nil
local status="Press G, type an RNG frame, and press Enter."
local lastText=""
local frameCounter=0

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
    return {
        phase=editing and "editing" or "idle",
        status=status,
        currentFrame=frameClock:currentFrame(),
        rngFrame=hit.currentFrame or 0,
        targetFrame=selectedFrame,
        targetText=editing and (editText.."_") or (selectedFrame and tostring(selectedFrame) or "G to enter"),
        currentSeed=runtime.currentSeed
    }
end

local function render(force)
    local state=snapshot()
    local text=table.concat({
        "JUMP  |  RNG FRAME",
        "",
        string.format("Current frame (mGBA)  %d",state.currentFrame),
        string.format("Current RNG position  %d",state.rngFrame),
        "Target RNG frame      "..state.targetText,
        string.format("Current RNG seed   %08X",state.currentSeed or 0),
        "",
        state.status,
        "",
        "G enter frame   Enter jump   Esc cancel",
        "",
        "Jump changes RNG position, not mGBA video time."
    },"\n")
    if force or text~=lastText then panel:moveCursor(0,0); panel:print(fit(text)); lastText=text end
end

local function jumpTo(value)
    local number=tonumber(value)
    if not number or number<0 or number>5000000 then
        status="Invalid frame. Enter a value from 0 to 5000000."
        render(true)
        return false,status
    end
    number=math.floor(number)
    local ok,seed=starterHunter:jumpToFrame(number)
    if not ok then
        status=tostring(seed or "The RNG frame could not be changed.")
        render(true)
        return false,status
    end
    selectedFrame=number
    status=string.format("Jumped directly to RNG frame %d (seed %08X).",number,seed)
    render(true)
    return true,seed
end

local function stop(message)
    editing,editText=false,""
    status=message or "Cancelled. The current RNG frame was not changed."
    render(true)
    return true
end

local function handleKey(event)
    if not activeTool() or event.state~=1 or ((event.modifiers or 0)&0xC)~=0 then return end
    local key=event.key
    if editing then
        if key>=48 and key<=57 then
            if #editText<7 then editText=editText..string.char(key) end
        elseif key==0x08 then
            editText=editText:sub(1,-2)
        elseif key==0x0A or key==0x0D or key==0x800050 then
            local value=editText
            editing,editText=false,""
            jumpTo(value)
            return
        elseif key==0x1B then
            stop("Frame entry cancelled.")
            return
        end
        render(true)
        return
    end
    if key==0x1B then stop(); return end
    if key==71 or key==103 then
        editing,editText=true,""
        status="Type the RNG frame, then press Enter to jump."
        render(true)
    end
end
callbacks:add("key",handleKey)

frameClock:add(function()
    if not activeTool() then return end
    frameCounter=frameCounter+1
    if frameCounter%12==0 then render(false) end
end)

Jump={}
function Jump:jump(value) return jumpTo(value) end
function Jump:setFrame(value) return jumpTo(value) end
function Jump:stop(message) return stop(message) end
function Jump:getState() return snapshot() end
function Jump:testKey(key)
    if not STARTER_HUNTER_ENABLE_TEST_API then return false end
    handleKey({key=key,state=1,modifiers=0})
    return true
end

render(true)
