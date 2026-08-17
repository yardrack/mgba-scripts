-- One frame dispatcher for the Gen 3 suite.
--
-- mGBA normally emits a `frame` event after every emulated frame. During
-- fast-forward, some Qt builds can spend long stretches delivering only the
-- `keysRead` event. One dispatcher lets the suite recover without running
-- every tool twice when both events are healthy.

if GEN3_FRAME_CLOCK then return GEN3_FRAME_CLOCK end

local clock={
    callbacks={},count=0,lastFrameAt=os.clock(),lastFallbackAt=-math.huge,
    displayFrame=nil,observedFrame=nil
}
local FALLBACK_AFTER=0.050
local FALLBACK_INTERVAL=1/120

local function currentFrame()
    local ok,value=pcall(function() return emu:currentFrame() end)
    return ok and tonumber(value) or nil
end

local function updateDisplayFrame(observed)
    observed=observed or currentFrame()
    if clock.displayFrame==nil then
        clock.displayFrame=observed or 0
    elseif observed and clock.observedFrame and observed>=clock.observedFrame then
        local delta=observed-clock.observedFrame
        clock.displayFrame=delta>100000 and observed or clock.displayFrame+delta
    elseif observed and clock.observedFrame and observed<clock.observedFrame then
        clock.displayFrame=observed
    else
        -- A reset or savestate can move mGBA's counter backwards. Keep the
        -- display moving until the next observed counter is available.
        clock.displayFrame=clock.displayFrame+1
    end
    clock.observedFrame=observed
end

local function dispatch(observed)
    clock.count=clock.count+1
    updateDisplayFrame(observed)
    for _,callback in ipairs(clock.callbacks) do callback(clock.count) end
end

function clock:add(callback)
    assert(type(callback)=="function","FrameClock callback must be a function")
    self.callbacks[#self.callbacks+1]=callback
    return #self.callbacks
end

function clock:frameCount() return self.count end
function clock:currentFrame() return self.displayFrame or currentFrame() or 0 end

callbacks:add("frame",function()
    clock.lastFrameAt=os.clock()
    dispatch()
end)

callbacks:add("keysRead",function()
    local now=os.clock()
    if now-clock.lastFrameAt<FALLBACK_AFTER then return end
    local observed=currentFrame()
    local frameChanged=observed and clock.observedFrame and observed~=clock.observedFrame
    if not frameChanged and now-clock.lastFallbackAt<FALLBACK_INTERVAL then return end
    clock.lastFallbackAt=now
    dispatch(observed)
end)

GEN3_FRAME_CLOCK=clock
return clock
